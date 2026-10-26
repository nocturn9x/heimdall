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
#
# Authored with assistance from AI agents.

## Active play-mode game orchestration and watch/ponder runtime.

import std/[options, random, atomics, strformat]

import heimdall/[board, moves, pieces, movegen, position, search, transpositions, eval]
import heimdall/util/limits
import heimdall/tui/[state, analysis]
import heimdall/tui/play/common
import heimdall/tui/util/clock
import heimdall/tui/util/san
import heimdall/tui/util/uci_client

proc startEngineTurn*(state: AppState)
proc onPlayerMove*(state: AppState, clearQueuedPremoves = true)
proc startWatchWorker*(state: AppState)
proc shutdownWatchEngine*(state: AppState)


proc externalEnginePtr(state: AppState, side: PieceColor): ptr ExternalWatchEngineState =
    if side == White:
        addr state.play.watchWhiteExternal
    else:
        addr state.play.watchBlackExternal


proc externalEngineConfigured(state: AppState, side: PieceColor): bool =
    state.externalEnginePtr(side)[].command.len > 0


proc externalEngineReady(state: AppState, side: PieceColor): bool =
    let engine = state.externalEnginePtr(side)
    engine[].initialized and engine[].client != nil


proc externalEngineCanPonder(state: AppState, side: PieceColor): bool =
    if not state.externalEngineReady(side):
        return false
    state.externalEnginePtr(side)[].client.supportsPonder


proc toUCIEngineLimit(limit: PlayLimitConfig, whiteClock, blackClock: ChessClock): UCIEngineLimit =
    result.hasTime = limit.timeControl.isSome()
    result.whiteTimeMs = whiteClock.remainingMs
    result.blackTimeMs = blackClock.remainingMs
    result.whiteIncrementMs = whiteClock.incrementMs
    result.blackIncrementMs = blackClock.incrementMs
    result.depth = limit.depth
    if limit.nodeLimit.isSome():
        let nodes = limit.nodeLimit.get()
        if nodes.hardNodes.isSome():
            result.nodes = nodes.hardNodes
        elif nodes.softNodes.isSome():
            result.nodes = nodes.softNodes


proc externalWatchWorkerLoop(statePtr: ptr AppState, side: PieceColor) =
    let state = statePtr[]
    dealloc(statePtr)
    let engine = state.externalEnginePtr(side)

    while true:
        let cmd = engine[].channels.command.recv()

        case cmd.kind:
            of Shutdown:
                engine[].client.close()
                engine[].channels.response.send(ExternalSearchResponse(kind: ExternalExiting))
                break

            of StopSearch:
                try:
                    engine[].client.stop()
                except CatchableError:
                    discard

            of StartAnalysis, StartGameAnalysis:
                engine[].channels.response.send(ExternalSearchResponse(
                    kind: ExternalSearchComplete,
                    result: UCIEngineMoveResult(error: "external watch engines do not run analysis")
                ))

            of StartEngineMove:
                let limit = toUCIEngineLimit(cmd.engineLimitConfig, cmd.engineWhiteClock, cmd.engineBlackClock)
                let result = engine[].client.searchBestMove(
                    cmd.enginePositions,
                    limit,
                    cmd.engineChess960,
                    cmd.engineStartFEN,
                    cmd.engineMoveHistory,
                    addr engine[].infoChannel,
                    ponder = cmd.ponder
                )
                engine[].channels.response.send(ExternalSearchResponse(kind: ExternalSearchComplete, result: result))


proc externalWhiteWatchWorkerLoop*(statePtr: ptr AppState) {.thread.} =
    externalWatchWorkerLoop(statePtr, White)


proc externalBlackWatchWorkerLoop*(statePtr: ptr AppState) {.thread.} =
    externalWatchWorkerLoop(statePtr, Black)


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

            of StartGameAnalysis:
                # Whole-game report analysis is only supported on the primary engine.
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


