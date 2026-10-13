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

## Focused SAN/UCI display and TUI option regressions.
## Build through make dev with MAIN=tests/test_tui_notation.nim IS_TEST=1,
## EXE_BASE=bin/test-tui-notation and an absolute EVALFILE path.

import std/strutils

import heimdall/[board, moves, movegen]
import heimdall/util/move_parse
import heimdall/tui/[state, input]
import heimdall/tui/input/engine_commands
import heimdall/tui/util/[notation, san]


proc makePV(board: Chessboard, coordinates: string, chess960 = false): seq[Move] =
    let preview = newChessboard(@[board.position])
    for text in coordinates.splitWhitespace():
        let parsed = parseUCIMove(preview.position, text, chess960=chess960)
        doAssert not parsed.error.hasError(), text
        doAssert preview.makeMove(parsed.move) != nullMove(), text
        result.add(parsed.move)


proc verifyLine(board: Chessboard, coordinates, expected: string, chess960 = false) =
    let before = newChessboard(board.positions)
    let pv = board.makePV(coordinates, chess960)
    doAssert board.formatPV(pv, chess960=chess960) == expected
    doAssert board.formatPV(pv, UCINotation, chess960) == coordinates
    doAssert board.positions == before.positions, "PV formatting changed the board/history"


block sequentialPositions:
    let board = newDefaultChessboard()
    board.verifyLine("e2e4 e7e5 g1f3 b8c6 f1b5 a7a6 b5a4 g8f6 e1g1 f8e7 f1e1 b7b5 a4b3 d7d6 c2c3 e8g8",
                     "e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O Be7 Re1 b5 Bb3 d6 c3 O-O")
    board.verifyLine("f2f3 e7e5 g2g4 d8h4", "f3 e5 g4 Qh4#")
    for move in board.makePV("e2e4 e7e5 g1f3"):
        board.doMove(move)
    board.verifyLine("b8c6 f1b5", "Nc6 Bb5")


block specialMovesAndDisambiguation:
    for (fen, coordinates, expected) in [
        ("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1", "e5d6", "exd6"),
        ("7k/P7/8/8/8/8/8/7K w - - 0 1", "a7a8q", "a8=Q+"),
        ("k7/8/8/8/8/8/8/1N3N1K w - - 0 1", "b1d2", "Nbd2"),
        ("7k/8/8/8/8/R7/8/R6K w - - 0 1", "a1a2", "R1a2"),
        ("k7/8/8/8/8/1N6/8/1N3N1K w - - 0 1", "b1d2", "Nb1d2"),
        ("5k2/8/8/8/8/8/8/4K2R w K - 0 1", "e1g1", "O-O+"),
        ("3k4/8/8/8/8/8/8/R3K3 w Q - 0 1", "e1c1", "O-O-O+")
    ]:
        let board = newChessboardFromFEN(fen)
        board.verifyLine(coordinates, expected)
        let (move, error) = board.parseSAN(expected)
        doAssert error.len == 0, error
        doAssert move == board.makePV(coordinates)[0]


block standardCastlingCoordinates:
    for side in ["w", "b"]:
        let board = newChessboardFromFEN("r3k2r/8/8/8/8/8/8/R3K2R " & side & " KQkq - 0 1")
        let rank = if side == "w": "1" else: "8"
        for (target, rook, expected) in [("g", "h", "O-O"), ("c", "a", "O-O-O")]:
            let coordinates = "e" & rank & target & rank
            let pv = board.makePV(coordinates)
            let original = pv[0]
            doAssert board.formatPV(pv) == expected
            doAssert board.formatPV(pv, UCINotation) == coordinates
            doAssert board.formatPV(pv, UCINotation, chess960=true) == "e" & rank & rook & rank
            doAssert pv[0] == original


block chess960Castling:
    for (fen, coordinates, expected) in [
        ("4k3/8/8/8/8/8/8/R1K2R2 w FA - 0 1", "c1f1", "O-O"),
        ("4k3/8/8/8/8/8/8/R1K2R2 w FA - 0 1", "c1a1", "O-O-O"),
        ("4k3/8/8/8/8/8/8/5KR1 w G - 0 1", "f1g1", "O-O"),
        ("4k3/8/8/8/8/8/8/6KR w H - 0 1", "g1h1", "O-O"),
        ("r1k2r2/8/8/8/8/8/8/4K3 b fa - 0 1", "c8f8", "O-O"),
        ("r1k2r2/8/8/8/8/8/8/4K3 b fa - 0 1", "c8a8", "O-O-O")
    ]:
        newChessboardFromFEN(fen).verifyLine(coordinates, expected, chess960=true)


block incompleteAndClippedLines:
    let board = newDefaultChessboard()
    let pv = board.makePV("e2e4 e7e5 g1f3")
    doAssert board.formatPV(@[]) == ""
    doAssert board.formatPV(@[pv[0], nullMove(), pv[1]]) == "e4"
    doAssert board.formatPV(@[pv[0], pv[0]]) == "e4"
    doAssert board.formatPV(pv, maxWidth=8) == "e4 e5.."
    doAssert board.formatPV(pv, maxWidth=5) == "e4.."
    doAssert board.formatPV(pv, maxWidth=1) == "."
    doAssert board.formatPV(pv, maxWidth=0) == ""
    doAssert board.formatPV(pv, UCINotation, maxWidth=8) == "e2e4.."


block notationOption:
    let app = newAppState()
    doAssert app.analysis.pvNotation == SANNotation
    app.analysis.running = true
    doAssert app.handleEngineCommand(@["set", "pvnotation", "UCI"])
    doAssert app.analysis.pvNotation == UCINotation
    doAssert not app.input.statusIsError
    doAssert app.analysis.running
    doAssert app.handleEngineCommand(@["set", "pvnotation", "invalid"])
    doAssert app.input.statusIsError
    doAssert app.analysis.pvNotation == UCINotation
    doAssert app.handleEngineCommand(@["set", "pvnotation", "SAN"])
    doAssert app.analysis.pvNotation == SANNotation
    doAssert not app.input.statusIsError
    app.input.buffer = ":set pvno"
    app.updateAutocomplete()
    doAssert app.input.acActive
    doAssert app.input.acSuggestions[0].cmd == "set pvnotation"
    doAssert buildHelpLines().join("\n").contains(":set pvnotation san|uci")
    app.channels.command.close()
    app.channels.response.close()
    app.pvChannel.close()
    app.gameAnalysisChannel.close()


echo "TUI notation tests passed"
