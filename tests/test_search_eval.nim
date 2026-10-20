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

## Optional search evaluations and packed TT/search-stack layout.
## Build through make dev MAIN=tests/test_search_eval.nim IS_TEST=1.
import std/[os, osproc]
include heimdall/search

# A subprocess verifies get() rejects absence even with --panics:on.
if paramCount() == 1 and paramStr(1) == "unwrap-none":
    discard noEval().get()
    quit(0)
let missing = execCmdEx(quoteShell(getAppFilename()) & " unwrap-none")
doAssert missing.exitCode != 0
doAssert "Can't obtain a value from noEval()" in missing.output

# Guard both layouts against adding a presence flag or widening the packed eval.
type
    PreviousTTEntry = object
        bestMove: Move
        rawEval: int16
        hash: TruncatedZobristKey
        score: int16
        flag: TTFlag
        depth: uint8
    PreviousStackEntry = object
        staticEval: Score
        move: Move
        piece: Piece
        inCheck: bool
        reduction: int

static:
    doAssert sizeof(OptionalEval) == sizeof(int16)
    doAssert sizeof(TTEntry) == sizeof(PreviousTTEntry)
    doAssert alignof(TTEntry) == alignof(PreviousTTEntry)
    doAssert sizeof(SearchStackEntry) == sizeof(PreviousStackEntry)
    doAssert alignof(SearchStackEntry) == alignof(PreviousStackEntry)
    doAssert not compiles(noEval() + Score(1))
    doAssert not compiles(-noEval())
    doAssert not compiles(noEval() < someEval(0))
    doAssert noEval().isNone()
    doAssert not noEval().isSome()
    # Zero-filled tables and stack frames retain their historical zero eval.
    doAssert default(OptionalEval).isSome()
    doAssert default(OptionalEval).get() == 0

var manager: SearchManager
# Absence must propagate without accessing the correction-history tables.
doAssert manager.staticEval(noEval(), 0).isNone()

let
    table = newTranspositionTable(1024)
    key = ZobristKey(0x1234_5678_9abc_def0'u64)
    move = createMove("e2", "e4", DoublePush)
for bound in TTBound:
    table.store(7, mateIn(3), key, move, bound, noEval(), true)
    let entry = table.get(key).get()
    doAssert entry.rawEval.isNone()
    doAssert entry.bestMove == move
    doAssert entry.depth == 7
    doAssert entry.flag.bound() == bound
    doAssert entry.flag.wasPV()
    doAssert entry.score == mateIn(3)

# Cover every legal static evaluation, including zero and both extremes.
for score in lowestEval()..highestEval():
    let optional = someEval(score)
    doAssert optional.isSome()
    doAssert not optional.isNone()
    doAssert optional.get() == score
    table.store(1, 0, key, nullMove(), NoBound, optional, false)
    doAssert table.get(key).get().rawEval.get() == score

echo "Optional eval: all values and absence round-trip; TT and stack layouts unchanged"
