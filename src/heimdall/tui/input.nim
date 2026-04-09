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

## Text input parsing: classifies input as commands, UCI moves, or SAN moves

import std/[strutils, strformat, options, atomics, base64, parseutils, times]

import heimdall/[board, moves, pieces, movegen, position, search, transpositions]
import heimdall/util/scharnagl
import heimdall/tui/[state, san, analysis, play, pgn, clock]


type
    InputKind* = enum
        Command
        UCIMove
        SANMove


const SET_OPTIONS*: seq[tuple[cmd, desc: string]] = @[
    ("hash", "Transposition table size (e.g. 64, 1 GB, 256 MiB)"),
    ("threads", "Number of search threads"),
    ("multipv", "Number of analysis lines"),
    ("depth", "Search depth limit"),
    ("contempt", "Static score offset (0-3000)"),
    ("moveoverhead", "Communication delay in ms (0-30000)"),
    ("ponder", "Enable/disable pondering (true/false)"),
    ("normalizescore", "Normalize displayed scores (true/false)"),
    ("evalfile", "Path to NNUE network file"),
    ("chess960", "Enable Chess960 mode (true/false)"),
]

const COMMANDS*: seq[tuple[cmd, desc: string]] = @[
    ("help", "Show available commands"),
    ("quit", "Exit the TUI"),
    ("flip", "Flip the board orientation"),
    ("reset", "Reset to starting position"),
    ("fen", "Show or load a FEN position"),
    ("unmove", "Take back the last move"),
    ("go", "Toggle continuous analysis"),
    ("stop", "Stop the current search"),
    ("play", "Play against the engine"),
    ("rematch", "Replay the last :play game"),
    ("resign", "Resign the current game"),
    ("takeback", "Undo your last move in play mode"),
    ("watch", "Engine vs engine game"),
    ("exit", "Exit play/replay mode"),
    ("load", "Load a PGN file"),
    ("pgn", "Export current game as PGN to a file"),
    ("set", "Set engine/UCI options (:set <option> <value>)"),
    ("clear", "Reset engine state (TT, histories)"),
    ("arrows", "Toggle best-move arrow overlay"),
    ("threats", "Toggle threat highlighting"),
    ("frc", "Load a Chess960 position by number (0-959)"),
    ("dfrc", "Load a Double Fischer Random position"),
    ("chess960", "Toggle Chess960 mode on/off"),
]

const HELP_SHORTCUTS*: seq[tuple[key, desc: string]] = @[
    ("Shift+A", "Toggle best-move arrow overlay"),
    ("Shift+F", "Flip board"),
    ("Shift+Q", "Toggle auto-queen promotion"),
    ("Shift+S", "Board setup mode (analysis)"),
    ("Ctrl+C", "Quit immediately"),
    ("Ctrl+D", "Quit (press twice)"),
    ("Esc", "Cancel current action"),
    ("Left/Right", "Undo/redo moves"),
    ("Home/End", "Go to start/end"),
]

const HELP_VIEW_HEADER_ROWS* = 3
const HELP_VIEW_FOOTER_ROWS* = 2


proc helpViewportHeight*(panelHeight: int): int =
    max(1, panelHeight - HELP_VIEW_HEADER_ROWS - HELP_VIEW_FOOTER_ROWS)


proc buildHelpLines*(): seq[string] =
    result.add("Commands:")
    for (cmd, desc) in COMMANDS:
        result.add((":" & cmd).alignLeft(14) & desc)

    result.add("")
    result.add("Shortcuts:")
    for (key, desc) in HELP_SHORTCUTS:
        result.add(key.alignLeft(14) & desc)

    result.add("")
    result.add("Move input:")
    result.add("UCI notation: e2e4, e7e8q")
    result.add("SAN notation: Nf3, O-O, e8=Q")
    result.add("Square select: e2 then e4")
    result.add("Click piece, click destination")
    result.add("Right-drag: draw/toggle arrow (Shift/Ctrl=red, Alt=blue, both=yellow)")
    result.add("Board setup: drag, drop off-board deletes")
    result.add("Type p/n/b/r/q/k (Shift=White) to spawn")
    result.add("Castling toggles: w/x = white Q/K, y/z = black Q/K")
    result.add("Premoves queue; highlight colors show order")

    result.add("")
    result.add("Autocomplete:")
    result.add("Tab: accept suggestion")
    result.add("Enter: execute suggestion")
    result.add("Up/Down: navigate suggestions")


