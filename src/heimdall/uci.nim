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

## Implementation of a UCI compatible server
import std/os
import std/random
import std/atomics
import std/options
import std/terminal
import std/strutils
import std/strformat

randomize()


import heimdall/board
import heimdall/search
import heimdall/movegen
import heimdall/util/limits
import heimdall/util/aligned
import heimdall/util/tunables
import heimdall/transpositions


type
    UCISession = ref object
        ## A UCI session
        debug: bool
        # All reached positions
        history: seq[Position]
        # Information about the current search
        searcher: SearchManager
        # Size of the transposition table (in megabytes, and not the retarded kind!)
        hashTableSize: uint64
        # Number of (extra) workers to use during search alongside
        # the main search thread. This is always Threads - 1
        workers: int
        # Whether we allow the user to have heimdall play
        # with weird, untested time controls (i.e. increment == 0)
        enableWeirdTCs: bool
        # The number of principal variations to search
        variations: int
        # The move overhead
        overhead: int
        # Can we ponder?
        canPonder: bool
        # Do we print minimal logs? (only final depth)
        minimal: bool


    UCICommandType = enum
        ## A UCI command type enumeration
        Unknown,
        IsReady,
        NewGame,
        Quit,
        Debug,
        Position,
        SetOption,
        Go,
        Stop,
        PonderHit,
        Uci,
        # Revert to pretty-print
        Icu,
        Wait,
        Barbecue

    UCICommand = object
        ## A UCI command
        case kind: UCICommandType
            of Debug:
                on: bool
            of Position:
                fen: string
                moves: seq[string]
            of SetOption:
                name: string
                value: string
            of Unknown:
                reason: string
            of Go:
                infinite: bool
                wtime: Option[int]
                btime: Option[int]
                winc: Option[int]
                binc: Option[int]
                movesToGo: Option[int]
                depth: Option[int]
                moveTime: Option[int]
                nodes: Option[uint64]
                searchmoves: seq[Move]
                ponder: bool
                mate: Option[int]
            else:
                discard

    WorkerAction = enum
        Search, Exit
    WorkerCommand = object
        case kind: WorkerAction
            of Search:
                command: UCICommand
            else:
                discard
    WorkerResponse = enum
        Exiting, SearchComplete
    UCISearchWorker = ref object
        session: UCISession
        channels: tuple[receive: Channel[WorkerCommand], send: Channel[WorkerResponse]]


proc parseUCIMove(session: UCISession, position: Position, move: string): tuple[move: Move, command: UCICommand] =
    ## Parses a UCI move string into a move
    ## object, ensuring it is legal for the
    ## current position
    var
        startSquare: Square
        targetSquare: Square
        flags: seq[MoveFlag]
    if len(move) notin 4..5:
        return (nullMove(), UCICommand(kind: Unknown, reason: "invalid move syntax"))
    try:
        startSquare = move[0..1].toSquare()
    except ValueError:
        return (nullMove(), UCICommand(kind: Unknown, reason: &"invalid start square {move[0..1]}"))
    try:
        targetSquare = move[2..3].toSquare()
    except ValueError:
        return (nullMove(), UCICommand(kind: Unknown, reason: &"invalid target square {move[2..3]}"))
    
    # Since the client tells us just the source and target square of the move,
    # we have to figure out all the flags by ourselves (whether it's a double
    # push, a capture, a promotion, etc.)

    if position.getPiece(startSquare).kind == Pawn and abs(rankFromSquare(startSquare).int - rankFromSquare(targetSquare).int) == 2:
        flags.add(DoublePush)

    if len(move) == 5:
        # Promotion
        case move[4]:
            of 'b':
                flags.add(PromoteToBishop)
            of 'n':
                flags.add(PromoteToKnight)
            of 'q':
                flags.add(PromoteToQueen)
            of 'r':
                flags.add(PromoteToRook)
            else:
                return
    let piece = position.getPiece(startSquare)

    if position.getPiece(targetSquare).color == piece.color.opposite():
        flags.add(Capture)

    let canCastle = position.canCastle()
    # Note: the order in which we check the castling move IS important! Lichess
    # likes to think different and sends standard notation castling moves even
    # in chess960 mode, so we account for that here.

    # Support for standard castling notation
    if piece.kind == King and targetSquare in ["c1".toSquare(), "g1".toSquare(), "c8".toSquare(), "g8".toSquare()] and abs(fileFromSquare(startSquare).int - fileFromSquare(targetSquare).int) > 1:
        flags.add(Castle)
    if Castle notin flags and piece.kind == King and (targetSquare == canCastle.king or targetSquare == canCastle.queen):
        flags.add(Castle)
    if piece.kind == Pawn and targetSquare == position.enPassantSquare:
        # I hate en passant I hate en passant I hate en passant I hate en passant I hate en passant I hate en passant 
        flags.add(EnPassant)
    result.move = createMove(startSquare, targetSquare, flags)
    if result.move.isCastling() and position.getPiece(targetSquare).kind == Empty:
        if result.move.targetSquare < result.move.startSquare:
            result.move.targetSquare = makeSquare(rankFromSquare(result.move.targetSquare), fileFromSquare(result.move.targetSquare) - 2)
        else:
            result.move.targetSquare = makeSquare(rankFromSquare(result.move.targetSquare), fileFromSquare(result.move.targetSquare) + 1)


