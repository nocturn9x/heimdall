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

import heimdallpkg/search
import heimdallpkg/uci
import heimdallpkg/board
import heimdallpkg/movegen
import heimdallpkg/transpositions
import heimdallpkg/tunables
import heimdallpkg/datagen/scharnagl
import heimdallpkg/datagen/util
import heimdallpkg/limits


import std/os
import std/math
import std/times
import std/random
import std/atomics
import std/terminal
import std/strformat


proc log(message: string, id: int = -1, lineEnd="\n", worker=true) =
    ## Logs a message to stdout
    let time = getTime().format("dd/MM/yyyy HH:mm:ss tt")
    var logMsg = ""
    if worker:
        logMsg &= &"[worker {id} "
    else:
        logMsg &= "[main "
    logMsg &= &"- {time}] {message}{lineEnd}"
    stdout.write(logMsg)


type WorkerArgs = tuple[workerID: int, runID: int64, stopFlag: ptr Atomic[bool], counter: ptr Atomic[int], drawAdjPly, winAdjPly, winAdjScore: int]
var stopFlag = create(Atomic[bool])
var threads: seq[ref Thread[WorkerArgs]] = @[]


proc generateData(args: WorkerArgs) {.thread.} =
    ## Begin generating training data to a binary file named
    ## datagen_{run_ID}_{workerID}.bin until the stop flag is set to
    ## true. The file is opened in append mode, meaning previously
    ## generated data with the same run and worker ID will not be lost.
    ## The provided run ID can be used to deterministically reproduce
    ## any given data generation run for debugging purposes
    {.cast(gcsafe).}:
        var rng = initRand(args.runID)
        var file = open(&"datagen_{args.runID}_{args.workerID}.bin", fmAppend)
        var
            i = 0
            stoppedMidGame = false
            winner = None
            adjudicated = false
            drawScorePlyCount = 0
            winScorePlyCount = 0
            moves {.noinit.} = newMoveList()
            positions: seq[CompressedPosition] = @[]
            transpositionTable = create(TTable)
            quietHistory = create(HistoryTable)
            captureHistory = create(HistoryTable)
            killerMoves = create(KillersTable)
            counterMoves = create(CountersTable)
            continuationHistory = create(ContinuationHistory)
            searcher = newSearchManager(@[startpos()], transpositionTable, quietHistory, captureHistory, killerMoves, counterMoves, continuationHistory, getDefaultParameters())
        searcher.limiter.addLimit(newNodeLimit(5000, 10_000_000))
        transpositionTable[] = newTranspositionTable(128 * 1024 * 1024)

        while not args.stopFlag[].load():
            inc(i)
            winner = None
            drawScorePlyCount = 0
            winScorePlyCount = 0
            adjudicated = false
            # Generate a random dfrc position
            var board = newChessboardFromFEN(scharnaglToFEN(rng.rand(959), rng.rand(959)))
            # Make either 8 or 9 random moves with a 50% chance to balance out which side
            # moves first
            let count = if rng.rand(1) == 0: 8 else: 9
            for i in 0..<count:
                moves.clear()
                board.generateMoves(moves)
                if moves.len() > 0:
                    board.makeMove(moves[rng.rand(moves.len() - 1)])
            positions.setLen(0)
            stoppedMidGame = false
            while not board.isGameOver():
                if args.stopFlag[].load():
                    stoppedMidGame = true
                    break
                # Search at most 10M nodes with a 5k node soft limit
                searcher.setBoardState(board.positions)
                let line = searcher.search(silent=true)
                let bestMove = line[0]
                board.doMove(bestMove)
                # Filter positions that would be bad for training
                if board.inCheck():
                    continue
                if bestMove.isCapture():
                    continue
                # Count how many consecutive plies are scored
                # with either a draw score or one that is >=
                # than our win adjudication score
                if searcher.bestRootScore == 0:
                    inc(drawScorePlyCount)
                else:
                    drawScorePlyCount = 0
                if args.winAdjScore > 0 and abs(searcher.bestRootScore) >= args.winAdjScore:
                    # Account for the value of the score being negative for unfavorable
                    # positions
                    inc(winScorePlyCount)
                else:
                    winScorePlyCount = 0
                # We don't know the outcome of the game yet, so we record it as a draw for now. We'll update it
                # later if needed
                positions.add(createCompressedPosition(board.position, None, searcher.bestRootScore.int16, 69))  # Nice.
                args.counter[].atomicInc()
                # Adjudicate a win or a draw
                if args.drawAdjPly > 0 and drawScorePlyCount == args.drawAdjPly:
                    # No need to set the winner
                    adjudicated = true
                    break
                if args.winAdjPly > 0 and winScorePlyCount == args.winAdjPly:
                    # When a move is played, the stm is swapped,
                    # so we need to flip it back to the side that
                    # played the winning move
                    winner = board.sideToMove.opposite()
                    adjudicated = true
                    break
            if not adjudicated and board.isCheckmate():
                winner = board.sideToMove.opposite()
            # Can't save a game if it was interrupted because we don't know
            # the outcome! 
            if not stoppedMidGame:
                for pos in positions.mitems():
                    # Update the outcome of the game
                    pos.wdl = winner
                    file.write(pos.toMarlinformat())
            # Reset everything at the end of the game
            resetHeuristicTables(quietHistory, captureHistory, killerMoves, counterMoves, continuationHistory)
        file.close()


proc stopWorkers {.noconv.} =
    stopFlag[].store(true)


proc startDataGeneration*(runID: int64 = 0, threadCount, drawAdjPly, winAdjPly, winAdjScore: int) =
    ## Begins data generation
    var runID = runID
    if runID == 0:
        var rng = initRand()
        runID = rng.rand(int64.high())
    log(&"Starting datagen on {threadCount} thread{(if threadCount == 1: \"\" else: \"s\")}. Run ID is {runID}, press Ctrl+C to stop", worker=false)
    threads.setLen(0)
    stopFlag[].store(false)
    var counter = create(Atomic[int])
    
    setControlCHook(stopWorkers)

    while len(threads) < threadCount:
        threads.add(new Thread[WorkerArgs])
    for i in 0..<threadCount:
        createThread(threads[i][], generateData, (i + 1, runID + i, stopFlag, counter, drawAdjPly, winAdjPly, winAdjScore))
    log("Workers started", worker=false)

    var previous = 0
    var runningAvg = 0'f64

    while not stopFlag[].load():
        let numPositions = counter[].load()
        let perSec = numPositions - previous
        if previous == 0:
            runningAvg = perSec.float
        runningAvg = 0.99 * runningAvg + perSec.float * 0.01
        log(&"Positions: ~{numPositions} total, {perSec} pos/sec immediate ({round(runningAvg, 0).int} pos/sec average)", worker=false)
        previous = numPositions
        sleep(1000)
        cursorUp(1)
        eraseLine()

    log("Received Ctrl+C, stopping workers", worker=false)
    for i in 0..<threadCount:
        joinThread(threads[i][])
    log(&"Done! Generated {counter[].load()} total positions", worker=false)
    dealloc(counter)

