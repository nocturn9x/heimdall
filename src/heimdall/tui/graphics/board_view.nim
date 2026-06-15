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

## Board rendering: composites pre-rendered piece images onto the
## board SVG and sends the result via the kitty graphics protocol.

import std/[options, monotimes, times, math, strformat]
from std/posix import STDOUT_FILENO
from std/termios import IOctl_WinSize, TIOCGWINSZ, ioctl

import illwill
import heimdall/[pieces, board, bitboards, moves, eval]
import heimdall/util/wdl
import heimdall/tui/[state, rawinput]
import heimdall/tui/graphics/pixel
import heimdall/tui/util/[kitty, premove]


const
    BOARD_IMG_IDS = [1, 3]
    BOARD_PLACEMENT_IDS = [1, 2]
    DRAG_IMG_ID = 2
    DRAG_PLACEMENT_ID = 1
    ENGINE_ARROW_IMG_ID = 4
    ENGINE_ARROW_PLACEMENT_ID = 1
    USER_ARROW_IMG_ID = 5
    USER_ARROW_PLACEMENT_ID = 1
    EVAL_BAR_IMG_ID = 6
    EVAL_BAR_PLACEMENT_ID = 1
    GAME_ANALYSIS_GRAPH_BG_IMG_ID = 7
    GAME_ANALYSIS_GRAPH_BG_PLACEMENT_ID = 1
    GAME_ANALYSIS_GRAPH_DATA_IMG_IDS = [8, 12, 13, 14, 15, 16]
    GAME_ANALYSIS_GRAPH_MARKERS_IMG_ID = 9
    GAME_ANALYSIS_GRAPH_MARKERS_PLACEMENT_ID = 1
    GAME_ANALYSIS_GRAPH_SCALE_IMG_ID = 10
    GAME_ANALYSIS_GRAPH_SCALE_PLACEMENT_ID = 1
    GAME_ANALYSIS_GRAPH_CURSOR_IMG_ID = 11
    GAME_ANALYSIS_GRAPH_CURSOR_PLACEMENT_ID = 1
    GAME_ANALYSIS_GRAPH_LINE_IMG_IDS = [17, 18, 19, 20, 21, 22]

    BOARD_MARGIN_X* = 1
    BOARD_MARGIN_Y* = 1
    EVAL_BAR_GUTTER_WIDTH* = 6
    BOARD_GAP_COLS* = 2
    INFO_PANEL_MIN_WIDTH* = 24
    BOARD_MIN_PX* = 320

    INPUT_UI_ROWS = 3
    AUTOCOMPLETE_MAX_ROWS = 8
    GAME_ANALYSIS_GRAPH_ROWS = 8
    GAME_ANALYSIS_GRAPH_GAP_ROWS = 2
    TRAILING_MARGIN_COLS = 1

    # Mixing salts for board/drag redraw fingerprints.
    HASH_MIX_BOARD_SIZE = 0xD6E8FEB86659FD93'u64
    HASH_MIX_ARROW_COUNT = 0x369DEA0F31A53F85'u64
    HASH_MIX_ARROW_FROM = 0xC2B2AE3D27D4EB4F'u64
    HASH_MIX_ARROW_TO = 0x165667B19E3779F9'u64
    HASH_MIX_USER_ARROW_COUNT = 0xF1357AEA2E62A9C5'u64
    HASH_MIX_PREMOVE_COUNT = 0x94D049BB133111EB'u64
    HASH_MIX_PREMOVE_FROM = 0x94D049BB133111EB'u64
    HASH_MIX_PREMOVE_TO = 0x2545F4914F6CDD1D'u64
    HASH_MIX_LEGAL_DEST_COUNT = 0xBF58476D1CE4E5B9'u64
    HASH_MIX_SQUARE = 0x9E3779B185EBCA87'u64
    HASH_MIX_DRAG_X = 0x517CC1B727220A95'u64
    HASH_MIX_DRAG_Y = 0xC2B2AE3D27D4EB4F'u64
    HASH_MIX_DRAG_SIZE = 0xDB4F0B9175AE2165'u64

template renderCache(state: AppState): untyped = state.boardRender


proc getCellPixelSize*: tuple[w, h: int]


proc boardCornerRadius(boardPx: int): int =
    max(4, boardPx div 96)


proc usesDragOverlay: bool =
    detectTerminalKind() != tkWezTerm


proc draggedPieceTopLeft(boardPx, pieceSize: int, dragCursor: tuple[x, y: int]): tuple[x, y: int] =
    result.x = max(0, min(boardPx - pieceSize, dragCursor.x - pieceSize div 2))
    result.y = max(0, min(boardPx - pieceSize, dragCursor.y - pieceSize div 2))


proc reservedAutocompleteRows: int =
    AUTOCOMPLETE_MAX_ROWS


proc evalBarLabelRows(state: AppState): int =
    if state.mode == ModePlay:
        return 0
    1


proc gameAnalysisGraphRows*(state: AppState): int =
    if state.mode == ModeReplay and state.gameAnalysis.graphVisible and state.gameAnalysis.positions.len > 1:
        max(GAME_ANALYSIS_GRAPH_ROWS + 1, min(14, terminalHeight() div 4))
    else:
        0


proc gameAnalysisGraphReservedRows(state: AppState): int =
    let rows = state.gameAnalysisGraphRows()
    if rows <= 0:
        return 0
    rows + GAME_ANALYSIS_GRAPH_GAP_ROWS


proc bottomUiRows(state: AppState): int =
    INPUT_UI_ROWS + reservedAutocompleteRows() + evalBarLabelRows(state) + gameAnalysisGraphReservedRows(state)


proc boardStartX*: int =
    BOARD_MARGIN_X + EVAL_BAR_GUTTER_WIDTH


proc currentBoardPixelSize*(state: AppState): int =
    let cellSize = getCellPixelSize()
    let cellW = max(1, cellSize.w)
    let cellH = max(1, cellSize.h)
    let termW = terminalWidth()
    let termH = terminalHeight()
    let availableCols = termW - boardStartX() - BOARD_GAP_COLS - INFO_PANEL_MIN_WIDTH - TRAILING_MARGIN_COLS
    let availableRows = termH - BOARD_MARGIN_Y - bottomUiRows(state)
    if availableCols <= 0 or availableRows <= 0:
        return 0

    let maxBoardPx = min(BOARD_PX, min(availableCols * cellW, availableRows * cellH))
    result = (maxBoardPx div 8) * 8
    if result < BOARD_MIN_PX:
        result = 0


proc minimumTerminalSize*(state: AppState): tuple[w, h: int] =
    let cellSize = getCellPixelSize()
    let cellW = max(1, cellSize.w)
    let cellH = max(1, cellSize.h)
    let boardCols = (BOARD_MIN_PX + cellW - 1) div cellW
    let boardRows = (BOARD_MIN_PX + cellH - 1) div cellH
    result.w = boardStartX() + boardCols + BOARD_GAP_COLS + INFO_PANEL_MIN_WIDTH + TRAILING_MARGIN_COLS
    result.h = BOARD_MARGIN_Y + boardRows + bottomUiRows(state)


proc boardVisible*(state: AppState): bool =
    currentBoardPixelSize(state) > 0


proc squareCenterPixel(state: AppState, sq: Square, squarePx: int): tuple[x, y: int] =
    let displayRank = if state.flipped: 7 - sq.rank().int else: sq.rank().int
    let displayFile = if state.flipped: 7 - sq.file().int else: sq.file().int
    result.x = displayFile * squarePx + squarePx div 2
    result.y = displayRank * squarePx + squarePx div 2


proc userArrowTint(brush: ArrowBrush): Color =
    case brush:
        of ArrowGreen:
            USER_ARROW_GREEN_TINT
        of ArrowRed:
            USER_ARROW_RED_TINT
        of ArrowBlue:
            USER_ARROW_BLUE_TINT
        of ArrowYellow:
            USER_ARROW_YELLOW_TINT
        of ArrowThreat:
            THREAT_ARROW_TINT


proc liveAnalysisArrowMoves(state: AppState): seq[Move] =
    if state.mode != ModeAnalysis or not state.showEngineArrows or state.boardSetup.active:
        return @[]

    for line in state.analysis.lines:
        if line.pv.len == 0:
            continue
        let move = line.pv[0]
        var duplicate = false
        for existing in result:
            if existing == move:
                duplicate = true
                break
        if not duplicate:
            result.add(move)


proc analysisArrowMoves(state: AppState): seq[Move] =
    if state.analysis.linesPositionKey != state.board.zobristKey().uint64:
        state.renderCache.displayedEngineArrows = @[]
        state.renderCache.lastEngineArrowSourceHash = 0
        return @[]

    let liveMoves = liveAnalysisArrowMoves(state)
    if liveMoves.len == 0:
        state.renderCache.displayedEngineArrows = @[]
        state.renderCache.lastEngineArrowSourceHash = 0
        state.renderCache.lastEngineArrowRefresh = getMonoTime()
        return @[]

    var liveHash = liveMoves.len.uint64 * HASH_MIX_ARROW_COUNT
    for i, move in liveMoves:
        liveHash = liveHash xor (move.startSquare().uint64 * (HASH_MIX_ARROW_FROM xor i.uint64))
        liveHash = liveHash xor (move.targetSquare().uint64 * (HASH_MIX_ARROW_TO xor (i.uint64 shl 8)))

    let now = getMonoTime()
    let refreshDue =
        state.renderCache.displayedEngineArrows.len == 0 or
        (now - state.renderCache.lastEngineArrowRefresh) >= initDuration(milliseconds = 500)

    if liveHash != state.renderCache.lastEngineArrowSourceHash and refreshDue:
        state.renderCache.displayedEngineArrows = liveMoves
        state.renderCache.lastEngineArrowSourceHash = liveHash
        state.renderCache.lastEngineArrowRefresh = now

    result = state.renderCache.displayedEngineArrows


proc threatArrowMoves(state: AppState): seq[BoardArrow] =
    if state.mode != ModeAnalysis or not state.showEngineArrows or not state.showThreats or state.boardSetup.active:
        return @[]

    let sideToMove = state.board.sideToMove()
    let attackerColor = sideToMove.opposite()
    let threats = state.board.position.threats

    for sq in threats:
        let piece = state.board.on(sq)
        if piece.kind == Empty or piece.color != sideToMove:
            continue
        let attackers = state.board.position.attackers(sq, attackerColor)
        for attackerSq in attackers:
            result.add(BoardArrow(fromSq: attackerSq, toSq: sq, brush: ArrowThreat))
            break


