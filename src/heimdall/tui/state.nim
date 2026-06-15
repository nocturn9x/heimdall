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

import std/[atomics, options, monotimes, times, strformat, tables, math]

import illwill
import heimdall/[board, moves, pieces, eval, search, transpositions, movegen]
import heimdall/util/limits
import heimdall/util/wdl
import heimdall/tui/util/openings


const
    DEFAULT_START_FEN* = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    GAME_ANALYSIS_GRAPH_TILE_COUNT* = 6


type
    AppState* = ref AppStateObj

    AnalysisPromptKind* = enum
        AnalysisPromptMateLimit
        AnalysisPromptGameReportTime
        AnalysisPromptGameReportDirection

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
        score*: Score       # Current display score, white-relative
        rawScore*: Score    # Raw STM-relative (for WDL computation)
        depth*: int

    AnalysisSnapshot* = object
        positionKey*: uint64
        lines*: seq[AnalysisLine]
        depth*: int
        nps*: uint64
        nodes*: uint64

    GameAnalysisDirection* = enum
        GameAnalysisReverse
        GameAnalysisForward

    GameAnalysisGraphMode* = enum
        GameAnalysisGraphEval
        GameAnalysisGraphWdl

    GamePhase* = enum
        PhaseOpening
        PhaseMidgame
        PhaseEndgame

    GameAnalysisJudgment* = enum
        JudgmentInaccuracy
        JudgmentMistake
        JudgmentBlunder

    GameAnalysisDivision* = object
        middlegameStart*: Option[int]
        endgameStart*: Option[int]

    GameAnalysisPosition* = object
        analyzed*: bool
        positionKey*: uint64
        score*: Score       # Current display score, white-relative
        rawScore*: Score    # Raw, white-relative (for metrics/graphing)
        material*: int
        sideToMove*: PieceColor
        depth*: int
        nps*: uint64
        nodes*: uint64
        bestMove*: Move

    GameAnalysisProgress* = object
        ply*: int
        positionKey*: uint64
        score*: Score
        rawScore*: Score
        material*: int
        sideToMove*: PieceColor
        depth*: int
        nps*: uint64
        nodes*: uint64
        bestMove*: Move

    GameAnalysisMoveSummary* = object
        mover*: PieceColor
        centipawnLoss*: int
        accuracy*: float
        bestMove*: Move
        judgment*: Option[GameAnalysisJudgment]

    GameAnalysisSummary* = object
        whiteMoves*: int
        blackMoves*: int
        whiteAvgCentipawnLoss*: int
        blackAvgCentipawnLoss*: int
        whiteAccuracy*: float
        blackAccuracy*: float

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

    UndoneMove* = tuple[move: Move, san: string, comment: string, arrows: seq[BoardArrow], highlights: seq[Square]]

    Premove* = tuple[fromSq, toSq: Square]

    ChessClock* = object
        remainingMs*: int64
        incrementMs*: int64
        lastTick*: MonoTime
        running*: bool
        expired*: bool

    SearchAction* = enum
        StartAnalysis
        StartGameAnalysis
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
            of StartGameAnalysis:
                gamePositions*: seq[Position]
                gameOrder*: seq[int]
                gameLimits*: seq[SearchLimit]
                gameMateDepth*: Option[int]
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
        cache*: Table[string, AnalysisSnapshot]

    GameAnalysisState* = object
        running*: bool
        limits*: seq[SearchLimit]
        limitLabel*: string
        mateLimit*: Option[int]
        direction*: GameAnalysisDirection
        graphMode*: GameAnalysisGraphMode
        graphVisible*: bool
        completedPositions*: int
        totalPositions*: int
        positions*: seq[GameAnalysisPosition]
        division*: GameAnalysisDivision

    ReplayState* = object
        moveIndex*: int
        moves*: seq[Move]
        sanHistory*: seq[string]
        startPosition*: Option[Position]
        openingHistory*: seq[Option[NamedOpening]]
        tags*: seq[tuple[name, value: string]]
        result*: string

    BoardSetupState* = object
        active*: bool
        spawnPiece*: Option[Piece]
        resumeAnalysis*: bool

    BoardRenderCache* = object
        lastBoardHash*: uint64
        lastEvalBarHash*: uint64
        lastGameAnalysisGraphBackgroundHash*: uint64
        lastGameAnalysisGraphDataTileHashes*: array[GAME_ANALYSIS_GRAPH_TILE_COUNT, uint64]
        lastGameAnalysisGraphLineTileHashes*: array[GAME_ANALYSIS_GRAPH_TILE_COUNT, uint64]
        lastGameAnalysisGraphMarkersHash*: uint64
        lastGameAnalysisGraphScaleHash*: uint64
        lastGameAnalysisGraphCursorHash*: uint64
        lastEngineArrowHash*: uint64
        lastUserArrowHash*: uint64
        lastDragHash*: uint64
        lastDragPiece*: Piece
        lastDragPieceSize*: int
        displayedEngineArrows*: seq[Move]
        lastEngineArrowSourceHash*: uint64
        lastEngineArrowRefresh*: MonoTime
        boardImageVisible*: bool
        evalBarImageVisible*: bool
        gameAnalysisGraphBackgroundVisible*: bool
        gameAnalysisGraphDataTileVisible*: array[GAME_ANALYSIS_GRAPH_TILE_COUNT, bool]
        gameAnalysisGraphLineTileVisible*: array[GAME_ANALYSIS_GRAPH_TILE_COUNT, bool]
        gameAnalysisGraphMarkersVisible*: bool
        gameAnalysisGraphScaleVisible*: bool
        gameAnalysisGraphCursorVisible*: bool
        engineArrowImageVisible*: bool
        userArrowImageVisible*: bool
        dragImageVisible*: bool
        activeBoardSlot*: Option[int]

    TerminalRenderCache* = object
        prevW*: int
        prevH*: int
        prevBoardX*: int
        prevBoardY*: int
        prevBoardW*: int
        prevBoardH*: int
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
        liveBoard*: Chessboard  # Authoritative game position during play/watch (state.board is the rendered view)
        viewPly*: int           # Ply shown in state.board; == moveHistory.len means the view follows the live tip

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
        userArrowHistory*: seq[seq[BoardArrow]]      # User-drawn board arrows, keyed by current ply
        highlightedSquareHistory*: seq[seq[Square]]  # User-highlighted board squares, keyed by current ply
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
        gameAnalysis*: GameAnalysisState

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
        gameAnalysisChannel*: Channel[GameAnalysisProgress]

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
    result.analysis.cache = initTable[string, AnalysisSnapshot]()
    result.autoQueen = true
    result.input.acSelected = none(int)
    result.dragSourceSquare = none(Square)
    result.dragCursor = none(tuple[x, y: int])
    result.arrowDrawSourceSquare = none(Square)
    result.arrowDrawTargetSquare = none(Square)
    result.arrowDrawBrush = ArrowGreen
    result.userArrowHistory = @[@[]]
    result.highlightedSquareHistory = @[@[]]
    result.pendingPremoves = @[]
    result.input.helpScroll = 0
    result.boardSetup.spawnPiece = none(Piece)
    result.boardRender.lastDragPiece = nullPiece()
    result.boardRender.activeBoardSlot = none(int)
    result.boardRender.lastEngineArrowRefresh = getMonoTime() - initDuration(milliseconds = 1000)
    result.engineThreads = 1
    result.engineHash = 64
    result.analysis.prompt = none(AnalysisPromptKind)
    result.gameAnalysis.limits = @[newTimeLimit(500, 0)]
    result.gameAnalysis.limitLabel = "500 ms"
    result.gameAnalysis.direction = GameAnalysisReverse
    result.gameAnalysis.graphMode = GameAnalysisGraphEval
    result.gameAnalysis.graphVisible = true
    result.play.playerLimit = PlayLimitConfig()
    result.play.engineLimit = PlayLimitConfig()
    result.play.phase = Setup
    result.play.setup = PlaySetupState(kind: SetupChooseVariant)
    result.play.sideSelection = SideRandom
    result.play.watch.hash = 64
    result.play.watch.threads = 1
    result.ttable = create(TranspositionTable)
    result.ttable[] = newTranspositionTable(result.engineHash * 1024 * 1024, result.engineThreads)
    result.searcher = newSearchManager(result.board.positions, result.ttable, evalState=newEvalState(verbose=false))
    result.channels.command.open()
    result.channels.response.open()
    result.pvChannel.open()
    result.gameAnalysisChannel.open()


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


