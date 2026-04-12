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

import std/[options, monotimes, times]
from std/posix import STDOUT_FILENO
from std/termios import IOctl_WinSize, TIOCGWINSZ, ioctl

import illwill
import heimdall/[pieces, board, bitboards, moves, eval]
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

    BOARD_MARGIN_X* = 1
    BOARD_MARGIN_Y* = 1
    EVAL_BAR_GUTTER_WIDTH* = 6
    BOARD_GAP_COLS* = 2
    INFO_PANEL_MIN_WIDTH* = 24
    BOARD_MIN_PX* = 320

    INPUT_UI_ROWS = 3
    AUTOCOMPLETE_MAX_ROWS = 8
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


proc bottomUiRows(state: AppState): int =
    INPUT_UI_ROWS + reservedAutocompleteRows() + evalBarLabelRows(state)


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


proc currentEvalScore(state: AppState): Option[Score] =
    if state.mode == ModePlay:
        return none(Score)
    if state.analysis.linesPositionKey != state.board.zobristKey().uint64 or state.analysis.lines.len == 0:
        return none(Score)
    some(state.analysis.lines[0].score)


proc renderEvalBarOverlay(state: AppState): PixelBuffer =
    let boardPx = currentBoardPixelSize(state)
    let cellSize = getCellPixelSize()
    let gutterPx = EVAL_BAR_GUTTER_WIDTH * max(1, cellSize.w)
    if boardPx <= 0 or gutterPx <= 0 or state.mode == ModePlay:
        return newPixelBuffer(0, 0)

    let scoreOpt = state.currentEvalScore()
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
    let threats = state.board.position.threats
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
    state.renderCache.lastEngineArrowHash = 0
    state.renderCache.lastUserArrowHash = 0
    state.renderCache.lastDragHash = 0
    state.renderCache.lastDragPiece = nullPiece()
    state.renderCache.lastDragPieceSize = 0


proc hideBoardImages*(state: AppState) =
    if not state.renderCache.boardImageVisible and
       not state.renderCache.evalBarImageVisible and
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
