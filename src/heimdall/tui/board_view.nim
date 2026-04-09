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

## Board rendering: composites pre-rendered piece images onto the
## board SVG and sends the result via the kitty graphics protocol.

import std/options
from std/posix import STDOUT_FILENO
from std/termios import IOctl_WinSize, TIOCGWINSZ, ioctl

import illwill
import heimdall/[pieces, board, bitboards]
import heimdall/tui/[state, pixel, kitty, rawinput]


const
    BOARD_IMG_IDS = [1, 3]
    BOARD_PLACEMENT_IDS = [1, 2]
    DRAG_IMG_ID = 2
    DRAG_PLACEMENT_ID = 1

    BOARD_MARGIN_X* = 1
    BOARD_MARGIN_Y* = 1
    EVAL_BAR_GUTTER_WIDTH* = 6
    BOARD_GAP_COLS* = 2
    INFO_PANEL_MIN_WIDTH* = 24
    BOARD_MIN_PX* = 320

    INPUT_UI_ROWS = 3
    AUTOCOMPLETE_MAX_ROWS = 8
    TRAILING_MARGIN_COLS = 1


proc getCellPixelSize*: tuple[w, h: int]


proc usesDragOverlay: bool =
    detectTerminalKind() != tkWezTerm


proc draggedPieceTopLeft(boardPx, pieceSize: int, dragCursor: tuple[x, y: int]): tuple[x, y: int] =
    result.x = max(0, min(boardPx - pieceSize, dragCursor.x - pieceSize div 2))
    result.y = max(0, min(boardPx - pieceSize, dragCursor.y - pieceSize div 2))


proc autocompleteRows(state: AppState): int =
    if state.acActive and state.acSuggestions.len > 0:
        return min(state.acSuggestions.len, AUTOCOMPLETE_MAX_ROWS)
    0


proc bottomUiRows(state: AppState): int =
    INPUT_UI_ROWS + autocompleteRows(state)


proc boardStartX*(): int =
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

    let dragging = state.dragSourceSquare.isSome() and state.dragCursor.isSome()
    let draggedSquare = if dragging: state.dragSourceSquare.get() else: Square(0)
    let threats = state.board.position.threats
    let sideToMove = state.board.sideToMove()
    let inCheck = state.board.inCheck()
    let kingSquare = if inCheck: state.board.position.pieces(King, sideToMove).toSquare() else: Square(0)

    for displayRank in 0..7:
        let rank = if state.flipped: 7 - displayRank else: displayRank
        for displayFile in 0..7:
            let file = if state.flipped: 7 - displayFile else: displayFile
            let sq = makeSquare(rank, file)
            let piece = state.board.on(sq)

            let ox = displayFile * squarePx
            let oy = displayRank * squarePx

            if state.lastMove.isSome():
                let lm = state.lastMove.get()
                if sq == lm.fromSq or sq == lm.toSq:
                    result.tintRect(ox, oy, ox + squarePx - 1, oy + squarePx - 1, LAST_MOVE_TINT)

            var premoveIndex = -1
            for i, premove in state.pendingPremoves:
                if sq == premove.fromSq or sq == premove.toSq:
                    premoveIndex = i
            if premoveIndex >= 0:
                result.tintRect(ox, oy, ox + squarePx - 1, oy + squarePx - 1, premoveTint(premoveIndex))

            if state.selectedSquare.isSome() and sq == state.selectedSquare.get():
                result.tintRect(ox, oy, ox + squarePx - 1, oy + squarePx - 1, SELECTED_TINT)

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

            if state.showThreats and piece.kind != Empty and piece.color == sideToMove:
                if sq in threats:
                    result.tintRect(ox, oy, ox + squarePx - 1, oy + squarePx - 1, THREATENED_TINT)

            if inCheck and sq == kingSquare:
                result.tintRect(ox, oy, ox + squarePx - 1, oy + squarePx - 1, CHECK_TINT)

            if piece.kind != Empty and (not dragging or sq != draggedSquare):
                let pieceImg = getPieceImage(piece)
                if pieceImg.width > 0:
                    result.blendOverScaled(pieceImg, ox + pad, oy + pad, pieceSize, pieceSize)

    if dragging and not usesDragOverlay():
        let piece = state.board.on(draggedSquare)
        if piece.kind != Empty:
            let pieceImg = getPieceImage(piece)
            if pieceImg.width > 0:
                let topLeft = draggedPieceTopLeft(boardPx, pieceSize, state.dragCursor.get())
                result.blendOverScaled(pieceImg, topLeft.x, topLeft.y, pieceSize, pieceSize)


var lastBoardHash: uint64 = 0
var lastDragHash: uint64 = 0
var lastDragPiece: Piece = nullPiece()
var lastDragPieceSize: int = 0
var boardImageVisible: bool = false
var dragImageVisible: bool = false
var activeBoardSlot: int = -1


proc boardImageId(slot: int): int =
    BOARD_IMG_IDS[slot]


proc boardPlacementId(slot: int): int =
    BOARD_PLACEMENT_IDS[slot]


proc resetBoardHash* =
    ## Forces the board to be re-rendered on the next displayBoard call
    lastBoardHash = 0
    lastDragHash = 0
    lastDragPiece = nullPiece()
    lastDragPieceSize = 0


