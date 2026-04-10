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

## Move parsing and keyboard move-entry handling extracted from input.nim.

import std/[options, strformat, strutils]

import heimdall/[board, movegen, moves, pieces]
import heimdall/util/move_parse
import heimdall/tui/[state, analysis, play]
import heimdall/tui/util/[san, premove]


proc parseUCIMoveString*(board: Chessboard, moveStr: string, chess960: bool = false): tuple[move: Move, error: string] =
    let parsed = move_parse.parseUCIMove(board.position, moveStr, chess960=chess960, requireSourcePiece=true)
    result.move = parsed.move
    result.error = formatUCIMoveParseError(parsed.error, quoteSquares=true)


proc commitEnteredMove(state: AppState, move: Move, san: string, beep = false): bool =
    state.lastMove = some((fromSq: move.startSquare(), toSq: move.targetSquare()))

    let applied = state.board.makeMove(move)
    if applied == nullMove():
        return false

    state.addMoveRecord(move, san)
    state.undoneHistory = @[]
    state.pendingPremoves = @[]
    state.resetSquareSelection()

    if beep:
        stdout.write("\a")
        stdout.flushFile()

    if state.mode == ModePlay and state.play.phase == PlayerTurn:
        onPlayerMove(state)
    elif state.analysis.running:
        restartAnalysis(state)

    true


proc processUCIMove*(state: AppState, moveStr: string) =
    if state.mode == ModeReplay:
        state.setError("Cannot make moves in replay mode")
        return
    if state.boardSetup.active:
        state.setError("Cannot enter moves in board setup mode")
        return
    if state.mode == ModePlay and state.play.phase == EngineTurn and not state.play.watchMode:
        let lower = moveStr.toLowerAscii()
        if lower.len notin 4..5:
            state.setError("Invalid premove syntax")
            return
        try:
            let fromSq = lower[0..1].toSquare(checked=true)
            let toSq = lower[2..3].toSquare(checked=true)
            let previewBoard = premoveViewBoard(state.board, state.play.playerColor, state.pendingPremoves, state.chess960)
            let piece = previewBoard.on(fromSq)
            if piece.kind == Empty or piece.color != state.play.playerColor:
                state.setError("Premove must start from one of your pieces")
                return
            if not canQueuePremove(state.board, state.play.playerColor, state.pendingPremoves, fromSq, toSq, state.chess960):
                state.setError("Premove must be pseudo-legal")
                return
            state.queuePremove(fromSq, toSq)
            state.selectedSquare = none(Square)
            state.legalDestinations = @[]
        except ValueError:
            state.setError("Invalid premove syntax")
        return
    if state.mode == ModePlay and state.play.phase in [EngineTurn, GameOver, Setup]:
        state.setError("Cannot make moves now")
        return

    let (move, error) = parseUCIMoveString(state.board, moveStr, state.chess960)
    if move == nullMove():
        state.setError(&"Invalid move: {error}")
        return

    let result = state.board.makeMove(move)
    if result == nullMove():
        state.setError(&"Illegal move: {moveStr}")
        return

    state.board.unmakeMove()

    let sanStr = state.board.toSAN(move)
    if not state.commitEnteredMove(move, sanStr):
        state.setError(&"Illegal move: {moveStr}")


proc processSANMove*(state: AppState, sanStr: string) =
    if state.mode == ModeReplay:
        state.setError("Cannot make moves in replay mode")
        return
    if state.boardSetup.active:
        state.setError("Cannot enter moves in board setup mode")
        return
    if state.mode == ModePlay and state.play.phase in [EngineTurn, GameOver, Setup]:
        if state.play.phase == EngineTurn and not state.play.watchMode:
            state.setError("Use square selection, dragging, or UCI to queue a premove")
        else:
            state.setError("Cannot make moves now")
        return

    let (move, error) = state.board.parseSAN(sanStr)
    if move == nullMove():
        state.setError(&"Invalid SAN: {error}")
        return

    let san = state.board.toSAN(move)
    if not state.commitEnteredMove(move, san):
        state.setError(&"Illegal move: {sanStr}")


