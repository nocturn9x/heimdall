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

## Premove pseudo-legal validation and virtual-board simulation helpers.

import heimdall/[board, movegen]
import heimdall/tui/state


proc lastRank(color: PieceColor): int {.inline.} =
    if color == White: 0 else: 7


proc homePawnRank(color: PieceColor): int {.inline.} =
    if color == White: 6 else: 1


proc preparePremoveBoard(board: Chessboard, playerColor: PieceColor) =
    board.positions[^1].sideToMove = playerColor
    board.positions[^1].updateChecksAndPins()
    board.positions[^1].hash()


proc buildPseudolegalPremoveMove*(board: Chessboard, fromSq, toSq: Square, chess960 = false): Move =
    let rawPiece = board.on(fromSq)
    if rawPiece.kind == Empty or rawPiece.color != board.sideToMove():
        return nullMove()
    if fromSq == toSq:
        return nullMove()

    let castlingRights = board.position.castlingAvailability[rawPiece.color]
    let rawTargetPiece = board.on(toSq)
    var actualFrom = fromSq
    var actualTo = toSq
    if rawPiece.kind == Rook and rawTargetPiece.kind == King and rawTargetPiece.color == rawPiece.color:
        if fromSq == castlingRights.king or fromSq == castlingRights.queen:
            actualFrom = board.position.kingSquare(rawPiece.color)
            actualTo = fromSq

    let piece = board.on(actualFrom)
    let targetPiece = board.on(actualTo)
    let castlingTarget =
        piece.kind == King and
        (
            actualTo in ["c1".toSquare(), "c8".toSquare(), "g1".toSquare(), "g8".toSquare()] or
            actualTo == castlingRights.king or
            actualTo == castlingRights.queen
        )
    if targetPiece.kind == King and not castlingTarget:
        return nullMove()
    if targetPiece.color == piece.color and not castlingTarget:
        return nullMove()

    let
        occupancy = board.position.pieces()
        fileDiff = actualTo.file().int - actualFrom.file().int
        rankDiff = actualTo.rank().int - actualFrom.rank().int

    case piece.kind:
        of Pawn:
            let forward = if piece.color == White: -1 else: 1
            if fileDiff == 0:
                if rankDiff == forward and targetPiece.kind == Empty:
                    if actualTo.rank().int == lastRank(piece.color):
                        return createMove(actualFrom, actualTo, PromotionQueen)
                    return createMove(actualFrom, actualTo, Normal)
                if rankDiff == 2 * forward and actualFrom.rank().int == homePawnRank(piece.color):
                    let intermediate = makeSquare(actualFrom.rank().int + forward, actualFrom.file().int)
                    if board.on(intermediate).kind == Empty and targetPiece.kind == Empty:
                        return createMove(actualFrom, actualTo, DoublePush)
                return nullMove()

            if abs(fileDiff) == 1 and rankDiff == forward:
                if targetPiece.color == piece.color.opposite():
                    if actualTo.rank().int == lastRank(piece.color):
                        return createMove(actualFrom, actualTo, CapturePromotionQueen)
                    return createMove(actualFrom, actualTo, Capture)
                if actualTo == board.position.enPassantSquare:
                    return createMove(actualFrom, actualTo, EnPassant)
            nullMove()

        of Knight:
            if (knightMoves(actualFrom) and actualTo.toBitboard()).isEmpty():
                return nullMove()
            if targetPiece.color == piece.color.opposite():
                return createMove(actualFrom, actualTo, Capture)
            createMove(actualFrom, actualTo, Normal)

        of Bishop:
            if (bishopMoves(actualFrom, occupancy) and actualTo.toBitboard()).isEmpty():
                return nullMove()
            if targetPiece.color == piece.color.opposite():
                return createMove(actualFrom, actualTo, Capture)
            createMove(actualFrom, actualTo, Normal)

        of Rook:
            if (rookMoves(actualFrom, occupancy) and actualTo.toBitboard()).isEmpty():
                return nullMove()
            if targetPiece.color == piece.color.opposite():
                return createMove(actualFrom, actualTo, Capture)
            createMove(actualFrom, actualTo, Normal)

        of Queen:
            if ((bishopMoves(actualFrom, occupancy) or rookMoves(actualFrom, occupancy)) and actualTo.toBitboard()).isEmpty():
                return nullMove()
            if targetPiece.color == piece.color.opposite():
                return createMove(actualFrom, actualTo, Capture)
            createMove(actualFrom, actualTo, Normal)

        of King:
            if not (kingMoves(actualFrom) and actualTo.toBitboard()).isEmpty():
                if targetPiece.color == piece.color.opposite():
                    return createMove(actualFrom, actualTo, Capture)
                return createMove(actualFrom, actualTo, Normal)

            var rookSquare = nullSquare()
            var flag = Normal
            if actualTo == castlingRights.king:
                rookSquare = castlingRights.king
                flag = ShortCastling
            elif actualTo == castlingRights.queen:
                rookSquare = castlingRights.queen
                flag = LongCastling
            elif actualFrom in ["e1".toSquare(), "e8".toSquare()]:
                case actualTo:
                of "c1".toSquare(), "c8".toSquare():
                    rookSquare = castlingRights.queen
                    flag = LongCastling
                of "g1".toSquare(), "g8".toSquare():
                    rookSquare = castlingRights.king
                    flag = ShortCastling
                else:
                    discard

            if flag == Normal:
                return nullMove()
            if rookSquare == nullSquare():
                return nullMove()

            let rook = board.on(rookSquare)
            if rook.kind != Rook or rook.color != piece.color:
                return nullMove()

            let castleOccupancy = board.position.pieces() and not actualFrom.toBitboard() and not rookSquare.toBitboard()
            let kingTarget = if flag == ShortCastling: piece.shortCastling() else: piece.longCastling()
            let rookTarget = if flag == ShortCastling: rook.shortCastling() else: rook.longCastling()

            if not (rayBetween(rookSquare, actualFrom) and castleOccupancy).isEmpty():
                return nullMove()
            if not (rayBetween(rookSquare, kingTarget) and castleOccupancy).isEmpty():
                return nullMove()
            if not (rayBetween(rookSquare, rookTarget) and castleOccupancy).isEmpty():
                return nullMove()

            createMove(actualFrom, rookSquare, flag)

        of Empty:
            nullMove()


