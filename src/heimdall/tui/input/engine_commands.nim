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

## Engine, search, and position-management commands extracted from input.nim.

import std/[atomics, base64, options, parseutils, strformat, strutils]

import heimdall/[board, search, transpositions]
import heimdall/util/scharnagl
import heimdall/tui/[state, analysis]


proc canChangePosition(state: AppState): bool =
    if state.mode == ModePlay and state.play.phase != Setup:
        state.setError("Cannot change position during a game. Use :exit first.")
        return false
    true


proc setChess960Enabled(state: AppState, enabled: bool) =
    state.chess960 = enabled
    state.searcher.state.chess960.store(enabled, moRelaxed)
    if not enabled:
        state.play.variant = Standard


proc resetBoard(state: AppState) =
    if not state.canChangePosition():
        return
    state.board = newDefaultChessboard()
    state.resetMoveSession()
    state.setChess960Enabled(false)
    state.startFEN = DEFAULT_START_FEN
    state.setStatus("Board reset to starting position")


proc copyOrLoadFen(state: AppState, parts: seq[string]) =
    if parts.len < 2:
        let fen = state.board.toFEN()
        let encoded = base64.encode(fen)
        stdout.write("\x1b]52;c;" & encoded & "\x1b\\")
        stdout.flushFile()
        state.setStatus("FEN copied: " & fen)
        return

    if not state.canChangePosition():
        return

    let fenStr = parts[1..^1].join(" ")
    try:
        state.board = newChessboardFromFEN(fenStr)
        state.resetMoveSession()
        state.startFEN = fenStr
        state.setStatus("Position loaded from FEN")
    except CatchableError as e:
        state.setError(&"Invalid FEN: {e.msg}")


proc handleSetCommand(state: AppState, parts: seq[string]) =
    if state.analysis.running or state.play.engineThinking:
        state.setError("Cannot change settings while searching. Use :stop first, then :set.")
        return
    if parts.len < 3:
        state.setError("Usage: :set <option> <value>")
        return

    case parts[1].toLowerAscii():
        of "multipv":
            try:
                let n = parseInt(parts[2])
                if n < 1 or n > 500:
                    state.setError("MultiPV must be between 1 and 500")
                else:
                    state.analysis.multiPV = n
                    state.analysis.lines = @[]
                    if state.analysis.running:
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
                    state.searcher.setWorkerCount(n - 1)
                    state.setStatus(&"Threads set to {n}")
            except ValueError:
                state.setError(&"Invalid number: {parts[2]}")
        of "hash":
            let raw = parts[2..^1].join(" ").strip()
            var sizeMiB: int64
            try:
                sizeMiB = parseBiggestInt(raw)
            except ValueError:
                var sizeBytes: int64
                let consumed = parseSize(raw, sizeBytes)
                if consumed == 0:
                    state.setError("Invalid size. Examples: 64, 256 MiB, 1 GB, 2 GiB")
                    return
                sizeMiB = sizeBytes div (1024 * 1024)

            if sizeMiB < 1 or sizeMiB > 33554432:
                state.setError("Hash must be between 1 MiB and 32 TiB")
            else:
                if state.ttable.resize(sizeMiB.uint64 * 1024 * 1024):
                    state.engineHash = sizeMiB.uint64
                    state.setStatus(&"Hash resized to {sizeMiB} MiB")
                else:
                    state.setError(&"Failed to resize hash to {sizeMiB} MiB")
        of "depth":
            try:
                let n = parseInt(parts[2])
                if n < 1 or n > 255:
                    state.setError("Depth must be between 1 and 255")
                else:
                    state.analysis.depthLimit = some(n)
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
            let value = parts[2].toLowerAscii()
            if value in ["true", "on", "yes", "1"]:
                state.setStatus("Ponder enabled")
            elif value in ["false", "off", "no", "0"]:
                state.setStatus("Ponder disabled")
            else:
                state.setError("Expected true/false")
        of "normalizescore":
            let value = parts[2].toLowerAscii()
            if value in ["true", "on", "yes", "1"]:
                state.searcher.state.normalizeScore.store(true, moRelaxed)
                state.setStatus("Score normalization enabled")
            elif value in ["false", "off", "no", "0"]:
                state.searcher.state.normalizeScore.store(false, moRelaxed)
                state.setStatus("Score normalization disabled")
            else:
                state.setError("Expected true/false")
        of "chess960", "uci_chess960":
            let value = parts[2].toLowerAscii()
            if value in ["true", "on", "yes", "1"]:
                state.setChess960Enabled(true)
                state.setStatus("Chess960 enabled")
            elif value in ["false", "off", "no", "0"]:
                state.setChess960Enabled(false)
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


