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

## Composes the full TUI layout into an illwill TerminalBuffer

import std/[strformat, strutils, monotimes, options]

import illwill
import heimdall/[pieces, board, eval, moves, transpositions]
import heimdall/util/wdl
import heimdall/tui/[state, input]
import heimdall/tui/graphics/board_view
import heimdall/tui/util/clock


const
    INFO_PANEL_PREFERRED_WIDTH = 30


proc annotatedReplaySan(state: AppState, index: int, san: string): string =
    if state.mode != ModeReplay or not state.hasGameAnalysis():
        return san
    if san.len == 0 or san[^1] in {'?', '!'}:
        return san

    let moveSummary = state.computeGameAnalysisMoveSummary(index + 1)
    if moveSummary.isSome() and moveSummary.get().judgment.isSome():
        return san & judgmentGlyph(moveSummary.get().judgment.get())
    san


proc replayMoveColor(state: AppState, index: int): tuple[color: ForegroundColor, bright: bool] =
    if state.mode != ModeReplay or not state.hasGameAnalysis():
        return (fgWhite, false)
    let moveSummary = state.computeGameAnalysisMoveSummary(index + 1)
    if moveSummary.isNone() or moveSummary.get().judgment.isNone():
        return (fgWhite, false)

    case moveSummary.get().judgment.get():
        of JudgmentInaccuracy:
            (fgBlue, true)
        of JudgmentMistake:
            (fgYellow, true)
        of JudgmentBlunder:
            (fgRed, true)


proc formatScore(score: Score): string =
    if score.isMateScore():
        let plies = mateScore() - abs(score)
        let moves = (plies + 1) div 2
        if score > 0:
            return &"M{moves}"
        else:
            return &"-M{moves}"
    else:
        let cp = score.float / 100.0
        return &"{cp:+.2f}"


proc formatNodes(n: uint64): string =
    if n >= 1_000_000_000:
        return &"{n.float / 1_000_000_000.0:.1f}G"
    elif n >= 1_000_000:
        return &"{n.float / 1_000_000.0:.1f}M"
    elif n >= 1_000:
        return &"{n.float / 1_000.0:.1f}K"
    else:
        return $n


proc formatSpeed(n: uint64): string =
    formatNodes(n) & " nodes/sec"


proc formatAnalysisTimeLimit(ms: int64): string =
    if ms < 1000:
        return &"{ms} ms"
    if ms mod 1000 == 0 and ms < 60_000:
        return &"{ms div 1000} s"
    if ms < 60_000:
        return &"{ms.float / 1000.0:.1f} s"
    let totalSeconds = ms div 1000
    let minutes = totalSeconds div 60
    let seconds = totalSeconds mod 60
    if seconds == 0:
        &"{minutes} m"
    else:
        &"{minutes}m {seconds}s"


proc formatCastling(board: Chessboard, chess960: bool): string =
    let
        whiteCastle = board.position.castlingAvailability[White]
        blackCastle = board.position.castlingAvailability[Black]

    if chess960:
        # Shredder notation: use rook file letters
        if whiteCastle.king != nullSquare():
            result &= chr(ord('A') + whiteCastle.king.file().int)
        if whiteCastle.queen != nullSquare():
            result &= chr(ord('A') + whiteCastle.queen.file().int)
        if blackCastle.king != nullSquare():
            result &= chr(ord('a') + blackCastle.king.file().int)
        if blackCastle.queen != nullSquare():
            result &= chr(ord('a') + blackCastle.queen.file().int)
    else:
        if whiteCastle.king != nullSquare():
            result &= "K"
        if whiteCastle.queen != nullSquare():
            result &= "Q"
        if blackCastle.king != nullSquare():
            result &= "k"
        if blackCastle.queen != nullSquare():
            result &= "q"

    if result.len == 0:
        result = "-"


proc formatClockForGame(limit: PlayLimitConfig, clock: ChessClock): string =
    if limit.timeControl.isSome():
        return formatTime(clock)
    return "N/A"