proc helpLineCount*(): int =
    buildHelpLines().len


proc updateAutocomplete*(state: AppState) =
    ## Updates autocomplete suggestions based on current input
    if not state.inputBuffer.startsWith(":") or state.inputBuffer.len < 2:
        state.acActive = false
        state.acSuggestions = @[]
        state.acSelected = -1
        return

    let content = state.inputBuffer[1..^1]
    let parts = content.splitWhitespace()

    if parts.len == 0:
        state.acActive = false
        return

    state.acSuggestions = @[]

    if parts.len == 1 and not content.endsWith(" "):
        # Autocomplete command name
        let prefix = parts[0].toLowerAscii()
        for (cmd, desc) in COMMANDS:
            if cmd.startsWith(prefix) and cmd != prefix:
                state.acSuggestions.add((cmd, desc))
    elif parts[0].toLowerAscii() == "set":
        # Autocomplete :set subcommands
        let subPrefix = if parts.len >= 2 and not content.endsWith(" "): parts[1].toLowerAscii()
                        elif content.endsWith(" "): ""
                        else: ""
        if parts.len <= 2 and (parts.len < 2 or not content.endsWith(" ") or subPrefix.len == 0):
            for (opt, desc) in SET_OPTIONS:
                if subPrefix.len == 0 or (opt.startsWith(subPrefix) and opt != subPrefix):
                    state.acSuggestions.add(("set " & opt, desc))

    state.acActive = state.acSuggestions.len > 0
    if state.acSelected >= state.acSuggestions.len:
        state.acSelected = state.acSuggestions.len - 1
    if state.acSelected < 0 and state.acSuggestions.len > 0:
        state.acSelected = 0


proc classifyInput*(s: string): InputKind =
    ## Determines whether the input is a command, UCI move, or SAN move
    if s.startsWith(":"):
        return Command
    # UCI move: 4-5 chars like e2e4, e7e8q
    if s.len in 4..5:
        let lower = s.toLowerAscii()
        if lower[0] in 'a'..'h' and lower[1] in '1'..'8' and
           lower[2] in 'a'..'h' and lower[3] in '1'..'8':
            if s.len == 5 and lower[4] notin ['q', 'r', 'b', 'n']:
                return SANMove
            return UCIMove
    return SANMove


proc parseUCIMoveString*(board: Chessboard, moveStr: string, chess960: bool = false): tuple[move: Move, error: string] =
    ## Parses a UCI move string (e.g. "e2e4") into a Move.
    ## Standalone version that doesn't depend on UCISession.
    var
        startSquare: Square
        targetSquare: Square
        flag = Normal

    if moveStr.len notin 4..5:
        return (nullMove(), "invalid move syntax")

    let move = moveStr.toLowerAscii()

    try:
        startSquare = move[0..1].toSquare(checked=true)
    except ValueError:
        return (nullMove(), &"invalid start square '{move[0..1]}'")
    try:
        targetSquare = move[2..3].toSquare(checked=true)
    except ValueError:
        return (nullMove(), &"invalid target square '{move[2..3]}'")

    let piece = board.on(startSquare)
    if piece.kind == Empty:
        return (nullMove(), &"no piece on {move[0..1]}")

    # Double pawn push
    if piece.kind == Pawn and absDistance(rank(startSquare), rank(targetSquare)) == 2:
        flag = DoublePush

    # Promotion
    if move.len == 5:
        case move[4]:
            of 'b': flag = PromotionBishop
            of 'n': flag = PromotionKnight
            of 'q': flag = PromotionQueen
            of 'r': flag = PromotionRook
            else:
                return (nullMove(), &"invalid promotion piece '{move[4]}'")

    # Capture detection
    if board.on(targetSquare).color == piece.color.opposite():
        case flag:
            of PromotionBishop: flag = CapturePromotionBishop
            of PromotionKnight: flag = CapturePromotionKnight
            of PromotionRook: flag = CapturePromotionRook
            of PromotionQueen: flag = CapturePromotionQueen
            else: flag = Capture

    # Castling detection
    let canCastle = board.canCastle()

    if piece.kind == King:
        if startSquare in ["e1".toSquare(), "e8".toSquare()]:
            case targetSquare:
                of "c1".toSquare(), "c8".toSquare():
                    flag = LongCastling
                    targetSquare = canCastle.queen
                of "g1".toSquare(), "g8".toSquare():
                    flag = ShortCastling
                    targetSquare = canCastle.king
                else:
                    if targetSquare in [canCastle.king, canCastle.queen]:
                        if not chess960:
                            return (nullMove(), &"Chess960-style castling move '{moveStr}', but Chess960 is not enabled")
                        flag = if targetSquare == canCastle.king: ShortCastling else: LongCastling
        elif targetSquare in [canCastle.king, canCastle.queen]:
            if not chess960:
                return (nullMove(), &"Chess960-style castling move '{moveStr}', but Chess960 is not enabled")
            flag = if targetSquare == canCastle.king: ShortCastling else: LongCastling

    # En passant
    if piece.kind == Pawn and targetSquare == board.position.enPassantSquare:
        flag = EnPassant

    result.move = createMove(startSquare, targetSquare, flag)


