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

## Key and mouse event dispatch for the TUI

import std/[options, strutils, strformat]

import illwill
import heimdall/[pieces, movegen, moves, board]
import heimdall/tui/[state, san, input, analysis, play, rawinput, board_view]


proc getLegalMovesFrom(state: AppState, sq: Square): seq[Square] =
    ## Returns all legal destination squares from the given square
    var moves = newMoveList()
    state.board.generateMoves(moves)
    for move in moves:
        if move.startSquare() == sq:
            result.add(move.targetSquare())


proc applyMove*(state: AppState, move: Move)


proc resetNavigationState(state: AppState) =
    state.resetSquareSelection()


proc refreshAfterNavigation(state: AppState) =
    state.resetNavigationState()
    if state.analysis.running:
        restartAnalysis(state)


proc replayToStart(state: AppState): bool =
    result = false
    while undoLastRecordedMove(state):
        result = true


proc replayStepForward(state: AppState): bool =
    if state.mode != ModeReplay or state.replay.moveIndex >= state.replay.moves.len:
        return false

    let move = state.replay.moves[state.replay.moveIndex]
    let sanStr = state.board.toSAN(move)
    state.lastMove = some((fromSq: move.startSquare(), toSq: move.targetSquare()))
    discard state.board.makeMove(move)
    state.addMoveRecord(move, sanStr)
    inc state.replay.moveIndex
    state.undoneHistory = @[]
    true


proc replayToEnd(state: AppState): bool =
    result = false
    if state.mode == ModeReplay:
        while replayStepForward(state):
            result = true
    else:
        while redoUndoneMove(state):
            result = true

proc isPromotionMove(state: AppState, fromSq, toSq: Square): bool =
    ## Checks if any legal move from fromSq to toSq is a promotion
    var moves = newMoveList()
    state.board.generateMoves(moves)
    for move in moves:
        if move.startSquare() == fromSq and move.targetSquare() == toSq and move.isPromotion():
            return true


proc findMove(state: AppState, fromSq, toSq: Square, promotionPiece: PieceKind = Queen): Move =
    ## Finds the legal move from fromSq to toSq, or returns nullMove.
    ## For promotions, uses the specified piece.
    var moves = newMoveList()
    state.board.generateMoves(moves)
    for move in moves:
        if move.startSquare() == fromSq and move.targetSquare() == toSq:
            if move.isPromotion():
                if move.flag().promotionToPiece() == promotionPiece:
                    return move
            else:
                return move
    return nullMove()


proc startPromotionChoice(state: AppState, fromSq, toSq: Square) =
    ## Enters promotion piece selection mode
    state.promotionPending = true
    state.promotionFrom = fromSq
    state.promotionTo = toSq
    state.setStatus("Promote to: [Q]ueen / [R]ook / [B]ishop / [N]knight")


proc maxHelpScroll: int =
    let panelHeight = terminalHeight() - 4
    max(0, helpLineCount() - helpViewportHeight(panelHeight))


proc completePromotion*(state: AppState, piece: PieceKind) =
    ## Completes a pending promotion with the chosen piece
    state.promotionPending = false
    let move = findMove(state, state.promotionFrom, state.promotionTo, piece)
    if move != nullMove():
        applyMove(state, move)
    else:
        state.setError("Invalid promotion!")


proc tryMakeMove(state: AppState, fromSq, toSq: Square) =
    ## Attempts to make a move, handling promotion if needed
    if isPromotionMove(state, fromSq, toSq):
        if state.autoQueen:
            let move = findMove(state, fromSq, toSq, Queen)
            if move != nullMove():
                applyMove(state, move)
        else:
            startPromotionChoice(state, fromSq, toSq)
    else:
        let move = findMove(state, fromSq, toSq)
        if move != nullMove():
            applyMove(state, move)
        else:
            state.setError("Illegal move!")


