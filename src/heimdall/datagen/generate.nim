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

import heimdall/search
import heimdall/uci
import heimdall/board
import heimdall/eval
import heimdall/movegen
import heimdall/transpositions
import heimdall/util/tunables
import heimdall/datagen/scharnagl
import heimdall/datagen/marlinformat
import heimdall/datagen/adjudication
import heimdall/util/limits


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


type
    WorkerArgs = tuple[workerID: int, runID: int64, stopFlag: ref Atomic[bool], posCounter, gameCounter: ref Atomic[int],
                       nodesSoft, nodesHard, drawAdjPly, drawAdjScore, winAdjPly, winAdjScore: int, standard: bool]
var stopFlag = new Atomic[bool]
var threads: seq[ref Thread[WorkerArgs]] = @[]


proc generateData(args: WorkerArgs) {.thread, gcsafe.} =
    ## Begin generating training data to a binary file named
    ## datagen_{run_ID}_{workerID}.bin until the stop flag is set to
    ## true. The provided run ID can be used to deterministically
    ## reproduce any given data generation run for debugging purposes
    var rng = initRand(args.runID + args.workerID)
    var file = open(&"datagen_{args.runID}_{args.workerID}.bin", fmWrite)
    defer: file.flushFile()
    defer: file.close()
    var
        i = 0
        stoppedMidGame = false
        winner = None
        moves {.noinit.} = newMoveList()
        positions: seq[MarlinFormatRecord] = @[]
        quietHistory = create(ThreatHistoryTable)
        captureHistory = create(CaptHistTable)
        killersTable = create(KillersTable)
        countersTable = create(CountersTable)
        continuationHistory = create(ContinuationHistory)
        transpositionTable = create(TTable)
        searchers: array[White..Black, SearchManager]
        adjudicator = newChessAdjudicator(createAdjudicationRule(Score(args.winAdjScore), args.winAdjPly),
                                          createAdjudicationRule(Score(args.drawAdjScore), args.drawAdjPly))


    transpositionTable[] = newTranspositionTable(16 * 1024 * 1024)

    for color in White..Black:
        searchers[color] = newSearchManager(@[startpos()], transpositionTable, quietHistory, captureHistory,
                                            killersTable, countersTable, continuationHistory, getDefaultParameters())
        # Set up hard/soft limits
        searchers[color].limiter.addLimit(newNodeLimit(args.nodesSoft.uint64, args.nodesHard.uint64))

    try:
        while not args.stopFlag[].load():
            inc(i)
            # Default game outcome is a draw
            winner = None
            # Generate a random dfrc position
            var board: Chessboard
            if not args.standard:
                board = newChessboardFromFEN(scharnaglToFEN(rng.rand(959), rng.rand(959)))
            else:
                board = newDefaultChessboard()
            # Make either 8 or 9 random moves with a 50% chance to balance out which side
            # moves first
            let count = if rng.rand(1) == 0: 8 else: 9
            for i in 0..<count:
                moves.clear()
                board.generateMoves(moves)
                if moves.len() > 0:
                    board.doMove(moves[rng.rand(moves.len() - 1)])
                else:
                    break
            # Ensure the game is not over
            if board.isGameOver():
                continue
            positions.setLen(0)
            stoppedMidGame = false
            adjudicator.reset()
            while not board.isGameOver():
                if args.stopFlag[].load():
                    stoppedMidGame = true
                    break

                let sideToMove = board.sideToMove
                searchers[sideToMove].setBoardState(board.positions)
                let line = searchers[sideToMove].search(silent=true)[0][]
                let bestMove = line[0]

                var bestRootScore = searchers[sideToMove].statistics.bestRootScore.load()
                adjudicator.update(sideToMove, bestRootScore)
                # Stored scores are white-relative!
                if sideToMove == Black:
                    bestRootScore = -bestRootScore
                board.doMove(bestMove)
                # Filter positions that would be bad for training
                if not bestRootScore.isMateScore() and not bestMove.isCapture() and not bestMove.isEnPassant() and not board.positions[^2].inCheck():
                    positions.add(createMarlinFormatRecord(board.positions[^2], winner, bestRootScore.int16, 69))  # Nice.
                    args.posCounter[].atomicInc()
                # Adjudicate a win or a draw
                let adjudication = adjudicator.adjudicate()
                if adjudication.isSome():
                    winner = adjudication.get()
                    break
                if board.isCheckmate():
                    winner = sideToMove
                    break
            # Can't save a game if it was interrupted because we don't know
            # the outcome!
            if not stoppedMidGame:
                for pos in positions.mitems():
                    # Update the outcome of the game
                    pos.wdl = winner
                    file.write(pos.toMarlinformat())
                args.gameCounter[].atomicInc()
                # Reset everything at the end of the game
                transpositionTable.init(1)
                resetHeuristicTables(quietHistory, captureHistory, killersTable, countersTable, continuationHistory)
            else:
                # Account for these positions not being saved
                args.posCounter[].atomicDec(len(positions))
    except CatchableError:
        log(&"Worker crashed due to an exception, shutting down: {getCurrentExceptionMsg()}", args.workerID)
    except NilAccessDefect:
        log(&"Worker crashed due to a segfault, shutting down: {getCurrentExceptionMsg()}", args.workerID)


