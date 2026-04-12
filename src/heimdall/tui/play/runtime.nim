# Copyright 2026 Mattia Giambirtone & All Contributors
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

## Active play-mode game orchestration and watch/ponder runtime.

import std/[options, random, atomics, strformat]

import heimdall/[board, moves, pieces, movegen, position, search, transpositions, eval]
import heimdall/util/limits
import heimdall/tui/[state, analysis]
import heimdall/tui/play/common
import heimdall/tui/util/clock
import heimdall/tui/util/san

proc startEngineTurn*(state: AppState)
proc onPlayerMove*(state: AppState, clearQueuedPremoves = true)
proc startWatchWorker*(state: AppState)


proc watchWorkerLoop*(statePtr: ptr AppState) {.thread.} =
    ## Background search thread for the second engine in watch mode.
    let state = statePtr[]

    while true:
        let cmd = state.play.watch.channels.command.recv()

        case cmd.kind:
            of Shutdown:
                state.play.watch.channels.response.send(Exiting)
                break

            of StopSearch:
                state.play.watch.searcher.cancel()
                if not state.play.watch.searcher.isSearching():
                    state.play.watch.channels.response.send(SearchComplete)

            of StartAnalysis:
                # Not used for watch engine, but handle gracefully.
                state.play.watch.channels.response.send(SearchComplete)

            of StartEngineMove:
                state.play.watch.searcher.limiter.clear()
                state.play.watch.searcher.state.mateDepth.store(none(int), moRelaxed)
                for limit in cmd.engineLimits:
                    state.play.watch.searcher.limiter.addLimit(limit)
                state.play.watch.searcher.setBoard(cmd.enginePositions)
                state.play.watch.searcher.setUCIMode(true)
                discard state.play.watch.searcher.search(silent=true, ponder=cmd.ponder, variations=1)

                state.play.watch.channels.response.send(SearchComplete)


proc clonePositions(board: Chessboard): seq[Position] =
    for pos in board.positions:
        result.add(pos.clone())


proc clonePositionsAfterMove(board: Chessboard, move: Move): seq[Position] =
    var previewBoard = newChessboard(clonePositions(board))
    discard previewBoard.makeMove(move)
    for pos in previewBoard.positions:
        result.add(pos.clone())


proc sendPrimaryEngineCommand(state: AppState, positions: sink seq[Position], engineLimits: sink seq[SearchLimit], ponder = false) =
    state.channels.command.send(SearchCommand(
        kind: StartEngineMove,
        ponder: ponder,
        enginePositions: positions,
        engineLimits: engineLimits
    ))


proc sendWatchEngineCommand(state: AppState, positions: sink seq[Position], engineLimits: sink seq[SearchLimit], ponder = false) =
    state.play.watch.channels.command.send(SearchCommand(
        kind: StartEngineMove,
        ponder: ponder,
        enginePositions: positions,
        engineLimits: engineLimits
    ))


proc setWatchWhiteLimit(state: AppState, limit: PlayLimitConfig) =
    state.play.playerLimit = limit
    state.play.playerClock = limitClock(limit)


proc setWatchBlackLimit(state: AppState, limit: PlayLimitConfig) =
    state.play.engineLimit = limit
    state.play.engineClock = limitClock(limit)


proc setHumanPlayerLimit(state: AppState, limit: PlayLimitConfig) =
    state.play.playerLimit = limit
    state.play.playerClock = limitClock(limit)


proc setHumanEngineLimit(state: AppState, limit: PlayLimitConfig) =
    state.play.engineLimit = limit
    state.play.engineClock = limitClock(limit)


proc applyLimitToTarget*(state: AppState, target: SetupLimitTarget, limit: PlayLimitConfig) =
    case target:
        of EngineLimitTarget:
            state.setHumanEngineLimit(limit)
        of WatchWhiteLimitTarget:
            state.setWatchWhiteLimit(limit)
        of WatchBlackLimitTarget:
            state.setWatchBlackLimit(limit)
        of WatchSharedLimitTarget:
            state.setWatchWhiteLimit(limit)
            state.setWatchBlackLimit(limit)