proc processCommand*(state: AppState, cmd: string) =
    ## Processes a colon-prefixed command
    let parts = cmd.strip().splitWhitespace()
    if parts.len == 0:
        return

    # Dismiss autocomplete on command execution
    state.acActive = false

    case parts[0].toLowerAscii()
    of "help", "h", "?":
        state.helpVisible = not state.helpVisible
        state.helpScroll = 0

    of "quit", "q":
        state.shouldQuit = true

    of "flip":
        state.flipped = not state.flipped

    of "reset":
        if state.mode == ModePlay and state.playPhase != Setup:
            state.setError("Cannot reset board during a game. Use :exit first.")
            return
        state.board = newDefaultChessboard()
        state.clearMoveRecords()
        state.lastMove = none(tuple[fromSq, toSq: Square])
        state.selectedSquare = none(Square)
        state.legalDestinations = @[]
        state.chess960 = false
        state.setStatus("Board reset to starting position")

    of "fen":
        if parts.len < 2:
            # Copy FEN to clipboard via OSC 52 and show it
            let fen = state.board.toFEN()
            let encoded = base64.encode(fen)
            stdout.write("\x1b]52;c;" & encoded & "\x1b\\")
            stdout.flushFile()
            state.setStatus("FEN copied: " & fen)
        else:
            if state.mode == ModePlay and state.playPhase != Setup:
                state.setError("Cannot load FEN during a game. Use :exit first.")
                return
            let fenStr = parts[1..^1].join(" ")
            try:
                state.board = newChessboardFromFEN(fenStr)
                state.clearMoveRecords()
                state.lastMove = none(tuple[fromSq, toSq: Square])
                state.selectedSquare = none(Square)
                state.legalDestinations = @[]
                state.startFEN = fenStr
                state.setStatus("Position loaded from FEN")
            except CatchableError as e:
                state.setError(&"Invalid FEN: {e.msg}")

    of "unmove":
        if state.moveHistory.len == 0:
            state.setError("No moves to undo")
        else:
            state.board.unmakeMove()
            discard state.popMoveRecord()
            if state.moveHistory.len > 0:
                let lastM = state.moveHistory[^1]
                state.lastMove = some((fromSq: lastM.startSquare(), toSq: lastM.targetSquare()))
            else:
                state.lastMove = none(tuple[fromSq, toSq: Square])
            state.selectedSquare = none(Square)
            state.legalDestinations = @[]
            state.setStatus("Move undone")

    of "set":
        if state.analysisRunning or state.engineThinking:
            state.setError("Cannot change settings while searching. Use :stop first, then :set.")
            return
        if parts.len < 3:
            state.setError("Usage: :set <option> <value>")
        else:
            case parts[1].toLowerAscii()
            of "multipv":
                try:
                    let n = parseInt(parts[2])
                    if n < 1 or n > 500:
                        state.setError("MultiPV must be between 1 and 500")
                    else:
                        state.multiPV = n
                        state.analysisLines = @[]  # Clear stale lines
                        if state.analysisRunning:
                            restartAnalysis(state)
                        state.setStatus(&"MultiPV set to {n}")
                except ValueError:
                    state.setError(&"Invalid number: {parts[2]}")
            of "threads":
                try:
                    let n = parseInt(parts[2])
                    if n < 1 or n > 1024:
                        state.setError("Threads must be between 1 and 1024")
                    else:
                        state.engineThreads = n
                        state.searcher.setWorkerCount(n - 1)  # n total = 1 main + (n-1) workers
                        state.setStatus(&"Threads set to {n}")
                except ValueError:
                    state.setError(&"Invalid number: {parts[2]}")
            of "hash":
                let raw = parts[2..^1].join(" ").strip()
                # Check if it's a bare number (no unit suffix) -> treat as MiB
                var sizeMiB: int64
                try:
                    let asNum = parseBiggestInt(raw)
                    # Bare number, interpret as MiB
                    sizeMiB = asNum
                except ValueError:
                    # Has a unit suffix, use parseSize (returns bytes)
                    var sizeBytes: int64
                    let consumed = parseSize(raw, sizeBytes)
                    if consumed == 0:
                        state.setError("Invalid size. Examples: 64, 256 MiB, 1 GB, 2 GiB")
                        return
                    sizeMiB = sizeBytes div (1024 * 1024)

                if sizeMiB < 1 or sizeMiB > 33554432:
                    state.setError("Hash must be between 1 MiB and 32 TiB")
                else:
                    state.engineHash = sizeMiB.uint64
                    state.ttable.resize(sizeMiB.uint64 * 1024 * 1024)
                    state.setStatus(&"Hash resized to {sizeMiB} MiB")
            of "depth":
                try:
                    let n = parseInt(parts[2])
                    if n < 1 or n > 255:
                        state.setError("Depth must be between 1 and 255")
                    else:
                        state.engineDepth = some(n)
                        state.setStatus(&"Depth limit set to {n}")
                except ValueError:
                    state.setError(&"Invalid number: {parts[2]}")
            of "contempt":
                try:
                    let n = parseInt(parts[2])
                    if n < 0 or n > 3000:
                        state.setError("Contempt must be between 0 and 3000")
                    else:
                        state.searcher.setContempt(n.int32)
                        state.setStatus(&"Contempt set to {n}")
                except ValueError:
                    state.setError(&"Invalid number: {parts[2]}")
            of "moveoverhead":
                try:
                    let n = parseInt(parts[2])
                    if n < 0 or n > 30000:
                        state.setError("Move overhead must be between 0 and 30000 ms")
                    else:
                        state.setStatus(&"Move overhead set to {n} ms")
                except ValueError:
                    state.setError(&"Invalid number: {parts[2]}")
            of "ponder":
                let v = parts[2].toLowerAscii()
                if v in ["true", "on", "yes", "1"]:
                    state.setStatus("Ponder enabled")
                elif v in ["false", "off", "no", "0"]:
                    state.setStatus("Ponder disabled")
                else:
                    state.setError("Expected true/false")
            of "normalizescore":
                let v = parts[2].toLowerAscii()
                if v in ["true", "on", "yes", "1"]:
                    state.searcher.state.normalizeScore.store(true, moRelaxed)
                    state.setStatus("Score normalization enabled")
                elif v in ["false", "off", "no", "0"]:
                    state.searcher.state.normalizeScore.store(false, moRelaxed)
                    state.setStatus("Score normalization disabled")
                else:
                    state.setError("Expected true/false")
            of "chess960", "uci_chess960":
                let v = parts[2].toLowerAscii()
                if v in ["true", "on", "yes", "1"]:
                    state.chess960 = true
                    state.searcher.state.chess960.store(true, moRelaxed)
                    state.setStatus("Chess960 enabled")
                elif v in ["false", "off", "no", "0"]:
                    state.chess960 = false
                    state.variant = Standard
                    state.searcher.state.chess960.store(false, moRelaxed)
                    state.setStatus("Chess960 disabled")
                else:
                    state.setError("Expected true/false")
            of "evalfile":
                let path = parts[2..^1].join(" ")
                if path == "<default>" or path == "default":
                    state.searcher.setNetwork("")
                    state.setStatus("Using default network")
                else:
                    state.searcher.setNetwork(path)
                    state.setStatus(&"Network loaded: {path}")
            else:
                state.setError(&"Unknown option: {parts[1]}. Use :help for available options.")

    of "load":
        if state.mode == ModePlay and state.playPhase != Setup:
            state.setError("Cannot load PGN during a game. Use :exit first.")
        elif parts.len < 2:
            state.setError("Usage: :load <pgn-file> [game-number]")
        else:
            # Check if last arg is a game number
            var path: string
            var gameIdx = 0
            let lastPart = parts[^1]
            try:
                let n = parseInt(lastPart)
                if n >= 1 and parts.len >= 3:
                    gameIdx = n - 1  # 1-based to 0-based
                    path = parts[1..^2].join(" ")
                else:
                    path = parts[1..^1].join(" ")
            except ValueError:
                path = parts[1..^1].join(" ")

            try:
                let content = readFile(path)
                let games = parsePGN(content)
                if games.len == 0:
                    state.setError("No games found in PGN file")
                elif gameIdx >= games.len:
                    state.setError(&"Game {gameIdx + 1} not found (file has {games.len} game(s))")
                else:
                    if games.len > 1 and gameIdx == 0:
                        # List available games
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
                    if state.analysisRunning:
                        stopAnalysis(state)

                    let startBoard = if game.startFEN.len > 0:
                        newChessboardFromFEN(game.startFEN)
                    else:
                        newDefaultChessboard()

                    state.board = startBoard
                    state.mode = ModeReplay
                    state.pgnMoves = game.moves
                    state.pgnSanHistory = game.sanMoves
                    state.pgnStartPosition = some(startBoard.position.clone())
                    state.pgnMoveIndex = 0
                    state.pgnTags = game.tags
                    state.pgnResult = game.result
                    state.clearMoveRecords()
                    state.lastMove = none(tuple[fromSq, toSq: Square])
                    state.selectedSquare = none(Square)
                    state.legalDestinations = @[]

                    let white = game.getTag("White")
                    let black = game.getTag("Black")
                    let gameNum = if games.len > 1: &" (game {gameIdx + 1}/{games.len})" else: ""
                    let info = if white.len > 0 or black.len > 0:
                        &"{white} vs {black} ({game.result}){gameNum}"
                    else:
                        &"Loaded {game.moves.len} moves ({game.result}){gameNum}"
                    state.setStatus(&"PGN loaded: {info}. Use Left/Right arrows to navigate.")
            except IOError:
                state.setError(&"Cannot read file: {path}")
            except CatchableError as e:
                state.setError(&"PGN error: {e.msg}")

    of "pgn":
        if parts.len < 2:
            state.setError("Usage: :pgn <file>")
        elif state.sanHistory.len == 0:
            state.setError("No moves to export")
        else:
            var pgn = ""
            pgn &= "[Event \"Heimdall TUI Game\"]\n"
            pgn &= "[Site \"Local\"]\n"
            # Date
            let now = times.now()
            pgn &= &"[Date \"{now.year}.{now.month.ord:02d}.{now.monthday:02d}\"]\n"
            # Player names
            if state.mode == ModePlay:
                let whiteName =
                    if state.watchMode: "Heimdall"
                    elif state.playerColor == White: "Human"
                    else: "Heimdall"
                let blackName =
                    if state.watchMode: "Heimdall"
                    elif state.playerColor == Black: "Human"
                    else: "Heimdall"
                pgn &= &"[White \"{whiteName}\"]\n"
                pgn &= &"[Black \"{blackName}\"]\n"
            else:
                pgn &= "[White \"?\"]\n"
                pgn &= "[Black \"?\"]\n"
            if state.startFEN != "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1":
                pgn &= &"[FEN \"{state.startFEN}\"]\n"
                pgn &= "[SetUp \"1\"]\n"
            if state.chess960:
                pgn &= "[Variant \"Chess960\"]\n"
            # Result
            let result = if state.gameResult.isSome():
                let r = state.gameResult.get()
                if "1-0" in r: "1-0"
                elif "0-1" in r: "0-1"
                elif "1/2" in r: "1/2-1/2"
                else: "*"
            else: "*"
            pgn &= &"[Result \"{result}\"]\n\n"
            # Movetext
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
            let path = parts[1..^1].join(" ")
            try:
                writeFile(path, pgn)
                state.setStatus(&"PGN saved to {path}")
            except IOError:
                state.setError(&"Cannot write to {path}")

    of "watch":
        if state.analysisRunning:
            stopAnalysis(state)
        state.mode = ModePlay
        state.watchMode = true
        state.clearUserArrows()
        state.playerLimit.kind = PlayUnlimited
        state.engineLimit.kind = PlayUnlimited
        state.engineDepth = none(int)
        state.watchDepth = none(int)
        state.pendingLimitTarget = NoPendingLimit
        state.pendingSoftNodes = 0
        state.playPhase = Setup
        state.setupStep = ChooseVariant
        state.gameResult = none(string)
        state.setStatus("Engine vs Engine. Choose variant: [S]tandard / [f]rc / [d]frc / [c]urrent", persistent=true)

    of "play":
        state.watchMode = false
        startPlayMode(state)

    of "rematch":
        startRematch(state)

    of "exit":
        if state.mode == ModePlay:
            exitPlayMode(state)
        elif state.mode == ModeReplay:
            state.mode = ModeAnalysis
            state.setStatus("Exited replay mode")
        else:
            state.setError("Nothing to exit")

    of "clear":
        if state.analysisRunning or state.engineThinking:
            state.setError("Cannot clear while searching. Use :stop first.")
        else:
            state.ttable.init()
            state.searcher.histories.clear()
            state.searcher.resetWorkers()
            state.setStatus("Engine state cleared (TT, histories, workers)")

    of "go", "analyze", "analysis":
        if state.mode == ModePlay:
            state.setError("Exit play mode first (:exit)")
        else:
            toggleAnalysis(state)

    of "takeback", "tb":
        if state.mode != ModePlay or state.playPhase != PlayerTurn:
            state.setError("Takeback only available during your turn in play mode")
        elif not state.allowTakeback:
            state.setError("Takeback is disabled for this game")
        elif state.moveHistory.len < 2:
            state.setError("No moves to take back")
        else:
            # Undo both the engine's last move and the player's last move
            state.board.unmakeMove()  # undo engine's move
            discard state.popMoveRecord()
            state.board.unmakeMove()  # undo player's move
            discard state.popMoveRecord()
            if state.moveHistory.len > 0:
                let m = state.moveHistory[^1]
                state.lastMove = some((fromSq: m.startSquare(), toSq: m.targetSquare()))
            else:
                state.lastMove = none(tuple[fromSq, toSq: Square])
            state.selectedSquare = none(Square)
            state.legalDestinations = @[]
            state.setStatus("Takeback: your last move undone")

    of "resign":
        if state.mode == ModePlay and state.playPhase in [PlayerTurn, EngineTurn]:
            let winner = if state.playerColor == White: "0-1" else: "1-0"
            state.gameResult = some(&"{winner} (resignation)")
            state.playPhase = GameOver
            state.playerClock.stop()
            state.engineClock.stop()
            if state.engineThinking:
                stopSearch(state)
                discard state.channels.response.recv()
                state.engineThinking = false
            state.setStatus(&"You resigned. {winner}")
        else:
            state.setError("Not in a game")

    of "arrows":
        state.showEngineArrows = not state.showEngineArrows
        state.setStatus("Engine arrows: " & (if state.showEngineArrows: "ON" else: "OFF"))

    of "threats":
        state.showThreats = not state.showThreats
        state.setStatus("Threats: " & (if state.showThreats: "ON" else: "OFF"))

    of "stop":
        if state.analysisRunning:
            stopAnalysis(state)
            state.setStatus("Search stopped")
        else:
            state.setError("No search running")

    of "frc":
        if state.mode == ModePlay and state.playPhase != Setup:
            state.setError("Cannot change position during a game. Use :exit first.")
            return
        if parts.len < 2:
            state.setError("Usage: :frc <number> (0-959)")
        else:
            try:
                let n = parseInt(parts[1])
                if n notin 0..959:
                    state.setError("Scharnagl number must be 0-959")
                else:
                    let fen = scharnaglToFEN(n)
                    state.board = newChessboardFromFEN(fen)
                    state.clearMoveRecords()
                    state.lastMove = none(tuple[fromSq, toSq: Square])
                    state.selectedSquare = none(Square)
                    state.legalDestinations = @[]
                    state.startFEN = fen
                    state.chess960 = true
                    state.variant = FischerRandom
                    state.searcher.state.chess960.store(true, moRelaxed)
                    state.setStatus(&"Chess960 position #{n} loaded")
            except ValueError:
                state.setError(&"Invalid number: {parts[1]}")

    of "dfrc":
        if state.mode == ModePlay and state.playPhase != Setup:
            state.setError("Cannot change position during a game. Use :exit first.")
            return
        if parts.len < 2:
            state.setError("Usage: :dfrc <white> <black> or :dfrc <index>")
        else:
            try:
                var whiteNum, blackNum: int
                if parts.len >= 3:
                    whiteNum = parseInt(parts[1])
                    blackNum = parseInt(parts[2])
                    if whiteNum notin 0..959 or blackNum notin 0..959:
                        state.setError("Scharnagl numbers must be 0-959")
                        return
                else:
                    let n = parseInt(parts[1])
                    if n < 0 or n >= 960 * 960:
                        state.setError("DFRC index must be 0-921599")
                        return
                    whiteNum = n mod 960
                    blackNum = n div 960

                let fen = scharnaglToFEN(whiteNum, blackNum)
                state.board = newChessboardFromFEN(fen)
                state.clearMoveRecords()
                state.lastMove = none(tuple[fromSq, toSq: Square])
                state.selectedSquare = none(Square)
                state.legalDestinations = @[]
                state.startFEN = fen
                state.chess960 = true
                state.variant = DoubleFischerRandom
                state.searcher.state.chess960.store(true, moRelaxed)
                state.setStatus(&"DFRC position (W:{whiteNum}, B:{blackNum}) loaded")
            except ValueError:
                state.setError("Invalid number(s)")

    of "chess960":
        if parts.len < 2:
            state.setStatus(&"Chess960: {(if state.chess960: \"on\" else: \"off\")}")
        else:
            case parts[1].toLowerAscii()
            of "on", "true", "yes", "1":
                state.chess960 = true
                state.searcher.state.chess960.store(true, moRelaxed)
                state.setStatus("Chess960 enabled")
            of "off", "false", "no", "0":
                state.chess960 = false
                state.variant = Standard
                state.searcher.state.chess960.store(false, moRelaxed)
                state.setStatus("Chess960 disabled")
            else:
                state.setError("Usage: :chess960 on|off")

    else:
        state.setError(&"Unknown command: {parts[0]}")


