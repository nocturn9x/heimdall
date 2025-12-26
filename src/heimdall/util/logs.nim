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

## Logging utilities

import heimdall/[eval, moves, board, transpositions]
import heimdall/util/[wdl, shared]


import std/[times, options, atomics, terminal, strutils, strformat, monotimes, macros]

type
    SearchLogger* = object
        enabled: bool
        color: bool
        state: SearchState
        stats: SearchStatistics
        board: Chessboard
        ttable: ptr TranspositionTable

    SearchDuration = tuple[msec, seconds, minutes, hours, days: int64]


func setColor*(self: var SearchLogger, value: bool) = self.color = value

func msToDuration*(x: int64): SearchDuration =
    result.msec = x
    var x = x div 1000
    result.seconds = x mod 60
    x = x div 60
    result.minutes = x mod 60
    x = x div 60
    result.hours = x mod 24
    x = x div 24
    result.days = x


func `$`*(self: SearchDuration): string =
    if self.msec < 1000:
        return &"{self.msec} ms"

    if self.days > 0:
        result &= &"{self.days}d "
    if self.hours > 0:
        result &= &"{self.hours}h "
    if self.minutes > 0:
        result &= &"{self.minutes}m "

    let frac = float(self.msec mod 1000) / 1000.0
    let s = float(self.seconds) + frac
    result &= &"{s:.2f}s"


func createSearchLogger*(state: SearchState, stats: SearchStatistics, board: Chessboard, ttable: ptr TranspositionTable): SearchLogger =
    return SearchLogger(state: state, stats: stats, board: board, ttable: ttable, enabled: true)


func enable*(self: var SearchLogger) =
    self.enabled = true

func disable*(self: var SearchLogger) =
    self.enabled = false


proc elapsedTime*(self: SearchState): int64 {.inline.} = (getMonoTime() - self.searchStart.load(moRelaxed)).inMilliseconds()


