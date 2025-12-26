import heimdall/[eval, board, moves, search, movegen, position, transpositions]
import heimdall/util/[wdl, limits, tunables]
import heimdall/util/memory/aligned


import std/[sets, math, times, strformat, atomics, random, terminal, os, strutils]


type
    WArg = tuple[workerID: int, depth: tuple[min, max: int], maxExit: int, filterChecks: bool, seed: int64,
                 searcherConfig: tuple[depth: int, nodes: tuple[soft, hard: uint64], hash: uint64],
                 positions, results: ptr seq[Position], counter: ptr Atomic[int], done: ptr Atomic[bool]]
    WThread = Thread[WArg]


proc workerProc(args: WArg) {.thread.} =
    var 
        picker = initRand(args.seed + args.workerID)
        transpositionTable = allocHeapAligned(TranspositionTable, 64)
        parameters = getDefaultParameters()
    transpositionTable[] = newTranspositionTable(args.searcherConfig.hash * 1024 * 1024)
    var searcher = newSearchManager(@[startpos()], transpositionTable, parameters, evalState=newEvalState(verbose=false))

    searcher.limiter.addLimit(newDepthLimit(args.searcherConfig.depth))
    searcher.limiter.addLimit(newNodeLimit(args.searcherConfig.nodes.soft, args.searcherConfig.nodes.hard))

    var 
        moves = newMoveList()
        valid: bool
    for position in args.positions[]:
        valid = true
        var board = newChessboard(@[position.clone()])
        # Note: assumes min <= max (enforced externally)
        let depth =
            if args.depth.max - args.depth.min > 0:
                picker.rand(args.depth.min..args.depth.max)
            else:
                args.depth.min
        for _ in 0..<depth:
            moves.clear()
            board.generateMoves(moves)
            if len(moves) == 0:
                # isGameOver generates the moves, but we
                # already have them so checking for a terminal
                # state is easy
                valid = false
                break
            board.makeMove(moves[picker.rand(0..len(moves))])
        if valid and args.filterChecks and board.inCheck():
            valid = false
        if valid:
            searcher.setBoardState(board.positions)
            searcher.histories.clear()
            transpositionTable.init(1)
            discard searcher.search(@[], true, false, false, 1)
            let score = normalizeScore(searcher.statistics.bestRootScore.load(moRelaxed), board.material())
            if abs(score) > args.maxExit:
                valid = false
        if valid:
            discard args.counter[].fetchAdd(1, moRelaxed)
            args.results[].add(board.position.clone())
    args.done[].store(true, moRelaxed)


