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

## External watch-engine protocol and lifecycle regressions.
## Build with make dev MAIN=tests/test_tui_uci.nim IS_TEST=1,
## EXE_BASE=bin/test-tui-uci and an absolute EVALFILE.

import std/[os, strutils, options, monotimes, times, syncio]

import heimdall/[board, moves, movegen, eval]
import heimdall/util/move_parse
import heimdall/tui/[state, input, analysis, play]
import heimdall/tui/util/[notation, uci_client]


proc mockEngine(mode: string) =
    # Run this executable as a deterministic, independent UCI peer. The optional
    # transcript verifies the actual commands written to the subprocess pipe.
    var board = newDefaultChessboard()
    var chess960 = false
    var pending = ""
    var transcript: syncio.File
    let logging = paramCount() >= 3
    if logging:
        doAssert open(transcript, paramStr(3), fmWrite)
    var line: string
    while stdin.readLine(line):
        if logging:
            transcript.writeLine(line)
            transcript.flushFile()
        let tokens = line.splitWhitespace()
        if tokens.len == 0:
            continue
        case tokens[0]:
            of "uci":
                if mode == "exit-handshake":
                    quit(0)
                echo "id name Test UCI Engine"
                echo "option name Ponder type check default false"
                if mode != "no960":
                    echo "option name UCI_Chess960 type check default false"
                echo "uciok"
            of "isready":
                echo "readyok"
            of "setoption":
                if "name UCI_Chess960 value true" in line:
                    chess960 = true
                elif "name UCI_Chess960 value false" in line:
                    chess960 = false
            of "position":
                let moveIdx = tokens.find("moves")
                let fenEnd = if moveIdx < 0: tokens.len else: moveIdx
                doAssert tokens[1] == "fen"
                board = newChessboardFromFEN(tokens[2..<fenEnd].join(" "))
                if moveIdx >= 0:
                    for text in tokens[moveIdx + 1..^1]:
                        let parsed = parseUCIMove(board.position, text, chess960=chess960)
                        doAssert not parsed.error.hasError(), text
                        doAssert board.makeMove(parsed.move) != nullMove(), text
            of "go":
                if mode == "exit-search":
                    quit(0)
                var legal = newMoveList()
                board.generateMoves(legal)
                doAssert legal.len > 0
                var best = legal[0]
                for move in legal:
                    if move.isCastling():
                        best = move
                        break
                let preview = newChessboard(@[board.position])
                discard preview.makeMove(best)
                var replies = newMoveList()
                preview.generateMoves(replies)
                let reply = if replies.len > 0: replies[0].toTUIUCI(chess960) else: ""
                let coordinates = best.toTUIUCI(chess960)
                echo "info depth 3 score cp 42 nodes 123 nps 456 pv " & coordinates & " " & reply
                pending = "bestmove " & coordinates
                if reply.len > 0:
                    pending &= " ponder " & reply
                if "ponder" notin tokens:
                    echo pending
                    pending = ""
            of "stop", "ponderhit":
                if pending.len > 0:
                    echo pending
                    pending = ""
            of "quit":
                quit(0)
            else:
                discard
        stdout.flushFile()


if paramCount() >= 2 and paramStr(1) == "--mock-uci":
    mockEngine(paramStr(2))
    quit(0)


proc mockCommand(mode = "normal", transcript = ""): string =
    result = quoteShell(getAppFilename()) & " --mock-uci " & mode
    if transcript.len > 0:
        result &= " " & quoteShell(transcript)


