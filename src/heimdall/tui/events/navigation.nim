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

## Replay navigation and shared post-navigation refresh helpers.

import std/options

import heimdall/[board, movegen, moves]
import heimdall/tui/[state, analysis]
import heimdall/tui/util/san


proc resetNavigationState(state: AppState) =
    state.resetSquareSelection()


proc refreshAfterNavigation*(state: AppState) =
    state.resetNavigationState()
    if state.analysis.running:
        restartAnalysis(state)


proc replayToStart*(state: AppState): bool =
    result = false
    while undoLastRecordedMove(state):
        result = true


proc replayStepForward*(state: AppState): bool =
    if state.mode != ModeReplay or state.replay.moveIndex >= state.replay.moves.len:
        return false

    let move = state.replay.moves[state.replay.moveIndex]
    let sanStr = state.board.toSAN(move)
    state.lastMove = some((fromSq: move.startSquare(), toSq: move.targetSquare()))
    discard state.board.makeMove(move)
    state.resetArrowState()
    state.addMoveRecord(move, sanStr)
    inc state.replay.moveIndex
    state.undoneHistory = @[]
    true


proc replayToEnd*(state: AppState): bool =
    result = false
    if state.mode == ModeReplay:
        while replayStepForward(state):
            result = true
    else:
        while redoUndoneMove(state):
            result = true
