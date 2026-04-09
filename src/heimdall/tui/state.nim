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

## Central application state for the TUI

import std/[options, monotimes, times, strformat]

import heimdall/[board, moves, pieces, eval, search, transpositions]
import heimdall/util/limits


type
    UndoneMove* = tuple[move: Move, san: string, comment: string]

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

    PlayLimitKind* = enum
        PlayTime
        PlayUnlimited
        PlayDepth
        PlayNodes
        PlaySoftNodes

    TimeControlConfig* = object
        timeMs*: int64
        incrementMs*: int64

    NodeLimitConfig* = object
        softNodes*: uint64
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
        SetupChooseSoftNodesHardBound
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

    SoftNodeSetupConfig* = tuple[target: SetupLimitTarget, limit: PlayLimitConfig]

    PlaySetupState* = object
        case kind*: PlaySetupKind
            of SetupChooseLimit:
                limitConfig*: LimitSetupConfig
            of SetupChooseSoftNodesHardBound, SetupChooseSoftNodesHardLimit:
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

    BoardArrow* = object
        fromSq*: Square
        toSq*: Square
        brush*: ArrowBrush
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
        case kind*: SearchAction
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

    AppState* = ref object
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
        userArrows*: seq[BoardArrow]           # User-drawn board arrows
        pendingPremoves*: seq[Premove]
        boardSetupMode*: bool       # Manual board editing mode (analysis only)
        boardSetupSpawnPiece*: Option[Piece]
        boardSetupResumeAnalysis*: bool
        legalDestinations*: seq[Square]
        lastMove*: Option[tuple[fromSq, toSq: Square]]
        undoneHistory*: seq[UndoneMove]  # for redo via Right arrow
        inputBuffer*: string
        inputCursorPos*: int
        statusMessage*: string
        statusIsError*: bool
        statusExpiry*: MonoTime
        statusPersistent*: bool     # If true, don't auto-expire (dismiss on keypress)
        shouldQuit*: bool
        showThreats*: bool          # Threat highlighting toggle (off by default)
        showEngineArrows*: bool     # Best-move arrow overlay toggle (off by default)
        ctrlDPending*: bool         # Waiting for second Ctrl+D to confirm exit
        autoQueen*: bool            # Auto-promote to queen (toggle with q)
        promotionPending*: bool     # Waiting for user to choose promotion piece
        promotionFrom*: Square      # Source square of pending promotion
        promotionTo*: Square        # Target square of pending promotion
        helpVisible*: bool          # Help box overlay in info panel
        helpScroll*: int            # Scroll offset for the help overlay

        # Autocomplete
        acSuggestions*: seq[tuple[cmd, desc: string]]
        acSelected*: Option[int]
        acActive*: bool

        # Analysis (MultiPV support)
        analysisRunning*: bool
        multiPV*: int
        analysisLines*: seq[AnalysisLine]
        analysisDepth*: int
        analysisNPS*: uint64
        analysisNodes*: uint64
        analysisMateLimit*: Option[int]
        analysisPrompt*: Option[AnalysisPromptKind]

        # Play mode
        playPhase*: PlayPhase
        setupState*: PlaySetupState
        variant*: ChessVariant
        playSideSelection*: PlaySideSelection
        playerColor*: PieceColor
        playerLimit*: PlayLimitConfig
        playerClock*: ChessClock
        playerClockMoveStartMs*: int64
        engineLimit*: PlayLimitConfig
        engineClock*: ChessClock
        engineClockMoveStartMs*: int64
        engineThinking*: bool
        gameResult*: Option[string]
        watchMode*: bool             # Engine vs Engine (both sides auto-play)
        watchSeparateConfig*: bool   # Engines configured separately in watch mode
        allowTakeback*: bool         # Whether takeback is allowed in this game
        allowPonder*: bool           # Primary engine ponder setting
        lastPlayRematch*: PlayRematchConfig
        isPondering*: bool           # Primary engine currently pondering
        ponderMove*: Move            # Move the primary engine is pondering on
        isWatchPondering*: bool      # Second engine currently pondering
        watchPonderMove*: Move       # Move the second engine is pondering on
        gameStartFEN*: string        # FEN at game start (for display)
        gameTimeControl*: string     # Human-readable TC description

        # Second engine for watch mode (independent instance)
        watchSearcher*: SearchManager
        watchTtable*: ptr TranspositionTable
        watchThreads*: int
        watchHash*: uint64
        watchPonder*: bool           # Second engine ponder setting
        watchInitialized*: bool
        watchWorkerThread*: Thread[ptr AppState]
        watchChannels*: tuple[command: Channel[SearchCommand], response: Channel[SearchResponse]]

        # PGN replay
        pgnMoveIndex*: int
        pgnMoves*: seq[Move]
        pgnSanHistory*: seq[string]
        pgnStartPosition*: Option[Position]
        pgnTags*: seq[tuple[name, value: string]]  # Metadata from loaded PGN
        pgnResult*: string

        # Engine config
        analysisDepthLimit*: Option[int]
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
    result.multiPV = 1
    result.autoQueen = true
    result.acSelected = none(int)
    result.dragSourceSquare = none(Square)
    result.dragCursor = none(tuple[x, y: int])
    result.arrowDrawSourceSquare = none(Square)
    result.arrowDrawTargetSquare = none(Square)
    result.arrowDrawBrush = ArrowGreen
    result.pendingPremoves = @[]
    result.helpScroll = 0
    result.boardSetupSpawnPiece = none(Piece)
    result.engineThreads = 1
    result.engineHash = 64
    result.analysisPrompt = none(AnalysisPromptKind)
    result.playerLimit = PlayLimitConfig()
    result.engineLimit = PlayLimitConfig()
    result.playPhase = Setup
    result.setupState = PlaySetupState(kind: SetupChooseVariant)
    result.playSideSelection = SideRandom
    result.ttable = create(TranspositionTable)
    result.ttable[] = newTranspositionTable(result.engineHash * 1024 * 1024)
    result.searcher = newSearchManager(result.board.positions, result.ttable, evalState=newEvalState(verbose=false))
    result.channels.command.open()
    result.channels.response.open()
    result.pvChannel.open()