proc sendExternalEngineCommand(
    state: AppState,
    side: PieceColor,
    positions: sink seq[Position],
    limitConfig: PlayLimitConfig,
    whiteClock, blackClock: ChessClock,
    moveHistory: seq[Move] = @[],
    ponder = false
) =
    let history = if moveHistory.len > 0: moveHistory else: state.moveHistory
    let engine = state.externalEnginePtr(side)
    engine[].channels.command.send(SearchCommand(
        kind: StartEngineMove,
        ponder: ponder,
        enginePositions: positions,
        engineLimits: @[],
        engineLimitConfig: limitConfig,
        engineWhiteClock: whiteClock,
        engineBlackClock: blackClock,
        engineChess960: state.chess960,
        engineStartFEN: state.play.gameStartFEN,
        engineMoveHistory: history
    ))


proc setWatchWhiteLimit(state: AppState, limit: PlayLimitConfig) =
    state.play.playerLimit = limit
    state.play.playerClock = limitClock(limit)


proc setWatchBlackLimit(state: AppState, limit: PlayLimitConfig) =
    state.play.engineLimit = limit
    state.play.engineClock = limitClock(limit)


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

    # A resolving premove is the local side moving, so snap the view to the live
    # tip (state.board now aliases liveBoard) before generating/applying the move.
    state.followLiveTip()

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
    state.ttable.init(state.engineThreads)
    state.searcher.histories.clear()
    state.searcher.resetWorkers()
    state.pendingPremoves = @[]


proc applyExternalEngineInfo(state: AppState, info: UCIEngineInfo) =
    if info.positionKey == 0 or info.positionKey != state.board.zobristKey().uint64:
        return

    state.analysis.depth = max(state.analysis.depth, info.depth)
    if info.nodes > 0:
        state.analysis.nodes = info.nodes
    if info.nps > 0:
        state.analysis.nps = info.nps

    if not info.hasScore or info.pv.len == 0:
        return

    let material = state.board.material()
    let rawWhiteScore = if info.sideToMove == Black: -info.score else: info.score
    let displayScore = state.displayScore(rawWhiteScore, material)
    let line = AnalysisLine(
        pv: info.pv,
        score: displayScore,
        rawScore: info.score,
        depth: info.depth
    )

    while state.analysis.lines.len < info.multipv:
        state.analysis.lines.add(AnalysisLine())
    state.analysis.lines[info.multipv - 1] = line
    state.analysis.linesPositionKey = info.positionKey
    state.storeCurrentAnalysisSnapshot()


proc startExternalWatchWorker(state: AppState, side: PieceColor) =
    let engine = state.externalEnginePtr(side)
    # Channel.close frees its storage without clearing the object in Nim 2.2.
    # A subsequent game must start with zeroed channels before opening them.
    reset(engine[].channels)
    reset(engine[].infoChannel)
    engine[].channels.command.open()
    engine[].channels.response.open()
    engine[].infoChannel.open()
    var statePtr = create(AppState)
    statePtr[] = state
    if side == White:
        createThread(engine[].workerThread, externalWhiteWatchWorkerLoop, statePtr)
    else:
        createThread(engine[].workerThread, externalBlackWatchWorkerLoop, statePtr)