proc drawInfoPanel(tb: var TerminalBuffer, state: AppState, startX, startY, width, height: int) =
    ## Draws the engine info panel on the right side
    var y = startY
    let panelBottom = startY + height - 1


    # Title
    tb.setForegroundColor(fgCyan, bright=true)
    tb.setBackgroundColor(bgNone)
    tb.write(startX, y, "Engine Info")
    inc y, 2

    # Helper: draw a label + value pair
    let labelCol = 14  # column width for labels

    template infoLine(label: string, value: string) =
        let maxVal = width - labelCol - 1
        tb.setForegroundColor(fgCyan)
        tb.write(startX, y, label)
        tb.setForegroundColor(fgWhite, bright=true)
        if value.len <= maxVal:
            tb.write(startX + labelCol, y, value)
            inc y
        else:
            # Wrap long values across multiple lines
            var pos = 0
            while pos < value.len:
                let chunk = value[pos..<min(pos + maxVal, value.len)]
                tb.write(startX + labelCol, y, chunk)
                inc y
                pos += maxVal

    # Position info
    let stm = if state.board.sideToMove() == White: "White" else: "Black"
    infoLine("Side:", stm)

    let castling = formatCastling(state.board, state.chess960)
    infoLine("Castling:", castling)

    infoLine("Zobrist:", &"{state.board.zobristKey().uint64:#0X}")

    let epStr = if state.board.position.enPassantSquare == nullSquare(): "-" else: $state.board.position.enPassantSquare
    infoLine("EP:", epStr)

    infoLine("50-move:", &"{state.board.halfMoveClock()}/100")

    infoLine("Move:", $state.board.position.fullMoveCount)

    # FEN (truncated to panel width)
    let fen = state.board.toFEN()
    let maxFen = width - labelCol - 1
    let fenDisplay = if fen.len > maxFen: fen[0..<maxFen-3] & "..." else: fen
    tb.setForegroundColor(fgCyan)
    tb.write(startX, y, "FEN:")
    tb.setForegroundColor(fgWhite)
    tb.setStyle({styleDim})
    tb.write(startX + labelCol, y, fenDisplay)
    tb.setStyle({})
    inc y

    # Engine settings
    infoLine("Threads:", $state.engineThreads)
    let hashFill = state.ttable.getFillEstimate()
    let hashPct = &"{hashFill.float / 10.0:.1f}%"
    infoLine("Hash:", $state.engineHash & " MiB (" & hashPct & " full)")
    var analysisLimits: seq[string]
    if state.analysis.depthLimit.isSome():
        analysisLimits.add("depth " & $state.analysis.depthLimit.get())
    if state.analysis.mateLimit.isSome():
        analysisLimits.add("mate " & $state.analysis.mateLimit.get())
    if analysisLimits.len > 0:
        infoLine("Limit:", analysisLimits.join(", "))
    if state.analysis.multiPV > 1:
        infoLine("MultiPV:", $state.analysis.multiPV)
    inc y

    # Search status
    if state.mode == ModePlay and (state.play.isPondering or state.play.watch.isPondering):
        tb.setForegroundColor(fgMagenta, bright=true)
        if state.play.isPondering and state.play.watch.isPondering:
            tb.write(startX, y, &"[W pondering {state.play.ponderMove.toUCI()}, B pondering {state.play.watch.ponderMove.toUCI()}]")
        elif state.play.isPondering:
            let side = if state.play.watchMode: "White" else: "Engine"
            tb.write(startX, y, &"[{side} PONDERING on {state.play.ponderMove.toUCI()}]")
        else:
            tb.write(startX, y, &"[Black PONDERING on {state.play.watch.ponderMove.toUCI()}]")
    elif state.mode == ModePlay and state.play.engineThinking:
        tb.setForegroundColor(fgYellow, bright=true)
        if state.play.watchMode:
            let side = if state.board.sideToMove() == White: "White" else: "Black"
            tb.write(startX, y, &"[{side} THINKING]")
        elif state.pendingPremoves.len > 0:
            let nextPremove = state.pendingPremoves[0]
            if state.pendingPremoves.len == 1:
                tb.write(startX, y, &"[ENGINE THINKING | PREMOVE {nextPremove.fromSq.toUCI()}{nextPremove.toSq.toUCI()}]")
            else:
                tb.write(startX, y, &"[ENGINE THINKING | PREMOVES {state.pendingPremoves.len} | NEXT {nextPremove.fromSq.toUCI()}{nextPremove.toSq.toUCI()}]")
        else:
            tb.write(startX, y, "[ENGINE THINKING]")
    elif state.boardSetup.active:
        tb.setForegroundColor(fgCyan, bright=true)
        tb.write(startX, y, "[BOARD SETUP]")
    elif state.analysis.running:
        tb.setForegroundColor(fgGreen, bright=true)
        tb.write(startX, y, "[SEARCHING]")
    elif state.gameAnalysis.running:
        tb.setForegroundColor(fgMagenta, bright=true)
        tb.write(startX, y, &"[COMPUTER ANALYSIS {state.gameAnalysis.completedPositions}/{state.gameAnalysis.totalPositions}]")
    elif state.mode == ModeReplay and state.hasGameAnalysis():
        tb.setForegroundColor(fgBlue, bright=true)
        tb.write(startX, y, "[REPORT READY]")
    elif state.mode == ModePlay:
        case state.play.phase:
            of PlayerTurn:
                tb.setForegroundColor(fgGreen, bright=true)
                tb.write(startX, y, "[YOUR TURN]")
            of GameOver:
                tb.setForegroundColor(fgRed, bright=true)
                tb.write(startX, y, "[GAME OVER]")
            of Setup:
                tb.setForegroundColor(fgCyan, bright=true)
                tb.write(startX, y, "[SETUP]")
            else:
                tb.setForegroundColor(fgRed)
                tb.write(startX, y, "[IDLE]")
    else:
        tb.setForegroundColor(fgRed)
        tb.write(startX, y, "[IDLE]")

    inc y

    # Indicators (on their own line)
    var indicatorX = startX
    template writeIndicator(color: ForegroundColor, isBright: bool, label: string) =
        if indicatorX > startX:
            tb.write(indicatorX, y, " ")
            inc indicatorX
        tb.setForegroundColor(color, bright=isBright)
        tb.write(indicatorX, y, label)
        indicatorX += label.len

    if state.chess960:
        let variantStr = case state.play.variant:
            of Standard:
                ""
            of FischerRandom:
                "[FRC]"
            of DoubleFischerRandom:
                "[DFRC]"
        if variantStr.len > 0:
            writeIndicator(fgMagenta, true, variantStr)
    if state.showThreats:
        writeIndicator(fgRed, true, "[Threats]")
    if state.mode != ModePlay and state.showEngineArrows:
        writeIndicator(fgGreen, true, "[Arrows]")
    if state.autoQueen:
        writeIndicator(fgYellow, true, "[Auto-queen]")
    if state.pendingPremoves.len > 0:
        let nextPremove = state.pendingPremoves[0]
        let premoveLabel =
            if state.pendingPremoves.len == 1:
                &"[Premove {nextPremove.fromSq.toUCI()}{nextPremove.toSq.toUCI()}]"
            else:
                &"[Premoves {state.pendingPremoves.len}, next {nextPremove.fromSq.toUCI()}{nextPremove.toSq.toUCI()}]"
        writeIndicator(fgBlue, true, premoveLabel)
    if state.boardSetup.active and state.boardSetup.spawnPiece.isSome():
        let piece = state.boardSetup.spawnPiece.get()
        writeIndicator(fgGreen, true, &"[Spawn {piece.toChar()}]")
    inc y

    if state.boardSetup.active:
        tb.setForegroundColor(fgCyan)
        tb.write(startX, y, "Setup: drag to move, drop off-board to delete, Esc to apply")
        inc y
        tb.setForegroundColor(fgWhite)
        tb.write(startX, y, "Spawn: p/n/b/r/q/k for black, Shift+key for white")
        inc y
        tb.write(startX, y, "Castling: w/x = white Q/K, y/z = black Q/K")
        inc y

    inc y

    # Move list (PGN-style, wrapped in the panel) - shown right after status
    if state.sanHistory.len > 0:
        tb.setForegroundColor(fgCyan, bright=true)
        tb.write(startX, y, "Moves:")
        inc y

        type ColoredToken = tuple[text: string, color: ForegroundColor, bright: bool]
        var lineTokens: seq[ColoredToken] = @[]
        var lineLen = 0
        var moveNum = 1

        template flushMoveLine() =
            if lineTokens.len == 0 or y > panelBottom:
                discard
            else:
                var x = startX
                for token in lineTokens:
                    tb.setForegroundColor(token.color, bright=token.bright)
                    tb.write(x, y, token.text)
                    x += token.text.len
                    tb.write(x, y, " ")
                    inc x
                inc y
                lineTokens = @[]
                lineLen = 0

        for i, san in state.sanHistory:
            let annotatedSan = annotatedReplaySan(state, i, san)
            let (tokenColor, tokenBright) = replayMoveColor(state, i)
            var token = ""
            if i mod 2 == 0:
                token = $moveNum & ". " & annotatedSan
            else:
                token = annotatedSan
                inc moveNum
            if lineLen > 0 and lineLen + token.len + 1 > width - 1:
                flushMoveLine()
                if y > panelBottom:
                    break
            if y > panelBottom:
                break
            lineTokens.add((token, tokenColor, tokenBright))
            lineLen += token.len + 1

        if y <= panelBottom:
            flushMoveLine()
    # Replay panes follow immediately after the move list to keep them away from the graph.

    # Analysis depth/nodes/nps (hidden during play mode)
    let hasCurrentAnalysis = state.analysis.linesPositionKey == state.board.zobristKey().uint64 and state.analysis.lines.len > 0
    if state.mode != ModePlay and (state.analysis.running or hasCurrentAnalysis):
        let speedDisplay = if state.analysis.running: formatSpeed(state.analysis.nps) else: "N/A"
        infoLine("Depth:", $state.analysis.depth)
        infoLine("Nodes:", formatNodes(state.analysis.nodes))
        infoLine("Speed:", speedDisplay)

        # WDL for the primary line
        if hasCurrentAnalysis and state.analysis.lines[0].pv.len > 0:
            let primaryLine = state.analysis.lines[0]
            let mat = state.board.material()
            let wdl = getExpectedWDL(primaryLine.rawScore, mat)

            tb.setForegroundColor(fgCyan)
            tb.write(startX, y, "WDL:")
            var x = startX + labelCol
            let winLabel = &"W: {wdl.win div 10}%"
            tb.setForegroundColor(fgGreen, bright=true)
            tb.write(x, y, winLabel)
            x += winLabel.len + 1
            let drawLabel = &"D: {wdl.draw div 10}%"
            tb.setForegroundColor(fgWhite, bright=true)
            tb.write(x, y, drawLabel)
            x += drawLabel.len + 1
            let lossLabel = &"L: {wdl.loss div 10}%"
            tb.setForegroundColor(fgRed, bright=true)
            tb.write(x, y, lossLabel)
            inc y

        inc y

        # Analysis lines (MultiPV)
        if hasCurrentAnalysis:
            tb.setForegroundColor(fgCyan, bright=true)
            tb.write(startX, y, "Analysis Lines:")
            inc y

            let mat = state.board.material()
            for i, line in state.analysis.lines:
                if y >= startY + height - 4:
                    break
                if line.pv.len == 0:
                    continue

                let scoreStr = formatScore(line.score)
                let wdl = getExpectedWDL(line.rawScore, mat)
                let wdlShort = &"({wdl.win div 10}/{wdl.draw div 10}/{wdl.loss div 10})"

                # Show PV moves (as many as fit)
                var pvStr = ""
                let headerLen = ($(i+1)).len + 2 + scoreStr.len + 1 + wdlShort.len + 1
                let maxPVWidth = width - headerLen - 1
                for j, move in line.pv:
                    let moveStr = move.toUCI()
                    if pvStr.len + moveStr.len + 1 > maxPVWidth:
                        pvStr &= ".."
                        break
                    if j > 0: pvStr &= " "
                    pvStr &= moveStr

                var x = startX
                tb.setForegroundColor(fgYellow, bright=true)
                tb.write(x, y, &"{i+1}. ")
                x += ($(i+1)).len + 2
                tb.setForegroundColor(fgWhite, bright=true)
                tb.write(x, y, scoreStr & " ")
                x += scoreStr.len + 1
                let wW = &"{wdl.win div 10}"
                let wD = &"{wdl.draw div 10}"
                let wL = &"{wdl.loss div 10}"
                tb.setForegroundColor(fgGreen)
                tb.write(x, y, "(")
                x += 1
                tb.write(x, y, wW)
                x += wW.len
                tb.setForegroundColor(fgWhite)
                tb.write(x, y, "/")
                x += 1
                tb.write(x, y, wD)
                x += wD.len
                tb.setForegroundColor(fgRed)
                tb.write(x, y, "/")
                x += 1
                tb.write(x, y, wL)
                x += wL.len
                tb.write(x, y, ") ")
                x += 2
                tb.setForegroundColor(fgWhite)
                tb.write(x, y, pvStr)
                inc y


    if state.mode == ModeReplay and y < panelBottom:
        inc y
        let sectionGap = 3
        let showComputerAnalysis = state.gameAnalysis.running or state.hasGameAnalysis()
        let leftWidth =
            if showComputerAnalysis:
                max(10, (width - sectionGap) div 2)
            else:
                width
        let rightWidth =
            if showComputerAnalysis:
                max(10, width - leftWidth - sectionGap)
            else:
                0
        let pgnX = startX
        let analysisX = startX + leftWidth + sectionGap
        var pgnY = y
        var analysisY = y

        proc getTag(tags: seq[tuple[name, value: string]], tagName: string): string =
            for (n, v) in tags:
                if n.toLowerAscii() == tagName.toLowerAscii() and v.len > 0 and v != "?":
                    return v
            return ""

        template sectionInfoLine(sectionX: int, sectionY: untyped, sectionWidth: int, label: string, value: string, valueColor: ForegroundColor = fgWhite) =
            if sectionY <= panelBottom:
                let sectionLabelCol = min(12, max(7, sectionWidth div 2))
                let maxVal = max(1, sectionWidth - sectionLabelCol - 1)
                tb.setForegroundColor(fgCyan)
                tb.write(sectionX, sectionY, label)
                tb.setForegroundColor(valueColor, bright=true)
                if value.len <= maxVal:
                    tb.write(sectionX + sectionLabelCol, sectionY, value)
                    inc sectionY
                else:
                    var pos = 0
                    while pos < value.len and sectionY <= panelBottom:
                        let chunk = value[pos..<min(pos + maxVal, value.len)]
                        tb.write(sectionX + sectionLabelCol, sectionY, chunk)
                        inc sectionY
                        pos += maxVal

        if pgnY <= panelBottom:
            tb.setForegroundColor(fgCyan, bright=true)
            tb.write(pgnX, pgnY, "PGN Info:")
            inc pgnY, 2

            for side in ["White", "Black"]:
                if pgnY > panelBottom:
                    break
                let name = getTag(state.replay.tags, side)
                if name.len > 0:
                    let elo = getTag(state.replay.tags, side & "Elo")
                    let display = if elo.len > 0: name & " (" & elo & ")" else: name
                    sectionInfoLine(pgnX, pgnY, leftWidth, side & ":", display)

            const otherTags = ["Event", "Site", "Date", "Round", "Result", "TimeControl"]
            for tagName in otherTags:
                if pgnY > panelBottom:
                    break
                let value = getTag(state.replay.tags, tagName)
                if value.len > 0:
                    let label = case tagName:
                        of "TimeControl":
                            "Time Ctrl:"
                        else:
                            tagName & ":"
                    sectionInfoLine(pgnX, pgnY, leftWidth, label, value, fgBlue)

            let currentOpening = state.currentReplayOpening()
            let openingEco =
                if currentOpening.isSome():
                    currentOpening.get().eco
                else:
                    getTag(state.replay.tags, "ECO")
            if pgnY <= panelBottom and openingEco.len > 0:
                sectionInfoLine(pgnX, pgnY, leftWidth, "ECO:", openingEco, fgBlue)

            let openingName =
                if currentOpening.isSome():
                    currentOpening.get().name
                elif state.chess960:
                    "N/A (Chess960)"
                else:
                    getTag(state.replay.tags, "Opening")
            if pgnY <= panelBottom and openingName.len > 0:
                sectionInfoLine(pgnX, pgnY, leftWidth, "Opening:", openingName, fgBlue)

            if pgnY <= panelBottom:
                sectionInfoLine(pgnX, pgnY, leftWidth, "Moves:", &"{state.replay.moveIndex}/{state.replay.moves.len}")

        if showComputerAnalysis and analysisY <= panelBottom:
            tb.setForegroundColor(fgCyan, bright=true)
            tb.write(analysisX, analysisY, "Computer Analysis:")
            inc analysisY, 2

            if state.hasGameAnalysis():
                sectionInfoLine(analysisX, analysisY, rightWidth, "Limit:", state.gameAnalysis.limitLabel)
                let direction =
                    if state.gameAnalysis.direction == GameAnalysisReverse:
                        "reversed"
                    else:
                        "forward"
                sectionInfoLine(analysisX, analysisY, rightWidth, "Order:", direction)
                let graphLabel =
                    if state.gameAnalysis.graphVisible:
                        gameAnalysisGraphModeLabel(state.gameAnalysis.graphMode)
                    else:
                        gameAnalysisGraphModeLabel(state.gameAnalysis.graphMode) & " (hidden)"
                sectionInfoLine(analysisX, analysisY, rightWidth, "Graph:", graphLabel)

                let summary = state.computeGameAnalysisSummary()
                if summary.whiteMoves > 0 or summary.blackMoves > 0:
                    let acplValue = &"W {summary.whiteAvgCentipawnLoss} | B {summary.blackAvgCentipawnLoss}"
                    let accValue = &"W {summary.whiteAccuracy:.1f}% | B {summary.blackAccuracy:.1f}%"
                    sectionInfoLine(analysisX, analysisY, rightWidth, "ACPL:", acplValue)
                    sectionInfoLine(analysisX, analysisY, rightWidth, "Acc:", accValue)

                let currentMove = state.computeGameAnalysisMoveSummary(state.replay.moveIndex)
                if currentMove.isSome():
                    let moveSummary = currentMove.get()
                    sectionInfoLine(analysisX, analysisY, rightWidth, "Move Loss:", &"{moveSummary.centipawnLoss} cp")
                    sectionInfoLine(analysisX, analysisY, rightWidth, "Move Acc:", &"{moveSummary.accuracy:.1f}%")
                    if moveSummary.judgment.isSome():
                        sectionInfoLine(analysisX, analysisY, rightWidth, "Judgment:", judgmentLabel(moveSummary.judgment.get()))
                    if moveSummary.bestMove != nullMove():
                        sectionInfoLine(analysisX, analysisY, rightWidth, "Best Move:", moveSummary.bestMove.toUCI())

        y = max(pgnY, analysisY)

    # Game info and clocks (if in play mode)
    if state.mode == ModePlay and state.play.phase != Setup:
        inc y
        tb.setForegroundColor(fgCyan, bright=true)
        tb.write(startX, y, "Game:")
        inc y

        # Game details
        let variantStr = case state.play.variant:
            of Standard:
                "Standard"
            of FischerRandom:
                "Chess960"
            of DoubleFischerRandom:
                "DFRC"
        infoLine("Variant:", variantStr)
        infoLine("TC:", state.play.gameTimeControl)
        if not state.play.watchMode:
            let sideStr = if state.play.playerColor == White: "White" else: "Black"
            infoLine("Playing:", sideStr)
        if state.play.allowTakeback:
            infoLine("Takeback:", "enabled")
        if state.play.allowPonder or state.play.watch.allowPonder:
            if state.play.watchMode:
                let wStatus = if state.play.isPondering: &"on {state.play.ponderMove.toUCI()}"
                              elif state.play.allowPonder: "enabled"
                              else: "off"
                let bStatus = if state.play.watch.isPondering: &"on {state.play.watch.ponderMove.toUCI()}"
                              elif state.play.watch.allowPonder: "enabled"
                              else: "off"
                infoLine("W Ponder:", wStatus)
                infoLine("B Ponder:", bStatus)
            else:
                if state.play.isPondering:
                    infoLine("Ponder:", &"on {state.play.ponderMove.toUCI()}")
                else:
                    infoLine("Ponder:", "enabled")
        if state.play.result.isSome():
            infoLine("Result:", state.play.result.get())
        inc y

        # Clocks
        tb.setForegroundColor(fgCyan, bright=true)
        tb.write(startX, y, "Clocks:")
        inc y

        let whiteLabel = if state.play.watchMode: "Engine" elif state.play.playerColor == White: "You" else: "Engine"
        let blackLabel = if state.play.watchMode: "Engine" elif state.play.playerColor == Black: "You" else: "Engine"

        let whiteLimit =
            if state.play.watchMode:
                state.play.playerLimit
            elif state.play.playerColor == White:
                state.play.playerLimit
            else:
                state.play.engineLimit
        let blackLimit =
            if state.play.watchMode:
                state.play.engineLimit
            elif state.play.playerColor == Black:
                state.play.playerLimit
            else:
                state.play.engineLimit

        let wClock = if state.play.playerColor == White: state.play.playerClock else: state.play.engineClock
        let bClock = if state.play.playerColor == Black: state.play.playerClock else: state.play.engineClock

        let clockCol = 15
        tb.setForegroundColor(fgCyan)
        tb.write(startX, y, &"W ({whiteLabel}):")
        tb.setForegroundColor(fgWhite, bright=true)
        tb.write(startX + clockCol, y, formatClockForGame(whiteLimit, wClock))
        inc y
        tb.setForegroundColor(fgCyan)
        tb.write(startX, y, &"B ({blackLabel}):")
        tb.setForegroundColor(fgWhite, bright=true)
        tb.write(startX + clockCol, y, formatClockForGame(blackLimit, bClock))
        inc y
        inc y


