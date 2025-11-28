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

import heimdall/[board, search, movegen, transpositions, pieces as pcs, eval, nnue]
import heimdall/util/[perft, limits, tunables, scharnagl, help, wdl, eval_stats]
import heimdall/util/memory/aligned

import std/[os, math, times, random, atomics, options, terminal, strutils, strformat, sequtils, parseutils]
from std/lenientops import `/`

randomize()


type
    UCISession = ref object
        # Print verbose logs for every action
        debug: bool
        board: Chessboard
        searcher: SearchManager
        # Size of the transposition table (in mebibytes, aka the only sensible unit.)
        hashTableSize: uint64
        # Number of (extra) workers to use during search alongside
        # the main search thread. This is always Threads - 1
        workers: int
        # Whether we allow the user to have heimdall play
        # with weird, untested time controls (e.g. increment == 0)
        enableWeirdTCs: bool
        # The number of principal variations to search
        variations: int
        # The move overhead
        overhead: int
        # Are we alloved to ponder when go ponder is sent?
        canPonder: bool
        # Do we print minimal logs? (only final depth)
        minimal: bool
        datagenMode: bool
        # Should we interpret the nodes from go nodes
        # as a soft bound instead of a hard bound? Only
        # active in datagen mode
        useSoftNodes: bool
        # Hard node limit applied across any one search. Only
        # active in datagen mode
        hardNodeLimit: int
        # Only applies in datagen mode: if this is set, the soft
        # node limit applied to each search will be randomly picked
        # using the value of go nodes as the lower bound and the value
        # of softNodeRandomLimit as the upper bound
        randomizeSoftNodes: bool
        # The upper bound for the soft node limit when using soft node
        # limit randomization (defaults to the lower bound if not set)
        softNodeRandomLimit: int
        # Used to avoid blocking forever when sending wait after a
        # go infinite command
        isInfiniteSearch: bool
        # Are we in mixed mode?
        isMixedMode: bool

    BareUCICommand = enum
        Icu            = "icu"
        Wait           = "wait"
        Barbecue       = "Dont"
        Clear          = "clear"
        NullMove       = "nullMove"
        SideToMove     = "stm"
        EnPassant      = "epTarget"
        Repeated       = "repeated"
        PrintFEN       = "fen"
        PrintASCII     = "print"
        PrettyPrint    = "pretty"
        CastlingRights = "castle"
        ZobristKey     = "zobrist"
        PawnKey        = "pkey"
        MinorKey       = "minKey"
        MajorKey       = "majKey"
        NonpawnKeys    = "npKeys"
        GameStatus     = "status"
        Threats        = "threats"
        InCheck        = "inCheck"
        Checkers       = "checkers"
        UnmakeMove     = "unmove"
        StaticEval     = "eval"
        Material       = "material"
        InputBucket    = "ibucket"
        OutputBucket   = "obucket"
        PrintNetName   = "network"
        PinnedPieces   = "pins"

    SimpleUCICommand = enum
        Help      = "help"
        Attackers = "atk"
        Defenders = "def"
        GetPiece  = "on"
        MakeMove  = "move"
        DumpNet   = "verbatim"
        GetStats  = "getStats"

    UCICommandType = enum
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
        ## Custom commands after here

        Bare,     # Bare commands take no arguments
        Simple,   # Simple commands take only one argument
        Set,      # Shorthand for setoption
        GetScale

    UCICommand = object
        case kind: UCICommandType
            of Debug:
                on: bool
            of Position:
                fen: string
                moves: seq[string]
            of SetOption, Set:
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
                # Custom bits
                perft: Option[tuple[depth: int, verbose, capturesOnly, divide, bulk: bool]]
            of Simple:
                simpleCmd: SimpleUCICommand
                arg: string
            of Bare:
                bareCmd: BareUCICommand
            of GetScale:
                currAbsMean: float
                newAbsMean: float
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
    var
        startSquare: Square
        targetSquare: Square
        flag = Normal
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

    if position.on(startSquare).kind == Pawn and absDistance(rank(startSquare), rank(targetSquare)) == 2:
        flag = DoublePush

    if len(move) == 5:
        # Promotion
        case move[4]:
            of 'b':
                flag = PromotionBishop
            of 'n':
                flag = PromotionKnight
            of 'q':
                flag = PromotionQueen
            of 'r':
                flag = PromotionRook
            else:
                return (nullMove(), UCICommand(kind: Unknown, reason: &"invalid promotion piece '{move[4]}'"))

    let piece = position.on(startSquare)

    if position.on(targetSquare).color == piece.color.opposite():
        case flag:
            of PromotionBishop:
                flag = CapturePromotionBishop
            of PromotionKnight:
                flag = CapturePromotionKnight
            of PromotionRook:
                flag = CapturePromotionRook
            of PromotionQueen:
                flag = CapturePromotionQueen
            else:
                flag = Capture

    let canCastle = position.canCastle()

    if piece.kind == King:
        if startSquare in ["e1".toSquare(), "e8".toSquare()]:
            # Support for standard castling notation
            case targetSquare:
                of "c1".toSquare(), "c8".toSquare():
                    flag = LongCastling
                    targetSquare = canCastle.queen
                of "g1".toSquare(), "g8".toSquare():
                    flag = ShortCastling
                    targetSquare = canCastle.king
                else:
                    if targetSquare in [canCastle.king, canCastle.queen]:
                        if not session.searcher.state.chess960.load():
                            return (nullMove(), UCICommand(kind: Unknown, reason: &"received Chess960-style castling move '{move}', but UCI_Chess960 is not set"))
                        flag = if targetSquare == canCastle.king: ShortCastling else: LongCastling
        elif targetSquare in [canCastle.king, canCastle.queen]:
            if not session.searcher.state.chess960.load():
                return (nullMove(), UCICommand(kind: Unknown, reason: &"received Chess960-style castling move '{move}', but UCI_Chess960 is not set"))
            flag = if targetSquare == canCastle.king: ShortCastling else: LongCastling
    if piece.kind == Pawn and targetSquare == position.enPassantSquare:
        # I hate en passant I hate en passant I hate en passant I hate en passant I hate en passant I hate en passant
        flag = EnPassant
    result.move = createMove(startSquare, targetSquare, flag)


