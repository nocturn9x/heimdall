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

# Shameless yoink of https://github.com/cosmobobak/viridithas/blob/master/src/evaluation.rs#L150
import heimdall/eval
import heimdall/board

import std/math
import std/times
import std/strutils
import std/strformat


proc printEvalStats*(inputBook: string) =

    echo &"Loading positions from '{inputBook}'"

    var f = open(inputBook)
    defer: f.close()

    var positions = newSeq[string]()

    for line in f.lines():
        positions.add(line)

    echo &"Loaded {len(positions)} positions"

    let start = cpuTime()

    var
        board: Chessboard
        evalState = newEvalState(verbose=false)
        total = 0'i64
        count = 0'i64
        absTotal = 0'i64
        minEval = highestEval()
        maxEval = lowestEval()
        sqTotal = 0'i64
    
    for i, line in positions:
        # Allows us to parse files where there's more
        # than just one FEN per line (like lichess-big3-resolved
        # which has the WDL as well)
        let fen = join(line.split(" ")[0..5], " ")
        board = newChessboardFromFEN(fen)
        if board.inCheck():
            continue
        evalState.init(board)
        
        let eval = board.evaluate(evalState)

        inc(count)
        inc(total, eval)
        inc(absTotal, abs(eval))
        inc(sqTotal, eval * eval)

        if eval < minEval:
            minEval = eval
        if eval > maxEval:
            maxEval = eval
        
        if i mod 1024 == 0:
            stdout.write(&"\rProcessed {i + 1:>10}/{len(positions)} positions")
            stdout.flushFile()
    
    echo &"\rProcessed {len(positions):>10}/{len(positions)} positions in {cpuTime() - start:.2f} seconds"
    
    echo "Statistics:"
    echo &"- Count: {count:>7}"
    if count > 0:
        let
            mean = total / count
            absMean = absTotal / count
            meanSquared = mean * mean
            variance = (sqTotal / count) - meanSquared
            stddev = sqrt(variance)
            minEval = minEval.float64
            maxEval = maxEval.float64
        
        echo &"- Mean          : {mean:>10.2f}"
        echo &"- Absolute mean : {absMean:>10.2f}"
        echo &"- Std. deviation: {stddev:>10.2f}"
        echo &"- Minimum eval  : {minEval:>10.2f}"
        echo &"- Maximum eval  : {maxEval:>10.2f}"
