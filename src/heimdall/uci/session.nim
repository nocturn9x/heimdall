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

## Handling of parsed UCI commands and the main UCI session loop

import heimdall/[board, search, movegen, transpositions, pieces as pcs, eval, nnue]
import heimdall/util/[perft, tunables, help, wdl, eval_stats, logs]
import heimdall/util/memory/aligned

import std/[os, math, times, atomics, options, terminal, strutils, strformat,
            sequtils, parseutils, exitprocs]
from std/lenientops import `/`

import noise

import heimdall/uci/[shared, parser, worker]


proc runPolicyEval(session: UCISession, evalState: EvalState, useColor: bool) =
    ## Treats the NNUE as a policy network: tries every legal move, statically
    ## evaluates the resulting position and prints the move that leaves us with
    ## the best score. No search is performed and no ponder move is given.
    if session.board.isGameOver():
        if not session.isMixedMode:
            stderr.writeLine("info string position is in terminal state (checkmate or draw)")
            echo "bestmove 0000"
        else:
            stdout.styledWrite(useColor, fgYellow, "Warning: position is in terminal state (checkmate or draw)\n")
        return
    var moves = newMoveList()
    session.board.generateMoves(moves)
    var
        bestMove = nullMove()
        bestScore = lowestEval()
    for move in moves:
        session.board.makeMove(move)
        evalState.init(session.board)  # Slow, but this is simple and correct
        # The eval is from the side-to-move's perspective: after our move
        # it's the opponent's turn, so we negate to get our own score
        let ourScore = -session.board.evaluate(evalState)
        session.board.unmakeMove()
        if bestMove == nullMove() or ourScore > bestScore:
            bestScore = ourScore
            bestMove = move
    let chess960 = session.searcher.state.chess960.load(moRelaxed)
    if bestMove.isCastling() and not chess960:
        # Hide the fact we're using FRC internally
        if bestMove.isLongCastling():
            bestMove.targetSquare = makeSquare(rank(bestMove.targetSquare), file(bestMove.targetSquare) + pcs.File(2))
        else:
            bestMove.targetSquare = makeSquare(rank(bestMove.targetSquare), file(bestMove.targetSquare) - pcs.File(1))
    if not session.isMixedMode:
        echo &"bestmove {bestMove.toUCI()}"
    else:
        stdout.styledWrite(useColor, fgGreen, "Best move (policy mode): ", styleBright, fgWhite, bestMove.toUCI(), "\n")