proc ensureHighlightedSquareHistory(state: AppState) =
    let neededEntries = max(1, state.moveHistory.len + 1)
    if state.highlightedSquareHistory.len < neededEntries:
        state.highlightedSquareHistory.setLen(neededEntries)
    elif state.highlightedSquareHistory.len == 0:
        state.highlightedSquareHistory = @[@[]]


proc currentHighlightedSquares*(state: AppState): seq[Square] =
    state.ensureHighlightedSquareHistory()
    result = state.highlightedSquareHistory[state.moveHistory.len]


proc setCurrentHighlightedSquares(state: AppState, highlights: sink seq[Square]) =
    state.ensureHighlightedSquareHistory()
    state.highlightedSquareHistory[state.moveHistory.len] = highlights


proc clearStoredHighlightedSquares(state: AppState) =
    state.highlightedSquareHistory = newSeq[seq[Square]](max(1, state.moveHistory.len + 1))


proc normalizeScoresEnabled*(state: AppState): bool =
    state.searcher.state.normalizeScore.load(moRelaxed)


proc displayScore*(state: AppState, rawWhiteScore: Score, material: int): Score =
    ## Converts a raw white-relative score into the score currently shown by the TUI.
    if state.normalizeScoresEnabled():
        normalizeScore(rawWhiteScore, material)
    else:
        rawWhiteScore


