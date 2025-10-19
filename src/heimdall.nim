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
import std/[os, math, times, atomics, parseopt, strutils, strformat, options, random]

import heimdall/[uci, tui, moves, board, search, movegen, position, transpositions, eval]
import heimdall/util/[magics, limits, tunables, book_augment]


randomize()
const benchFens = staticRead("heimdall/resources/misc/bench.txt").splitLines()


proc runBench(depth: int = 13) =
    var transpositionTable = create(TTable)
    transpositionTable[] = newTranspositionTable(64 * 1024 * 1024)
    var mgr = newSearchManager(@[startpos()], transpositionTable)
    mgr.limiter.addLimit(newDepthLimit(depth))

    echo "info string Benchmark started"
    var
        nodes = 0'u64
        bestMoveTotalNodes = 0'u64
    let startTime = cpuTime()
    for i, fen in benchFens:
        echo &"Position {i + 1}/{len(benchFens)}: {fen}\n"
        mgr.setBoardState(@[fromFEN(fen)])

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
        parser     = initOptParser(commandLineParams())
        augment    = false
        magicGen   = false
        runTUI     = false
        runUCI     = true
        testOnly   = false
        bench      = false
        getParams  = false
        benchDepth = 13
        prevSubCmd = ""
        # Parameters for the data augmentation tool
        inputBook     = none(string)
        outputBook    = none(string)
        augmentDepth  = (min: 8, max: 8)
        bookSizeHint  = 1_000_000
        bookMaxExit   = Score(400)
        filterChecks  = true
        append        = false
        seed          = rand(int64.high())
        searcherDepth = 10
        searcherNodes = (soft: 5000'u64, hard: 1_000_000'u64)
        searcherHash  = 8'u64
        threads       = 1
        limit         = 0
        skip          = 0
        rounds        = 1

    const subcommands = ["magics", "testonly", "bench", "spsa", "tui", "chonk"]
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

                let inSubCommand = runTUI or bench or getParams or magicGen or testOnly or augment

                if key in subcommands and inSubCommand:
                    echo &"heimdall: error: '{prevSubCmd}' subcommand does not accept any arguments"
                    quit(-1)

                if key notin subcommands:
                    if not inSubCommand:
                        echo &"heimdall: error: unknown subcommand '{key}'"
                        quit(-1)
                    else:
                        echo &"heimdall: error: '{prevSubCmd}' subcommand does not accept any arguments (to pass options, do --opt=value instead of --opt value)"
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
                    of "chonk":
                        # Hehe me make chonky book
                        augment = true
                    else:
                        discard
                prevSubCmd = key
            of cmdLongOption:
                if augment:
                    case key:
                        of "input":
                            inputBook = some(value)
                        of "output":
                            outputBook = some(value)
                        of "nodes-soft":
                            searcherNodes.soft = parseBiggestUInt(value)
                        of "nodes-hard":
                            searcherNodes.hard = parseBiggestUInt(value)
                        of "hash":
                            searcherHash = parseBiggestUInt(value)
                        of "depth":
                            searcherDepth = parseBiggestInt(value)
                        of "moves":
                            augmentDepth.min = parseBiggestInt(value)
                            augmentDepth.max = augmentDepth.min
                        of "moves-min":
                            augmentDepth.min = parseBiggestInt(value)
                        of "moves-max":
                            augmentDepth.max = parseBiggestInt(value)
                        of "allow-checks":
                            filterChecks = false
                        of "max-exit":
                            bookMaxExit = Score(parseInt(value))
                        of "seed":
                            seed = parseBiggestInt(value)
                        of "size-hint":
                            bookSizeHint = parseBiggestInt(value)
                        of "threads":
                            threads = parseInt(value)
                        of "limit":
                            limit = parseInt(value)
                        of "skip":
                            skip = parseInt(value)
                        of "append":
                            append = true
                        of "rounds":
                            rounds = parseInt(value)
                        else:
                            echo &"heimdall: chonk: error: unknown option '{key}'"
                            quit(-1)
                else:
                    echo &"heimdall: error: unknown option '{key}'"
                    quit(-1)
            of cmdShortOption:
                echo &"heimdall: error: unknown option '{key}'"
                quit(-1)
            of cmdEnd:
                break
    if not magicGen and not augment:
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
    elif augment:
        if not inputBook.isSome() or not outputBook.isSome():
            echo &"heimdall: chonk: error: --input and --output are required"
            quit(-1)
        if rounds < 1:
            echo &"heimdall: chonk: error: --rounds must be > 1"
            quit(-1)
        if rounds > 1:
            echo &"Running {rounds} consecutive rounds of book chonkening: note that this changes the meaning of the --seed option!"
        augmentBook(inputBook.get(), outputBook.get(), augmentDepth, limit, skip, bookSizeHint, bookMaxExit,
                    filterChecks, append, seed, (depth: searcherDepth, nodes: searcherNodes, hash: searcherHash),
                    threads, rounds)
    quit(0)