proc toggleEngineArrows*(state: AppState) =
    state.showEngineArrows = not state.showEngineArrows
    state.setStatus("Engine arrows: " & (if state.showEngineArrows: "ON" else: "OFF"))


proc loadChess960Position(state: AppState, index: int) =
    let fen = scharnaglToFEN(index)
    state.board = newChessboardFromFEN(fen)
    state.resetMoveSession()
    state.startFEN = fen
    state.setChess960Enabled(true)
    state.play.variant = FischerRandom
    state.setStatus(&"Chess960 position #{index} loaded")


proc loadDoubleChess960Position(state: AppState, whiteNum, blackNum: int) =
    let fen = scharnaglToFEN(whiteNum, blackNum)
    state.board = newChessboardFromFEN(fen)
    state.resetMoveSession()
    state.startFEN = fen
    state.setChess960Enabled(true)
    state.play.variant = DoubleFischerRandom
    state.setStatus(&"DFRC position (W:{whiteNum}, B:{blackNum}) loaded")


proc handleEngineCommand*(state: AppState, parts: seq[string]): bool =
    if parts.len == 0:
        return false

    case parts[0].toLowerAscii():
        of "reset":
            state.resetBoard()
            true
        of "fen":
            state.copyOrLoadFen(parts)
            true
        of "set":
            state.handleSetCommand(parts)
            true
        of "go", "analyze", "analysis":
            if state.mode == ModePlay:
                state.setError("Exit play mode first (:exit)")
            else:
                toggleAnalysis(state)
            true
        of "arrows":
            state.toggleEngineArrows()
            true
        of "threats":
            state.showThreats = not state.showThreats
            state.setStatus("Threats: " & (if state.showThreats: "ON" else: "OFF"))
            true
        of "stop":
            if state.analysis.running:
                stopAnalysis(state)
                state.setStatus("Search stopped")
            else:
                state.setError("No search running")
            true
        of "frc":
            if not state.canChangePosition():
                return true
            if parts.len < 2:
                state.setError("Usage: :frc <number> (0-959)")
                return true
            try:
                let n = parseInt(parts[1])
                if n notin 0..959:
                    state.setError("Scharnagl number must be 0-959")
                else:
                    state.loadChess960Position(n)
            except ValueError:
                state.setError(&"Invalid number: {parts[1]}")
            true
        of "dfrc":
            if not state.canChangePosition():
                return true
            if parts.len < 2:
                state.setError("Usage: :dfrc <white> <black> or :dfrc <index>")
                return true
            try:
                var whiteNum, blackNum: int
                if parts.len >= 3:
                    whiteNum = parseInt(parts[1])
                    blackNum = parseInt(parts[2])
                    if whiteNum notin 0..959 or blackNum notin 0..959:
                        state.setError("Scharnagl numbers must be 0-959")
                        return true
                else:
                    let n = parseInt(parts[1])
                    if n < 0 or n >= 960 * 960:
                        state.setError("DFRC index must be 0-921599")
                        return true
                    whiteNum = n mod 960
                    blackNum = n div 960

                state.loadDoubleChess960Position(whiteNum, blackNum)
            except ValueError:
                state.setError("Invalid number(s)")
            true
        of "chess960":
            if parts.len < 2:
                state.setStatus(&"Chess960: {(if state.chess960: \"on\" else: \"off\")}")
            else:
                case parts[1].toLowerAscii():
                of "on", "true", "yes", "1":
                    state.setChess960Enabled(true)
                    state.setStatus("Chess960 enabled")
                of "off", "false", "no", "0":
                    state.setChess960Enabled(false)
                    state.setStatus("Chess960 disabled")
                else:
                    state.setError("Usage: :chess960 on|off")
            true
        else:
            false
