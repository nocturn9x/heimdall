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

## Central application state for the TUI

import std/[options, monotimes, times, strformat]

import illwill
import heimdall/[board, moves, pieces, eval, search, transpositions, movegen]
import heimdall/util/limits


type
    AppState* = ref AppStateObj

    AnalysisPromptKind* = enum
        AnalysisPromptMateLimit

    TUIMode* = enum
        ModeAnalysis    ## Free position analysis
        ModePlay        ## Playing against the engine
        ModeReplay      ## Stepping through a loaded PGN

    PlayPhase* = enum
        Setup           ## Choosing side, time control, variant
        PlayerTurn      ## Waiting for player input
        EngineTurn      ## Engine is thinking
        GameOver        ## Game ended

    ChessVariant* = enum
        Standard
        FischerRandom
        DoubleFischerRandom

    PlaySideSelection* = enum
        SideWhite
        SideBlack
        SideRandom

    TimeControlConfig* = object
        timeMs*: int64
        incrementMs*: int64

    NodeLimitConfig* = object
        softNodes*: Option[uint64]
        hardNodes*: Option[uint64]

    PlayLimitConfig* = object
        timeControl*: Option[TimeControlConfig]
        depth*: Option[int]
        nodeLimit*: Option[NodeLimitConfig]

    PlayRematchConfig* = object
        available*: bool
        startFEN*: string
        chess960*: bool
        variant*: ChessVariant
        sideSelection*: PlaySideSelection
        playerLimit*: PlayLimitConfig
        engineLimit*: PlayLimitConfig
        allowTakeback*: bool
        allowPonder*: bool

    SetupLimitTarget* = enum
        EngineLimitTarget
        WatchWhiteLimitTarget
        WatchBlackLimitTarget
        WatchSharedLimitTarget

    PlaySetupKind* = enum
        SetupChooseVariant
        SetupChooseSide
        SetupChoosePlayerTime
        SetupChooseLimit
        SetupChooseSoftNodesHardLimit
        SetupChooseTakeback
        SetupChoosePonder
        SetupChooseWatchSeparate
        SetupChooseWatchThreads
        SetupChooseWatchHash
        SetupChooseWatchBlackThreads
        SetupChooseWatchBlackHash
        SetupChooseWatchPonder
        SetupChooseWatchWhitePonder
        SetupChooseWatchBlackPonder

    LimitSetupConfig* = tuple[
        target: SetupLimitTarget,
        allowSame: bool,
        sameLimit: PlayLimitConfig,
        invalidExamples: string
    ]

    SoftNodeSetupStage* = enum
        SoftNodeAskHardCap
        SoftNodeEnterHardCap

    SoftNodeSetupConfig* = tuple[target: SetupLimitTarget, limit: PlayLimitConfig, stage: SoftNodeSetupStage]

    PlaySetupState* = object
        case kind*: PlaySetupKind:
            of SetupChooseLimit:
                limitConfig*: LimitSetupConfig
            of SetupChooseSoftNodesHardLimit:
                softNodeConfig*: SoftNodeSetupConfig
            else:
                discard

    AnalysisLine* = object
        pv*: seq[Move]
        score*: Score       # Normalized, white-relative (for display)
        rawScore*: Score    # Raw STM-relative (for WDL computation)
        depth*: int

    ArrowBrush* = enum
        ArrowGreen
        ArrowRed
        ArrowBlue
        ArrowYellow
        ArrowThreat

    BoardArrow* = object
        fromSq*: Square
        toSq*: Square
        brush*: ArrowBrush

    UndoneMove* = tuple[move: Move, san: string, comment: string, arrows: seq[BoardArrow]]

    Premove* = tuple[fromSq, toSq: Square]

    ChessClock* = object
        remainingMs*: int64
        incrementMs*: int64
        lastTick*: MonoTime
        running*: bool
        expired*: bool

    SearchAction* = enum
        StartAnalysis
        StartEngineMove
        StopSearch
        Shutdown

    SearchCommand* = object
        case kind*: SearchAction:
            of StartAnalysis:
                analysisPositions*: seq[Position]
                analysisVariations*: int
                analysisLimits*: seq[SearchLimit]
                analysisMateDepth*: Option[int]
            of StartEngineMove:
                enginePositions*: seq[Position]
                engineLimits*: seq[SearchLimit]
                ponder*: bool       # Search in ponder mode (limits disabled until ponderhit)
            of StopSearch, Shutdown:
                discard

    SearchResponse* = enum
        SearchComplete
        Exiting

    InputState* = object
        buffer*: string
        cursorPos*: int
        statusMessage*: string
        statusIsError*: bool
        statusExpiry*: MonoTime
        statusPersistent*: bool
        helpVisible*: bool
        helpScroll*: int
        acSuggestions*: seq[tuple[cmd, desc: string]]
        acSelected*: Option[int]
        acActive*: bool

    AnalysisState* = object
        running*: bool
        multiPV*: int
        lines*: seq[AnalysisLine]
        linesPositionKey*: uint64
        depth*: int
        nps*: uint64
        nodes*: uint64
        depthLimit*: Option[int]
        mateLimit*: Option[int]
        prompt*: Option[AnalysisPromptKind]

    ReplayState* = object
        moveIndex*: int
        moves*: seq[Move]
        sanHistory*: seq[string]
        startPosition*: Option[Position]
        tags*: seq[tuple[name, value: string]]
        result*: string

    BoardSetupState* = object
        active*: bool
        spawnPiece*: Option[Piece]
        resumeAnalysis*: bool

    BoardRenderCache* = object
        lastBoardHash*: uint64
        lastEngineArrowHash*: uint64
        lastUserArrowHash*: uint64
        lastDragHash*: uint64
        lastDragPiece*: Piece
        lastDragPieceSize*: int
        displayedEngineArrows*: seq[Move]
        lastEngineArrowSourceHash*: uint64
        lastEngineArrowRefresh*: MonoTime
        boardImageVisible*: bool
        engineArrowImageVisible*: bool
        userArrowImageVisible*: bool
        dragImageVisible*: bool
        activeBoardSlot*: Option[int]

    TerminalRenderCache* = object
        prevW*: int
        prevH*: int
        persistentTb*: TerminalBuffer

    WatchEngineState* = object
        searcher*: SearchManager
        ttable*: ptr TranspositionTable
        threads*: int
        hash*: uint64
        allowPonder*: bool
        initialized*: bool
        isPondering*: bool
        ponderMove*: Move
        workerThread*: Thread[ptr AppState]
        channels*: tuple[command: Channel[SearchCommand], response: Channel[SearchResponse]]

    PlayState* = object
        phase*: PlayPhase
        setup*: PlaySetupState
        variant*: ChessVariant
        sideSelection*: PlaySideSelection
        playerColor*: PieceColor
        playerLimit*: PlayLimitConfig
        playerClock*: ChessClock
        playerClockMoveStartMs*: int64
        engineLimit*: PlayLimitConfig
        engineClock*: ChessClock
        engineClockMoveStartMs*: int64
        engineThinking*: bool
        result*: Option[string]
        watchMode*: bool
        watchSeparateConfig*: bool
        allowTakeback*: bool
        allowPonder*: bool
        lastRematch*: PlayRematchConfig
        isPondering*: bool
        ponderMove*: Move
        gameStartFEN*: string
        gameTimeControl*: string
        watch*: WatchEngineState

    AppStateObj = object
        mode*: TUIMode
        board*: Chessboard
        moveHistory*: seq[Move]
        sanHistory*: seq[string]
        moveComments*: seq[string]
        startFEN*: string
        flipped*: bool
        chess960*: bool
        selectedSquare*: Option[Square]
        dragSourceSquare*: Option[Square]      # Source square of an in-progress mouse drag
        dragCursor*: Option[tuple[x, y: int]]  # Board-image pixel position of the dragged piece
        arrowDrawSourceSquare*: Option[Square] # Source square of an in-progress user arrow
        arrowDrawTargetSquare*: Option[Square] # Current target square of an in-progress user arrow
        arrowDrawBrush*: ArrowBrush            # Brush for an in-progress user arrow
        userArrowHistory*: seq[seq[BoardArrow]] # User-drawn board arrows, keyed by current ply
        highlightedSquares*: seq[Square]       # User-highlighted board squares
        pendingPremoves*: seq[Premove]
        boardSetup*: BoardSetupState
        legalDestinations*: seq[Square]
        lastMove*: Option[tuple[fromSq, toSq: Square]]
        undoneHistory*: seq[UndoneMove]  # for redo via Right arrow
        input*: InputState
        shouldQuit*: bool
        showThreats*: bool          # Threat highlighting toggle (off by default)
        showEngineArrows*: bool     # Best-move arrow overlay toggle (off by default)
        ctrlDPending*: bool         # Waiting for second Ctrl+D to confirm exit
        autoQueen*: bool            # Auto-promote to queen (toggle with q)
        promotionPending*: bool     # Waiting for user to choose promotion piece
        promotionFrom*: Square      # Source square of pending promotion
        promotionTo*: Square        # Target square of pending promotion
        analysis*: AnalysisState

        # Play mode
        play*: PlayState

        # PGN replay
        replay*: ReplayState

        # Board renderer cache / uploaded image state
        boardRender*: BoardRenderCache
        terminalRender*: TerminalRenderCache

        # Engine config
        engineThreads*: int
        engineHash*: uint64

        # Search integration
        searcher*: SearchManager
        ttable*: ptr TranspositionTable
        searchWorkerThread*: Thread[ptr AppState]
        channels*: tuple[command: Channel[SearchCommand], response: Channel[SearchResponse]]
        pvChannel*: Channel[seq[AnalysisLine]]