macro styledWrite*(f: syncio.File, useColor: bool, args: varargs[typed]): untyped =
    # Credit goes to @litlighilit in the Nim discord for this beauty
    let simpWrites = newStmtList()
    let styled = newCall(bindSym"styledWrite", f)
    for i in args:
        styled.add i
        if i.typeKind in {ntyString,
            ntyInt..ntyInt64, ntyUInt, ntyUint64,
            ntyFloat, ntyFloat64, #[more to add...]#}:
            simpWrites.add quote do:
                `f`.write(`i`)
    result = quote do:
        if `useColor`:
            `styled`
        else:
            `simpWrites`


proc logPretty(self: SearchLogger, depth, selDepth, variation: int, nodeCount, nps: uint64, elapsedMsec: int64,
               chess960: bool, line: array[MAX_DEPTH + 1, Move], bestRootScore: Score, wdl: tuple[win, draw, loss: int],
               material, hashfull: int) =
    # Thanks to @tsoj for the patch!

    let kiloNps = nps div 1_000

    stdout.styledWrite self.color, styleBright, fmt"{depth:>3}/{selDepth:<3} "
    stdout.styledWrite self.color, styleDim, fmt"{msToDuration(elapsedMsec):>6} "
    stdout.styledWrite self.color, styleDim, styleBright, fmt"{nodeCount:>6}"
    stdout.styledWrite self.color, styleDim, " nodes "
    stdout.styledWrite self.color, styleDim, styleBright, fmt"{kiloNps:>7}"
    stdout.styledWrite self.color, styleDim, " knps "
    stdout.styledWrite self.color, styleBright, fgGreen, fmt"  W: ", styleDim, fmt"{wdl.win / 10:>5.1f}% ",
                       resetStyle, styleBright, fgDefault, "D: ", styleDim, fmt"{wdl.draw / 10:>5.1f}% ",
                       resetStyle, styleBright, fgRed, "L: ", styleDim, fmt"{wdl.loss / 10:>5.1f}%  "
    stdout.styledWrite self.color, styleBright, fgBlue, "  TT: ", styleDim, fgDefault, fmt"{hashfull div 10:>3}%"


    stdout.styledWrite self.color, styleDim, "   variation "
    stdout.styledWrite self.color, styleDim, styleBright, fgYellow, fmt"{variation} "

    var printedScore = bestRootScore
    if self.state.normalizeScore.load(moRelaxed):
        printedScore = normalizeScore(bestRootScore, material)

    let
        color =
            if printedScore.abs <= 10:
                fgDefault
            elif printedScore > 0:
                fgGreen
            else:
                fgRed
        style: set[Style] =
            if printedScore.abs >= 100:
                {styleBright}
            elif printedScore.abs <= 20:
                {styleDim}
            else:
                {}

    if bestRootScore.isMateScore():
        let
          extra = if bestRootScore > 0: ":D" else: ":("
          mateScore = if bestRootScore > 0: (mateScore() - bestRootScore + 1) div 2 else: (mateScore() + bestRootScore) div 2
        stdout.styledWrite self.color, styleBright,
            color, fmt"  #{mateScore} ", resetStyle, color, styleDim, extra, " "
    else:
        let scoreString = (if printedScore > 0: "+" else: "") & fmt"{printedScore.float / 100.0:.2f}"
        stdout.styledWrite self.color, style, color, fmt"{scoreString:>7} "


    const moveColors = [fgBlue, fgCyan, fgGreen, fgYellow, fgRed, fgMagenta, fgRed, fgYellow, fgGreen, fgCyan]

    for i, move in line:

        if move == nullMove():
            break

        var move = move
        if move.isCastling() and not chess960:
            # Hide the fact we're using FRC internally
            if move.isLongCastling():
                move.targetSquare = makeSquare(rank(move.targetSquare), file(move.targetSquare) + pieces.File(2))
            else:
                move.targetSquare = makeSquare(rank(move.targetSquare), file(move.targetSquare) - pieces.File(1))

        if i == 0:
            stdout.styledWrite self.color, " ", moveColors[i mod moveColors.len], styleBright, styleItalic, move.toUCI()
        else:
            stdout.styledWrite self.color, " ", moveColors[i mod moveColors.len], move.toUCI()

    echo ""


proc logUCI(self: SearchLogger, depth, selDepth, variation: int, nodeCount, nps: uint64, elapsedMsec: int64,
            chess960: bool, line: array[MAX_DEPTH + 1, Move], bestRootScore: Score, wdl: tuple[win, draw, loss: int],
            material, hashfull: int)  =
    # Using a shared atomic for such frequently updated counters kills
    # performance and cripples nps scaling, so instead we let each thread
    # have its own local counters and then aggregate the results here

    var logMsg = &"info depth {depth} seldepth {selDepth} multipv {variation}"
    if bestRootScore.isMateScore():
        if bestRootScore > 0:
            logMsg &= &" score mate {((mateScore() - bestRootScore + 1) div 2)}"
        else:
            logMsg &= &" score mate {(-(mateScore() + bestRootScore) div 2)}"
    else:
        var printedScore = bestRootScore
        if self.state.normalizeScore.load(moRelaxed):
            printedScore = normalizeScore(bestRootScore, material)
        logMsg &= &" score cp {printedScore}"

    if self.state.showWDL.load(moRelaxed):
        let wdl = getExpectedWDL(bestRootScore, material)
        logMsg &= &" wdl {wdl.win} {wdl.draw} {wdl.loss}"

    logMsg &= &" hashfull {hashfull} time {elapsedMsec} nodes {nodeCount} nps {nps}"
    let chess960 = self.state.chess960.load(moRelaxed)
    if line[0] != nullMove():
        logMsg &= " pv "
        for move in line:
            if move == nullMove():
                break
            if move.isCastling() and not chess960:
                # Hide the fact we're using FRC internally
                var move = move
                if move.isLongCastling():
                    move.targetSquare = makeSquare(rank(move.targetSquare), file(move.targetSquare) + pieces.File(2))
                else:
                    move.targetSquare = makeSquare(rank(move.targetSquare), file(move.targetSquare) - pieces.File(1))
                logMsg &= &"{move.toUCI()} "
            else:
                logMsg &= &"{move.toUCI()} "
    if logMsg.endsWith(" "):
        # Remove extra space at the end of the pv
        logMsg = logMsg[0..^2]
    echo logMsg


proc log*(self: SearchLogger, line: array[MAX_DEPTH + 1, Move], variation: int, bestRootScore: Option[Score] = none(Score), stats: Option[SearchStatistics] = none(SearchStatistics)) =
    if not self.state.isMainThread.load(moRelaxed) or not self.enabled:
        return
    # Using a shared atomic for such frequently updated counters kills
    # performance and cripples nps scaling, so instead we let each thread
    # have its own local counters and then aggregate the results here
    let stats = if stats.isNone(): self.stats else: stats.get()
    var
        # We always use self.stats for loading the node
        # count and selective depth, since if stats is
        # provided and is not the main thread's, we'd count
        # a worker's nodes/seldepth twice while missing those
        # of the main thread
        nodeCount = self.stats.nodeCount.load(moRelaxed)
        selDepth = self.stats.selectiveDepth.load(moRelaxed)
    for child in self.state.childrenStats:
        nodeCount += child.nodeCount.load(moRelaxed)
        selDepth = max(selDepth, child.selectiveDepth.load(moRelaxed))

    let
        depth = stats.highestDepth.load(moRelaxed)
        elapsedMsec = self.state.elapsedTime()
        nps = 1000 * (nodeCount div max(elapsedMsec, 1).uint64)
        chess960 = self.state.chess960.load(moRelaxed)
        # We allow the searcher to pass in a different best root score because
        # in some cases (e.g. when a search is interrupted or when logging multiple
        # variations), we don't want to use the value in self.stats
        bestRootScore = if bestRootScore.isNone(): stats.bestRootScore.load(moRelaxed) else: bestRootScore.get()
        material = self.board.material()
        wdl = getExpectedWDL(bestRootScore, material)
        hashfull = self.ttable[].getFillEstimate()

    if self.state.uciMode.load(moRelaxed):
        self.logUCI(depth, selDepth, variation, nodeCount, nps, elapsedMsec, chess960, line, bestRootScore, wdl, material, hashfull)
    else:
        self.logPretty(depth, selDepth, variation, nodeCount, nps, elapsedMsec, chess960, line, bestRootScore, wdl, material, hashfull)