proc applyMove*(state: AppState, move: Move) =
    ## Applies a move to the board and updates state
    if move == nullMove():
        return

    # Record SAN before making the move (position must be pre-move)
    let sanStr = state.board.toSAN(move)

    # Record last move for highlighting
    state.lastMove = some((fromSq: move.startSquare(), toSq: move.targetSquare()))

    let result = state.board.makeMove(move)
    if result == nullMove():
        state.setError("Illegal move!")
        return

    state.addMoveRecord(move, sanStr)
    state.undoneHistory = @[]  # new move clears redo stack

    # Audible feedback
    stdout.write("\a")
    stdout.flushFile()

    # Clear selection
    state.selectedSquare = none(Square)
    state.dragSourceSquare = none(Square)
    state.dragCursor = none(tuple[x, y: int])
    state.arrowDrawSourceSquare = none(Square)
    state.arrowDrawTargetSquare = none(Square)
    state.userArrows = @[]
    state.pendingPremoves = @[]
    state.legalDestinations = @[]

    # Trigger engine turn in play mode, or restart analysis
    if state.mode == ModePlay and state.playPhase == PlayerTurn:
        onPlayerMove(state)
    elif state.analysis.running:
        restartAnalysis(state)


proc selectSquare(state: AppState, sq: Square) =
    state.selectedSquare = some(sq)
    state.legalDestinations = getLegalMovesFrom(state, sq)


proc clearSelection(state: AppState) =
    state.resetSquareSelection()


proc userArrowBrush(mouse: MouseEvent): ArrowBrush =
    let modA = mouse.shift or mouse.ctrl
    let modB = mouse.alt
    if modA and modB:
        ArrowYellow
    elif modB:
        ArrowBlue
    elif modA:
        ArrowRed
    else:
        ArrowGreen


proc replaceBoardState(state: AppState, pos: Position) =
    state.board = newChessboardFromFEN(pos.toFEN(state.chess960))
    state.resetMoveSession()
    state.clearUserArrows()
    clearSelection(state)
    state.startFEN = state.board.toFEN()


proc setupSpawnPieceForKey(key: Key): Option[Piece] =
    let keyVal = key.int
    if keyVal < 32 or keyVal > 126:
        return none(Piece)

    let c = chr(keyVal)
    let color = if c.isUpperAscii(): White else: Black
    let kind = case c.toLowerAscii()
        of 'b': Bishop
        of 'k': King
        of 'n': Knight
        of 'p': Pawn
        of 'q': Queen
        of 'r': Rook
        else: return none(Piece)

    result = some(Piece(kind: kind, color: color))


proc validateBoardSetupPosition(state: AppState): tuple[ok: bool, error: string] =
    if state.board.position.pieces(King, White).count() != 1:
        return (false, "board setup requires exactly one white king")
    if state.board.position.pieces(King, Black).count() != 1:
        return (false, "board setup requires exactly one black king")

    for pawn in state.board.position.pieces(Pawn):
        if rank(pawn) in [Rank(0), Rank(7)]:
            return (false, "pawns cannot be placed on the first or eighth rank")

    let whiteKing = state.board.position.kingSquare(White)
    let blackKing = state.board.position.kingSquare(Black)
    if not (kingMoves(whiteKing) and blackKing.toBitboard()).isEmpty():
        return (false, "kings cannot be adjacent")

    let nonSideToMove = state.board.position.sideToMove.opposite()
    if not state.board.position.attackers(state.board.position.kingSquare(nonSideToMove), state.board.position.sideToMove).isEmpty():
        return (false, &"{nonSideToMove} king is in check while it is {state.board.position.sideToMove}'s turn")

    return (true, "")


