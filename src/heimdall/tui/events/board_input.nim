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

## Board interaction, promotion, premove, and arrow input handling.

import std/options

import heimdall/[board, movegen, moves, pieces]
import heimdall/tui/[state, analysis, play, rawinput]
import heimdall/tui/graphics/board_view
import heimdall/tui/events/board_setup
import heimdall/tui/util/[san, premove]


proc applyMove*(state: AppState, move: Move)


proc getLegalMovesFrom(state: AppState, sq: Square): seq[Square] =
    var moves = newMoveList()
    state.board.generateMoves(moves)
    for move in moves:
        if move.startSquare() == sq:
            result.add(move.targetSquare())


proc isPromotionMove(state: AppState, fromSq, toSq: Square): bool =
    var moves = newMoveList()
    state.board.generateMoves(moves)
    for move in moves:
        if move.startSquare() == fromSq and move.targetSquare() == toSq and move.isPromotion():
            return true


proc findMove(state: AppState, fromSq, toSq: Square, promotionPiece: PieceKind = Queen): Move =
    var moves = newMoveList()
    state.board.generateMoves(moves)
    for move in moves:
        if move.startSquare() == fromSq and move.targetSquare() == toSq:
            if move.isPromotion():
                if move.flag().promotionToPiece() == promotionPiece:
                    return move
            else:
                return move
    nullMove()


proc startPromotionChoice(state: AppState, fromSq, toSq: Square) =
    state.promotionPending = true
    state.promotionFrom = fromSq
    state.promotionTo = toSq
    state.setStatus("Promote to: [Q]ueen / [R]ook / [B]ishop / [N]knight")


proc tryMakeMove(state: AppState, fromSq, toSq: Square) =
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
    if move == nullMove():
        return

    let sanStr = state.board.toSAN(move)
    state.lastMove = some((fromSq: move.startSquare(), toSq: move.targetSquare()))

    let result = state.board.makeMove(move)
    if result == nullMove():
        state.setError("Illegal move!")
        return

    state.addMoveRecord(move, sanStr)
    state.undoneHistory = @[]

    stdout.write("\a")
    stdout.flushFile()

    state.selectedSquare = none(Square)
    state.dragSourceSquare = none(Square)
    state.dragCursor = none(tuple[x, y: int])
    state.arrowDrawSourceSquare = none(Square)
    state.arrowDrawTargetSquare = none(Square)
    state.resetArrowState()
    state.pendingPremoves = @[]
    state.legalDestinations = @[]

    if state.mode == ModePlay and state.play.phase == PlayerTurn:
        onPlayerMove(state)
    elif state.analysis.running:
        restartAnalysis(state)


proc completePromotion*(state: AppState, piece: PieceKind) =
    state.promotionPending = false
    let move = findMove(state, state.promotionFrom, state.promotionTo, piece)
    if move != nullMove():
        applyMove(state, move)
    else:
        state.setError("Invalid promotion!")


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
    let previewBoard = premoveViewBoard(state.board, state.play.playerColor, state.pendingPremoves, state.chess960)

    case mouse.action:
        of maPress:
            if sq.isNone():
                clearSelection(state)
                return

            let clickedSq = sq.get()
            let piece = previewBoard.on(clickedSq)
            if piece.kind != Empty and piece.color == state.play.playerColor:
                state.dragSourceSquare = some(clickedSq)
                state.dragCursor = some(termPixelToBoardPixel(state, mouse.x, mouse.y, boardTermRow, boardTermCol))
                state.selectedSquare = some(clickedSq)
                state.legalDestinations = premoveDestinations(state.board, state.play.playerColor, state.pendingPremoves, clickedSq, state.chess960)
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
                        if canQueuePremove(state.board, state.play.playerColor, state.pendingPremoves, fromSq, targetSq, state.chess960):
                            clearSelection(state)
                            state.queuePremove(fromSq, targetSq)
                        else:
                            state.setError("Premove must be pseudo-legal")
                            state.selectedSquare = some(fromSq)
                            state.legalDestinations = premoveDestinations(state.board, state.play.playerColor, state.pendingPremoves, fromSq, state.chess960)
                    elif state.removeLatestPremoveAtSquare(fromSq):
                        clearSelection(state)
                    else:
                        state.selectedSquare = some(fromSq)
                        state.legalDestinations = premoveDestinations(state.board, state.play.playerColor, state.pendingPremoves, fromSq, state.chess960)
                else:
                    clearSelection(state)
            elif sq.isNone():
                clearSelection(state)
            else:
                discard state.removeLatestPremoveAtSquare(sq.get())

        of maMove:
            if state.dragSourceSquare.isSome():
                state.dragCursor = some(termPixelToBoardPixel(state, mouse.x, mouse.y, boardTermRow, boardTermCol))


proc handleUserArrowMouseEvent(state: AppState, mouse: MouseEvent, boardTermRow, boardTermCol: int) =
    if state.boardSetup.active:
        return
    if state.mode == ModePlay and state.play.phase == Setup:
        return

    let sq = termPixelToSquare(state, mouse.x, mouse.y, boardTermRow, boardTermCol)

    case mouse.action:
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
                elif sq.isSome() and sq.get() == fromSq:
                    state.toggleHighlightedSquare(fromSq)
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
    if mouse.button == rawinput.mbRight:
        handleUserArrowMouseEvent(state, mouse, boardTermRow, boardTermCol)
        return
    if mouse.button != rawinput.mbLeft:
        return

    if state.boardSetup.active:
        handleBoardSetupMouseEvent(state, mouse, boardTermRow, boardTermCol)
        return

    if state.mode == ModeReplay:
        return
    if state.mode == ModePlay and state.play.phase == EngineTurn and not state.play.watchMode:
        handlePremoveMouseEvent(state, mouse, boardTermRow, boardTermCol)
        return
    if state.mode == ModePlay and state.play.phase in [EngineTurn, GameOver, Setup]:
        return

    let sq = termPixelToSquare(state, mouse.x, mouse.y, boardTermRow, boardTermCol)

    case mouse.action:
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