const DEFAULT_START_FEN* = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"


proc `==`*(a, b: PlayLimitConfig): bool =
    a.timeControl == b.timeControl and
    a.depth == b.depth and
    a.nodeLimit == b.nodeLimit


proc newAppState*: AppState =
    new(result)
    result.mode = ModeAnalysis
    result.board = newDefaultChessboard()
    result.startFEN = DEFAULT_START_FEN
    result.analysis.multiPV = 1
    result.autoQueen = true
    result.input.acSelected = none(int)
    result.dragSourceSquare = none(Square)
    result.dragCursor = none(tuple[x, y: int])
    result.arrowDrawSourceSquare = none(Square)
    result.arrowDrawTargetSquare = none(Square)
    result.arrowDrawBrush = ArrowGreen
    result.userArrowHistory = @[@[]]
    result.pendingPremoves = @[]
    result.highlightedSquares = @[]
    result.input.helpScroll = 0
    result.boardSetup.spawnPiece = none(Piece)
    result.boardRender.lastDragPiece = nullPiece()
    result.boardRender.activeBoardSlot = none(int)
    result.boardRender.lastEngineArrowRefresh = getMonoTime() - initDuration(milliseconds = 1000)
    result.engineThreads = 1
    result.engineHash = 64
    result.analysis.prompt = none(AnalysisPromptKind)
    result.play.playerLimit = PlayLimitConfig()
    result.play.engineLimit = PlayLimitConfig()
    result.play.phase = Setup
    result.play.setup = PlaySetupState(kind: SetupChooseVariant)
    result.play.sideSelection = SideRandom
    result.play.watch.hash = 64
    result.play.watch.threads = 1
    result.ttable = create(TranspositionTable)
    result.ttable[] = newTranspositionTable(result.engineHash * 1024 * 1024)
    result.searcher = newSearchManager(result.board.positions, result.ttable, evalState=newEvalState(verbose=false))
    result.channels.command.open()
    result.channels.response.open()
    result.pvChannel.open()


