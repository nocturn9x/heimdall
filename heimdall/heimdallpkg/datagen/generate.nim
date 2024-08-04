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


import std/times
import std/random
import std/atomics
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


proc generateData(args: tuple[workerId: int, runID: int64, stopFlag: ptr Atomic[bool]]) {.thread.} =
    ## Begin generating training data to a binary file named
    ## datagen_thread_{id}.bin until the stop flag is set to
    ## true. The provided ID can be used to deterministically
    ## reproduce any given data generation run for debugging
    ## purposes
    {.cast(gcsafe).}:
        log("Started worker thread", args.workerId)
        var rng = initRand(args.runID)
        var file = open(&"datagen_{args.runID}_{args.workerID}.bin", fmAppend)
        var
            i = 0
            stoppedMidGame = false
            moves {.noinit.} = newMoveList()
            games: seq[CompressedPosition] = @[]
            transpositionTable = create(TTable)
            quietHistory = create(HistoryTable)
            captureHistory = create(HistoryTable)
            killerMoves = create(KillersTable)
            counterMoves = create(CountersTable)
            continuationHistory = create(ContinuationHistory)
            searcher = newSearchManager(@[startpos()], transpositionTable, quietHistory, captureHistory, killerMoves, counterMoves, continuationHistory, getDefaultParameters())
        transpositionTable[] = newTranspositionTable(128 * 1024 * 1024)

        while not args.stopFlag[].load():
            inc(i)
            # Generate a random dfrc position
            var board = newChessboardFromFEN(scharnaglToFEN(rng.rand(959), rng.rand(959)))
            # Make either 8 or 9 random moves with a 50% chance to balance out which side
            # moves first
            let count = if rng.rand(1) == 0: 8 else: 9
            log(&"Starting position is {board.toFEN()}, making {count} random moves", args.workerId)
            for i in 0..<count:
                moves.clear()
                board.generateMoves(moves)
                if moves.len() > 0:
                    board.makeMove(moves[0])
            games.setLen(0)
            log(&"Starting game {i} from {board.toFEN()}", args.workerId)
            stoppedMidGame = false
            while not board.isGameOver():
                if args.stopFlag[].load():
                    stoppedMidGame = true
                    log(&"Stopping mid-game! Game number is {i}", args.workerId)
                    break
                # Search at most 10M nodes with a 5k node soft limit
                searcher.setBoardState(board.positions)
                let line = searcher.search(int64.high(), 0, -1, 10_000_000, @[], silent=true, ponder=true, softNodeLimit=5000)
                let bestMove = line[0]
                board.doMove(bestMove)
                # Filter positions that would be bad for training
                if board.inCheck():
                    continue
                if bestMove.isCapture():
                    continue
                # We don't know the outcome of the game yet, so we record it as a draw for now. We'll update it
                # later if needed
                games.add(createCompressedPosition(board.position, None, searcher.bestRootScore.int16, 69))  # Nice.   
            # Can't save a game if it was interrupted because we don't know
            # the outcome!      
            if not stoppedMidGame:
                let checkmated = board.isCheckmate()
                log(&"Game {i} is over, outcome: ", args.workerId, "")
                if checkmated:
                    stdout.write(&"{board.sideToMove.opposite()} wins by checkmate\n")
                else:
                    stdout.write("Draw\n")
                for game in games.mitems():
                    # Update the winning side if the game
                    # ended in a checkmate instead of a draw
                    if checkmated:
                        # When a move is played, the stm is swapped,
                        # so we need to flip it back to the side that
                        # played the checkmating move
                        game.wdl = board.sideToMove.opposite()
                    file.write(game.toMarlinformat())
            # Reset everything at the end of the game
            resetHeuristicTables(quietHistory, captureHistory, killerMoves, counterMoves, continuationHistory)
        log("Stopping!", args.workerId)


var stopFlag = create(Atomic[bool])
var threads: seq[ref Thread[tuple[workerId: int, runID: int64, stopFlag: ptr Atomic[bool]]]] = @[]


proc startDataGeneration*(runID: int64 = 0, threadCount: int) =
    ## Begins data generation
    var runID = runID
    if runID == 0:
        var rng = initRand()
        runID = rng.rand(int64.high())
    log(&"Starting datagen on {threadCount} thread{(if threadCount == 1: \"\" else: \"s\")}. Run ID is {runID}, press Ctrl+C to stop", worker=false)
    threads.setLen(0)
    stopFlag[].store(false)

    proc stopWorkers {.noconv.} =
        log("Stopping workers", worker=false)
        stopFlag[].store(true)
    
    setControlCHook(stopWorkers)

    while len(threads) < threadCount:
        threads.add(new Thread[tuple[workerId: int, runID: int64, stopFlag: ptr Atomic[bool]]])
    for i in 0..<threadCount:
        createThread(threads[i][], generateData, (i + 1, runID + i, stopFlag))
    log("Waiting for workers", worker=false)
    for i in 0..<threadCount:
        joinThread(threads[i][])
    log("Done!", worker=false)
    quit(0)

