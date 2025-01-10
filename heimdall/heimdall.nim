# Copyright 2024 Mattia Giambirtone & All Contributors
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

import heimdallpkg/tui
import heimdallpkg/movegen
import heimdallpkg/bitboards
import heimdallpkg/moves
import heimdallpkg/pieces
import heimdallpkg/magics
import heimdallpkg/rays
import heimdallpkg/position
import heimdallpkg/board
import heimdallpkg/transpositions
import heimdallpkg/search
import heimdallpkg/eval
import heimdallpkg/util/tunables
import heimdallpkg/uci
import heimdallpkg/datagen/generate
import heimdallpkg/datagen/tool
import heimdallpkg/util/limits


import std/os
import std/times
import std/math
import std/atomics
import std/cpuinfo
import std/parseopt
import std/strutils
import std/strformat
import std/options


export tui, movegen, bitboards, moves, pieces, magics, rays, position, board, transpositions, search, eval, uci, tunables


when defined(mimalloc):
    {.link: "../mimalloc.o".}
    {.warning: "-d:mimalloc switch enabled, statically linking mimalloc".}


const benchFens = staticRead("heimdallpkg/resources/misc/bench.txt").splitLines()


proc runBench(depth: int = 13) =
    var
        transpositionTable = create(TTable)
        quietHistory = create(ThreatHistoryTable)
        captureHistory = create(CaptHistTable)
        killerMoves = create(KillersTable)
        counterMoves = create(CountersTable)
        continuationHistory = create(ContinuationHistory)
        parameters = getDefaultParameters()
    transpositionTable[] = newTranspositionTable(64 * 1024 * 1024)
    resetHeuristicTables(quietHistory, captureHistory, killerMoves, counterMoves, continuationHistory)
    var mgr = newSearchManager(@[startpos()], transpositionTable, quietHistory, captureHistory, killerMoves, counterMoves, continuationHistory, parameters)
    mgr.limiter.addLimit(newDepthLimit(depth))

    echo "info string Benchmark started"
    var
        nodes = 0'u64
        bestMoveTotalNodes = 0'u64
    let startTime = cpuTime()
    for i, fen in benchFens:
        echo &"Position {i + 1}/{len(benchFens)}: {fen}\n"
        mgr.setBoardState(@[loadFEN(fen)])

        let line = mgr.search()
        if line.len() == 1:
            echo &"bestmove {line[0].toAlgebraic()}"
        else:
            echo &"bestmove {line[0].toAlgebraic()} ponder {line[1].toAlgebraic()}"
        transpositionTable[].clear()
        resetHeuristicTables(quietHistory, captureHistory, killerMoves, counterMoves, continuationHistory)
        let
            move = mgr.statistics.bestMove.load()
            totalNodes = mgr.statistics.nodeCount.load()
            bestMoveNodes = mgr.statistics.spentNodes[move.startSquare][move.targetSquare].load()
            bestMoveFrac = bestMoveNodes.float / totalNodes.float
        nodes += totalNodes
        bestMoveTotalNodes += bestMoveNodes
        echo &"info string fraction of nodes spent on best move for this position: {round(bestMoveFrac * 100, 2)}% ({bestMoveNodes}/{totalNodes})"
        echo ""
    let
        endTime = cpuTime() - startTime
        bestMoveFrac = bestMoveTotalNodes.float / nodes.float
    echo &"info string fraction of nodes spent on best move for this bench: {round(bestMoveFrac * 100, 2)}% ({bestMoveTotalNodes}/{nodes})"
    echo &"{nodes} nodes {round(nodes.float / endTime).int} nps"


