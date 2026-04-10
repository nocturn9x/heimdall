# Copyright 2025 Mattia Giambirtone & All Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

## PGN (Portable Game Notation) parser.

import std/[strutils, strformat]

import heimdall/[board, moves, movegen, position]
import heimdall/tui/util/san


type
    PGNTag* = tuple[name, value: string]

    PGNGame* = object
        tags*: seq[PGNTag]
        moves*: seq[Move]          ## Main line moves
        sanMoves*: seq[string]     ## SAN text of each move
        comments*: seq[string]     ## Comment after each move (empty if none)
        result*: string            ## "1-0", "0-1", "1/2-1/2", "*"
        startFEN*: string          ## Starting position FEN (empty = standard)

    PGNTokenKind = enum
        tokSymbol       # Move text, result, etc
        tokString       # Quoted string
        tokInteger      # Move number
        tokPeriod       # .
        tokTagOpen      # [
        tokTagClose     # ]
        tokCommentOpen  # {
        tokCommentClose # }
        tokRAVOpen      # (
        tokRAVClose     # )
        tokNAG          # $N
        tokEOF

    PGNToken = object
        kind: PGNTokenKind
        value: string

    PGNParser = object
        input: string
        pos: int
        tokens: seq[PGNToken]
        tokIdx: int


# --- Tokenizer ---

proc skipWhitespace(p: var PGNParser) =
    while p.pos < p.input.len and p.input[p.pos] in {' ', '\t', '\n', '\r'}:
        inc p.pos
    # Skip line comments (;)
    if p.pos < p.input.len and p.input[p.pos] == ';':
        while p.pos < p.input.len and p.input[p.pos] != '\n':
            inc p.pos
        p.skipWhitespace()


proc tokenize(p: var PGNParser) =
    while p.pos < p.input.len:
        p.skipWhitespace()
        if p.pos >= p.input.len: break

        let c = p.input[p.pos]
        case c:
            of '[':
                p.tokens.add(PGNToken(kind: tokTagOpen))
                inc p.pos
            of ']':
                p.tokens.add(PGNToken(kind: tokTagClose))
                inc p.pos
            of '{':
                inc p.pos
                var comment = ""
                while p.pos < p.input.len and p.input[p.pos] != '}':
                    comment.add(p.input[p.pos])
                    inc p.pos
                if p.pos < p.input.len: inc p.pos  # skip }
                p.tokens.add(PGNToken(kind: tokCommentOpen, value: comment.strip()))
            of '(':
                p.tokens.add(PGNToken(kind: tokRAVOpen))
                inc p.pos
            of ')':
                p.tokens.add(PGNToken(kind: tokRAVClose))
                inc p.pos
            of '"':
                inc p.pos
                var s = ""
                while p.pos < p.input.len and p.input[p.pos] != '"':
                    if p.input[p.pos] == '\\' and p.pos + 1 < p.input.len:
                        inc p.pos
                    s.add(p.input[p.pos])
                    inc p.pos
                if p.pos < p.input.len: inc p.pos  # skip closing "
                p.tokens.add(PGNToken(kind: tokString, value: s))
            of '$':
                inc p.pos
                var nag = ""
                while p.pos < p.input.len and p.input[p.pos].isDigit():
                    nag.add(p.input[p.pos])
                    inc p.pos
                p.tokens.add(PGNToken(kind: tokNAG, value: nag))
            of '.':
                p.tokens.add(PGNToken(kind: tokPeriod))
                inc p.pos
                # Skip additional dots (e.g. "1..." = "1.")
                while p.pos < p.input.len and p.input[p.pos] == '.':
                    inc p.pos
            of '*':
                p.tokens.add(PGNToken(kind: tokSymbol, value: "*"))
                inc p.pos
            else:
                if c.isDigit() or c.isAlphaAscii() or c in {'-', '+', '#', '=', '/'}:
                    var sym = ""
                    while p.pos < p.input.len and p.input[p.pos] notin {' ', '\t', '\n', '\r', '[', ']', '{', '}', '(', ')', '"', ';'}:
                        sym.add(p.input[p.pos])
                        inc p.pos
                    # Distinguish integers from symbols
                    var allDigits = true
                    for ch in sym:
                        if not ch.isDigit():
                            allDigits = false
                            break
                    if allDigits and sym.len > 0:
                        p.tokens.add(PGNToken(kind: tokInteger, value: sym))
                    else:
                        p.tokens.add(PGNToken(kind: tokSymbol, value: sym))
                else:
                    inc p.pos  # skip unknown chars

    p.tokens.add(PGNToken(kind: tokEOF))


