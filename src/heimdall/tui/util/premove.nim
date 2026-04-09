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
    let piece = board.on(fromSq)
    if piece.kind == Empty or piece.color != board.sideToMove():
        return nullMove()
    if fromSq == toSq:
        return nullMove()

    let targetPiece = board.on(toSq)
    if targetPiece.color == piece.color:
        return nullMove()

    let
        occupancy = board.position.pieces()
        fileDiff = toSq.file().int - fromSq.file().int
        rankDiff = toSq.rank().int - fromSq.rank().int

    case piece.kind
    of Pawn:
        let forward = if piece.color == White: -1 else: 1
        if fileDiff == 0:
            if rankDiff == forward and targetPiece.kind == Empty:
                if toSq.rank().int == lastRank(piece.color):
                    return createMove(fromSq, toSq, PromotionQueen)
                return createMove(fromSq, toSq, Normal)
            if rankDiff == 2 * forward and fromSq.rank().int == homePawnRank(piece.color):
                let intermediate = makeSquare(fromSq.rank().int + forward, fromSq.file().int)
                if board.on(intermediate).kind == Empty and targetPiece.kind == Empty:
                    return createMove(fromSq, toSq, DoublePush)
            return nullMove()

        if abs(fileDiff) == 1 and rankDiff == forward:
            if targetPiece.color == piece.color.opposite():
                if toSq.rank().int == lastRank(piece.color):
                    return createMove(fromSq, toSq, CapturePromotionQueen)
                return createMove(fromSq, toSq, Capture)
            if toSq == board.position.enPassantSquare:
                return createMove(fromSq, toSq, EnPassant)
        nullMove()

    of Knight:
        if (knightMoves(fromSq) and toSq.toBitboard()).isEmpty():
            return nullMove()
        if targetPiece.color == piece.color.opposite():
            return createMove(fromSq, toSq, Capture)
        createMove(fromSq, toSq, Normal)

    of Bishop:
        if (bishopMoves(fromSq, occupancy) and toSq.toBitboard()).isEmpty():
            return nullMove()
        if targetPiece.color == piece.color.opposite():
            return createMove(fromSq, toSq, Capture)
        createMove(fromSq, toSq, Normal)

    of Rook:
        if (rookMoves(fromSq, occupancy) and toSq.toBitboard()).isEmpty():
            return nullMove()
        if targetPiece.color == piece.color.opposite():
            return createMove(fromSq, toSq, Capture)
        createMove(fromSq, toSq, Normal)

    of Queen:
        if ((bishopMoves(fromSq, occupancy) or rookMoves(fromSq, occupancy)) and toSq.toBitboard()).isEmpty():
            return nullMove()
        if targetPiece.color == piece.color.opposite():
            return createMove(fromSq, toSq, Capture)
        createMove(fromSq, toSq, Normal)

    of King:
        if not (kingMoves(fromSq) and toSq.toBitboard()).isEmpty():
            if targetPiece.color == piece.color.opposite():
                return createMove(fromSq, toSq, Capture)
            return createMove(fromSq, toSq, Normal)

        let canCastle = board.canCastle()
        var targetSquare = toSq
        var flag = Normal
        if fromSq in ["e1".toSquare(), "e8".toSquare()]:
            case toSq
            of "c1".toSquare(), "c8".toSquare():
                targetSquare = canCastle.queen
                flag = LongCastling
            of "g1".toSquare(), "g8".toSquare():
                targetSquare = canCastle.king
                flag = ShortCastling
            else:
                if toSq == canCastle.king:
                    flag = ShortCastling
                elif toSq == canCastle.queen:
                    flag = LongCastling
        elif toSq == canCastle.king:
            flag = ShortCastling
        elif toSq == canCastle.queen:
            flag = LongCastling

        if flag == Normal:
            return nullMove()
        if targetSquare == nullSquare():
            return nullMove()
        if not chess960 and toSq notin ["c1".toSquare(), "c8".toSquare(), "g1".toSquare(), "g8".toSquare()]:
            return nullMove()
        createMove(fromSq, targetSquare, flag)

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
