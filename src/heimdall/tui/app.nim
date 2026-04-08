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

## TUI application entry point and main event loop

import std/[os, exitprocs]

import illwill
import heimdall/search
import heimdall/tui/[state, renderer, events, analysis, play, kitty, rawinput]


const
    BOARD_MARGIN_X = 1
    BOARD_MARGIN_Y = 1


var
    gState: AppState
    gIllwillInitialized: bool = false


proc resetTerminal() =
    ## Restores the terminal to a usable state
    disableMouseTracking()
    deleteImage(1)
    deleteImage(2)
    if gIllwillInitialized:
        illwillDeinit()
        gIllwillInitialized = false
    showCursor()


proc exitProc() {.noconv.} =
    resetTerminal()
    if gState != nil:
        if gState.searcher.isSearching():
            gState.searcher.cancel()
        gState.cleanup()
    quit(0)


proc startTUI* =
    ## Main entry point for the TUI mode
    gState = newAppState()
    let state = gState

    addExitProc(proc () = resetTerminal())

    # mouse=false: we handle mouse ourselves via rawinput
    illwillInit(fullScreen=true, mouse=false)
    gIllwillInitialized = true
    hideCursor()

    # Disable ISIG so Ctrl+C comes through as byte 0x03 to our input
    # reader instead of generating SIGINT (which doesn't quit cleanly
    # in threaded Nim programs)
    disableISIG()

    # Enable SGR mouse tracking (our rawinput module parses these)
    enableMouseTracking()

    # Start the background search worker
    startSearchWorker(state)

    # Board image position on terminal (1-based for ANSI)
    let boardTermRow = BOARD_MARGIN_Y + 1
    let boardTermCol = BOARD_MARGIN_X + 1

    var wasEngineThinking = false

    try:
        while not state.shouldQuit:
            # Drain all available input events (handles paste, rapid typing)
            for inputRound in 0..255:
                let event = pollInput()
                case event.kind
                of ievKey:
                    handleInput(state, event.key)
                of ievMouse:
                    handleMouseEvent(state, event.mouse, boardTermRow, boardTermCol)
                of ievNone:
                    break

            # Poll search results for live updates
            pollSearchResults(state)

            # Detect engine move completion in play mode
            if wasEngineThinking and not state.engineThinking:
                if state.mode == ModePlay and state.playPhase == EngineTurn:
                    onEngineMoveComplete(state)
            wasEngineThinking = state.engineThinking

            # Tick clocks in play mode
            tickClocks(state)

            # Render the frame
            render(state)

            # ~60 FPS
            sleep(16)
    except CatchableError:
        let e = getCurrentException()
        resetTerminal()
        stderr.writeLine("TUI error: " & e.msg)
        stderr.writeLine(e.getStackTrace())
    finally:
        if state.searcher.isSearching():
            state.searcher.cancel()
        shutdownSearchWorker(state)
        resetTerminal()
        state.cleanup()