# --- Parser ---

proc peek(p: PGNParser): PGNToken =
    if p.tokIdx < p.tokens.len:
        p.tokens[p.tokIdx]
    else:
        PGNToken(kind: tokEOF)

proc advance(p: var PGNParser): PGNToken =
    result = p.peek()
    if p.tokIdx < p.tokens.len:
        inc p.tokIdx

proc isResult(s: string): bool =
    s in ["1-0", "0-1", "1/2-1/2", "*"]


proc parseTags(p: var PGNParser): seq[PGNTag] =
    while p.peek().kind == tokTagOpen:
        discard p.advance()  # [
        var name = ""
        var value = ""
        if p.peek().kind == tokSymbol:
            name = p.advance().value
        if p.peek().kind == tokString:
            value = p.advance().value
        if p.peek().kind == tokTagClose:
            discard p.advance()  # ]
        result.add((name: name, value: value))


proc parseMovetext(p: var PGNParser, startBoard: Chessboard): tuple[moves: seq[Move], sans: seq[string], comments: seq[string], result: string] =
    var board = newChessboard(startBoard.positions)
    var ravDepth = 0

    while p.peek().kind != tokEOF:
        let tok = p.peek()

        case tok.kind:
            of tokInteger:
                discard p.advance()  # move number
                # Skip periods after move number
                while p.peek().kind == tokPeriod:
                    discard p.advance()

            of tokPeriod:
                discard p.advance()

            of tokSymbol:
                if tok.value.isResult():
                    result.result = p.advance().value
                    return

                if ravDepth > 0:
                    # Inside a variation - skip
                    discard p.advance()
                    continue

                let sanStr = p.advance().value
                let (move, error) = board.parseSAN(sanStr)
                if move == nullMove():
                    # Failed to parse move - try to continue
                    result.comments.add(&"[Error: {error} for '{sanStr}']")
                    continue

                result.moves.add(move)
                result.sans.add(sanStr)

                # Check for comment after the move
                if p.peek().kind == tokCommentOpen:
                    result.comments.add(p.advance().value)
                else:
                    result.comments.add("")

                discard board.makeMove(move)

            of tokCommentOpen:
                let comment = p.advance().value
                # Comment before any move or between move number and move
                if ravDepth == 0 and result.comments.len > 0 and result.comments[^1] == "":
                    result.comments[^1] = comment

            of tokRAVOpen:
                discard p.advance()
                inc ravDepth

            of tokRAVClose:
                discard p.advance()
                if ravDepth > 0:
                    dec ravDepth

            of tokNAG:
                discard p.advance()  # skip NAGs

            else:
                discard p.advance()

    result.result = "*"  # unterminated


proc parsePGN*(input: string): seq[PGNGame] =
    ## Parses one or more PGN games from a string
    var p = PGNParser(input: input, pos: 0)
    p.tokenize()

    while p.peek().kind != tokEOF:
        # Skip any non-tag tokens between games
        while p.peek().kind notin {tokTagOpen, tokEOF}:
            discard p.advance()

        if p.peek().kind == tokEOF:
            break

        var game: PGNGame

        # Parse tags
        game.tags = p.parseTags()

        # Check for FEN tag
        for tag in game.tags:
            if tag.name.toLowerAscii() == "fen":
                game.startFEN = tag.value

        # Create starting board
        let startBoard = if game.startFEN.len > 0:
            newChessboardFromFEN(game.startFEN)
        else:
            newDefaultChessboard()

        # Parse movetext
        let (moves, sans, comments, gameResult) = p.parseMovetext(startBoard)
        game.moves = moves
        game.sanMoves = sans
        game.comments = comments
        game.result = gameResult

        result.add(game)


proc getTag*(game: PGNGame, name: string): string =
    for tag in game.tags:
        if tag.name.toLowerAscii() == name.toLowerAscii():
            return tag.value
    return ""
