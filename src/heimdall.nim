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
import std/[os, math, times, monotimes, atomics, parseopt, strutils, strformat, options, random]

import heimdall/[moves, board, search, movegen, position, transpositions, eval]
import heimdall/util/[magics, limits, tunables, book_augment, logs, scharnagl, relabel as relabelUtil]
import heimdall/uci/session
import heimdall/util/simd_dispatch


when not defined(windows):
    import heimdall/tui/app


randomize()


const benchFens = staticRead("heimdall/resources/misc/bench.txt").splitLines()


proc runBench(depth: int = 13, threads: int = 1, silent: bool = false) =
    let transpositionTable = newTranspositionTable(64 * 1024 * 1024)
    var mgr = newSearchManager(@[startpos()], transpositionTable)
    mgr.limiter.addLimit(newDepthLimit(depth))
    mgr.logger.setColor(not existsEnv("NO_COLOR"))
    if threads > 1:
        stderr.writeLine("info string warning: multithreaded bench is not deterministic")
        mgr.setWorkerCount(threads - 1)

    echo "info string Benchmark started"
    var
        nodes = 0'u64
        bestMoveTotalNodes = 0'u64
    let
        startTime = cpuTime()
        startWall = getMonoTime()
    for i, fen in benchFens:
        if not silent:
            echo &"Position {i + 1}/{len(benchFens)}: {fen}\n"
        mgr.setBoard(@[fromFEN(fen)])

        let line = mgr.search(silent=silent)[0]
        if not silent:
            if line.moves[1] == nullMove():
                echo &"bestmove {line.moves[0].toUCI()}"
            else:
                echo &"bestmove {line.moves[0].toUCI()} ponder {line.moves[1].toUCI()}"
        let
            move = mgr.statistics.bestMove.load(moRelaxed)
            totalNodes = mgr.limiter.totalNodes()
            bestMoveNodes = mgr.statistics.spentNodes[move.startSquare][move.targetSquare].load(moRelaxed)
            bestMoveFrac = bestMoveNodes.float / totalNodes.float
        nodes += totalNodes
        bestMoveTotalNodes += bestMoveNodes
        if not silent:
            echo &"info string fraction of nodes spent on best move for this position: {round(bestMoveFrac * 100, 2)}% ({bestMoveNodes}/{totalNodes})"
            echo ""
    let
        # Process CPU time sums all search threads and understates parallel NPS.
        # Keep CPU timing for deterministic single-thread comparisons; use elapsed
        # monotonic time when measuring throughput across multiple threads.
        endTime = if threads == 1: cpuTime() - startTime
                  else: (getMonoTime() - startWall).inNanoseconds().float / 1_000_000_000
        bestMoveFrac = bestMoveTotalNodes.float / nodes.float
    if not silent:
        echo &"info string fraction of nodes spent on best move for this bench: {round(bestMoveFrac * 100, 2)}% ({bestMoveTotalNodes}/{nodes})"
    echo &"{nodes} nodes {round(nodes.float / endTime).int} nps"