proc drawEvalBarLabel(tb: var TerminalBuffer, state: AppState, boardX, boardY, boardHeight: int) =
    if state.mode == ModePlay:
        return

    let gutterWidth = boardX - BOARD_MARGIN_X
    if gutterWidth <= 0 or boardHeight <= 0:
        return

    let score = currentEvalScore(state)
    if score.isNone():
        return

    var scoreText = formatScore(score.get())
    if scoreText.len > gutterWidth:
        scoreText = scoreText[0..<gutterWidth]
    let scoreX = BOARD_MARGIN_X + max(0, (gutterWidth - scoreText.len) div 2)
    let scoreY = boardY + boardHeight
    tb.setForegroundColor(fgWhite, bright=true)
    tb.write(scoreX, scoreY, scoreText)


proc drawInputBar(tb: var TerminalBuffer, state: AppState, startX, startY, width: int) =
    ## Draws the input bar at the bottom
    tb.setForegroundColor(fgYellow, bright=true)
    tb.setBackgroundColor(bgNone)
    tb.write(startX, startY, "> ")

    let modeStr = case state.mode:
        of ModeAnalysis:
            if state.boardSetup.active: "[Board Setup]"
            elif state.analysis.running: "[Analyzing]" else: "[Analysis]"
        of ModePlay:
            case state.play.phase:
                of Setup:
                    "[Setup]"
                of PlayerTurn:
                    "[Your Turn]"
                of EngineTurn:
                    "[Thinking]"
                of GameOver:
                    "[Game Over]"
        of ModeReplay:
            "[Replay]"

    let inputStartX = startX + 2
    let modeX = startX + width - modeStr.len - 1
    let inputAreaWidth = max(1, modeX - inputStartX - 1)
    let visibleTextLen = max(0, inputAreaWidth - 1)  # Reserve one cell for the caret

    var showSuggestion = false
    var displayText = state.input.buffer
    if state.input.acActive and state.input.acSelected.isSome() and state.input.acSelected.get() < state.input.acSuggestions.len:
        let suggestion = ":" & state.input.acSuggestions[state.input.acSelected.get()].cmd
        # Only show a ghost suggestion while the caret is at the end of the typed input.
        if state.input.cursorPos == state.input.buffer.len and suggestion.startsWith(state.input.buffer):
            showSuggestion = true
            displayText = suggestion

    let cursorPos = min(state.input.cursorPos, displayText.len)
    var visibleStart = 0
    if displayText.len > visibleTextLen and visibleTextLen > 0:
        visibleStart = max(0, min(cursorPos - visibleTextLen div 2, displayText.len - visibleTextLen))
    let visibleEnd = min(displayText.len, visibleStart + visibleTextLen)
    let beforeCursorEnd = min(cursorPos, visibleEnd)
    let beforeCursor =
        if beforeCursorEnd > visibleStart: displayText[visibleStart ..< beforeCursorEnd]
        else: ""
    let afterCursor =
        if cursorPos < visibleEnd: displayText[cursorPos ..< visibleEnd]
        else: ""

    template writeStyledSlice(x: int, sliceStart: int, sliceText: string) =
        if sliceText.len == 0:
            discard
        elif not showSuggestion:
            tb.setForegroundColor(fgWhite)
            tb.setStyle({})
            tb.write(x, startY, sliceText)
        else:
            let typedVisibleLen = max(0, min(sliceText.len, state.input.buffer.len - sliceStart))
            if typedVisibleLen > 0:
                tb.setForegroundColor(fgWhite, bright=true)
                tb.setStyle({})
                tb.write(x, startY, sliceText[0 ..< typedVisibleLen])
            if typedVisibleLen < sliceText.len:
                tb.setForegroundColor(fgWhite)
                tb.setStyle({styleDim})
                tb.write(x + typedVisibleLen, startY, sliceText[typedVisibleLen .. ^1])
            tb.setStyle({})

    writeStyledSlice(inputStartX, visibleStart, beforeCursor)

    let cursorX = inputStartX + beforeCursor.len
    tb.setForegroundColor(fgYellow, bright=true)
    tb.write(cursorX, startY, "|")
    writeStyledSlice(cursorX + 1, cursorPos, afterCursor)

    # Mode indicator on the right
    tb.setForegroundColor(fgCyan)
    tb.write(modeX, startY, modeStr)