proc initializeExternalWatchEngine(state: AppState, side: PieceColor): bool =
    let engine = state.externalEnginePtr(side)
    if engine[].command.len == 0:
        return true

    let started = startUCIClient(engine[].command)
    if started.error.len > 0:
        let label = if side == White: "White" else: "Black"
        state.setStatus(&"{label} UCI engine failed to start: {started.error}", isError=true, persistent=true)
        return false

    engine[].client = started.client
    engine[].name = started.client.name
    engine[].lastResult = UCIEngineMoveResult(bestMove: nullMove(), ponderMove: nullMove())
    engine[].lastInfo = UCIEngineInfo()

    try:
        if state.chess960 and not engine[].client.supportsChess960:
            raise newException(IOError, "engine does not advertise UCI_Chess960")
        if engine[].client.supportsThreads:
            let threads = if side == White: state.engineThreads else: state.play.watch.threads
            engine[].client.setOption("Threads", $threads)
        if engine[].client.supportsHash:
            let hash = if side == White: state.engineHash else: state.play.watch.hash
            engine[].client.setOption("Hash", $hash)
        for option in engine[].options:
            engine[].client.setOption(option.name, option.value)
        if engine[].client.supportsPonder:
            let allowPonder = if side == White: state.play.allowPonder else: state.play.watch.allowPonder
            engine[].client.setOption("Ponder", if allowPonder: "true" else: "false")
        if engine[].client.supportsChess960:
            engine[].client.setOption("UCI_Chess960", if state.chess960: "true" else: "false")
        engine[].client.newGame()
    except CatchableError as e:
        let label = if side == White: "White" else: "Black"
        state.setStatus(&"{label} UCI engine initialization failed: {e.msg}", isError=true, persistent=true)
        engine[].client.close()
        engine[].client = nil
        return false

    engine[].initialized = true
    startExternalWatchWorker(state, side)
    true


proc initializeWatchEngine(state: AppState): bool =
    if not state.play.watchMode:
        return true

    if not state.initializeExternalWatchEngine(White):
        return false
    if not state.initializeExternalWatchEngine(Black):
        return false

    if state.externalEngineConfigured(Black):
        state.play.watch.initialized = false
        return true

    state.play.watch.ttable = newTranspositionTable(state.play.watch.hash * 1024 * 1024, state.play.watch.threads)
    state.play.watch.searcher = newSearchManager(state.play.liveBoard.positions, state.play.watch.ttable, evalState=newEvalState(verbose=false))
    if state.play.watch.threads > 1:
        state.play.watch.searcher.setWorkerCount(state.play.watch.threads - 1)
    state.play.watch.initialized = true
    startWatchWorker(state)
    true


proc startWatchWorker*(state: AppState) =
    ## Spawns the second background search thread for watch mode.
    reset(state.play.watch.channels)
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
    # The live game is the authoritative board the engine(s) play on. state.board is
    # only the rendered view; while at the tip it aliases liveBoard so that locally
    # entered moves land on the live game. Collapse any prior position stack to the
    # chosen starting position so liveBoard.positions stays in step with moveHistory.
    state.play.liveBoard = newChessboard(@[state.board.position.clone()])
    state.board = state.play.liveBoard
    state.play.viewPly = 0
    if not state.initializeWatchEngine():
        state.shutdownWatchEngine()
        state.play.phase = Setup
        return
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

    if state.play.liveBoard == nil:
        return false
    let live = state.play.liveBoard

    var moves = newMoveList()
    live.generateMoves(moves)

    if moves.len == 0:
        if live.inCheck():
            let winner = if live.sideToMove() == White: "0-1" else: "1-0"
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

    if live.isInsufficientMaterial():
        state.play.result = some("1/2-1/2 (insufficient material)")
        state.play.phase = GameOver
        state.play.playerClock.stop()
        state.play.engineClock.stop()
        state.setStatus("Draw by insufficient material")
        return true

    if live.halfMoveClock() >= 100:
        state.play.result = some("1/2-1/2 (50-move rule)")
        state.play.phase = GameOver
        state.play.playerClock.stop()
        state.play.engineClock.stop()
        state.setStatus("Draw by 50-move rule")
        return true

    if live.drawnByRepetition(0):
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
    if state.play.watchMode and state.externalEngineReady(White):
        if not state.externalEngineCanPonder(White):
            return
        let engine = state.externalEnginePtr(White)
        engine[].ponderMove = ponderMove
        engine[].isPondering = true
        state.play.ponderMove = ponderMove
        state.play.isPondering = true
        var moveHistory = state.moveHistory
        moveHistory.add(ponderMove)
        let positions = clonePositionsAfterMove(state.play.liveBoard, ponderMove)
        state.sendExternalEngineCommand(
            White,
            positions,
            limit,
            state.play.playerClock,
            state.play.engineClock,
            moveHistory,
            ponder = true
        )
        return
    state.play.ponderMove = ponderMove
    let positions = clonePositionsAfterMove(state.play.liveBoard, ponderMove)
    state.sendPrimaryEngineCommand(positions, buildSearchLimits(limit, clock), ponder=true)
    state.play.isPondering = true