proc currentAnalysisCacheKey*(state: AppState): string =
    let positionKey = state.board.zobristKey().uint64
    let depthLimit = if state.analysis.depthLimit.isSome(): $state.analysis.depthLimit.get() else: "-"
    let mateLimit = if state.analysis.mateLimit.isSome(): $state.analysis.mateLimit.get() else: "-"
    let chess960Flag = if state.chess960: "1" else: "0"
    let normalizeFlag = if state.normalizeScoresEnabled(): "1" else: "0"
    &"{positionKey:#0X}|960={chess960Flag}|mpv={state.analysis.multiPV}|d={depthLimit}|m={mateLimit}|norm={normalizeFlag}"


proc clearAnalysisCache*(state: AppState) =
    state.analysis.cache.clear()


proc clearAnalysisDisplay*(state: AppState) =
    state.analysis.lines = @[]
    state.analysis.linesPositionKey = 0
    state.analysis.depth = 0
    state.analysis.nps = 0
    state.analysis.nodes = 0


proc clearGameAnalysis*(state: AppState) =
    state.gameAnalysis.running = false
    state.gameAnalysis.completedPositions = 0
    state.gameAnalysis.totalPositions = 0
    state.gameAnalysis.positions = @[]
    state.gameAnalysis.division = GameAnalysisDivision()


proc hasGameAnalysis*(state: AppState): bool =
    state.gameAnalysis.positions.len > 0


proc currentGameAnalysisPosition*(state: AppState): Option[GameAnalysisPosition] =
    if state.mode != ModeReplay:
        return none(GameAnalysisPosition)
    if state.replay.moveIndex < 0 or state.replay.moveIndex >= state.gameAnalysis.positions.len:
        return none(GameAnalysisPosition)
    let position = state.gameAnalysis.positions[state.replay.moveIndex]
    if not position.analyzed:
        return none(GameAnalysisPosition)
    some(position)


proc currentReplayOpening*(state: AppState): Option[NamedOpening] =
    if state.mode != ModeReplay:
        return none(NamedOpening)
    if state.replay.moveIndex < 0 or state.replay.moveIndex >= state.replay.openingHistory.len:
        return none(NamedOpening)
    result = state.replay.openingHistory[state.replay.moveIndex]


proc gameAnalysisGraphModeLabel*(mode: GameAnalysisGraphMode): string =
    case mode:
        of GameAnalysisGraphEval:
            "Eval"
        of GameAnalysisGraphWdl:
            "WDL"


proc judgmentGlyph*(judgment: GameAnalysisJudgment): string =
    case judgment:
        of JudgmentInaccuracy:
            "?!"
        of JudgmentMistake:
            "?"
        of JudgmentBlunder:
            "??"


proc judgmentLabel*(judgment: GameAnalysisJudgment): string =
    case judgment:
        of JudgmentInaccuracy:
            "Inaccuracy"
        of JudgmentMistake:
            "Mistake"
        of JudgmentBlunder:
            "Blunder"