proc handleUCIMove(session: UCISession, board: Chessboard, moveStr: string): tuple[move: Move, cmd: UCICommand] {.discardable.} =
    ## Attempts to parse a move and performs it on the
    ## chessboard if it is legal
    if session.debug:
        echo &"info string making move {moveStr}"
    let 
        r = session.parseUCIMove(board.position, moveStr)
        move = r.move
        command = r.command
    if move == nullMove():
        return (move, command)
    else:
        if session.debug:
            echo &"info string {moveStr} parses to {move}"
        result.move = board.makeMove(move)


proc handleUCIGoCommand(session: UCISession, command: seq[string]): UCICommand =
    ## Handles the "go" UCI command
    result = UCICommand(kind: Go)
    var current = 1   # Skip the "go"
    while current < command.len():
        let flag = command[current]
        inc(current)
        case flag:
            of "infinite":
                result.infinite = true
            of "ponder":
                result.ponder = true
            of "wtime":
                result.wtime = some(command[current].parseInt())
            of "btime":
                result.btime = some(command[current].parseInt())
            of "winc":
                result.winc = some(command[current].parseInt())
            of "binc":
                result.binc = some(command[current].parseInt())
            of "movestogo":
                result.movesToGo = some(command[current].parseInt())
            of "depth":
                result.depth = some(command[current].parseInt())
            of "movetime":
                result.moveTime = some(command[current].parseInt())
            of "nodes":
                result.nodes = some(command[current].parseBiggestUInt().uint64)
            of "mate":
                result.mate = some(command[current].parseInt())
            of "searchmoves":
                while current < command.len():
                    if command[current] == "":
                        break
                    let move = session.parseUCIMove(session.history[^1], command[current]).move
                    if move == nullMove():
                        return UCICommand(kind: Unknown, reason: &"invalid move '{command[current]}' for searchmoves")
                    result.searchmoves.add(move)
                    inc(current)
            else:
                discard


