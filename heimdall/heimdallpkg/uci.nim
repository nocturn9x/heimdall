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
import std/strutils
import std/strformat
import std/atomics


import heimdallpkg/board
import heimdallpkg/movegen
import heimdallpkg/search
import heimdallpkg/eval
import heimdallpkg/tunables
import heimdallpkg/transpositions


type
    UCISession = object
        ## A UCI session
        debug: bool
        # All reached positions
        history: seq[Position]
        ## Information about the current search
        searchState: SearchManager
        printMove: ptr Atomic[bool]
        # Size of the transposition table (in megabytes, and not the retarded kind!)
        hashTableSize: uint64
        # Number of workers to use during search
        workers: int
        # Whether we allow the user to have heimdall play
        # with weird, untested time controls (i.e. increment == 0)
        userIsDumb: bool
        # The number of principal variations to search
        variations: int
    
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
                wtime: int
                btime: int
                winc: int
                binc: int
                movesToGo: int
                depth: int
                moveTime: int
                nodes: uint64
                searchmoves: seq[Move]
                ponder: bool
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
    result.wtime = 0
    result.btime = 0
    result.winc = 0
    result.binc = 0
    result.movesToGo = 0
    result.depth = -1
    result.moveTime = -1
    result.nodes = 0
    var current = 1   # Skip the "go"
    while current < command.len():
        let flag = command[current]
        inc(current)
        case flag:
            of "infinite":
                result.wtime = -1
                result.btime = -1
            of "ponder":
                result.ponder = true
            of "wtime":
                result.wtime = command[current].parseInt()
            of "btime":
                result.btime = command[current].parseInt()
            of "winc":
                result.winc = command[current].parseInt()
            of "binc":
                result.binc = command[current].parseInt()
            of "movestogo":
                result.movesToGo = command[current].parseInt()
            of "depth":
                result.depth = command[current].parseInt()
            of "movetime":
                result.moveTime = command[current].parseInt()
            of "nodes":
                result.nodes = command[current].parseBiggestUInt()
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


proc bestMove(args: tuple[session: UCISession, command: UCICommand]) {.thread.} =
    ## Finds the best move in the current position
    setControlCHook(proc () {.noconv.} = quit(0))

    # Yes yes nim sure this isn't gcsafe. Now stfu and spawn a thread
    {.cast(gcsafe).}:
        var session = args.session
        let command = args.command
        var 
            timeRemaining = (if session.history[^1].sideToMove == White: command.wtime else: command.btime)
            increment = (if session.history[^1].sideToMove == White: command.winc else: command.binc)
            timePerMove = command.moveTime != -1
            depth = if command.depth == -1: MAX_DEPTH else: command.depth
        if timePerMove:
            timeRemaining = command.moveTime
            increment = 0
        elif timeRemaining in -1..0:
            timeRemaining = int32.high()
        elif not session.userIsDumb and increment == 0:
            echo &"""info string Heimdall has not been tested nor designed with this specific time control in mind and is likely to perform poorly as a result. If you really wanna do this, set the EnableWeirdTCs option to true first."""
            return
        var line = session.searchState.search(timeRemaining, increment, depth, command.nodes, command.searchmoves, timePerMove, 
                                              command.ponder, false, session.workers, session.variations)
        for move in line.mitems():
            if move == nullMove():
                break
            if move.isCastling() and not session.searchState.chess960:
                # Hide the fact we're using FRC internally
                if move.targetSquare < move.startSquare:
                    move.targetSquare = makeSquare(rankFromSquare(move.targetSquare), fileFromSquare(move.targetSquare) + 2)
                else:
                    move.targetSquare = makeSquare(rankFromSquare(move.targetSquare), fileFromSquare(move.targetSquare) - 1)
        if session.printMove[].load():
            # Shouldn't send a ponder move if we were already pondering
            if line.len() == 1 or command.ponder:
                echo &"bestmove {line[0].toAlgebraic()}"
            else:
                echo &"bestmove {line[0].toAlgebraic()} ponder {line[1].toAlgebraic()}"


