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

## Composes the full TUI layout into an illwill TerminalBuffer

import std/[strformat, strutils, monotimes, options]

import illwill
import heimdall/[pieces, board, eval, moves, transpositions]
import heimdall/util/wdl
import heimdall/tui/[state, board_view, clock, input]


const
    INFO_PANEL_PREFERRED_WIDTH = 30


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
    if state.analysisDepthLimit.isSome():
        infoLine("Limit:", "depth " & $state.analysisDepthLimit.get())
    if state.multiPV > 1:
        infoLine("MultiPV:", $state.multiPV)
    inc y

    # Search status
    if state.mode == ModePlay and (state.isPondering or state.isWatchPondering):
        tb.setForegroundColor(fgMagenta, bright=true)
        if state.isPondering and state.isWatchPondering:
            tb.write(startX, y, &"[W pondering {state.ponderMove.toUCI()}, B pondering {state.watchPonderMove.toUCI()}]")
        elif state.isPondering:
            let side = if state.watchMode: "White" else: "Engine"
            tb.write(startX, y, &"[{side} PONDERING on {state.ponderMove.toUCI()}]")
        else:
            tb.write(startX, y, &"[Black PONDERING on {state.watchPonderMove.toUCI()}]")
    elif state.mode == ModePlay and state.engineThinking:
        tb.setForegroundColor(fgYellow, bright=true)
        if state.watchMode:
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
    elif state.boardSetupMode:
        tb.setForegroundColor(fgCyan, bright=true)
        tb.write(startX, y, "[BOARD SETUP]")
    elif state.analysisRunning:
        tb.setForegroundColor(fgGreen, bright=true)
        tb.write(startX, y, "[SEARCHING]")
    elif state.mode == ModePlay:
        case state.playPhase
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
    if state.chess960:
        tb.setForegroundColor(fgMagenta, bright=true)
        let variantStr = case state.variant
            of Standard: ""
            of FischerRandom: " [FRC]"
            of DoubleFischerRandom: " [DFRC]"
        if variantStr.len > 0:
            tb.write(indicatorX, y, variantStr)
            indicatorX += variantStr.len + 1
    if state.showThreats:
        tb.setForegroundColor(fgRed, bright=true)
        tb.write(indicatorX, y, "[Threats]")
        indicatorX += 10
    if state.mode != ModePlay and state.showEngineArrows:
        tb.setForegroundColor(fgGreen, bright=true)
        tb.write(indicatorX, y, "[Arrows]")
        indicatorX += 9
    if state.autoQueen:
        tb.setForegroundColor(fgYellow, bright=true)
        tb.write(indicatorX, y, "[Auto-queen]")
        indicatorX += 13
    if state.pendingPremoves.len > 0:
        let nextPremove = state.pendingPremoves[0]
        tb.setForegroundColor(fgBlue, bright=true)
        let premoveLabel =
            if state.pendingPremoves.len == 1:
                &" [Premove {nextPremove.fromSq.toUCI()}{nextPremove.toSq.toUCI()}]"
            else:
                &" [Premoves {state.pendingPremoves.len}, next {nextPremove.fromSq.toUCI()}{nextPremove.toSq.toUCI()}]"
        tb.write(indicatorX, y, premoveLabel)
        indicatorX += premoveLabel.len
    if state.boardSetupMode and state.boardSetupSpawnPiece.isSome():
        let piece = state.boardSetupSpawnPiece.get()
        tb.setForegroundColor(fgGreen, bright=true)
        tb.write(indicatorX, y, &" [Spawn {piece.toChar()}]")
    inc y

    if state.boardSetupMode:
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

        var line = ""
        var moveNum = 1
        for i, san in state.sanHistory:
            var token = ""
            if i mod 2 == 0:
                token = $moveNum & ". " & san
            else:
                token = san
                inc moveNum
            if line.len + token.len + 1 > width - 1:
                tb.setForegroundColor(fgWhite)
                tb.write(startX, y, line)
                inc y
                if y >= startY + height - 6:
                    break
                line = token & " "
            else:
                line &= token & " "

        if line.len > 0 and y < startY + height - 6:
            tb.setForegroundColor(fgWhite)
            tb.write(startX, y, line)
            inc y
        inc y

    # Analysis depth/nodes/nps (hidden during play mode)
    if state.mode != ModePlay and (state.analysisRunning or state.analysisLines.len > 0):
        infoLine("Depth:", $state.analysisDepth)
        infoLine("Nodes:", formatNodes(state.analysisNodes))
        infoLine("Speed:", formatSpeed(state.analysisNPS))

        # WDL for the primary line
        if state.analysisLines.len > 0 and state.analysisLines[0].pv.len > 0:
            let primaryLine = state.analysisLines[0]
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
        if state.analysisLines.len > 0:
            tb.setForegroundColor(fgCyan, bright=true)
            tb.write(startX, y, "Analysis Lines:")
            inc y

            let mat = state.board.material()
            for i, line in state.analysisLines:
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


    # PGN metadata (if in replay mode)
    if state.mode == ModeReplay and state.pgnTags.len > 0:
        inc y
        tb.setForegroundColor(fgCyan, bright=true)
        tb.write(startX, y, "PGN Info:")
        inc y, 2

        # Helper to find a tag value
        proc getTag(tags: seq[tuple[name, value: string]], tagName: string): string =
            for (n, v) in tags:
                if n.toLowerAscii() == tagName.toLowerAscii() and v.len > 0 and v != "?":
                    return v
            return ""

        # Players with Elo (name in white, elo in yellow)
        for side in ["White", "Black"]:
            let name = getTag(state.pgnTags, side)
            if name.len > 0:
                let elo = getTag(state.pgnTags, side & "Elo")
                tb.setForegroundColor(fgCyan)
                tb.write(startX, y, side & ":")
                tb.setForegroundColor(fgWhite, bright=true)
                tb.write(startX + labelCol, y, name)
                if elo.len > 0:
                    tb.setForegroundColor(fgYellow, bright=true)
                    tb.write(startX + labelCol + name.len, y, " (" & elo & ")")
                inc y

        # Other tags in blue
        const otherTags = ["Event", "Site", "Date", "Round", "Result",
                           "TimeControl", "ECO", "Opening"]
        for tagName in otherTags:
            if y >= startY + height - 6:
                break
            let value = getTag(state.pgnTags, tagName)
            if value.len > 0:
                let label = case tagName
                    of "TimeControl": "Time Ctrl:"
                    of "ECO": "ECO:"
                    else: tagName & ":"
                let maxVal = width - labelCol - 1
                let displayVal = if value.len > maxVal: value[0..<maxVal] else: value
                tb.setForegroundColor(fgCyan)
                tb.write(startX, y, label)
                tb.setForegroundColor(fgBlue, bright=true)
                tb.write(startX + labelCol, y, displayVal)
                inc y

        # Move counter
        infoLine("Moves:", &"{state.pgnMoveIndex}/{state.pgnMoves.len}")
        inc y

    # Game info and clocks (if in play mode)
    if state.mode == ModePlay and state.playPhase != Setup:
        inc y
        tb.setForegroundColor(fgCyan, bright=true)
        tb.write(startX, y, "Game:")
        inc y

        # Game details
        let variantStr = case state.variant
            of Standard: "Standard"
            of FischerRandom: "Chess960"
            of DoubleFischerRandom: "DFRC"
        infoLine("Variant:", variantStr)
        infoLine("TC:", state.gameTimeControl)
        if not state.watchMode:
            let sideStr = if state.playerColor == White: "White" else: "Black"
            infoLine("Playing:", sideStr)
        if state.allowTakeback:
            infoLine("Takeback:", "enabled")
        if state.allowPonder or state.watchPonder:
            if state.watchMode:
                let wStatus = if state.isPondering: &"on {state.ponderMove.toUCI()}"
                              elif state.allowPonder: "enabled"
                              else: "off"
                let bStatus = if state.isWatchPondering: &"on {state.watchPonderMove.toUCI()}"
                              elif state.watchPonder: "enabled"
                              else: "off"
                infoLine("W Ponder:", wStatus)
                infoLine("B Ponder:", bStatus)
            else:
                if state.isPondering:
                    infoLine("Ponder:", &"on {state.ponderMove.toUCI()}")
                else:
                    infoLine("Ponder:", "enabled")
        if state.gameResult.isSome():
            infoLine("Result:", state.gameResult.get())
        inc y

        # Clocks
        tb.setForegroundColor(fgCyan, bright=true)
        tb.write(startX, y, "Clocks:")
        inc y

        let whiteLabel = if state.watchMode: "Engine" elif state.playerColor == White: "You" else: "Engine"
        let blackLabel = if state.watchMode: "Engine" elif state.playerColor == Black: "You" else: "Engine"

        let whiteLimit =
            if state.watchMode:
                state.playerLimit
            elif state.playerColor == White:
                state.playerLimit
            else:
                state.engineLimit
        let blackLimit =
            if state.watchMode:
                state.engineLimit
            elif state.playerColor == Black:
                state.playerLimit
            else:
                state.engineLimit

        let wClock = if state.playerColor == White: state.playerClock else: state.engineClock
        let bClock = if state.playerColor == Black: state.playerClock else: state.engineClock

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