proc ensureUserArrowHistory(state: AppState) =
    let neededEntries = max(1, state.moveHistory.len + 1)
    if state.userArrowHistory.len < neededEntries:
        state.userArrowHistory.setLen(neededEntries)
    elif state.userArrowHistory.len == 0:
        state.userArrowHistory = @[@[]]


proc currentUserArrows*(state: AppState): seq[BoardArrow] =
    state.ensureUserArrowHistory()
    result = state.userArrowHistory[state.moveHistory.len]


proc setCurrentUserArrows(state: AppState, arrows: sink seq[BoardArrow]) =
    state.ensureUserArrowHistory()
    state.userArrowHistory[state.moveHistory.len] = arrows


proc clearStoredUserArrows(state: AppState) =
    state.userArrowHistory = newSeq[seq[BoardArrow]](max(1, state.moveHistory.len + 1))


proc addMoveRecord*(state: AppState, move: Move, san: string, comment: string = "") =
    state.ensureUserArrowHistory()
    state.moveHistory.add(move)
    state.sanHistory.add(san)
    state.moveComments.add(comment)
    state.userArrowHistory.setLen(state.moveHistory.len + 1)


proc popMoveRecord*(state: AppState): UndoneMove =
    state.ensureUserArrowHistory()
    result.move = state.moveHistory.pop()
    result.san = state.sanHistory.pop()
    result.comment = state.moveComments.pop()
    result.arrows =
        if state.userArrowHistory.len > 1:
            state.userArrowHistory.pop()
        else:
            @[]


