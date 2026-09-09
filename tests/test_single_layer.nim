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

## Single-layer file IO, PSQ/TI checkpoints, SCReLU output, and TI state ownership.
## Build with make dev SINGLE_LAYER=1 MAIN=tests/test_single_layer.nim IS_TEST=1
## EXE_BASE=bin/test-single-layer EVALFILE="$PWD/threans.bin".
## threans is a debugging fixture and must not be used for releases.
include heimdall/eval
import heimdall/movegen
import std/[os, tempfiles]

static:
    doAssert L1_SIZE == 32 and NUM_INPUT_BUCKETS == 1 and NUM_OUTPUT_BUCKETS == 1
    doAssert QA == 255 and QB == 64 and EVAL_SCALE == 400
    doAssert not MERGED_KINGS and MIRRORED

const
    START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    KIWI_FEN = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
    # First 16 lanes come from the supplied debugging data. Remaining lanes
    # were independently calculated from the published indices and threans.bin
    # (SHA256 050be5d715a5d9569a422ed3c02430cde7fef429388a86bbb224b01435fbdba5).
    START_PSQ: array[32, int16] = [
        211, 170, 101, 121, 104, 111, -15, 206,
        -8, 355, 176, 401, 148, -500, 105, 26,
        -867, 19, 221, 13, 18, -81, 440, 437,
        542, -241, -823, 768, 136, 399, -2090, -39
    ]
    KIWI_WHITE_PSQ: array[32, int16] = [
        169, 174, 91, 97, 100, 33, 122, 197,
        -43, 588, 69, 463, 199, -403, 199, 19,
        -589, 103, 136, 41, 172, 61, 537, 456,
        650, -230, -563, 871, 47, 724, -1877, 47
    ]
    KIWI_BLACK_PSQ: array[32, int16] = [
        191, 210, 35, 118, 120, 87, 204, 194,
        59, 544, 98, 453, 218, -282, 126, 0,
        -570, 195, 174, -17, 137, 84, 606, 381,
        534, -232, -534, 813, 99, 280, -1936, -32
    ]
    START_COMBINED: array[32, int16] = [
        97, 59, 28, 9, -23, 97, -162, 184,
        -48, 212, 178, 323, 111, -733, -4, 106,
        -1183, 0, 196, -68, -12, -43, 195, 427,
        315, -234, -922, 1016, 67, 408, -2520, -128
    ]
    KIWI_WHITE_COMBINED: array[32, int16] = [
        167, 90, 8, 77, 65, 90, 33, 162,
        -19, 383, 112, 282, 36, -377, 15, 106,
        -526, 117, 101, -38, 62, 8, 354, 251,
        435, -308, -543, 826, 18, 458, -2288, -190
    ]
    KIWI_BLACK_COMBINED: array[32, int16] = [
        45, 81, 51, 11, -6, 17, 28, 123,
        -37, 388, 116, 267, 155, -373, -44, 152,
        -515, 159, 231, -2, 44, 87, 394, 302,
        276, -246, -420, 826, 40, 279, -2247, -158
    ]

var owner = newEvalState(verbose=false)
let state = owner.raw