proc gameAnalysisPhase*(state: AppState, ply: int): GamePhase =
    let clampedPly = max(0, ply)
    if state.gameAnalysis.division.endgameStart.isSome() and clampedPly >= state.gameAnalysis.division.endgameStart.get():
        return PhaseEndgame
    if state.gameAnalysis.division.middlegameStart.isSome() and clampedPly >= state.gameAnalysis.division.middlegameStart.get():
        return PhaseMidgame
    PhaseOpening


proc gameAnalysisPhaseLabel*(phase: GamePhase): string =
    case phase:
        of PhaseOpening:
            "opening"
        of PhaseMidgame:
            "middlegame"
        of PhaseEndgame:
            "endgame"


const
    LICHESS_WINNING_CHANCE_MULTIPLIER = -0.00368208
    WHITE_HOME_RANK = 7
    BLACK_HOME_RANK = 0


proc lichessWinningChances(score: Score): float =
    let cp =
        if score.isMateScore():
            if score > 0: 1000.0 else: -1000.0
        else:
            score.float
    2.0 / (1.0 + exp(LICHESS_WINNING_CHANCE_MULTIPLIER * cp)) - 1.0


proc moverRelativeScore(score: Score, mover: PieceColor): Score =
    if mover == White: score else: -score


proc majorsAndMinors(position: Position): int =
    for color in White..Black:
        result += position.pieces(Knight, color).count()
        result += position.pieces(Bishop, color).count()
        result += position.pieces(Rook, color).count()
        result += position.pieces(Queen, color).count()


proc backrankSparse(position: Position): bool =
    var whiteBackrankPieces = 0
    var blackBackrankPieces = 0
    for file in 0..7:
        if position.on(makeSquare(WHITE_HOME_RANK, file)).color == White:
            inc whiteBackrankPieces
        if position.on(makeSquare(BLACK_HOME_RANK, file)).color == Black:
            inc blackBackrankPieces
    whiteBackrankPieces < 4 or blackBackrankPieces < 4


proc mixednessRegionScore(whiteCount, blackCount, boardY: int): int =
    if whiteCount == 0 and blackCount == 0:
        0
    elif whiteCount == 1 and blackCount == 0:
        1 + (8 - boardY)
    elif whiteCount == 2 and blackCount == 0:
        if boardY > 2: 2 + (boardY - 2) else: 0
    elif (whiteCount == 3 or whiteCount == 4) and blackCount == 0:
        if boardY > 1: 3 + (boardY - 1) else: 0
    elif whiteCount == 0 and blackCount == 1:
        1 + boardY
    elif whiteCount == 1 and blackCount == 1:
        5 + abs(3 - boardY)
    elif whiteCount == 2 and blackCount == 1:
        4 + boardY
    elif whiteCount == 3 and blackCount == 1:
        5 + boardY
    elif whiteCount == 0 and blackCount == 2:
        if boardY < 6: 2 + (6 - boardY) else: 0
    elif whiteCount == 1 and blackCount == 2:
        4 + (6 - boardY)
    elif whiteCount == 2 and blackCount == 2:
        7
    elif whiteCount == 0 and blackCount == 3:
        if boardY < 7: 3 + (7 - boardY) else: 0
    elif whiteCount == 1 and blackCount == 3:
        5 + (6 - boardY)
    elif whiteCount == 0 and blackCount == 4:
        if boardY < 7: 3 + (7 - boardY) else: 0
    else:
        0


proc mixedness(position: Position): int =
    for rank in 0..6:
        for file in 0..6:
            var whiteCount = 0
            var blackCount = 0
            for dRank in 0..1:
                for dFile in 0..1:
                    let piece = position.on(makeSquare(rank + dRank, file + dFile))
                    case piece.color:
                        of White:
                            inc whiteCount
                        of Black:
                            inc blackCount
                        of None:
                            discard
            result += mixednessRegionScore(whiteCount, blackCount, 8 - rank)


proc classifyGameAnalysisDivision*(positions: seq[Position]): GameAnalysisDivision =
    for index in 0..positions.high:
        if majorsAndMinors(positions[index]) <= 10 or backrankSparse(positions[index]) or mixedness(positions[index]) > 150:
            result.middlegameStart = some(index)
            break

    if result.middlegameStart.isSome():
        for index in 0..positions.high:
            if majorsAndMinors(positions[index]) <= 6:
                result.endgameStart = some(index)
                break

    if result.middlegameStart.isSome() and result.endgameStart.isSome() and
       result.middlegameStart.get() >= result.endgameStart.get():
        result.endgameStart = none(int)