proc userArrowMoves(state: AppState): seq[BoardArrow] =
    if state.boardSetup.active:
        return @[]
    result = state.currentUserArrows()


proc currentUserArrow(state: AppState): Option[BoardArrow] =
    if state.boardSetup.active:
        return none(BoardArrow)
    if state.arrowDrawSourceSquare.isSome() and state.arrowDrawTargetSquare.isSome():
        return some(BoardArrow(
            fromSq: state.arrowDrawSourceSquare.get(),
            toSq: state.arrowDrawTargetSquare.get(),
            brush: state.arrowDrawBrush
        ))
    none(BoardArrow)


proc displayBoardState(state: AppState): Chessboard =
    if state.pendingPremoves.len > 0 and state.mode == ModePlay and state.play.phase == EngineTurn and not state.play.watchMode:
        return premoveViewBoard(state.board, state.play.playerColor, state.pendingPremoves, state.chess960)
    state.board


proc currentEvalScoreImpl(state: AppState): Option[Score] =
    if state.mode == ModePlay:
        return none(Score)
    if state.analysis.linesPositionKey != state.board.zobristKey().uint64 or state.analysis.lines.len == 0:
        let reportPosition = state.currentGameAnalysisPosition()
        if reportPosition.isSome():
            let position = reportPosition.get()
            return some(state.displayScore(position.rawScore, position.material))
        return none(Score)
    some(state.analysis.lines[0].score)


proc currentEvalScore*(state: AppState): Option[Score] =
    currentEvalScoreImpl(state)


proc hasGameAnalysisGraph(state: AppState): bool =
    state.mode == ModeReplay and state.gameAnalysis.graphVisible and state.gameAnalysis.positions.len > 1


type
    EvalGraphScale = object
        absLimitCp: float
        labelTop: string
        labelMid: string
        labelBottom: string


proc scoreToGraphRatio(score: Score, absLimitCp: float): float


proc whiteExpectedScore(score: Score, material: int): float =
    let wdl = getExpectedWDL(score, material)
    (wdl.win.float + 0.5 * wdl.draw.float) / 1000.0


proc formatGraphEvalLabel(cp: float, forceSign: bool): string =
    let pawns = cp / 100.0
    if forceSign:
        &"{pawns:+.1f}"
    else:
        &"{pawns:.1f}"


proc niceEvalScaleLimit(cp: float): float =
    let clamped = max(80.0, cp)
    let steps = [100.0, 150.0, 200.0, 300.0, 400.0, 500.0, 800.0, 1000.0, 1500.0, 2000.0, 3000.0]
    for step in steps:
        if clamped <= step:
            return step
    ceil(clamped / 1000.0) * 1000.0


proc currentEvalGraphScale(state: AppState): EvalGraphScale =
    var maxAbsCp = 0.0
    for position in state.gameAnalysis.positions:
        let displayScore = state.displayScore(position.rawScore, position.material)
        if not position.analyzed or displayScore.isMateScore():
            continue
        maxAbsCp = max(maxAbsCp, abs(displayScore.float))

    result.absLimitCp = max(200.0, niceEvalScaleLimit(maxAbsCp))
    result.labelTop = formatGraphEvalLabel(result.absLimitCp, true)
    result.labelMid = "0.0"
    result.labelBottom = formatGraphEvalLabel(-result.absLimitCp, true)


proc graphValueRatio(state: AppState, position: GameAnalysisPosition, evalAbsLimitCp: float): float =
    case state.gameAnalysis.graphMode:
        of GameAnalysisGraphEval:
            scoreToGraphRatio(state.displayScore(position.rawScore, position.material), evalAbsLimitCp)
        of GameAnalysisGraphWdl:
            let expectedScore = whiteExpectedScore(position.rawScore, position.material)
            1.0 - max(0.0, min(1.0, expectedScore))


proc graphPhaseBoundaryX(moveCount, plotLeft, plotWidth, boundary: int): int =
    if moveCount <= 1:
        return plotLeft
    let clampedBoundary = max(0, min(moveCount - 1, boundary))
    plotLeft + int(round(plotWidth.float * clampedBoundary.float / (moveCount - 1).float))


proc openingPhaseAnchorX(state: AppState, moveCount, plotLeft, plotWidth: int): int =
    if state.gameAnalysis.division.middlegameStart.isSome():
        graphPhaseBoundaryX(moveCount, plotLeft, plotWidth, max(0, state.gameAnalysis.division.middlegameStart.get() div 2))
    else:
        plotLeft + max(8, plotWidth div 10)