proc addMoveRecord*(state: AppState, move: Move, san: string, comment: string = "") =
    state.moveHistory.add(move)
    state.sanHistory.add(san)
    state.moveComments.add(comment)


proc popMoveRecord*(state: AppState): UndoneMove =
    result.move = state.moveHistory.pop()
    result.san = state.sanHistory.pop()
    result.comment = state.moveComments.pop()


proc clearMoveRecords*(state: AppState) =
    state.moveHistory = @[]
    state.sanHistory = @[]
    state.moveComments = @[]
    state.undoneHistory = @[]


const STATUS_DURATION* = initDuration(seconds = 3)


proc setStatus*(state: AppState, msg: string, isError: bool = false, persistent: bool = false) =
    state.statusMessage = msg
    state.statusIsError = isError
    state.statusPersistent = persistent
    if persistent:
        state.statusExpiry = MonoTime.high()
    else:
        state.statusExpiry = getMonoTime() + STATUS_DURATION


proc setError*(state: AppState, msg: string) =
    state.setStatus(msg, isError = true)


proc dismissStatus*(state: AppState) =
    ## Clears a persistent status message
    if state.statusPersistent:
        state.statusMessage = ""
        state.statusPersistent = false


proc queuePremove*(state: AppState, fromSq, toSq: Square) =
    state.pendingPremoves.add((fromSq: fromSq, toSq: toSq))
    state.setStatus(&"Queued premove #{state.pendingPremoves.len}: {fromSq.toUCI()}{toSq.toUCI()}")


proc clearPremoves*(state: AppState, statusMessage = "") =
    state.pendingPremoves = @[]
    if statusMessage.len > 0:
        state.setStatus(statusMessage)


proc clearUserArrows*(state: AppState) =
    state.userArrows = @[]
    state.arrowDrawSourceSquare = none(Square)
    state.arrowDrawTargetSquare = none(Square)
    state.arrowDrawBrush = ArrowGreen


proc resetSquareSelection*(state: AppState) =
    state.selectedSquare = none(Square)
    state.dragSourceSquare = none(Square)
    state.dragCursor = none(tuple[x, y: int])
    state.legalDestinations = @[]


proc resetBoardSetupState*(state: AppState) =
    state.boardSetupMode = false
    state.boardSetupSpawnPiece = none(Piece)
    state.boardSetupResumeAnalysis = false


proc resetPromotionState*(state: AppState) =
    state.promotionPending = false


proc resetMoveSession*(state: AppState) =
    state.clearMoveRecords()
    state.lastMove = none(tuple[fromSq, toSq: Square])
    state.pendingPremoves = @[]
    state.resetSquareSelection()
    state.resetPromotionState()


proc clearAnalysisPrompt*(state: AppState) =
    state.analysisPrompt = none(AnalysisPromptKind)


proc beginMateFinderPrompt*(state: AppState) =
    state.analysisPrompt = some(AnalysisPromptMateLimit)
    let currentLimit =
        if state.analysisMateLimit.isSome():
            &", current: {state.analysisMateLimit.get()}"
        else:
            ""
    state.setStatus(&"Mate finder depth in moves (1-255{currentLimit}; type none to clear):", persistent=true)


proc preparePlaySetup*(state: AppState, watchMode = false) =
    state.mode = ModePlay
    state.watchMode = watchMode
    state.watchSeparateConfig = false
    state.clearAnalysisPrompt()
    state.resetBoardSetupState()
    state.clearUserArrows()
    state.pendingPremoves = @[]
    state.resetSquareSelection()
    state.resetPromotionState()
    state.playPhase = Setup
    state.setupState = PlaySetupState(kind: SetupChooseVariant)
    state.gameResult = none(string)


proc enterAnalysisMode*(state: AppState) =
    state.mode = ModeAnalysis
    state.playPhase = Setup
    state.watchMode = false
    state.watchSeparateConfig = false
    state.gameResult = none(string)
    state.clearAnalysisPrompt()
    state.resetBoardSetupState()
    state.pendingPremoves = @[]
    state.resetSquareSelection()
    state.resetPromotionState()


proc enterReplayMode*(state: AppState) =
    state.mode = ModeReplay
    state.clearAnalysisPrompt()
    state.resetBoardSetupState()
    state.resetMoveSession()


proc toggleUserArrow*(state: AppState, fromSq, toSq: Square, brush: ArrowBrush) =
    for i, arrow in state.userArrows:
        if arrow.fromSq == fromSq and arrow.toSq == toSq:
            if arrow.brush == brush:
                state.userArrows.delete(i)
            else:
                state.userArrows[i].brush = brush
            return
    state.userArrows.add(BoardArrow(fromSq: fromSq, toSq: toSq, brush: brush))


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
        dealloc(state.ttable)
        state.ttable = nil