proc formatPgnElapsed(elapsedMs: int64): string =
    let totalMs = max(0'i64, elapsedMs)
    let totalSec = totalMs div 1000
    let millis = totalMs mod 1000
    let hours = totalSec div 3600
    let minutes = (totalSec mod 3600) div 60
    let seconds = totalSec mod 60
    &"{hours}:{minutes:02d}:{seconds:02d}.{millis:03d}"


proc buildMoveComment(elapsedMs: int64, nodes: Option[uint64] = none(uint64)): string =
    result = &"[%emt {formatPgnElapsed(elapsedMs)}]"
    if nodes.isSome():
        result &= &" [%nodes {nodes.get()}]"


proc resolvePendingPremove(state: AppState): bool =
    if state.pendingPremoves.len == 0:
        return false

    let premove = state.pendingPremoves[0]
    state.pendingPremoves.delete(0)

    var moves = newMoveList()
    state.board.generateMoves(moves)

    var foundMove = nullMove()
    var isPromotion = false
    for move in moves:
        if move.startSquare() == premove.fromSq and move.targetSquare() == premove.toSq:
            if move.isPromotion():
                isPromotion = true
                if state.autoQueen and move.flag().promotionToPiece() == Queen:
                    foundMove = move
                    break
            else:
                foundMove = move
                break

    if foundMove == nullMove() and not isPromotion:
        state.clearPremoves()
        state.setStatus(&"Premove canceled: {premove.fromSq.toUCI()}{premove.toSq.toUCI()}")
        return false

    if isPromotion and not state.autoQueen:
        state.promotionPending = true
        state.promotionFrom = premove.fromSq
        state.promotionTo = premove.toSq
        state.setStatus("Premove ready: choose [Q]ueen / [R]ook / [B]ishop / [N]knight")
        return true

    if foundMove == nullMove():
        state.clearPremoves()
        state.setStatus(&"Premove canceled: {premove.fromSq.toUCI()}{premove.toSq.toUCI()}")
        return false

    let sanStr = state.board.toSAN(foundMove)
    state.lastMove = some((fromSq: foundMove.startSquare(), toSq: foundMove.targetSquare()))
    let applied = state.board.makeMove(foundMove)
    if applied == nullMove():
        state.clearPremoves()
        state.setStatus(&"Premove canceled: {premove.fromSq.toUCI()}{premove.toSq.toUCI()}")
        return false

    state.resetArrowState(clearUserAnnotations = false)
    state.addMoveRecord(foundMove, sanStr)
    state.undoneHistory = @[]
    stdout.write("\a")
    stdout.flushFile()
    onPlayerMove(state, clearQueuedPremoves=false)
    true


proc resetPrimaryEngineState(state: AppState) =
    state.ttable.init()
    state.searcher.histories.clear()
    state.searcher.resetWorkers()
    state.pendingPremoves = @[]


proc initializeWatchEngine(state: AppState) =
    if not state.play.watchMode:
        return

    if state.play.watch.ttable != nil:
        state.play.watch.ttable.destroy()
        dealloc(state.play.watch.ttable)
    state.play.watch.ttable = create(TranspositionTable)
    state.play.watch.ttable[] = newTranspositionTable(state.play.watch.hash * 1024 * 1024)
    state.play.watch.searcher = newSearchManager(state.board.positions, state.play.watch.ttable, evalState=newEvalState(verbose=false))
    if state.play.watch.threads > 1:
        state.play.watch.searcher.setWorkerCount(state.play.watch.threads - 1)
    state.play.watch.initialized = true
    startWatchWorker(state)


proc startWatchWorker*(state: AppState) =
    ## Spawns the second background search thread for watch mode.
    state.play.watch.channels.command.open()
    state.play.watch.channels.response.open()
    var statePtr = create(AppState)
    statePtr[] = state
    createThread(state.play.watch.workerThread, watchWorkerLoop, statePtr)


proc updateGameMetadata(state: AppState) =
    state.play.gameStartFEN = state.board.position.toFEN(state.chess960)
    state.startFEN = state.play.gameStartFEN

    if not state.play.watchMode:
        state.play.lastRematch = PlayRematchConfig(
            available: true,
            startFEN: state.play.gameStartFEN,
            chess960: state.chess960,
            variant: state.play.variant,
            sideSelection: state.play.sideSelection,
            playerLimit: state.play.playerLimit,
            engineLimit: state.play.engineLimit,
            allowTakeback: state.play.allowTakeback,
            allowPonder: state.play.allowPonder
        )

    if state.play.watchMode:
        if state.play.playerLimit == state.play.engineLimit:
            state.play.gameTimeControl = "Engine vs Engine: " & formatConfiguredLimit(state.play.playerLimit)
        else:
            state.play.gameTimeControl =
                "Engine vs Engine: White " & formatConfiguredLimit(state.play.playerLimit) &
                " vs Black " & formatConfiguredLimit(state.play.engineLimit)
    elif state.play.playerLimit == state.play.engineLimit:
        state.play.gameTimeControl = formatConfiguredLimit(state.play.playerLimit)
    else:
        state.play.gameTimeControl = formatConfiguredLimit(state.play.playerLimit) & " vs " & formatConfiguredLimit(state.play.engineLimit)


proc startInitialGamePhase(state: AppState) =
    if state.play.watchMode:
        state.play.phase = EngineTurn
        startEngineTurn(state)
        return

    state.play.phase = if state.board.sideToMove() == state.play.playerColor: PlayerTurn else: EngineTurn
    if state.play.phase == PlayerTurn:
        startTrackedClock(state.play.playerClock, state.play.playerClockMoveStartMs)
        state.setStatus("Your turn!")
    else:
        startTrackedClock(state.play.engineClock, state.play.engineClockMoveStartMs)
        startEngineTurn(state)


proc beginGame*(state: AppState) =
    ## Transitions from setup to active game.
    state.resetPrimaryEngineState()
    state.initializeWatchEngine()
    state.updateGameMetadata()
    state.startInitialGamePhase()


proc startRematch*(state: AppState) =
    ## Starts a fresh game using the last :play configuration.
    if not state.play.lastRematch.available:
        state.setError("No previous :play game to rematch")
        return
    if state.mode == ModeReplay:
        state.setError("Exit replay mode first (:exit)")
        return
    if state.mode == ModePlay and state.play.watchMode:
        state.setError("Rematch is only available for :play games")
        return
    if state.mode == ModePlay and state.play.phase in [PlayerTurn, EngineTurn]:
        state.setError("Cannot start a rematch during an active game")
        return

    let rematch = state.play.lastRematch

    if state.analysis.running:
        stopAnalysis(state)

    state.preparePlaySetup()
    state.play.watchSeparateConfig = false
    state.resetMoveSession()
    state.play.isPondering = false
    state.play.watch.allowPonder = false
    state.play.watch.isPondering = false
    state.play.allowTakeback = rematch.allowTakeback
    state.play.allowPonder = rematch.allowPonder
    state.play.variant = rematch.variant
    state.chess960 = rematch.chess960
    state.play.sideSelection = rematch.sideSelection
    state.searcher.state.chess960.store(state.chess960, moRelaxed)
    state.board = newChessboardFromFEN(rematch.startFEN)
    state.startFEN = rematch.startFEN
    state.play.playerLimit = rematch.playerLimit
    state.play.playerClock = limitClock(state.play.playerLimit)
    state.play.engineLimit = rematch.engineLimit
    state.play.engineClock = limitClock(state.play.engineLimit)

    case rematch.sideSelection:
        of SideWhite:
            state.play.playerColor = White
        of SideBlack:
            state.play.playerColor = Black
        of SideRandom:
            state.play.playerColor = if rand(1) == 0: White else: Black

    state.flipped = state.play.playerColor == Black
    beginGame(state)


proc checkGameOver*(state: AppState): bool =
    if state.play.result.isSome():
        return true

    if state.play.playerLimit.isTimeManaged() and state.play.playerClock.expired:
        let winner = if state.play.playerColor == White: "0-1" else: "1-0"
        state.play.result = some(&"{winner} (time)")
        state.play.phase = GameOver
        state.play.playerClock.stop()
        state.play.engineClock.stop()
        state.setStatus(&"Time forfeit! {winner}")
        return true

    if state.play.engineLimit.isTimeManaged() and state.play.engineClock.expired:
        let winner = if state.play.playerColor == White: "1-0" else: "0-1"
        state.play.result = some(&"{winner} (time)")
        state.play.phase = GameOver
        state.play.playerClock.stop()
        state.play.engineClock.stop()
        state.setStatus(&"Engine flagged! {winner}")
        return true

    var moves = newMoveList()
    state.board.generateMoves(moves)

    if moves.len == 0:
        if state.board.inCheck():
            let winner = if state.board.sideToMove() == White: "0-1" else: "1-0"
            state.play.result = some(&"{winner} (checkmate)")
            state.play.phase = GameOver
            state.play.playerClock.stop()
            state.play.engineClock.stop()
            state.setStatus(&"Checkmate! {winner}")
        else:
            state.play.result = some("1/2-1/2 (stalemate)")
            state.play.phase = GameOver
            state.play.playerClock.stop()
            state.play.engineClock.stop()
            state.setStatus("Stalemate! Draw")
        return true

    if state.board.isInsufficientMaterial():
        state.play.result = some("1/2-1/2 (insufficient material)")
        state.play.phase = GameOver
        state.play.playerClock.stop()
        state.play.engineClock.stop()
        state.setStatus("Draw by insufficient material")
        return true

    if state.board.halfMoveClock() >= 100:
        state.play.result = some("1/2-1/2 (50-move rule)")
        state.play.phase = GameOver
        state.play.playerClock.stop()
        state.play.engineClock.stop()
        state.setStatus("Draw by 50-move rule")
        return true

    if state.board.drawnByRepetition(0):
        state.play.result = some("1/2-1/2 (repetition)")
        state.play.phase = GameOver
        state.play.playerClock.stop()
        state.play.engineClock.stop()
        state.setStatus("Draw by repetition")
        return true

    false


proc startPrimaryPonder(state: AppState, ponderMove: Move, limit: PlayLimitConfig, clock: ChessClock) =
    if ponderMove == nullMove():
        return
    state.play.ponderMove = ponderMove
    let positions = clonePositionsAfterMove(state.board, ponderMove)
    state.sendPrimaryEngineCommand(positions, buildSearchLimits(limit, clock), ponder=true)
    state.play.isPondering = true


proc startWatchPonder(state: AppState, ponderMove: Move) =
    if ponderMove == nullMove():
        return
    state.play.watch.ponderMove = ponderMove
    let positions = clonePositionsAfterMove(state.board, ponderMove)
    state.sendWatchEngineCommand(positions, buildSearchLimits(state.play.engineLimit, state.play.engineClock), ponder=true)
    state.play.watch.isPondering = true


proc stopPrimaryPonder(state: AppState, ponderHit: bool) =
    if not state.play.isPondering:
        return
    if ponderHit:
        state.searcher.stopPondering()
    else:
        state.searcher.cancel()
        discard state.channels.response.recv()
    state.play.isPondering = false


proc stopWatchPonder(state: AppState, ponderHit: bool) =
    if not state.play.watch.isPondering:
        return
    if ponderHit:
        state.play.watch.searcher.stopPondering()
    else:
        state.play.watch.searcher.cancel()
        discard state.play.watch.channels.response.recv()
    state.play.watch.isPondering = false


proc startEngineTurn*(state: AppState) =
    state.play.engineThinking = true

    let positions = clonePositions(state.board)
    let isBlackTurn = state.board.sideToMove() == Black
    let useSecond = state.play.watchMode and state.play.watch.initialized and isBlackTurn

    let limitConfig =
        if state.play.watchMode:
            if useSecond: state.play.engineLimit else: state.play.playerLimit
        else:
            state.play.engineLimit

    var engineLimits: seq[SearchLimit]
    if useSecond:
        startTrackedClock(state.play.engineClock, state.play.engineClockMoveStartMs)
        engineLimits = buildSearchLimits(limitConfig, state.play.engineClock)
        state.sendWatchEngineCommand(positions, engineLimits)
    elif state.play.watchMode:
        startTrackedClock(state.play.playerClock, state.play.playerClockMoveStartMs)
        engineLimits = buildSearchLimits(limitConfig, state.play.playerClock)
        state.sendPrimaryEngineCommand(positions, engineLimits)
    else:
        startTrackedClock(state.play.engineClock, state.play.engineClockMoveStartMs)
        engineLimits = buildSearchLimits(limitConfig, state.play.engineClock)
        state.sendPrimaryEngineCommand(positions, engineLimits)


proc onEngineMoveComplete*(state: AppState) =
    state.play.engineThinking = false

    let wasBlack = state.board.sideToMove() == Black
    let usedSecond = state.play.watchMode and state.play.watch.initialized and wasBlack
    let stats =
        if usedSecond: state.play.watch.searcher.statistics
        else: state.searcher.statistics
    let nodesSearched = stats.nodeCount.load(moRelaxed)

    var elapsedMs = 0'i64
    if usedSecond:
        elapsedMs = state.play.engineClock.finishMove(state.play.engineClockMoveStartMs)
    elif state.play.watchMode:
        elapsedMs = state.play.playerClock.finishMove(state.play.playerClockMoveStartMs)
    else:
        elapsedMs = state.play.engineClock.finishMove(state.play.engineClockMoveStartMs)

    let bestMove = stats.bestMove.load(moRelaxed)
    if bestMove == nullMove():
        state.setStatus("Engine couldn't find a move!")
        state.play.phase = GameOver
        return

    if state.play.watchMode:
        if usedSecond:
            state.stopPrimaryPonder(bestMove == state.play.ponderMove)
        else:
            state.stopWatchPonder(bestMove == state.play.watch.ponderMove)

    let sanStr = state.board.toSAN(bestMove)
    state.lastMove = some((fromSq: bestMove.startSquare(), toSq: bestMove.targetSquare()))

    let applied = state.board.makeMove(bestMove)
    if applied == nullMove():
        state.setStatus("Engine made illegal move!")
        state.play.phase = GameOver
        return

    state.resetArrowState(clearUserAnnotations = false)
    state.addMoveRecord(bestMove, sanStr, buildMoveComment(elapsedMs, some(nodesSearched)))

    if not state.play.watchMode:
        stdout.write("\a")
        stdout.flushFile()

    if checkGameOver(state):
        return

    if state.play.watchMode:
        state.play.phase = EngineTurn
        let justMovedBlack = usedSecond
        if justMovedBlack and state.play.watch.allowPonder:
            state.startWatchPonder(state.play.watch.searcher.previousVariations[0].moves[1])
        elif not justMovedBlack and state.play.allowPonder:
            state.startPrimaryPonder(
                state.searcher.previousVariations[0].moves[1],
                state.play.playerLimit,
                state.play.playerClock
            )
        startEngineTurn(state)
        return

    state.play.phase = PlayerTurn
    startTrackedClock(state.play.playerClock, state.play.playerClockMoveStartMs)
    if resolvePendingPremove(state):
        return
    state.setStatus(&"Engine played {sanStr}. Your turn!")

    if state.play.allowPonder:
        state.startPrimaryPonder(
            state.searcher.previousVariations[0].moves[1],
            state.play.engineLimit,
            state.play.engineClock
        )


proc onPlayerMove*(state: AppState, clearQueuedPremoves = true) =
    if clearQueuedPremoves:
        state.pendingPremoves = @[]
    let elapsedMs = state.play.playerClock.finishMove(state.play.playerClockMoveStartMs)
    if state.moveComments.len > 0:
        state.moveComments[^1] = buildMoveComment(elapsedMs)

    if state.play.isPondering:
        let playerMove = state.moveHistory[^1]
        if playerMove == state.play.ponderMove:
            state.searcher.stopPondering()
            state.play.isPondering = false
            state.play.engineThinking = true
            state.play.phase = EngineTurn
            startTrackedClock(state.play.engineClock, state.play.engineClockMoveStartMs)
            return

        state.stopPrimaryPonder(false)

    if not checkGameOver(state):
        state.play.phase = EngineTurn
        startEngineTurn(state)


proc tickClocks*(state: AppState) =
    if state.mode != ModePlay or state.play.phase in [Setup, GameOver]:
        return
    if state.play.playerLimit.isTimeManaged():
        state.play.playerClock.tick()
    if state.play.engineLimit.isTimeManaged():
        state.play.engineClock.tick()
    discard checkGameOver(state)


proc shutdownWatchEngine*(state: AppState) =
    if not state.play.watch.initialized:
        return

    if state.play.watch.searcher.isSearching():
        state.play.watch.searcher.cancel()
    state.play.watch.channels.command.send(SearchCommand(kind: Shutdown))
    discard state.play.watch.channels.response.recv()
    joinThread(state.play.watch.workerThread)
    state.play.watch.channels.command.close()
    state.play.watch.channels.response.close()
    state.play.watch.searcher.shutdownWorkers()
    if state.play.watch.ttable != nil:
        state.play.watch.ttable.destroy()
        dealloc(state.play.watch.ttable)
        state.play.watch.ttable = nil
    state.play.watch.initialized = false


proc pollWatchSearchResults*(state: AppState) =
    ## Non-blocking poll of watch-engine completion notifications.
    if not state.play.watch.initialized:
        return

    let (hasWatch, watchResp) = state.play.watch.channels.response.tryRecv()
    if not hasWatch:
        return

    case watchResp:
        of SearchComplete:
            if state.play.engineThinking:
                state.play.engineThinking = false
        of Exiting:
            discard


proc exitPlayMode*(state: AppState) =
    if state.play.isPondering or state.play.engineThinking:
        stopSearch(state)
        discard state.channels.response.recv()
        state.play.engineThinking = false
        state.play.isPondering = false
    if state.play.watch.isPondering:
        state.stopWatchPonder(false)
    state.play.playerClock.stop()
    state.play.engineClock.stop()
    state.pendingPremoves = @[]
    state.enterAnalysisMode()
    state.shutdownWatchEngine()
    state.play.watchMode = false
    state.play.watchSeparateConfig = false
    state.setStatus("Exited play mode")