proc applySimulatedPremove(board: Chessboard, playerColor: PieceColor, premove: Premove, chess960: bool): bool =
    board.preparePremoveBoard(playerColor)
    let move = board.buildPseudolegalPremoveMove(premove.fromSq, premove.toSq, chess960)
    if move == nullMove():
        return false
    board.doMove(move)
    true


proc premoveViewBoard*(board: Chessboard, playerColor: PieceColor, premoves: openArray[Premove], chess960 = false): Chessboard =
    result = newChessboard(board.positions)
    result.preparePremoveBoard(playerColor)
    for premove in premoves:
        if not result.applySimulatedPremove(playerColor, premove, chess960):
            break


proc canQueuePremove*(board: Chessboard, playerColor: PieceColor, premoves: openArray[Premove], fromSq, toSq: Square, chess960 = false): bool =
    let previewBoard = premoveViewBoard(board, playerColor, premoves, chess960)
    previewBoard.preparePremoveBoard(playerColor)
    previewBoard.buildPseudolegalPremoveMove(fromSq, toSq, chess960) != nullMove()


proc premoveDestinations*(board: Chessboard, playerColor: PieceColor, premoves: openArray[Premove], fromSq: Square, chess960 = false): seq[Square] =
    let previewBoard = premoveViewBoard(board, playerColor, premoves, chess960)
    previewBoard.preparePremoveBoard(playerColor)
    for rank in 0..7:
        for file in 0..7:
            let sq = makeSquare(rank, file)
            if previewBoard.buildPseudolegalPremoveMove(fromSq, sq, chess960) != nullMove():
                result.add(sq)
