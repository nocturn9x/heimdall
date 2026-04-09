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

## Board setup mode state transitions and input handling.

import std/[options, strutils, strformat]

import illwill
import heimdall/[pieces, movegen, board]
import heimdall/tui/[state, analysis, rawinput]
import heimdall/tui/graphics/board_view


proc replaceBoardState(state: AppState, pos: Position) =
    state.board = newChessboardFromFEN(pos.toFEN(state.chess960))
    state.resetMoveSession()
    state.clearUserAnnotations()
    state.resetSquareSelection()
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

    some(Piece(kind: kind, color: color))


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

    (true, "")


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


proc enterBoardSetupMode*(state: AppState) =
    if state.mode != ModeAnalysis:
        return
    state.boardSetup.resumeAnalysis = state.analysis.running
    if state.analysis.running:
        stopAnalysis(state)
    state.boardSetup.active = true
    state.boardSetup.spawnPiece = none(Piece)
    replaceBoardState(state, state.board.position.clone())
    state.setStatus("Board setup mode: drag pieces, drop off-board to delete, type p/n/b/r/q/k (Shift=White), w/x toggle white castling, y/z toggle black castling, Esc to validate and exit")


proc tryExitBoardSetupMode*(state: AppState) =
    let validation = validateBoardSetupPosition(state)
    if not validation.ok:
        state.setError("Cannot exit board setup: " & validation.error)
        return

    finalizeBoardSetupPosition(state)
    state.boardSetup.active = false
    state.boardSetup.spawnPiece = none(Piece)
    let resumeAnalysis = state.boardSetup.resumeAnalysis
    state.boardSetup.resumeAnalysis = false
    state.setStatus("Board setup applied")
    if resumeAnalysis:
        restartAnalysis(state)


proc handleBoardSetupMouseEvent*(state: AppState, mouse: MouseEvent, boardTermRow, boardTermCol: int) =
    let sq = termPixelToSquare(state, mouse.x, mouse.y, boardTermRow, boardTermCol)

    case mouse.action
    of maPress:
        if state.boardSetup.spawnPiece.isSome():
            if sq.isSome():
                var pos = state.board.position.clone()
                let targetSq = sq.get()
                if pos.on(targetSq).kind != Empty:
                    pos.remove(targetSq)
                pos.spawn(targetSq, state.boardSetup.spawnPiece.get())
                pos.updateChecksAndPins()
                pos.hash()
                replaceBoardState(state, pos)
                let piece = state.boardSetup.spawnPiece.get()
                state.boardSetup.spawnPiece = none(Piece)
                state.setStatus(&"Placed {piece.toChar()} on {targetSq.toUCI()}")
            return

        if sq.isNone():
            state.resetSquareSelection()
            return

        let clickedSq = sq.get()
        let piece = state.board.on(clickedSq)
        if piece.kind != Empty:
            state.dragSourceSquare = some(clickedSq)
            state.dragCursor = some(termPixelToBoardPixel(state, mouse.x, mouse.y, boardTermRow, boardTermCol))
            state.selectedSquare = some(clickedSq)
            state.legalDestinations = @[]
        else:
            state.resetSquareSelection()

    of maRelease:
        if state.dragSourceSquare.isSome():
            let fromSq = state.dragSourceSquare.get()
            state.dragSourceSquare = none(Square)
            state.dragCursor = none(tuple[x, y: int])

            var pos = state.board.position.clone()
            let piece = pos.on(fromSq)
            if piece.kind == Empty:
                state.resetSquareSelection()
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
                state.resetSquareSelection()
        elif sq.isNone():
            state.resetSquareSelection()

    of maMove:
        if state.dragSourceSquare.isSome():
            state.dragCursor = some(termPixelToBoardPixel(state, mouse.x, mouse.y, boardTermRow, boardTermCol))


proc handleBoardSetupKey*(state: AppState, key: Key): bool =
    let setupSpawnPiece = setupSpawnPieceForKey(key)
    if setupSpawnPiece.isSome():
        state.boardSetup.spawnPiece = setupSpawnPiece
        let piece = setupSpawnPiece.get()
        state.resetSquareSelection()
        state.setStatus(&"Spawn armed: {piece.toChar()} (click a square to place it)")
        return true

    case key
    of Key.W, Key.ShiftW:
        toggleBoardSetupCastling(state, White, kingSide = false)
        true
    of Key.X, Key.ShiftX:
        toggleBoardSetupCastling(state, White, kingSide = true)
        true
    of Key.Y, Key.ShiftY:
        toggleBoardSetupCastling(state, Black, kingSide = false)
        true
    of Key.Z, Key.ShiftZ:
        toggleBoardSetupCastling(state, Black, kingSide = true)
        true
    else:
        false
