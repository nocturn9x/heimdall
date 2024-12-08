# Copyright 2024 Mattia Giambirtone & All Contributors
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
import std/strutils
import std/strformat
import std/atomics
import std/options
import std/terminal



import heimdallpkg/board
import heimdallpkg/movegen
import heimdallpkg/search
import heimdallpkg/eval
import heimdallpkg/util/tunables
import heimdallpkg/util/limits
import heimdallpkg/util/aligned
import heimdallpkg/transpositions


type
    UCISession = object
        ## A UCI session
        debug: bool
        # All reached positions
        history: seq[Position]
        ## Information about the current search
        searcher: SearchManager
        printMove: ptr Atomic[bool]
        # Size of the transposition table (in megabytes, and not the retarded kind!)
        hashTableSize: uint64
        # Number of workers to use during search
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

    if position.getPiece(startSquare).kind == Pawn and abs(rankFromSquare(startSquare) - rankFromSquare(targetSquare)) == 2:
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
    if piece.kind == King and targetSquare in ["c1".toSquare(), "g1".toSquare(), "c8".toSquare(), "g8".toSquare()] and abs(fileFromSquare(startSquare) - fileFromSquare(targetSquare)) > 1:
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
        r = session.parseUCIMove(board.positions[^1], moveStr)
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
                discard
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
            # Account for checkmated FENs with the wrong stm
            var moves = newMoveList()
            chessboard.makeNullMove()
            chessboard.generateMoves(moves)
            chessboard.unmakeMove()
            if len(moves) == 0:
                return UCICommand(kind: Unknown, reason: "illegal FEN: side to move has already checkmated")
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
    session.history = chessboard.positions


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
                     
            else:
                # Unknown UCI commands should be ignored. Attempt
                # to make sense of the input regardless
                inc(current)


const WEIRD_TC_DETECTED = "Heimdall has not been tested nor designed with this specific time control in mind and is likely to perform poorly as a result. If you really wanna do this, set the EnableWeirdTCs option to true first."


proc bestMove(args: tuple[session: UCISession, command: UCICommand]) {.thread.} =
    ## Finds the best move in the current position and
    ## prints it
    setControlCHook(proc () {.noconv.} = quit(0))

    # Yes yes nim sure this isn't gcsafe. Now stfu and spawn a thread
    {.cast(gcsafe).}:
        var session = args.session
        let command = args.command
        var 
            timeRemaining = (if session.history[^1].sideToMove == White: command.wtime else: command.btime)
            increment = (if session.history[^1].sideToMove == White: command.winc else: command.binc)
            timePerMove = command.moveTime.isSome()
            depth = if command.depth.isNone(): MAX_DEPTH else: command.depth.get()
        
        if not session.enableWeirdTCs and not (timePerMove or timeRemaining.isNone() or timeRemaining.get() == 0) and (increment.isNone() or increment.get() == 0):
            echo &"info string {WEIRD_TC_DETECTED}"
            return
        # Code duplication is ugly, but the condition would get ginormous if I were to do it in one if statement
        if not session.enableWeirdTCs and (command.movesToGo.isSome() and command.movesToGo.get() != 0):
            # We don't even implement the movesToGo TC (it's old af), so this warning is especially
            # meaningful
            echo &"info string {WEIRD_TC_DETECTED}"
            return
        # Setup search limits

        # Remove limits from previous search
        session.searcher.limiter.reset()

        # Add limits from new UCI command. Multiple limits are supported!
        session.searcher.limiter.addLimit(newDepthLimit(depth))
        if command.nodes.isSome():
            session.searcher.limiter.addLimit(newNodeLimit(command.nodes.get()))

        if timeRemaining.isSome():
            if increment.isSome():
                session.searcher.limiter.addLimit(newTimeLimit(timeRemaining.get(), increment.get(), session.overhead))
            else:
                session.searcher.limiter.addLimit(newTimeLimit(timeRemaining.get(), 0, session.overhead))

        if timePerMove:
            session.searcher.limiter.addLimit(newTimeLimit(command.moveTime.get().uint64, session.overhead.uint64))
        
        if command.mate.isSome():
            session.searcher.limiter.addLimit(newMateLimit(command.mate.get()))

        var line = session.searcher.search(command.searchmoves, false, session.canPonder and command.ponder, session.workers, session.variations)
        let chess960 = session.searcher.state.chess960.load()
        for move in line.mitems():
            if move == nullMove():
                break
            if move.isCastling() and not chess960:
                # Hide the fact we're using FRC internally
                if move.targetSquare < move.startSquare:
                    move.targetSquare = makeSquare(rankFromSquare(move.targetSquare), fileFromSquare(move.targetSquare) + 2)
                else:
                    move.targetSquare = makeSquare(rankFromSquare(move.targetSquare), fileFromSquare(move.targetSquare) - 1)
        if session.printMove[].load():
            # No limit has expired but the search has completed:
            # the most likely occurrence is a go infinite command.
            # UCI tells us we must not print a best move until we're
            # told to stop explicitly, so we spin until that happens
            while not session.searcher.shouldStop(false):
                # Sleep for 10ms
                sleep(10)
            # Shouldn't send a ponder move if we were already pondering!
            if line.len() == 1 or command.ponder:
                echo &"bestmove {line[0].toAlgebraic()}"
            else:
                echo &"bestmove {line[0].toAlgebraic()} ponder {line[1].toAlgebraic()}"