when isMainModule:
    setControlCHook(proc () {.noconv.} = echo ""; quit(0))
    basicTests()
    # This is horrible, but it works so ¯\_(ツ)_/¯
    var 
        parser = initOptParser(commandLineParams())
        datagen = false
        standardDatagen = false
        datatool = false
        runTUI = false
        runUCI = true
        bench = false
        getParams = false
        workers = (let p = countProcessors(); if p != 0: p else: 1)
        seed = 0
        drawAdjPly = 10
        drawAdjScore = 10
        winAdjScore = 2500
        winAdjPly = 5
        benchDepth = 13
        nodesSoft = 5000
        nodesHard = 100_000
        dataFile = ""
        filterScores = (min: lowestEval(), max: highestEval())
        dataDryRun = false
        dataToolLimit = none(int)
        filterOutputFile = "filtered.bin"
    for kind, key, value in parser.getopt():
        case kind:
            of cmdArgument:
                if bench:
                    try:
                       benchDepth = key.parseInt()
                       continue
                    except ValueError:
                        discard
                case key:
                    of "testonly":
                        runUCI = false
                    of "datagen":
                        if runTUI or bench or getParams or datatool:
                            echo "error: 'datagen' subcommand does not accept any arguments"
                            quit(-1)
                        datagen = true
                    of "datatool":
                        if runTUI or bench or getParams or datagen or datatool:
                            echo "error: 'datatool' subcommand does not accept any arguments"
                            quit(-1)
                        datatool = true
                    of "bench":
                        runUCI = false
                        if runTUI or datagen or getParams or datatool:
                            echo "error: 'bench' subcommand does not accept any arguments"
                            quit(-1)
                        bench = true
                    of "spsa":
                        runUCI = false
                        if runTUI or datagen or bench or datatool:
                            echo "error: 'spsa' subcommand does not accept any arguments"
                            quit(-1)
                        getParams = true
                    of "tui":
                        runUCI = false
                        if datagen or getParams or bench or datatool:
                            echo "error: 'tui' subcommand does not accept any arguments"
                            quit(-1)
                        runTUI = true
                    else:
                        echo &"error: unknown subcommand '{key}'"
                        quit(-1)
            of cmdLongOption:
                if datagen:
                    case key:
                        of "standard":
                            standardDatagen = true
                        of "workers":
                            workers = value.parseInt()
                        of "seed":
                            seed = value.parseInt()
                        of "draw-adj-ply":
                            drawAdjPly = value.parseInt()
                        of "draw-adj-score":
                            drawAdjScore = value.parseInt()
                        of "win-adj-score":
                            winAdjScore = value.parseInt()
                        of "win-adj-ply":
                            winAdjPly = value.parseInt()
                        of "nodes-soft":
                            nodesSoft = value.parseInt()
                        of "nodes-hard":
                            nodesHard = value.parseInt()
                        else:
                            echo &"error: unknown option '{key}' for 'datagen'"
                            quit(-1)
                elif datatool:
                    case key:
                        of "file":
                            dataFile = value
                        of "score-min":
                            filterScores.min = Score(value.parseInt())
                        of "score-max":
                            filterScores.max = Score(value.parseInt())
                        of "dry-run":
                            dataDryRun = true
                        of "limit":
                            dataToolLimit = some(value.parseInt())
                        of "output":
                            filterOutputFile = value
                        else:
                            echo &"error: unknown option '{key}' for 'datatool'"
                else:
                    echo &"error: option '{key}' does not apply to this subcommand"
                    quit(-1)
            of cmdShortOption:
                if datatool:
                    case key:
                        of "f":
                            dataFile = value
                        of "d":
                            dataDryRun = true
                        of "l":
                            dataToolLimit = some(value.parseInt())
                        of "o":
                            filterOutputFile = value
                        else:
                            echo &"error: unknown option '{key}' for 'datatool'"
                else:
                    echo &"error: unknown option '{key}'"
                    quit(-1)
            of cmdEnd:
                break
    if not datagen and not datatool:
        if runTUI:
            quit(commandLoop())
        if runUCI:
            startUCISession()
        if bench:
            runBench(benchDepth)
        if getParams:
            echo getSPSAInput(getDefaultParameters())
    elif datatool:
        if dataFile.len() == 0:
            echo &"error: 'datatool' subcommand requires the -f/--file option"
            quit(-1)
        runDataTool(dataFile, filterScores, dataDryRun, filterOutputFile, dataToolLimit)
    else:
        startDataGeneration(seed, workers, nodesSoft, nodesHard, drawAdjPly, drawAdjScore, winAdjPly, winAdjScore, standardDatagen)
    quit(0)
