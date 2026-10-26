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
#
# Authored with assistance from AI agents.

## Play/replay/PGN command handling extracted from input.nim.

import std/[options, os, strutils, strformat, times]

import heimdall/[board, moves, pieces, movegen, search, transpositions]
import heimdall/tui/[state, analysis, play]
import heimdall/tui/util/uci_client
import heimdall/tui/util/clock
import heimdall/tui/util/[pgn, openings]


proc resultReason(resultText: string): string =
    let openParen = resultText.find('(')
    if openParen < 0 or not resultText.endsWith(")"):
        return ""
    resultText[openParen + 1..^2].strip()


proc pgnEscape(value: string): string =
    for c in value:
        case c:
            of '\\', '"':
                result.add('\\')
                result.add(c)
            of '\n', '\r':
                result.add(' ')
            else:
                result.add(c)


proc configureReplayVariant(state: AppState, game: PGNGame) =
    let variant = game.getTag("Variant").toLowerAscii()
    if "double" in variant and "fischer" in variant:
        state.chess960 = true
        state.play.variant = DoubleFischerRandom
    elif "960" in variant or "fischer" in variant:
        state.chess960 = true
        state.play.variant = FischerRandom
    else:
        state.chess960 = false
        state.play.variant = Standard


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
    if state.gameAnalysis.running:
        stopGameAnalysis(state)

    let startBoard =
        if game.startFEN.len > 0:
            newChessboardFromFEN(game.startFEN)
        else:
            newDefaultChessboard()

    state.board = startBoard
    state.enterReplayMode()
    state.configureReplayVariant(game)
    state.replay.moves = game.moves
    state.replay.sanHistory = game.sanMoves
    state.replay.startPosition = some(startBoard.position.clone())
    state.replay.moveIndex = 0
    state.replay.openingHistory = classifyReplayOpenings(startBoard.position.clone(), game.moves, state.chess960)
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
            if state.play.watchMode and state.play.watchWhiteExternal.name.len > 0: state.play.watchWhiteExternal.name
            elif state.play.watchMode: "Heimdall"
            elif state.play.playerColor == White: "Human"
            else: "Heimdall"
        let blackName =
            if state.play.watchMode and state.play.watchBlackExternal.name.len > 0: state.play.watchBlackExternal.name
            elif state.play.watchMode: "Heimdall"
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
    pgn &= &"[Result \"{result}\"]\n"
    if state.play.result.isSome():
        let termination = resultReason(state.play.result.get())
        if termination.len > 0:
            pgn &= &"[Termination \"{pgnEscape(termination)}\"]\n"
    pgn &= "\n"

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
        # Take back on the authoritative live game, then snap the view to the new tip.
        state.play.liveBoard.unmakeMove()
        discard state.popMoveRecord()
        state.play.liveBoard.unmakeMove()
        discard state.popMoveRecord()
        state.resetArrowState(clearUserAnnotations = false)
        state.play.viewPly = state.moveHistory.len
        state.rebuildPlayView()
        state.selectedSquare = none(Square)
        state.legalDestinations = @[]
        state.setStatus("Takeback: your last move undone")


proc handleResign(state: AppState) =
    if state.mode == ModePlay and state.play.watchMode:
        state.setError("Use :exit to stop a watch game")
        return
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


proc optionUsage(): string =
    "Usage: :ucioption <white|black|both> <name>=<value> or :ucioption <white|black|both> \"Option Name\" value"


proc parseUCIOptionSetting(tokens: seq[string], start: int): tuple[option: UCIOptionSetting, error: string] =
    if start >= tokens.len:
        return (UCIOptionSetting(), optionUsage())

    let first = tokens[start]
    let eq = first.find('=')
    if eq > 0:
        if eq >= first.high:
            return (UCIOptionSetting(), optionUsage())
        let name = first[0..<eq].strip()
        let value = first[eq + 1..^1].strip()
        if name.len == 0 or value.len == 0:
            return (UCIOptionSetting(), optionUsage())
        return (UCIOptionSetting(name: name, value: value), "")

    if start + 1 >= tokens.len:
        return (UCIOptionSetting(), optionUsage())

    let name = first.strip()
    let value = tokens[start + 1..^1].join(" ").strip()
    if name.len == 0 or value.len == 0:
        return (UCIOptionSetting(), optionUsage())
    (UCIOptionSetting(name: name, value: value), "")


proc appendOptionForSide(state: AppState, side: PieceColor, option: UCIOptionSetting): tuple[applied: bool, error: string] =
    let engine =
        if side == White:
            addr state.play.watchWhiteExternal
        else:
            addr state.play.watchBlackExternal

    if engine[].command.len == 0 and not engine[].initialized:
        return (false, "No external UCI engine configured for " & $side)

    engine[].options.add(option)
    if engine[].initialized and engine[].client != nil:
        try:
            engine[].client.setOption(option.name, option.value)
            return (true, "")
        except CatchableError as e:
            return (false, e.msg)
    (false, "")


