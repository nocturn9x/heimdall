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

import heimdall/uci
import heimdall/tui
import heimdall/moves
import heimdall/board
import heimdall/search
import heimdall/movegen
import heimdall/position
import heimdall/util/magics
import heimdall/util/limits
import heimdall/util/tunables
import heimdall/transpositions


import std/os
import std/math
import std/times
import std/atomics
import std/parseopt
import std/strutils
import std/strformat


const benchFens = staticRead("heimdall/resources/misc/bench.txt").splitLines()


proc runBench(depth: int = 13) =
    var
        transpositionTable = create(TTable)
        quietHistory = create(ThreatHistory)
        captureHistory = create(CaptureHistory)
        killerMoves = create(KillerMoves)
        counterMoves = create(CounterMoves)
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

        let line = mgr.search()[0]
        if line[1] == nullMove():
            echo &"bestmove {line[0].toUCI()}"
        else:
            echo &"bestmove {line[0].toUCI()} ponder {line[1].toUCI()}"
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
        magicGen = false
        runTUI = false
        runUCI = true
        testOnly = false
        bench = false
        getParams = false
        benchDepth = 13
        previousSubCommand = ""
    
    const subcommands = ["magics", "testonly", "datagen", "datatool", "bench", "spsa", "tui"]
    for kind, key, value in parser.getopt():
        case kind:
            of cmdArgument:
                if bench:
                    for c in key:
                        if not c.isDigit():
                            echo "heimdall: error: 'bench' subcommand requires a number as its only argument"
                            quit(-1)
                    benchDepth = key.parseInt()
                    continue
                
                let inSubCommand = runTUI or bench or getParams or magicGen or testOnly

                if key in subcommands and inSubCommand:
                    echo &"heimdall: error: '{previousSubCommand}' subcommand does not accept any arguments"
                    quit(-1)
                
                if key notin subcommands:
                    if not inSubCommand:
                        echo &"heimdall: error: unknown subcommand '{key}'"
                        quit(-1)
                    else:
                        echo &"heimdall: error: '{previousSubCommand}' subcommand does not accept any arguments"
                        quit(-1)

                case key:
                    of "magics":
                        magicGen = true
                    of "testonly":
                        runUCI = false
                        testOnly = true
                    of "bench":
                        runUCI = false
                        bench = true
                    of "spsa":
                        runUCI = false
                        getParams = true
                    of "tui":
                        runUCI = false
                        runTUI = true
                    else:
                        discard
                previousSubCommand = key
            of cmdLongOption:
                echo &"heimdall: error: option '{key}' does not apply to this subcommand"
                quit(-1)
            of cmdShortOption:
                echo &"heimdall: error: unknown option '{key}'"
                quit(-1)
            of cmdEnd:
                break
    if not magicGen:
        if runTUI:
            quit(commandLoop())
        if runUCI:
            startUCISession()
        if bench:
            runBench(benchDepth)
        if getParams:
            echo getSPSAInput(getDefaultParameters())
    elif magicGen:
        magicWizard()
    quit(0)