proc handleUCIMove(session: UCISession, board: Chessboard, moveStr: string): tuple[move: Move, cmd: UCICommand] {.discardable.} =
    if session.debug:
        echo &"info string making move {moveStr}"
    let r = session.parseUCIMove(board.position, moveStr)
    if session.debug:
        echo &"info string {moveStr} parses to {r.move}"
    result.cmd = r.command
    result.move = r.move
    if result.move != nullMove():
        result.move = board.makeMove(r.move)
        if result.move == nullMove():
            result.cmd = UCICommand(kind: Unknown, reason: &"move is illegal")


proc handleUCIGoCommand(session: UCISession, command: seq[string]): UCICommand =
    result = UCICommand(kind: Go)
    var current = 1   # Skip the "go"
    while current < command.len():
        let subcommand = command[current]
        inc(current)
        case subcommand:
            of "infinite":
                result.infinite = true
            of "ponder":
                result.ponder = true
            of "wtime":
                try:
                    result.wtime = some(command[current].parseInt())
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand}' subcommand")
            of "btime":
                try:
                    result.btime = some(command[current].parseInt())
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand}' subcommand")
            of "winc":
                try:
                    result.winc = some(command[current].parseInt())
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand}' subcommand")
            of "binc":
                try:
                    result.binc = some(command[current].parseInt())
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand}' subcommand")
            of "movestogo":
                try:
                    result.movesToGo = some(command[current].parseInt())
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand}' subcommand")
            of "depth":
                try:
                    result.depth = some(command[current].parseInt())
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand}' subcommand")
            of "movetime":
                try:
                    result.moveTime = some(command[current].parseInt())
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand}' subcommand")
            of "nodes":
                try:
                    result.nodes = some(command[current].parseBiggestUInt().uint64)
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand}' subcommand")
            of "mate":
                try:
                    let value = command[current].parseInt()
                    if value < 1:
                        return UCICommand(kind: Unknown, reason: &"invalid value '{command[current]} for '{subcommand}' subcommand (must be >= 1)")
                    result.mate = some(command[current].parseInt())
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand}' subcommand")
            of "searchmoves":
                while current < command.len():
                    if command[current] == "":
                        break
                    let move = session.parseUCIMove(session.board.position, command[current]).move
                    if move == nullMove():
                        return UCICommand(kind: Unknown, reason: &"invalid move '{command[current]}' for searchmoves")
                    result.searchmoves.add(move)
                    inc(current)
            of "perft":
                if current >= command.len():
                    return UCICommand(kind: Unknown, reason: "missing depth argument for '{subcommand}'")
                var depth: int
                try:
                    depth = command[current].parseInt()
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand} depth'")

                var tup = (depth: depth, verbose: false, capturesOnly: false, divide: true, bulk: false)

                while current < command.len():
                    if command[current] == "":
                        break
                    case command[current]:
                        of "bulk":
                            tup.bulk = true
                        of "verbose":
                            tup.verbose = true
                        of "captures":
                            tup.capturesOnly = true
                        of "nosplit":
                            tup.divide = false
                        else:
                            return UCICommand(kind: Unknown, reason: &"unknown option '{command[current]}' for '{subcommand}' subcommand")
                    inc(current)

                result.perft = some(tup)
            else:
                return UCICommand(kind: Unknown, reason: &"unknown subcommand '{command[current - 1]}' for 'go'")

    let
        isLimitedSearch = anyIt([result.wtime, result.btime, result.winc, result.binc, result.movesToGo, result.depth, result.moveTime, result.mate], it.isSome()) or result.nodes.isSome()
        isPerftSearch = result.perft.isSome()
    if result.infinite:
        if result.ponder:
            return UCICommand(kind: Unknown, reason: "'go infinite' does not make sense with the 'ponder' option")
        if isLimitedSearch:
            return UCICommand(kind: Unknown, reason: "'go infinite' does not make sense with other search limits")
        if isPerftSearch:
            # Note: go perft <stuff> and go <limits> are already mutually exclusive because one
            # will be parsed as a subcommand of the other and will cause a parse error
            return UCICommand(kind: Unknown, reason: "'go infinite' and 'go perft' are mutually exclusive")
    if not isLimitedSearch and not isPerftSearch:
        # A bare 'go' is interpreted as 'go infinite'
        result.infinite = true