proc startWatchPonder(state: AppState, ponderMove: Move) =
    if ponderMove == nullMove():
        return
    if state.externalEngineReady(Black):
        if not state.externalEngineCanPonder(Black):
            return
        let engine = state.externalEnginePtr(Black)
        engine[].ponderMove = ponderMove
        engine[].isPondering = true
        state.play.watch.ponderMove = ponderMove
        state.play.watch.isPondering = true
        var moveHistory = state.moveHistory
        moveHistory.add(ponderMove)
        let positions = clonePositionsAfterMove(state.play.liveBoard, ponderMove)
        state.sendExternalEngineCommand(
            Black,
            positions,
            state.play.engineLimit,
            state.play.playerClock,
            state.play.engineClock,
            moveHistory,
            ponder = true
        )
        return
    state.play.watch.ponderMove = ponderMove
    let positions = clonePositionsAfterMove(state.play.liveBoard, ponderMove)
    state.sendWatchEngineCommand(positions, buildSearchLimits(state.play.engineLimit, state.play.engineClock), ponder=true)
    state.play.watch.isPondering = true


proc stopPrimaryPonder(state: AppState, ponderHit: bool): bool =
    if state.play.watchMode and state.externalEngineReady(White):
        let engine = state.externalEnginePtr(White)
        if not engine[].isPondering:
            return false
        if ponderHit:
            try:
                engine[].client.ponderHit()
            except CatchableError:
                discard
        else:
            try:
                engine[].client.stop()
            except CatchableError:
                discard
            discard engine[].channels.response.recv()
        engine[].isPondering = false
        state.play.isPondering = false
        return ponderHit

    if not state.play.isPondering:
        return false
    if ponderHit:
        state.searcher.stopPondering()
    else:
        state.searcher.cancel()
        discard state.channels.response.recv()
    state.play.isPondering = false
    return ponderHit


proc stopWatchPonder(state: AppState, ponderHit: bool): bool =
    if state.externalEngineReady(Black):
        let engine = state.externalEnginePtr(Black)
        if not engine[].isPondering:
            return false
        if ponderHit:
            try:
                engine[].client.ponderHit()
            except CatchableError:
                discard
        else:
            try:
                engine[].client.stop()
            except CatchableError:
                discard
            discard engine[].channels.response.recv()
        engine[].isPondering = false
        state.play.watch.isPondering = false
        return ponderHit

    if not state.play.watch.isPondering:
        return false
    if ponderHit:
        state.play.watch.searcher.stopPondering()
    else:
        state.play.watch.searcher.cancel()
        discard state.play.watch.channels.response.recv()
    state.play.watch.isPondering = false
    return ponderHit