proc augmentBook*(inputBook, outputBook: string, depth: tuple[min, max: int], limit, skip, sizeHint, maxExit: int, filterChecks,
                  append: bool, seed: int64, searcherConfig: tuple[depth: int, nodes: tuple[soft, hard: uint64], hash: uint64], threads, rounds: int) =
    var 
        inputFile = open(inputBook)
        outputFile = open(outputBook, if append: fmAppend else: fmWrite)
    defer: inputFile.close()
    defer: outputFile.close()

    echo &"""Loading book at '{inputBook}'

Info:
- Seed for this run: {seed}
- Max. exit: ±{maxExit / 100} (normalized)
- Filter out checks: {(if filterChecks: "yes" else: "no")}
- Searcher config: depth={searcherConfig.depth} nodesSoft={searcherConfig.nodes.soft} nodesHard={searcherConfig.nodes.hard} hash={searcherConfig.hash} (MiB)
- Random moves: min={depth.min} max={depth.max}
- Workers: {threads}
- Position limit: {(if limit <= 0: "None" else: $limit)}
- Skipping: {(if skip <= 0: "No" else: "Yes, to #" & $skip)}
- Rounds: {rounds}
"""
    var
        transpositionTable = allocHeapAligned(TranspositionTable, 64)
        parameters = getDefaultParameters()
    transpositionTable[] = newTranspositionTable(searcherConfig.hash * 1024 * 1024)
    var searcher = newSearchManager(@[startpos()], transpositionTable, parameters, evalState=newEvalState(verbose=false))

    searcher.limiter.addLimit(newDepthLimit(searcherConfig.depth))
    searcher.limiter.addLimit(newNodeLimit(searcherConfig.nodes.soft, searcherConfig.nodes.hard))

    var sizeHint = sizeHint
    if limit > 0 and sizeHint > limit:
        echo &"Note: size hint of {sizeHint} overridden by position limit of {limit}"
        sizeHint = limit
    # TODO: If memory usage proves to be a problem, add the option to proces positions
    # one at a time from the file
    var sizePretty = block:
        let sizeBytes = sizeHint * sizeof(Position) + sizeof(ZobristKey) * sizeHint
        if sizeBytes div 1048576 > 0:
            &"{sizeBytes / 1048576:.2f} MiB"
        else:
            &"{sizeBytes / 1024:.2f} KiB"
    echo &"Preloading book for splitting and indexing, using size hint of {sizeHint} to allocate {sizePretty}"
    var 
        bookPositions = newSeqOfCap[Position](sizeHint)
        hashes = initHashSet[ZobristKey](sizeHint * rounds)
        count = 0
        skipped = 0
    for line in inputFile.lines:
        if limit > 0 and bookPositions.len() == limit:
            break
        inc(count)
        if line == "":
            continue
        if skip > 0 and skipped < skip:
            inc(skipped)
            continue
        try:
            bookPositions.add(fromFEN(line))
        except ValueError:
            echo &"Error when loading position at line {count}: {getCurrentExceptionMsg()}"
        # This makes sure we filter positions that are already in the input book
        hashes.incl(bookPositions[^1].zobristKey)
   
    let chunkSize = ceilDiv(len(bookPositions), threads)

    sizePretty = block:
        let sizeBytes = (chunkSize * 2 * sizeof(Position) +
            sizeof(WThread) + sizeof(Atomic[bool]) + sizeof(Atomic[int])) * threads +
            (sizeof(Position) * sizeHint * rounds)
        if sizeBytes div 1048576 > 0:
            &"{sizeBytes / 1048576:.2f} MiB"
        else:
            &"{sizeBytes / 1024:.2f} KiB"
    echo &"Loaded {len(bookPositions)} positions, allocating an extra ~{sizePretty} and splitting across {threads} threads"

    let startTime = epochTime()

    var 
        threadPositions = newSeqOfCap[seq[Position]](threads)
        threadResults = newSeqOfCap[seq[Position]](threads)
        threadObjs = newSeq[WThread](threads)
        threadCounters = newSeq[Atomic[int]](threads)
        threadFlags = newSeq[Atomic[bool]](threads)
        augmentedPositions = newSeqOfCap[Position](sizeHint * rounds)
        totalPositions = 0

    var seeds = newSeq[int64](rounds)
    if rounds == 1:
         seeds[0] = seed
    else:
        echo &"Note: running more than one chonkening round, round seeds will be generated from the initial seed\n"
        var picker = initRand(seed)
        for i in 0..<rounds:
            seeds[i] = picker.rand(int64.high())
    for round in 0..<rounds:
        if round > 0:
            echo ""
        for i in 0..<threads:
            threadPositions.add(newSeqOfCap[Position](chunkSize))
            for j in 0..<chunkSize:
                threadPositions[^1].add(bookPositions[i + j].clone())
            threadResults.add(newSeqOfCap[Position](chunkSize))
        
        for i, worker in threadObjs.mpairs():
            worker.createThread(workerProc, (i, depth, maxExit, filterChecks, seeds[round], searcherConfig,
                                            addr threadPositions[i], addr threadResults[i], addr threadCounters[i],
                                            addr threadFlags[i]))
        var doneThreads = 0

        while doneThreads < threads:
            let processed = block:
                var i = 0
                for queue in threadResults:
                    # Note: not super duper safe since seqs aren't
                    # thread safe, but we're only ever reading the
                    # length field so *at worst* we'll miscount a
                    # little, no big deal. We only ever read from
                    # the sequences once all threads have exited
                    # anyway!
                    inc(i, len(queue))
                i
            cursorUp(1)
            eraseLine()
            if rounds == 1:
                echo &"Generated #{processed} positions"
            else:
                echo &"Generated #{processed} positions ({round + 1}/{rounds})"
            sleep(100)
            
            doneThreads = 0
            # Unfortunataly all/allIt expect immutable predicates :(
            for flag in threadFlags.mitems():
                if flag.load(moRelaxed):
                    inc(doneThreads)

        # Ensure threads are actually stopped
        joinThreads(threadObjs)

        # Collect thread results
        var i = 0
        for queue in threadResults:
            for position in queue:
                if position.zobristKey notin hashes:
                    augmentedPositions.add(position.clone())
                    hashes.incl(position.zobristKey)
                inc(totalPositions)
            inc(i)
        
        threadPositions = newSeqOfCap[seq[Position]](threads)
        threadResults = newSeqOfCap[seq[Position]](threads)
        threadObjs = newSeq[WThread](threads)
        threadFlags = newSeq[Atomic[bool]](threads)
        threadCounters = newSeq[Atomic[int]](threads)

    let totalTime = epochTime() - startTime
    let pps = round(augmentedPositions.len().float / totalTime).int
    if rounds == 1:
        cursorUp(1)
        eraseLine()
    if rounds > 1:
        echo &"""Ran {rounds} rounds with the following seeds: {seeds.join(", ")}"""
    echo &"Chonking produced {totalPositions} positions (of which {len(augmentedPositions)} are new and unique) in {totalTime:.2f} seconds (~{pps}/sec), {(if append: \"appending\" else: \"writing\")} to '{outputBook}'"
    for position in augmentedPositions:
        outputFile.writeLine(position.toFEN())