proc expectedScorePercent(score: Score, material: int, mover: PieceColor): float =
    let wdl = getExpectedWDL(score, material)
    let whiteScore = (wdl.win.float + 0.5 * wdl.draw.float) / 10.0
    if mover == White:
        whiteScore
    else:
        100.0 - whiteScore


proc computeGameAnalysisMoveSummary*(state: AppState, ply: int): Option[GameAnalysisMoveSummary] =
    if ply <= 0 or ply >= state.gameAnalysis.positions.len:
        return none(GameAnalysisMoveSummary)

    let before = state.gameAnalysis.positions[ply - 1]
    let after = state.gameAnalysis.positions[ply]
    if not before.analyzed or not after.analyzed:
        return none(GameAnalysisMoveSummary)

    let mover = before.sideToMove
    let rawLoss =
        if mover == White:
            before.rawScore.int - after.rawScore.int
        else:
            after.rawScore.int - before.rawScore.int
    let centipawnLoss = max(0, rawLoss)

    let beforeExpected = expectedScorePercent(before.rawScore, before.material, mover)
    let afterExpected = expectedScorePercent(after.rawScore, after.material, mover)
    let winPercentLoss = max(0.0, beforeExpected - afterExpected)
    let accuracy =
        if winPercentLoss <= 0.0:
            100.0
        else:
            max(0.0, min(100.0, 103.1668 * exp(-0.04354 * winPercentLoss) - 3.1669))

    var judgment = none(GameAnalysisJudgment)
    let beforeMoverScore = moverRelativeScore(before.rawScore, mover)
    let afterMoverScore = moverRelativeScore(after.rawScore, mover)
    if beforeMoverScore.isMateScore() or afterMoverScore.isMateScore():
        let beforeWinningMate = beforeMoverScore.isMateScore() and beforeMoverScore > 0
        let afterLosingMate = afterMoverScore.isMateScore() and afterMoverScore < 0
        let lostWinningMate = beforeWinningMate and ((not afterMoverScore.isMateScore()) or afterMoverScore < 0)
        let createdLosingMate = (not beforeMoverScore.isMateScore()) and afterLosingMate

        if createdLosingMate:
            if beforeMoverScore < -999:
                judgment = some(JudgmentInaccuracy)
            elif beforeMoverScore < -700:
                judgment = some(JudgmentMistake)
            else:
                judgment = some(JudgmentBlunder)
        elif lostWinningMate:
            if (not afterMoverScore.isMateScore()) and afterMoverScore > 999:
                judgment = some(JudgmentInaccuracy)
            elif (not afterMoverScore.isMateScore()) and afterMoverScore > 700:
                judgment = some(JudgmentMistake)
            else:
                judgment = some(JudgmentBlunder)
    else:
        let beforeWinningChance = lichessWinningChances(before.rawScore)
        let afterWinningChance = lichessWinningChances(after.rawScore)
        let winningChanceDrop =
            if mover == White:
                beforeWinningChance - afterWinningChance
            else:
                afterWinningChance - beforeWinningChance

        if winningChanceDrop >= 0.3:
            judgment = some(JudgmentBlunder)
        elif winningChanceDrop >= 0.2:
            judgment = some(JudgmentMistake)
        elif winningChanceDrop >= 0.1:
            judgment = some(JudgmentInaccuracy)

    if judgment == some(JudgmentInaccuracy) and state.gameAnalysisPhase(ply - 1) == PhaseOpening:
        judgment = none(GameAnalysisJudgment)

    some(GameAnalysisMoveSummary(
        mover: mover,
        centipawnLoss: centipawnLoss,
        accuracy: accuracy,
        bestMove: before.bestMove,
        judgment: judgment
    ))