proc catmullRomValue(p0, p1, p2, p3, t: float): float {.inline.} =
    0.5 * ((2.0 * p1) +
           (-p0 + p2) * t +
           (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t * t +
           (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t * t * t)


proc scoreToGraphRatio(score: Score, absLimitCp: float): float =
    if score.isMateScore():
        if score > 0:
            return 0.0
        return 1.0

    let cp = score.float
    let scale = max(1.0, absLimitCp)
    let scaled = cp / (abs(cp) + scale)
    result = 0.5 - 0.5 * scaled
    result = max(0.0, min(1.0, result))


proc graphCanvasWidth(widthPx: int): int =
    max(1, widthPx - max(32, widthPx div 12))


proc graphTileBounds(widthPx, tileIndex: int): tuple[startX, width: int] =
    let canvasWidth = graphCanvasWidth(widthPx)
    let clampedTile = max(0, min(GAME_ANALYSIS_GRAPH_TILE_COUNT - 1, tileIndex))
    let startX = (canvasWidth * clampedTile) div GAME_ANALYSIS_GRAPH_TILE_COUNT
    let endX = (canvasWidth * (clampedTile + 1)) div GAME_ANALYSIS_GRAPH_TILE_COUNT
    (startX, max(1, endX - startX))


proc graphPlotBounds(widthPx, heightPx: int): tuple[left, top, width, height, midY, radius, canvasWidth: int] =
    let canvasWidth = graphCanvasWidth(widthPx)
    let radius = max(4, min(canvasWidth, heightPx) div 18)
    let padLeft = max(12, canvasWidth div 40)
    let padRight = max(60, canvasWidth div 20)
    let padY = max(10, heightPx div 10)
    let plotLeft = padLeft
    let plotTop = padY
    let plotWidth = max(1, canvasWidth - padLeft - padRight)
    let plotHeight = max(1, heightPx - padY * 2)
    let midlineY = plotTop + plotHeight div 2
    (plotLeft, plotTop, plotWidth, plotHeight, midlineY, radius, canvasWidth)


proc drawGraphScaleLabels(buf: var PixelBuffer, state: AppState, widthPx, heightPx: int) =
    let (plotLeft, plotTop, plotWidth, plotHeight, midlineY, _, canvasWidth) = graphPlotBounds(widthPx, heightPx)
    let scale = 2
    let labelColor = Color(r: 224, g: 228, b: 235, a: 216)
    let shadowColor = Color(r: 14, g: 16, b: 20, a: 168)
    let evalScale = currentEvalGraphScale(state)
    let topLabel =
        if state.gameAnalysis.graphMode == GameAnalysisGraphWdl: "1.0"
        else: evalScale.labelTop
    let midLabel =
        if state.gameAnalysis.graphMode == GameAnalysisGraphWdl: "0.5"
        else: evalScale.labelMid
    let bottomLabel =
        if state.gameAnalysis.graphMode == GameAnalysisGraphWdl: "0.0"
        else: evalScale.labelBottom

    let upperGuideY = plotTop + int(round(plotHeight.float * 0.25)) - (7 * scale) div 2
    let lowerGuideY = plotTop + int(round(plotHeight.float * 0.75)) - (7 * scale) div 2

    for (text, y) in [(topLabel, upperGuideY), (midLabel, midlineY - (7 * scale) div 2), (bottomLabel, lowerGuideY)]:
        let textWidth = text.len * 6 * scale - 2 * scale
        let plotRight = plotLeft + plotWidth
        let labelX = max(4, min(canvasWidth - textWidth - 4, plotRight + 4))
        let labelY = max(2, min(heightPx - 7 * scale - 2, y))
        buf.fillRoundedRect(labelX - 4, labelY - 2, textWidth + 8, 7 * scale + 4, 4, shadowColor)
        buf.drawBitmapText(labelX, labelY, text, labelColor, scale)


proc drawPhaseDividerLabel(buf: var PixelBuffer, x, plotTop, plotHeight: int, label: string) =
    if label.len == 0:
        return
    let scale = 1
    let labelHeight = label.len * 6 * scale - scale
    let boxWidth = 13
    let boxHeight = labelHeight + 8
    let boxX = max(2, min(buf.width - boxWidth - 2, x - boxWidth div 2))
    let boxY = max(plotTop + 6, min(plotTop + plotHeight - boxHeight - 6, plotTop + (plotHeight - boxHeight) div 2))
    buf.fillRoundedRect(boxX, boxY, boxWidth, boxHeight, 4, Color(r: 20, g: 23, b: 28, a: 188))
    buf.drawBitmapTextVertical(boxX + 3, boxY + 4, label, Color(r: 236, g: 239, b: 243, a: 232), scale)


proc formatGraphCursorScore(score: Score): string =
    if score.isMateScore():
        let plies = mateScore() - abs(score)
        let moves = (plies + 1) div 2
        if score > 0:
            return &"M{moves}"
        else:
            return &"-M{moves}"

    let pawns = score.float / 100.0
    if abs(pawns) >= 10.0:
        &"{pawns:+.0f}"
    else:
        &"{pawns:+.1f}"


proc formatGraphCursorLabel(state: AppState, position: GameAnalysisPosition): string =
    case state.gameAnalysis.graphMode:
        of GameAnalysisGraphEval:
            formatGraphCursorScore(state.displayScore(position.rawScore, position.material))
        of GameAnalysisGraphWdl:
            let expectedScore = whiteExpectedScore(position.rawScore, position.material)
            &"{expectedScore:.2f}"


proc renderGameAnalysisGraphBackground(state: AppState, widthPx, heightPx: int): PixelBuffer =
    if widthPx <= 0 or heightPx <= 0:
        return newPixelBuffer(0, 0)

    result = newPixelBuffer(widthPx, heightPx)
    let (plotLeft, plotTop, plotWidth, plotHeight, midlineY, radius, canvasWidth) = graphPlotBounds(widthPx, heightPx)
    let moveCount = state.gameAnalysis.positions.len
    result.fillRoundedRect(0, 0, canvasWidth, heightPx, radius, Color(r: 24, g: 27, b: 31, a: 232))

    let guideColor = Color(r: 102, g: 110, b: 121, a: 72)
    result.fillRoundedRect(plotLeft, midlineY, plotWidth, 1, 0, guideColor)
    for ratio in [0.25, 0.75]:
        let guideY = plotTop + int(plotHeight.float * ratio)
        result.fillRoundedRect(plotLeft, guideY, plotWidth, 1, 0, Color(r: 82, g: 88, b: 96, a: 40))
    if moveCount > 1:
        for moveNo in countup(10, moveCount - 1, 10):
            let x = plotLeft + int(round(plotWidth.float * moveNo.float / (moveCount - 1).float))
            result.fillRoundedRect(x, plotTop, 1, plotHeight, 0, Color(r: 74, g: 80, b: 88, a: 36))

    result.applyRoundedRectMask(0, 0, canvasWidth, heightPx, radius)


proc renderGameAnalysisGraphData(state: AppState, widthPx, heightPx: int): PixelBuffer =
    if widthPx <= 0 or heightPx <= 0 or not hasGameAnalysisGraph(state):
        return newPixelBuffer(0, 0)

    let moveCount = state.gameAnalysis.positions.len
    if moveCount <= 1:
        return newPixelBuffer(0, 0)

    type GraphPoint = tuple[x, y: float]
    let (plotLeft, plotTop, plotWidth, plotHeight, _, radius, canvasWidth) = graphPlotBounds(widthPx, heightPx)
    result = newPixelBuffer(widthPx, heightPx)
    let evalScale = currentEvalGraphScale(state)
    let graphLineThickness = max(1.08, heightPx.float / 176.0)
    let moveDotThickness = max(2.2, graphLineThickness * 2.35)
    let whiteLineColor = Color(r: 244, g: 244, b: 244, a: 252)
    let blackLineColor = Color(r: 8, g: 8, b: 8, a: 252)
    let moveDotColor = Color(r: 72, g: 188, b: 255, a: 255)

    var plottedPoints: seq[GraphPoint] = @[]
    var plottedMetrics: seq[float] = @[]
    let baselineMetric =
        if state.gameAnalysis.graphMode == GameAnalysisGraphEval:
            0.0
        else:
            0.5

    proc metricLineColor(metric: float): Color =
        if metric >= baselineMetric:
            whiteLineColor
        else:
            blackLineColor

    proc drawSampledPolyline(buf: var PixelBuffer, points: seq[GraphPoint], c: Color, thickness: float, blend: bool) =
        if blend:
            buf.drawAnalyticPolyline(points, c, thickness, blend=true)
            return

        var overlay = newPixelBuffer(buf.width, buf.height)
        overlay.drawAnalyticPolyline(points, c, thickness, blend=false)
        buf.blendOver(overlay, 0, 0)

    proc drawGraphMoveDots(buf: var PixelBuffer, points: seq[GraphPoint], c: Color, thickness: float) =
        if points.len == 0:
            return

        var overlay = newPixelBuffer(buf.width, buf.height)
        for point in points:
            overlay.drawAnalyticPolyline(@[point], c, thickness, blend=false)
        buf.blendOver(overlay, 0, 0)

    proc drawColoredGraphSegment(buf: var PixelBuffer,
                                 fromPoint: GraphPoint,
                                 fromMetric: float,
                                 toPoint: GraphPoint,
                                 toMetric: float) =
        let fromDelta = fromMetric - baselineMetric
        let toDelta = toMetric - baselineMetric
        if abs(fromDelta) < 0.000001 and abs(toDelta) < 0.000001:
            buf.drawSampledPolyline(@[fromPoint, toPoint], whiteLineColor, graphLineThickness, blend=false)
            return

        if fromDelta == 0.0 or toDelta == 0.0 or fromDelta * toDelta > 0.0:
            let lineColor = metricLineColor((fromMetric + toMetric) * 0.5)
            buf.drawSampledPolyline(@[fromPoint, toPoint], lineColor, graphLineThickness, blend=false)
            return

        let tCross = max(0.0, min(1.0, (baselineMetric - fromMetric) / (toMetric - fromMetric)))
        let crossPoint = (
            x: fromPoint.x + (toPoint.x - fromPoint.x) * tCross,
            y: fromPoint.y + (toPoint.y - fromPoint.y) * tCross
        )
        buf.drawSampledPolyline(@[fromPoint, crossPoint], metricLineColor(fromMetric), graphLineThickness, blend=false)
        buf.drawSampledPolyline(@[crossPoint, toPoint], metricLineColor(toMetric), graphLineThickness, blend=false)

    proc flushPlottedSegment(buf: var PixelBuffer) =
        if plottedPoints.len > 1:
            for i in 0..<(plottedPoints.len - 1):
                buf.drawColoredGraphSegment(plottedPoints[i], plottedMetrics[i], plottedPoints[i + 1], plottedMetrics[i + 1])
            buf.drawGraphMoveDots(plottedPoints, moveDotColor, moveDotThickness)
        elif plottedPoints.len == 1:
            let point = plottedPoints[0]
            buf.drawGraphMoveDots(@[point], moveDotColor, moveDotThickness)
        plottedPoints = @[]
        plottedMetrics = @[]

    for i, position in state.gameAnalysis.positions:
        if not position.analyzed:
            flushPlottedSegment(result)
            continue

        let x = plotLeft.float + plotWidth.float * i.float / (moveCount - 1).float
        let currentMetric =
            case state.gameAnalysis.graphMode:
                of GameAnalysisGraphEval:
                    state.displayScore(position.rawScore, position.material).float
                of GameAnalysisGraphWdl:
                    whiteExpectedScore(position.rawScore, position.material)
        let y = plotTop.float + graphValueRatio(state, position, evalScale.absLimitCp) * plotHeight.float
        plottedPoints.add((x: x, y: y))
        plottedMetrics.add(currentMetric)

    flushPlottedSegment(result)

    result.applyRoundedRectMask(0, 0, canvasWidth, heightPx, radius)


proc slicePixelBuffer(buf: PixelBuffer, startX, width: int): PixelBuffer =
    let clampedStartX = max(0, min(buf.width, startX))
    let sliceWidth = max(0, min(width, buf.width - clampedStartX))
    result = newPixelBuffer(sliceWidth, buf.height)
    if sliceWidth <= 0 or buf.height <= 0:
        return
    for y in 0..<buf.height:
        let srcStart = (y * buf.width + clampedStartX) * 4
        let dstStart = y * sliceWidth * 4
        copyMem(addr result.data[dstStart], unsafeAddr buf.data[srcStart], sliceWidth * 4)


proc renderGameAnalysisGraphLineTile(state: AppState, widthPx, heightPx, tileIndex: int): PixelBuffer =
    if widthPx <= 0 or heightPx <= 0 or not hasGameAnalysisGraph(state):
        return newPixelBuffer(0, 0)

    let moveCount = state.gameAnalysis.positions.len
    if moveCount <= 1:
        return newPixelBuffer(0, 0)

    type GraphPoint = tuple[x, y: float]
    let tileBounds = graphTileBounds(widthPx, tileIndex)
    let tileStartX = tileBounds.startX
    let tileWidth = tileBounds.width
    let tileEndX = tileStartX + tileWidth - 1
    result = newPixelBuffer(tileWidth, heightPx)
    let (plotLeft, plotTop, plotWidth, plotHeight, _, _, _) = graphPlotBounds(widthPx, heightPx)
    let evalScale = currentEvalGraphScale(state)
    let lineColor =
        if state.gameAnalysis.graphMode == GameAnalysisGraphWdl:
            Color(r: 132, g: 218, b: 255, a: 248)
        else:
            Color(r: 224, g: 228, b: 235, a: 255)
    let lineThickness = max(0.58, heightPx.float / 235.0)

    var plottedPoints: seq[GraphPoint] = @[]

    proc flushPlottedSegment(buf: var PixelBuffer) =
        if plottedPoints.len > 1:
            var minX = plottedPoints[0].x
            var maxX = plottedPoints[0].x
            for point in plottedPoints:
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
            if maxX >= tileStartX.float - lineThickness * 2.0 and minX <= tileEndX.float + lineThickness * 2.0:
                var localPoints: seq[GraphPoint] = @[]
                for point in plottedPoints:
                    localPoints.add((x: point.x - tileStartX.float, y: point.y))
                buf.drawSmoothPolyline(localPoints, lineColor, lineThickness, blend=true)
        elif plottedPoints.len == 1:
            let point = plottedPoints[0]
            if point.x >= tileStartX.float - 1.0 and point.x <= tileEndX.float + 1.0:
                buf.fillCircle(int(round(point.x - tileStartX.float)), int(round(point.y)), 1, lineColor)
        plottedPoints = @[]

    for i, position in state.gameAnalysis.positions:
        if not position.analyzed:
            flushPlottedSegment(result)
            continue
        let x = plotLeft.float + plotWidth.float * i.float / (moveCount - 1).float
        let y = plotTop.float + graphValueRatio(state, position, evalScale.absLimitCp) * plotHeight.float
        plottedPoints.add((x: x, y: y))

    flushPlottedSegment(result)


proc hashPixelBuffer(buf: PixelBuffer, seed: uint64): uint64 =
    result = seed xor 0xCBF29CE484222325'u64
    for byte in buf.data:
        result = (result xor byte.uint64) * 0x100000001B3'u64
    result = result xor (buf.width.uint64 shl 32) xor buf.height.uint64


proc renderGameAnalysisGraphMarkers(state: AppState, widthPx, heightPx: int): PixelBuffer =
    if widthPx <= 0 or heightPx <= 0 or not hasGameAnalysisGraph(state):
        return newPixelBuffer(0, 0)

    let moveCount = state.gameAnalysis.positions.len
    if moveCount <= 1:
        return newPixelBuffer(0, 0)

    result = newPixelBuffer(widthPx, heightPx)
    let (plotLeft, plotTop, plotWidth, plotHeight, _, radius, canvasWidth) = graphPlotBounds(widthPx, heightPx)
    let openingX = openingPhaseAnchorX(state, moveCount, plotLeft, plotWidth)
    result.fillRoundedRect(openingX, plotTop, 1, plotHeight, 0, Color(r: 255, g: 255, b: 255, a: 52))
    drawPhaseDividerLabel(result, openingX, plotTop, plotHeight, "OPENING")

    if state.gameAnalysis.division.middlegameStart.isSome():
        let x = graphPhaseBoundaryX(moveCount, plotLeft, plotWidth, state.gameAnalysis.division.middlegameStart.get())
        result.fillRoundedRect(x, plotTop, 1, plotHeight, 0, Color(r: 255, g: 255, b: 255, a: 64))
        drawPhaseDividerLabel(result, x, plotTop, plotHeight, "MIDGAME")
    if state.gameAnalysis.division.endgameStart.isSome():
        let x = graphPhaseBoundaryX(moveCount, plotLeft, plotWidth, state.gameAnalysis.division.endgameStart.get())
        result.fillRoundedRect(x, plotTop, 1, plotHeight, 0, Color(r: 255, g: 255, b: 255, a: 64))
        drawPhaseDividerLabel(result, x, plotTop, plotHeight, "ENDGAME")

    result.applyRoundedRectMask(0, 0, canvasWidth, heightPx, radius)


proc renderGameAnalysisGraphScale(state: AppState, widthPx, heightPx: int): PixelBuffer =
    if widthPx <= 0 or heightPx <= 0 or not hasGameAnalysisGraph(state):
        return newPixelBuffer(0, 0)

    result = newPixelBuffer(widthPx, heightPx)
    let (_, _, _, _, _, radius, canvasWidth) = graphPlotBounds(widthPx, heightPx)
    drawGraphScaleLabels(result, state, widthPx, heightPx)
    result.applyRoundedRectMask(0, 0, canvasWidth, heightPx, radius)


proc renderGameAnalysisGraphCursor(state: AppState, widthPx, heightPx, currentPly: int): PixelBuffer =
    if widthPx <= 0 or heightPx <= 0 or not hasGameAnalysisGraph(state):
        return newPixelBuffer(0, 0)

    let moveCount = state.gameAnalysis.positions.len
    if moveCount <= 1:
        return newPixelBuffer(0, 0)

    result = newPixelBuffer(widthPx, heightPx)
    let (plotLeft, plotTop, plotWidth, plotHeight, _, radius, canvasWidth) = graphPlotBounds(widthPx, heightPx)
    let clampedCurrentPly = max(0, min(moveCount - 1, currentPly))
    let currentX = plotLeft + int(round(plotWidth.float * clampedCurrentPly.float / (moveCount - 1).float))
    result.fillRoundedRect(currentX, plotTop, 2, plotHeight, 0, Color(r: 72, g: 188, b: 255, a: 96))

    let currentPosition = state.gameAnalysis.positions[clampedCurrentPly]
    if currentPosition.analyzed:
        let currentEvalScale = currentEvalGraphScale(state)
        let currentY = plotTop.float + graphValueRatio(state, currentPosition, currentEvalScale.absLimitCp) * plotHeight.float
        let scoreLabel = formatGraphCursorLabel(state, currentPosition)
        let textScale = 1
        let textWidth = scoreLabel.len * 6 * textScale - textScale
        let textHeight = 7 * textScale
        let badgeWidth = max(max(20, textWidth + 10), heightPx div 9)
        let badgeHeight = max(14, textHeight + 8)
        let badgeX = max(0, min(canvasWidth - badgeWidth, currentX - badgeWidth div 2))
        let badgeY = max(0, min(heightPx - badgeHeight, int(round(currentY)) - badgeHeight div 2))
        result.fillCircle(currentX, int(round(currentY)), max(5, heightPx div 14), Color(r: 24, g: 27, b: 31, a: 220))
        result.fillCircle(currentX, int(round(currentY)), max(3, heightPx div 22), Color(r: 72, g: 188, b: 255, a: 255))
        result.fillRoundedRect(badgeX, badgeY, badgeWidth, badgeHeight, badgeHeight div 2, Color(r: 36, g: 110, b: 170, a: 232))
        result.drawBitmapText(
            badgeX + max(3, (badgeWidth - textWidth) div 2),
            badgeY + max(2, (badgeHeight - textHeight) div 2),
            scoreLabel,
            Color(r: 245, g: 248, b: 252, a: 255),
            textScale
        )

    result.applyRoundedRectMask(0, 0, canvasWidth, heightPx, radius)


proc renderEvalBarOverlay(state: AppState): PixelBuffer =
    let boardPx = currentBoardPixelSize(state)
    let cellSize = getCellPixelSize()
    let gutterPx = EVAL_BAR_GUTTER_WIDTH * max(1, cellSize.w)
    if boardPx <= 0 or gutterPx <= 0 or state.mode == ModePlay:
        return newPixelBuffer(0, 0)

    let scoreOpt = state.currentEvalScoreImpl()
    let barHeight = boardPx
    let barWidth = min(max(10, max(1, cellSize.w) * 4), max(10, gutterPx - max(2, cellSize.w div 2)))
    let barX = max(0, (gutterPx - barWidth) div 2)
    let whiteAtTop = state.flipped
    let outerRadius = max(3, min(barWidth div 2, max(1, cellSize.w)))
    let borderThickness = max(1, min(2, barWidth div 6))
    let innerX = barX + borderThickness
    let innerY = borderThickness
    let innerWidth = max(1, barWidth - borderThickness * 2)
    let innerHeight = max(1, barHeight - borderThickness * 2)
    let innerRadius = max(1, outerRadius - borderThickness)

    result = newPixelBuffer(gutterPx, boardPx)
    result.fillRoundedRect(barX, 0, barWidth, barHeight, outerRadius, Color(r: 92, g: 92, b: 92, a: 210))

    var mask = newPixelBuffer(gutterPx, boardPx)
    mask.fillRoundedRect(innerX, innerY, innerWidth, innerHeight, innerRadius, Color(r: 255, g: 255, b: 255, a: 255))

    var whitePx = innerHeight div 2
    if scoreOpt.isSome():
        let score = scoreOpt.get()
        if score.isMateScore():
            whitePx = if score > 0: innerHeight else: 0
        else:
            let cp = score.float
            let whiteRatio = 0.5 + 0.5 * (cp / (abs(cp) + 600.0))
            whitePx = max(0, min(innerHeight, int(whiteRatio * innerHeight.float + 0.5)))

    let splitY =
        if whiteAtTop:
            innerY + whitePx
        else:
            innerY + (innerHeight - whitePx)

    for y in innerY..<innerY + innerHeight:
        let topIsWhite =
            if whiteAtTop:
                y < splitY
            else:
                y >= splitY
        let fillColor =
            if topIsWhite:
                Color(r: 245, g: 245, b: 245, a: 255)
            else:
                Color(r: 18, g: 18, b: 18, a: 255)
        for x in innerX..<innerX + innerWidth:
            let alpha = mask.getPixel(x, y).a
            if alpha == 0:
                continue
            var shaded = fillColor
            shaded.a = alpha
            result.blendPixel(x, y, shaded)


proc renderEngineArrowOverlay(state: AppState): PixelBuffer =
    let boardPx = currentBoardPixelSize(state)
    if boardPx <= 0:
        return newPixelBuffer(0, 0)

    let squarePx = boardPx div 8
    let engineMoves = analysisArrowMoves(state)
    let threatMoves = threatArrowMoves(state)
    result = newPixelBuffer(boardPx, boardPx)

    for i in countdown(engineMoves.high, 0):
        let move = engineMoves[i]
        let startCenter = squareCenterPixel(state, move.startSquare(), squarePx)
        let targetCenter = squareCenterPixel(state, move.targetSquare(), squarePx)
        let isPrimary = i == 0
        let arrowTint =
            if isPrimary:
                ENGINE_ARROW_TINT
            else:
                ENGINE_ARROW_SECONDARY_TINTS[min(i - 1, ENGINE_ARROW_SECONDARY_TINTS.high)]
        let shaftThickness =
            if isPrimary:
                max(8, squarePx div 7)
            else:
                max(6, squarePx div 9)
        let headLength =
            if isPrimary:
                max(18, squarePx div 2)
            else:
                max(14, squarePx * 2 div 5)
        let headWidth =
            if isPrimary:
                max(20, squarePx * 2 div 3)
            else:
                max(16, squarePx div 2)
        result.drawArrowOverlay(
            startCenter.x,
            startCenter.y,
            targetCenter.x,
            targetCenter.y,
            arrowTint,
            shaftThickness,
            headLength,
            headWidth
        )

    for arrow in threatMoves:
        let startCenter = squareCenterPixel(state, arrow.fromSq, squarePx)
        let targetCenter = squareCenterPixel(state, arrow.toSq, squarePx)
        result.drawArrowOverlay(
            startCenter.x,
            startCenter.y,
            targetCenter.x,
            targetCenter.y,
            userArrowTint(arrow.brush),
            max(7, squarePx div 10),
            max(16, squarePx * 2 div 5),
            max(16, squarePx div 2)
        )

    result.applyRoundedRectMask(0, 0, boardPx, boardPx, boardCornerRadius(boardPx))


proc renderUserArrowOverlay(state: AppState): PixelBuffer =
    let boardPx = currentBoardPixelSize(state)
    if boardPx <= 0:
        return newPixelBuffer(0, 0)

    let squarePx = boardPx div 8
    let userMoves = userArrowMoves(state)
    let previewArrow = currentUserArrow(state)
    result = newPixelBuffer(boardPx, boardPx)

    for arrow in userMoves:
        let startCenter = squareCenterPixel(state, arrow.fromSq, squarePx)
        let targetCenter = squareCenterPixel(state, arrow.toSq, squarePx)
        result.drawArrowOverlay(
            startCenter.x,
            startCenter.y,
            targetCenter.x,
            targetCenter.y,
            userArrowTint(arrow.brush),
            max(8, squarePx div 8),
            max(18, squarePx div 2),
            max(20, squarePx * 2 div 3)
        )

    if previewArrow.isSome():
        let arrow = previewArrow.get()
        let startCenter = squareCenterPixel(state, arrow.fromSq, squarePx)
        let targetCenter = squareCenterPixel(state, arrow.toSq, squarePx)
        result.drawArrowOverlay(
            startCenter.x,
            startCenter.y,
            targetCenter.x,
            targetCenter.y,
            userArrowTint(arrow.brush),
            max(8, squarePx div 8),
            max(18, squarePx div 2),
            max(20, squarePx * 2 div 3)
        )

    result.applyRoundedRectMask(0, 0, boardPx, boardPx, boardCornerRadius(boardPx))


proc renderBoardImage*(state: AppState): PixelBuffer =
    ## Composites the full chessboard image: board background + pieces + highlights
    let boardPx = currentBoardPixelSize(state)
    if boardPx <= 0:
        return newPixelBuffer(0, 0)

    let squarePx = boardPx div 8
    let pad = max(1, squarePx div 8)
    let pieceSize = max(1, squarePx - pad * 2)

    result = newPixelBuffer(boardPx, boardPx)
    result.blendOverScaled(getBoardImage(state.flipped), 0, 0, boardPx, boardPx)

    let displayBoard = displayBoardState(state)
    let dragging = state.dragSourceSquare.isSome() and state.dragCursor.isSome()
    let draggedSquare = if dragging: state.dragSourceSquare.get() else: Square(0)
    let highlightedSquares = state.currentHighlightedSquares()
    let sideToMove = state.board.sideToMove()
    let inCheck = state.board.inCheck()
    let kingSquare = if inCheck: state.board.position.pieces(King, sideToMove).toSquare() else: Square(0)

    for displayRank in 0..7:
        let rank = if state.flipped: 7 - displayRank else: displayRank
        for displayFile in 0..7:
            let file = if state.flipped: 7 - displayFile else: displayFile
            let sq = makeSquare(rank, file)
            let piece = displayBoard.on(sq)

            let ox = displayFile * squarePx
            let oy = displayRank * squarePx

            if state.lastMove.isSome():
                let lm = state.lastMove.get()
                if sq == lm.fromSq or sq == lm.toSq:
                    result.tintRect(ox, oy, ox + squarePx - 1, oy + squarePx - 1, LAST_MOVE_TINT)

            var premoveIndex = none(int)
            for i, premove in state.pendingPremoves:
                if sq == premove.fromSq or sq == premove.toSq:
                    premoveIndex = some(i)
            if premoveIndex.isSome():
                result.tintRect(ox, oy, ox + squarePx - 1, oy + squarePx - 1, premoveTint(premoveIndex.get()))

            if state.selectedSquare.isSome() and sq == state.selectedSquare.get():
                result.tintRect(ox, oy, ox + squarePx - 1, oy + squarePx - 1, SELECTED_TINT)

            for highlightedSq in highlightedSquares:
                if sq == highlightedSq:
                    result.tintRect(ox, oy, ox + squarePx - 1, oy + squarePx - 1, HIGHLIGHTED_SQUARE_TINT)
                    break

            var isLegalDest = false
            for dest in state.legalDestinations:
                if sq == dest:
                    isLegalDest = true
                    break

            if isLegalDest:
                if piece.kind == Empty:
                    result.fillCircle(ox + squarePx div 2, oy + squarePx div 2, max(2, squarePx div 6), LEGAL_DEST_TINT)
                else:
                    result.tintRect(ox, oy, ox + squarePx - 1, oy + squarePx - 1, LEGAL_DEST_TINT)

            if inCheck and sq == kingSquare:
                result.tintRect(ox, oy, ox + squarePx - 1, oy + squarePx - 1, CHECK_TINT)

            if piece.kind != Empty and (not dragging or sq != draggedSquare):
                let pieceImg = getPieceImage(piece)
                if pieceImg.width > 0:
                    result.blendOverScaledSmooth(pieceImg, ox + pad, oy + pad, pieceSize, pieceSize)

    if dragging and not usesDragOverlay():
        let piece = state.board.on(draggedSquare)
        if piece.kind != Empty:
            let pieceImg = getPieceImage(piece)
            if pieceImg.width > 0:
                let topLeft = draggedPieceTopLeft(boardPx, pieceSize, state.dragCursor.get())
                result.blendOverScaledSmooth(pieceImg, topLeft.x, topLeft.y, pieceSize, pieceSize)

    result.applyRoundedRectMask(0, 0, boardPx, boardPx, boardCornerRadius(boardPx))


proc boardImageId(slot: int): int =
    BOARD_IMG_IDS[slot]


proc boardPlacementId(slot: int): int =
    BOARD_PLACEMENT_IDS[slot]


proc resetBoardHash*(state: AppState) =
    ## Forces the board to be re-rendered on the next displayBoard call
    state.renderCache.lastBoardHash = 0
    state.renderCache.lastEvalBarHash = 0
    state.renderCache.lastGameAnalysisGraphBackgroundHash = 0
    for tileIndex in 0..<GAME_ANALYSIS_GRAPH_TILE_COUNT:
        state.renderCache.lastGameAnalysisGraphDataTileHashes[tileIndex] = 0
        state.renderCache.lastGameAnalysisGraphLineTileHashes[tileIndex] = 0
    state.renderCache.lastGameAnalysisGraphMarkersHash = 0
    state.renderCache.lastGameAnalysisGraphScaleHash = 0
    state.renderCache.lastGameAnalysisGraphCursorHash = 0
    state.renderCache.lastEngineArrowHash = 0
    state.renderCache.lastUserArrowHash = 0
    state.renderCache.lastDragHash = 0
    state.renderCache.lastDragPiece = nullPiece()
    state.renderCache.lastDragPieceSize = 0


proc hideBoardImages*(state: AppState) =
    var graphTileVisible = false
    for tileIndex in 0..<GAME_ANALYSIS_GRAPH_TILE_COUNT:
        graphTileVisible = graphTileVisible or state.renderCache.gameAnalysisGraphDataTileVisible[tileIndex]
        graphTileVisible = graphTileVisible or state.renderCache.gameAnalysisGraphLineTileVisible[tileIndex]
    if not state.renderCache.boardImageVisible and
       not state.renderCache.evalBarImageVisible and
       not state.renderCache.gameAnalysisGraphBackgroundVisible and
       not graphTileVisible and
       not state.renderCache.gameAnalysisGraphMarkersVisible and
       not state.renderCache.gameAnalysisGraphScaleVisible and
       not state.renderCache.gameAnalysisGraphCursorVisible and
       not state.renderCache.engineArrowImageVisible and
       not state.renderCache.userArrowImageVisible and
       not state.renderCache.dragImageVisible:
        return
    if state.renderCache.boardImageVisible:
        for slot in 0..BOARD_IMG_IDS.high:
            deletePlacement(boardImageId(slot), boardPlacementId(slot))
            deleteImage(boardImageId(slot))
        state.renderCache.boardImageVisible = false
        state.renderCache.activeBoardSlot = none(int)
    if state.renderCache.evalBarImageVisible:
        deletePlacement(EVAL_BAR_IMG_ID, EVAL_BAR_PLACEMENT_ID)
        deleteImage(EVAL_BAR_IMG_ID)
        state.renderCache.evalBarImageVisible = false
    if state.renderCache.gameAnalysisGraphBackgroundVisible:
        deletePlacement(GAME_ANALYSIS_GRAPH_BG_IMG_ID, GAME_ANALYSIS_GRAPH_BG_PLACEMENT_ID)
        deleteImage(GAME_ANALYSIS_GRAPH_BG_IMG_ID)
        state.renderCache.gameAnalysisGraphBackgroundVisible = false
    for tileIndex in 0..<GAME_ANALYSIS_GRAPH_TILE_COUNT:
        if state.renderCache.gameAnalysisGraphDataTileVisible[tileIndex]:
            deletePlacement(GAME_ANALYSIS_GRAPH_DATA_IMG_IDS[tileIndex], 1)
            deleteImage(GAME_ANALYSIS_GRAPH_DATA_IMG_IDS[tileIndex])
            state.renderCache.gameAnalysisGraphDataTileVisible[tileIndex] = false
        if state.renderCache.gameAnalysisGraphLineTileVisible[tileIndex]:
            deletePlacement(GAME_ANALYSIS_GRAPH_LINE_IMG_IDS[tileIndex], 1)
            deleteImage(GAME_ANALYSIS_GRAPH_LINE_IMG_IDS[tileIndex])
            state.renderCache.gameAnalysisGraphLineTileVisible[tileIndex] = false
    if state.renderCache.gameAnalysisGraphCursorVisible:
        deletePlacement(GAME_ANALYSIS_GRAPH_CURSOR_IMG_ID, GAME_ANALYSIS_GRAPH_CURSOR_PLACEMENT_ID)
        deleteImage(GAME_ANALYSIS_GRAPH_CURSOR_IMG_ID)
        state.renderCache.gameAnalysisGraphCursorVisible = false
    if state.renderCache.engineArrowImageVisible:
        deletePlacement(ENGINE_ARROW_IMG_ID, ENGINE_ARROW_PLACEMENT_ID)
        deleteImage(ENGINE_ARROW_IMG_ID)
        state.renderCache.engineArrowImageVisible = false
    if state.renderCache.userArrowImageVisible:
        deletePlacement(USER_ARROW_IMG_ID, USER_ARROW_PLACEMENT_ID)
        deleteImage(USER_ARROW_IMG_ID)
        state.renderCache.userArrowImageVisible = false
    if state.renderCache.dragImageVisible:
        deletePlacement(DRAG_IMG_ID, DRAG_PLACEMENT_ID)
        deleteImage(DRAG_IMG_ID)
        state.renderCache.dragImageVisible = false
    state.resetBoardHash()


proc boardChanged*(state: AppState): bool =
    let boardPx = currentBoardPixelSize(state)
    let highlightedSquares = state.currentHighlightedSquares()
    var h: uint64 = state.board.zobristKey().uint64
    h = h xor (if state.flipped: 1'u64 else: 0'u64)
    h = h xor (if state.showThreats: 2'u64 else: 0'u64)
    h = h xor (boardPx.uint64 * HASH_MIX_BOARD_SIZE)
    if state.lastMove.isSome():
        let lm = state.lastMove.get()
        h = h xor (lm.fromSq.uint64 shl 16) xor (lm.toSq.uint64 shl 24)
    if state.selectedSquare.isSome():
        h = h xor (state.selectedSquare.get().uint64 shl 32)
    for i, highlightedSq in highlightedSquares:
        h = h xor (highlightedSq.uint64 * (HASH_MIX_SQUARE xor (i.uint64 shl 12)))
    h = h xor (state.pendingPremoves.len.uint64 * HASH_MIX_PREMOVE_COUNT)
    for i, premove in state.pendingPremoves:
        h = h xor (premove.fromSq.uint64 * (HASH_MIX_PREMOVE_FROM xor i.uint64))
        h = h xor (premove.toSq.uint64 * (HASH_MIX_PREMOVE_TO xor (i.uint64 shl 8)))
    h = h xor (state.legalDestinations.len.uint64 * HASH_MIX_LEGAL_DEST_COUNT)
    for i, dest in state.legalDestinations:
        h = h xor (dest.uint64 * (HASH_MIX_SQUARE xor i.uint64))
    if state.dragSourceSquare.isSome():
        h = h xor (state.dragSourceSquare.get().uint64 * HASH_MIX_SQUARE)
    if not usesDragOverlay() and state.dragCursor.isSome():
        let dragCursor = state.dragCursor.get()
        h = h xor (dragCursor.x.uint64 * HASH_MIX_DRAG_X)
        h = h xor (dragCursor.y.uint64 * HASH_MIX_DRAG_Y)
    result = h != state.renderCache.lastBoardHash
    state.renderCache.lastBoardHash = h


proc evalBarOverlayChanged(state: AppState): bool =
    let boardPx = currentBoardPixelSize(state)
    let cellSize = getCellPixelSize()
    var h = boardPx.uint64 * HASH_MIX_BOARD_SIZE
    h = h xor (max(1, cellSize.w).uint64 shl 8)
    h = h xor (max(1, cellSize.h).uint64 shl 16)
    h = h xor (if state.flipped: 1'u64 else: 0'u64)
    let scoreOpt = state.currentEvalScore()
    if scoreOpt.isSome():
        h = h xor (cast[uint64](scoreOpt.get().int64) * HASH_MIX_ARROW_TO)
    result = h != state.renderCache.lastEvalBarHash
    state.renderCache.lastEvalBarHash = h


proc gameAnalysisGraphBackgroundChanged(state: AppState, widthCols, heightRows: int): bool =
    let cellSize = getCellPixelSize()
    var h = (widthCols.uint64 shl 8) xor (heightRows.uint64 shl 20)
    h = h xor (state.gameAnalysis.positions.len.uint64 * HASH_MIX_ARROW_COUNT)
    h = h xor (max(1, cellSize.w).uint64 shl 32)
    h = h xor (max(1, cellSize.h).uint64 shl 40)
    result = h != state.renderCache.lastGameAnalysisGraphBackgroundHash
    state.renderCache.lastGameAnalysisGraphBackgroundHash = h


proc gameAnalysisGraphMarkersChanged(state: AppState, widthCols, heightRows: int): bool =
    let cellSize = getCellPixelSize()
    var h = (widthCols.uint64 shl 8) xor (heightRows.uint64 shl 20)
    h = h xor (state.gameAnalysis.positions.len.uint64 * HASH_MIX_ARROW_COUNT)
    if state.gameAnalysis.division.middlegameStart.isSome():
        h = h xor (state.gameAnalysis.division.middlegameStart.get().uint64 * HASH_MIX_ARROW_FROM)
    if state.gameAnalysis.division.endgameStart.isSome():
        h = h xor (state.gameAnalysis.division.endgameStart.get().uint64 * HASH_MIX_ARROW_TO)
    h = h xor (max(1, cellSize.w).uint64 shl 32)
    h = h xor (max(1, cellSize.h).uint64 shl 40)
    result = h != state.renderCache.lastGameAnalysisGraphMarkersHash
    state.renderCache.lastGameAnalysisGraphMarkersHash = h


proc gameAnalysisGraphScaleChanged(state: AppState, widthCols, heightRows: int): bool =
    let cellSize = getCellPixelSize()
    var h = (widthCols.uint64 shl 8) xor (heightRows.uint64 shl 20)
    h = h xor (state.gameAnalysis.graphMode.ord.uint64 shl 48)
    let evalScale = currentEvalGraphScale(state)
    h = h xor (cast[uint64](int64(round(evalScale.absLimitCp))) * HASH_MIX_ARROW_TO)
    h = h xor (max(1, cellSize.w).uint64 shl 32)
    h = h xor (max(1, cellSize.h).uint64 shl 40)
    result = h != state.renderCache.lastGameAnalysisGraphScaleHash
    state.renderCache.lastGameAnalysisGraphScaleHash = h


proc gameAnalysisGraphCursorChanged(state: AppState, widthCols, heightRows, currentPly: int): bool =
    let cellSize = getCellPixelSize()
    var h = (widthCols.uint64 shl 8) xor (heightRows.uint64 shl 20)
    h = h xor (currentPly.uint64 * HASH_MIX_SQUARE)
    h = h xor (state.gameAnalysis.graphMode.ord.uint64 shl 48)
    if currentPly >= 0 and currentPly < state.gameAnalysis.positions.len:
        let position = state.gameAnalysis.positions[currentPly]
        h = h xor (position.positionKey * HASH_MIX_ARROW_FROM)
        if position.analyzed:
            let graphScore =
                if state.gameAnalysis.graphMode == GameAnalysisGraphEval:
                    state.displayScore(position.rawScore, position.material)
                else:
                    position.rawScore
            h = h xor (cast[uint64](graphScore.int64) * HASH_MIX_ARROW_TO)
    h = h xor (max(1, cellSize.w).uint64 shl 32)
    h = h xor (max(1, cellSize.h).uint64 shl 40)
    result = h != state.renderCache.lastGameAnalysisGraphCursorHash
    state.renderCache.lastGameAnalysisGraphCursorHash = h


proc engineArrowOverlayChanged(state: AppState): bool =
    let boardPx = currentBoardPixelSize(state)
    var h = boardPx.uint64 * HASH_MIX_BOARD_SIZE
    h = h xor (if state.flipped: 1'u64 else: 0'u64)
    h = h xor (if state.showEngineArrows: 4'u64 else: 0'u64)
    let engineMoves = analysisArrowMoves(state)
    h = h xor (engineMoves.len.uint64 * HASH_MIX_ARROW_COUNT)
    for i, move in engineMoves:
        h = h xor (move.startSquare().uint64 * (HASH_MIX_ARROW_FROM xor i.uint64))
        h = h xor (move.targetSquare().uint64 * (HASH_MIX_ARROW_TO xor (i.uint64 shl 8)))
    let threatMoves = threatArrowMoves(state)
    h = h xor (threatMoves.len.uint64 * HASH_MIX_USER_ARROW_COUNT)
    for i, arrow in threatMoves:
        h = h xor (arrow.fromSq.uint64 * (HASH_MIX_ARROW_FROM xor (i.uint64 shl 20)))
        h = h xor (arrow.toSq.uint64 * (HASH_MIX_ARROW_TO xor (i.uint64 shl 28)))
        h = h xor (arrow.brush.ord.uint64 shl (12 + (i mod 4) * 4))
    result = h != state.renderCache.lastEngineArrowHash
    state.renderCache.lastEngineArrowHash = h


proc userArrowOverlayChanged(state: AppState): bool =
    let boardPx = currentBoardPixelSize(state)
    var h = boardPx.uint64 * HASH_MIX_BOARD_SIZE
    h = h xor (if state.flipped: 1'u64 else: 0'u64)
    let userMoves = userArrowMoves(state)
    h = h xor (userMoves.len.uint64 * HASH_MIX_USER_ARROW_COUNT)
    for i, arrow in userMoves:
        h = h xor (arrow.fromSq.uint64 * (HASH_MIX_ARROW_FROM xor (i.uint64 shl 16)))
        h = h xor (arrow.toSq.uint64 * (HASH_MIX_ARROW_TO xor (i.uint64 shl 24)))
        h = h xor (arrow.brush.ord.uint64 shl (8 + (i mod 4) * 4))
    let previewArrow = currentUserArrow(state)
    if previewArrow.isSome():
        let arrow = previewArrow.get()
        h = h xor (arrow.fromSq.uint64 shl 32)
        h = h xor (arrow.toSq.uint64 shl 40)
        h = h xor (arrow.brush.ord.uint64 shl 48)
    result = h != state.renderCache.lastUserArrowHash
    state.renderCache.lastUserArrowHash = h


proc renderDraggedPiece(state: AppState, piece: Piece): PixelBuffer =
    let boardPx = currentBoardPixelSize(state)
    if boardPx <= 0:
        return newPixelBuffer(0, 0)

    let pieceImg = getPieceImage(piece)
    let squarePx = boardPx div 8
    let pad = max(1, squarePx div 8)
    let pieceSize = max(1, squarePx - pad * 2)
    result = newPixelBuffer(pieceSize, pieceSize)
    if pieceImg.width > 0:
        result.blendOverScaledSmooth(pieceImg, 0, 0, pieceSize, pieceSize)


proc hideEngineArrowOverlay(state: AppState) =
    if state.renderCache.engineArrowImageVisible:
        deletePlacement(ENGINE_ARROW_IMG_ID, ENGINE_ARROW_PLACEMENT_ID)
        deleteImage(ENGINE_ARROW_IMG_ID)
        state.renderCache.engineArrowImageVisible = false
    state.renderCache.lastEngineArrowHash = 0


proc hideEvalBarOverlay(state: AppState) =
    if state.renderCache.evalBarImageVisible:
        deletePlacement(EVAL_BAR_IMG_ID, EVAL_BAR_PLACEMENT_ID)
        deleteImage(EVAL_BAR_IMG_ID)
        state.renderCache.evalBarImageVisible = false
    state.renderCache.lastEvalBarHash = 0


proc hideGameAnalysisGraph*(state: AppState) =
    if state.renderCache.gameAnalysisGraphBackgroundVisible:
        deletePlacement(GAME_ANALYSIS_GRAPH_BG_IMG_ID, GAME_ANALYSIS_GRAPH_BG_PLACEMENT_ID)
        deleteImage(GAME_ANALYSIS_GRAPH_BG_IMG_ID)
        state.renderCache.gameAnalysisGraphBackgroundVisible = false
    for tileIndex in 0..<GAME_ANALYSIS_GRAPH_TILE_COUNT:
        if state.renderCache.gameAnalysisGraphDataTileVisible[tileIndex]:
            deletePlacement(GAME_ANALYSIS_GRAPH_DATA_IMG_IDS[tileIndex], 1)
            deleteImage(GAME_ANALYSIS_GRAPH_DATA_IMG_IDS[tileIndex])
            state.renderCache.gameAnalysisGraphDataTileVisible[tileIndex] = false
        if state.renderCache.gameAnalysisGraphLineTileVisible[tileIndex]:
            deletePlacement(GAME_ANALYSIS_GRAPH_LINE_IMG_IDS[tileIndex], 1)
            deleteImage(GAME_ANALYSIS_GRAPH_LINE_IMG_IDS[tileIndex])
            state.renderCache.gameAnalysisGraphLineTileVisible[tileIndex] = false
    if state.renderCache.gameAnalysisGraphMarkersVisible:
        deletePlacement(GAME_ANALYSIS_GRAPH_MARKERS_IMG_ID, GAME_ANALYSIS_GRAPH_MARKERS_PLACEMENT_ID)
        deleteImage(GAME_ANALYSIS_GRAPH_MARKERS_IMG_ID)
        state.renderCache.gameAnalysisGraphMarkersVisible = false
    if state.renderCache.gameAnalysisGraphScaleVisible:
        deletePlacement(GAME_ANALYSIS_GRAPH_SCALE_IMG_ID, GAME_ANALYSIS_GRAPH_SCALE_PLACEMENT_ID)
        deleteImage(GAME_ANALYSIS_GRAPH_SCALE_IMG_ID)
        state.renderCache.gameAnalysisGraphScaleVisible = false
    if state.renderCache.gameAnalysisGraphCursorVisible:
        deletePlacement(GAME_ANALYSIS_GRAPH_CURSOR_IMG_ID, GAME_ANALYSIS_GRAPH_CURSOR_PLACEMENT_ID)
        deleteImage(GAME_ANALYSIS_GRAPH_CURSOR_IMG_ID)
        state.renderCache.gameAnalysisGraphCursorVisible = false
    state.renderCache.lastGameAnalysisGraphBackgroundHash = 0
    for tileIndex in 0..<GAME_ANALYSIS_GRAPH_TILE_COUNT:
        state.renderCache.lastGameAnalysisGraphDataTileHashes[tileIndex] = 0
        state.renderCache.lastGameAnalysisGraphLineTileHashes[tileIndex] = 0
    state.renderCache.lastGameAnalysisGraphMarkersHash = 0
    state.renderCache.lastGameAnalysisGraphScaleHash = 0
    state.renderCache.lastGameAnalysisGraphCursorHash = 0


proc hideUserArrowOverlay(state: AppState) =
    if state.renderCache.userArrowImageVisible:
        deletePlacement(USER_ARROW_IMG_ID, USER_ARROW_PLACEMENT_ID)
        deleteImage(USER_ARROW_IMG_ID)
        state.renderCache.userArrowImageVisible = false
    state.renderCache.lastUserArrowHash = 0


proc displayEngineArrowOverlay(state: AppState, termRow, termCol: int) =
    let boardPx = currentBoardPixelSize(state)
    let engineMoves = analysisArrowMoves(state)
    let threatMoves = threatArrowMoves(state)
    if boardPx <= 0 or (engineMoves.len == 0 and threatMoves.len == 0):
        state.hideEngineArrowOverlay()
        return

    if not engineArrowOverlayChanged(state):
        if not state.renderCache.engineArrowImageVisible:
            placeImage(ENGINE_ARROW_IMG_ID, ENGINE_ARROW_PLACEMENT_ID, termRow, termCol, z=1)
            state.renderCache.engineArrowImageVisible = true
        return

    if state.renderCache.engineArrowImageVisible:
        deletePlacement(ENGINE_ARROW_IMG_ID, ENGINE_ARROW_PLACEMENT_ID)
        deleteImage(ENGINE_ARROW_IMG_ID)

    uploadImage(renderEngineArrowOverlay(state), ENGINE_ARROW_IMG_ID)
    placeImage(ENGINE_ARROW_IMG_ID, ENGINE_ARROW_PLACEMENT_ID, termRow, termCol, z=1)
    state.renderCache.engineArrowImageVisible = true


proc displayUserArrowOverlay(state: AppState, termRow, termCol: int) =
    let boardPx = currentBoardPixelSize(state)
    let userMoves = userArrowMoves(state)
    let previewArrow = currentUserArrow(state)
    if boardPx <= 0 or (userMoves.len == 0 and previewArrow.isNone()):
        state.hideUserArrowOverlay()
        return

    if not userArrowOverlayChanged(state):
        if not state.renderCache.userArrowImageVisible:
            placeImage(USER_ARROW_IMG_ID, USER_ARROW_PLACEMENT_ID, termRow, termCol, z=2)
            state.renderCache.userArrowImageVisible = true
        return

    if state.renderCache.userArrowImageVisible:
        deletePlacement(USER_ARROW_IMG_ID, USER_ARROW_PLACEMENT_ID)
        deleteImage(USER_ARROW_IMG_ID)

    uploadImage(renderUserArrowOverlay(state), USER_ARROW_IMG_ID)
    placeImage(USER_ARROW_IMG_ID, USER_ARROW_PLACEMENT_ID, termRow, termCol, z=2)
    state.renderCache.userArrowImageVisible = true


proc displayArrowOverlay(state: AppState, termRow, termCol: int) =
    state.displayEngineArrowOverlay(termRow, termCol)
    state.displayUserArrowOverlay(termRow, termCol)


proc displayEvalBar*(state: AppState, termRow, termCol: int) =
    let boardPx = currentBoardPixelSize(state)
    if boardPx <= 0 or state.mode == ModePlay:
        state.hideEvalBarOverlay()
        return

    if not evalBarOverlayChanged(state):
        if not state.renderCache.evalBarImageVisible:
            placeImage(EVAL_BAR_IMG_ID, EVAL_BAR_PLACEMENT_ID, termRow, termCol, z=0)
            state.renderCache.evalBarImageVisible = true
        return

    if state.renderCache.evalBarImageVisible:
        deletePlacement(EVAL_BAR_IMG_ID, EVAL_BAR_PLACEMENT_ID)
        deleteImage(EVAL_BAR_IMG_ID)

    uploadImage(renderEvalBarOverlay(state), EVAL_BAR_IMG_ID)
    placeImage(EVAL_BAR_IMG_ID, EVAL_BAR_PLACEMENT_ID, termRow, termCol, z=0)
    state.renderCache.evalBarImageVisible = true


proc displayGameAnalysisGraph*(state: AppState, termRow, termCol, widthCols, heightRows, currentPly: int) =
    if not hasGameAnalysisGraph(state) or widthCols <= 0 or heightRows <= 0:
        state.hideGameAnalysisGraph()
        return

    let cellSize = getCellPixelSize()
    let cellW = max(1, cellSize.w)
    let cellH = max(1, cellSize.h)
    let widthPx = max(1, widthCols * cellW)
    let heightPx = max(1, heightRows * cellH)

    if gameAnalysisGraphBackgroundChanged(state, widthCols, heightRows):
        if state.renderCache.gameAnalysisGraphBackgroundVisible:
            deletePlacement(GAME_ANALYSIS_GRAPH_BG_IMG_ID, GAME_ANALYSIS_GRAPH_BG_PLACEMENT_ID)
            deleteImage(GAME_ANALYSIS_GRAPH_BG_IMG_ID)
        uploadImage(renderGameAnalysisGraphBackground(state, widthPx, heightPx), GAME_ANALYSIS_GRAPH_BG_IMG_ID)
        placeImage(GAME_ANALYSIS_GRAPH_BG_IMG_ID, GAME_ANALYSIS_GRAPH_BG_PLACEMENT_ID, termRow, termCol, z=0)
        state.renderCache.gameAnalysisGraphBackgroundVisible = true
    elif not state.renderCache.gameAnalysisGraphBackgroundVisible:
        placeImage(GAME_ANALYSIS_GRAPH_BG_IMG_ID, GAME_ANALYSIS_GRAPH_BG_PLACEMENT_ID, termRow, termCol, z=0)
        state.renderCache.gameAnalysisGraphBackgroundVisible = true

    let dataBuffer = renderGameAnalysisGraphData(state, widthPx, heightPx)
    for tileIndex in 0..<GAME_ANALYSIS_GRAPH_TILE_COUNT:
        let tileBounds = graphTileBounds(widthPx, tileIndex)
        let tileBuffer = slicePixelBuffer(dataBuffer, tileBounds.startX, tileBounds.width)
        let tileHashSeed =
            (widthCols.uint64 shl 8) xor
            (heightRows.uint64 shl 20) xor
            (tileIndex.uint64 shl 52) xor
            (state.gameAnalysis.graphMode.ord.uint64 shl 56)
        let tileHash = hashPixelBuffer(tileBuffer, tileHashSeed)
        let imageId = GAME_ANALYSIS_GRAPH_DATA_IMG_IDS[tileIndex]
        let placementId = 1
        let tileTermCol = termCol + tileBounds.startX div cellW
        let tileOffsetX = tileBounds.startX mod cellW
        let changed = tileHash != state.renderCache.lastGameAnalysisGraphDataTileHashes[tileIndex]
        if changed:
            if state.renderCache.gameAnalysisGraphDataTileVisible[tileIndex]:
                deletePlacement(imageId, placementId)
                deleteImage(imageId)
            uploadImage(tileBuffer, imageId)
            placeImage(imageId, placementId, termRow, tileTermCol, x=tileOffsetX, z=1)
            state.renderCache.gameAnalysisGraphDataTileVisible[tileIndex] = true
            state.renderCache.lastGameAnalysisGraphDataTileHashes[tileIndex] = tileHash
        elif not state.renderCache.gameAnalysisGraphDataTileVisible[tileIndex]:
            placeImage(imageId, placementId, termRow, tileTermCol, x=tileOffsetX, z=1)
            state.renderCache.gameAnalysisGraphDataTileVisible[tileIndex] = true

    if gameAnalysisGraphMarkersChanged(state, widthCols, heightRows):
        if state.renderCache.gameAnalysisGraphMarkersVisible:
            deletePlacement(GAME_ANALYSIS_GRAPH_MARKERS_IMG_ID, GAME_ANALYSIS_GRAPH_MARKERS_PLACEMENT_ID)
            deleteImage(GAME_ANALYSIS_GRAPH_MARKERS_IMG_ID)
        uploadImage(renderGameAnalysisGraphMarkers(state, widthPx, heightPx), GAME_ANALYSIS_GRAPH_MARKERS_IMG_ID)
        placeImage(GAME_ANALYSIS_GRAPH_MARKERS_IMG_ID, GAME_ANALYSIS_GRAPH_MARKERS_PLACEMENT_ID, termRow, termCol, z=2)
        state.renderCache.gameAnalysisGraphMarkersVisible = true
    elif not state.renderCache.gameAnalysisGraphMarkersVisible:
        placeImage(GAME_ANALYSIS_GRAPH_MARKERS_IMG_ID, GAME_ANALYSIS_GRAPH_MARKERS_PLACEMENT_ID, termRow, termCol, z=2)
        state.renderCache.gameAnalysisGraphMarkersVisible = true

    if gameAnalysisGraphScaleChanged(state, widthCols, heightRows):
        if state.renderCache.gameAnalysisGraphScaleVisible:
            deletePlacement(GAME_ANALYSIS_GRAPH_SCALE_IMG_ID, GAME_ANALYSIS_GRAPH_SCALE_PLACEMENT_ID)
            deleteImage(GAME_ANALYSIS_GRAPH_SCALE_IMG_ID)
        uploadImage(renderGameAnalysisGraphScale(state, widthPx, heightPx), GAME_ANALYSIS_GRAPH_SCALE_IMG_ID)
        placeImage(GAME_ANALYSIS_GRAPH_SCALE_IMG_ID, GAME_ANALYSIS_GRAPH_SCALE_PLACEMENT_ID, termRow, termCol, z=3)
        state.renderCache.gameAnalysisGraphScaleVisible = true
    elif not state.renderCache.gameAnalysisGraphScaleVisible:
        placeImage(GAME_ANALYSIS_GRAPH_SCALE_IMG_ID, GAME_ANALYSIS_GRAPH_SCALE_PLACEMENT_ID, termRow, termCol, z=3)
        state.renderCache.gameAnalysisGraphScaleVisible = true

    if gameAnalysisGraphCursorChanged(state, widthCols, heightRows, currentPly):
        if state.renderCache.gameAnalysisGraphCursorVisible:
            deletePlacement(GAME_ANALYSIS_GRAPH_CURSOR_IMG_ID, GAME_ANALYSIS_GRAPH_CURSOR_PLACEMENT_ID)
            deleteImage(GAME_ANALYSIS_GRAPH_CURSOR_IMG_ID)
        uploadImage(renderGameAnalysisGraphCursor(state, widthPx, heightPx, currentPly), GAME_ANALYSIS_GRAPH_CURSOR_IMG_ID)
        placeImage(GAME_ANALYSIS_GRAPH_CURSOR_IMG_ID, GAME_ANALYSIS_GRAPH_CURSOR_PLACEMENT_ID, termRow, termCol, z=4)
        state.renderCache.gameAnalysisGraphCursorVisible = true
    elif not state.renderCache.gameAnalysisGraphCursorVisible:
        placeImage(GAME_ANALYSIS_GRAPH_CURSOR_IMG_ID, GAME_ANALYSIS_GRAPH_CURSOR_PLACEMENT_ID, termRow, termCol, z=4)
        state.renderCache.gameAnalysisGraphCursorVisible = true


proc displayDraggedPiece(state: AppState, termRow, termCol: int) =
    if not usesDragOverlay():
        if state.renderCache.dragImageVisible:
            deletePlacement(DRAG_IMG_ID, DRAG_PLACEMENT_ID)
            state.renderCache.lastDragHash = 0
            state.renderCache.dragImageVisible = false
        return

    let boardPx = currentBoardPixelSize(state)
    let dragging = state.dragSourceSquare.isSome() and state.dragCursor.isSome()
    if not dragging or boardPx <= 0:
        if state.renderCache.dragImageVisible:
            deletePlacement(DRAG_IMG_ID, DRAG_PLACEMENT_ID)
            state.renderCache.lastDragHash = 0
            state.renderCache.dragImageVisible = false
        return

    let sourceSq = state.dragSourceSquare.get()
    let piece = displayBoardState(state).on(sourceSq)
    if piece.kind == Empty:
        if state.renderCache.dragImageVisible:
            deletePlacement(DRAG_IMG_ID, DRAG_PLACEMENT_ID)
            state.renderCache.lastDragHash = 0
            state.renderCache.dragImageVisible = false
        return

    let squarePx = boardPx div 8
    let pad = max(1, squarePx div 8)
    let pieceSize = max(1, squarePx - pad * 2)
    let dragCursor = state.dragCursor.get()
    let topLeft = draggedPieceTopLeft(boardPx, pieceSize, dragCursor)
    let cellSize = getCellPixelSize()
    let cellW = max(1, cellSize.w)
    let cellH = max(1, cellSize.h)
    let placementCol = termCol + (topLeft.x div cellW)
    let placementRow = termRow + (topLeft.y div cellH)
    let offsetX = topLeft.x mod cellW
    let offsetY = topLeft.y mod cellH

    var h = sourceSq.uint64 * HASH_MIX_SQUARE
    h = h xor (piece.kind.uint64 shl 8)
    h = h xor (piece.color.uint64 shl 16)
    h = h xor (placementCol.uint64 * HASH_MIX_DRAG_X)
    h = h xor (placementRow.uint64 * HASH_MIX_DRAG_Y)
    h = h xor (offsetX.uint64 shl 24)
    h = h xor (offsetY.uint64 shl 32)
    h = h xor (pieceSize.uint64 * HASH_MIX_DRAG_SIZE)

    if h == state.renderCache.lastDragHash:
        return

    if piece != state.renderCache.lastDragPiece or pieceSize != state.renderCache.lastDragPieceSize:
        if state.renderCache.lastDragPiece.kind != Empty:
            deleteImage(DRAG_IMG_ID)
        uploadImage(renderDraggedPiece(state, piece), DRAG_IMG_ID)
        state.renderCache.lastDragPiece = piece
        state.renderCache.lastDragPieceSize = pieceSize

    placeImage(DRAG_IMG_ID, DRAG_PLACEMENT_ID, placementRow, placementCol, offsetX, offsetY, z=3)
    state.renderCache.lastDragHash = h
    state.renderCache.dragImageVisible = true


proc displayBoard*(state: AppState, termRow, termCol: int) =
    ## Renders and transmits the board image only when state changes.
    if not boardVisible(state):
        hideBoardImages(state)
        return
    if not boardChanged(state):
        displayArrowOverlay(state, termRow, termCol)
        displayDraggedPiece(state, termRow, termCol)
        return
    let img = renderBoardImage(state)
    let nextBoardSlot =
        if state.renderCache.activeBoardSlot.isSome() and state.renderCache.activeBoardSlot.get() == 0: 1
        else: 0
    let nextBoardImgId = boardImageId(nextBoardSlot)
    let nextBoardPlacementId = boardPlacementId(nextBoardSlot)

    uploadImage(img, nextBoardImgId)
    placeImage(nextBoardImgId, nextBoardPlacementId, termRow, termCol)

    if state.renderCache.boardImageVisible and state.renderCache.activeBoardSlot.isSome():
        let oldBoardImgId = boardImageId(state.renderCache.activeBoardSlot.get())
        let oldBoardPlacementId = boardPlacementId(state.renderCache.activeBoardSlot.get())
        deletePlacement(oldBoardImgId, oldBoardPlacementId)
        deleteImage(oldBoardImgId)

    state.renderCache.activeBoardSlot = some(nextBoardSlot)
    state.renderCache.boardImageVisible = true
    displayArrowOverlay(state, termRow, termCol)
    displayDraggedPiece(state, termRow, termCol)


proc getCellPixelSize*: tuple[w, h: int] =
    ## Queries the terminal for the actual cell pixel size via TIOCGWINSZ.
    ## Falls back to 9x18 if unavailable.
    var ws: IOctl_WinSize
    if ioctl(STDOUT_FILENO.cint, TIOCGWINSZ, addr ws) == 0 and ws.ws_xpixel > 0 and ws.ws_row > 0:
        result.w = ws.ws_xpixel.int div ws.ws_col.int
        result.h = ws.ws_ypixel.int div ws.ws_row.int
    else:
        result.w = 9
        result.h = 18


proc boardWidth*(state: AppState): int =
    ## Terminal columns the board image occupies
    let boardPx = currentBoardPixelSize(state)
    if boardPx <= 0:
        return 0
    let cellW = getCellPixelSize().w
    if cellW > 0:
        return (boardPx + cellW - 1) div cellW
    boardPx div 9 + 2


proc boardHeight*(state: AppState): int =
    ## Terminal rows the board image occupies
    let boardPx = currentBoardPixelSize(state)
    if boardPx <= 0:
        return 0
    let cellH = getCellPixelSize().h
    if cellH > 0:
        return (boardPx + cellH - 1) div cellH
    boardPx div 18 + 1


proc gameAnalysisGraphTermRow*(state: AppState): int =
    BOARD_MARGIN_Y + boardHeight(state) + evalBarLabelRows(state) + GAME_ANALYSIS_GRAPH_GAP_ROWS + 1


proc termPixelToSquare*(state: AppState, mouseX, mouseY, boardTermRow, boardTermCol: int): Option[Square] =
    ## Maps a terminal pixel coordinate to a board square, given the
    ## board image's top-left terminal position (1-based cells).
    let boardPx = currentBoardPixelSize(state)
    if boardPx <= 0:
        return none(Square)

    let cellSize = getCellPixelSize()
    let boardOriginX = (boardTermCol - 1) * cellSize.w
    let boardOriginY = (boardTermRow - 1) * cellSize.h
    let relX = mouseX - boardOriginX
    let relY = mouseY - boardOriginY

    if relX < 0 or relX >= boardPx or relY < 0 or relY >= boardPx:
        return none(Square)

    var file = (relX * 8) div boardPx
    var rank = (relY * 8) div boardPx

    if state.flipped:
        file = 7 - file
        rank = 7 - rank

    if file in 0..7 and rank in 0..7:
        return some(makeSquare(rank, file))
    none(Square)


proc termPixelToBoardPixel*(state: AppState, mouseX, mouseY, boardTermRow, boardTermCol: int): tuple[x, y: int] =
    ## Maps a terminal pixel coordinate to a clamped pixel position inside the board image.
    let boardPx = currentBoardPixelSize(state)
    if boardPx <= 0:
        return (x: 0, y: 0)

    let cellSize = getCellPixelSize()
    let boardOriginX = (boardTermCol - 1) * cellSize.w
    let boardOriginY = (boardTermRow - 1) * cellSize.h

    result.x = max(0, min(boardPx - 1, mouseX - boardOriginX))
    result.y = max(0, min(boardPx - 1, mouseY - boardOriginY))