proc stopWorkers {.noconv.} =
    stopFlag[].store(true)


proc startDataGeneration*(runID: int64 = 0, threadCount, nodesSoft, nodesHard, drawAdjPly, drawAdjScore: int, winAdjPly, winAdjScore: int, standard: bool) =
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
    log(&"Starting {(if standard: \"standard chess\" else: \"dfrc\")} datagen on {threadCount} thread{(if threadCount == 1: \"\" else: \"s\")}. Run ID is {runID}, press Ctrl+C to stop", worker=false)
    log(&"Limiting search to {nodesSoft} soft nodes and {nodesHard} hard nodes", worker=false)
    if winAdjPly > 0:
        log(&"Adjudicating a win after {winAdjPly} consecutive pl{(if winAdjPly == 1: \"y\" else: \"ies\")} when score is +/- {winAdjScore}cp", worker=false)
    if drawAdjPly > 0:
        log(&"Adjudicating a draw after {drawAdjPly} consecutive pl{(if drawAdjPly == 1: \"y\" else: \"ies\")} when score is +/- {drawAdjScore}cp", worker=false)
    threads.setLen(0)
    stopFlag[].store(false)
    var posCounter = new Atomic[int]
    var gameCounter = new Atomic[int]
    
    setControlCHook(stopWorkers)

    while len(threads) < threadCount:
        threads.add(new Thread[WorkerArgs])
    for i in 0..<threadCount:
        createThread(threads[i][], generateData, (i + 1, runID, stopFlag, posCounter, gameCounter, nodesSoft, nodesHard,
                                                  drawAdjPly, drawAdjScore, winAdjPly, winAdjScore, standard))
    log("Workers started", worker=false)

    var previous = (pos: 0, games: 0)
    var runningAvg = (pos: 0'f64, games: 0'f64)

    while not stopFlag[].load():
        let
            numPositions = posCounter[].load()
            numGames = gameCounter[].load()
            gamesPerSec = numGames - previous.games
            posPerSec = numPositions - previous.pos
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
    let total = posCounter[].load()
    if threadCount > 1:
        let outputFile = &"datagen_{runID}.bin"
        var output = open(outputFile, fmWrite)
        log(&"Concatenating {threadCount} temporary files", worker=false)
        for i in 0..<threadCount:
            let tempFile = &"datagen_{runID}_{i + 1}.bin"
            doAssert fileExists(tempFile), tempFile
            output.write(readFile(tempFile))
            removeFile(tempFile)
        output.close()
        let read = len(readFile(outputFile))
        doAssert read div 32 == total, &"{read div 32} != {total}"
        log(&"Datagen output dumped to {outputFile}", worker=false)
    log(&"Done! Generated {total} valid positions over {gameCounter[].load()} games", worker=false)