proc runGenfens(command: string) =
    ## Generate opening positions for OpenBench's datagen interface.
    ##
    ## OpenBench passes this as one quoted argument, rather than as ordinary
    ## command-line options: `genfens N seed S book PATH [extra arguments]`.
    let args = command.splitWhitespace()
    if args.len < 6 or args[0] != "genfens" or args[2] != "seed" or args[4] != "book":
        stderr.writeLine("heimdall: genfens: expected 'genfens N seed S book PATH [options]'")
        quit(-1)

    var
        count: int
        seed: uint64
        plies = none(int)
        dfrc = false
        book: seq[Position] = @[]

    try:
        count = args[1].parseInt()
        seed = args[3].parseBiggestUInt()
        if count < 0:
            raise newException(ValueError, "count must not be negative")
    except ValueError:
        stderr.writeLine("heimdall: genfens: invalid count or seed")
        quit(-1)

    # Extra arguments are intentionally simple and extensible.  OpenBench
    # forwards this part verbatim, so accepting `plies N` and `moves N` gives
    # callers a useful way to control the generated line without changing the
    # fixed interface.
    var i = 6
    while i < args.len:
        if args[i] in ["plies", "moves", "depth"] and i + 1 < args.len:
            try:
                plies = some(args[i + 1].parseInt())
            except ValueError:
                stderr.writeLine(&"heimdall: genfens: invalid {args[i]} value")
                quit(-1)
            inc(i, 2)
        elif args[i] == "dfrc":
            if i + 1 >= args.len or args[i + 1] notin ["true", "false"]:
                stderr.writeLine("heimdall: genfens: dfrc requires true or false")
                quit(-1)
            dfrc = args[i + 1] == "true"
            inc(i, 2)
        else:
            inc(i)
    if plies.isSome() and plies.get() < 0:
        stderr.writeLine("heimdall: genfens: plies must not be negative")
        quit(-1)

    # An explicit DFRC request selects fresh starting positions instead of a book.
    if not dfrc and args[5].toLowerAscii() != "none":
        try:
            for line in lines(args[5]):
                let fields = line.strip().splitWhitespace()
                if fields.len < 4 or line.strip().startsWith("#"):
                    continue
                var halfmove = 0
                var fullmove = 1
                # Books used by OpenBench are EPD files.  Convert their hmvc
                # and fmvn operations to the two trailing FEN fields.
                var j = 4
                while j < fields.len:
                    if fields[j] == "hmvc" and j + 1 < fields.len:
                        halfmove = fields[j + 1].strip(chars = {';'}).parseInt()
                    elif fields[j] == "fmvn" and j + 1 < fields.len:
                        fullmove = fields[j + 1].strip(chars = {';'}).parseInt()
                    inc(j)
                book.add(fromFEN(fields[0..3].join(" ") & &" {halfmove} {fullmove}"))
        except CatchableError:
            stderr.writeLine(&"heimdall: genfens: could not read book '{args[5]}': {getCurrentExceptionMsg()}")
            quit(-1)

    var picker = initRand(seed.int64)
    for _ in 0..<count:
        let initial =
            if dfrc:
                fromFEN(scharnaglToFEN(picker.rand(0..959), picker.rand(0..959)))
            elif book.len == 0:
                startpos()
            else:
                book[picker.rand(0 ..< book.len)]
        # Draw separately for each opening, using the same seeded RNG as the
        # starting position and moves. Explicit lengths consume no extra draw.
        let openingPlies = if plies.isSome(): plies.get() else: picker.rand(8..9)
        var board = newChessboard(@[initial])
        var moves = newMoveList()
        for _ in 0..<openingPlies:
            moves.clear()
            board.generateMoves(moves)
            if moves.len == 0:
                break
            board.doMove(moves[picker.rand(0 ..< moves.len.int)])
        echo &"info string genfens {board.position.toFEN(chess960=dfrc)}"