proc handleUCIPositionCommand(session: var UCISession, command: seq[string]): UCICommand =
    result = UCICommand(kind: Position)
    # Makes sure we don't leave the board in an invalid state if
    # some error occurs
    var chessboard: Chessboard
    if command[1] notin ["startpos", "kiwipete"] and len(command) < 3:
        return UCICommand(kind: Unknown, reason: &"missing FEN/scharnagl number for 'position {command[1]}' command")
    var args = command[2..^1]
    case command[1]:
        of "startpos", "fen", "kiwipete":
            if command[1] == "startpos":
                result.fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
            elif command[1] == "kiwipete":
                result.fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -"
            else:
                var fenString = ""
                var stop = 0
                for i, arg in args:
                    if arg == "moves":
                        break
                    if i > 0:
                        fenString &= " "
                    fenString &= arg
                    inc(stop)
                result.fen = fenString
                args = args[stop..^1]
            chessboard = newChessboardFromFEN(result.fen)
            let
                sideToMove = chessboard.sideToMove
                attackers = chessboard.position.attackers(chessboard.position.kingSquare(sideToMove.opposite()), sideToMove)
            if not attackers.isEmpty():
                return UCICommand(kind: Unknown, reason: "position is illegal: opponent must not be in check")
            if command.len() > 2 and args.len() > 0:
                var i = 0
                while i < args.len():
                    if args[i] == "moves":
                        var j = i + 1
                        while j < args.len():
                            let r = handleUCIMove(session, chessboard, args[j])
                            if r.move == nullMove():
                                if r.cmd.reason.len() > 0:
                                    return UCICommand(kind: Unknown, reason: &"move {args[j]} is invalid ({r.cmd.reason})")
                                else:
                                    return UCICommand(kind: Unknown, reason: &"move {args[j]} is invalid")
                            result.moves.add(args[j])
                            inc(j)
                    inc(i)
        of "frc":
            if len(args) < 1:
                return UCICommand(kind: Unknown, reason: "missing scharnagl number for 'position frc' command")
            if len(args) > 1:
                return UCICommand(kind: Unknown, reason: "too many arguments for 'position frc' command")
            try:
                let scharnaglNumber = args[0].parseInt()
                if scharnaglNumber notin 0..959:
                    return UCICommand(kind: Unknown, reason: &"scharnagl number must be 0 <= n < 960")
                result = session.handleUCIPositionCommand(@["position", "fen", scharnaglNumber.scharnaglToFEN()])
                if not session.searcher.state.chess960.load():
                    if session.debug:
                        echo "info automatically enabling Chess960 support"
                    session.searcher.state.chess960.store(true)
                return
            except ValueError:
                return UCICommand(kind: Unknown, reason: &"invalid integer for 'position frc' command")
        of "dfrc":
            if len(args) < 1:
                return UCICommand(kind: Unknown, reason: "missing white scharnagl number for 'position dfrc' command")
            if len(args) > 2:
                return UCICommand(kind: Unknown, reason: "too many arguments for 'position dfrc' command")

            try:
                var whiteScharnaglNumber: int
                var blackScharnaglNumber: int
                if len(args) == 2:
                    whiteScharnaglNumber = args[0].parseInt()
                    blackScharnaglNumber = args[1].parseInt()
                    if whiteScharnaglNumber notin 0..959 or blackScharnaglNumber notin 0..959:
                        return UCICommand(kind: Unknown, reason: &"scharnagl numbers must be 0 <= n < 960")
                else:
                    let n = args[0].parseInt()
                    if n >= 960 * 960:
                        return UCICommand(kind: Unknown, reason: &"scharnagl index must be 0 <= n < 921600")
                    whiteScharnaglNumber = n mod 960
                    blackScharnaglNumber = n div 960
                result = session.handleUCIPositionCommand(@["position", "fen", scharnaglToFEN(whiteScharnaglNumber, blackScharnaglNumber)])
                if not session.searcher.state.chess960.load():
                    if session.debug:
                        echo "info automatically enabling Chess960 support"
                    session.searcher.state.chess960.store(true)
                return
            except ValueError:
                return UCICommand(kind: Unknown, reason: &"invalid integer for 'position dfrc' command")
        else:
            return UCICommand(kind: Unknown, reason: &"unknown subcomponent '{command[1]}' for 'position' command")
    session.board.positions.setLen(0)
    for position in chessboard.positions:
        session.board.positions.add(position.clone())


