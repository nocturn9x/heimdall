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
import heimdallpkg/tunables



import std/os
import std/times
import std/math
import std/parseopt
import std/strutils
import std/strformat


export tui, movegen, bitboards, moves, pieces, magics, rays, position, board, transpositions, search, eval


when defined(mimalloc):
    {.link: "../mimalloc.o".}
    {.warning: "-d:mimalloc switch enabled, statically linking mimalloc".}


const benchFens = staticRead("heimdallpkg/resources/bench.txt").splitLines()


proc runBench =
    var
        transpositionTable = create(TTable)
        historyTable = create(HistoryTable)
        killerMoves = create(KillersTable)
        counterMoves = create(CountersTable)
        parameters = getDefaultParameters()
    transpositionTable[] = newTranspositionTable(64 * 1024 * 1024)
    echo "Benchmark started"
    var nodes = 0'u64
    let startTime = cpuTime()
    for i, fen in benchFens:
        echo &"Position {i + 1}/{len(benchFens)}: {fen}\n"
        var mgr = newSearchManager(@[loadFEN(fen)], transpositionTable, historyTable, killerMoves, counterMoves, parameters)
        let line = mgr.search(0, 0, 10, 0, @[], false, true, false, 1)
        if line.len() == 1:
            echo &"bestmove {line[0].toAlgebraic()}"
        else:
            echo &"bestmove {line[0].toAlgebraic()} ponder {line[1].toAlgebraic()}"
        nodes += mgr.nodes()
        transpositionTable[].clear()
        # Re-Initialize history table
        for color in PieceColor.White..PieceColor.Black:
            for i in Square(0)..Square(63):
                for j in Square(0)..Square(63):
                    historyTable[color][i][j] = Score(0)
        # Re-nitialize killer move table
        for i in 0..<MAX_DEPTH:
            for j in 0..<NUM_KILLERS:
                killerMoves[i][j] = nullMove()
        for fromSq in Square(0)..Square(63):
            for toSq in Square(0)..Square(63):
                counterMoves[fromSq][toSq] = nullMove()
        echo ""
    let endTime = cpuTime() - startTime
    echo &"{nodes} nodes {round(nodes.float / endTime).int} nps"


when isMainModule:
    var parser = initOptParser(commandLineParams())
    for kind, key, value in parser.getopt():
        case kind:
            of cmdArgument:
                case key:
                    of "bench":
                        runBench()
                        quit(0)
                    of "spsa":
                        echo getSPSAInput(getDefaultParameters())
                        quit(0)
                    else:
                        discard
            of cmdLongOption:
                discard
            of cmdShortOption:
                discard
            of cmdEnd:
                break
    setControlCHook(proc () {.noconv.} = quit(0))
    basicTests()
    quit(commandLoop())