proc finalizeBoardSetupPosition(state: AppState) =
    var pos = state.board.position.clone()
    pos.recoverCastlingAvailability()
    pos.enPassantSquare = nullSquare()
    pos.halfMoveClock = 0
    pos.fullMoveCount = max(1'u16, pos.fullMoveCount)
    pos.updateChecksAndPins()
    pos.hash()
    replaceBoardState(state, pos)


proc toggleBoardSetupCastling(state: AppState, color: PieceColor, kingSide: bool) =
    var pos = state.board.position.clone()
    let
        sideName = if kingSide: "king-side" else: "queen-side"
        colorName = if color == White: "white" else: "black"

    let currentRook = if kingSide: pos.castlingAvailability[color].king else: pos.castlingAvailability[color].queen
    if currentRook != nullSquare():
        if kingSide:
            pos.castlingAvailability[color].king = nullSquare()
        else:
            pos.castlingAvailability[color].queen = nullSquare()
        pos.updateChecksAndPins()
        pos.hash()
        replaceBoardState(state, pos)
        state.setStatus(&"{colorName} {sideName} castling disabled")
        return

    let rook = pos.castleableRook(color, kingSide)
    if rook == nullSquare():
        state.setError(&"Cannot enable {colorName} {sideName} castling: no castleable rook exists on that side")
        return

    if kingSide:
        pos.castlingAvailability[color].king = rook
    else:
        pos.castlingAvailability[color].queen = rook
    pos.updateChecksAndPins()
    pos.hash()
    replaceBoardState(state, pos)
    state.setStatus(&"{colorName} {sideName} castling enabled via rook on {rook.toUCI()}")


proc enterBoardSetupMode(state: AppState) =
    if state.mode != ModeAnalysis:
        return
    state.boardSetupResumeAnalysis = state.analysis.running
    if state.analysis.running:
        stopAnalysis(state)
    state.boardSetupMode = true
    state.boardSetupSpawnPiece = none(Piece)
    replaceBoardState(state, state.board.position.clone())
    state.setStatus("Board setup mode: drag pieces, drop off-board to delete, type p/n/b/r/q/k (Shift=White), w/x toggle white castling, y/z toggle black castling, Esc to validate and exit")


proc tryExitBoardSetupMode(state: AppState) =
    let validation = validateBoardSetupPosition(state)
    if not validation.ok:
        state.setError("Cannot exit board setup: " & validation.error)
        return

    finalizeBoardSetupPosition(state)
    state.boardSetupMode = false
    state.boardSetupSpawnPiece = none(Piece)
    let resumeAnalysis = state.boardSetupResumeAnalysis
    state.boardSetupResumeAnalysis = false
    state.setStatus("Board setup applied")
    if resumeAnalysis:
        restartAnalysis(state)


proc isLegalDestination(state: AppState, sq: Square): bool =
    for dest in state.legalDestinations:
        if dest == sq:
            return true


proc handleBoardClick(state: AppState, clickedSq: Square) =
    if state.selectedSquare.isSome():
        let fromSq = state.selectedSquare.get()

        if clickedSq == fromSq:
            clearSelection(state)
            return

        if isLegalDestination(state, clickedSq):
            clearSelection(state)
            tryMakeMove(state, fromSq, clickedSq)
        else:
            let piece = state.board.on(clickedSq)
            if piece.kind != Empty and piece.color == state.board.sideToMove():
                selectSquare(state, clickedSq)
            else:
                clearSelection(state)
    else:
        let piece = state.board.on(clickedSq)
        if piece.kind != Empty and piece.color == state.board.sideToMove():
            selectSquare(state, clickedSq)


proc handlePremoveMouseEvent(state: AppState, mouse: MouseEvent, boardTermRow, boardTermCol: int) =
    let sq = termPixelToSquare(state, mouse.x, mouse.y, boardTermRow, boardTermCol)

    case mouse.action
    of maPress:
        if sq.isNone():
            clearSelection(state)
            return

        let clickedSq = sq.get()
        let piece = state.board.on(clickedSq)
        if piece.kind != Empty and piece.color == state.playerColor:
            state.dragSourceSquare = some(clickedSq)
            state.dragCursor = some(termPixelToBoardPixel(state, mouse.x, mouse.y, boardTermRow, boardTermCol))
            state.selectedSquare = some(clickedSq)
            state.legalDestinations = @[]
        else:
            clearSelection(state)

    of maRelease:
        if state.dragSourceSquare.isSome():
            let fromSq = state.dragSourceSquare.get()
            state.dragSourceSquare = none(Square)
            state.dragCursor = none(tuple[x, y: int])

            if sq.isSome():
                let targetSq = sq.get()
                if targetSq != fromSq:
                    clearSelection(state)
                    state.queuePremove(fromSq, targetSq)
                elif state.removeLatestPremoveAtSquare(fromSq):
                    clearSelection(state)
                else:
                    state.selectedSquare = some(fromSq)
            else:
                clearSelection(state)
        elif sq.isNone():
            clearSelection(state)
        else:
            discard state.removeLatestPremoveAtSquare(sq.get())

    of maMove:
        if state.dragSourceSquare.isSome():
            state.dragCursor = some(termPixelToBoardPixel(state, mouse.x, mouse.y, boardTermRow, boardTermCol))


proc handleBoardSetupMouseEvent(state: AppState, mouse: MouseEvent, boardTermRow, boardTermCol: int) =
    let sq = termPixelToSquare(state, mouse.x, mouse.y, boardTermRow, boardTermCol)

    case mouse.action
    of maPress:
        if state.boardSetupSpawnPiece.isSome():
            if sq.isSome():
                var pos = state.board.position.clone()
                let targetSq = sq.get()
                if pos.on(targetSq).kind != Empty:
                    pos.remove(targetSq)
                pos.spawn(targetSq, state.boardSetupSpawnPiece.get())
                pos.updateChecksAndPins()
                pos.hash()
                replaceBoardState(state, pos)
                let piece = state.boardSetupSpawnPiece.get()
                state.boardSetupSpawnPiece = none(Piece)
                state.setStatus(&"Placed {piece.toChar()} on {targetSq.toUCI()}")
            return

        if sq.isNone():
            clearSelection(state)
            return

        let clickedSq = sq.get()
        let piece = state.board.on(clickedSq)
        if piece.kind != Empty:
            state.dragSourceSquare = some(clickedSq)
            state.dragCursor = some(termPixelToBoardPixel(state, mouse.x, mouse.y, boardTermRow, boardTermCol))
            state.selectedSquare = some(clickedSq)
            state.legalDestinations = @[]
        else:
            clearSelection(state)

    of maRelease:
        if state.dragSourceSquare.isSome():
            let fromSq = state.dragSourceSquare.get()
            state.dragSourceSquare = none(Square)
            state.dragCursor = none(tuple[x, y: int])

            var pos = state.board.position.clone()
            let piece = pos.on(fromSq)
            if piece.kind == Empty:
                clearSelection(state)
                return

            if sq.isNone():
                pos.remove(fromSq)
                pos.updateChecksAndPins()
                pos.hash()
                replaceBoardState(state, pos)
                state.setStatus(&"Removed {piece.toChar()} from {fromSq.toUCI()}")
                return

            let targetSq = sq.get()
            if targetSq != fromSq:
                if pos.on(targetSq).kind != Empty:
                    pos.remove(targetSq)
                pos.remove(fromSq)
                pos.spawn(targetSq, piece)
                pos.updateChecksAndPins()
                pos.hash()
                replaceBoardState(state, pos)
                state.setStatus(&"Moved {piece.toChar()} to {targetSq.toUCI()}")
            else:
                clearSelection(state)
        elif sq.isNone():
            clearSelection(state)

    of maMove:
        if state.dragSourceSquare.isSome():
            state.dragCursor = some(termPixelToBoardPixel(state, mouse.x, mouse.y, boardTermRow, boardTermCol))


proc handleUserArrowMouseEvent(state: AppState, mouse: MouseEvent, boardTermRow, boardTermCol: int) =
    if state.boardSetupMode:
        return
    if state.mode == ModePlay and state.playPhase == Setup:
        return

    let sq = termPixelToSquare(state, mouse.x, mouse.y, boardTermRow, boardTermCol)

    case mouse.action
    of maPress:
        state.dragSourceSquare = none(Square)
        state.dragCursor = none(tuple[x, y: int])
        clearSelection(state)
        state.arrowDrawTargetSquare = none(Square)
        state.arrowDrawBrush = userArrowBrush(mouse)
        if sq.isSome():
            state.arrowDrawSourceSquare = some(sq.get())
        else:
            state.arrowDrawSourceSquare = none(Square)

    of maRelease:
        if state.arrowDrawSourceSquare.isSome():
            let fromSq = state.arrowDrawSourceSquare.get()
            let targetSq =
                if state.arrowDrawTargetSquare.isSome():
                    state.arrowDrawTargetSquare
                elif sq.isSome() and sq.get() != fromSq:
                    some(sq.get())
                else:
                    none(Square)
            if targetSq.isSome():
                state.toggleUserArrow(fromSq, targetSq.get(), state.arrowDrawBrush)
        state.arrowDrawSourceSquare = none(Square)
        state.arrowDrawTargetSquare = none(Square)
        state.arrowDrawBrush = ArrowGreen

    of maMove:
        if state.arrowDrawSourceSquare.isSome():
            let fromSq = state.arrowDrawSourceSquare.get()
            if sq.isSome() and sq.get() != fromSq:
                state.arrowDrawTargetSquare = some(sq.get())
            else:
                state.arrowDrawTargetSquare = none(Square)


proc handleMouseEvent*(state: AppState, mouse: MouseEvent, boardTermRow, boardTermCol: int) =
    ## Handles mouse clicks and simple drag-and-drop move input
    if mouse.button == rawinput.mbRight:
        handleUserArrowMouseEvent(state, mouse, boardTermRow, boardTermCol)
        return
    if mouse.button != rawinput.mbLeft:
        return

    if state.boardSetupMode:
        handleBoardSetupMouseEvent(state, mouse, boardTermRow, boardTermCol)
        return

    if state.mode == ModeReplay:
        return
    if state.mode == ModePlay and state.playPhase == EngineTurn and not state.watchMode:
        handlePremoveMouseEvent(state, mouse, boardTermRow, boardTermCol)
        return
    if state.mode == ModePlay and state.playPhase in [EngineTurn, GameOver, Setup]:
        return

    let sq = termPixelToSquare(state, mouse.x, mouse.y, boardTermRow, boardTermCol)

    case mouse.action
    of maPress:
        if sq.isNone():
            state.dragSourceSquare = none(Square)
            state.dragCursor = none(tuple[x, y: int])
            clearSelection(state)
            return

        let clickedSq = sq.get()
        let piece = state.board.on(clickedSq)

        if piece.kind != Empty and piece.color == state.board.sideToMove():
            state.dragSourceSquare = some(clickedSq)
            state.dragCursor = some(termPixelToBoardPixel(state, mouse.x, mouse.y, boardTermRow, boardTermCol))
            selectSquare(state, clickedSq)
        else:
            state.dragSourceSquare = none(Square)
            state.dragCursor = none(tuple[x, y: int])

    of maRelease:
        if state.dragSourceSquare.isSome():
            let fromSq = state.dragSourceSquare.get()
            state.dragSourceSquare = none(Square)
            state.dragCursor = none(tuple[x, y: int])

            if sq.isNone():
                selectSquare(state, fromSq)
                return

            let targetSq = sq.get()
            if targetSq == fromSq:
                selectSquare(state, fromSq)
                return

            if isLegalDestination(state, targetSq):
                clearSelection(state)
                tryMakeMove(state, fromSq, targetSq)
            else:
                let piece = state.board.on(targetSq)
                if piece.kind != Empty and piece.color == state.board.sideToMove():
                    selectSquare(state, targetSq)
                else:
                    selectSquare(state, fromSq)
        elif sq.isNone():
            clearSelection(state)
        else:
            handleBoardClick(state, sq.get())

    of maMove:
        if state.dragSourceSquare.isSome():
            state.dragCursor = some(termPixelToBoardPixel(state, mouse.x, mouse.y, boardTermRow, boardTermCol))


proc handleTextInput(state: AppState, key: Key) =
    ## Handles text character input to the input buffer
    let c = chr(key.int)
    state.input.buffer.insert($c, state.input.cursorPos)
    inc state.input.cursorPos


proc handleBackspace(state: AppState) =
    if state.input.cursorPos > 0:
        let idx = state.input.cursorPos - 1
        state.input.buffer = state.input.buffer[0..<idx] & state.input.buffer[idx+1..^1]
        dec state.input.cursorPos


proc toggleAutoQueen(state: AppState) =
    state.autoQueen = not state.autoQueen
    state.setStatus("Auto-queen: " & (if state.autoQueen: "ON" else: "OFF"))


proc toggleEngineArrows(state: AppState) =
    state.showEngineArrows = not state.showEngineArrows
    state.setStatus("Engine arrows: " & (if state.showEngineArrows: "ON" else: "OFF"))


proc handleInput*(state: AppState, key: Key) =
    ## Main input dispatcher

    # Ctrl+C always quits immediately, never intercepted
    if key == Key.CtrlC:
        state.shouldQuit = true
        return

    # Handle pending promotion piece selection
    if state.promotionPending:
        case key:
            of Key.Q, Key.ShiftQ:
                completePromotion(state, Queen)
            of Key.R, Key.ShiftR:
                completePromotion(state, Rook)
            of Key.B, Key.ShiftB:
                completePromotion(state, Bishop)
            of Key.N, Key.ShiftN:
                completePromotion(state, Knight)
            of Key.Escape:
                state.promotionPending = false
                state.setStatus("")
            else:
                state.setStatus("Promote to: [Q]ueen / [R]ook / [B]ishop / [N]knight")
        return

    # Handle single-key setup prompts (no Enter needed)
    if state.mode == ModePlay and state.playPhase == Setup and state.input.buffer.len == 0:
        let shortcutInput = state.setupShortcutInput(key)
        if shortcutInput.isSome():
            state.dismissStatus()
            handlePlaySetup(state, shortcutInput.get())
            return

    # Dismiss persistent status on any keypress (but not during setup - those prompts need input)
    if state.input.statusPersistent and key != Key.None:
        if not (state.mode == ModePlay and state.playPhase == Setup) and
           not state.boardSetupMode and
           state.analysis.prompt.isNone():
            state.dismissStatus()
            return

    # Help overlay owns input while visible.
    if state.input.helpVisible and key != Key.None:
        let maxScroll = maxHelpScroll()
        case key
        of Key.Escape:
            state.input.helpVisible = false
            state.input.helpScroll = 0
        of Key.Up:
            state.input.helpScroll = max(0, state.input.helpScroll - 1)
        of Key.Down:
            state.input.helpScroll = min(maxScroll, state.input.helpScroll + 1)
        of Key.PageUp:
            state.input.helpScroll = max(0, state.input.helpScroll - helpViewportHeight(terminalHeight() - 4))
        of Key.PageDown:
            state.input.helpScroll = min(maxScroll, state.input.helpScroll + helpViewportHeight(terminalHeight() - 4))
        of Key.Home:
            state.input.helpScroll = 0
        of Key.End:
            state.input.helpScroll = maxScroll
        else:
            discard
        return

    # Any key other than Ctrl+D cancels the pending exit
    if state.ctrlDPending and key != Key.CtrlD:
        state.ctrlDPending = false
        state.setStatus("")

    if state.analysis.prompt.isSome():
        case key
        of Key.Escape:
            state.clearAnalysisPrompt()
            state.dismissStatus()
        of Key.Enter:
            if state.input.buffer.len > 0:
                let cmd = state.input.buffer
                state.input.buffer = ""
                state.input.cursorPos = 0
                state.input.acActive = false
                state.input.acSelected = none(int)
                processInput(state, cmd)
        of Key.Backspace:
            handleBackspace(state)
            updateAutocomplete(state)
        of Key.Left:
            if state.input.cursorPos > 0:
                dec state.input.cursorPos
        of Key.Right:
            if state.input.cursorPos < state.input.buffer.len:
                inc state.input.cursorPos
        else:
            let keyVal = key.int
            if keyVal >= 32 and keyVal <= 126:
                handleTextInput(state, key)
                updateAutocomplete(state)
        return

    case key
    of Key.CtrlC:
        discard  # handled above, never reached

    of Key.CtrlD:
        if state.ctrlDPending:
            state.shouldQuit = true
        else:
            state.ctrlDPending = true
            state.setStatus("Press Ctrl+D again to exit")

    of Key.Escape:
        # ESC cancels the current action, never exits the GUI directly.
        # Use Ctrl+C / Ctrl+D or :quit to exit.
        if state.boardSetupMode:
            tryExitBoardSetupMode(state)
        elif state.analysis.prompt.isSome():
            state.clearAnalysisPrompt()
            state.dismissStatus()
        elif state.input.statusPersistent:
            state.dismissStatus()
        elif state.input.acActive:
            state.input.acActive = false
            state.input.acSelected = none(int)
        elif state.pendingPremoves.len > 0:
            state.clearPremoves("Premoves cleared")
        elif state.selectedSquare.isSome():
            state.selectedSquare = none(Square)
            state.legalDestinations = @[]
        elif state.input.buffer.len > 0:
            state.input.buffer = ""
            state.input.cursorPos = 0
        elif state.analysis.running:
            stopAnalysis(state)
            state.setStatus("Analysis stopped")
        elif state.mode == ModePlay and state.playPhase == Setup:
            exitPlayMode(state)
        elif state.mode == ModeReplay:
            state.enterAnalysisMode()
            state.setStatus("Exited replay mode")

    of Key.Tab:
        # Accept autocomplete selection into input buffer
        if state.input.acActive and state.input.acSelected.isSome() and state.input.acSelected.get() < state.input.acSuggestions.len:
            state.input.buffer = ":" & state.input.acSuggestions[state.input.acSelected.get()].cmd
            state.input.cursorPos = state.input.buffer.len
            state.input.acActive = false
            state.input.acSelected = none(int)

    of Key.Up:
        if state.input.acActive and state.input.acSuggestions.len > 0:
            let selected = if state.input.acSelected.isSome(): state.input.acSelected.get() else: 0
            if selected > 0:
                state.input.acSelected = some(selected - 1)
            else:
                state.input.acSelected = some(state.input.acSuggestions.len - 1)
            return
        # else fall through to default

    of Key.Down:
        if state.input.acActive and state.input.acSuggestions.len > 0:
            let selected = if state.input.acSelected.isSome(): state.input.acSelected.get() else: -1
            if selected < state.input.acSuggestions.len - 1:
                state.input.acSelected = some(selected + 1)
            else:
                state.input.acSelected = some(0)
            return
        # else fall through to default

    of Key.Enter:
        if state.input.acActive and state.input.acSelected.isSome() and state.input.acSelected.get() < state.input.acSuggestions.len:
            # Execute the selected autocomplete command directly
            let cmd = ":" & state.input.acSuggestions[state.input.acSelected.get()].cmd
            state.input.buffer = ""
            state.input.cursorPos = 0
            state.input.acActive = false
            state.input.acSelected = none(int)
            processInput(state, cmd)
        elif state.input.buffer.len > 0:
            let cmd = state.input.buffer
            state.input.buffer = ""
            state.input.cursorPos = 0
            state.input.acActive = false
            state.input.acSelected = none(int)
            processInput(state, cmd)
        elif state.mode == ModePlay and state.playPhase == Setup:
            # Empty Enter during setup = accept default
            state.dismissStatus()
            handlePlaySetup(state, "")

    of Key.Backspace:
        handleBackspace(state)
        updateAutocomplete(state)

    of Key.Left:
        if state.input.buffer.len == 0:
            # Undo last move (works in analysis, play, and PGN replay)
            if state.undoLastRecordedMove():
                state.refreshAfterNavigation()
        elif state.input.cursorPos > 0:
            dec state.input.cursorPos

    of Key.Right:
        if state.input.buffer.len == 0:
            if state.replayStepForward() or state.redoUndoneMove():
                state.refreshAfterNavigation()
        elif state.input.cursorPos < state.input.buffer.len:
            inc state.input.cursorPos

    of Key.Home:
        if state.input.buffer.len == 0 and state.moveHistory.len > 0:
            # Go to start - undo all moves
            if state.replayToStart():
                state.refreshAfterNavigation()

    of Key.End:
        if state.input.buffer.len == 0:
            # Go to end - redo all undone moves (or PGN moves)
            if state.replayToEnd():
                state.refreshAfterNavigation()

    else:
        let setupSpawnPiece = if state.boardSetupMode: setupSpawnPieceForKey(key) else: none(Piece)
        if setupSpawnPiece.isSome():
            state.boardSetupSpawnPiece = setupSpawnPiece
            let piece = setupSpawnPiece.get()
            clearSelection(state)
            state.setStatus(&"Spawn armed: {piece.toChar()} (click a square to place it)")
            return
        elif state.boardSetupMode:
            case key
            of Key.W, Key.ShiftW:
                toggleBoardSetupCastling(state, White, kingSide = false)
            of Key.X, Key.ShiftX:
                toggleBoardSetupCastling(state, White, kingSide = true)
            of Key.Y, Key.ShiftY:
                toggleBoardSetupCastling(state, Black, kingSide = false)
            of Key.Z, Key.ShiftZ:
                toggleBoardSetupCastling(state, Black, kingSide = true)
            else:
                discard
            return

        # Global shortcuts always require Shift.
        if state.mode == ModeAnalysis and not state.boardSetupMode and key == Key.ShiftS:
            enterBoardSetupMode(state)
            return
        if key == Key.ShiftF:
            state.flipped = not state.flipped
            return
        if state.mode == ModeAnalysis and not state.boardSetupMode and state.input.buffer.len == 0 and key == Key.ShiftM:
            state.beginMateFinderPrompt()
            return
        if key == Key.ShiftA:
            toggleEngineArrows(state)
            return
        if key == Key.ShiftQ:
            toggleAutoQueen(state)
            return

        # Printable ASCII characters
        let keyVal = key.int
        if keyVal >= 32 and keyVal <= 126:
            handleTextInput(state, key)
            updateAutocomplete(state)
