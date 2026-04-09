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

## SAN (Standard Algebraic Notation) parser and formatter

import std/[options, strutils, strformat]

import heimdall/[board, moves, pieces, movegen]


proc charToPieceKind(c: char): PieceKind =
    case c.toLowerAscii():
        of 'k': King
        of 'q': Queen
        of 'r': Rook
        of 'b': Bishop
        of 'n': Knight
        of 'p': Pawn
        else: Empty


proc parseSAN*(board: Chessboard, san: string): tuple[move: Move, error: string] =
    ## Parses a SAN string and returns the corresponding legal move.
    ## Returns nullMove() with an error message if the SAN is invalid.
    var moves = newMoveList()
    board.generateMoves(moves)

    if san.len == 0:
        return (nullMove(), "empty move")

    # Handle castling
    if san in ["O-O", "0-0", "o-o"]:
        for move in moves:
            if move.isShortCastling():
                return (move, "")
        return (nullMove(), "short castling not available")

    if san in ["O-O-O", "0-0-0", "o-o-o"]:
        for move in moves:
            if move.isLongCastling():
                return (move, "")
        return (nullMove(), "long castling not available")

    # Strip check/checkmate indicators and annotations
    var s = san
    while s.len > 0 and s[^1] in {'+', '#', '!', '?'}:
        s = s[0..^2]

    if s.len == 0:
        return (nullMove(), "empty move after stripping annotations")

    # Parse promotion suffix (e.g., "=Q", "=N")
    var promotionPiece = Empty
    if s.len >= 2 and s[^2] == '=':
        promotionPiece = charToPieceKind(s[^1])
        if promotionPiece == Empty:
            return (nullMove(), &"invalid promotion piece '{s[^1]}'")
        s = s[0..^3]

    # Parse capture marker
    s = s.replace("x", "")

    if s.len < 2:
        return (nullMove(), "move too short")

    # Determine piece kind from first character
    var pieceKind: PieceKind
    if s[0] in "KQRBN":
        pieceKind = charToPieceKind(s[0])
        s = s[1..^1]
    else:
        pieceKind = Pawn

    if s.len < 2:
        return (nullMove(), "move too short after piece")

    # Target square is always the last two characters
    let targetStr = s[^2..^1]
    if targetStr[0] notin 'a'..'h' or targetStr[1] notin '1'..'8':
        return (nullMove(), &"invalid target square '{targetStr}'")

    var targetSquare: Square
    try:
        targetSquare = targetStr.toSquare(checked=true)
    except ValueError:
        return (nullMove(), &"invalid target square '{targetStr}'")

    # Disambiguation: everything before the target square
    let disambig = s[0..^3]
    var disambigFile = none(int8)
    var disambigRank = none(int8)
    for c in disambig:
        if c in 'a'..'h':
            disambigFile = some((c.uint8 - 'a'.uint8).int8)
        elif c in '1'..'8':
            # Convert to internal rank (0 = rank 8, 7 = rank 1)
            disambigRank = some(((c.uint8 - '1'.uint8) xor 7).int8)

    # Find matching legal move
    var matchCount = 0
    var matchedMove = nullMove()

    for move in moves:
        if move.targetSquare() != targetSquare:
            continue

        let startSq = move.startSquare()
        let piece = board.on(startSq)

        if piece.kind != pieceKind:
            continue

        # Check disambiguation
        if disambigFile.isSome() and startSq.file().int8 != disambigFile.get():
            continue
        if disambigRank.isSome() and startSq.rank().int8 != disambigRank.get():
            continue

        # Check promotion
        if promotionPiece != Empty:
            if not move.isPromotion():
                continue
            if move.flag().promotionToPiece() != promotionPiece:
                continue
        elif move.isPromotion():
            # If no promotion specified but move is a promotion, skip non-queen promotions
            if move.flag().promotionToPiece() != Queen:
                continue

        inc matchCount
        matchedMove = move

    if matchCount == 0:
        return (nullMove(), &"no legal move matches '{san}'")
    if matchCount > 1:
        return (nullMove(), &"ambiguous move '{san}' ({matchCount} matches)")

    return (matchedMove, "")


proc toSAN*(board: Chessboard, move: Move): string =
    ## Converts a move to SAN notation given the current board position.
    if move == nullMove():
        return "null"

    # Castling
    if move.isShortCastling():
        return "O-O"
    if move.isLongCastling():
        return "O-O-O"

    let piece = board.on(move.startSquare())
    let isCapture = move.isCapture() or move.isEnPassant()

    # Piece letter (uppercase, omitted for pawns)
    if piece.kind != Pawn:
        result &= piece.toChar().toUpperAscii()

    # Disambiguation
    if piece.kind != Pawn:
        var moves = newMoveList()
        board.generateMoves(moves)

        var needFile = false
        var needRank = false
        var ambiguous = false

        for other in moves:
            if other == move:
                continue
            if other.targetSquare() != move.targetSquare():
                continue
            if board.on(other.startSquare()).kind != piece.kind:
                continue

            # Another piece of same kind can go to same target
            ambiguous = true
            if other.startSquare().file() == move.startSquare().file():
                needRank = true
            if other.startSquare().rank() == move.startSquare().rank():
                needFile = true

        if ambiguous:
            if not needFile and not needRank:
                # Default: disambiguate by file
                needFile = true
            if needFile:
                result &= chr(ord('a') + move.startSquare().file().int)
            if needRank:
                result &= chr(ord('1') + (move.startSquare().rank().int xor 7))

    elif isCapture:
        # Pawn captures include the origin file
        result &= chr(ord('a') + move.startSquare().file().int)

    # Capture marker
    if isCapture:
        result &= "x"

    # Target square
    result &= move.targetSquare().toUCI()

    # Promotion
    if move.isPromotion():
        result &= "="
        case move.flag().promotionToPiece():
            of Queen: result &= "Q"
            of Rook: result &= "R"
            of Bishop: result &= "B"
            of Knight: result &= "N"
            else: discard

    # Check/checkmate indicator
    # We need to make the move to see if it results in check/mate
    let resultMove = board.makeMove(move)
    if resultMove != nullMove():
        if board.inCheck():
            var legalMoves = newMoveList()
            board.generateMoves(legalMoves)
            if legalMoves.len == 0:
                result &= "#"
            else:
                result &= "+"
        board.unmakeMove()