func resetHeuristicTables*(quietHistory: ptr ThreatHistoryTable, captureHistory: ptr CaptHistTable, killerMoves: ptr KillersTable,
                           counterMoves: ptr CountersTable, continuationHistory: ptr ContinuationHistory) =
    ## Resets all the heuristic tables to their default configuration
    
    for color in White..Black:
        for i in Square(0)..Square(63):
            for j in Square(0)..Square(63):
                quietHistory[color][i][j][true][false] = Score(0)
                quietHistory[color][i][j][false][true] = Score(0)
                quietHistory[color][i][j][true][true] = Score(0)
                quietHistory[color][i][j][false][false] = Score(0)
                for piece in Pawn..Queen:
                    captureHistory[color][i][j][piece]  = Score(0)
    for i in 0..<MAX_DEPTH:
        for j in 0..<NUM_KILLERS:
            killerMoves[i][j] = nullMove()
    for fromSq in Square(0)..Square(63):
        for toSq in Square(0)..Square(63):
            counterMoves[fromSq][toSq] = nullMove()
    for sideToMove in White..Black:
        for piece in PieceKind.all():
            for to in Square(0)..Square(63):
                for prevColor in White..Black:
                    for prevPiece in PieceKind.all():
                        for prevTo in Square(0)..Square(63):
                            continuationHistory[sideToMove][piece][to][prevColor][prevPiece][prevTo] = 0

# TODO: Windows compatible?
const COMMIT = staticExec("git rev-parse HEAD | head -c 6")
const BRANCH = staticExec("git symbolic-ref HEAD 2>/dev/null | cut -f 3 -d /")
const isRelease {.booldefine.} = false
const VERSION_MAJOR {.define: "majorVersion".} = 1
const VERSION_MINOR {.define: "minorVersion".} = 0
const VERSION_PATCH {.define: "patchVersion".} = 0
const isBeta {.booldefine.} = false


func getVersionString*: string {.compileTime.}  =
    if isRelease:
        result = &"Heimdall {VERSION_MAJOR}.{VERSION_MINOR}.{VERSION_PATCH}"
        if isBeta:
            result &= "-beta"
            when not defined(windows):
                result &= &"-{COMMIT}"
    else:
        when not defined(windows):
            return &"Heimdall dev ({BRANCH} at {COMMIT})"
        else:
            return "Heimdall dev"


