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


proc maxHelpScroll(): int =
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
    state.pendingPremoves = @[]
    state.legalDestinations = @[]

    # Trigger engine turn in play mode, or restart analysis
    if state.mode == ModePlay and state.playPhase == PlayerTurn:
        onPlayerMove(state)
    elif state.analysisRunning:
        restartAnalysis(state)


proc selectSquare(state: AppState, sq: Square) =
    state.selectedSquare = some(sq)
    state.legalDestinations = getLegalMovesFrom(state, sq)


proc clearSelection(state: AppState) =
    state.selectedSquare = none(Square)
    state.dragSourceSquare = none(Square)
    state.dragCursor = none(tuple[x, y: int])
    state.legalDestinations = @[]


proc replaceBoardState(state: AppState, pos: Position) =
    state.board = newChessboardFromFEN(pos.toFEN(state.chess960))
    state.clearMoveRecords()
    state.lastMove = none(tuple[fromSq, toSq: Square])
    state.pendingPremoves = @[]
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
    state.boardSetupResumeAnalysis = state.analysisRunning
    if state.analysisRunning:
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


proc handleMouseEvent*(state: AppState, mouse: MouseEvent, boardTermRow, boardTermCol: int) =
    ## Handles mouse clicks and simple drag-and-drop move input
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
    state.inputBuffer.insert($c, state.inputCursorPos)
    inc state.inputCursorPos


proc handleBackspace(state: AppState) =
    if state.inputCursorPos > 0:
        let idx = state.inputCursorPos - 1
        state.inputBuffer = state.inputBuffer[0..<idx] & state.inputBuffer[idx+1..^1]
        dec state.inputCursorPos


proc toggleAutoQueen(state: AppState) =
    state.autoQueen = not state.autoQueen
    state.setStatus("Auto-queen: " & (if state.autoQueen: "ON" else: "OFF"))