doAssert network.ft.bias.toOpenArray(0, 15) == [
    -20'i16, -2, 18, 17, 10, 7, -30, -20, -39, -42, -14, 35, 12, -14, -18, 29]
doAssert network.output.bias[0] == -248
# Signed i8 rows lie between the PSQ rows and the biases on disk.
doAssert network.threatWeights[506].toOpenArray(0, 7) == [0'i8, 0, -5, 2, -3, -4, -6, 2]
for side in White..Black:
    for square in Square.all():
        doAssert kingBucket(side, square) == 0

proc checkRebuilt(position: Position) =
    var rebuiltOwner = state.clone(state.board)
    let rebuilt = rebuiltOwner.raw
    for side in White..Black:
        rebuilt.refreshThreats(side, position)
        doAssert state.threatAccumulators[side][state.current].data == rebuilt.threatAccumulators[side][rebuilt.current].data

for entry in [(START_FEN, START_PSQ, START_PSQ, START_COMBINED, START_COMBINED, 98'i32),
              (KIWI_FEN, KIWI_WHITE_PSQ, KIWI_BLACK_PSQ, KIWI_WHITE_COMBINED, KIWI_BLACK_COMBINED, -205'i32)]:
    let board = newChessboardFromFEN(entry[0])
    state.init(board)
    checkRebuilt(board.position)
    doAssert board.evaluate(state) == entry[5]
    for side in White..Black:
        let psq = if side == White: entry[1] else: entry[2]
        let combined = if side == White: entry[3] else: entry[4]
        doAssert state.accumulators[side][state.current].data == psq
        for i in 0..<L1_SIZE:
            doAssert state.threatAccumulators[side][state.current].data[i] == combined[i] - psq[i]
    doAssert state.forwardScalar(White, 0) == entry[5]
    doAssert board.evaluate(state) == entry[5]

    # A saved pair of PSQ/TI accumulators must suffice for forward inference,
    # even when the attached board has entirely different threat features.
    let unrelated = newChessboardFromFEN("4k3/8/8/8/8/8/8/4K3 w - - 0 1")
    var detachedOwner = state.clone(unrelated)
    let detached = detachedOwner.raw
    let whiteThreats = detached.threatAccumulators[White][detached.current]
    let blackThreats = detached.threatAccumulators[Black][detached.current]
    doAssert detached.forwardScalar(White, 0) == entry[5]
    when defined(simd):
        doAssert detached.forwardFast(White, 0) == entry[5]
    doAssert detached.threatAccumulators[White][detached.current] == whiteThreats
    doAssert detached.threatAccumulators[Black][detached.current] == blackThreats

block emptyThreats:
    let board = newChessboardFromFEN("4k3/8/8/8/8/8/8/4K3 w - - 0 1")
    for side in White..Black:
        for value in state.threatAccumulators[side][0].data.mitems:
            value = 1234
    state.init(board)
    for side in White..Black:
        doAssert state.threatAccumulators[side][0].data == default(array[L1_SIZE, int16])
    discard board.evaluate(state)
    checkRebuilt(board.position)

proc push(board: Chessboard, uci: string) =
    var legal = newMoveList()
    board.generateMoves(legal)
    for move in legal:
        if move.toUCI() == uci:
            state.update(move, board.sideToMove, board.on(move.startSquare).kind,
                         board.on(move.captureSquare()).kind,
                         board.position.kingSquare(board.sideToMove))
            board.doMove(move)
            return
    doAssert false, "missing legal move " & uci

block bookkeeping:
    let board = newChessboardFromFEN(START_FEN)
    state.init(board)
    doAssert board.evaluate(state) == 98
    let rootWhite = state.threatAccumulators[White][0]
    let rootBlack = state.threatAccumulators[Black][0]
    push(board, "g1f3")
    doAssert state.pending == 1 and state.current == 0
    let clonedBoard = newChessboard(board.positions)
    var clonedOwner = state.clone(clonedBoard)
    let cloned = clonedOwner.raw
    doAssert cloned.threatAccumulators[White][0] == rootWhite
    doAssert cloned.threatAccumulators[Black][0] == rootBlack
    let childScore = clonedBoard.evaluate(cloned)
    let childWhite = cloned.threatAccumulators[White][1]
    let childBlack = cloned.threatAccumulators[Black][1]
    cloned.undo()
    clonedBoard.unmakeMove()
    doAssert cloned.threatAccumulators[White][cloned.current] == rootWhite
    doAssert cloned.threatAccumulators[Black][cloned.current] == rootBlack
    cloned.threatAccumulators[White][0].data[0] = 456
    doAssert state.threatAccumulators[White][0] == rootWhite

    doAssert board.evaluate(state) == childScore
    doAssert state.threatAccumulators[White][state.current] == childWhite
    doAssert state.threatAccumulators[Black][state.current] == childBlack
    state.threatAccumulators[Black][state.current].data[7] = 789
    state.undo()
    board.unmakeMove()
    doAssert state.threatAccumulators[White][state.current] == rootWhite
    doAssert state.threatAccumulators[Black][state.current] == rootBlack
    push(board, "e2e4")
    let branchScore = board.evaluate(state)

    # Reused descendant slots must match a fresh evaluation of the new branch.
    let reboundBoard = newChessboard(board.positions)
    cloned.init(reboundBoard)
    doAssert reboundBoard.evaluate(cloned) == branchScore
    for side in White..Black:
        doAssert state.threatAccumulators[side][state.current] == cloned.threatAccumulators[side][cloned.current]

    # copyFrom must also work when reusing a previously populated destination.
    cloned.copyFrom(state, reboundBoard)
    doAssert cloned.current == state.current
    for side in White..Black:
        doAssert cloned.threatAccumulators[side][cloned.current] == state.threatAccumulators[side][state.current]
    cloned.copyFrom(cloned, reboundBoard)
    cloned.undo()
    reboundBoard.unmakeMove()
    doAssert cloned.threatAccumulators[White][cloned.current] == rootWhite
    doAssert cloned.threatAccumulators[Black][cloned.current] == rootBlack

    state.init(board)
    checkRebuilt(board.position)
    push(board, "e7e5")
    state.undo()
    board.unmakeMove()
    doAssert state.current == 0 and state.pending == 0
    checkRebuilt(board.position)

block roundTrip:
    let (file, path) = createTempFile("heimdall-single-layer-", ".bin")
    file.close()
    defer: removeFile(path)
    network.dumpNet(path)
    let
        payloadSize = 768 * 32 * 2 + 60144 * 32 + 32 * 2 + 64 * 2 + 2
        original = readFile(DEFAULT_NET_PATH)
        dumped = readFile(path)
    doAssert original.len == payloadSize + 62
    doAssert dumped == original[0..<payloadSize]
    let restored = loadNet(path)
    doAssert restored.ft == network.ft
    doAssert restored.threatWeights == network.threatWeights
    doAssert restored.output == network.output

echo "Single-layer: loader, PSQ/TI checkpoints, saved-accumulator inference, and TI bookkeeping passed"
