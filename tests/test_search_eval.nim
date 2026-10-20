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

## Optional search evaluations, in-check search, and packed TT/stack layout.
## Build through make dev MAIN=tests/test_search_eval.nim IS_TEST=1.
import std/[os, osproc]
include heimdall/search

# A subprocess verifies get() rejects absence even with --panics:on.
if paramCount() == 1 and paramStr(1) == "unwrap-none":
    discard noEval().get()
    quit(0)
if paramCount() == 1 and paramStr(1) == "evaluate-in-check":
    var searcher: SearchManager
    searcher.board = newChessboardFromFEN("7k/6Q1/6K1/8/8/8/8/8 b - - 0 1")
    discard searcher.rawEval()
    quit(0)
let missing = execCmdEx(quoteShell(getAppFilename()) & " unwrap-none")
doAssert missing.exitCode != 0
doAssert "Can't obtain a value from noEval()" in missing.output
let checked = execCmdEx(quoteShell(getAppFilename()) & " evaluate-in-check")
doAssert checked.exitCode != 0
doAssert "Static evaluation is unavailable in check" in checked.output

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

proc searcherForFen(fen: string, loadNetwork = true): SearchManager =
    let table = newTranspositionTable(1024 * 1024)
    result = newSearchManager(@[], table, mainWorker=false,
                              evalState=if loadNetwork: newEvalState() else: EvalStateOwner())
    result.board.positions = @[fromFEN(fen)]
    result.statistics.currentVariation.store(1, moRelaxed)
    if loadNetwork:
        result.evalState.init(result.board)

# Mate and the hard ply boundary must not evaluate: no NNUE state is allocated.
block:
    var searcher = searcherForFen("7k/6Q1/6K1/8/8/8/8/8 b - - 0 1", false)
    doAssert searcher.board.inCheck()
    doAssert searcher.qsearch(false, 0, -SCORE_INF, SCORE_INF, true) == matedIn(0)
    doAssert searcher.search(1, 0, -SCORE_INF, SCORE_INF, true, true, false) == matedIn(0)
    doAssert searcher.stack[0].staticEval.isNone()
    doAssert searcher.qsearch(false, MAX_DEPTH, -SCORE_INF, SCORE_INF, false) == 0
    doAssert searcher.search(1, MAX_DEPTH, -SCORE_INF, SCORE_INF, true, false, false) == 0

# All four escapes from a rook check are quiet. Stand pat and capture-only move
# generation would miss every one of them. Ignore legacy cached evals in check.
for cached in [noEval(), someEval(highestEval())]:
    var searcher = searcherForFen("4r2k/8/8/8/8/8/8/4K3 w - - 0 1")
    let key = searcher.board.zobristKey
    searcher.ttable.store(0, 0, key, nullMove(), NoBound, cached, false)
    var legal = newMoveList()
    searcher.board.generateMoves(legal)
    doAssert legal.len == 4
    for move in legal:
        doAssert move.isQuiet()
    let score = searcher.qsearch(true, 0, -SCORE_INF, SCORE_INF, true)
    doAssert not score.isMateScore()
    doAssert searcher.statistics.nodeCount.load(moRelaxed) >= legal.len.uint64
    doAssert searcher.statistics.bestMove.load(moRelaxed) in legal
    doAssert searcher.stack[0].staticEval.isNone()
    doAssert searcher.ttable.get(key).get().rawEval.isNone()
    doAssert searcher.board.zobristKey == key

# A losing capture can still be a legal check evasion and must be searched.
block:
    var searcher = searcherForFen("3Qrk2/8/8/8/8/8/8/4K3 w - - 0 1")
    let evasion = createMove("d8", "e8", Capture)
    var legal = newMoveList()
    searcher.board.generateMoves(legal)
    doAssert evasion in legal
    doAssert not searcher.parameters.see(searcher.board.position, evasion, 0, SeePruning)
    searcher.board.doMove(evasion)
    let childKey = searcher.board.zobristKey
    searcher.board.unmakeMove()
    discard searcher.qsearch(false, 0, -SCORE_INF, SCORE_INF, true)
    let child = searcher.ttable.get(childKey)
    doAssert child.isSome()
    doAssert child.get().rawEval.isNone()

# Main search stores no eval for checked positions. A missing cached eval in a
# non-checked position must instead be recomputed before heuristics unwrap it.
for fen in ["4r2k/8/8/8/8/8/8/4K3 w - - 0 1", "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"]:
    var searcher = searcherForFen(fen)
    let
        key = searcher.board.zobristKey
        checked = searcher.board.inCheck()
    searcher.ttable.store(0, 0, key, nullMove(), NoBound, noEval(), false)
    discard searcher.search(2, 0, -SCORE_INF, SCORE_INF, true, true, false)
    doAssert searcher.stack[0].staticEval.isNone() == checked
    doAssert searcher.ttable.get(key).get().rawEval.isNone() == checked
    doAssert searcher.board.zobristKey == key

# Exercise non-PV extension and futility decisions at a checked child of LMR.
block:
    var searcher = searcherForFen("4r2k/8/8/8/8/8/8/4K3 w - - 0 1")
    searcher.stack[0].reduction = 1
    searcher.stack[0].staticEval = someEval(100)
    searcher.stack[0].move = createMove("a8", "e8", Normal)
    searcher.stack[0].piece = createPiece(Rook, Black)
    discard searcher.search(2, 1, 0, 1, false, false, true)
    doAssert searcher.stack[1].staticEval.isNone()

echo "In-check eval: mate, quiet and losing evasions, TT absence, and ply boundary passed"