proc handleUCIPositionCommand(session: var UCISession, command: seq[string]): UCICommand =
    ## Handles the "position" UCI command

    # Makes sure we don't leave the board in an invalid state if
    # some error occurs
    result = UCICommand(kind: Position)
    var chessboard: Chessboard
    case command[1]:
        of "startpos":
            result.fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
            chessboard = newChessboardFromFEN(result.fen)
            if command.len() > 2:
                let args = command[2..^1]
                if args.len() > 0:
                    var i = 0
                    while i < args.len():
                        case args[i]:
                            of "moves":
                                var j = i + 1
                                while j < args.len():
                                    let r = handleUCIMove(session, chessboard, args[j])
                                    if r.move == nullMove():
                                        if r.cmd.reason.len() > 0:
                                            return UCICommand(kind: Unknown, reason: &"move {args[j]} is illegal or invalid ({r.cmd.reason})")
                                        else:
                                            return UCICommand(kind: Unknown, reason: &"move {args[j]} is illegal or invalid")
                                    result.moves.add(args[j])
                                    inc(j)
                        inc(i)
        of "fen":
            var 
                args = command[2..^1]
                fenString = ""
                stop = 0
            for i, arg in args:
                if arg in ["moves", ]:
                    break
                if i > 0:
                    fenString &= " "
                fenString &= arg
                inc(stop)
            result.fen = fenString
            args = args[stop..^1]
            chessboard = newChessboardFromFEN(result.fen)
            if args.len() > 0:
                var i = 0
                while i < args.len():
                    case args[i]:
                        of "moves":
                            var j = i + 1
                            while j < args.len():
                                let r = handleUCIMove(session, chessboard, args[j])
                                if r.move == nullMove():
                                    if r.cmd.reason.len() > 0:
                                        return UCICommand(kind: Unknown, reason: &"move {args[j]} is illegal or invalid ({r.cmd.reason})")
                                    else:
                                        return UCICommand(kind: Unknown, reason: &"move {args[j]} is illegal or invalid")
                                result.moves.add(args[j])
                                inc(j)
                    inc(i)
        else:
            return UCICommand(kind: Unknown, reason: &"unknown subcomponent '{command[1]}'")
    session.history.setLen(0)
    for position in chessboard.positions:
        session.history.add(position.clone())


proc parseUCICommand(session: var UCISession, command: string): UCICommand =
    ## Attempts to parse the given UCI command
    var cmd = command.replace("\t", "").splitWhitespace()
    result = UCICommand(kind: Unknown)
    var current = 0
    while current < cmd.len():
        case cmd[current]:
            of "isready":
                return UCICommand(kind: IsReady)
            of "uci":
                return UCICommand(kind: Uci)
            of "icu":
                return UCICommand(kind: Icu)
            of "wait":
                return UCICommand(kind: Wait)
            of "stop":
                return UCICommand(kind: Stop)
            of "ucinewgame":
                return UCICommand(kind: NewGame)
            of "quit":
                return UCICommand(kind: Quit)
            of "ponderhit":
                return UCICommand(kind: PonderHit)
            of "debug":
                if current == cmd.high():
                    return
                case cmd[current + 1]:
                    of "on":
                        return UCICommand(kind: Debug, on: true)
                    of "off":
                        return UCICommand(kind: Debug, on: false)
                    else:
                        return
            of "position":
                return session.handleUCIPositionCommand(cmd)
            of "go":
                return session.handleUCIGoCommand(cmd)
            of "setoption":
                result = UCICommand(kind: SetOption)
                inc(current)
                while current < cmd.len():
                    case cmd[current]:
                        of "name":
                            inc(current)
                            result.name = cmd[current]
                        of "value":
                            inc(current)
                            result.value = cmd[current]
                        else:
                            discard
                    inc(current)
            of "Dont":
                inc(current)
                let base = current
                const words = "miss the ShredderChess Annual Barbeque".splitWhitespace()
                var i = 0
                while i < words.len() and current < cmd.len():
                    if cmd[base + i] != words[i]:
                        break
                    inc(i)
                    inc(current)
                if i == words.len():
                    return UCICommand(kind: Barbecue)
            else:
                # Unknown UCI commands should be ignored. Attempt
                # to make sense of the input regardless
                inc(current)


const NO_INCREMENT_TC_DETECTED = "Heimdall has not been tested nor designed to play without increment and is likely to perform poorly as a result. If you really wanna do this, set the EnableWeirdTCs option to true first."
const CYCLIC_TC_DETECTED = "Heimdall has not been tested to work with cyclic (movestogo) time controls and is likely to perform poorly as a result. If you really wanna do this, set the EnableWeirdTCs option to true first."


