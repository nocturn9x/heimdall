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

## Buffer-level watch panel and eval label regressions; no terminal required.
## Build through make dev with MAIN=tests/test_tui_render.nim IS_TEST=1,
## EXE_BASE=bin/test-tui-render and an absolute EVALFILE.

import std/unicode
import heimdall/util/move_parse
include heimdall/tui/graphics/renderer


proc rowText(tb: TerminalBuffer, y: int): string =
    for x in 0..<tb.width:
        result.add($tb[x, y].ch)


proc rowContaining(tb: TerminalBuffer, text: string): int =
    for y in 0..<tb.height:
        if text in tb.rowText(y):
            return y
    -1


proc panel(state: AppState, width: int): TerminalBuffer =
    result = newTerminalBuffer(width + 2, 100)
    result.clear()
    result.drawInfoPanel(state, 1, 1, width, 98)


let app = newAppState()
try:
    let parsed = parseUCIMove(app.board.position, "e2e4")
    doAssert not parsed.error.hasError()
    let line = AnalysisLine(pv: @[parsed.move], score: Score(128), rawScore: Score(128), depth: 10)

    for width in [24, 40, 80]:
        app.preparePlaySetup(watchMode=true)
        app.play.phase = EngineTurn
        app.play.engineThinking = true
        app.play.liveBoard = app.board
        app.clearAnalysisDisplay()
        let waiting = app.panel(width)
        let clockRow = waiting.rowContaining("Clocks:")
        doAssert clockRow >= 0
        doAssert waiting.rowContaining("Waiting for engine") >= 0

        app.analysis.lines = @[line]
        app.analysis.linesPositionKey = app.board.zobristKey().uint64
        app.analysis.depth = 10
        app.analysis.nodes = 1_000_000
        app.analysis.nps = 99_000_000
        app.storeCurrentAnalysisSnapshot()
        doAssert app.panel(width).rowContaining("Clocks:") == clockRow,
            "search info moved the clocks at panel width " & $width

        app.clearAnalysisDisplay()
        doAssert app.panel(width).rowContaining("Clocks:") == clockRow,
            "clearing info between turns collapsed the watch panel"
        doAssert app.currentEvalScore() == some(Score(128))

        # Once MultiPV needs more rows, keep them through the next turn and
        # when the other engine sends fewer lines.
        app.analysis.lines = @[line, line]
        app.analysis.linesPositionKey = app.board.zobristKey().uint64
        app.storeCurrentAnalysisSnapshot()
        let multiPVClockRow = app.panel(width).rowContaining("Clocks:")
        doAssert multiPVClockRow == clockRow + 1
        app.clearAnalysisDisplay()
        doAssert app.panel(width).rowContaining("Clocks:") == multiPVClockRow
        app.analysis.lines = @[line]
        app.analysis.linesPositionKey = app.board.zobristKey().uint64
        app.storeCurrentAnalysisSnapshot()
        doAssert app.panel(width).rowContaining("Clocks:") == multiPVClockRow

    block evalLabel:
        app.clearAnalysisDisplay()
        for flipped in [false, true]:
            app.flipped = flipped
            var tb = newTerminalBuffer(40, 30)
            tb.clear()
            tb.drawEvalBarLabel(app, 7, 1, 20)
            doAssert "+1.28" in tb.rowText(21), "watch eval label is missing"

        # The retained score is white-relative, even after Black starts thinking.
        app.board = newChessboardFromFEN(DEFAULT_START_FEN.replace(" w ", " b "))
        app.play.liveBoard = app.board
        doAssert app.currentEvalScore() == some(Score(128))

        # History browsing must not borrow the live game's last score.
        app.moveHistory = @[parsed.move]
        app.play.viewPly = 0
        doAssert app.currentEvalScore().isNone()
        app.moveHistory = @[]

    block labelSpace:
        app.mode = ModeAnalysis
        let analysisMinimum = app.minimumTerminalSize()
        app.mode = ModePlay
        doAssert app.minimumTerminalSize() == analysisMinimum
        app.play.watchMode = false
        doAssert app.minimumTerminalSize().h == analysisMinimum.h - 1
        var tb = newTerminalBuffer(40, 30)
        tb.clear()
        tb.drawEvalBarLabel(app, 7, 1, 20)
        doAssert tb.rowContaining("+1.28") == -1

    app.preparePlaySetup(watchMode=true)
    doAssert app.play.watchScore.isNone()
    doAssert app.play.watchPVRows == 1
finally:
    app.cleanup()

echo "TUI watch rendering tests passed"