proc processUCIMove*(state: AppState, moveStr: string) =
    ## Processes a UCI move string
    # Don't allow moves in replay mode or when engine is thinking
    if state.mode == ModeReplay:
        state.setError("Cannot make moves in replay mode")
        return
    if state.boardSetupMode:
        state.setError("Cannot enter moves in board setup mode")
        return
    if state.mode == ModePlay and state.playPhase == EngineTurn and not state.watchMode:
        let lower = moveStr.toLowerAscii()
        if lower.len notin 4..5:
            state.setError("Invalid premove syntax")
            return
        try:
            let fromSq = lower[0..1].toSquare(checked=true)
            let toSq = lower[2..3].toSquare(checked=true)
            let piece = state.board.on(fromSq)
            if piece.kind == Empty or piece.color != state.playerColor:
                state.setError("Premove must start from one of your pieces")
                return
            state.queuePremove(fromSq, toSq)
            state.selectedSquare = none(Square)
            state.legalDestinations = @[]
        except ValueError:
            state.setError("Invalid premove syntax")
        return
    if state.mode == ModePlay and state.playPhase in [EngineTurn, GameOver, Setup]:
        state.setError("Cannot make moves now")
        return

    let (move, error) = parseUCIMoveString(state.board, moveStr, state.chess960)
    if move == nullMove():
        state.setError(&"Invalid move: {error}")
        return

    # Validate legality
    let result = state.board.makeMove(move)
    if result == nullMove():
        state.setError(&"Illegal move: {moveStr}")
        return

    # Undo the makeMove so applyMove can redo it properly
    state.board.unmakeMove()

    # Record SAN before making the move
    let sanStr = state.board.toSAN(move)
    state.lastMove = some((fromSq: move.startSquare(), toSq: move.targetSquare()))

    let applied = state.board.makeMove(move)
    if applied == nullMove():
        state.setError(&"Illegal move: {moveStr}")
        return

    state.addMoveRecord(move, sanStr)
    state.pendingPremoves = @[]
    state.selectedSquare = none(Square)
    state.legalDestinations = @[]

    if state.mode == ModePlay and state.playPhase == PlayerTurn:
        onPlayerMove(state)
    elif state.analysisRunning:
        restartAnalysis(state)