const COMMIT = block:
    var s = staticExec("git rev-parse --short=6 HEAD")
    s.stripLineEnd()
    s
const BRANCH = block:
    var s = staticExec("git rev-parse --abbrev-ref HEAD")
    s.stripLineEnd()
    s
const isRelease {.booldefine.} = false
# Note: check the Makefile for their real values!
const VERSION_MAJOR {.define: "majorVersion".} = 1
const VERSION_MINOR {.define: "minorVersion".} = 0
const VERSION_PATCH {.define: "patchVersion".} = 0
const isBeta {.booldefine.} = false


func getVersionString*: string {.compileTime.} =
    var version: string
    if isRelease:
        version = &"{VERSION_MAJOR}.{VERSION_MINOR}.{VERSION_PATCH}"
        if isBeta:
            version &= &"-beta-COMMIT"
    else:
        version = &"dev ({BRANCH} at {COMMIT})"
    return &"Heimdall {version}"


proc printLogo =
    # Thanks @tsoj!
    stdout.styledWrite styleDim, "|'.                \n"
    stdout.styledWrite styleDim, " \\ \\               \n"
    stdout.styledWrite styleDim, "  \\", resetStyle, styleBright, fgCyan, "H", resetStyle, styleDim, "\\              \n"
    stdout.styledWrite styleDim, "   \\", resetStyle, styleBright, fgBlue, "e", resetStyle, styleDim, "\\", resetStyle, " .~.         \n"
    stdout.styledWrite styleDim, "    \\", resetStyle, styleBright, fgCyan, "i", resetStyle, styleDim, "\\", resetStyle, " \\", styleDim, "\\", resetStyle, "'.       \n"
    stdout.styledWrite "     \\", styleBright, fgGreen, "m", resetStyle, "\\ |",styleDim, "|\\", resetStyle, "\\      \n"
    stdout.styledWrite "   _  \\", styleBright, fgYellow, "d", resetStyle, "\\/", styleDim, "/|", resetStyle, "|      \n"
    stdout.styledWrite "  / \\>=\\", styleBright, fgRed, "a", resetStyle, "\\", styleDim, "//", resetStyle, "/      \n"
    stdout.styledWrite "  |  |", styleDim, ">=", resetStyle, "\\", styleBright, fgMagenta, "l", resetStyle, "\\/       \n"
    stdout.styledWrite "   \\_/==~\\", styleBright, fgRed, "l",resetStyle, "\\       \n"
    stdout.styledWrite "          \\ \\      \n"
    stdout.styledWrite styleDim, "           \\", resetStyle, "\\", styleDim, "\\     \n"
    stdout.styledWrite styleDim, "            \\", resetStyle, "\\", styleDim, "\\    \n"
    stdout.styledWrite "          o", styleBright, styleDim, "==", resetStyle, styleBright, "<X>", styleDim, "==", resetStyle, "o\n"
    stdout.styledWrite styleDim, "              ()   \n"
    stdout.styledWrite styleDim, "               ()  \n"
    stdout.styledWrite styleBright, "                O  "
    echo ""


