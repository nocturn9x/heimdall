import std/[strutils, terminal, strformat, options]

import heimdall/[board, search, movegen]
import heimdall/util/logs


type
    UCISession* = ref object
        # Print verbose logs for every action
        debug*: bool
        board*: Chessboard
        searcher*: SearchManager
        # Size of the transposition table (in mebibytes, aka the only sensible unit.)
        hashTableSize*: uint64
        # Number of (extra) workers to use during search alongside
        # the main search thread. This is always Threads - 1
        workers*: int
        # Whether we allow the user to have heimdall play
        # with weird, untested time controls (e.g. increment == 0)
        enableWeirdTCs*: bool
        # The number of principal variations to search
        variations*: int
        # The move overhead
        overhead*: int
        # Are we alloved to ponder when go ponder is sent?
        canPonder*: bool
        # Do we print minimal logs? (only final depth)
        minimal*: bool
        datagenMode*: bool
        # Should we interpret the nodes from go nodes
        # as a soft bound instead of a hard bound? Only
        # active in datagen mode
        useSoftNodes*: bool
        # Hard node limit applied across any one search. Only
        # active in datagen mode
        hardNodeLimit*: int
        # Only applies in datagen mode: if this is set, the soft
        # node limit applied to each search will be randomly picked
        # using the value of go nodes as the lower bound and the value
        # of softNodeRandomLimit as the upper bound
        randomizeSoftNodes*: bool
        # The upper bound for the soft node limit when using soft node
        # limit randomization (defaults to the lower bound if not set)
        softNodeRandomLimit*: int
        # Used to avoid blocking forever when sending wait after a
        # go infinite command
        isInfiniteSearch*: bool
        # Are we in mixed mode?
        isMixedMode*: bool
        # Are we allowed to print colors to the terminal?
        useColor*: bool

    BareUCICommand* = enum
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

    SimpleUCICommand* = enum
        Help      = "help"
        Attackers = "atk"
        Defenders = "def"
        GetPiece  = "on"
        MakeMove  = "move"
        DumpNet   = "verbatim"
        GetStats  = "getStats"

    UCICommandType* = enum
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

    UCICommand* = object
        case kind*: UCICommandType
            of Debug:
                on*: bool
            of Position:
                fen*: string
                moves*: seq[string]
            of SetOption, Set:
                name*: string
                value*: string
            of Unknown:
                reason*: string
            of Go:
                infinite*: bool
                wtime*: Option[int]
                btime*: Option[int]
                winc*: Option[int]
                binc*: Option[int]
                movesToGo*: Option[int]
                depth*: Option[int]
                moveTime*: Option[int]
                nodes*: Option[uint64]
                searchmoves*: seq[Move]
                ponder*: bool
                mate*: Option[int]
                # Custom bits
                perft*: Option[tuple[depth: int, verbose, capturesOnly, divide, bulk: bool]]
                # Treat the NNUE as a policy network: evaluate every legal move
                # and pick the one that yields the best static eval
                eval*: bool
            of Simple:
                simpleCmd*: SimpleUCICommand
                arg*: string
            of Bare:
                bareCmd*: BareUCICommand
            of GetScale:
                currAbsMean*: float
                newAbsMean*: float
            else:
                discard

    WorkerAction* = enum
        Search, Exit

    WorkerCommand* = object
        case kind*: WorkerAction
            of Search:
                command*: UCICommand
            else:
                discard

    WorkerResponse* = enum
        Exiting, SearchComplete

    UCISearchWorker* = ref object
        session*: UCISession
        channels*: tuple[receive: Channel[WorkerCommand], send: Channel[WorkerResponse]]