proc processSANMove*(state: AppState, sanStr: string) =
    ## Processes a SAN move string
    if state.mode == ModeReplay:
        state.setError("Cannot make moves in replay mode")
        return
    if state.boardSetupMode:
        state.setError("Cannot enter moves in board setup mode")
        return
    if state.mode == ModePlay and state.playPhase in [EngineTurn, GameOver, Setup]:
        if state.playPhase == EngineTurn and not state.watchMode:
            state.setError("Use square selection, dragging, or UCI to queue a premove")
        else:
            state.setError("Cannot make moves now")
        return

    let (move, error) = state.board.parseSAN(sanStr)
    if move == nullMove():
        state.setError(&"Invalid SAN: {error}")
        return

    # Record SAN before making the move
    let san = state.board.toSAN(move)
    state.lastMove = some((fromSq: move.startSquare(), toSq: move.targetSquare()))

    let applied = state.board.makeMove(move)
    if applied == nullMove():
        state.setError(&"Illegal move: {sanStr}")
        return

    state.addMoveRecord(move, san)
    state.pendingPremoves = @[]
    state.selectedSquare = none(Square)
    state.legalDestinations = @[]

    if state.mode == ModePlay and state.playPhase == PlayerTurn:
        onPlayerMove(state)
    elif state.analysisRunning:
        restartAnalysis(state)