proc drawEvalBar(tb: var TerminalBuffer, state: AppState, boardX, boardY, boardHeight: int) =
    if state.mode == ModePlay:
        return

    let gutterWidth = boardX - BOARD_MARGIN_X
    if gutterWidth <= 0 or boardHeight <= 0:
        return

    let scoreY = boardY
    let barStartY = boardY + 1
    let barHeight = max(0, boardHeight - 1)
    let barX = BOARD_MARGIN_X + gutterWidth div 2
    let whiteAtTop = state.flipped

    var scoreText = "--"
    var whiteCells = barHeight div 2

    if state.analysisLines.len > 0:
        let primaryLine = state.analysisLines[0]
        scoreText = formatScore(primaryLine.score)
        whiteCells =
            if primaryLine.score.isMateScore():
                (if primaryLine.score > 0: barHeight else: 0)
            else:
                let cp = primaryLine.score.float
                let whiteRatio = 0.5 + 0.5 * (cp / (abs(cp) + 600.0))
                max(0, min(barHeight, int(whiteRatio * barHeight.float + 0.5)))

    if scoreText.len > gutterWidth:
        scoreText = scoreText[0..<gutterWidth]
    let scoreX = BOARD_MARGIN_X + max(0, (gutterWidth - scoreText.len) div 2)
    tb.setForegroundColor(fgWhite, bright=true)
    tb.write(scoreX, scoreY, scoreText)

    for i in 0..<barHeight:
        let isWhiteCell =
            if whiteAtTop:
                i < whiteCells
            else:
                i >= barHeight - whiteCells
        if isWhiteCell:
            tb.setForegroundColor(fgWhite, bright=true)
        else:
            tb.setForegroundColor(fgBlack, bright=true)
        tb.write(barX, barStartY + i, "\xe2\x96\x88")