const
    NO_INCREMENT_TC_DETECTED* = "Heimdall has not been tested nor designed to play without increment and is likely to perform poorly as a result. If you really wanna do this, set the EnableWeirdTCs option to true first."
    CYCLIC_TC_DETECTED* = "Heimdall has not been tested to work with cyclic (movestogo) time controls and is likely to perform poorly as a result. If you really wanna do this, set the EnableWeirdTCs option to true first."
    PONDER_OPT_REQUIRED* = "A 'go ponder' command was sent, but pondering is not enabled via the UCI 'Ponder' option: please enable it in your program of choice and try again"


func isGitHash(s: string): bool =
    if s.len == 0:
        return false
    for c in s:
        if c notin {'0'..'9', 'a'..'f', 'A'..'F'}:
            return false
    return true


const COMMIT* = block:
    var s = staticExec("git rev-parse --short=6 HEAD")
    s.stripLineEnd()
    if s.isGitHash():
        s
    else:
        "unknown"
const BRANCH* = block:
    var s = staticExec("git rev-parse --abbrev-ref HEAD")
    s.stripLineEnd()
    if s.len == 0 or s.contains('\n') or s.startsWith("fatal:") or s.startsWith("git:"):
        "unknown"
    else:
        s
# Note: check the Makefile for their real values!
const isRelease* {.booldefine.} = false
const isBeta* {.booldefine.} = false
const VERSION_MAJOR* {.define: "majorVersion".} = 1
const VERSION_MINOR* {.define: "minorVersion".} = 0
const VERSION_PATCH* {.define: "patchVersion".} = 0


func getVersionString*: string {.compileTime.} =
    var version: string
    if isRelease:
        version = &"{VERSION_MAJOR}.{VERSION_MINOR}.{VERSION_PATCH}"
        if isBeta:
            version &= &"-beta-{COMMIT}"
    else:
        version = &"dev ({BRANCH} at {COMMIT})"
    return &"Heimdall {version}"


proc printLogo*(colored=true) =
    # Thanks @tsoj!
    stdout.styledWrite colored, styleDim, "|'.                \n"
    stdout.styledWrite colored, styleDim, " \\ \\               \n"
    stdout.styledWrite colored, styleDim, "  \\", resetStyle, styleBright, fgCyan, "H", resetStyle, styleDim, "\\              \n"
    stdout.styledWrite colored, styleDim, "   \\", resetStyle, styleBright, fgBlue, "e", resetStyle, styleDim, "\\", resetStyle, " .~.         \n"
    stdout.styledWrite colored, styleDim, "    \\", resetStyle, styleBright, fgCyan, "i", resetStyle, styleDim, "\\", resetStyle, " \\", styleDim, "\\", resetStyle, "'.       \n"
    stdout.styledWrite colored, "     \\", styleBright, fgGreen, "m", resetStyle, "\\ |",styleDim, "|\\", resetStyle, "\\      \n"
    stdout.styledWrite colored, "   _  \\", styleBright, fgYellow, "d", resetStyle, "\\/", styleDim, "/|", resetStyle, "|      \n"
    stdout.styledWrite colored, "  / \\>=\\", styleBright, fgRed, "a", resetStyle, "\\", styleDim, "//", resetStyle, "/      \n"
    stdout.styledWrite colored, "  |  |", styleDim, ">=", resetStyle, "\\", styleBright, fgMagenta, "l", resetStyle, "\\/       \n"
    stdout.styledWrite colored, "   \\_/==~\\", styleBright, fgRed, "l",resetStyle, "\\       \n"
    stdout.styledWrite colored, "          \\ \\      \n"
    stdout.styledWrite colored, styleDim, "           \\", resetStyle, "\\", styleDim, "\\     \n"
    stdout.styledWrite colored, styleDim, "            \\", resetStyle, "\\", styleDim, "\\    \n"
    stdout.styledWrite colored, "          o", styleBright, styleDim, "==", resetStyle, styleBright, "<X>", styleDim, "==", resetStyle, "o\n"
    stdout.styledWrite colored, styleDim, "              ()   \n"
    stdout.styledWrite colored, styleDim, "               ()  \n"
    stdout.styledWrite colored, styleBright, "                O  "
    echo ""
