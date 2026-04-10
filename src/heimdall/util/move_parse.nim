# Copyright 2026 Mattia Giambirtone & All Contributors
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

## Shared UCI move parsing helpers used by both the engine UCI frontend and the TUI.

import std/[strformat, strutils]

import heimdall/position


type
    UCIMoveParseErrorKind* = enum
        umpNone
        umpInvalidSyntax
        umpInvalidStartSquare
        umpInvalidTargetSquare
        umpNoPieceOnStart
        umpInvalidPromotionPiece
        umpChess960Disabled

    UCIMoveParseError* = object
        kind*: UCIMoveParseErrorKind
        detail*: string


func hasError*(error: UCIMoveParseError): bool {.inline.} =
    error.kind != umpNone


proc formatUCIMoveParseError*(
    error: UCIMoveParseError,
    quoteSquares = false,
    chess960DisabledPrefix = "Chess960-style castling move",
    chess960DisabledReason = "Chess960 is not enabled"
): string =
    case error.kind:
        of umpNone:
            ""
        of umpInvalidSyntax:
            "invalid move syntax"
        of umpInvalidStartSquare:
            let square = if quoteSquares: &"'{error.detail}'" else: error.detail
            &"invalid start square {square}"
        of umpInvalidTargetSquare:
            let square = if quoteSquares: &"'{error.detail}'" else: error.detail
            &"invalid target square {square}"
        of umpNoPieceOnStart:
            &"no piece on {error.detail}"
        of umpInvalidPromotionPiece:
            &"invalid promotion piece '{error.detail}'"
        of umpChess960Disabled:
            &"{chess960DisabledPrefix} '{error.detail}', but {chess960DisabledReason}"


proc parseUCIMove*(
    position: Position,
    moveStr: string,
    chess960 = false,
    requireSourcePiece = false
): tuple[move: Move, error: UCIMoveParseError] =
    var
        startSquare: Square
        targetSquare: Square
        flag = Normal

    if moveStr.len notin 4..5:
        result.error = UCIMoveParseError(kind: umpInvalidSyntax)
        return

    let move = moveStr.toLowerAscii()

    try:
        startSquare = move[0..1].toSquare(checked=true)
    except ValueError:
        result.error = UCIMoveParseError(kind: umpInvalidStartSquare, detail: move[0..1])
        return

    try:
        targetSquare = move[2..3].toSquare(checked=true)
    except ValueError:
        result.error = UCIMoveParseError(kind: umpInvalidTargetSquare, detail: move[2..3])
        return

    let piece = position.on(startSquare)

    if requireSourcePiece and piece.kind == Empty:
        result.error = UCIMoveParseError(kind: umpNoPieceOnStart, detail: move[0..1])
        return

    if piece.kind == Pawn and absDistance(rank(startSquare), rank(targetSquare)) == 2:
        flag = DoublePush

    if move.len == 5:
        case move[4]:
            of 'b':
                flag = PromotionBishop
            of 'n':
                flag = PromotionKnight
            of 'q':
                flag = PromotionQueen
            of 'r':
                flag = PromotionRook
            else:
                result.error = UCIMoveParseError(kind: umpInvalidPromotionPiece, detail: $move[4])
                return

    if piece.kind != Empty and position.on(targetSquare).color == piece.color.opposite():
        case flag:
            of PromotionBishop:
                flag = CapturePromotionBishop
            of PromotionKnight:
                flag = CapturePromotionKnight
            of PromotionRook:
                flag = CapturePromotionRook
            of PromotionQueen:
                flag = CapturePromotionQueen
            else:
                flag = Capture

    let canCastle = position.canCastle()

    if piece.kind == King:
        if startSquare in ["e1".toSquare(), "e8".toSquare()]:
            case targetSquare:
                of "c1".toSquare(), "c8".toSquare():
                    flag = LongCastling
                    targetSquare = canCastle.queen
                of "g1".toSquare(), "g8".toSquare():
                    flag = ShortCastling
                    targetSquare = canCastle.king
                else:
                    if targetSquare in [canCastle.king, canCastle.queen]:
                        if not chess960:
                            result.error = UCIMoveParseError(kind: umpChess960Disabled, detail: moveStr)
                            return
                        flag = if targetSquare == canCastle.king: ShortCastling else: LongCastling
        elif targetSquare in [canCastle.king, canCastle.queen]:
            if not chess960:
                result.error = UCIMoveParseError(kind: umpChess960Disabled, detail: moveStr)
                return
            flag = if targetSquare == canCastle.king: ShortCastling else: LongCastling

    if piece.kind == Pawn and targetSquare == position.enPassantSquare:
        flag = EnPassant

    result.move = createMove(startSquare, targetSquare, flag)