proc parseUCICommand(session: var UCISession, command: string): UCICommand =
    var cmd = command.replace("\t", "").splitWhitespace()
    result = UCICommand(kind: Unknown)
    var current = 0
    while current < cmd.len():
        # Try bare commands first, then simple commands, then standard UCI commands.
        # We call toLowerAscii because parseEnum does style-insensitive comparisons
        # and they bother me greatly
        try:
            let bareCmd = parseEnum[BareUCICommand](cmd[current].toLowerAscii())
            inc(current)
            if current != cmd.len() and bareCmd != Barbecue:
                return UCICommand(kind: Unknown, reason: &"too many arguments for '{cmd[current - 1]}' command")
            if bareCmd != Barbecue:
                # The easter egg is another special case which requires
                # more validation
                return UCICommand(kind: Bare, bareCmd: bareCmd)
        except ValueError:
            try:
                let simpleCmd = parseEnum[SimpleUCICommand](cmd[current].toLowerAscii())
                let argCount = cmd.high() - current
                if argCount > 1:
                    return UCICommand(kind: Unknown, reason: &"too many arguments for '{cmd[current]}' command")
                if argCount < 1 and simpleCmd != Help:
                    # Help is the only simple command taking in an *optional*
                    # argument!
                    return UCICommand(kind: Unknown, reason: &"insufficient arguments for '{cmd[current]}' command")
                if argCount > 0:
                    inc(current)
                    return UCICommand(kind: Simple, simpleCmd: simpleCmd, arg: cmd[current])
                else:
                    return UCICommand(kind: Simple, simpleCmd: simpleCmd, arg: "")
            except ValueError:
                discard
        case cmd[current]:
            of "getScale":
                inc(current)
                let currMean = parseFloat(cmd[current])
                inc(current)
                let newMean = parseFloat(cmd[current])
                return UCICommand(kind: GetScale, currAbsMean: currMean, newAbsMean: newMean)
            of "isready":
                return UCICommand(kind: IsReady)
            of "uci":
                return UCICommand(kind: Uci)
            of "stop":
                return UCICommand(kind: Stop)
            of "help":
                # TODO: Help with submenus
                return UCICommand(kind: Simple, arg: "")
            of "ucinewgame":
                return UCICommand(kind: NewGame)
            of "quit":
                return UCICommand(kind: Quit)
            of "ponderhit":
                return UCICommand(kind: PonderHit)
            of "debug":
                if current == cmd.high():
                    return UCICommand(kind: Unknown, reason: "expecting 'on' or 'off' after 'debug' command")
                case cmd[current + 1]:
                    of "on":
                        return UCICommand(kind: Debug, on: true)
                    of "off":
                        return UCICommand(kind: Debug, on: false)
                    else:
                        return UCICommand(kind: Unknown, reason: &"expecting 'on' or 'off' after 'debug' command, got '{cmd[current + 1]}' instead")
            of "position":
                return session.handleUCIPositionCommand(cmd)
            of "go":
                return session.handleUCIGoCommand(cmd)
            of "set":
                inc(current)
                result = UCICommand(kind: Set)
                if len(cmd) != 3:
                    return UCICommand(kind: Unknown, reason: &"wrong number of arguments for set")
                let cmd = session.parseUCICommand(&"setoption name {cmd[current]} value {cmd[current + 1]}")
                result.name = cmd.name
                result.value = cmd.value
                inc(current, 2)
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
                    return UCICommand(kind: Bare, bareCmd: Barbecue)
            else:
                # Unknown UCI commands should be ignored. Attempt
                # to make sense of the input regardless
                inc(current)


const
    NO_INCREMENT_TC_DETECTED = "Heimdall has not been tested nor designed to play without increment and is likely to perform poorly as a result. If you really wanna do this, set the EnableWeirdTCs option to true first."
    CYCLIC_TC_DETECTED = "Heimdall has not been tested to work with cyclic (movestogo) time controls and is likely to perform poorly as a result. If you really wanna do this, set the EnableWeirdTCs option to true first."
    PONDER_OPT_REQUIRED = "A 'go ponder' command was sent, but pondering is not enabled via the UCI 'Ponder' option: please enable it in your program of choice and try again"

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
            version &= &"-beta-{COMMIT}"
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