proc hideBoardImages* =
    if not boardImageVisible and not dragImageVisible:
        return
    if boardImageVisible:
        for slot in 0..BOARD_IMG_IDS.high:
            deletePlacement(boardImageId(slot), boardPlacementId(slot))
            deleteImage(boardImageId(slot))
        boardImageVisible = false
        activeBoardSlot = -1
    if dragImageVisible:
        deletePlacement(DRAG_IMG_ID, DRAG_PLACEMENT_ID)
        deleteImage(DRAG_IMG_ID)
        dragImageVisible = false
    resetBoardHash()


proc boardChanged*(state: AppState): bool =
    let boardPx = currentBoardPixelSize(state)
    var h: uint64 = state.board.zobristKey().uint64
    h = h xor (if state.flipped: 1'u64 else: 0'u64)
    h = h xor (if state.showThreats: 2'u64 else: 0'u64)
    h = h xor (boardPx.uint64 * 0xD6E8FEB86659FD93'u64)
    if state.lastMove.isSome():
        let lm = state.lastMove.get()
        h = h xor (lm.fromSq.uint64 shl 16) xor (lm.toSq.uint64 shl 24)
    if state.selectedSquare.isSome():
        h = h xor (state.selectedSquare.get().uint64 shl 32)
    h = h xor (state.pendingPremoves.len.uint64 * 0x94D049BB133111EB'u64)
    for i, premove in state.pendingPremoves:
        h = h xor (premove.fromSq.uint64 * (0x94D049BB133111EB'u64 xor i.uint64))
        h = h xor (premove.toSq.uint64 * (0x2545F4914F6CDD1D'u64 xor (i.uint64 shl 8)))
    h = h xor (state.legalDestinations.len.uint64 * 0xBF58476D1CE4E5B9'u64)
    for i, dest in state.legalDestinations:
        h = h xor (dest.uint64 * (0x9E3779B185EBCA87'u64 xor i.uint64))
    if state.dragSourceSquare.isSome():
        h = h xor (state.dragSourceSquare.get().uint64 * 0x9E3779B185EBCA87'u64)
    if not usesDragOverlay() and state.dragCursor.isSome():
        let dragCursor = state.dragCursor.get()
        h = h xor (dragCursor.x.uint64 * 0x517CC1B727220A95'u64)
        h = h xor (dragCursor.y.uint64 * 0xC2B2AE3D27D4EB4F'u64)
    result = h != lastBoardHash
    lastBoardHash = h


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
        result.blendOverScaled(pieceImg, 0, 0, pieceSize, pieceSize)


proc displayDraggedPiece(state: AppState, termRow, termCol: int) =
    if not usesDragOverlay():
        if dragImageVisible:
            deletePlacement(DRAG_IMG_ID, DRAG_PLACEMENT_ID)
            lastDragHash = 0
            dragImageVisible = false
        return

    let boardPx = currentBoardPixelSize(state)
    let dragging = state.dragSourceSquare.isSome() and state.dragCursor.isSome()
    if not dragging or boardPx <= 0:
        if dragImageVisible:
            deletePlacement(DRAG_IMG_ID, DRAG_PLACEMENT_ID)
            lastDragHash = 0
            dragImageVisible = false
        return

    let sourceSq = state.dragSourceSquare.get()
    let piece = state.board.on(sourceSq)
    if piece.kind == Empty:
        if dragImageVisible:
            deletePlacement(DRAG_IMG_ID, DRAG_PLACEMENT_ID)
            lastDragHash = 0
            dragImageVisible = false
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

    var h = sourceSq.uint64 * 0x9E3779B185EBCA87'u64
    h = h xor (piece.kind.uint64 shl 8)
    h = h xor (piece.color.uint64 shl 16)
    h = h xor (placementCol.uint64 * 0x517CC1B727220A95'u64)
    h = h xor (placementRow.uint64 * 0xC2B2AE3D27D4EB4F'u64)
    h = h xor (offsetX.uint64 shl 24)
    h = h xor (offsetY.uint64 shl 32)
    h = h xor (pieceSize.uint64 * 0xDB4F0B9175AE2165'u64)

    if h == lastDragHash:
        return

    if piece != lastDragPiece or pieceSize != lastDragPieceSize:
        if lastDragPiece.kind != Empty:
            deleteImage(DRAG_IMG_ID)
        uploadImage(renderDraggedPiece(state, piece), DRAG_IMG_ID)
        lastDragPiece = piece
        lastDragPieceSize = pieceSize

    placeImage(DRAG_IMG_ID, DRAG_PLACEMENT_ID, placementRow, placementCol, offsetX, offsetY, z=1)
    lastDragHash = h
    dragImageVisible = true


proc displayBoard*(state: AppState, termRow, termCol: int) =
    ## Renders and transmits the board image only when state changes.
    if not boardVisible(state):
        hideBoardImages()
        return
    if not boardChanged(state):
        displayDraggedPiece(state, termRow, termCol)
        return
    let img = renderBoardImage(state)
    let nextBoardSlot = if activeBoardSlot == 0: 1 else: 0
    let nextBoardImgId = boardImageId(nextBoardSlot)
    let nextBoardPlacementId = boardPlacementId(nextBoardSlot)

    uploadImage(img, nextBoardImgId)
    placeImage(nextBoardImgId, nextBoardPlacementId, termRow, termCol)

    if boardImageVisible and activeBoardSlot >= 0:
        let oldBoardImgId = boardImageId(activeBoardSlot)
        let oldBoardPlacementId = boardPlacementId(activeBoardSlot)
        deletePlacement(oldBoardImgId, oldBoardPlacementId)
        deleteImage(oldBoardImgId)

    activeBoardSlot = nextBoardSlot
    boardImageVisible = true
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