proc handleUCIOptionCommand(state: AppState, raw: string): bool =
    let tokens = parseCmdLine(raw)
    if tokens.len < 3:
        state.setError(optionUsage())
        return true

    let parsed = parseUCIOptionSetting(tokens, 2)
    if parsed.error.len > 0:
        state.setError(parsed.error)
        return true

    var sides: seq[PieceColor]
    case tokens[1].toLowerAscii():
        of "white", "w":
            sides = @[White]
        of "black", "b":
            sides = @[Black]
        of "both", "all":
            sides = @[White, Black]
        else:
            state.setError(optionUsage())
            return true

    var appliedCount = 0
    var storedCount = 0
    for side in sides:
        let setResult = state.appendOptionForSide(side, parsed.option)
        if setResult.error.len > 0:
            state.setError(setResult.error)
            return true
        if setResult.applied:
            inc appliedCount
        else:
            inc storedCount

    if appliedCount > 0 and storedCount > 0:
        state.setStatus(&"UCI option {parsed.option.name} applied to {appliedCount} engine(s), stored for {storedCount}")
    elif appliedCount > 0:
        state.setStatus(&"UCI option {parsed.option.name} applied")
    else:
        state.setStatus(&"UCI option {parsed.option.name} stored for next watch game")
    true


proc parseWatchEngineCommands(raw: string): tuple[white, black, error: string, whiteOptions, blackOptions: seq[UCIOptionSetting]] =
    let tokens = parseCmdLine(raw)
    if tokens.len <= 1:
        return

    let usage = "Usage: :watch [--white \"engine command\"] [--black \"engine command\"] [--white-option \"Name=value\"] [--black-option \"Name=value\"]"

    var i = 1
    while i < tokens.len:
        case tokens[i].toLowerAscii():
            of "--white", "-w":
                inc i
                if i >= tokens.len:
                    result.error = usage
                    return
                result.white = tokens[i]
            of "--black", "-b":
                inc i
                if i >= tokens.len:
                    result.error = usage
                    return
                result.black = tokens[i]
            of "--white-option", "--woption":
                inc i
                if i >= tokens.len:
                    result.error = usage
                    return
                let parsed = parseUCIOptionSetting(@["option", tokens[i]], 1)
                if parsed.error.len > 0:
                    result.error = usage
                    return
                result.whiteOptions.add(parsed.option)
            of "--black-option", "--boption":
                inc i
                if i >= tokens.len:
                    result.error = usage
                    return
                let parsed = parseUCIOptionSetting(@["option", tokens[i]], 1)
                if parsed.error.len > 0:
                    result.error = usage
                    return
                result.blackOptions.add(parsed.option)
            of "--option", "-o":
                inc i
                if i >= tokens.len:
                    result.error = usage
                    return
                let parsed = parseUCIOptionSetting(@["option", tokens[i]], 1)
                if parsed.error.len > 0:
                    result.error = usage
                    return
                result.whiteOptions.add(parsed.option)
                result.blackOptions.add(parsed.option)
            else:
                result.error = usage
                return
        inc i


proc handleGameCommand*(state: AppState, parts: seq[string], raw = ""): bool =
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

        of "ucioption":
            return state.handleUCIOptionCommand(raw)

        of "watch":
            let parsedEngines = parseWatchEngineCommands(raw)
            if parsedEngines.error.len > 0:
                state.setError(parsedEngines.error)
                return true
            if state.mode == ModePlay:
                exitPlayMode(state)
            if state.gameAnalysis.running:
                stopGameAnalysis(state)
            if state.analysis.running:
                stopAnalysis(state)
            state.preparePlaySetup(watchMode=true)
            state.play.playerLimit = PlayLimitConfig()
            state.play.engineLimit = PlayLimitConfig()
            state.play.watchWhiteExternal.command = parsedEngines.white
            state.play.watchBlackExternal.command = parsedEngines.black
            state.play.watchWhiteExternal.options = parsedEngines.whiteOptions
            state.play.watchBlackExternal.options = parsedEngines.blackOptions
            state.play.watchWhiteExternal.name = ""
            state.play.watchBlackExternal.name = ""
            state.setStatus("Engine vs Engine. Choose variant: [S]tandard / [f]rc / [d]frc / [c]urrent", persistent=true)
            return true

        of "play":
            if state.mode == ModePlay:
                exitPlayMode(state)
            if state.gameAnalysis.running:
                stopGameAnalysis(state)
            state.play.watchMode = false
            state.play.watchWhiteExternal.command = ""
            state.play.watchBlackExternal.command = ""
            state.play.watchWhiteExternal.options = @[]
            state.play.watchBlackExternal.options = @[]
            state.play.watchWhiteExternal.name = ""
            state.play.watchBlackExternal.name = ""
            startPlayMode(state)
            return true

        of "rematch":
            startRematch(state)
            return true

        of "exit":
            if state.mode == ModePlay:
                exitPlayMode(state)
            elif state.mode == ModeReplay:
                if state.gameAnalysis.running:
                    stopGameAnalysis(state)
                state.enterAnalysisMode()
                state.setStatus("Exited replay mode")
            else:
                state.setError("Nothing to exit")
            return true

        of "analyse", "analyze":
            if state.mode != ModeReplay or state.replay.moves.len == 0:
                state.setError("Load a PGN first")
            elif state.gameAnalysis.running:
                state.setError("Computer analysis is already running. Use :stop first.")
            else:
                state.beginGameAnalysisPrompt()
            return true

        of "wdl":
            discard state.toggleGameAnalysisGraphMode()
            return true

        of "clear":
            if state.analysis.running or state.play.engineThinking or state.gameAnalysis.running:
                state.setError("Cannot clear while searching. Use :stop first.")
            else:
                state.ttable.init(state.engineThreads)
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