proc createSearchWorker(session: UCISession): UCISearchWorker =
    new(result)
    result.channels.receive.open(0)
    result.channels.send.open(0)
    result.session = session

proc getResponse(worker: UCISearchWorker): WorkerResponse {.inline.} =
    return worker.channels.send.recv()

proc getAction(worker: UCISearchWorker): WorkerCommand {.inline.} =
    return worker.channels.receive.recv()

proc waitFor(worker: UCISearchWorker, response: WorkerResponse) {.inline.} =
    doAssert worker.getResponse() == response

func simpleCmd(kind: WorkerAction): WorkerCommand = WorkerCommand(kind: kind)

proc sendAction(worker: UCISearchWorker, command: WorkerCommand) {.inline.} =
    worker.channels.receive.send(command)

proc sendResponse(worker: UCISearchWorker, response: WorkerResponse) {.inline.} =
    worker.channels.send.send(response)


proc searchWorkerLoop(self: UCISearchWorker) {.thread.} =
    ## Finds the best move in the current position and
    ## prints it

    while true:
        let action = self.getAction()
        if self.session.debug:
            echo &"info string worker received action: {action.kind}"
        case action.kind:
            of Exit:
                if self.session.debug:
                    echo &"info string worker shutting down"
                self.sendResponse(Exiting)
                break
            of Search:
                if self.session.debug:
                    echo &"info string worker beginning search on UCI command {action.command}"
                var
                    timeRemaining = (if self.session.board.position.sideToMove == White: action.command.wtime else: action.command.btime)
                    increment = (if self.session.board.position.sideToMove == White: action.command.winc else: action.command.binc)
                    timePerMove = action.command.moveTime.isSome()

                if not self.session.enableWeirdTCs and not (timePerMove or timeRemaining.isNone()) and (increment.isNone() or increment.get() == 0):
                    stderr.writeLine(&"info string {NO_INCREMENT_TC_DETECTED}")
                    # Resign
                    echo "bestmove 0000"
                    continue
                # Code duplication is ugly, but the condition would get ginormous if I were to do it in one if statement
                if not self.session.enableWeirdTCs and (action.command.movesToGo.isSome() and action.command.movesToGo.get() != 0):
                    # We don't even implement the movesToGo TC (it's old af), so this warning is especially
                    # meaningful
                    stderr.writeLine(&"info string {CYCLIC_TC_DETECTED}")
                    echo "bestmove 0000"
                    continue
                # Setup search limits

                # Remove limits from previous search
                self.session.searcher.limiter.clear()
                self.session.searcher.state.mateDepth.store(none(int))

                # Add limits from new UCI command. Multiple limits are supported!
                if action.command.depth.isSome():
                    self.session.searcher.limiter.addLimit(newDepthLimit(action.command.depth.get()))
                if action.command.nodes.isSome():
                    if not self.session.datagenMode:
                        # When not in datagen mode, the values of UseSoftNodes and HardNodeLimit are ignored:
                        # the limit in the go command is always a hard limit
                        self.session.searcher.limiter.addLimit(newNodeLimit(action.command.nodes.get()))
                    else:
                        # If in datagen mode, but not using soft nodes, the node limit is the smallest between
                        # the globally configured limit (if nonzero) and the one provided in the go command
                        if not self.session.useSoftNodes:
                            let limit = block:
                                if self.session.hardNodeLimit > 0:
                                    min(self.session.hardNodeLimit.uint64, action.command.nodes.get())
                                else:
                                    action.command.nodes.get()
                            self.session.searcher.limiter.addLimit(newNodeLimit(limit))
                        else:
                            # Otherwise, use the limit in the go command as the soft limit (with some extra bits
                            # for soft limit randomization) and the globally configured limit (if nonzero) as the
                            # hard limit. If the hard limit is smaller than the soft limit, then it will be overridden
                            # by the soft limit
                            let softLimit = block:
                                let
                                    minimum = action.command.nodes.get()
                                    maximum = max(action.command.nodes.get(), self.session.softNodeRandomLimit.uint64)
                                if maximum != minimum:
                                    rand(minimum..maximum)
                                else:
                                    minimum
                            let hardLimit = max(self.session.hardNodeLimit.uint64, softLimit)
                            self.session.searcher.limiter.addLimit(newNodeLimit(softLimit, hardLimit))

                if timeRemaining.isSome():
                    if increment.isSome():
                        self.session.searcher.limiter.addLimit(newTimeLimit(timeRemaining.get(), increment.get(), self.session.overhead))
                    else:
                        self.session.searcher.limiter.addLimit(newTimeLimit(timeRemaining.get(), 0, self.session.overhead))

                if timePerMove:
                    self.session.searcher.limiter.addLimit(newTimeLimit(action.command.moveTime.get(), self.session.overhead))

                if action.command.mate.isSome():
                    let depth = action.command.mate.get()
                    self.session.searcher.state.mateDepth.store(some(depth))
                    self.session.searcher.limiter.addLimit(newMateLimit(depth))

                if action.command.ponder and not self.session.canPonder:
                    # Since some GUIs might misbehave, we require that Ponder be set to
                    # true to start a search when go ponder is detected. This should make
                    # it obvious that there's a problem!
                    stderr.writeLine(&"info string {PONDER_OPT_REQUIRED}")
                    echo "bestmove 0000"
                    continue

                self.session.searcher.setBoardState(self.session.board.positions)
                var line = self.session.searcher.search(action.command.searchmoves, false, self.session.canPonder and action.command.ponder,
                                                        self.session.minimal, self.session.variations)[0]
                let chess960 = self.session.searcher.state.chess960.load()
                for move in line.mitems():
                    if move == nullMove():
                        break
                    if move.isCastling() and not chess960:
                        # Hide the fact we're using FRC internally
                        if move.isLongCastling():
                            move.targetSquare = makeSquare(rank(move.targetSquare), file(move.targetSquare) + pcs.File(2))
                        else:
                            move.targetSquare = makeSquare(rank(move.targetSquare), file(move.targetSquare) - pcs.File(1))
                # No limit has expired but the search has completed:
                # If this is a `go infinite` command, UCI tells us we must
                # not print a best move until we're told to stop explicitly,
                # so we spin until that happens
                if action.command.infinite:
                    while not self.session.searcher.shouldStop():
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
                if self.session.isMixedMode and not self.session.searcher.cancelled():
                    # Search exited because an internal limit was hit: make sure the command
                    # prompt is reprinted
                    stdout.write("cmd> ")
                    stdout.flushFile()
                self.session.isInfiniteSearch = false
                self.sendResponse(SearchComplete)