proc drawInputBar(tb: var TerminalBuffer, state: AppState, startX, startY, width: int) =
    ## Draws the input bar at the bottom
    tb.setForegroundColor(fgYellow, bright=true)
    tb.setBackgroundColor(bgNone)
    tb.write(startX, startY, "> ")

    let modeStr = case state.mode
        of ModeAnalysis:
            if state.boardSetupMode: "[Board Setup]"
            elif state.analysisRunning: "[Analyzing]" else: "[Analysis]"
        of ModePlay:
            case state.playPhase
            of Setup: "[Setup]"
            of PlayerTurn: "[Your Turn]"
            of EngineTurn: "[Thinking]"
            of GameOver: "[Game Over]"
        of ModeReplay: "[Replay]"

    let inputStartX = startX + 2
    let modeX = startX + width - modeStr.len - 1
    let inputAreaWidth = max(1, modeX - inputStartX - 1)
    let visibleTextLen = max(0, inputAreaWidth - 1)  # Reserve one cell for the caret

    var showSuggestion = false
    var displayText = state.inputBuffer
    if state.acActive and state.acSelected.isSome() and state.acSelected.get() < state.acSuggestions.len:
        let suggestion = ":" & state.acSuggestions[state.acSelected.get()].cmd
        # Only show a ghost suggestion while the caret is at the end of the typed input.
        if state.inputCursorPos == state.inputBuffer.len and suggestion.startsWith(state.inputBuffer):
            showSuggestion = true
            displayText = suggestion

    let cursorPos = min(state.inputCursorPos, displayText.len)
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
            let typedVisibleLen = max(0, min(sliceText.len, state.inputBuffer.len - sliceStart))
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
    if not state.helpVisible:
        return

    let lines = buildHelpLines()
    let viewportHeight = helpViewportHeight(height)
    let maxScroll = max(0, lines.len - viewportHeight)
    let scroll = max(0, min(state.helpScroll, maxScroll))
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
    if not state.acActive or state.acSuggestions.len == 0:
        return

    let count = min(state.acSuggestions.len, 8)  # Max 8 visible suggestions

    # Compute description column based on longest command name
    var maxCmdLen = 0
    for i in 0..<count:
        maxCmdLen = max(maxCmdLen, state.acSuggestions[i].cmd.len)
    let descCol = maxCmdLen + 6  # 3 for "> :" prefix + 3 padding

    for i in 0..<count:
        let y = bottomY - count + i
        if y < 0: continue

        let (cmd, desc) = state.acSuggestions[i]
        let isSelected = state.acSelected.isSome() and i == state.acSelected.get()

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
    if state.statusMessage.len > 0 and getMonoTime() < state.statusExpiry:
        if state.statusIsError:
            tb.setForegroundColor(fgRed, bright=true)
        else:
            tb.setForegroundColor(fgYellow)
        tb.setBackgroundColor(bgNone)
        let msg = if state.statusMessage.len > width: state.statusMessage[0..<width] else: state.statusMessage
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