proc computeGameAnalysisSummary*(state: AppState): GameAnalysisSummary =
    var whiteLossTotal = 0
    var blackLossTotal = 0
    var whiteAccuracyTotal = 0.0
    var blackAccuracyTotal = 0.0

    for ply in 1..<state.gameAnalysis.positions.len:
        let moveSummary = state.computeGameAnalysisMoveSummary(ply)
        if moveSummary.isNone():
            continue
        let summary = moveSummary.get()
        if summary.mover == White:
            inc result.whiteMoves
            whiteLossTotal += summary.centipawnLoss
            whiteAccuracyTotal += summary.accuracy
        else:
            inc result.blackMoves
            blackLossTotal += summary.centipawnLoss
            blackAccuracyTotal += summary.accuracy

    if result.whiteMoves > 0:
        result.whiteAvgCentipawnLoss = int(round(whiteLossTotal.float / result.whiteMoves.float))
        result.whiteAccuracy = whiteAccuracyTotal / result.whiteMoves.float
    if result.blackMoves > 0:
        result.blackAvgCentipawnLoss = int(round(blackLossTotal.float / result.blackMoves.float))
        result.blackAccuracy = blackAccuracyTotal / result.blackMoves.float


proc storeCurrentAnalysisSnapshot*(state: AppState) =
    let positionKey = state.board.zobristKey().uint64
    if state.analysis.lines.len == 0 or state.analysis.linesPositionKey != positionKey:
        return

    state.analysis.cache[state.currentAnalysisCacheKey()] = AnalysisSnapshot(
        positionKey: positionKey,
        lines: state.analysis.lines,
        depth: state.analysis.depth,
        nps: state.analysis.nps,
        nodes: state.analysis.nodes
    )


proc restoreCachedAnalysis*(state: AppState): bool =
    let cacheKey = state.currentAnalysisCacheKey()
    if cacheKey in state.analysis.cache:
        let snapshot = state.analysis.cache[cacheKey]
        let positionKey = state.board.zobristKey().uint64
        if snapshot.positionKey == positionKey:
            state.analysis.lines = snapshot.lines
            state.analysis.linesPositionKey = snapshot.positionKey
            state.analysis.depth = snapshot.depth
            state.analysis.nps = snapshot.nps
            state.analysis.nodes = snapshot.nodes
            return true

    state.clearAnalysisDisplay()
    false


proc addMoveRecord*(state: AppState, move: Move, san: string, comment: string = "") =
    state.ensureUserArrowHistory()
    state.ensureHighlightedSquareHistory()
    state.moveHistory.add(move)
    state.sanHistory.add(san)
    state.moveComments.add(comment)
    state.userArrowHistory.setLen(state.moveHistory.len + 1)
    state.highlightedSquareHistory.setLen(state.moveHistory.len + 1)


proc popMoveRecord*(state: AppState): UndoneMove =
    state.ensureUserArrowHistory()
    state.ensureHighlightedSquareHistory()
    result.move = state.moveHistory.pop()
    result.san = state.sanHistory.pop()
    result.comment = state.moveComments.pop()
    result.arrows =
        if state.userArrowHistory.len > 1:
            state.userArrowHistory.pop()
        else:
            @[]
    result.highlights =
        if state.highlightedSquareHistory.len > 1:
            state.highlightedSquareHistory.pop()
        else:
            @[]


proc clearMoveRecords*(state: AppState) =
    state.moveHistory = @[]
    state.sanHistory = @[]
    state.moveComments = @[]
    state.undoneHistory = @[]
    state.userArrowHistory = @[@[]]
    state.highlightedSquareHistory = @[@[]]
    state.clearGameAnalysis()


proc resetArrowState*(state: AppState, clearUserAnnotations = true)


proc syncLastMoveFromHistory*(state: AppState) =
    if state.moveHistory.len > 0:
        let move = state.moveHistory[^1]
        state.lastMove = some((fromSq: move.startSquare(), toSq: move.targetSquare()))
    else:
        state.lastMove = none(tuple[fromSq, toSq: Square])


proc atLiveTip*(state: AppState): bool =
    ## True when the rendered board reflects the live game position (or we are not
    ## in an active game). When false, the user is browsing move history.
    state.mode != ModePlay or state.play.phase == Setup or
        state.play.viewPly >= state.moveHistory.len


proc isBrowsingHistory*(state: AppState): bool =
    ## True when an active game is in progress but the user has scrolled back into
    ## the move history, so the rendered board is not the live position.
    state.mode == ModePlay and state.play.phase != Setup and
        state.play.viewPly < state.moveHistory.len