proc drawHelpBox(tb: var TerminalBuffer, state: AppState, startX, startY, width, height: int) =
    ## Draws the help overlay in the info panel area
    if not state.input.helpVisible:
        return

    let lines = buildHelpLines()
    let viewportHeight = helpViewportHeight(height)
    let maxScroll = max(0, lines.len - viewportHeight)
    let scroll = max(0, min(state.input.helpScroll, maxScroll))
    var y = startY

    tb.setForegroundColor(fgCyan, bright=true)
    tb.setBackgroundColor(bgNone)
    let title =
        if maxScroll > 0: &"Help [{scroll + 1}-{min(scroll + viewportHeight, lines.len)}/{lines.len}]"
        else: "Help"
    tb.write(startX, y, title)
    inc y
    tb.setForegroundColor(fgWhite)
    tb.write(startX, y, "-".repeat(min(width, 40)))
    inc y, 2

    for i in 0..<viewportHeight:
        let lineIndex = scroll + i
        if lineIndex >= lines.len or y >= startY + height - HELP_VIEW_FOOTER_ROWS:
            break
        let line = lines[lineIndex]
        if line.len == 0:
            inc y
            continue
        if line.endsWith(":"):
            tb.setForegroundColor(fgYellow, bright=true)
            tb.write(startX, y, line)
        else:
            tb.setForegroundColor(fgWhite)
            let truncLine = if line.len > width - 1: line[0..<max(0, width - 1)] else: line
            tb.write(startX + 1, y, truncLine)
        inc y

    let footerY = startY + height - 1
    let footer = "↑/↓ scroll, PgUp/PgDn page, Esc close"
    tb.setForegroundColor(fgCyan)
    tb.write(startX, footerY, if footer.len > width: footer[0..<width] else: footer)