proc searchWorkerLoop(self: UCISearchWorker) {.thread.} =
    ## Finds the best move in the current position and
    ## prints it
    setControlCHook(proc () {.noconv.} = quit(0))

    while true:
        let action = self.channels.receive.recv()
        if self.session.debug:
            echo &"info string worker received action: {action.kind}"
        case action.kind:
            of Exit:
                if self.session.debug:
                    echo &"info string worker shutting down"
                self.channels.send.send(Exiting)
                break
            of Search:
                if self.session.debug:
                    echo &"info string worker beginning search on UCI command {action.command}"
                var 
                    timeRemaining = (if self.session.history[^1].sideToMove == White: action.command.wtime else: action.command.btime)
                    increment = (if self.session.history[^1].sideToMove == White: action.command.winc else: action.command.binc)
                    timePerMove = action.command.moveTime.isSome()
                
                if not self.session.enableWeirdTCs and not (timePerMove or timeRemaining.isNone()) and (increment.isNone() or increment.get() == 0):
                    echo &"info string {NO_INCREMENT_TC_DETECTED}"
                    # Resign
                    echo "bestmove 0000"
                    continue
                # Code duplication is ugly, but the condition would get ginormous if I were to do it in one if statement
                if not self.session.enableWeirdTCs and (action.command.movesToGo.isSome() and action.command.movesToGo.get() != 0):
                    # We don't even implement the movesToGo TC (it's old af), so this warning is especially
                    # meaningful
                    echo &"info string {CYCLIC_TC_DETECTED}"
                    echo "bestmove 0000"
                    continue
                # Setup search limits

                # Remove limits from previous search
                self.session.searcher.limiter.clear()

                # Add limits from new UCI action.command. Multiple limits are supported!
                if action.command.depth.isSome():
                    self.session.searcher.limiter.addLimit(newDepthLimit(action.command.depth.get()))
                if action.command.nodes.isSome():
                    self.session.searcher.limiter.addLimit(newNodeLimit(action.command.nodes.get()))

                if timeRemaining.isSome():
                    if increment.isSome():
                        self.session.searcher.limiter.addLimit(newTimeLimit(timeRemaining.get(), increment.get(), self.session.overhead))
                    else:
                        self.session.searcher.limiter.addLimit(newTimeLimit(timeRemaining.get(), 0, self.session.overhead))

                if timePerMove:
                    self.session.searcher.limiter.addLimit(newTimeLimit(action.command.moveTime.get(), self.session.overhead))
                
                if action.command.mate.isSome():
                    self.session.searcher.limiter.addLimit(newMateLimit(action.command.mate.get()))

                self.session.searcher.setBoardState(self.session.history)
                var line = self.session.searcher.search(action.command.searchmoves, false, self.session.canPonder and action.command.ponder,
                                                        self.session.minimal, self.session.variations)[0][]
                let chess960 = self.session.searcher.state.chess960.load()
                for move in line.mitems():
                    if move == nullMove():
                        break
                    if move.isCastling() and not chess960:
                        # Hide the fact we're using FRC internally
                        if move.targetSquare < move.startSquare:
                            move.targetSquare = makeSquare(rankFromSquare(move.targetSquare), fileFromSquare(move.targetSquare) + 2)
                        else:
                            move.targetSquare = makeSquare(rankFromSquare(move.targetSquare), fileFromSquare(move.targetSquare) - 1)
                # No limit has expired but the search has completed:
                # If this is a `go infinite` command, UCI tells us we must
                # not print a best move until we're told to stop explicitly,
                # so we spin until that happens
                if action.command.infinite:
                    while not self.session.searcher.shouldStop(false):
                        # Sleep for 10ms
                        sleep(10)
                if line[0] == nullMove():
                    # No best move. Well shit. Usually this only happens at insanely low TCs
                    # so we just pick a random legal move
                    var moves = newMoveList()
                    var board = newChessboard(@[self.session.searcher.getCurrentPosition().clone()])
                    board.generateMoves(moves)
                    line[0] = moves[rand(0..moves.high())]
                if line[1] != nullMove():
                    echo &"bestmove {line[0].toUCI()} ponder {line[1].toUCI()}"
                else:
                    echo &"bestmove {line[0].toUCI()}"
                if self.session.debug:
                    echo "info string worker has finished searching"
                self.channels.send.send(SearchComplete)