proc handleSquareSelectionInput*(state: AppState, trimmed: string): bool =
    let lower = trimmed.toLowerAscii()
    if lower.len != 2 or lower[0] notin 'a'..'h' or lower[1] notin '1'..'8':
        return false

    try:
        let sq = lower.toSquare(checked=true)
        let canQueuePremoveMode = state.mode == ModePlay and state.play.phase == EngineTurn and not state.play.watchMode
        let previewBoard =
            if canQueuePremoveMode:
                premoveViewBoard(state.board, state.play.playerColor, state.pendingPremoves, state.chess960)
            else:
                nil
        let piece = if canQueuePremoveMode: previewBoard.on(sq) else: state.board.on(sq)
        if state.selectedSquare.isSome():
            let fromSq = state.selectedSquare.get()
            if canQueuePremoveMode:
                if canQueuePremove(state.board, state.play.playerColor, state.pendingPremoves, fromSq, sq, state.chess960):
                    state.queuePremove(fromSq, sq)
                    state.selectedSquare = none(Square)
                    state.legalDestinations = @[]
                else:
                    state.setError(&"Invalid premove from {fromSq.toUCI()} to {sq.toUCI()}")
                    state.legalDestinations = premoveDestinations(state.board, state.play.playerColor, state.pendingPremoves, fromSq, state.chess960)
                return true

            var moves = newMoveList()
            state.board.generateMoves(moves)

            var hasMove = false
            var isPromo = false
            for move in moves:
                if move.startSquare() == fromSq and move.targetSquare() == sq:
                    hasMove = true
                    if move.isPromotion():
                        isPromo = true
                    break

            if hasMove:
                state.selectedSquare = none(Square)
                state.legalDestinations = @[]
                if isPromo and not state.autoQueen:
                    state.promotionPending = true
                    state.promotionFrom = fromSq
                    state.promotionTo = sq
                    state.setStatus("Promote to: [Q]ueen / [R]ook / [B]ishop / [N]knight")
                else:
                    var foundMove = nullMove()
                    for move in moves:
                        if move.startSquare() == fromSq and move.targetSquare() == sq:
                            if move.isPromotion():
                                if move.flag().promotionToPiece() == Queen:
                                    foundMove = move
                                    break
                            else:
                                foundMove = move
                                break
                    if foundMove != nullMove():
                        let sanStr = state.board.toSAN(foundMove)
                        discard state.commitEnteredMove(foundMove, sanStr, beep=true)
            elif piece.kind != Empty and piece.color == state.board.sideToMove():
                state.selectedSquare = some(sq)
                state.legalDestinations = @[]
                for move in moves:
                    if move.startSquare() == sq:
                        state.legalDestinations.add(move.targetSquare())
            else:
                state.setError(&"No legal move from {state.selectedSquare.get()} to {sq}")
                state.selectedSquare = none(Square)
                state.legalDestinations = @[]
        elif canQueuePremoveMode and piece.kind != Empty and piece.color == state.play.playerColor:
            state.selectedSquare = some(sq)
            state.legalDestinations = premoveDestinations(state.board, state.play.playerColor, state.pendingPremoves, sq, state.chess960)
            state.setStatus(&"Selected {piece.toChar()} on {lower}. Type premove destination square.")
        elif piece.kind != Empty and piece.color == state.board.sideToMove():
            state.selectedSquare = some(sq)
            state.legalDestinations = @[]
            var moves = newMoveList()
            state.board.generateMoves(moves)
            for move in moves:
                if move.startSquare() == sq:
                    state.legalDestinations.add(move.targetSquare())
            state.setStatus(&"Selected {piece.toChar()} on {lower}. Type destination square.")
        elif piece.kind == Empty:
            processSANMove(state, lower)
        else:
            if canQueuePremoveMode:
                state.setError(&"No piece of yours to premove from on {lower}")
            else:
                state.setError(&"No piece to select on {lower}")
        true
    except ValueError:
        false
