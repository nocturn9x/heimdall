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

import heimdall/eval
import heimdall/moves
import heimdall/board
import heimdall/util/wdl
import heimdall/util/shared
import heimdall/transpositions


import std/times
import std/options
import std/atomics
import std/terminal
import std/strutils
import std/strformat
import std/monotimes


type

    SearchLogger* = object
        enabled: bool
        state: SearchState
        stats: SearchStatistics
        board: Chessboard
        ttable: ptr TTable


func createSearchLogger*(state: SearchState, stats: SearchStatistics, board: Chessboard, ttable: ptr TTable): SearchLogger =
    return SearchLogger(state: state, stats: stats, board: board, ttable: ttable, enabled: true)


func enable*(self: var SearchLogger) =
    self.enabled = true

func disable*(self: var SearchLogger) = 
    self.enabled = false


proc elapsedTime*(self: SearchState): int64 {.inline.} = (getMonoTime() - self.searchStart.load()).inMilliseconds()


proc logPretty(self: SearchLogger, depth, selDepth, variation: int, nodeCount, nps: uint64, elapsedMsec: int64,
               chess960: bool, line: array[MAX_DEPTH + 1, Move], bestRootScore: Score, wdl: tuple[win, draw, loss: int],
               material, hashfull: int) =
    # Thanks to @tsoj for the patch!
    
    let kiloNps = nps div 1_000

    stdout.styledWrite styleBright, fmt"{depth:>3}/{selDepth:<3} "
    stdout.styledWrite styleDim, fmt"{elapsedMsec:>6} ms "
    stdout.styledWrite styleDim, styleBright, fmt"{nodeCount:>10}"
    stdout.styledWrite styleDim, " nodes "
    stdout.styledWrite styleDim, styleBright, fmt"{kiloNps:>7}"
    stdout.styledWrite styleDim, " knps "
    stdout.styledWrite styleBright, fgGreen, fmt"  W: ", styleDim, fmt"{wdl.win / 10:>5.1f}% ",
                       resetStyle, styleBright, fgDefault, "D: ", styleDim, fmt"{wdl.draw / 10:>5.1f}% ",
                       resetStyle, styleBright, fgRed, "L: ", styleDim, fmt"{wdl.loss / 10:>5.1f}%  "
    stdout.styledWrite styleBright, fgBlue, "  TT: ", styleDim, fgDefault, fmt"{hashfull div 10:>3}%"


    stdout.styledWrite styleDim, "   variation "
    stdout.styledWrite styleDim, styleBright, fgYellow, fmt"{variation} "

    var printedScore = bestRootScore
    if self.state.normalizeScore.load():
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
        stdout.styledWrite styleBright,
            color, fmt"  #{mateScore} ", resetStyle, color, styleDim, extra, " "
    else:
        let scoreString = (if printedScore > 0: "+" else: "") & fmt"{printedScore.float / 100.0:.2f}"
        stdout.styledWrite style, color, fmt"{scoreString:>7} "


    const moveColors = [fgBlue, fgCyan, fgGreen, fgYellow, fgRed, fgMagenta, fgRed, fgYellow, fgGreen, fgCyan]

    for i, move in line:

        if move == nullMove():
            break

        var move = move
        if move.isCastling() and not chess960:
            # Hide the fact we're using FRC internally
            if move.targetSquare < move.startSquare:
                move.targetSquare = makeSquare(rankFromSquare(move.targetSquare), fileFromSquare(move.targetSquare) + 2)
            else:
                move.targetSquare = makeSquare(rankFromSquare(move.targetSquare), fileFromSquare(move.targetSquare) - 1)

        if i == 0:
            stdout.styledWrite " ", moveColors[i mod moveColors.len], styleBright, styleItalic, move.toUCI()
        else:
            stdout.styledWrite " ", moveColors[i mod moveColors.len], move.toUCI()

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
        if self.state.normalizeScore.load():
            printedScore = normalizeScore(bestRootScore, material)
        logMsg &= &" score cp {printedScore}"
    
    if self.state.showWDL.load():
        let wdl = getExpectedWDL(bestRootScore, material)
        logMsg &= &" wdl {wdl.win} {wdl.draw} {wdl.loss}"

    logMsg &= &" hashfull {hashfull} time {elapsedMsec} nodes {nodeCount} nps {nps}"
    let chess960 = self.state.chess960.load()
    if line[0] != nullMove():
        logMsg &= " pv "
        for move in line:
            if move == nullMove():
                break
            if move.isCastling() and not chess960:
                # Hide the fact we're using FRC internally
                var move = move
                if move.targetSquare < move.startSquare:
                    move.targetSquare = makeSquare(rankFromSquare(move.targetSquare), fileFromSquare(move.targetSquare) + 2)
                else:
                    move.targetSquare = makeSquare(rankFromSquare(move.targetSquare), fileFromSquare(move.targetSquare) - 1)
                logMsg &= &"{move.toUCI()} "
            else:
                logMsg &= &"{move.toUCI()} "
    if logMsg.endsWith(" "):
        # Remove extra space at the end of the pv
        logMsg = logMsg[0..^2]
    echo logMsg


proc log*(self: SearchLogger, line: array[MAX_DEPTH + 1, Move], bestRootScore: Option[Score] = none(Score)) =
    if not self.state.isMainThread.load() or not self.enabled:
        return
    # Using a shared atomic for such frequently updated counters kills
    # performance and cripples nps scaling, so instead we let each thread
    # have its own local counters and then aggregate the results here
    var
        nodeCount = self.stats.nodeCount.load()
        selDepth = self.stats.selectiveDepth.load()
    for child in self.state.childrenStats:
        nodeCount += child.nodeCount.load()
        selDepth = max(selDepth, child.selectiveDepth.load())
    
    let
        depth = self.stats.highestDepth.load()
        elapsedMsec = self.state.elapsedTime()
        nps = 1000 * (nodeCount div max(elapsedMsec, 1).uint64)
        chess960 = self.state.chess960.load()
        # We allow the searcher to pass in a different best root score because
        # in some cases (e.g. when a search is interrupted or when logging multiple
        # variations), we don't want to use the value in self.stats
        bestRootScore = if bestRootScore.isNone(): self.stats.bestRootScore.load() else: bestRootScore.get()
        variation = self.stats.currentVariation.load()
        material = self.board.getMaterial()
        wdl = getExpectedWDL(bestRootScore, material)
        hashfull = self.ttable[].getFillEstimate()

    if self.state.uciMode.load():
        self.logUCI(depth, selDepth, variation, nodeCOunt, nps, elapsedMsec, chess960, line, bestRootScore, wdl, material, hashfull)
    else:
        self.logPretty(depth, selDepth, variation, nodeCOunt, nps, elapsedMsec, chess960, line, bestRootScore, wdl, material, hashfull)
