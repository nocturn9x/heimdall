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

## Play/replay/PGN command handling extracted from input.nim.

import std/[options, strutils, strformat, times]

import heimdall/[board, moves, pieces, movegen, search, transpositions]
import heimdall/tui/[state, analysis, play]
import heimdall/tui/util/clock
import heimdall/tui/util/pgn


proc loadReplay(state: AppState, path: string, gameIdx: int) =
    let content = readFile(path)
    let games = parsePGN(content)
    if games.len == 0:
        state.setError("No games found in PGN file")
        return
    if gameIdx >= games.len:
        state.setError(&"Game {gameIdx + 1} not found (file has {games.len} game(s))")
        return

    if games.len > 1 and gameIdx == 0:
        var listing = &"{games.len} games found. "
        for i, g in games:
            if i >= 5:
                listing &= &"... Use :load {path} <1-{games.len}>"
                break
            let w = g.getTag("White")
            let b = g.getTag("Black")
            listing &= &"[{i+1}] {w} vs {b} "
        state.setStatus(listing)

    let game = games[gameIdx]
    if state.analysis.running:
        stopAnalysis(state)

    let startBoard =
        if game.startFEN.len > 0:
            newChessboardFromFEN(game.startFEN)
        else:
            newDefaultChessboard()

    state.board = startBoard
    state.enterReplayMode()
    state.replay.moves = game.moves
    state.replay.sanHistory = game.sanMoves
    state.replay.startPosition = some(startBoard.position.clone())
    state.replay.moveIndex = 0
    state.replay.tags = game.tags
    state.replay.result = game.result

    let white = game.getTag("White")
    let black = game.getTag("Black")
    let gameNum = if games.len > 1: &" (game {gameIdx + 1}/{games.len})" else: ""
    let info =
        if white.len > 0 or black.len > 0:
            &"{white} vs {black} ({game.result}){gameNum}"
        else:
            &"Loaded {game.moves.len} moves ({game.result}){gameNum}"
    state.setStatus(&"PGN loaded: {info}. Use Left/Right arrows to navigate.")


proc exportCurrentGame(state: AppState, path: string) =
    if state.sanHistory.len == 0:
        state.setError("No moves to export")
        return

    var pgn = ""
    pgn &= "[Event \"Heimdall TUI Game\"]\n"
    pgn &= "[Site \"Local\"]\n"
    let now = times.now()
    pgn &= &"[Date \"{now.year}.{now.month.ord:02d}.{now.monthday:02d}\"]\n"

    if state.mode == ModePlay:
        let whiteName =
            if state.play.watchMode: "Heimdall"
            elif state.play.playerColor == White: "Human"
            else: "Heimdall"
        let blackName =
            if state.play.watchMode: "Heimdall"
            elif state.play.playerColor == Black: "Human"
            else: "Heimdall"
        pgn &= &"[White \"{whiteName}\"]\n"
        pgn &= &"[Black \"{blackName}\"]\n"
    else:
        pgn &= "[White \"?\"]\n"
        pgn &= "[Black \"?\"]\n"

    if state.startFEN != DEFAULT_START_FEN:
        pgn &= &"[FEN \"{state.startFEN}\"]\n"
        pgn &= "[SetUp \"1\"]\n"
    if state.chess960:
        pgn &= "[Variant \"Chess960\"]\n"

    let result =
        if state.play.result.isSome():
            let r = state.play.result.get()
            if "1-0" in r: "1-0"
            elif "0-1" in r: "0-1"
            elif "1/2" in r: "1/2-1/2"
            else: "*"
        else:
            "*"
    pgn &= &"[Result \"{result}\"]\n\n"

    var moveNum = 1
    for i, san in state.sanHistory:
        if i mod 2 == 0:
            pgn &= $moveNum & ". "
        pgn &= san & " "
        if i < state.moveComments.len and state.moveComments[i].len > 0:
            pgn &= "{" & state.moveComments[i] & "} "
        if i mod 2 == 1:
            inc moveNum
    pgn &= result & "\n"

    writeFile(path, pgn)
    state.setStatus(&"PGN saved to {path}")


