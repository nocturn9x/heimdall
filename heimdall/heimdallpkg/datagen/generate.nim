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
import heimdallpkg/uci
import heimdallpkg/eval
import heimdallpkg/movegen
import heimdallpkg/transpositions
import heimdallpkg/util/tunables
import heimdallpkg/datagen/scharnagl
import heimdallpkg/datagen/marlinformat
import heimdallpkg/datagen/adjudication
import heimdallpkg/util/limits


import std/os
import std/math
import std/times
import std/random
import std/options
import std/atomics
import std/terminal
import std/strformat
import std/segfaults


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


type WorkerArgs = tuple[workerID: int, runID: int64, stopFlag: ptr Atomic[bool], posCounter, gameCounter: ptr Atomic[int], drawAdjPly, winAdjPly, winAdjScore: int]
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
            moves {.noinit.} = newMoveList()
            positions: seq[MarlinFormatRecord] = @[]
            quietHistories: array[White..Black, ptr HistoryTable]
            captureHistories: array[White..Black, ptr HistoryTable]
            killerTables: array[White..Black, ptr KillersTable]
            counterTables: array[White..Black, ptr CountersTable]
            continuationHistories: array[White..Black, ptr ContinuationHistory]
            transpositionTables: array[White..Black, ptr TTable]
            searchers: array[White..Black, SearchManager]
        
        # We keep the searchers and related metadata of each side separate to ensure no issues
        for color in White..Black:
            transpositionTables[color] = create(TTable)
            quietHistories[color] = create(HistoryTable)
            captureHistories[color] = create(HistoryTable)
            killerTables[color] = create(KillersTable)
            counterTables[color] = create(CountersTable)
            continuationHistories[color] = create(ContinuationHistory)
            transpositionTables[color][] = newTranspositionTable(128 * 1024 * 1024)

            searchers[color] = newSearchManager(@[startpos()], transpositionTables[color], quietHistories[color], captureHistories[color],
                                                killerTables[color], counterTables[color], continuationHistories[color], getDefaultParameters())
            # Search at most 100k nodes with a 5k node soft limit
            searchers[color].limiter.addLimit(newNodeLimit(5000, 100_000))

        try:
            while not args.stopFlag[].load():
                inc(i)
                # Default game outcome is a draw
                winner = None
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
                var adjudicator = newChessAdjudicator(createAdjudicationRule(0, args.drawAdjPly),
                                                      createAdjudicationRule(Score(args.winAdjScore), args.winAdjPly))
                while not board.isGameOver():
                    if args.stopFlag[].load():
                        stoppedMidGame = true
                        break
                    searchers[board.sideToMove].setBoardState(board.positions)
                    let line = searchers[board.sideToMove].search(silent=true)
                    let bestMove = line[0]
                    let bestRootScore = searchers[board.sideToMove].statistics.bestRootScore.load()
                    board.doMove(bestMove)
                    # Filter positions that would be bad for training
                    if board.inCheck():
                        continue
                    if bestMove.isCapture() or bestMove.isEnPassant():
                        continue
                    # Record the previous position, not the one after we
                    # made the move
                    positions.add(createMarlinFormatRecord(board.positions[^2], winner, bestRootScore.int16, 69))  # Nice.
                    args.posCounter[].atomicInc()
                    # Adjudicate a win or a draw
                    let adjudication = adjudicator.adjudicate()
                    if adjudication.isSome():
                        winner = adjudication.get()
                        adjudicated = true
                        break
                    elif board.isCheckmate():
                        winner = board.sideToMove.opposite()
                        break
                # Can't save a game if it was interrupted because we don't know
                # the outcome!
                if not stoppedMidGame:
                    for pos in positions.mitems():
                        # Update the outcome of the game
                        pos.wdl = winner
                        file.write(pos.toMarlinformat())
                args.gameCounter[].atomicInc()
                for color in White..Black:
                    # Reset everything at the end of the game
                    resetHeuristicTables(quietHistories[color], captureHistories[color], killerTables[color], counterTables[color], continuationHistories[color])
            file.close()
        except CatchableError:
            log(&"Worker crashed due to an exception, shutting down: {getCurrentExceptionMsg()}", args.workerID)
        except NilAccessDefect:
            log(&"Worker crashed due to a segfault, shutting down: {getCurrentExceptionMsg()}", args.workerID)


proc stopWorkers {.noconv.} =
    stopFlag[].store(true)


proc startDataGeneration*(runID: int64 = 0, threadCount, drawAdjPly, winAdjPly, winAdjScore: int) =
    ## Begins data generation
    var runID = runID
    if runID == 0:
        var rng = initRand()
        runID = rng.rand(int64.high())
    echo """
    __  __     _               __      ____
   / / / /__  (_)___ ___  ____/ /___ _/ / /
  / /_/ / _ \/ / __ `__ \/ __  / __ `/ / / 
 / __  /  __/ / / / / / / /_/ / /_/ / / /  
/_/ /_/\___/_/_/ /_/ /_/\__,_/\__,_/_/_/
    """
    log(&"Datagen tool v2 for {getVersionString()}", worker=false)
    log(&"Starting datagen on {threadCount} thread{(if threadCount == 1: \"\" else: \"s\")}. Run ID is {runID}, press Ctrl+C to stop", worker=false)
    if winAdjPly > 0:
        log(&"Adjudicating a win after {winAdjPly} consecutive pl{(if winAdjPly == 1: \"y\" else: \"ies\")} (threshold: {winAdjScore}cp)", worker=false)
    if drawAdjPly > 0:
        log(&"Adjudicating a draw after {drawAdjPly} consecutive pl{(if drawAdjPly == 1: \"y\" else: \"ies\")} iff score == 0", worker=false)
    threads.setLen(0)
    stopFlag[].store(false)
    var posCounter = create(Atomic[int])
    var gameCounter = create(Atomic[int]) 
    
    setControlCHook(stopWorkers)

    while len(threads) < threadCount:
        threads.add(new Thread[WorkerArgs])
    for i in 0..<threadCount:
        createThread(threads[i][], generateData, (i + 1, runID + i, stopFlag, posCounter, gameCounter, drawAdjPly, winAdjPly, winAdjScore))
    log("Workers started", worker=false)

    var previous = (pos: 0, games: 0)
    var runningAvg = (pos: 0'f64, games: 0'f64)

    while not stopFlag[].load():
        let numPositions = posCounter[].load()
        let numGames = gameCounter[].load()
        let gamesPerSec = numGames - previous.games
        let posPerSec = numPositions - previous.pos
        if previous.pos == 0:
            runningAvg.pos = posPerSec.float
        if previous.games == 0:
            runningAvg.games = gamesPerSec.float
        runningAvg.pos = 0.85 * runningAvg.pos + posPerSec.float * 0.15
        runningAvg.games = 0.75 * runningAvg.games + gamesPerSec.float * 0.25
        log(&"Stats: ~{numPositions} total positions over {numGames} games, {posPerSec} pos/sec (avg: {round(runningAvg.pos, 0).int} pos/sec, {round(runningAvg.games, 0).int} games/sec)", worker=false)
        previous.pos = numPositions
        previous.games = numGames
        sleep(1000)
        cursorUp(1)
        eraseLine()

    log("Received Ctrl+C, waiting for workers", worker=false)
    for i in 0..<threadCount:
        if threads[i][].running:
            joinThread(threads[i][])
    log(&"Done! Generated {posCounter[].load()} total positions over {gameCounter[].load()} games", worker=false)
    dealloc(posCounter)
    dealloc(gameCounter)