proc startUCISession* =
    ## Begins listening for UCI commands

    setControlCHook(proc () {.noconv.} = stderr.writeLine("info string SIGINT detected, exiting"); quit(0))
    var
        cmd: UCICommand
        cmdStr: string
        session = UCISession(hashTableSize: 64, board: newDefaultChessboard(), variations: 1, overhead: 250, isMixedMode: true)
        transpositionTable = allocHeapAligned(TranspositionTable, 64)
        searchWorker = session.createSearchWorker()
        # Used for the StaticEval command so we don't mess with the eval
        # state of the searcher. The owner keeps the huge-page-backed state
        # alive for the lifetime of the UCI loop; evalState is a borrowed handle
        evalStateOwner = newEvalState(verbose=false)
        evalState = evalStateOwner.raw
        searchWorkerThread: Thread[UCISearchWorker]
        firstSearch = false

    # Start search worker
    createThread(searchWorkerThread, searchWorkerLoop, searchWorker)
    transpositionTable[] = newTranspositionTable(session.hashTableSize * 1024 * 1024, session.workers + 1)
    transpositionTable.init(session.workers + 1)
    session.searcher = newSearchManager(session.board.positions, transpositionTable)

    let
        isTTY = isatty(stdout)
        useColor = not existsEnv("NO_COLOR")
        funnyESC = existsEnv("FUNNY_ESC")
        noLogo = existsEnv("NO_LOGO")

    session.useColor = useColor

    stdout.styledWrite(useColor, fgCyan, &"{getVersionString()} by nocturn9x (see LICENSE)\n")

    if not isTTY or existsEnv("NO_TUI"):
        session.isMixedMode = false
        session.searcher.setUCIMode(true)

    if isTTY and useColor:
        enableTrueColors()
        addExitProc(disableTrueColors)
        addExitProc(proc () = stdout.resetAttributes())

    session.searcher.logger.setColor(useColor)

    if not noLogo:
        printLogo(useColor)

    var noise = Noise.init()
    let prompt = block:
        if not useColor:
            Styler.init("cmd> ")
        else:
            Styler.init(fgYellow, "cmd> ")

    noise.setPrompt(prompt)

    while true:
        try:
            let smartPrompt = session.isMixedMode and (not session.searcher.isSearching() or session.minimal)
            if smartPrompt:
                var ok = noise.readLine()
                if not ok:
                    raise newException(IOError, "")

                if noise.getKeyType == ktEsc:
                    const prompts = ["Are you sure you want to exit (press enter to confirm)?", "'ight, just checking... are you really sure?",
                                     "Are you super duper sure?!"]
                    const responses = ["Thought so, punk!", "OwO I knew it", "Why did you say yes twice then!??"]
                    const promptColors = [fgRed, fgMagenta, fgCyan]
                    const colors = [fgCyan, fgMagenta, fgRed]

                    let count = if funnyESC: prompts.high() else: 0

                    var confirmed = [false, false, false]
                    for i in 0..count:
                        let exitPrompt = block:
                            if not useColor:
                                Styler.init(&"{prompts[i]} [Y/n] ")
                            else:
                                Styler.init(promptColors[i], prompts[i], resetStyle, styleDim, " [Y/n] ")

                        noise.setPrompt(exitPrompt)

                        ok = noise.readLine()
                        if not ok:
                            raise newException(IOError, "")

                        if noise.getLine().toLowerAscii() notin ["n", "no", "nope", "nyet", "nein", "non"]: # lul
                            confirmed[i] = true
                        else:
                            break

                    if count == 0 and confirmed[0]:
                        quit(0)
                    else:
                        for i in 0..count:
                            if not confirmed[i]:
                                if not useColor:
                                    echo responses[i]
                                else:
                                    styledWrite stdout, useColor, colors[i], responses[i], "\n"
                                break
                        if allIt(confirmed, it):
                            styledWrite stdout, useColor, fgBlue, styleBright, "You have no power here.\n"
                            styledWrite stdout, useColor, styleDim, fgBlue, "(You kinda did this to yourself: you can still press Ctrl+C/Ctrl+D if you", styleBright, " really ", resetStyle, styleDim, fgBlue, "wanna exit)\n"

                    noise.setPrompt(prompt)
                    continue

                cmdStr = noise.getLine()
            else:
                cmdStr = readLine(stdin)
            if smartPrompt:
                noise.historyAdd(cmdStr)
            cmdStr = cmdStr.strip(leading=true, trailing=true, chars={'\t', ' '})
            if cmdStr.len() == 0:
                if session.debug:
                    echo "info string received empty input, ignoring it"
                continue
            cmd = session.parseUCICommand(cmdStr)
            if session.debug:
                echo &"info string received command '{cmdStr}' -> {cmd}"
            if cmd.kind == Unknown:
                if not session.isMixedMode:
                    if cmd.reason.len() > 0:
                        stderr.writeLine(&"info string error: received unknown or invalid command '{cmdStr}' -> {cmd.reason}")
                    else:
                        stderr.writeLine(&"info string error: received unknown or invalid command '{cmdStr}'")
                else:
                    if cmd.reason.len() > 0:
                        stderr.styledWrite(useColor, fgRed, "Error: received unknown or invalid command ", fgWhite, styleBright, cmdStr, resetStyle, fgRed, " -> ", fgYellow, &"{cmd.reason}\n")
                    else:
                        stderr.styledWrite(useColor, fgRed, "Error: received unknown or invalid command ", styleBright, fgWhite, cmdStr, "\n")
                continue
            case cmd.kind:
                of Uci:
                    echo &"id name {getVersionString()}"
                    echo "id author Nocturn9x (see LICENSE)"
                    echo "option name HClear type button"
                    echo "option name TTClear type button"
                    echo "option name Ponder type check default false"
                    echo "option name Minimal type check default false"
                    echo "option name UCI_ShowWDL type check default false"
                    echo "option name DatagenMode type check default false"
                    echo "option name UseSoftNodes type check default false"
                    echo "option name UCI_Chess960 type check default false"
                    echo "option name EvalFile type string default <default>"
                    echo "option name NormalizeScore type check default true"
                    echo "option name EnableWeirdTCs type check default false"
                    echo "option name MultiPV type spin default 1 min 1 max 218"
                    echo "option name Threads type spin default 1 min 1 max 1024"
                    echo "option name RandomizeSoftLimit type check default false"
                    echo "option name Contempt type spin default 0 min 0 max 3000"
                    echo "option name Hash type spin default 64 min 1 max 33554432"
                    echo "option name MoveOverhead type spin default 250 min 0 max 30000"
                    echo "option name HardNodeLimit type spin default 1000000 min 0 max 4294967296"
                    echo "option name SoftNodeRandomLimit type spin default 0 min 0 max 4294967296"
                    when isTuningEnabled:
                        for param in getParameters():
                            echo &"option name {param.name} type spin default {param.default} min {param.min} max {param.max}"
                    echo "uciok"
                    session.searcher.setUCIMode(true)
                    session.isMixedMode = false
                of Simple:
                    if not session.isMixedMode:
                        echo "info string this command is disabled while in UCI mode, send icu to revert to mixed mode"
                        continue
                    case cmd.simpleCmd:
                        of GetStats:
                            printEvalStats(cmd.arg)
                        of Help:
                            # TODO: Handle submenus, colored output, etc.
                            echo HELP_TEXT
                        of Attackers:
                            try:
                                let attackers = session.board.position.attackers(cmd.arg.toSquare(checked=true), session.board.sideToMove.opposite())
                                stdout.styledWrite(useColor, fgGreen, "Bitboard of enemy pieces attacking ", fgWhite, styleBright, cmd.arg , "\n",
                                                   $attackers, "\n")
                            except ValueError:
                                stderr.styledWrite(useColor, fgRed, "Error: invalid square ", fgWhite, styleBright, cmd.arg, resetStyle, fgRed, " -> ", fgYellow, getCurrentExceptionMsg(), "\n")
                                continue
                        of Defenders:
                            try:
                                let attackers = session.board.position.attackers(cmd.arg.toSquare(checked=true), session.board.sideToMove)
                                stdout.styledWrite(useColor, fgGreen, "Bitboard of friendly pieces defending ", fgWhite, styleBright, cmd.arg, "\n",
                                                   $attackers, "\n")
                            except ValueError:
                                stderr.styledWrite(useColor, fgRed, "Error: invalid square ", fgWhite, styleBright, cmd.arg, resetStyle, fgRed, " -> ", fgYellow, getCurrentExceptionMsg(), "\n")
                                continue
                        of GetPiece:
                            try:
                                let piece = session.board.on(cmd.arg)
                                let pieceStr = block:
                                    if piece == nullPiece():
                                        ""
                                    else:
                                        &"{piece.color} {($piece.kind).toLowerAscii()}"
                                if pieceStr == "":
                                    stdout.styledWrite(useColor, fgGreen, "There is no piece on ", fgWhite, styleBright, cmd.arg, "\n")
                                else:
                                    stdout.styledWrite(useColor, fgGreen, "Piece on ", fgWhite, styleBright, cmd.arg, resetStyle, fgGreen, ": ", fgWhite, styleBright, pieceStr, "\n")
                            except ValueError:
                                stderr.styledWrite(useColor, fgRed, "Error: invalid square ", fgWhite, styleBright, cmd.arg, "\n")
                                continue
                        of MakeMove:
                            let r = session.parseUCIMove(session.board.position, cmd.arg)
                            if r.move == nullMove():
                                stderr.styledWrite(useColor, fgRed, "Error: move ", styleBright, fgWhite, cmd.arg, resetStyle, fgRed, " is invalid -> ", fgYellow, r.command.reason, "\n")
                                continue
                            else:
                                if not session.board.isLegal(r.move):
                                    stderr.styledWrite(useColor, fgRed, "Error: move ", styleBright, fgWhite, cmd.arg, resetStyle, fgRed, " is illegal\n")
                                else:
                                    session.board.doMove(r.move)
                                    stdout.styledWrite(useColor, fgWhite, styleBright, cmd.arg, resetStyle, fgGreen, " was played on the board\n")
                        of DumpNet:
                            stdout.styledWrite(useColor, fgGreen, "Dumping built-in network ", fgWhite, styleBright, NET_ID, resetStyle, fgGreen, " to ", styleBright, fgWhite, cmd.arg, "\n")
                            dumpVerbatimNet(cmd.arg, network)
                of Bare:
                    if not session.isMixedMode and cmd.bareCmd notin [Wait, Icu, Barbecue]:
                        echo "info string this command is disabled while in UCI mode, send icu to revert to mixed mode"
                        continue
                    case cmd.bareCmd:
                        of Icu:
                            echo "koicu"
                            session.isMixedMode = true
                            session.searcher.setUCIMode(false)
                        of Wait:
                            if session.isInfiniteSearch:
                                if session.isMixedMode:
                                    stderr.styledWrite(useColor, fgRed, "Error: cannot wait for infinite search\n")
                                else:
                                    stderr.writeLine("info string error: cannot wait for infinite search")
                                continue
                            if session.searcher.isSearching():
                                searchWorker.waitFor(SearchComplete)
                        of Barbecue:
                            echo "info string just tell me the date and time..."
                        of Clear:
                            echo "\x1Bc"
                        of NullMove:
                            if session.board.position.fromNull:
                                stdout.styledWrite(useColor, fgGreen, "Unmaking null move\n")
                                session.board.unmakeMove()
                            else:
                                stdout.styledWrite(useColor, fgGreen, "Making null move\n")
                                session.board.makeNullMove()
                        of SideToMove:
                            styledWrite stdout, useColor, fgGreen, "Side to move: ", styleBright, fgWhite, $session.board.sideToMove, resetStyle, "\n"
                        of EnPassant:
                            let target = block:
                                let t = session.board.position.enPassantSquare
                                if t != nullSquare():
                                    t.toUCI()
                                else:
                                    "None"
                            stdout.styledWrite(useColor, fgGreen, "En passant target: ", styleBright, fgWhite, target, resetStyle, "\n")
                        of CastlingRights:
                            let
                                castleRights = session.board.position.castlingAvailability[session.board.sideToMove]
                                canCastle = session.board.canCastle()
                                kingSide = if castleRights.king != nullSquare(): castleRights.king.toUCI() else: "None"
                                queenSide = if castleRights.queen != nullSquare(): castleRights.queen.toUCI() else: "None"
                                canKingSide = if canCastle.king != nullSquare(): "yes" else: "no"
                                canQueenSide = if canCastle.queen != nullSquare(): "yes" else: "no"
                            stdout.styledWrite(useColor, fgGreen, "Castling targets for ", styleBright, fgWhite, ($session.board.sideToMove).toLowerAscii(), resetStyle, fgGreen, ":\n  - ", fgRed, "King side: ", styleBright, fgWhite, kingSide, resetStyle, fgGreen, "\n  - ", fgBlue, "Queen side: ", styleBright, fgWhite, queenSide, resetStyle, "\n")
                            stdout.styledWrite(useColor, fgGreen, styleBright, fgWhite, $session.board.sideToMove, resetStyle, fgGreen, " can currently castle:\n  - ", fgRed, "King side: ", styleBright, fgWhite, canKingSide, resetStyle, fgGreen, "\n  - ", fgBlue, "Queen side: ", styleBright, fgWhite, canQueenSide, resetStyle, "\n")
                        of InCheck:
                            stdout.styledWrite(useColor, fgGreen, $session.board.sideToMove, " king in check: ", styleBright, fgWhite, (if session.board.inCheck(): "yes" else: "no"), resetStyle, "\n")
                        of Checkers:
                            stdout.styledWrite(useColor, fgGreen, "Pieces checking the ", styleBright, fgWhite, ($session.board.sideToMove).toLowerAscii(), resetStyle, fgGreen, " king:\n", styleBright, fgWhite, $session.board.position.checkers, resetStyle, "\n")
                        of UnmakeMove:
                            if session.board.positions.len() == 1:
                                stdout.styledWrite(useColor, fgGreen, "No move to undo\n")
                            else:
                                session.board.unmakeMove()
                        of Repeated:
                            stdout.styledWrite(useColor, fgGreen, "Position is drawn by repetition: ", styleBright, fgWhite, if session.board.drawnByRepetition(0): "yes" else: "no", resetStyle, "\n")
                        of StaticEval:
                            evalState.init(session.board)  # Slow, but this is simple and correct
                            let rawEval = session.board.evaluate(evalState)
                            stdout.styledWrite(useColor, fgGreen, "Raw eval: ", styleBright, fgWhite, $rawEval, resetStyle, fgGreen, " engine units\n")
                            stdout.styledWrite(useColor, fgRed, "Normalized eval: ", styleBright, fgWhite, $rawEval.normalizeScore(session.board.material()), resetStyle, fgMagenta, " cp\n")
                        of PrintFEN:
                            let fen = session.board.position.toFEN(session.searcher.state.chess960.load())
                            stdout.styledWrite(useColor, fgGreen, "FEN of the current position: ", styleBright, fgWhite, fen, resetStyle, "\n")
                        of PrintASCII:
                            echo $session.board
                        of PrettyPrint:
                            echo session.board.pretty()
                        of ZobristKey:
                            stdout.styledWrite(useColor, fgGreen, "Current Zobrist key: ", styleBright, fgWhite, "0x", session.board.zobristKey.uint64.toHex().toLowerAscii(), resetStyle, fgGreen, " (", styleBright, fgWhite, $session.board.zobristKey, resetStyle, fgGreen, ")\n")
                        of PawnKey:
                            stdout.styledWrite(useColor, fgGreen, "Current pawn Zobrist key: ", styleBright, fgWhite, "0x", session.board.pawnKey.uint64.toHex().toLowerAscii(), resetStyle, fgGreen, " (", styleBright, fgWhite, $session.board.pawnKey, resetStyle, fgGreen, ")\n")
                        of MajorKey:
                            stdout.styledWrite(useColor, fgGreen, "Current major piece Zobrist key: ", styleBright, fgWhite, "0x", session.board.majorKey.uint64.toHex().toLowerAscii(), resetStyle, fgGreen, " (", styleBright, fgWhite, $session.board.majorKey, resetStyle, fgGreen, ")\n")
                        of MinorKey:
                            stdout.styledWrite(useColor, fgGreen, "Current minor piece Zobrist key: ", styleBright, fgWhite, "0x", session.board.minorKey.uint64.toHex().toLowerAscii(), resetStyle, fgGreen, " (", styleBright, fgWhite, $session.board.minorKey, resetStyle, fgGreen, ")\n")
                        of NonpawnKeys:
                            stdout.styledWrite(useColor, fgGreen, "Current nonpawn piece Zobrist key for ", styleBright, fgWhite, "white", resetStyle, fgGreen, ": ", styleBright, fgWhite, "0x", session.board.nonpawnKey(White).uint64.toHex().toLowerAscii(), resetStyle, fgGreen, " (", styleBright, fgWhite, $session.board.nonpawnKey(White), resetStyle, fgGreen, ")\n")
                            stdout.styledWrite(useColor, fgGreen, "Current nonpawn piece Zobrist key for ", styleBright, fgWhite, "black", resetStyle, fgGreen, ": ", styleBright, fgWhite, "0x", session.board.nonpawnKey(Black).uint64.toHex().toLowerAscii(), resetStyle, fgGreen, " (", styleBright, fgWhite, $session.board.nonpawnKey(Black), resetStyle, fgGreen, ")\n")
                        of GameStatus:
                            stdout.styledWrite(useColor, fgGreen, "Current game status: ")
                            if session.board.isStalemate():
                                stdout.styledWrite(useColor, styleBright, fgWhite, "drawn by stalemate", resetStyle, "\n")
                            elif session.board.drawnByRepetition(0):
                                stdout.styledWrite(useColor, styleBright, fgWhite, "drawn by repetition", resetStyle, "\n")
                            elif session.board.isDrawn(0):
                                stdout.styledWrite(useColor, styleBright, fgWhite, "drawn", resetStyle, "\n")
                            elif session.board.isCheckmate():
                                let winner = session.board.sideToMove.opposite()
                                stdout.styledWrite(useColor,  styleBright, fgWhite, $winner, resetStyle, fgGreen, " wins by checkmate \n")
                            else:
                                stdout.styledWrite(useColor, styleBright, fgWhite, "in progress", resetStyle, "\n")
                        of Threats:
                            stdout.styledWrite(useColor, fgGreen, "Squares threathened by ", styleBright, fgWhite, ($session.board.sideToMove.opposite()).toLowerAscii(), resetStyle, fgGreen, " in the current position:\n", styleBright, fgWhite, $session.board.position.threats, resetStyle, "\n")
                        of Material:
                            stdout.styledWrite(useColor, fgGreen, "Material currently on the board: ", styleBright, fgWhite, $session.board.material(), resetStyle, fgGreen, " points\n")
                        of InputBucket:
                            let kingSq = session.board.position.kingSquare(session.board.sideToMove)
                            stdout.styledWrite(useColor, fgGreen, "Current king input bucket for ", styleBright, fgWhite, $session.board.sideToMove, resetStyle, fgGreen, ": ", styleBright, fgWhite, $kingBucket(session.board.sideToMove, kingSq), resetStyle, "\n")
                        of OutputBucket:
                            const divisor = 32 div NUM_OUTPUT_BUCKETS
                            let outputBucket = (session.board.pieces().count() - 2) div divisor
                            stdout.styledWrite(useColor, fgGreen, "Current output bucket: ", styleBright, fgWhite, $outputBucket, resetStyle, "\n")
                        of PrintNetName:
                            stdout.styledWrite(useColor, fgGreen, "ID of the built-in network: ", styleBright, fgWhite, NET_ID, resetStyle, "\n")
                        of PinnedPieces:
                            stdout.styledWrite(useColor, fgGreen, "Bitboard of orthogonally pinned pieces:\n", styleBright, fgWhite, $session.board.position.orthogonalPins, resetStyle, "\n")
                            stdout.styledWrite(useColor, fgGreen, "Bitboard of diagonally pinned pieces:\n", styleBright, fgWhite, $session.board.position.diagonalPins, resetStyle, "\n")
                of Quit:
                    if session.searcher.isSearching():
                        session.searcher.cancel()
                    searchWorker.sendAction(simpleCmd(Exit))
                    var workerResp = searchWorker.channels.send.recv()
                    # One or more searches were completed before and their messages were not dequeued yet
                    if workerResp != Exiting:
                        while true:
                            doAssert workerResp == SearchComplete, $workerResp
                            workerResp = searchWorker.getResponse()
                            if workerResp != SearchComplete:
                                break
                    doAssert workerResp == Exiting, $workerResp
                    searchWorker.channels.receive.close()
                    searchWorker.channels.send.close()
                    quit(0)
                of IsReady:
                    echo "readyok"
                of Debug:
                    session.debug = cmd.on
                of NewGame:
                    if session.searcher.isSearching():
                        if session.isMixedMode:
                            stderr.styledWriteLine("Error: cannot start a new game while searching")
                        else:
                            stderr.writeLine("info string error: cannot start a new game while searching")
                        continue
                    if session.debug:
                        echo &"info string clearing out TT of size {session.hashTableSize} MiB"
                    transpositionTable.init(session.workers + 1)
                    session.searcher.histories.clear()
                    # Since each worker thread has their own copy of the heuristics, which they keep using once started,
                    # we have to reset the thread pool as well
                    session.searcher.resetWorkers()
                of PonderHit:
                    if session.debug:
                        echo "info string ponder move has ben hit"
                    if not session.searcher.isSearching():
                        continue
                    session.searcher.stopPondering()
                    if session.debug:
                        echo "info string switched to normal search"
                of Go:
                    # A one-node search can't return anything meaningful, so we treat
                    # 'go nodes 1' as a request to run the NNUE as a policy network
                    let policyFallback = not cmd.eval and cmd.nodes.isSome() and cmd.nodes.get() == 1'u64
                    if policyFallback:
                        if session.isMixedMode:
                            stdout.styledWrite(useColor, fgYellow, "Warning: 'go nodes 1' falls back to policy mode ('go eval')\n")
                        else:
                            echo "info string 'go nodes 1' falls back to policy mode ('go eval')"
                    if cmd.eval or policyFallback:
                        # Treat the NNUE as a policy network: try every legal move,
                        # statically evaluate the resulting position and pick the move
                        # that leaves us with the best score
                        session.runPolicyEval(evalState, useColor)
                    elif cmd.perft.isSome():
                        let perftInfo = cmd.perft.get()
                        if perftInfo.bulk:
                            let t = cpuTime()
                            let nodes = session.board.perft(perftInfo.depth, divide=perftInfo.divide, bulk=true, verbose=perftInfo.verbose, capturesOnly=perftInfo.capturesOnly).nodes
                            let tot = cpuTime() - t
                            if perftInfo.divide:
                                echo ""
                            stdout.styledWrite(useColor, fgGreen, "Nodes searched (bulk-counting: off): ", styleBright, fgWhite, $nodes, resetStyle, "\n")
                            stdout.styledWrite(useColor, fgGreen, "Time taken: ", styleBright, fgWhite, &"{tot:.3f}", resetStyle, fgGreen, " seconds\nNodes per second: ", styleBright, fgWhite, $round(nodes / tot).uint64, resetStyle, "\n")
                        else:
                            let t = cpuTime()
                            let data = session.board.perft(perftInfo.depth, divide=perftInfo.divide, bulk=false, verbose=perftInfo.verbose, capturesOnly=perftInfo.capturesOnly)
                            let tot = cpuTime() - t
                            if perftInfo.divide:
                                stdout.styledWrite(useColor, "\n")
                            stdout.styledWrite(useColor, fgGreen, "Nodes searched (bulk-counting: off): ", styleBright, fgWhite, $data.nodes, resetStyle, "\n")
                            stdout.styledWrite(useColor, fgGreen, "  - Captures: ", styleBright, fgWhite, $data.captures, resetStyle, "\n")
                            stdout.styledWrite(useColor, fgGreen, "  - Checks: ", styleBright, fgWhite, $data.checks, resetStyle, "\n")
                            stdout.styledWrite(useColor, fgGreen, "  - E.P: ", styleBright, fgWhite, $data.enPassant, resetStyle, "\n")
                            stdout.styledWrite(useColor, fgGreen, "  - Checkmates: ", styleBright, fgWhite, $data.checkmates, resetStyle, "\n")
                            stdout.styledWrite(useColor, fgGreen, "  - Castles: ", styleBright, fgWhite, $data.castles, resetStyle, "\n")
                            stdout.styledWrite(useColor, fgGreen, "  - Promotions: ", styleBright, fgWhite, $data.promotions, resetStyle, "\n")
                            stdout.styledWrite(useColor, "\n")
                            stdout.styledWrite(useColor, fgGreen, "Time taken: ", styleBright, fgWhite, &"{tot:.3f}", resetStyle, fgGreen, " seconds\nNodes per second: ", styleBright, fgWhite, $round(data.nodes / tot).uint64, resetStyle, "\n")
                    else:
                        session.isInfiniteSearch = cmd.infinite
                        if session.searcher.isSearching():
                            # Search already running. Let's teach the user a lesson
                            session.searcher.cancel()
                            searchWorker.waitFor(SearchComplete)
                            if not session.isMixedMode:
                                echo "info string premium membership is required to send go during search. Please check out https://n9x.co/heimdall-premium for details"
                            else:
                                stdout.styledWrite(useColor, fgYellow, "Warning: premium membership is required to send go during search. Please check out https://n9x.co/heimdall-premium for details\n")
                            continue
                        if session.board.isGameOver():
                            if not session.isMixedMode:
                                stderr.writeLine("info string position is in terminal state (checkmate or draw)")
                                echo "bestmove 0000"
                            else:
                                stdout.styledWrite(useColor, fgYellow, "Warning: position is in terminal state (checkmate or draw)\n")
                            continue
                        if not firstSearch:
                            firstSearch = true
                        else:
                            transpositionTable.birthday()
                        # Start the clock as soon as possible to account
                        # for startup delays in our time management
                        session.searcher.startClock()
                        # Publish the "searching" flag synchronously here, before we
                        # hand the search off to the (asynchronous) search worker
                        # thread and loop back to reading stdin. Otherwise there is a
                        # window where the next command (e.g. ucinewgame or a Threads
                        # change) sees searching=false and mutates/drives the worker
                        # pool concurrently with the search, desyncing the protocol.
                        session.searcher.markSearching()
                        searchWorker.channels.receive.send(WorkerCommand(kind: Search, command: cmd))
                        if session.debug:
                            echo "info string search started"
                        if session.isMixedMode:
                            # Give the search worker ~1ms to start searching
                            # so we don't print the prompt right before it has
                            # a chance to start (it's ugly)
                            sleep(1)
                of Stop:
                    if session.searcher.isSearching():
                        session.searcher.cancel()
                        searchWorker.waitFor(SearchComplete)
                    if session.isMixedMode:
                        # Same as above: give time for the search to actually stop
                        sleep(1)
                    if session.debug:
                        echo "info string search stopped"
                of SetOption, Set:
                    if session.searcher.isSearching():
                        # Cannot set options during search: changing options like the
                        # thread count or clearing histories mutates the worker pool,
                        # which must never happen concurrently with an in-flight search
                        # (it desyncs the worker request/response protocol). Skip the
                        # command entirely instead of falling through.
                        if session.isMixedMode:
                            stderr.styledWrite(useColor, fgRed, "Error: cannot set options while searching\n")
                        else:
                            stderr.writeLine("info string error: cannot set options while searching")
                        continue
                    let
                        # UCI mandates that names and values are not to be case sensitive
                        name = cmd.name.toLowerAscii()
                        value = cmd.value.toLowerAscii()
                    if cmd.kind == Set:
                        if not session.isMixedMode:
                            echo "info string this command is disabled while in UCI mode, send icu to revert to mixed mode"
                            continue
                    case name:
                        of "multipv":
                            session.variations = value.parseInt()
                            doAssert session.variations > 0 and session.variations < 219
                        of "enableweirdtcs":
                            doAssert value in ["true", "false"]
                            session.enableWeirdTCs = value == "true"
                            if session.enableWeirdTCs:
                                echo "info string By enabling this option, you acknowledge that you are stepping into uncharted territory. Proceed at your own risk!"
                        of "hash":
                            var newSize: BiggestUInt
                            if session.isMixedMode:
                                try:
                                    newSize = value.parseBiggestUInt()
                                except ValueError:
                                    var size: int64
                                    var readBytes = value.parseSize(size)
                                    if readBytes != len(value):
                                        stdout.styledWrite(fgRed, "Error: Malformed hash table size", styleBright, fgWhite, cmd.value, "\n")
                                        continue
                                    newSize = size.uint64 div 1048576
                                    styledWrite(stdout, useColor, fgYellow, &"Note: ", styleBright, fgWhite, cmd.value, resetStyle, fgGreen, " interpreted as ",
                                                styleBright, fgWhite, $newSize, resetStyle, fgGreen, " MiB\n")
                                    if newSize notin 1'u64..33554432'u64:
                                        stdout.styledWrite(fgRed, "Error: selected hash table size", styleBright, fgWhite, $newSize, resetStyle, fgRed, "is not valid (n must be in 1 <= n <= 33554432 MiB)\n")
                                        continue
                            else:
                                newSize = value.parseBiggestUInt()
                            doAssert newSize in 1'u64..33554432'u64
                            if newSize != transpositionTable.size():
                                if session.debug:
                                    echo &"info string resizing TT from {session.hashTableSize} MiB To {newSize} MiB"
                                if transpositionTable.resize(newSize * 1048576, session.workers + 1):
                                    session.hashTableSize = newSize
                                else:
                                    echo &"info string failed to resize TT to {newSize} MiB"
                            if session.debug:
                                echo &"info string set TT hash table size to {session.hashTableSize} MiB"
                        of "ttclear":
                            if session.debug:
                                echo "info string clearing TT"
                            transpositionTable.init(session.workers + 1)
                        of "hclear":
                            if session.debug:
                                echo "info string clearing history tables"
                            session.searcher.histories.clear()
                            session.searcher.resetWorkers()
                        of "threads":
                            let numWorkers = value.parseInt()
                            doAssert numWorkers in 1..1024
                            if session.debug:
                                echo &"info string set thread count to {numWorkers}"
                            session.workers = numWorkers - 1
                            session.searcher.setWorkerCount(session.workers)
                            if transpositionTable.distributes():
                                transpositionTable.init(session.workers + 1)
                        of "uci_chess960":
                            doAssert value in ["true", "false"]
                            let enabled = value == "true"
                            session.searcher.state.chess960.store(enabled, moRelaxed)
                            if session.debug:
                                echo &"info string Chess960 mode: {enabled}"
                        of "evalfile":
                            if session.debug:
                                echo &"info string loading net at {cmd.value}"
                            if value == "<default>":
                                session.searcher.setNetwork("")
                            else:
                                # Paths *are* case sensitive. Sorry UCI
                                session.searcher.setNetwork(cmd.value)
                        of "moveoverhead":
                            let overhead = value.parseInt()
                            doAssert overhead in 0..30000
                            session.overhead = overhead
                            if session.debug:
                                echo &"info string set move overhead to {overhead}"
                        of "ponder":
                            doAssert value in ["true", "false"]
                            let enabled = value == "true"
                            session.canPonder = enabled
                            if session.debug:
                                echo &"info string pondering: {enabled}"
                        of "normalizescore":
                            doAssert value in ["true", "false"]
                            let enabled = value == "true"
                            session.searcher.state.normalizeScore.store(enabled, moRelaxed)
                            if session.debug:
                                echo &"info string normalizing displayed scores: {enabled}"
                        of "uci_showwdl":
                            doAssert value in ["true", "false"]
                            let enabled = value == "true"
                            session.searcher.state.showWDL.store(enabled, moRelaxed)
                            if session.debug:
                                echo &"info string showing wdl: {enabled}"
                        of "minimal":
                            doAssert value in ["true", "false"]
                            let enabled = value == "true"
                            session.minimal = enabled
                            if session.debug:
                                echo &"info string printing minimal logs: {enabled}"
                        of "contempt":
                            let contempt = value.parseInt()
                            doAssert contempt in 0..3000
                            session.searcher.setContempt(contempt.int32)
                            if session.debug:
                                echo &"info string set contempt to {contempt}"
                        of "datagenmode":
                            doAssert value in ["true", "false"]
                            let enabled = value == "true"
                            session.datagenMode = enabled
                            if session.debug:
                                echo &"info string using datagen mode: {enabled}"
                        of "usesoftnodes":
                            doAssert value in ["true", "false"]
                            let enabled = value == "true"
                            session.useSoftNodes = enabled
                            if session.debug:
                                echo &"info string using soft nodes: {enabled}"
                        of "hardnodelimit":
                            let value = value.parseInt()
                            doAssert value in 0..4294967296
                            session.hardNodeLimit = value
                            if session.debug:
                                echo &"info string set hard node limit to {value}"
                        of "randomizesoftlimit":
                            doAssert value in ["true", "false"]
                            let enabled = value == "true"
                            session.randomizeSoftNodes = enabled
                            if session.debug:
                                echo &"info string using soft node limit randomization: {enabled}"
                        of "softnoderandomlimit":
                            let value = value.parseInt()
                            doAssert value in 0..4294967296
                            session.softNodeRandomLimit = value
                            if session.debug:
                                echo &"info string set soft node randomization limit to {value}"
                        else:
                            when isTuningEnabled:
                                if cmd.name.isParamName():
                                    # Note: tunable parameters are case sensitive. Deal with it.
                                    session.searcher.setParameter(cmd.name, value.parseInt())
                                else:
                                    if session.isMixedMode:
                                        stderr.styledWrite(useColor, fgRed, "Error: no such option ", fgWhite, styleBright, cmd.name, "\n")
                                    else:
                                        stderr.writeLine(&"info string unknown option '{cmd.name}'")
                                    continue
                            else:
                                if session.isMixedMode:
                                    stderr.styledWrite(useColor, fgRed, "Error: no such option ", fgWhite, styleBright, cmd.name, "\n")
                                else:
                                    stderr.writeLine(&"info string unknown option '{cmd.name}'")
                                continue
                    if session.isMixedMode:
                        styledWrite stdout, useColor, fgGreen, "Set option ", fgWhite, styleBright, &"{cmd.name} ", resetStyle, fgGreen, "to ", fgWhite, styleBright, cmd.value, "\n"
                of Position:
                    # Nothing to do: the moves have already been parsed into
                    # session.history and they will be set as the searcher's
                    # board state once search starts
                    discard
                of Unknown:
                    # Already handled
                    discard
                of GetScale:
                    let scale = cmd.currAbsMean / cmd.newAbsMean * EVAL_SCALE.float64
                    styledWrite stdout, useColor, fgGreen, "Expected scaling factor: ", fgWhite, styleBright, &"{scale:.6f}\n"
        except IOError:
            if session.isMixedMode:
                stderr.styledWrite(useColor, fgRed, "Error: I/O error while reading from stdin, exiting\n")
            else:
                stderr.writeLine("info string I/O error while reading from stdin, exiting")
            quit(0)
        except EOFError:
            if session.isMixedMode:
                stderr.styledWrite(useColor, fgRed, "Error: EOF received while reading from stdin, exiting\n")
            else:
                stderr.writeLine("info string EOF received while reading from stdin, exiting")
            quit(0)