proc processInput*(state: AppState, input: string) =
    ## Processes a line of text input from the user
    let trimmed = input.strip()
    if trimmed.len == 0:
        return

    if state.boardSetupMode:
        state.setError("Use the mouse and piece keys while in board setup mode")
        return

    # During play setup, non-command input goes to the setup handler
    if state.mode == ModePlay and state.playPhase == Setup:
        if trimmed.startsWith(":"):
            processCommand(state, trimmed[1..^1])
        else:
            handlePlaySetup(state, trimmed)
        return

    # Check for square selection (2 chars like "e2") - select piece for keyboard move
    let lower = trimmed.toLowerAscii()
    if lower.len == 2 and lower[0] in 'a'..'h' and lower[1] in '1'..'8':
        try:
            let sq = lower.toSquare(checked=true)
            let piece = state.board.on(sq)
            let canQueuePremove = state.mode == ModePlay and state.playPhase == EngineTurn and not state.watchMode
            if state.selectedSquare.isSome():
                # Second square: try to make a move from selected to this square
                let fromSq = state.selectedSquare.get()
                if canQueuePremove:
                    state.queuePremove(fromSq, sq)
                    state.selectedSquare = none(Square)
                    state.legalDestinations = @[]
                    return
                var moves = newMoveList()
                state.board.generateMoves(moves)

                # Check if any legal move exists from->to
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
                        # Enter promotion selection mode
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
                            state.lastMove = some((fromSq: foundMove.startSquare(), toSq: foundMove.targetSquare()))
                            let applied = state.board.makeMove(foundMove)
                            if applied != nullMove():
                                state.addMoveRecord(foundMove, sanStr)
                                state.undoneHistory = @[]
                                state.pendingPremoves = @[]
                                stdout.write("\a")
                                stdout.flushFile()
                                if state.mode == ModePlay and state.playPhase == PlayerTurn:
                                    onPlayerMove(state)
                                elif state.analysisRunning:
                                    restartAnalysis(state)
                elif piece.kind != Empty and piece.color == state.board.sideToMove():
                    # Re-select different piece
                    state.selectedSquare = some(sq)
                    state.legalDestinations = @[]
                    for move in moves:
                        if move.startSquare() == sq:
                            state.legalDestinations.add(move.targetSquare())
                else:
                    state.setError(&"No legal move from {state.selectedSquare.get()} to {sq}")
                    state.selectedSquare = none(Square)
                    state.legalDestinations = @[]
            elif canQueuePremove and piece.kind != Empty and piece.color == state.playerColor:
                state.selectedSquare = some(sq)
                state.legalDestinations = @[]
                state.setStatus(&"Selected {piece.toChar()} on {lower}. Type premove destination square.")
            elif piece.kind != Empty and piece.color == state.board.sideToMove():
                # Select piece
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
                if canQueuePremove:
                    state.setError(&"No piece of yours to premove from on {lower}")
                else:
                    state.setError(&"No piece to select on {lower}")
            return
        except ValueError:
            discard  # fall through to normal input handling

    let kind = classifyInput(trimmed)

    case kind
    of Command:
        processCommand(state, trimmed[1..^1])
    of UCIMove:
        processUCIMove(state, trimmed)
    of SANMove:
        processSANMove(state, trimmed)