proc clearMoveRecords*(state: AppState) =
    state.moveHistory = @[]
    state.sanHistory = @[]
    state.moveComments = @[]
    state.undoneHistory = @[]
    state.userArrowHistory = @[@[]]


proc resetArrowState*(state: AppState, clearUserAnnotations = true)


proc syncLastMoveFromHistory*(state: AppState) =
    if state.moveHistory.len > 0:
        let move = state.moveHistory[^1]
        state.lastMove = some((fromSq: move.startSquare(), toSq: move.targetSquare()))
    else:
        state.lastMove = none(tuple[fromSq, toSq: Square])


proc undoLastRecordedMove*(state: AppState): bool =
    if state.moveHistory.len == 0:
        return false

    let lastRecord = state.popMoveRecord()
    state.board.unmakeMove()
    state.undoneHistory.add(lastRecord)
    state.resetArrowState(clearUserAnnotations = false)
    if state.mode == ModeReplay and state.replay.moveIndex > 0:
        dec state.replay.moveIndex
    state.syncLastMoveFromHistory()
    true


proc redoUndoneMove*(state: AppState): bool =
    if state.undoneHistory.len == 0:
        return false

    let (move, san, comment, arrows) = state.undoneHistory.pop()
    state.lastMove = some((fromSq: move.startSquare(), toSq: move.targetSquare()))
    discard state.board.makeMove(move)
    state.resetArrowState(clearUserAnnotations = false)
    state.addMoveRecord(move, san, comment)
    state.setCurrentUserArrows(arrows)
    true


const STATUS_DURATION* = initDuration(seconds = 3)


proc setStatus*(state: AppState, msg: string, isError: bool = false, persistent: bool = false) =
    state.input.statusMessage = msg
    state.input.statusIsError = isError
    state.input.statusPersistent = persistent
    if persistent:
        state.input.statusExpiry = MonoTime.high()
    else:
        state.input.statusExpiry = getMonoTime() + STATUS_DURATION


proc setError*(state: AppState, msg: string) =
    state.setStatus(msg, isError = true)


proc dismissStatus*(state: AppState) =
    ## Clears a persistent status message
    if state.input.statusPersistent:
        state.input.statusMessage = ""
        state.input.statusPersistent = false


proc queuePremove*(state: AppState, fromSq, toSq: Square) =
    state.pendingPremoves.add((fromSq: fromSq, toSq: toSq))
    state.setStatus(&"Queued premove #{state.pendingPremoves.len}: {fromSq.toUCI()}{toSq.toUCI()}")


proc clearPremoves*(state: AppState, statusMessage = "") =
    state.pendingPremoves = @[]
    if statusMessage.len > 0:
        state.setStatus(statusMessage)


proc clearUserArrows*(state: AppState) =
    state.setCurrentUserArrows(@[])
    state.arrowDrawSourceSquare = none(Square)
    state.arrowDrawTargetSquare = none(Square)
    state.arrowDrawBrush = ArrowGreen


proc clearHighlightedSquares*(state: AppState) =
    state.highlightedSquares = @[]


proc clearUserAnnotations*(state: AppState) =
    state.clearStoredUserArrows()
    state.arrowDrawSourceSquare = none(Square)
    state.arrowDrawTargetSquare = none(Square)
    state.arrowDrawBrush = ArrowGreen
    state.clearHighlightedSquares()


proc resetArrowState*(state: AppState, clearUserAnnotations = true) =
    if clearUserAnnotations:
        state.clearUserAnnotations()
    state.boardRender.displayedEngineArrows = @[]
    state.boardRender.lastEngineArrowSourceHash = 0
    state.boardRender.lastEngineArrowRefresh = getMonoTime() - initDuration(milliseconds = 1000)
    state.boardRender.lastEngineArrowHash = 0
    state.boardRender.lastUserArrowHash = 0
    state.analysis.linesPositionKey = 0