proc startEngineTurn*(state: AppState) =
    state.play.engineThinking = true

    let positions = clonePositions(state.play.liveBoard)
    let side = state.play.liveBoard.sideToMove()
    let isBlackTurn = side == Black
    let useExternal = state.play.watchMode and state.externalEngineReady(side)
    let useSecond = state.play.watchMode and state.play.watch.initialized and isBlackTurn

    if state.play.watchMode:
        state.clearAnalysisDisplay()

    let limitConfig =
        if state.play.watchMode:
            if isBlackTurn: state.play.engineLimit else: state.play.playerLimit
        else:
            state.play.engineLimit

    var engineLimits: seq[SearchLimit]
    if useExternal:
        if isBlackTurn:
            startTrackedClock(state.play.engineClock, state.play.engineClockMoveStartMs)
        else:
            startTrackedClock(state.play.playerClock, state.play.playerClockMoveStartMs)
        state.sendExternalEngineCommand(side, positions, limitConfig, state.play.playerClock, state.play.engineClock)
    elif useSecond:
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

    let live = state.play.liveBoard
    let mover = live.sideToMove()
    let wasBlack = mover == Black
    let usedExternal = state.play.watchMode and state.externalEngineReady(mover)
    let usedSecond = state.play.watchMode and state.play.watch.initialized and wasBlack

    var elapsedMs = 0'i64
    if usedSecond:
        elapsedMs = state.play.engineClock.finishMove(state.play.engineClockMoveStartMs)
    elif state.play.watchMode and wasBlack:
        elapsedMs = state.play.engineClock.finishMove(state.play.engineClockMoveStartMs)
    elif state.play.watchMode:
        elapsedMs = state.play.playerClock.finishMove(state.play.playerClockMoveStartMs)
    else:
        elapsedMs = state.play.engineClock.finishMove(state.play.engineClockMoveStartMs)

    let externalResult =
        if usedExternal:
            state.externalEnginePtr(mover)[].lastResult
        else:
            UCIEngineMoveResult(bestMove: nullMove(), ponderMove: nullMove())
    let bestMove =
        if usedExternal:
            externalResult.bestMove
        elif usedSecond:
            state.play.watch.searcher.statistics.bestMove.load(moRelaxed)
        else:
            state.searcher.statistics.bestMove.load(moRelaxed)
    if bestMove == nullMove():
        if usedExternal and externalResult.error.len > 0:
            state.play.result = some("* (external engine error)")
            state.setStatus(&"External engine error: {externalResult.error}", isError=true)
        else:
            state.play.result = some("* (no legal engine move)")
            state.setStatus("Engine couldn't find a move!")
        state.play.phase = GameOver
        return

    var promotedPonder = false
    if state.play.watchMode:
        if wasBlack:
            let expected =
                if state.externalEngineReady(White):
                    state.externalEnginePtr(White)[].ponderMove
                else:
                    state.play.ponderMove
            promotedPonder = state.stopPrimaryPonder(bestMove == expected)
        else:
            let expected =
                if state.externalEngineReady(Black):
                    state.externalEnginePtr(Black)[].ponderMove
                else:
                    state.play.watch.ponderMove
            promotedPonder = state.stopWatchPonder(bestMove == expected)

    let sanStr = live.toSAN(bestMove)
    # Whether the user is currently watching the live position. If so, the view
    # follows this move; if they have scrolled back into history, the live game
    # advances underneath while the rendered board stays frozen (à la Lichess).
    let wasAtTip = state.atLiveTip()

    let applied = live.makeMove(bestMove)
    if applied == nullMove():
        state.play.result = some("* (illegal engine move)")
        state.setStatus("Engine made illegal move!")
        state.play.phase = GameOver
        return

    state.resetArrowState(clearUserAnnotations = false)
    let nodesSearched =
        if usedExternal:
            externalResult.nodes
        elif usedSecond:
            state.play.watch.searcher.statistics.nodeCount.load(moRelaxed)
        else:
            state.searcher.statistics.nodeCount.load(moRelaxed)
    let nodeComment = if nodesSearched > 0'u64: some(nodesSearched) else: none(uint64)
    state.addMoveRecord(bestMove, sanStr, buildMoveComment(elapsedMs, nodeComment))
    if wasAtTip:
        state.followLiveTip()

    if not state.play.watchMode:
        stdout.write("\a")
        stdout.flushFile()

    if checkGameOver(state):
        return

    if state.play.watchMode:
        state.play.phase = EngineTurn
        let justMovedBlack = wasBlack
        let ponderMove =
            if usedExternal:
                externalResult.ponderMove
            elif usedSecond:
                state.play.watch.searcher.previousVariations[0].moves[1]
            else:
                state.searcher.previousVariations[0].moves[1]
        if justMovedBlack and state.play.watch.allowPonder:
            state.startWatchPonder(ponderMove)
        elif not justMovedBlack and state.play.allowPonder:
            state.startPrimaryPonder(
                ponderMove,
                state.play.playerLimit,
                state.play.playerClock
            )
        if promotedPonder:
            if live.sideToMove() == Black:
                startTrackedClock(state.play.engineClock, state.play.engineClockMoveStartMs)
            else:
                startTrackedClock(state.play.playerClock, state.play.playerClockMoveStartMs)
            state.play.engineThinking = true
        else:
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
    # The local move has been applied to the live board; keep the view following it.
    state.followLiveTip()
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

        discard state.stopPrimaryPonder(false)

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
    for side in [White, Black]:
        let engine = state.externalEnginePtr(side)
        if engine[].initialized:
            try:
                engine[].client.stop()
            except CatchableError:
                discard
            engine[].channels.command.send(SearchCommand(kind: Shutdown))
            while true:
                let response = engine[].channels.response.recv()
                if response.kind == ExternalExiting:
                    break
            joinThread(engine[].workerThread)
            # Release PV sequences still queued when a search was stopped.
            while true:
                let (hasInfo, _) = engine[].infoChannel.tryRecv()
                if not hasInfo:
                    break
            engine[].channels.command.close()
            engine[].channels.response.close()
            engine[].infoChannel.close()
            engine[].client = nil
            engine[].initialized = false
            engine[].isPondering = false

    if not state.play.watch.initialized:
        return

    if state.play.watch.searcher.isSearching():
        state.play.watch.searcher.cancel()
    state.play.watch.channels.command.send(SearchCommand(kind: Shutdown))
    while true:
        let response = state.play.watch.channels.response.recv()
        if response == Exiting:
            break
    joinThread(state.play.watch.workerThread)
    state.play.watch.channels.command.close()
    state.play.watch.channels.response.close()
    state.play.watch.searcher.shutdownWorkers()
    state.play.watch.ttable = nil
    state.play.watch.initialized = false