block clientProtocol:
    let transcript = getTempDir() / ("heimdall-uci-" & $getCurrentProcessId() & ".log")
    let started = startUCIClient(mockCommand(transcript=transcript))
    doAssert started.error.len == 0, started.error
    let client = started.client
    doAssert client.name == "Test UCI Engine"
    doAssert client.supportsPonder and client.supportsChess960
    client.setOption("Option With Spaces", "a value with spaces")
    client.newGame()
    var infos: Channel[UCIEngineInfo]
    infos.open()
    for chess960 in [false, true]:
        let fen = if chess960: "4k3/8/8/8/8/8/8/R1K2R2 w FA - 0 1"
                  else: "4k3/8/8/8/8/8/8/R3K2R w KQ - 0 1"
        let board = newChessboardFromFEN(fen)
        let reply = client.searchBestMove(@[board.position], UCIEngineLimit(
            hasTime: true, whiteTimeMs: 10000, blackTimeMs: 20000,
            whiteIncrementMs: 100, blackIncrementMs: 200,
            depth: some(3), nodes: some(1000'u64)
        ), chess960, startFEN=fen, infoChannel=addr infos)
        doAssert reply.error.len == 0, reply.error
        doAssert reply.bestMove.isCastling()
        doAssert board.isLegal(reply.bestMove)
        doAssert reply.nodes == 123
        let info = infos.recv()
        doAssert info.positionKey == board.zobristKey().uint64
        doAssert info.hasScore and info.score == Score(42)
        doAssert info.pv[0] == reply.bestMove
        doAssert info.pv.len == 2 and info.pv[1] == reply.ponderMove
        doAssert info.depth == 3 and info.nps == 456
    client.close()
    infos.close()
    let commands = readFile(transcript)
    doAssert "setoption name Option With Spaces value a value with spaces\n" in commands
    doAssert "go wtime 10000 btime 20000 winc 100 binc 200 depth 3 nodes 1000\n" in commands
    removeFile(transcript)


block processFailures:
    let missing = startUCIClient("/nonexistent/heimdall-test-uci")
    doAssert missing.client == nil and missing.error.len > 0
    let handshake = startUCIClient(mockCommand("exit-handshake"))
    doAssert handshake.client == nil and handshake.error.len > 0
    let started = startUCIClient(mockCommand("exit-search"))
    doAssert started.error.len == 0, started.error
    let reply = started.client.searchBestMove(@[newDefaultChessboard().position],
        UCIEngineLimit(depth: some(1)), false)
    doAssert reply.error.len > 0
    started.client.close()


proc pumpUntil(app: AppState, plies: int) =
    let deadline = getMonoTime() + initDuration(seconds=10)
    while app.moveHistory.len < plies:
        doAssert getMonoTime() < deadline, "watch search timed out"
        let thinking = app.play.engineThinking
        app.pollSearchResults()
        app.pollWatchSearchResults()
        if thinking and not app.play.engineThinking and app.play.phase == EngineTurn:
            let externalTurn =
                if app.board.sideToMove() == White: app.play.watchWhiteExternal.initialized
                else: app.play.watchBlackExternal.initialized
            if not externalTurn:
                # Keep the root on display while polling the completed internal
                # search again: shallow searches can finish between the polls.
                app.play.engineThinking = true
                app.pollSearchResults()
                app.play.engineThinking = false
                doAssert app.analysis.linesPositionKey == app.board.zobristKey().uint64,
                    "missing watch analysis for " & $app.board.sideToMove()
                doAssert app.analysis.depth > 0 and app.analysis.nodes > 0
                doAssert app.analysis.lines.len > 0 and app.analysis.lines[0].pv.len > 0
                doAssert app.board.isLegal(app.analysis.lines[0].pv[0]),
                    "watch PV belongs to a different position/engine"
            app.onEngineMoveComplete()
        doAssert app.play.phase != GameOver, app.input.statusMessage
        sleep(1)


proc setupWatch(app: AppState, command: string, ponder = false) =
    app.processCommand(command)
    doAssert app.play.phase == Setup and app.play.watchMode
    for answer in ["s", "n", "depth 2", "1", "1", if ponder: "y" else: "n"]:
        app.handlePlaySetup(answer)


let app = newAppState()
app.startSearchWorker()
try:
    block externalGames:
        let command = "watch --white " & quoteShell(mockCommand()) &
                      " --black " & quoteShell(mockCommand()) &
                      " --option 'Test Option=some value'"
        app.setupWatch(command, ponder=true)
        doAssert app.play.watchWhiteExternal.options[0].name == "Test Option"
        doAssert app.play.watchBlackExternal.options[0].value == "some value"
        app.pumpUntil(8)
        doAssert app.play.watchWhiteExternal.initialized
        doAssert app.play.watchBlackExternal.initialized
        doAssert not app.play.watch.initialized
        app.processCommand("ucioption both 'Another Option' another value")
        doAssert not app.input.statusIsError, app.input.statusMessage
        let pgnPath = getTempDir() / ("heimdall-watch-" & $getCurrentProcessId() & ".pgn")
        app.processCommand("pgn " & pgnPath)
        let pgn = readFile(pgnPath)
        doAssert "[White \"Test UCI Engine\"]" in pgn
        doAssert "[Black \"Test UCI Engine\"]" in pgn
        doAssert "[%nodes 123]" in pgn
        removeFile(pgnPath)
        # Starting another game must release the old subprocesses and workers.
        app.setupWatch(command)
        app.pumpUntil(4)
        app.exitPlayMode()
        doAssert not app.play.watchWhiteExternal.initialized
        doAssert not app.play.watchBlackExternal.initialized

    block mixedGames:
        for side in ["white", "black"]:
            app.setupWatch("watch --" & side & " " & quoteShell(mockCommand()))
            app.pumpUntil(4)
            app.exitPlayMode()
        app.setupWatch("watch")
        app.pumpUntil(4)
        app.exitPlayMode()

    block failedInitialization:
        app.setupWatch("watch --white " & quoteShell(mockCommand()) &
                       " --black /nonexistent/heimdall-test-uci")
        doAssert app.play.phase == Setup
        doAssert app.input.statusIsError, app.input.statusMessage
        doAssert not app.play.watchWhiteExternal.initialized
        doAssert not app.play.watchBlackExternal.initialized
        app.exitPlayMode()

    block unsupportedChess960:
        app.processCommand("watch --white " & quoteShell(mockCommand("no960")))
        for answer in ["f", "n", "depth 2", "1", "1", "n"]:
            app.handlePlaySetup(answer)
        doAssert app.play.phase == Setup and app.input.statusIsError
        doAssert "UCI_Chess960" in app.input.statusMessage
        doAssert not app.play.watchWhiteExternal.initialized
        app.exitPlayMode()

    block realEngine:
        let engine = getEnv("TUI_UCI_ENGINE")
        if engine.len > 0:
            app.setupWatch("watch --white " & quoteShell(engine) & " --black " & quoteShell(engine), ponder=true)
            app.pumpUntil(8)
            app.exitPlayMode()
            for side in ["white", "black"]:
                app.setupWatch("watch --" & side & " " & quoteShell(engine))
                app.pumpUntil(4)
                app.exitPlayMode()
finally:
    if app.mode == ModePlay:
        app.exitPlayMode()
    app.shutdownSearchWorker()
    app.cleanup()

echo "External TUI UCI tests passed"