proc handleInput*(state: AppState, key: Key) =
    ## Main input dispatcher

    # Ctrl+C always quits immediately, never intercepted
    if key == Key.CtrlC:
        state.shouldQuit = true
        return

    # Handle pending promotion piece selection
    if state.promotionPending:
        case key
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
    if state.mode == ModePlay and state.playPhase == Setup and state.inputBuffer.len == 0:
        case state.setupStep
        of ChooseVariant:
            case key
            of Key.S, Key.ShiftS, Key.Enter:
                state.dismissStatus()
                handlePlaySetup(state, "s")
                return
            of Key.F, Key.ShiftF:
                state.dismissStatus()
                handlePlaySetup(state, "f")
                return
            of Key.D, Key.ShiftD:
                state.dismissStatus()
                handlePlaySetup(state, "d")
                return
            of Key.C, Key.ShiftC:
                state.dismissStatus()
                handlePlaySetup(state, "c")
                return
            else: discard
        of ChooseSide:
            case key
            of Key.W, Key.ShiftW:
                state.dismissStatus()
                handlePlaySetup(state, "w")
                return
            of Key.B, Key.ShiftB:
                state.dismissStatus()
                handlePlaySetup(state, "b")
                return
            of Key.R, Key.ShiftR, Key.Enter:
                state.dismissStatus()
                handlePlaySetup(state, "r")
                return
            else: discard
        of ChooseTakeback:
            case key
            of Key.Y, Key.ShiftY:
                state.dismissStatus()
                handlePlaySetup(state, "y")
                return
            of Key.N, Key.ShiftN, Key.Enter:
                state.dismissStatus()
                handlePlaySetup(state, "n")
                return
            else: discard
        of ChoosePonder:
            case key
            of Key.Y, Key.ShiftY:
                state.dismissStatus()
                handlePlaySetup(state, "y")
                return
            of Key.N, Key.ShiftN, Key.Enter:
                state.dismissStatus()
                handlePlaySetup(state, "n")
                return
            else: discard
        of ChooseWatchSeparate:
            case key
            of Key.Y, Key.ShiftY:
                state.dismissStatus()
                handlePlaySetup(state, "y")
                return
            of Key.N, Key.ShiftN, Key.Enter:
                state.dismissStatus()
                handlePlaySetup(state, "n")
                return
            else: discard
        of ChooseWatchPonder, ChooseWatchWhitePonder, ChooseWatchBlackPonder:
            case key
            of Key.Y, Key.ShiftY:
                state.dismissStatus()
                handlePlaySetup(state, "y")
                return
            of Key.N, Key.ShiftN, Key.Enter:
                state.dismissStatus()
                handlePlaySetup(state, "n")
                return
            else: discard
        of ChooseSoftNodesHardBound:
            case key
            of Key.Y, Key.ShiftY:
                state.dismissStatus()
                handlePlaySetup(state, "y")
                return
            of Key.N, Key.ShiftN, Key.Enter:
                state.dismissStatus()
                handlePlaySetup(state, "n")
                return
            else: discard
        else:
            discard  # Multi-char inputs (TC, hash, threads) need Enter

    # Dismiss persistent status on any keypress (but not during setup - those prompts need input)
    if state.statusPersistent and key != Key.None:
        if not (state.mode == ModePlay and state.playPhase == Setup) and not state.boardSetupMode:
            state.dismissStatus()
            return

    # Help overlay owns input while visible.
    if state.helpVisible and key != Key.None:
        let maxScroll = maxHelpScroll()
        case key
        of Key.Escape:
            state.helpVisible = false
            state.helpScroll = 0
        of Key.Up:
            state.helpScroll = max(0, state.helpScroll - 1)
        of Key.Down:
            state.helpScroll = min(maxScroll, state.helpScroll + 1)
        of Key.PageUp:
            state.helpScroll = max(0, state.helpScroll - helpViewportHeight(terminalHeight() - 4))
        of Key.PageDown:
            state.helpScroll = min(maxScroll, state.helpScroll + helpViewportHeight(terminalHeight() - 4))
        of Key.Home:
            state.helpScroll = 0
        of Key.End:
            state.helpScroll = maxScroll
        else:
            discard
        return

    # Any key other than Ctrl+D cancels the pending exit
    if state.ctrlDPending and key != Key.CtrlD:
        state.ctrlDPending = false
        state.setStatus("")

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
        elif state.statusPersistent:
            state.dismissStatus()
        elif state.acActive:
            state.acActive = false
        elif state.pendingPremoves.len > 0:
            state.clearPremoves("Premoves cleared")
        elif state.selectedSquare.isSome():
            state.selectedSquare = none(Square)
            state.legalDestinations = @[]
        elif state.inputBuffer.len > 0:
            state.inputBuffer = ""
            state.inputCursorPos = 0
        elif state.analysisRunning:
            stopAnalysis(state)
            state.setStatus("Analysis stopped")
        elif state.mode == ModePlay and state.playPhase == Setup:
            exitPlayMode(state)
        elif state.mode == ModeReplay:
            state.mode = ModeAnalysis
            state.setStatus("Exited replay mode")

    of Key.Tab:
        # Accept autocomplete selection into input buffer
        if state.acActive and state.acSelected >= 0 and state.acSelected < state.acSuggestions.len:
            state.inputBuffer = ":" & state.acSuggestions[state.acSelected].cmd
            state.inputCursorPos = state.inputBuffer.len
            state.acActive = false

    of Key.Up:
        if state.acActive and state.acSuggestions.len > 0:
            if state.acSelected > 0:
                dec state.acSelected
            else:
                state.acSelected = state.acSuggestions.len - 1
            return
        # else fall through to default

    of Key.Down:
        if state.acActive and state.acSuggestions.len > 0:
            if state.acSelected < state.acSuggestions.len - 1:
                inc state.acSelected
            else:
                state.acSelected = 0
            return
        # else fall through to default

    of Key.Enter:
        if state.acActive and state.acSelected >= 0 and state.acSelected < state.acSuggestions.len:
            # Execute the selected autocomplete command directly
            let cmd = ":" & state.acSuggestions[state.acSelected].cmd
            state.inputBuffer = ""
            state.inputCursorPos = 0
            state.acActive = false
            processInput(state, cmd)
        elif state.inputBuffer.len > 0:
            let cmd = state.inputBuffer
            state.inputBuffer = ""
            state.inputCursorPos = 0
            state.acActive = false
            processInput(state, cmd)
        elif state.mode == ModePlay and state.playPhase == Setup:
            # Empty Enter during setup = accept default
            state.dismissStatus()
            handlePlaySetup(state, "")

    of Key.Backspace:
        handleBackspace(state)
        updateAutocomplete(state)

    of Key.Left:
        if state.inputBuffer.len == 0:
            # Undo last move (works in analysis, play, and PGN replay)
            if state.moveHistory.len > 0:
                let lastRecord = state.popMoveRecord()
                state.board.unmakeMove()
                # Save for redo
                state.undoneHistory.add(lastRecord)
                if state.mode == ModeReplay:
                    dec state.pgnMoveIndex
                if state.moveHistory.len > 0:
                    let m = state.moveHistory[^1]
                    state.lastMove = some((fromSq: m.startSquare(), toSq: m.targetSquare()))
                else:
                    state.lastMove = none(tuple[fromSq, toSq: Square])
                state.selectedSquare = none(Square)
                state.legalDestinations = @[]
                if state.analysisRunning:
                    restartAnalysis(state)
        elif state.inputCursorPos > 0:
            dec state.inputCursorPos

    of Key.Right:
        if state.inputBuffer.len == 0:
            if state.mode == ModeReplay and state.pgnMoveIndex < state.pgnMoves.len:
                # Navigate forward in PGN (use the PGN's moves)
                let move = state.pgnMoves[state.pgnMoveIndex]
                let sanStr = state.board.toSAN(move)
                state.lastMove = some((fromSq: move.startSquare(), toSq: move.targetSquare()))
                discard state.board.makeMove(move)
                state.addMoveRecord(move, sanStr)
                inc state.pgnMoveIndex
                state.undoneHistory = @[]  # clear redo stack on forward PGN nav
                if state.analysisRunning:
                    restartAnalysis(state)
            elif state.undoneHistory.len > 0:
                # Redo an undone move
                let (move, san, comment) = state.undoneHistory.pop()
                state.lastMove = some((fromSq: move.startSquare(), toSq: move.targetSquare()))
                discard state.board.makeMove(move)
                state.addMoveRecord(move, san, comment)
                state.selectedSquare = none(Square)
                state.legalDestinations = @[]
                if state.analysisRunning:
                    restartAnalysis(state)
        elif state.inputCursorPos < state.inputBuffer.len:
            inc state.inputCursorPos

    of Key.Home:
        if state.inputBuffer.len == 0 and state.moveHistory.len > 0:
            # Go to start - undo all moves
            while state.moveHistory.len > 0:
                let record = state.popMoveRecord()
                state.board.unmakeMove()
                state.undoneHistory.add(record)
                if state.mode == ModeReplay:
                    dec state.pgnMoveIndex
            state.lastMove = none(tuple[fromSq, toSq: Square])
            state.selectedSquare = none(Square)
            state.legalDestinations = @[]
            if state.analysisRunning:
                restartAnalysis(state)

    of Key.End:
        if state.inputBuffer.len == 0:
            # Go to end - redo all undone moves (or PGN moves)
            if state.mode == ModeReplay:
                while state.pgnMoveIndex < state.pgnMoves.len:
                    let move = state.pgnMoves[state.pgnMoveIndex]
                    let sanStr = state.board.toSAN(move)
                    state.lastMove = some((fromSq: move.startSquare(), toSq: move.targetSquare()))
                    discard state.board.makeMove(move)
                    state.addMoveRecord(move, sanStr)
                    inc state.pgnMoveIndex
                state.undoneHistory = @[]
            else:
                while state.undoneHistory.len > 0:
                    let (move, san, comment) = state.undoneHistory.pop()
                    state.lastMove = some((fromSq: move.startSquare(), toSq: move.targetSquare()))
                    discard state.board.makeMove(move)
                    state.addMoveRecord(move, san, comment)
            state.selectedSquare = none(Square)
            state.legalDestinations = @[]
            if state.analysisRunning:
                restartAnalysis(state)

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
        if key == Key.ShiftQ:
            toggleAutoQueen(state)
            return

        # Printable ASCII characters
        let keyVal = key.int
        if keyVal >= 32 and keyVal <= 126:
            handleTextInput(state, key)
            updateAutocomplete(state)