var
    prevW, prevH: int
    persistentTb: TerminalBuffer


proc render*(state: AppState) =
    ## Renders the complete TUI layout
    let
        w = terminalWidth()
        h = terminalHeight()

    # Recreate buffer only on resize; otherwise reuse to avoid
    # illwill doing a full redraw that wipes the kitty board image
    if persistentTb == nil or w != prevW or h != prevH:
        hideBoardImages()
        persistentTb = newTerminalBuffer(w, h)
        prevW = w
        prevH = h
        # Force board image retransmit after resize since illwill's
        # displayFull will overwrite the board area
        resetBoardHash()

    var tb = persistentTb

    let boardIsVisible = boardVisible(state)
    let boardX = boardStartX()
    let boardW = boardWidth(state)
    let boardH = boardHeight(state)
    let infoPanelX = boardX + boardW + BOARD_GAP_COLS
    let infoPanelWidth = min(max(INFO_PANEL_MIN_WIDTH, w - infoPanelX - 1), max(INFO_PANEL_PREFERRED_WIDTH, w - infoPanelX - 1))
    let infoPanelHeight = h - 4

    tb.setBackgroundColor(bgNone)
    tb.setForegroundColor(fgNone)
    for y in 0..<h:
        for x in 0..<w:
            if boardIsVisible and x >= boardX and x < boardX + boardW and y >= BOARD_MARGIN_Y and y < BOARD_MARGIN_Y + boardH:
                continue  # skip board area
            tb.write(x, y, " ")

    if not boardIsVisible:
        hideBoardImages()
        drawTooSmallOverlay(tb, state, w, h)
    else:
        drawEvalBar(tb, state, boardX, BOARD_MARGIN_Y, boardH)
        if state.helpVisible:
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
        displayBoard(state, BOARD_MARGIN_Y + 1, boardX + 1)