proc drawAutocomplete(tb: var TerminalBuffer, state: AppState, startX, bottomY, width: int) =
    ## Draws autocomplete suggestions above the input bar
    if not state.input.acActive or state.input.acSuggestions.len == 0:
        return

    let count = min(state.input.acSuggestions.len, 8)  # Max 8 visible suggestions

    # Compute description column based on longest command name
    var maxCmdLen = 0
    for i in 0..<count:
        maxCmdLen = max(maxCmdLen, state.input.acSuggestions[i].cmd.len)
    let descCol = maxCmdLen + 6  # 3 for "> :" prefix + 3 padding

    for i in 0..<count:
        let y = bottomY - count + i
        if y < 0: continue

        let (cmd, desc) = state.input.acSuggestions[i]
        let isSelected = state.input.acSelected.isSome() and i == state.input.acSelected.get()

        tb.setBackgroundColor(bgNone)

        if isSelected:
            tb.setForegroundColor(fgGreen, bright=true)
            tb.setStyle({styleBright})
            tb.write(startX, y, ">")
            tb.write(startX + 1, y, " :" & cmd)
        else:
            tb.setForegroundColor(fgYellow, bright=true)
            tb.write(startX, y, "  :" & cmd)

        # Description, positioned after the longest command
        tb.setStyle({styleBright})
        if isSelected:
            tb.setForegroundColor(fgWhite, bright=true)
        else:
            tb.setForegroundColor(fgWhite)
        let descX = startX + descCol
        let maxDesc = width - descCol - 1
        if maxDesc > 0:
            let truncDesc = if desc.len > maxDesc: desc[0..<maxDesc] else: desc
            tb.write(descX, y, truncDesc)
        tb.setStyle({})
        tb.setBackgroundColor(bgNone)


