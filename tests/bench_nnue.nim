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

## Isolate forward inference from board updates and search. Including eval makes
## its private accumulator layout available to this diagnostic program only.
## Build with make dev MAIN=tests/bench_nnue.nim EXE_BASE=bin/bench-nnue
## and an absolute EVALFILE path. Optional argument: repetitions (default 10000).
include heimdall/eval
import std/[os, strutils, times, strformat]
import heimdall/movegen

const SAMPLE_COUNT = 128
var
    samplerOwner = newEvalState(verbose=false)
    runnerOwner = samplerOwner.raw.clone(newDefaultChessboard())
    colors: array[SAMPLE_COUNT, PieceColor]
    buckets: array[SAMPLE_COUNT, int]
    samples = 0
    checksum = 0'i64
let
    sampler = samplerOwner.raw
    runner = runnerOwner.raw
    repetitions = if paramCount() > 0: paramStr(1).parseInt() else: 10000
    fens = readFile("src/heimdall/resources/misc/bench.txt").splitLines()
doAssert repetitions > 0

for fen in fens:
    if fen.len == 0 or samples == SAMPLE_COUNT:
        continue
    let board = newChessboardFromFEN(fen)
    sampler.init(board)
    for ply in 0..<4:
        discard board.evaluate(sampler)
        for side in White..Black:
            runner.accumulators[side][samples] = sampler.accumulators[side][sampler.current]
        colors[samples] = board.sideToMove
        buckets[samples] = (board.pieces().count() - 2) div (32 div NUM_OUTPUT_BUCKETS)
        inc(samples)
        if samples == SAMPLE_COUNT:
            break
        var legal = newMoveList()
        board.generateMoves(legal)
        if legal.len() == 0:
            break
        let move = legal[(samples * 17) mod legal.len()]
        sampler.update(move, board.sideToMove, board.on(move.startSquare).kind,
                       board.on(move.captureSquare()).kind,
                       board.position.kingSquare(board.sideToMove))
        board.doMove(move)
doAssert samples == SAMPLE_COUNT

let start = cpuTime()
for repetition in 0..<repetitions:
    for i in 0..<samples:
        runner.current = i
        when defined(simd):
            checksum += runner.forwardFast(colors[i], buckets[i]).int64
        else:
            checksum += runner.forwardScalar(colors[i], buckets[i]).int64
let elapsed = cpuTime() - start
echo &"NNUE forward: {samples * repetitions} calls, {elapsed:.6f} seconds, checksum {checksum}"