proc rebuildPlayView*(state: AppState) =
    ## Re-derives the rendered board (state.board) from the live game at the current
    ## view ply. At the tip, state.board aliases liveBoard so moves land on the live
    ## game; while browsing, it is a separate snapshot frozen at the viewed ply.
    if state.play.liveBoard == nil:
        return
    let tip = state.moveHistory.len
    let ply = clamp(state.play.viewPly, 0, tip)
    state.play.viewPly = ply
    if ply >= tip:
        state.board = state.play.liveBoard
    else:
        var snapshot: seq[Position]
        for i in 0 .. ply:
            snapshot.add(state.play.liveBoard.positions[i].clone())
        state.board = newChessboard(snapshot)
    if ply > 0 and ply <= state.moveHistory.len:
        let m = state.moveHistory[ply - 1]
        state.lastMove = some((fromSq: m.startSquare(), toSq: m.targetSquare()))
    else:
        state.lastMove = none(tuple[fromSq, toSq: Square])


proc followLiveTip*(state: AppState) =
    ## Snaps the view to the live game tip. Used after the local side commits a move
    ## so the rendered board keeps aliasing liveBoard.
    if state.mode != ModePlay or state.play.liveBoard == nil:
        return
    state.play.viewPly = state.moveHistory.len
    state.board = state.play.liveBoard
    state.syncLastMoveFromHistory()


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

    let (move, san, comment, arrows, highlights) = state.undoneHistory.pop()
    state.lastMove = some((fromSq: move.startSquare(), toSq: move.targetSquare()))
    discard state.board.makeMove(move)
    state.resetArrowState(clearUserAnnotations = false)
    state.addMoveRecord(move, san, comment)
    state.setCurrentUserArrows(arrows)
    state.setCurrentHighlightedSquares(highlights)
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


proc toggleGameAnalysisGraphMode*(state: AppState): bool =
    if state.mode != ModeReplay or not state.hasGameAnalysis():
        state.setError("Run :analyse first")
        return false

    case state.gameAnalysis.graphMode:
        of GameAnalysisGraphEval:
            state.gameAnalysis.graphMode = GameAnalysisGraphWdl
        of GameAnalysisGraphWdl:
            state.gameAnalysis.graphMode = GameAnalysisGraphEval
    state.setStatus(&"Game analysis graph: {gameAnalysisGraphModeLabel(state.gameAnalysis.graphMode)}")
    true


proc toggleGameAnalysisGraphVisibility*(state: AppState): bool =
    if state.mode != ModeReplay or not state.hasGameAnalysis():
        state.setError("Run :analyse first")
        return false

    state.gameAnalysis.graphVisible = not state.gameAnalysis.graphVisible
    state.setStatus(
        if state.gameAnalysis.graphVisible:
            "Game analysis graph shown"
        else:
            "Game analysis graph hidden"
    )
    true


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
    state.setCurrentHighlightedSquares(@[])


proc clearUserAnnotations*(state: AppState) =
    state.clearStoredUserArrows()
    state.clearStoredHighlightedSquares()
    state.arrowDrawSourceSquare = none(Square)
    state.arrowDrawTargetSquare = none(Square)
    state.arrowDrawBrush = ArrowGreen


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
    if state.analysis.running:
        state.clearAnalysisDisplay()
    else:
        discard state.restoreCachedAnalysis()


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


proc beginGameAnalysisPrompt*(state: AppState) =
    state.analysis.prompt = some(AnalysisPromptGameReportTime)
    state.gameAnalysis.limits = @[newTimeLimit(500, 0)]
    state.gameAnalysis.limitLabel = "500 ms"
    state.gameAnalysis.mateLimit = none(int)
    state.gameAnalysis.direction = GameAnalysisReverse
    state.setStatus("Computer analysis limit (e.g. 500ms, depth 20, nodes 200000, mate 6; Enter for 500ms):", persistent=true)


proc preparePlaySetup*(state: AppState, watchMode = false) =
    state.mode = ModePlay
    state.play.watchMode = watchMode
    state.play.watchSeparateConfig = false
    state.clearAnalysisPrompt()
    state.clearGameAnalysis()
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
    state.clearGameAnalysis()
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
    state.ensureHighlightedSquareHistory()
    for i, highlightedSq in state.highlightedSquareHistory[state.moveHistory.len]:
        if highlightedSq == sq:
            state.highlightedSquareHistory[state.moveHistory.len].delete(i)
            return
    state.highlightedSquareHistory[state.moveHistory.len].add(sq)


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
    state.gameAnalysisChannel.close()
    if state.ttable != nil:
        state.ttable.destroy()
        dealloc(state.ttable)
        state.ttable = nil