proc drawStatusBar(tb: var TerminalBuffer, state: AppState, startX, startY, width: int) =
    ## Draws the status bar (transient messages)
    if state.input.statusMessage.len > 0 and getMonoTime() < state.input.statusExpiry:
        if state.input.statusIsError:
            tb.setForegroundColor(fgRed, bright=true)
        else:
            tb.setForegroundColor(fgYellow)
        tb.setBackgroundColor(bgNone)
        let msg = if state.input.statusMessage.len > width: state.input.statusMessage[0..<width] else: state.input.statusMessage
        tb.write(startX, startY, msg)


proc drawTooSmallOverlay(tb: var TerminalBuffer, state: AppState, w, h: int) =
    let minimum = minimumTerminalSize(state)
    let lines = [
        "Terminal too small for the TUI",
        &"Minimum size: {minimum.w}x{minimum.h}",
        &"Current size: {w}x{h}",
        "Resize the window or reduce the terminal font size"
    ]
    let startY = max(1, h div 2 - lines.len div 2)
    for i, line in lines:
        let x = max(0, (w - line.len) div 2)
        tb.setForegroundColor(if i == 0: fgRed else: fgYellow, bright=true)
        tb.setBackgroundColor(bgNone)
        tb.write(x, startY + i, line)

proc render*(state: AppState) =
    ## Renders the complete TUI layout
    let
        w = terminalWidth()
        h = terminalHeight()

    # Recreate buffer only on resize; otherwise reuse to avoid
    # illwill doing a full redraw that wipes the kitty board image
    if state.terminalRender.persistentTb == nil or
       w != state.terminalRender.prevW or
       h != state.terminalRender.prevH:
        hideBoardImages(state)
        state.terminalRender.persistentTb = newTerminalBuffer(w, h)
        state.terminalRender.prevW = w
        state.terminalRender.prevH = h
        # Force board image retransmit after resize since illwill's
        # displayFull will overwrite the board area
        resetBoardHash(state)

    var tb = state.terminalRender.persistentTb

    let boardIsVisible = boardVisible(state)
    let boardX = boardStartX()
    let boardW = boardWidth(state)
    let boardH = boardHeight(state)
    let boardAreaChanged =
        boardIsVisible and (
            not state.boardRender.boardImageVisible or
            state.terminalRender.prevBoardX != boardX or
            state.terminalRender.prevBoardY != BOARD_MARGIN_Y or
            state.terminalRender.prevBoardW != boardW or
            state.terminalRender.prevBoardH != boardH
        )
    let graphRows =
        if boardIsVisible:
            state.gameAnalysisGraphRows()
        else:
            0
    let graphTopRow =
        if boardIsVisible and graphRows > 0:
            gameAnalysisGraphTermRow(state) - 1
        else:
            h - 3
    let infoPanelX = boardX + boardW + BOARD_GAP_COLS
    let infoPanelWidth = min(max(INFO_PANEL_MIN_WIDTH, w - infoPanelX - 1), max(INFO_PANEL_PREFERRED_WIDTH, w - infoPanelX - 1))
    let infoPanelHeight = max(1, graphTopRow - BOARD_MARGIN_Y)

    tb.setBackgroundColor(bgNone)
    tb.setForegroundColor(fgNone)
    for y in 0..<h:
        for x in 0..<w:
            if boardIsVisible and x >= boardX and x < boardX + boardW and y >= BOARD_MARGIN_Y and y < BOARD_MARGIN_Y + boardH:
                continue  # skip board area
            tb.write(x, y, " ")

    if boardAreaChanged:
        for y in BOARD_MARGIN_Y..<BOARD_MARGIN_Y + boardH:
            for x in boardX..<boardX + boardW:
                tb.write(x, y, " ")
        resetBoardHash(state)

    if not boardIsVisible:
        hideBoardImages(state)
        state.terminalRender.prevBoardX = 0
        state.terminalRender.prevBoardY = 0
        state.terminalRender.prevBoardW = 0
        state.terminalRender.prevBoardH = 0
        drawTooSmallOverlay(tb, state, w, h)
    else:
        state.terminalRender.prevBoardX = boardX
        state.terminalRender.prevBoardY = BOARD_MARGIN_Y
        state.terminalRender.prevBoardW = boardW
        state.terminalRender.prevBoardH = boardH
        drawEvalBarLabel(tb, state, boardX, BOARD_MARGIN_Y, boardH)
        if state.input.helpVisible:
            drawHelpBox(tb, state, infoPanelX, BOARD_MARGIN_Y, infoPanelWidth, infoPanelHeight)
        else:
            drawInfoPanel(tb, state, infoPanelX, BOARD_MARGIN_Y, infoPanelWidth, infoPanelHeight)

    # Draw the separator line
    tb.setForegroundColor(fgWhite)
    tb.setBackgroundColor(bgNone)
    for x in 0..<w:
        tb.write(x, h - 3, "-")

    # Draw autocomplete suggestions (above input bar)
    drawAutocomplete(tb, state, 1, h - 3, w - 2)

    # Draw the input bar
    drawInputBar(tb, state, 1, h - 2, w - 2)

    # Draw the status bar
    drawStatusBar(tb, state, 1, h - 1, w - 2)

    tb.display()

    if boardIsVisible:
        displayEvalBar(state, BOARD_MARGIN_Y + 1, BOARD_MARGIN_X + 1)
        displayBoard(state, BOARD_MARGIN_Y + 1, boardX + 1)
        if graphRows > 0:
            let graphTermCol = 1
            let graphWidth = w
            displayGameAnalysisGraph(
                state,
                gameAnalysisGraphTermRow(state),
                graphTermCol,
                graphWidth,
                graphRows,
                state.replay.moveIndex
            )
        else:
            hideGameAnalysisGraph(state)
