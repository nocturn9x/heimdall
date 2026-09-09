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
#
# Authored with assistance from AI agents.

## Focused move-generation invariants for performance-sensitive specializations.
## Build with:
## make dev MAIN=tests/test_movegen.nim IS_TEST=1 EXE_BASE=bin/test-movegen \
##   EVALFILE="$PWD/threans.bin"
import std/[random, strformat, strutils]
import heimdall/[board, movegen, moves]
import heimdall/util/scharnagl

var
    rng = initRand(0xA0D172)
    positionsChecked = 0
    transitionsChecked = 0
    flags: set[MoveFlag]


proc verifyPosition(board: Chessboard) =
    # Reconstruct every board representation and hash independently of doMove.
    let actual = board.position
    let expected = fromFEN(actual.toFEN(chess960=true))
    doAssert actual.mailbox == expected.mailbox
    doAssert actual.pieces == expected.pieces
    doAssert actual.colors == expected.colors
    doAssert actual.zobristKey == expected.zobristKey
    doAssert actual.pawnKey == expected.pawnKey
    doAssert actual.nonpawnKeys == expected.nonpawnKeys
    doAssert actual.majorKey == expected.majorKey
    doAssert actual.minorKey == expected.minorKey
    doAssert actual.checkers == expected.checkers
    doAssert actual.diagonalPins == expected.diagonalPins
    doAssert actual.orthogonalPins == expected.orthogonalPins
    doAssert actual.castlingAvailability == expected.castlingAvailability
    doAssert actual.enPassantSquare == expected.enPassantSquare


proc verifyMoves(board: Chessboard): MoveList =
    let before = board.position.clone()
    result = newMoveList()
    var captures = newMoveList()
    board.generateMoves(result)
    board.generateMoves(captures, capturesOnly=true)
    doAssert board.position == before, "move generation changed the position"
    var index = 0
    for move in result:
        if move.isCapture():
            doAssert index < captures.len(), &"missing capture {move}: {board.toFEN()}"
            doAssert captures[index] == move, &"capture order changed: {board.toFEN()}"
            inc(index)
    doAssert index == captures.len(), &"non-capture in capture-only list: {board.toFEN()}"
    inc(positionsChecked)


proc verifyTransition(board: Chessboard, move: Move) =
    let before = board.position.clone()
    flags.incl(move.flag())
    board.doMove(move)
    verifyPosition(board)
    discard verifyMoves(board)
    board.unmakeMove()
    doAssert board.position == before, "make/unmake changed the parent"
    inc(transitionsChecked)


block capturesExcludeCastling:
    let board = newChessboardFromFEN(
        "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"
    )
    var moves {.noinit.} = newMoveList()
    board.generateMoves(moves, capturesOnly = true)
    doAssert moves.len() == 2
    for move in moves:
        doAssert move.isCapture()


# All standard, Chess960, and en-passant edge cases in the reference corpus.
# Check every root move, then use deterministic walks to vary stack depth and
# exercise state restoration, null moves, and cloning away from the root.
const positions = staticRead("all.txt").splitLines()
for index, fen in positions:
    if fen.strip().len == 0:
        continue
    let board = newChessboardFromFEN(fen)
    verifyPosition(board)
    let legal = verifyMoves(board)
    for move in legal:
        verifyTransition(board, move)
    if index mod 12 != 0:
        continue
    var parents: seq[Position]
    for ply in 0..<96:
        let moves = verifyMoves(board)
        if moves.len() == 0:
            break
        if ply mod 11 == 0 and board.canNullMove():
            let before = board.position.clone()
            board.makeNullMove()
            verifyPosition(board)
            discard verifyMoves(board)
            board.unmakeMove()
            doAssert board.position == before
        let move = moves[rng.rand(moves.high())]
        parents.add(board.position.clone())
        flags.incl(move.flag())
        board.doMove(move)
        verifyPosition(board)
        inc(transitionsChecked)
    let copied = newChessboard(board.positions)
    for parent in countdown(parents.high(), 0):
        board.unmakeMove()
        copied.unmakeMove()
        doAssert board.position == parents[parent]
        doAssert copied.position == parents[parent]

block chess960Castling:
    var stationaryKing, stationaryRook, swapKingRook: bool
    for arrangement in 0..<960:
        for side in White..Black:
            var position = fromFEN(scharnaglToFEN(arrangement))
            # Clear the castling paths and remove enemy rooks, which would
            # otherwise check some of the exposed kings down the open files.
            for square in position.pieces():
                let piece = position.on(square)
                if piece.kind != King and (piece.kind != Rook or piece.color != side):
                    position.remove(square)
            position.revokeCastling(side.opposite())
            position.sideToMove = side
            position.hash()
            position.updateChecksAndPins()
            let board = newChessboard(@[position])
            let legal = verifyMoves(board)
            for move in legal:
                if not move.isCastling():
                    continue
                let king = createPiece(kind=King, color=side)
                let rook = createPiece(kind=Rook, color=side)
                let kingTarget = if move.flag() == ShortCastling: king.shortCastling() else: king.longCastling()
                let rookTarget = if move.flag() == ShortCastling: rook.shortCastling() else: rook.longCastling()
                stationaryKing = stationaryKing or kingTarget == move.startSquare
                stationaryRook = stationaryRook or rookTarget == move.targetSquare
                swapKingRook = swapKingRook or (kingTarget == move.targetSquare and rookTarget == move.startSquare)
                verifyTransition(board, move)
                board.doMove(move)
                doAssert board.on(kingTarget) == king
                doAssert board.on(rookTarget) == rook
                board.unmakeMove()
    doAssert stationaryKing and stationaryRook and swapKingRook

for flag in [Normal, DoublePush, Capture, EnPassant, ShortCastling, LongCastling,
             PromotionKnight, PromotionBishop, PromotionRook, PromotionQueen,
             CapturePromotionKnight, CapturePromotionBishop,
             CapturePromotionRook, CapturePromotionQueen]:
    doAssert flag in flags, &"test did not exercise {flag}"
echo &"Move generation: {positionsChecked} capture-list checks; {transitionsChecked} state/hash transitions"