proc pollWatchSearchResults*(state: AppState) =
    ## Non-blocking poll of watch-engine completion notifications.
    for side in [White, Black]:
        let engine = state.externalEnginePtr(side)
        if engine[].initialized:
            while true:
                let (hasInfo, info) = engine[].infoChannel.tryRecv()
                if not hasInfo:
                    break
                engine[].lastInfo = info
                state.applyExternalEngineInfo(info)

            let (hasExternal, response) = engine[].channels.response.tryRecv()
            if hasExternal:
                case response.kind:
                    of ExternalSearchComplete:
                        engine[].lastResult = response.result
                        if engine[].isPondering:
                            engine[].isPondering = false
                            if side == White:
                                state.play.isPondering = false
                            else:
                                state.play.watch.isPondering = false
                        elif state.play.engineThinking:
                            state.play.engineThinking = false
                    of ExternalExiting:
                        discard

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
    if state.play.engineThinking:
        let side =
            if state.play.liveBoard != nil:
                state.play.liveBoard.sideToMove()
            else:
                state.board.sideToMove()
        if state.play.watchMode and state.externalEngineReady(side):
            let engine = state.externalEnginePtr(side)
            try:
                engine[].client.stop()
            except CatchableError:
                discard
            discard engine[].channels.response.recv()
        elif state.play.watchMode and side == Black and state.play.watch.initialized:
            state.play.watch.searcher.cancel()
            discard state.play.watch.channels.response.recv()
        else:
            stopSearch(state)
            discard state.channels.response.recv()
        state.play.engineThinking = false
    if state.play.isPondering:
        discard state.stopPrimaryPonder(false)
        state.play.isPondering = false
    if state.play.watch.isPondering:
        discard state.stopWatchPonder(false)
    state.play.playerClock.stop()
    state.play.engineClock.stop()
    state.pendingPremoves = @[]
    # If the user exits while browsing history, restore the full live game so
    # analysis continues from the final position rather than a frozen snapshot.
    if state.play.liveBoard != nil:
        state.board = state.play.liveBoard
        state.play.viewPly = state.moveHistory.len
    state.enterAnalysisMode()
    state.shutdownWatchEngine()
    state.play.watchMode = false
    state.play.watchSeparateConfig = false
    state.setStatus("Exited play mode")