proc startUCISession* =
    ## Begins listening for UCI commands

    setControlCHook(proc () {.noconv.} = stderr.writeLine("info string SIGINT detected, exiting"); quit(0))
    echo &"{getVersionString()} by nocturn9x (see LICENSE)"
    var
        cmd: UCICommand
        cmdStr: string
        session = UCISession(hashTableSize: 64, board: newDefaultChessboard(), variations: 1, overhead: 250, isMixedMode: true)
        transpositionTable = allocHeapAligned(TTable, 64)
        parameters = getDefaultParameters()
        searchWorker = session.createSearchWorker()
        # Used for the StaticEval command so we don't mess with the eval
        # state of the searcher
        evalState = newEvalState(verbose=false)
        searchWorkerThread: Thread[UCISearchWorker]

    # Start search worker
    createThread(searchWorkerThread, searchWorkerLoop, searchWorker)
    transpositionTable[] = newTranspositionTable(session.hashTableSize * 1024 * 1024)
    transpositionTable.init(1)
    session.searcher = newSearchManager(session.board.positions, transpositionTable, parameters)

    let isTTY = isatty(stdout)
    if not isTTY or getEnv("NO_TUI").len() != 0:
        session.isMixedMode = false

    if not isTTY or getEnv("NO_COLOR").len() != 0:
        session.searcher.setUCIMode(true)
    else:
        printLogo()

    while true:
        try:
            if session.isMixedMode and (not session.searcher.isSearching() or session.minimal):
                stdout.write("cmd> ")
            cmdStr = readLine(stdin).strip(leading=true, trailing=true, chars={'\t', ' '})
            if cmdStr.len() == 0:
                if session.debug:
                    echo "info string received empty input, ignoring it"
                continue
            cmd = session.parseUCICommand(cmdStr)
            if session.debug:
                echo &"info string received command '{cmdStr}' -> {cmd}"
            if cmd.kind == Unknown:
                if cmd.reason.len() > 0:
                    stderr.writeLine(&"info string error: received unknown or invalid command '{cmdStr}' -> {cmd.reason}")
                else:
                    stderr.writeLine(&"info string error: received unknown or invalid command '{cmdStr}'")
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
                                echo &"Enemy pieces attacking the given square:\n{session.board.position.attackers(cmd.arg.toSquare(), session.board.sideToMove.opposite())}"
                            except ValueError:
                                stderr.writeLine("error: invalid square")
                                continue
                        of Defenders:
                            try:
                                echo &"Friendly pieces defending the given square:\n{session.board.position.attackers(cmd.arg.toSquare(), session.board.sideToMove)}"
                            except ValueError:
                                stderr.writeLine("error: invalid square")
                                continue
                        of GetPiece:
                            try:
                                echo session.board.position.on(cmd.arg)
                            except ValueError:
                                stderr.writeLine("error: invalid square")
                                continue
                        of MakeMove:
                            let r = session.parseUCIMove(session.board.position, cmd.arg)
                            if r.move == nullMove():
                                echo &"Error, {cmd.arg} is invalid: {r.command.reason}"
                                continue
                            else:
                                if not session.board.isLegal(r.move):
                                    echo &"Error, {cmd.arg} is illegal"
                                else:
                                    session.board.doMove(r.move)
                                    echo &"{cmd.arg} was played on the board"
                        of DumpNet:
                            echo &"Dumping built-in network {NET_ID} to '{cmd.arg}'"
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
                                session.board.unmakeMove()
                            else:
                                session.board.makeNullMove()
                        of SideToMove:
                            echo &"Side to move: {session.board.sideToMove}"
                        of EnPassant:
                            let target = session.board.position.enPassantSquare
                            if target != nullSquare():
                                echo &"En passant target: {target.toUCI()}"
                            else:
                                echo "En passant target: None"
                        of CastlingRights:
                            let castleRights = session.board.position.castlingAvailability[session.board.sideToMove]
                            let canCastle = session.board.canCastle()
                            echo &"Castling targets for {($session.board.sideToMove).toLowerAscii()}:\n  - King side: {(if castleRights.king != nullSquare(): castleRights.king.toUCI() else: \"None\")}\n  - Queen side: {(if castleRights.queen != nullSquare(): castleRights.queen.toUCI() else: \"None\")}"
                            echo &"{($session.board.sideToMove)} can currently castle:\n  - King side: {(if canCastle.king != nullSquare(): \"yes\" else: \"no\")}\n  - Queen side: {(if canCastle.queen != nullSquare(): \"yes\" else: \"no\")}"
                        of InCheck:
                            echo &"{session.board.sideToMove} king in check: {(if session.board.inCheck(): \"yes\" else: \"no\")}"
                        of Checkers:
                            echo &"Pieces checking the {($session.board.sideToMove).toLowerAscii()} king:\n{session.board.position.checkers}"
                        of UnmakeMove:
                            if session.board.positions.len() == 1:
                                echo "No move to undo"
                            else:
                                session.board.unmakeMove()
                        of Repeated:
                            echo "Position is drawn by repetition: ", if session.board.drawnByRepetition(0): "yes" else: "no"
                        of StaticEval:
                            evalState.init(session.board)  # Slow, but this is simple and correct
                            let rawEval = session.board.evaluate(evalState)
                            echo &"Raw eval: {rawEval} engine units"
                            echo &"Normalized eval: {rawEval.normalizeScore(session.board.material())} cp"
                        of PrintFEN:
                            echo &"FEN of the current position: {session.board.position.toFEN()}"
                        of PrintASCII:
                            echo $session.board
                        of PrettyPrint:
                            echo session.board.pretty()
                        of ZobristKey:
                            echo &"Current Zobrist key: 0x{session.board.zobristKey.uint64.toHex().toLowerAscii()} ({session.board.zobristKey})"
                        of PawnKey:
                            echo &"Current pawn Zobrist key: 0x{session.board.pawnKey.uint64.toHex().toLowerAscii()} ({session.board.pawnKey})"
                        of MajorKey:
                            echo &"Current major piece Zobrist key: 0x{session.board.majorKey.uint64.toHex().toLowerAscii()} ({session.board.majorKey})"
                        of MinorKey:
                            echo &"Current minor piece Zobrist key: 0x{session.board.minorKey.uint64.toHex().toLowerAscii()} ({session.board.minorKey})"
                        of NonpawnKeys:
                            echo &"Current nonpawn piece Zobrist key for white: 0x{session.board.nonpawnKey(White).uint64.toHex().toLowerAscii()} ({session.board.nonpawnKey(White)})"
                            echo &"Current nonpawn piece Zobrist key for black: 0x{session.board.nonpawnKey(Black).uint64.toHex().toLowerAscii()} ({session.board.nonpawnKey(Black)})"
                        of GameStatus:
                            stdout.write("Current game status: ")
                            if session.board.isStalemate():
                                echo "drawn by stalemate"
                            elif session.board.drawnByRepetition(0):
                                echo "drawn by repetition"
                            elif session.board.isDrawn(0):
                                echo "drawn"
                            elif session.board.isCheckmate():
                                echo &"{session.board.sideToMove.opposite()} wins by checkmate"
                            else:
                                echo "in progress"
                        of Threats:
                            echo &"Squares threathened by the opponent in the current position:\n{session.board.position.threats}"
                        of Material:
                            echo &"Material currently on the board: {session.board.material()} points"
                        of InputBucket:
                            let kingSq = session.board.position.kingSquare(session.board.sideToMove)
                            echo &"Current king input bucket for {session.board.sideToMove}: {kingBucket(session.board.sideToMove, kingSq)}"
                        of OutputBucket:
                            const divisor = 32 div NUM_OUTPUT_BUCKETS
                            let outputBucket = (session.board.pieces().count() - 2) div divisor
                            echo &"Current output bucket: {outputBucket}"
                        of PrintNetName:
                            echo &"ID of the built-in network: {NET_ID}"
                        of PinnedPieces:
                            echo &"Orthogonal pins:\n{session.board.position.orthogonalPins}"
                            echo &"Diagonal pins:\n{session.board.position.diagonalPins}"
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
                    session.searcher.histories.release()
                    quit(0)
                of IsReady:
                    echo "readyok"
                of Debug:
                    session.debug = cmd.on
                of NewGame:
                    if session.searcher.isSearching():
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
                    if cmd.perft.isSome():
                        let perftInfo = cmd.perft.get()
                        if perftInfo.bulk:
                            let t = cpuTime()
                            let nodes = session.board.perft(perftInfo.depth, divide=perftInfo.divide, bulk=true, verbose=perftInfo.verbose, capturesOnly=perftInfo.capturesOnly).nodes
                            let tot = cpuTime() - t
                            if perftInfo.divide:
                                echo ""
                            echo &"Nodes searched (bulk-counting: on): {nodes}"
                            echo &"Time taken: {tot:.3f} seconds\nNodes per second: {round(nodes / tot).uint64}"
                        else:
                            let t = cpuTime()
                            let data = session.board.perft(perftInfo.depth, divide=perftInfo.divide, bulk=false, verbose=perftInfo.verbose, capturesOnly=perftInfo.capturesOnly)
                            let tot = cpuTime() - t
                            if perftInfo.divide:
                                echo ""
                            echo &"Nodes searched (bulk-counting: off): {data.nodes}"
                            echo &"  - Captures: {data.captures}"
                            echo &"  - Checks: {data.checks}"
                            echo &"  - E.P: {data.enPassant}"
                            echo &"  - Checkmates: {data.checkmates}"
                            echo &"  - Castles: {data.castles}"
                            echo &"  - Promotions: {data.promotions}"
                            echo ""
                            echo &"Time taken: {tot:.3f} seconds\nNodes per second: {round(data.nodes / tot).uint64}"
                    else:
                        session.isInfiniteSearch = cmd.infinite
                        if session.searcher.isSearching():
                            # Search already running. Let's teach the user a lesson
                            session.searcher.cancel()
                            searchWorker.waitFor(SearchComplete)
                            echo "info string premium membership is required to send go during search. Please check out https://n9x.co/heimdall-premium for details"
                            continue
                        if session.board.isGameOver():
                            stderr.writeLine("info string position is in terminal state (checkmate or draw)")
                            echo "bestmove 0000"
                            continue
                        # Start the clock as soon as possible to account
                        # for startup delays in our time management
                        session.searcher.startClock()
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
                        # Same as a bove: give time for the search to actually stop
                        sleep(1)
                    if session.debug:
                        echo "info string search stopped"
                of SetOption, Set:
                    if session.searcher.isSearching():
                        # Cannot set options during search
                        continue
                    let
                        # UCI mandates that names and values are not to be case sensitive
                        name = cmd.name.toLowerAscii()
                        value = cmd.value.toLowerAscii()
                    if cmd.kind == Set:
                        if not session.isMixedMode:
                            echo "info string this command is disabled while in UCI mode, send icu to revert to mixed mode"
                            continue
                        else:
                            echo &"Setting {cmd.name} to {cmd.value}"
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
                                        echo &"Invalid hash table size '{cmd.value}'"
                                        continue
                                    newSize = size.uint64 div 1048576
                                    echo &"Note: '{cmd.value}' parsed to {newSize} MiB"
                                    if newSize notin 1'u64..33554432'u64:
                                        echo &"Erorr: selected hash table size is too big (n must be in 1 <= n <= 33554432 MiB)"
                                        continue
                            else:
                                newSize = value.parseBiggestUInt()
                            doAssert newSize in 1'u64..33554432'u64
                            if newSize != transpositionTable.size:
                                if session.debug:
                                    echo &"info string resizing TT from {session.hashTableSize} MiB To {newSize} MiB"
                                transpositionTable.resize(newSize * 1048576, session.workers + 1)
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
                            session.searcher.histories.clear()
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
                                    parameters.setParameter(cmd.name, value.parseInt())
                                else:
                                    stderr.writeLine(&"info string unknown option '{cmd.name}'")
                            else:
                                stderr.writeLine(&"info string unknown option '{cmd.name}'")
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
                    echo &"Expected scaling factor: {scale:.6f}"
        except IOError:
            echo ""
            stderr.writeLine("info string I/O error while reading from stdin, exiting")
            quit(0)
        except EOFError:
            echo ""
            stderr.writeLine("info string EOF received while reading from stdin, exiting")
            quit(0)