proc startUCISession* =
    ## Begins listening for UCI commands
    echo &"{getVersionString()} by nocturn9x (see LICENSE)"
    var
        cmd: UCICommand
        cmdStr: string
        session = UCISession(hashTableSize: 64, history: @[startpos()], workers: 1, variations: 1)
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
    session.printMove = create(Atomic[bool])
    resetHeuristicTables(quietHistory, captureHistory, killerMoves, counterMoves, continuationHistory)
    if not isatty(stdout) or getEnv("NO_COLOR").len() != 0:
        session.searcher.setUCIMode(true)
    else:
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
    # Fun fact, nim doesn't collect the memory of thread vars. Another stupid fucking design pitfall
    # of nim's AWESOME threading model. Someone is getting a pipebomb in their mailbox about this, mark
    # my fucking words. (for legal purposes THAT IS A JOKE). See https://github.com/nim-lang/Nim/issues/23165
    # The solution? Just reuse the same thread object so the leak is isolated to a single thread.
    # Also the nim allocator has internal races, so we gotta lose performance by using -d:useMalloc instead.
    # At least mimalloc exists.
    # THANKS ARAQ
    var searchThread: Thread[tuple[session: UCISession, command: UCICommand]]
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
                    echo "option name ShowWDL type check default false"
                    echo "option name UCI_Chess960 type check default false"
                    echo "option name EvalFile type string default <default>"
                    echo "option name NormalizeScore type check default true"
                    echo "option name EnableWeirdTCs type check default false"
                    echo "option name MultiPV type spin default 1 min 1 max 218"
                    echo "option name Threads type spin default 1 min 1 max 1024"
                    echo "option name Hash type spin default 64 min 1 max 33554432"
                    echo "option name MoveOverhead type spin default 0 min 0 max 30000"
                    when isTuningEnabled:
                        for param in getParameters():
                            echo &"option name {param.name} type spin default {param.default} min {param.min} max {param.max}"
                    echo "uciok"
                    session.searcher.setUCIMode(true)
                of Quit:
                    if session.searcher.isSearching():
                        session.searcher.stop()
                        joinThread(searchThread)
                    quit(0)
                of IsReady:
                    echo "readyok"
                of Debug:
                    session.debug = cmd.on
                of NewGame:
                    if session.debug:
                        echo &"info string clearing out TT of size {session.hashTableSize} MiB"
                    transpositionTable.clear()
                    resetHeuristicTables(quietHistory, captureHistory, killerMoves, counterMoves, continuationHistory)
                of PonderHit:
                    if session.debug:
                        echo "info string ponder move has ben hit"
                    if not session.searcher.isSearching():
                        continue
                    session.searcher.stopPondering()
                    if session.debug:
                        echo "info string switched to normal search"
                of Go:
                    session.printMove[].store(true)
                    if not cmd.ponder and session.searcher.isPondering():
                        session.searcher.stopPondering()
                    else:
                        if searchThread.running:
                            joinThread(searchThread)
                        # Start the clock as soon as possible to account
                        # for startup delays in our time management
                        session.searcher.startClock()
                        createThread(searchThread, bestMove, (session, cmd))
                        if session.debug:
                            echo "info string search started"
                of Stop:
                    session.searcher.stop()
                    joinThread(searchThread)
                    if session.debug:
                        echo "info string search stopped"
                of SetOption:
                    if session.searcher.isSearching():
                        # Cannot set options during search
                        continue
                    case cmd.name:
                        of "MultiPV":
                            session.variations = cmd.value.parseInt()
                            doAssert session.variations > 0 and session.variations < 219
                        of "EnableWeirdTCs":
                            doAssert cmd.value in ["true", "false"]
                            session.enableWeirdTCs = cmd.value == "true"
                            if session.enableWeirdTCs:
                                echo "info string By enabling this option, you acknowledge that you are stepping into uncharted territory. Proceed at your own risk!"
                        of "Hash":
                            let newSize = cmd.value.parseBiggestUInt()
                            doAssert newSize in 1'u64..33554432'u64
                            if session.debug:
                                echo &"info string resizing TT from {session.hashTableSize} MiB To {newSize} MiB"
                            transpositionTable.resize(newSize * 1024 * 1024)
                            session.hashTableSize = newSize
                            if session.debug:
                                echo &"info string set TT hash table size to {session.hashTableSize} MiB"
                        of "TTClear":
                            if session.debug:
                                echo "info string clearing TT"
                            transpositionTable.clear()
                        of "HClear":
                            if session.debug:
                                echo "info string clearing history tables"
                            resetHeuristicTables(quietHistory, captureHistory, killerMoves, counterMoves, continuationHistory)
                        of "Threads":
                            let numWorkers = cmd.value.parseInt()
                            doAssert numWorkers in 1..1024
                            if session.debug:
                                echo &"info string set thread count to {numWorkers}"
                            session.workers = numWorkers
                        of "UCI_Chess960":
                            doAssert cmd.value in ["true", "false"]
                            let enabled = cmd.value == "true"
                            session.searcher.state.chess960.store(enabled)
                            if session.debug:
                                echo &"info string Chess960 mode: {enabled}"
                        of "EvalFile":
                            if session.debug:
                                echo &"info string loading net at {cmd.value}"
                            if cmd.value == "<default>":
                                session.searcher.setNetwork("")
                            else:
                                session.searcher.setNetwork(cmd.value)
                        of "MoveOverhead":
                            let overhead = cmd.value.parseInt()
                            doAssert overhead in 0..30000
                            session.overhead = overhead
                            if session.debug:
                                echo &"info string set move overhead to {overhead}"
                        of "Ponder":
                            doAssert cmd.value in ["true", "false"]
                            let enabled = cmd.value == "true"
                            session.canPonder = enabled
                            if session.debug:
                                echo &"info string pondering: {enabled}"
                        of "NormalizeScore":
                            doAssert cmd.value in ["true", "false"]
                            let enabled = cmd.value == "true"
                            session.searcher.state.normalizeScore = enabled
                            if session.debug:
                                echo &"info string normalizing displayed scores: {enabled}"
                        of "ShowWDL":
                            doAssert cmd.value in ["true", "false"]
                            let enabled = cmd.value == "true"
                            session.searcher.state.showWDL = enabled
                            if session.debug:
                                echo &"info string showing wdl: {enabled}"
                        else:
                            when isTuningEnabled:
                                if cmd.name.isParamName():
                                    parameters.setParameter(cmd.name, cmd.value.parseInt())
                of Position:
                    if session.searcher.isPondering():
                        # The ponder move was not played. Stop
                        # the ponder search and make sure it doesn't
                        # print out its result (it would be an illegal
                        # move)
                        session.printMove[].store(false)
                        session.searcher.stop()
                        joinThread(searchThread)
                    session.searcher.setBoardState(session.history)
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