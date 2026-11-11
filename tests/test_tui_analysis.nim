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

## Analysis lifecycle regressions; no terminal required.
## Build through make dev MAIN=tests/test_tui_analysis.nim IS_TEST=1,
## EXE_BASE=bin/test-tui-analysis and an absolute EVALFILE.

import std/[os, strutils, monotimes, times]
import heimdall/search
import heimdall/util/limits
import heimdall/tui/[state, input, analysis]
include heimdall/tui/graphics/renderer


const positions = [
    "1r3k2/2r4p/2Pq2pP/3P1p2/2B1p3/p3Q1P1/Rb3PK1/3R4 w - - 0 1",
    "3rr3/1p4k1/p1q2pp1/P1Nnp3/1P5p/1Q5P/5PPK/2RR4 w - - 0 28"
]


proc command(app: AppState, text: string) =
    echo text
    app.processCommand(text)
    doAssert not app.input.statusIsError, app.input.statusMessage


proc drawPanel(app: AppState) =
    var buffer = newTerminalBuffer(120, 60)
    buffer.drawInfoPanel(app, 1, 1, 118, 58)


block reducedMultiPVBeforeWorkerStarts:
    let app = newAppState()
    try:
        app.command("fen " & positions[0])
        app.command("set multipv 5")
        app.searcher.setBoard(app.board.positions)
        app.searcher.limiter.addLimit(newDepthLimit(1))
        let variations = app.searcher.search(silent=true, variations=5)
        var oldLines: seq[AnalysisLine]
        for variation in variations:
            var pv: seq[Move]
            for move in variation.moves:
                if move == nullMove():
                    break
                pv.add(move)
            oldLines.add(AnalysisLine(pv: pv, score: variation.score, depth: 1))
        doAssert oldLines.len == 5
        app.command("set multipv 1")
        app.pvChannel.send(oldLines)
        # Keep the worker paused before it receives the new command, so the
        # previous search's five published variations are still visible.
        app.startAnalysis()
        doAssert app.pvChannel.peek() == 0, "queued PV from the old search survived restart"
        app.pollSearchResults()
        app.drawPanel()
        doAssert app.analysis.lines.len == 1
        # A final PV can arrive after the first poll if the previous worker
        # was still finishing its response. It must obey the new display limit.
        app.pvChannel.send(oldLines)
        app.pollSearchResults()
        app.drawPanel()
        doAssert app.analysis.lines.len == 1
    finally:
        app.cleanup()


let app = newAppState()
app.startSearchWorker()
try:
    app.command("set threads 8")
    app.command("set hash " & getEnv("TUI_ANALYSIS_HASH", "16"))
    for fen in positions:
        app.command("fen " & fen)
        app.drawPanel()
        for multiPV in [5, 1]:
            app.command("set multipv " & $multiPV)
            app.command("go")
            let deadline = getMonoTime() + initDuration(seconds=parseInt(getEnv("TUI_ANALYSIS_SECONDS", "1")))
            while getMonoTime() < deadline:
                app.pollSearchResults()
                app.drawPanel()
                doAssert app.analysis.lines.len <= multiPV
                doAssert app.board.toFEN() == fen, "rendering changed the position"
                sleep(1)
            app.command("stop")
        app.command("clear")
finally:
    app.shutdownSearchWorker()
    app.searcher.shutdownWorkers()
    app.cleanup()

echo "TUI analysis lifecycle tests passed"