func resetHeuristicTables*(quietHistory, captureHistory: ptr HistoryTable, killerMoves: ptr KillersTable, counterMoves: ptr CountersTable,
                          continuationHistory: ptr ContinuationHistory) =
    ## Resets all the heuristic tables to their default configuration
    
    for color in White..Black:
        for i in Square(0)..Square(63):
            for j in Square(0)..Square(63):
                quietHistory[color][i][j] = Score(0)
                captureHistory[color][i][j]  = Score(0)
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
        quietHistory = create(HistoryTable)
        captureHistory = create(HistoryTable)
        killerMoves = create(KillersTable)
        counterMoves = create(CountersTable)
        continuationHistory = create(ContinuationHistory)
        parameters = getDefaultParameters()
    transpositionTable[] = newTranspositionTable(session.hashTableSize * 1024 * 1024)
    session.searchState = newSearchManager(session.history, transpositionTable, quietHistory, captureHistory, killerMoves, counterMoves, continuationHistory, parameters)
    session.printMove = create(Atomic[bool])
    resetHeuristicTables(quietHistory, captureHistory, killerMoves, counterMoves, continuationHistory)
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
                    echo &"option name EvalFile type string"
                    echo "option name UCI_Chess960 type check default false"
                    echo "option name EnableWeirdTCs type check default false"
                    echo "option name MultiPV type spin default 1 min 1 max 256"
                    echo "option name Threads type spin default 1 min 1 max 1024"
                    echo "option name Hash type spin default 64 min 1 max 33554432"
                    when isTuningEnabled:
                        for param in getParameters():
                            echo &"option name {param.name} type spin default {param.default} min {param.min} max {param.max}"
                    echo "uciok"
                of Quit:
                    if session.searchState.isSearching():
                        session.searchState.stop()
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
                    if not session.searchState.isSearching():
                        continue
                    session.searchState.stopPondering()
                    if session.debug:
                        echo "info string switched to normal search"
                of Go:
                    session.printMove[].store(true)
                    if not cmd.ponder and session.searchState.isPondering():
                        session.searchState.stopPondering()
                    else:
                        if searchThread.running:
                            joinThread(searchThread)
                        createThread(searchThread, bestMove, (session, cmd))
                        if session.debug:
                            echo "info string search started"
                of Stop:
                    if not session.searchState.isSearching():
                        continue
                    session.searchState.stop()
                    joinThread(searchThread)
                    if session.debug:
                        echo "info string search stopped"
                of SetOption:
                    if session.searchState.isSearching():
                        # Cannot set options during search
                        continue
                    case cmd.name:
                        of "MultiPV":
                            session.variations = cmd.value.parseInt()
                            doAssert session.variations > 0
                        of "EnableWeirdTCs":
                            doAssert cmd.value in ["true", "false"]
                            session.userIsDumb = cmd.value == "true"
                            if session.userIsDumb:
                                echo "info string By enabling this option, you acknowledge that you are stepping into uncharted territory. Proceed at your own risk!"
                        of "Hash":
                            let newSize = cmd.value.parseBiggestUInt()
                            if newSize < 1:
                                continue
                            if transpositionTable.size() > 0:
                                if session.debug:
                                    echo &"info string resizing TT from {session.hashTableSize} MiB To {newSize} MiB"
                                if newSize > 0:
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
                            if numWorkers < 1 or numWorkers > 1024:
                                continue
                            if session.debug:
                                echo &"info string set thread count to {numWorkers}"
                            session.workers = numWorkers
                        of "UCI_Chess960":
                            doAssert cmd.value in ["true", "false"]
                            session.searchState.chess960 = cmd.value == "true"
                        of "EvalFile":
                            session.searchState.setNetwork(cmd.value)
                        else:
                            when isTuningEnabled:
                                if cmd.name.isParamName():
                                    parameters.setParameter(cmd.name, cmd.value.parseInt())
                of Position:
                    if session.searchState.isPondering():
                        # The ponder move was not played. Stop
                        # the ponder search and make sure it doesn't
                        # print out its result (it would be an illegal
                        # move)
                        session.printMove[].store(false)
                        session.searchState.stop()
                        joinThread(searchThread)
                    session.searchState.setBoardState(session.history)
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