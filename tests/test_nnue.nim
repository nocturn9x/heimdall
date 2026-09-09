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

## Exercise incremental and delayed NNUE updates against a full refresh.
## Build using make dev MAIN=tests/test_nnue.nim EXE_BASE=bin/test-nnue
## with EVALFILE set to the absolute path of the desired network.
import std/[random, strformat]
import heimdall/[board, eval, movegen, moves, nnue, pieces, position]
import heimdall/util/scharnagl
from heimdall/util/shared import MAX_DEPTH


var
    rng = initRand(0x51A7)
    comparisons = 0
    checksum = 0'i64
    flags: set[MoveFlag]
    incrementalOwner = newEvalState(verbose=false)
    freshOwner = incrementalOwner.raw.clone(newDefaultChessboard())
let
    incremental = incrementalOwner.raw
    fresh = freshOwner.raw


proc verify(board: Chessboard, state: EvalState = incremental) =
    let actual = board.evaluate(state)
    fresh.init(board)
    let expected = board.evaluate(fresh)
    doAssert actual == expected,
        &"incremental {actual} != refreshed {expected}: {board.toFEN()}"
    inc(comparisons)
    checksum += actual.int64


proc push(board: Chessboard, move: Move) =
    flags.incl(move.flag())
    incremental.update(move, board.sideToMove, board.on(move.startSquare).kind,
                       board.on(move.captureSquare()).kind,
                       board.position.kingSquare(board.sideToMove))
    board.doMove(move)


proc visit(board: Chessboard, depth: int, root=false) =
    if depth == 0:
        verify(board)
        return
    var legal = newMoveList()
    board.generateMoves(legal)
    for i in 0..<min(legal.len(), if root: MAX_MOVES else: 3):
        let move = legal[if root: i else: rng.rand(legal.high())]
        push(board, move)
        # Leave runs of updates pending, then evaluate descendants and ancestors.
        if rng.rand(3) == 0:
            verify(board)
        visit(board, depth - 1)
        incremental.undo()
        board.unmakeMove()
        if rng.rand(2) == 0:
            verify(board)


let fens = @[
    startpos().toFEN(),
    "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1",
    "4k3/P7/8/8/8/8/7p/4K3 w - - 0 1",
    "1r2k3/P7/8/8/8/8/7p/4K3 w - - 0 1",
    "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1",
    "4k3/8/8/8/3Pp3/8/8/4K3 b - d3 0 1",
    "4k3/8/8/8/8/8/8/RK1R4 w AD - 0 1",
    scharnaglToFEN(0, 959),
    scharnaglToFEN(959, 0)
]

for fen in fens:
    let board = newChessboardFromFEN(fen)
    incremental.init(board)
    verify(board)
    visit(board, 4, root=true)
    verify(board)

    var played = 0
    for ply in 0..<120:
        var legal = newMoveList()
        board.generateMoves(legal)
        if legal.len() == 0:
            break
        push(board, legal[rng.rand(legal.high())])
        inc(played)
        if ply mod 7 == 0:
            verify(board)
        if ply mod 11 == 0 and board.canNullMove():
            board.makeNullMove()
            verify(board)
            board.unmakeMove()
            verify(board)
    verify(board)
    for ply in 0..<played:
        incremental.undo()
        board.unmakeMove()
        if ply mod 3 == 0:
            verify(board)
    verify(board)

# Clone a state with both evaluated ancestors and pending descendants. Undo in
# the clone must preserve its history and leave the source usable independently.
block:
    let board = newDefaultChessboard()
    incremental.init(board)
    for ply in 0..<8:
        var legal = newMoveList()
        board.generateMoves(legal)
        push(board, legal[(ply * 7) mod legal.len()])
        if ply == 3:
            verify(board)
    let copiedBoard = newChessboard(board.positions)
    var copiedOwner = incremental.clone(copiedBoard)
    for ply in 0..<8:
        verify(copiedBoard, copiedOwner.raw)
        copiedOwner.raw.undo()
        copiedBoard.unmakeMove()
    verify(copiedBoard, copiedOwner.raw)
    # Reuse the same allocation for a deeper state with pending updates, then
    # exercise its ancestors again. Also allow rebinding a state to itself.
    let reboundBoard = newChessboard(board.positions)
    copiedOwner.raw.copyFrom(incremental, reboundBoard)
    copiedOwner.raw.copyFrom(copiedOwner.raw, reboundBoard)
    for ply in 0..<8:
        verify(reboundBoard, copiedOwner.raw)
        copiedOwner.raw.undo()
        reboundBoard.unmakeMove()
    verify(reboundBoard, copiedOwner.raw)
    verify(board)

# Search can evaluate at ply 255, so its root plus all descendants must fit.
# Legal knight cycles make the boundary deterministic without exhausting moves.
for eager in [false, true]:
    let board = newDefaultChessboard()
    incremental.init(board)
    verify(board)
    let cycle = ["g1f3", "g8f6", "f3g1", "f6g8"]
    for ply in 0..<MAX_DEPTH:
        var legal = newMoveList()
        board.generateMoves(legal)
        var selected = nullMove()
        for move in legal:
            if move.toUCI() == cycle[ply mod cycle.len]:
                selected = move
                break
        doAssert selected != nullMove()
        push(board, selected)
        if eager:
            verify(board)
    verify(board)
    for ply in 0..<MAX_DEPTH:
        incremental.undo()
        board.unmakeMove()
        if eager or ply mod 17 == 0:
            verify(board)
    verify(board)

# Exercise the paired-update and refresh paths for every Chess960 castling
# arrangement, including a stationary king/rook and a king/rook swap.
block chess960Castling:
    var stationaryKing, stationaryRook, swapKingRook: bool
    for arrangement in 0..<960:
        for side in White..Black:
            var position = fromFEN(scharnaglToFEN(arrangement))
            for square in position.pieces():
                let piece = position.on(square)
                if piece.kind != King and (piece.kind != Rook or piece.color != side):
                    position.remove(square)
            position.revokeCastling(side.opposite())
            position.sideToMove = side
            position.hash()
            position.updateChecksAndPins()
            let board = newChessboard(@[position])
            incremental.init(board)
            verify(board)
            var legal = newMoveList()
            board.generateMoves(legal)
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
                push(board, move)
                verify(board)
                incremental.undo()
                board.unmakeMove()
                verify(board)
    doAssert stationaryKing and stationaryRook and swapKingRook

for flag in [Normal, DoublePush, Capture, EnPassant, ShortCastling, LongCastling,
             PromotionKnight, PromotionBishop, PromotionRook, PromotionQueen,
             CapturePromotionKnight, CapturePromotionBishop,
             CapturePromotionRook, CapturePromotionQueen]:
    doAssert flag in flags, &"test did not exercise {flag}"
when defined(simd):
    echo "NNUE backend: SIMD"
else:
    echo "NNUE backend: scalar"
echo &"NNUE: {comparisons} incremental/full-refresh comparisons; checksum {checksum}"