when isMainModule:
    setControlCHook(proc () {.noconv.} = echo ""; quit(0))
    basicTests()
    let rawArgs = commandLineParams()
    if rawArgs == @["simd"]:
        printSimdInfo()
        quit(0)
    if rawArgs.len > 0:
        # OpenBench invokes genfens as a quoted command string and appends a
        # second quoted `quit` command.  Handle that protocol before parseopt,
        # whose normal option grammar deliberately rejects space-separated
        # values for Heimdall's existing subcommands.
        if rawArgs[0].startsWith("genfens "):
            runGenfens(rawArgs[0])
            quit(0)
        elif rawArgs[0] == "genfens":
            var stopAt = rawArgs.len
            for i in 1..<rawArgs.len:
                if rawArgs[i] == "quit":
                    stopAt = i
                    break
            runGenfens(rawArgs[0..<stopAt].join(" "))
            quit(0)
    # This is horrible, but it works so ¯\_(ツ)_/¯
    var
        parser        = initOptParser(rawArgs)
        augment       = false
        magicGen      = false
        runUCI        = true
        testOnly      = false
        bench         = false
        getParams     = false
        benchDepth    = 13
        benchThreads  = 1
        benchSilent   = false
        prevSubCmd    = ""
        # Parameters for the data augmentation tool
        inputBook     = none(string)
        outputBook    = none(string)
        augmentDepth  = (min: 8, max: 8)
        bookSizeHint  = 1_000_000
        bookMaxExit   = Score(100)
        filterChecks  = true
        append        = false
        seed          = rand(int64.high())
        searcherDepth = 10
        searcherNodes = (soft: 5000'u64, hard: 1_000_000'u64)
        searcherHash  = 1'u64
        threads       = 1
        limit         = 0
        skip          = 0
        rounds        = 1
        # Parameters for viriformat relabelling
        relabel       = false
        relabelInput  = none(string)
        relabelOutput = none(string)
        relabelDepth  = none(int)
        relabelSoftNodesProvided = false
        relabelChunk  = 1024
        relabelJoin   = false

    var runTUI = false
    const subcommands = ["magics", "testonly", "bench", "spsa", "chonk", "relabel", "tui"]
    for kind, key, value in parser.getopt():
        case kind:
            of cmdArgument:
                if bench:
                    for c in key:
                        if not c.isDigit():
                            stderr.writeLine("heimdall: error: 'bench' subcommand requires a number as its only argument")
                            quit(-1)
                    benchDepth = key.parseInt()
                    continue

                let inSubCommand = bench or getParams or magicGen or testOnly or augment or relabel

                if key in subcommands and inSubCommand:
                    stderr.writeLine(&"heimdall: error: '{prevSubCmd}' subcommand does not accept any arguments")
                    quit(-1)

                if key notin subcommands:
                    if not inSubCommand:
                        stderr.writeLine(&"heimdall: error: unknown subcommand '{key}'")
                        quit(-1)
                    else:
                        stderr.writeLine(&"heimdall: error: '{prevSubCmd}' subcommand does not accept any arguments (to pass options, do --opt=value instead of --opt value)")
                        quit(-1)

                case key:
                    of "magics":
                        magicGen = true
                    of "testonly":
                        runUCI = false
                        testOnly = true
                    of "bench":
                        runUCI = false
                        bench = true
                    of "spsa":
                        runUCI = false
                        getParams = true
                    of "chonk":
                        # Hehe me make chonky book
                        augment = true
                    of "relabel":
                        runUCI = false
                        relabel = true
                    of "tui":
                        runUCI = false
                        runTUI = true
                    else:
                        discard
                prevSubCmd = key
            of cmdLongOption:
                if bench:
                    case key:
                        of "threads":
                            benchThreads = parseInt(value)
                            if benchThreads notin 1..1024:
                                stderr.writeLine("heimdall: bench: error: threads must be in 1..1024")
                                quit(-1)
                        of "silent":
                            benchSilent = true
                        else:
                            stderr.writeLine(&"heimdall: bench: error: unknown long option '{key}'")
                            quit(-1)
                elif augment:
                    case key:
                        of "input":
                            inputBook = some(value)
                        of "output":
                            outputBook = some(value)
                        of "nodes-soft":
                            searcherNodes.soft = parseBiggestUInt(value)
                        of "nodes-hard":
                            searcherNodes.hard = parseBiggestUInt(value)
                        of "hash":
                            searcherHash = parseBiggestUInt(value)
                        of "depth":
                            searcherDepth = parseBiggestInt(value)
                        of "moves":
                            augmentDepth.min = parseBiggestInt(value)
                            augmentDepth.max = augmentDepth.min
                        of "moves-min":
                            augmentDepth.min = parseBiggestInt(value)
                        of "moves-max":
                            augmentDepth.max = parseBiggestInt(value)
                        of "allow-checks":
                            filterChecks = false
                        of "max-exit":
                            bookMaxExit = Score(parseInt(value))
                        of "seed":
                            seed = parseBiggestInt(value)
                        of "size-hint":
                            bookSizeHint = parseBiggestInt(value)
                        of "threads":
                            threads = parseInt(value)
                        of "limit":
                            limit = parseInt(value)
                        of "skip":
                            skip = parseInt(value)
                        of "append":
                            append = true
                        of "rounds":
                            rounds = parseInt(value)
                        else:
                            stderr.writeLine(&"heimdall: chonk: error: unknown long option '{key}'")
                            quit(-1)
                elif relabel:
                    case key:
                        of "input":
                            relabelInput = some(value)
                        of "output":
                            relabelOutput = some(value)
                        of "nodes-soft":
                            searcherNodes.soft = parseBiggestUInt(value)
                            relabelSoftNodesProvided = true
                        of "nodes-hard":
                            searcherNodes.hard = parseBiggestUInt(value)
                        of "hash":
                            searcherHash = parseBiggestUInt(value)
                        of "depth":
                            relabelDepth = some(parseInt(value))
                        of "threads":
                            threads = parseInt(value)
                        of "chunk-size":
                            relabelChunk = parseInt(value)
                        of "limit":
                            limit = parseInt(value)
                        of "skip":
                            skip = parseInt(value)
                        of "join":
                            relabelJoin = true
                        else:
                            stderr.writeLine(&"heimdall: relabel: error: unknown long option '{key}'")
                            quit(-1)
                else:
                    stderr.writeLine(&"heimdall: error: unknown long option '{key}'")
                    quit(-1)
            of cmdShortOption:
                if bench:
                    case key:
                        of "t":
                            benchThreads = parseInt(value)
                            if benchThreads notin 1..1024:
                                stderr.writeLine("heimdall: bench: error: threads must be in 1..1024")
                                quit(-1)
                        of "s":
                            benchSilent = true
                        else:
                            stderr.writeLine(&"heimdall: bench: error: unknown short option '{key}'")
                            quit(-1)
                else:
                    stderr.writeLine(&"heimdall: error: unknown short option '{key}'")
                    quit(-1)
            of cmdEnd:
                break
    if relabel:
        if not relabelInput.isSome() or not relabelOutput.isSome():
            stderr.writeLine("heimdall: relabel: error: --input and --output are required")
            quit(-1)
        try:
            relabelViriformat(relabelInput.get(), relabelOutput.get(), RelabelConfig(
                depth: relabelDepth,
                nodes: searcherNodes,
                softNodesProvided: relabelSoftNodesProvided,
                hashMiB: searcherHash,
                threads: threads,
                chunkSize: relabelChunk,
                skip: skip,
                limit: limit,
                join: relabelJoin
            ))
        except CatchableError:
            stderr.writeLine(&"heimdall: relabel: error: {getCurrentExceptionMsg()}")
            quit(-1)
    elif not magicGen and not augment:
        if runTUI:
            when defined(windows):
                stderr.writeLine("heimdall: the built-in TUI is disabled on Windows because termios.h is unavailable")
                quit(-1)
            else:
                startTUI()
        elif runUCI:
            startUCISession()
        if bench:
            runBench(benchDepth, benchThreads, benchSilent)
        if getParams:
            echo getSPSAInput(getDefaultParameters())
    elif magicGen:
        magicWizard()
    elif augment:
        if not inputBook.isSome() or not outputBook.isSome():
            stderr.writeLine(&"heimdall: chonk: error: --input and --output are required")
            quit(-1)
        if rounds < 1:
            stderr.writeLine(&"heimdall: chonk: error: --rounds must be > 1")
            quit(-1)
        if rounds > 1:
            echo &"Running {rounds} consecutive rounds of book chonkening: note that this changes the meaning of the --seed option!"
        augmentBook(inputBook.get(), outputBook.get(), augmentDepth, limit, skip, bookSizeHint, bookMaxExit,
                    filterChecks, append, seed, (depth: searcherDepth, nodes: searcherNodes, hash: searcherHash),
                    threads, rounds)
    quit(0)
