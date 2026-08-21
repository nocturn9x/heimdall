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

import std/[math, os, strformat, syncio, times]

import heimdall/[board, eval, movegen, search, transpositions]
import heimdall/util/[limits, tunables, viriformat]
import heimdall/util/memory/aligned


type
    RelabelConfig* = object
        depth*: int
        nodes*: tuple[soft, hard: uint64]
        hashMiB*: uint64
        threads*: int
        chunkSize*: int
        skip*: int
        limit*: int
        join*: bool

    RelabelWork = object
        stop: bool
        games: seq[ViriformatGame]

    RelabelResult = object
        games: int
        positions: int
        offset: int64
        bytes: int64
        error: string

    RelabelRange = tuple[worker: int, offset, bytes: int64]

    RelabelWorker = object
        outputPath: string
        config: RelabelConfig
        inbox: Channel[RelabelWork]
        outbox: Channel[RelabelResult]

    RelabelThread = Thread[ptr RelabelWorker]


func shardPath(output: string, worker: int): string =
    &"{output}.part-{worker:03}"


proc relabelGame(game: ViriformatGame, searcher: var SearchManager,
                 ttable: ptr TranspositionTable): string =
    var
        board = newChessboard(@[game.initial.position.clone()])
        scores = newSeq[int16](game.moves.len)

    for i, entry in game.moves:
        # Decode first so malformed input is rejected before doing an expensive
        # search or emitting a partial game.
        let move = board.positions[^1].parseViriformatMove(entry.move)

        searcher.setBoard(board.positions)
        searcher.histories.clear()
        ttable[].init(1)
        let variations = searcher.search(silent=true)
        if variations.len == 0 or variations[0].moves[0] == nullMove():
            raise newException(ValueError, &"search produced no move for position {board.toFEN()}")

        var score = variations[0].score
        if board.sideToMove == Black:
            score = -score
        scores[i] = int16(score)
        board.doMove(move)

    result = game.toViriformat(scores)


proc workerMain(worker: ptr RelabelWorker) {.thread.} =
    var ttable: ptr TranspositionTable
    try:
        ttable = allocHeapAligned(TranspositionTable, 64)
        if ttable == nil:
            raise newException(IOError, "failed to allocate a transposition table object")
        ttable[] = newTranspositionTable(worker.config.hashMiB * 1024 * 1024)

        var searcher = newSearchManager(@[startpos()], ttable, getDefaultParameters(),
                                        evalState=newEvalState(verbose=false), normalizeScore=false)
        searcher.limiter.addLimit(newDepthLimit(worker.config.depth))
        searcher.limiter.addLimit(newNodeLimit(worker.config.nodes.soft, worker.config.nodes.hard))

        var output = syncio.open(worker.outputPath, fmWrite)
        defer: output.close()

        # Readiness handshake: the coordinator does not start reading a large
        # input until every worker has its search state and output shard ready.
        worker.outbox.send(RelabelResult())

        while true:
            let work = worker.inbox.recv()
            if work.stop:
                break

            var response = RelabelResult()
            try:
                response.offset = output.getFilePos()
                for game in work.games:
                    let encoded = game.relabelGame(searcher, ttable)
                    output.write(encoded)
                    inc(response.games)
                    inc(response.positions, game.moves.len)
                output.flushFile()
                response.bytes = output.getFilePos() - response.offset
            except CatchableError:
                response.error = getCurrentExceptionMsg()
            worker.outbox.send(response)
    except CatchableError:
        worker.outbox.send(RelabelResult(error: getCurrentExceptionMsg()))
    finally:
        if ttable != nil:
            ttable[].destroy()
            freeHeapAligned(ttable)


proc joinShards(output: string, shardPaths: openArray[string], ranges: openArray[RelabelRange]) =
    var joined = syncio.open(output, fmWrite)
    defer: joined.close()
    var buffer: array[1024 * 1024, char]
    for part in ranges:
        let path = shardPaths[part.worker]
        var shard = syncio.open(path, fmRead)
        shard.setFilePos(part.offset)
        var remaining = part.bytes
        while remaining > 0:
            let count = shard.readBuffer(addr buffer[0], min(remaining, buffer.len.int64).int)
            if count == 0:
                raise newException(IOError, &"short read while joining relabel shard '{path}'")
            if joined.writeBuffer(addr buffer[0], count) != count:
                raise newException(IOError, &"short write while joining relabel shard '{path}'")
            dec(remaining, count)
        shard.close()
    joined.flushFile()


