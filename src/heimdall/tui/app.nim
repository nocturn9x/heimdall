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
import heimdall/tui/[state, events, analysis, play, rawinput]
import heimdall/tui/graphics/[renderer, board_view]
import heimdall/tui/util/kitty


proc resetTerminal(illwillInitialized: var bool) =
    ## Restores the terminal to a usable state
    disableMouseTracking()
    deleteImage(1)
    deleteImage(2)
    deleteImage(3)
    deleteImage(4)
    if illwillInitialized:
        illwillDeinit()
        illwillInitialized = false
    showCursor()


proc initializeTerminal(state: AppState, illwillInitialized: var bool) =
    illwillInit(fullScreen=true, mouse=false)
    illwillInitialized = true
    hideCursor()
    disableISIG()
    enableMouseTracking()

    let compatibilityWarning = terminalCompatibilityWarning()
    if compatibilityWarning.len > 0:
        state.setStatus(compatibilityWarning)


proc drainInputEvents(state: AppState, boardTermRow, boardTermCol: int) =
    for inputRound in 0..255:
        let event = pollInput()
        case event.kind:
            of ievKey:
                handleInput(state, event.key)
            of ievMouse:
                handleMouseEvent(state, event.mouse, boardTermRow, boardTermCol)
            of ievNone:
                break


proc pollFrame(state: AppState, wasEngineThinking: var bool) =
    pollSearchResults(state)
    pollWatchSearchResults(state)

    if wasEngineThinking and not state.play.engineThinking and state.mode == ModePlay and state.play.phase == EngineTurn:
        onEngineMoveComplete(state)
    wasEngineThinking = state.play.engineThinking

    tickClocks(state)
    render(state)


proc shutdownTui(state: AppState, illwillInitialized: var bool) =
    if state.searcher.isSearching():
        state.searcher.cancel()
    shutdownWatchEngine(state)
    shutdownSearchWorker(state)
    resetTerminal(illwillInitialized)
    state.cleanup()


proc startTUI* =
    ## Main entry point for the TUI mode
    let state = newAppState()
    var illwillInitialized = false

    proc cleanupTerminal() =
        resetTerminal(illwillInitialized)

    addExitProc(proc () = cleanupTerminal())

    initializeTerminal(state, illwillInitialized)
    startSearchWorker(state)
    let boardTermRow = BOARD_MARGIN_Y + 1
    let boardTermCol = boardStartX() + 1
    var wasEngineThinking = false

    try:
        while not state.shouldQuit:
            drainInputEvents(state, boardTermRow, boardTermCol)
            pollFrame(state, wasEngineThinking)
            sleep(16)
    except CatchableError:
        let e = getCurrentException()
        cleanupTerminal()
        stderr.writeLine("TUI error: " & e.msg)
        stderr.writeLine(e.getStackTrace())
    finally:
        shutdownTui(state, illwillInitialized)
