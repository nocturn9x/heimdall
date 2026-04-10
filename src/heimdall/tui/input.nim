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

## Text input parsing and top-level command dispatch.

import std/[strutils, strformat, options]

import heimdall/tui/[state, analysis, play]
import heimdall/tui/input/[game_commands, engine_commands, move_entry]


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
    ("Shift+M", "Set mate-finder limit"),
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
    result.add("Right-click: toggle square highlight")
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

    result.add("")
    result.add("Play/watch setup:")
    result.add("Engine limits can be combined with commas")
    result.add("Examples: 5m+3s, depth 20 | depth 20, nodes 200000")
    result.add("softnodes prompts for an optional hard cap")


proc helpLineCount*(): int =
    buildHelpLines().len


proc updateAutocomplete*(state: AppState) =
    ## Updates autocomplete suggestions based on current input
    if not state.input.buffer.startsWith(":") or state.input.buffer.len < 2:
        state.input.acActive = false
        state.input.acSuggestions = @[]
        state.input.acSelected = none(int)
        return

    let content = state.input.buffer[1..^1]
    let parts = content.splitWhitespace()

    if parts.len == 0:
        state.input.acActive = false
        state.input.acSelected = none(int)
        return

    state.input.acSuggestions = @[]

    if parts.len == 1 and not content.endsWith(" "):
        # Autocomplete command name
        let prefix = parts[0].toLowerAscii()
        for (cmd, desc) in COMMANDS:
            if cmd.startsWith(prefix) and cmd != prefix:
                state.input.acSuggestions.add((cmd, desc))
    elif parts[0].toLowerAscii() == "set":
        # Autocomplete :set subcommands
        let subPrefix = if parts.len >= 2 and not content.endsWith(" "): parts[1].toLowerAscii()
                        elif content.endsWith(" "): ""
                        else: ""
        if parts.len <= 2 and (parts.len < 2 or not content.endsWith(" ") or subPrefix.len == 0):
            for (opt, desc) in SET_OPTIONS:
                if subPrefix.len == 0 or (opt.startsWith(subPrefix) and opt != subPrefix):
                    state.input.acSuggestions.add(("set " & opt, desc))

    state.input.acActive = state.input.acSuggestions.len > 0
    if not state.input.acActive:
        state.input.acSelected = none(int)
    elif state.input.acSelected.isNone():
        state.input.acSelected = some(0)
    elif state.input.acSelected.get() >= state.input.acSuggestions.len:
        state.input.acSelected = some(state.input.acSuggestions.len - 1)


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


proc processCommand*(state: AppState, cmd: string) =
    ## Processes a colon-prefixed command
    let parts = cmd.strip().splitWhitespace()
    if parts.len == 0:
        return

    # Dismiss autocomplete on command execution
    state.input.acActive = false
    state.input.acSelected = none(int)

    if state.handleGameCommand(parts):
        return
    if state.handleEngineCommand(parts):
        return

    case parts[0].toLowerAscii():
        of "help", "h", "?":
            state.input.helpVisible = not state.input.helpVisible
            state.input.helpScroll = 0

        of "quit", "q":
            state.shouldQuit = true

        of "flip":
            state.flipped = not state.flipped

        of "unmove":
            if state.moveHistory.len == 0:
                state.setError("No moves to undo")
            elif state.undoLastRecordedMove():
                state.resetSquareSelection()
                state.setStatus("Move undone")

        else:
            state.setError(&"Unknown command: {parts[0]}")


proc handleAnalysisPrompt(state: AppState, input: string): bool =
    if state.analysis.prompt.isNone():
        return false

    case state.analysis.prompt.get():
        of AnalysisPromptMateLimit:
            let stripped = input.strip().toLowerAscii()
            if stripped in ["none", "off", "0"]:
                state.analysis.mateLimit = none(int)
                state.clearAnalysisPrompt()
                state.dismissStatus()
                if state.analysis.running:
                    restartAnalysis(state)
                state.setStatus("Mate finder disabled")
                return true

            try:
                let depth = parseInt(stripped)
                if depth < 1 or depth > 255:
                    state.setStatus("Mate finder depth must be between 1 and 255. Type none to clear.", isError=true, persistent=true)
                    return true
                state.analysis.mateLimit = some(depth)
                state.clearAnalysisPrompt()
                state.dismissStatus()
                if state.analysis.running:
                    restartAnalysis(state)
                state.setStatus(&"Mate finder limit set to mate {depth}")
                return true
            except ValueError:
                state.setStatus("Invalid mate finder depth. Enter 1-255 or none to clear.", isError=true, persistent=true)
                return true


proc processInput*(state: AppState, input: string) =
    ## Processes a line of text input from the user
    let trimmed = input.strip()
    if trimmed.len == 0:
        return

    if state.mode == ModeAnalysis and state.analysis.prompt.isSome():
        if trimmed.startsWith(":"):
            state.clearAnalysisPrompt()
            state.dismissStatus()
            processCommand(state, trimmed[1..^1])
        else:
            discard handleAnalysisPrompt(state, trimmed)
        return

    if state.boardSetup.active:
        state.setError("Use the mouse and piece keys while in board setup mode")
        return

    # During play setup, non-command input goes to the setup handler
    if state.mode == ModePlay and state.play.phase == Setup:
        if trimmed.startsWith(":"):
            processCommand(state, trimmed[1..^1])
        else:
            handlePlaySetup(state, trimmed)
        return

    if state.handleSquareSelectionInput(trimmed):
        return

    let kind = classifyInput(trimmed)

    case kind:
        of Command:
            processCommand(state, trimmed[1..^1])
        of UCIMove:
            processUCIMove(state, trimmed)
        of SANMove:
            processSANMove(state, trimmed)