proc validate(config: RelabelConfig) =
    if config.depth < 1:
        raise newException(ValueError, "depth must be at least 1")
    if config.nodes.soft < 1 or config.nodes.hard < 1:
        raise newException(ValueError, "soft and hard node limits must be at least 1")
    if config.nodes.soft > config.nodes.hard:
        raise newException(ValueError, "soft node limit cannot exceed the hard node limit")
    if config.hashMiB < 1:
        raise newException(ValueError, "hash size must be at least 1 MiB per worker")
    if config.threads notin 1..1024:
        raise newException(ValueError, "threads must be in 1..1024")
    if config.chunkSize < 1:
        raise newException(ValueError, "chunk size must be at least 1 game")
    if config.skip < 0 or config.limit < 0:
        raise newException(ValueError, "skip and limit cannot be negative")


proc relabelViriformat*(inputPath, outputPath: string, config: RelabelConfig) =
    ## Streams viriformat games in bounded chunks, searches each recorded
    ## position on independent workers, and writes one output shard per worker.
    ## If `join` is enabled the shards are concatenated and removed afterwards.
    config.validate()
    let inputAbsolute = inputPath.absolutePath()
    if inputAbsolute == outputPath.absolutePath():
        raise newException(ValueError, "input and output paths must differ")
    for i in 0..<config.threads:
        if inputAbsolute == shardPath(outputPath, i).absolutePath():
            raise newException(ValueError, "input path collides with a generated output shard")

    var input = syncio.open(inputPath, fmRead)
    defer: input.close()

    var
        workers = newSeq[RelabelWorker](config.threads)
        threads = newSeq[RelabelThread](config.threads)
        paths = newSeq[string](config.threads)
        startedWorkers = 0
        openedWorkers = 0
        workersStopped = false

    defer:
        if not workersStopped:
            for i in 0..<startedWorkers:
                workers[i].inbox.send(RelabelWork(stop: true))
            for i in 0..<startedWorkers:
                threads[i].joinThread()
        for i in 0..<openedWorkers:
            workers[i].inbox.close()
            workers[i].outbox.close()

    for i in 0..<config.threads:
        paths[i] = shardPath(outputPath, i)
        workers[i] = RelabelWorker(outputPath: paths[i], config: config)
        workers[i].inbox.open()
        workers[i].outbox.open()
        inc(openedWorkers)
        # Starting sequentially also avoids having all workers initialise the
        # shared, immutable NNUE network at the same time.
        threads[i].createThread(workerMain, addr workers[i])
        inc(startedWorkers)
        let ready = workers[i].outbox.recv()
        if ready.error.len > 0:
            raise newException(IOError, &"worker {i} failed to initialise: {ready.error}")

    echo &"Relabelling '{inputPath}' with {config.threads} worker(s), depth={config.depth}, " &
         &"nodes={config.nodes.soft}/{config.nodes.hard}, hash={config.hashMiB} MiB/worker"

    var scratch: ViriformatGame
    for _ in 0..<config.skip:
        if not input.readViriformatGame(scratch):
            break

    let started = epochTime()
    var
        totalGames = 0
        totalPositions = 0
        eof = false
        ranges: seq[RelabelRange]

    while not eof and (config.limit == 0 or totalGames < config.limit):
        let wanted = if config.limit == 0:
                config.chunkSize
            else:
                min(config.chunkSize, config.limit - totalGames)
        var
            workerChunks = newSeq[seq[ViriformatGame]](config.threads)
            chunkLen = 0
            perWorker = wanted.ceilDiv(config.threads)
        while chunkLen < wanted:
            var game: ViriformatGame
            if not input.readViriformatGame(game):
                eof = true
                break
            workerChunks[min(chunkLen div perWorker, config.threads - 1)].add(game)
            inc(chunkLen)
        if chunkLen == 0:
            break

        for i in 0..<config.threads:
            workers[i].inbox.send(RelabelWork(games: move(workerChunks[i])))

        for i in 0..<config.threads:
            let response = workers[i].outbox.recv()
            if response.error.len > 0:
                raise newException(ValueError, &"worker {i} failed: {response.error}")
            inc(totalGames, response.games)
            inc(totalPositions, response.positions)
            if response.bytes > 0:
                ranges.add((worker: i, offset: response.offset, bytes: response.bytes))

        let
            elapsed = epochTime() - started
            rate = if elapsed > 0: totalPositions.float / elapsed else: 0.0
        echo &"Relabelled {totalGames} games / {totalPositions} positions ({rate:.1f} positions/s)"

    for worker in workers.mitems():
        worker.inbox.send(RelabelWork(stop: true))
    for thread in threads.mitems():
        thread.joinThread()
    workersStopped = true

    if config.join:
        echo &"Joining {paths.len} shards into '{outputPath}'"
        joinShards(outputPath, paths, ranges)
        for path in paths:
            removeFile(path)
    else:
        echo &"Wrote {paths.len} shards: {outputPath}.part-000 ... {paths[^1]}"

    let elapsed = epochTime() - started
    echo &"Finished: {totalGames} games / {totalPositions} positions in {elapsed:.2f} seconds"