proc handleTakeback(state: AppState) =
    if state.mode != ModePlay or state.play.phase != PlayerTurn:
        state.setError("Takeback only available during your turn in play mode")
    elif not state.play.allowTakeback:
        state.setError("Takeback is disabled for this game")
    elif state.moveHistory.len < 2:
        state.setError("No moves to take back")
    else:
        state.board.unmakeMove()
        discard state.popMoveRecord()
        state.board.unmakeMove()
        discard state.popMoveRecord()
        state.resetArrowState()
        if state.moveHistory.len > 0:
            let m = state.moveHistory[^1]
            state.lastMove = some((fromSq: m.startSquare(), toSq: m.targetSquare()))
        else:
            state.lastMove = none(tuple[fromSq, toSq: Square])
        state.selectedSquare = none(Square)
        state.legalDestinations = @[]
        state.setStatus("Takeback: your last move undone")


proc handleResign(state: AppState) =
    if state.mode == ModePlay and state.play.phase in [PlayerTurn, EngineTurn]:
        let winner = if state.play.playerColor == White: "0-1" else: "1-0"
        state.play.result = some(&"{winner} (resignation)")
        state.play.phase = GameOver
        state.play.playerClock.stop()
        state.play.engineClock.stop()
        if state.play.engineThinking:
            stopSearch(state)
            discard state.channels.response.recv()
            state.play.engineThinking = false
        state.setStatus(&"You resigned. {winner}")
    else:
        state.setError("Not in a game")


proc handleGameCommand*(state: AppState, parts: seq[string]): bool =
    if parts.len == 0:
        return false

    case parts[0].toLowerAscii():
        of "load":
            if state.mode == ModePlay and state.play.phase != Setup:
                state.setError("Cannot load PGN during a game. Use :exit first.")
            elif parts.len < 2:
                state.setError("Usage: :load <pgn-file> [game-number]")
            else:
                var path: string
                var gameIdx = 0
                let lastPart = parts[^1]
                try:
                    let n = parseInt(lastPart)
                    if n >= 1 and parts.len >= 3:
                        gameIdx = n - 1
                        path = parts[1..^2].join(" ")
                    else:
                        path = parts[1..^1].join(" ")
                except ValueError:
                    path = parts[1..^1].join(" ")

                try:
                    state.loadReplay(path, gameIdx)
                except IOError:
                    state.setError(&"Cannot read file: {path}")
                except CatchableError as e:
                    state.setError(&"PGN error: {e.msg}")
            return true

        of "pgn":
            if parts.len < 2:
                state.setError("Usage: :pgn <file>")
            else:
                let path = parts[1..^1].join(" ")
                try:
                    state.exportCurrentGame(path)
                except IOError:
                    state.setError(&"Cannot write to {path}")
            return true

        of "watch":
            if state.analysis.running:
                stopAnalysis(state)
            state.preparePlaySetup(watchMode=true)
            state.play.playerLimit = PlayLimitConfig()
            state.play.engineLimit = PlayLimitConfig()
            state.setStatus("Engine vs Engine. Choose variant: [S]tandard / [f]rc / [d]frc / [c]urrent", persistent=true)
            return true

        of "play":
            state.play.watchMode = false
            startPlayMode(state)
            return true

        of "rematch":
            startRematch(state)
            return true

        of "exit":
            if state.mode == ModePlay:
                exitPlayMode(state)
            elif state.mode == ModeReplay:
                state.enterAnalysisMode()
                state.setStatus("Exited replay mode")
            else:
                state.setError("Nothing to exit")
            return true

        of "clear":
            if state.analysis.running or state.play.engineThinking:
                state.setError("Cannot clear while searching. Use :stop first.")
            else:
                state.ttable.init()
                state.searcher.histories.clear()
                state.searcher.resetWorkers()
                state.setStatus("Engine state cleared (TT, histories, workers)")
            return true

        of "takeback", "tb":
            state.handleTakeback()
            return true

        of "resign":
            state.handleResign()
            return true

        else:
            return false
