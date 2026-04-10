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

## Key event dispatch for the TUI.

import std/options

import illwill
import heimdall/pieces
import heimdall/tui/[state, input, analysis, play, rawinput]
import heimdall/tui/input/engine_commands
import heimdall/tui/events/[board_setup, navigation, board_input]


proc maxHelpScroll: int =
    let panelHeight = terminalHeight() - 4
    max(0, helpLineCount() - helpViewportHeight(panelHeight))



proc handleHelpOverlayKey(state: AppState, key: Key): bool =
    if not state.input.helpVisible or key == Key.None:
        return false

    let maxScroll = maxHelpScroll()
    case key:
        of Key.Escape:
            state.input.helpVisible = false
            state.input.helpScroll = 0
            return true
        of Key.PageUp:
            state.input.helpScroll = max(0, state.input.helpScroll - helpViewportHeight(terminalHeight() - 4))
            return true
        of Key.PageDown:
            state.input.helpScroll = min(maxScroll, state.input.helpScroll + helpViewportHeight(terminalHeight() - 4))
            return true
        of Key.Home:
            state.input.helpScroll = 0
            return true
        of Key.End:
            state.input.helpScroll = maxScroll
            return true
        of Key.Up:
            if state.input.buffer.len == 0 and not state.input.acActive:
                state.input.helpScroll = max(0, state.input.helpScroll - 1)
                return true
        of Key.Down:
            if state.input.buffer.len == 0 and not state.input.acActive:
                state.input.helpScroll = min(maxScroll, state.input.helpScroll + 1)
                return true
        else:
            discard

    false


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
    if state.mode == ModePlay and state.play.phase == Setup and state.input.buffer.len == 0:
        let shortcutInput = state.setupShortcutInput(key)
        if shortcutInput.isSome():
            state.dismissStatus()
            handlePlaySetup(state, shortcutInput.get())
            return

    # Dismiss persistent status on any keypress (but not during setup - those prompts need input)
    if state.input.statusPersistent and key != Key.None:
        if not (state.mode == ModePlay and state.play.phase == Setup) and
           not state.boardSetup.active and
           state.analysis.prompt.isNone() and
           not state.input.helpVisible:
            state.dismissStatus()
            return

    if handleHelpOverlayKey(state, key):
        return

    # Any key other than Ctrl+D cancels the pending exit
    if state.ctrlDPending and key != Key.CtrlD:
        state.ctrlDPending = false
        state.setStatus("")

    if state.analysis.prompt.isSome():
        case key:
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

    case key:
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
            if state.boardSetup.active:
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
            elif state.mode == ModePlay and state.play.phase == Setup:
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
            elif state.mode == ModePlay and state.play.phase == Setup:
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
            if state.boardSetup.active and state.handleBoardSetupKey(key):
                return

            # Global shortcuts always require Shift.
            if state.mode == ModeAnalysis and not state.boardSetup.active and key == Key.ShiftS:
                enterBoardSetupMode(state)
                return
            if key == Key.ShiftF:
                state.flipped = not state.flipped
                return
            if state.mode == ModeAnalysis and not state.boardSetup.active and state.input.buffer.len == 0 and key == Key.ShiftM:
                state.beginMateFinderPrompt()
                return
            if key == Key.ShiftA:
                state.toggleEngineArrows()
                return
            if key == Key.ShiftQ:
                toggleAutoQueen(state)
                return

            # Printable ASCII characters
            let keyVal = key.int
            if keyVal >= 32 and keyVal <= 126:
                handleTextInput(state, key)
                updateAutocomplete(state)


proc handleMouseEvent*(state: AppState, mouse: MouseEvent, boardTermRow, boardTermCol: int) =
    board_input.handleMouseEvent(state, mouse, boardTermRow, boardTermCol)