proc startUCISession* =
    ## Begins listening for UCI commands
    echo &"{getVersionString()} by nocturn9x (see LICENSE)"
    var
        cmd: UCICommand
        cmdStr: string
        session = UCISession(hashTableSize: 64, history: @[startpos()], variations: 1, overhead: 100)
    # God forbid we try to use atomic ARC like it was intended. Raw pointers
    # it is then... sigh
    var
        transpositionTable = create(TTable)
        # Align local heuristic tables to cache-line boundaries
        quietHistory = allocHeapAligned(ThreatHistoryTable, 64)
        captureHistory = allocHeapAligned(CaptHistTable, 64)
        killerMoves = allocHeapAligned(KillersTable, 64)
        counterMoves = allocHeapAligned(CountersTable, 64)
        continuationHistory = allocHeapAligned(ContinuationHistory, 64)
        parameters = getDefaultParameters()
    transpositionTable[] = newTranspositionTable(session.hashTableSize * 1024 * 1024)
    session.searcher = newSearchManager(session.history, transpositionTable, quietHistory, captureHistory,
                                        killerMoves, counterMoves, continuationHistory, parameters)
    var searchWorker: UCISearchWorker
    new(searchWorker)
    searchWorker.channels.receive.open(0)
    searchWorker.channels.send.open(0)
    searchWorker.session = session
    var searchWorkerThread: Thread[UCISearchWorker]
    createThread(searchWorkerThread, searchWorkerLoop, searchWorker)
    resetHeuristicTables(quietHistory, captureHistory, killerMoves, counterMoves, continuationHistory)
    if not isatty(stdout) or getEnv("NO_COLOR").len() != 0:
        session.searcher.setUCIMode(true)
    else:
        printLogo()
    while true:
        try:
            cmdStr = readLine(stdin).strip(leading=true, trailing=true, chars={'\t', ' '})
            if cmdStr.len() == 0:
                if session.debug:
                    echo "info string received empty input, ignoring it"
                continue
            cmd = session.parseUCICommand(cmdStr)
            if cmd.kind == Unknown:
                if session.debug:
                    echo &"info string received unknown or invalid command '{cmdStr}' -> {cmd.reason}"
                continue
            if session.debug:
                echo &"info string received command '{cmdStr}' -> {cmd}"
            case cmd.kind:
                of Uci:
                    echo &"id name {getVersionString()}"
                    echo "id author Nocturn9x (see LICENSE)"
                    echo "option name HClear type button"
                    echo "option name TTClear type button"
                    echo "option name Ponder type check default false"
                    echo "option name UCI_ShowWDL type check default false"
                    echo "option name Minimal type check default false"
                    echo "option name UCI_Chess960 type check default false"
                    echo "option name EvalFile type string default <default>"
                    echo "option name NormalizeScore type check default true"
                    echo "option name EnableWeirdTCs type check default false"
                    echo "option name MultiPV type spin default 1 min 1 max 218"
                    echo "option name Threads type spin default 1 min 1 max 1024"
                    echo "option name Hash type spin default 64 min 1 max 33554432"
                    echo "option name MoveOverhead type spin default 100 min 0 max 30000"
                    when isTuningEnabled:
                        for param in getParameters():
                            echo &"option name {param.name} type spin default {param.default} min {param.min} max {param.max}"
                    echo "uciok"
                    session.searcher.setUCIMode(true)
                of Icu:
                    echo "koicu"
                    session.searcher.setUCIMode(false)
                of Quit:
                    if session.searcher.isSearching():
                        session.searcher.stop()
                    searchWorker.channels.receive.send(WorkerCommand(kind: Exit))
                    var workerResp = searchWorker.channels.send.recv()
                    # One or more searches were completed before and their messages were not dequeued yet
                    if workerResp != Exiting:
                        while true:
                            doAssert workerResp == SearchComplete, $workerResp
                            workerResp = searchWorker.channels.send.recv()
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
                        if session.debug:
                            echo "info string cannot start a new game while searching"
                        continue
                    if session.debug:
                        echo &"info string clearing out TT of size {session.hashTableSize} MiB"
                    transpositionTable.init(session.workers + 1)
                    resetHeuristicTables(quietHistory, captureHistory, killerMoves, counterMoves, continuationHistory)
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
                    if session.searcher.isSearching():
                        # Search already running. Let's teach the user a lesson
                        session.searcher.stop()
                        doAssert searchWorker.channels.send.recv() == SearchComplete
                        echo "info string premium membership is required to send go during search. Please check out https://n9x.co/heimdall-premium for details"
                        continue
                    if session.history[^1].isCheckmate():
                        echo "info string position is mated"
                        echo "bestmove 0000"
                        continue
                    # Start the clock as soon as possible to account
                    # for startup delays in our time management
                    session.searcher.startClock()
                    searchWorker.channels.receive.send(WorkerCommand(kind: Search, command: cmd))
                    if session.debug:
                        echo "info string search started"
                of Wait:
                    if session.searcher.isSearching():
                        doAssert searchWorker.channels.send.recv() == SearchComplete
                of Stop:
                    if session.searcher.isSearching():
                        session.searcher.stop()
                        doAssert searchWorker.channels.send.recv() == SearchComplete
                    if session.debug:
                        echo "info string search stopped"
                of SetOption:
                    if session.searcher.isSearching():
                        # Cannot set options during search
                        continue
                    let
                        # UCI mandates that names and values are not to be case sensitive
                        name = cmd.name.toLowerAscii()
                        value = cmd.value.toLowerAscii()
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
                            let newSize = value.parseBiggestUInt()
                            doAssert newSize in 1'u64..33554432'u64
                            if session.debug:
                                echo &"info string resizing TT from {session.hashTableSize} MiB To {newSize} MiB"
                            transpositionTable.resize(newSize * 1024 * 1024, session.workers + 1)
                            session.hashTableSize = newSize
                            if session.debug:
                                echo &"info string set TT hash table size to {session.hashTableSize} MiB"
                        of "ttclear":
                            if session.debug:
                                echo "info string clearing TT"
                            transpositionTable.init(session.workers + 1)
                        of "hclear":
                            if session.debug:
                                echo "info string clearing history tables"
                            resetHeuristicTables(quietHistory, captureHistory, killerMoves, counterMoves, continuationHistory)
                            session.searcher.resetWorkers()
                        of "threads":
                            let numWorkers = value.parseInt()
                            doAssert numWorkers in 1..1024
                            if session.debug:
                                echo &"info string set thread count to {numWorkers}"
                            session.workers = numWorkers - 1
                            session.searcher.setWorkerCount(session.workers)
                        of "uci_chess960":
                            doAssert value in ["true", "false"]
                            let enabled = value == "true"
                            session.searcher.state.chess960.store(enabled)
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
                            session.searcher.state.normalizeScore.store(enabled)
                            if session.debug:
                                echo &"info string normalizing displayed scores: {enabled}"
                        of "uci_showwdl":
                            doAssert value in ["true", "false"]
                            let enabled = value == "true"
                            session.searcher.state.showWDL.store(enabled)
                            if session.debug:
                                echo &"info string showing wdl: {enabled}"
                        of "minimal":
                            doAssert value in ["true", "false"]
                            let enabled = value == "true"
                            session.minimal = enabled
                            if session.debug:
                                echo &"info string printing minimal logs: {enabled}"
                        else:
                            when isTuningEnabled:
                                if cmd.name.isParamName():
                                    parameters.setParameter(name, value.parseInt())
                                elif session.debug:
                                    echo &"info string unknown option '{cmd.name}'"
                            else:
                                if session.debug:
                                    echo &"info string unknown option '{cmd.name}'"
                of Position:
                    # Nothing to do: the moves have already been parsed into
                    # session.history and they will be set as the searcher's
                    # board state once search starts
                    discard
                of Barbecue:
                    echo "info string just tell me the date and time..."
                else:
                    discard
        except IOError:
            if session.debug:
                echo "info string I/O error while reading from stdin, exiting"
            echo ""
            quit(0)
        except EOFError:
            if session.debug:
                echo "info string EOF received while reading from stdin, exiting"
            echo ""
            quit(0)