proc resetSquareSelection*(state: AppState) =
    state.selectedSquare = none(Square)
    state.dragSourceSquare = none(Square)
    state.dragCursor = none(tuple[x, y: int])
    state.legalDestinations = @[]


proc resetBoardSetupState*(state: AppState) =
    state.boardSetup.active = false
    state.boardSetup.spawnPiece = none(Piece)
    state.boardSetup.resumeAnalysis = false


proc resetPromotionState*(state: AppState) =
    state.promotionPending = false


proc resetMoveSession*(state: AppState) =
    state.clearMoveRecords()
    state.lastMove = none(tuple[fromSq, toSq: Square])
    state.pendingPremoves = @[]
    state.resetArrowState()
    state.resetSquareSelection()
    state.resetPromotionState()


proc clearAnalysisPrompt*(state: AppState) =
    state.analysis.prompt = none(AnalysisPromptKind)


proc beginMateFinderPrompt*(state: AppState) =
    state.analysis.prompt = some(AnalysisPromptMateLimit)
    let currentLimit =
        if state.analysis.mateLimit.isSome():
            &", current: {state.analysis.mateLimit.get()}"
        else:
            ""
    state.setStatus(&"Mate finder depth in moves (1-255{currentLimit}; type none to clear):", persistent=true)


proc preparePlaySetup*(state: AppState, watchMode = false) =
    state.mode = ModePlay
    state.play.watchMode = watchMode
    state.play.watchSeparateConfig = false
    state.clearAnalysisPrompt()
    state.resetBoardSetupState()
    state.clearUserAnnotations()
    state.pendingPremoves = @[]
    state.resetSquareSelection()
    state.resetPromotionState()
    state.play.phase = Setup
    state.play.setup = PlaySetupState(kind: SetupChooseVariant)
    state.play.result = none(string)


proc enterAnalysisMode*(state: AppState) =
    state.mode = ModeAnalysis
    state.play.phase = Setup
    state.play.watchMode = false
    state.play.watchSeparateConfig = false
    state.play.result = none(string)
    state.clearAnalysisPrompt()
    state.resetBoardSetupState()
    state.pendingPremoves = @[]
    state.clearUserAnnotations()
    state.resetSquareSelection()
    state.resetPromotionState()


proc enterReplayMode*(state: AppState) =
    state.mode = ModeReplay
    state.clearAnalysisPrompt()
    state.resetBoardSetupState()
    state.resetMoveSession()


proc toggleUserArrow*(state: AppState, fromSq, toSq: Square, brush: ArrowBrush) =
    state.ensureUserArrowHistory()
    for i, arrow in state.userArrowHistory[state.moveHistory.len]:
        if arrow.fromSq == fromSq and arrow.toSq == toSq:
            if arrow.brush == brush:
                state.userArrowHistory[state.moveHistory.len].delete(i)
            else:
                state.userArrowHistory[state.moveHistory.len][i].brush = brush
            return
    state.userArrowHistory[state.moveHistory.len].add(BoardArrow(fromSq: fromSq, toSq: toSq, brush: brush))


proc toggleHighlightedSquare*(state: AppState, sq: Square) =
    for i, highlightedSq in state.highlightedSquares:
        if highlightedSq == sq:
            state.highlightedSquares.delete(i)
            return
    state.highlightedSquares.add(sq)


proc removeLatestPremoveAtSquare*(state: AppState, sq: Square): bool =
    if state.pendingPremoves.len == 0:
        return false
    for i in countdown(state.pendingPremoves.high, 0):
        let premove = state.pendingPremoves[i]
        if premove.fromSq == sq or premove.toSq == sq:
            state.pendingPremoves.delete(i)
            if state.pendingPremoves.len == 0:
                state.setStatus("Premoves cleared")
            else:
                state.setStatus(&"Removed premove on {sq.toUCI()} ({state.pendingPremoves.len} queued)")
            return true
    false


proc cleanup*(state: AppState) =
    state.channels.command.close()
    state.channels.response.close()
    state.pvChannel.close()
    if state.ttable != nil:
        state.ttable.destroy()
        dealloc(state.ttable)
        state.ttable = nil
