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

import std/[atomics, math, options, os, strformat, syncio, terminal, times]

import heimdall/[board, eval, movegen, search, transpositions]
import heimdall/util/[limits, tunables, viriformat]
import heimdall/util/memory/aligned


type
    RelabelConfig* = object
        depth*: Option[int]
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
        completedGames: Atomic[int]
        completedPositions: Atomic[int]

    RelabelThread = Thread[ptr RelabelWorker]

    ProgressLine = object
        inPlace: bool
        active: bool


func shardPath(output: string, worker: int): string =
    &"{output}.part-{worker:03}"


proc update(self: var ProgressLine, message: string) =
    if not self.inPlace:
        echo message
        return

    var rendered = message
    let width = terminalWidth()
    if width > 4 and rendered.len >= width:
        rendered = rendered[0..<(width - 4)] & "..."
    stdout.setCursorXPos(0)
    stdout.eraseLine()
    stdout.write(rendered)
    stdout.flushFile()
    self.active = true


proc finish(self: var ProgressLine) =
    if self.active:
        stdout.writeLine("")
        stdout.flushFile()
        self.active = false


func formatDuration(seconds: float): string =
    if seconds > 0 and seconds < 1:
        return "<1s"
    let totalSeconds = max(0'i64, ceil(seconds).int64)
    let
        days = totalSeconds div 86400
        hours = (totalSeconds mod 86400) div 3600
        minutes = (totalSeconds mod 3600) div 60
        secs = totalSeconds mod 60
    if days > 0:
        return &"{days}d {hours}h"
    if hours > 0:
        return &"{hours}h {minutes}m"
    if minutes > 0:
        return &"{minutes}m {secs}s"
    result = &"{secs}s"


proc relabelGame(game: ViriformatGame, searcher: var SearchManager,
                 ttable: ptr TranspositionTable, completed: ptr Atomic[int]): string =
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
        discard completed[].fetchAdd(1, moRelaxed)

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
        if worker.config.depth.isSome():
            searcher.limiter.addLimit(newDepthLimit(worker.config.depth.get()))
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
                    let encoded = game.relabelGame(searcher, ttable, addr worker.completedPositions)
                    output.write(encoded)
                    inc(response.games)
                    inc(response.positions, game.moves.len)
                    discard worker.completedGames.fetchAdd(1, moRelaxed)
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


proc joinShards(output: string, shardPaths: openArray[string], ranges: openArray[RelabelRange],
                progressLine: var ProgressLine) =
    var joined = syncio.open(output, fmWrite)
    defer: joined.close()
    var
        buffer: array[1024 * 1024, char]
        totalBytes = 0'i64
        joinedBytes = 0'i64
        started = epochTime()
        lastUpdate = started
    for part in ranges:
        inc(totalBytes, part.bytes)
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
            inc(joinedBytes, count)
            let now = epochTime()
            if now - lastUpdate >= 1.0 or joinedBytes == totalBytes:
                let
                    elapsed = now - started
                    progress = if totalBytes > 0: joinedBytes.float / totalBytes.float else: 1.0
                    rateMiB = if elapsed > 0: joinedBytes.float / elapsed / 1048576.0 else: 0.0
                    eta = if progress > 0 and progress < 1:
                            formatDuration(elapsed * (1.0 - progress) / progress)
                        else:
                            "0s"
                progressLine.update(&"Join {progress * 100:>6.2f}% | ETA {eta} | " &
                    &"{rateMiB:.1f} MiB/s | Elapsed {formatDuration(elapsed)}")
                lastUpdate = now
        shard.close()
    joined.flushFile()


proc validate(config: RelabelConfig) =
    if config.depth.isSome() and config.depth.get() < 1:
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
    var progressLine = ProgressLine(inPlace: stdout.isatty())
    defer: progressLine.finish()

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
        workers[i].outputPath = paths[i]
        workers[i].config = config
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

    let depthDescription = if config.depth.isSome(): &", depth={config.depth.get()}" else: ""
    echo &"Relabelling '{inputPath}' with {config.threads} worker(s), " &
         &"nodes={config.nodes.soft}/{config.nodes.hard}{depthDescription}, hash={config.hashMiB} MiB/worker"

    let inputFileSize = getFileSize(inputPath)
    var
        scratch: ViriformatGame
        skipped = 0
        skipStarted = epochTime()
        lastSkipUpdate = skipStarted
    for _ in 0..<config.skip:
        if not input.readViriformatGame(scratch):
            break
        inc(skipped)
        let now = epochTime()
        if now - lastSkipUpdate >= 1.0 or skipped == config.skip:
            let
                elapsed = now - skipStarted
                progress = skipped.float / config.skip.float
                rate = if elapsed > 0: skipped.float / elapsed else: 0.0
                eta = if rate > 0: formatDuration((config.skip - skipped).float / rate) else: "calculating"
            progressLine.update(&"Skip {progress * 100:>6.2f}% | ETA {eta} | " &
                &"{skipped}/{config.skip} games | {rate:.1f} games/s | " &
                &"Elapsed {formatDuration(elapsed)}")
            lastSkipUpdate = now

    let
        started = epochTime()
        inputStart = input.getFilePos()
        inputBytes = max(0'i64, inputFileSize - inputStart)
    var
        totalGames = 0
        totalPositions = 0
        eof = false
        ranges: seq[RelabelRange]
        chunkNumber = 0

    while not eof and (config.limit == 0 or totalGames < config.limit):
        inc(chunkNumber)
        let wanted = if config.limit == 0:
                config.chunkSize
            else:
                min(config.chunkSize, config.limit - totalGames)
        var
            workerChunks = newSeq[seq[ViriformatGame]](config.threads)
            chunkLen = 0
            chunkPositions = 0
            perWorker = wanted.ceilDiv(config.threads)
            chunkInputStart = input.getFilePos()
            loadStarted = epochTime()
            lastLoadUpdate = loadStarted
        while chunkLen < wanted:
            var game: ViriformatGame
            if not input.readViriformatGame(game):
                eof = true
                break
            inc(chunkPositions, game.moves.len)
            workerChunks[min(chunkLen div perWorker, config.threads - 1)].add(game)
            inc(chunkLen)
            let now = epochTime()
            if now - lastLoadUpdate >= 1.0:
                let
                    elapsed = now - loadStarted
                    progress = chunkLen.float / wanted.float
                    rate = if elapsed > 0: chunkLen.float / elapsed else: 0.0
                    readMiB = if elapsed > 0:
                            (input.getFilePos() - chunkInputStart).float / elapsed / 1048576.0
                        else:
                            0.0
                    inputProgress = if inputBytes > 0:
                            min(1.0, (input.getFilePos() - inputStart).float / inputBytes.float)
                        else:
                            1.0
                    eta = if rate > 0: formatDuration((wanted - chunkLen).float / rate) else: "calculating"
                progressLine.update(&"Load #{chunkNumber} {progress * 100:>6.2f}% | ETA {eta} | " &
                    &"{chunkLen}/{wanted} games, {chunkPositions} positions | " &
                    &"Input {inputProgress * 100:.3f}% | {readMiB:.1f} MiB/s")
                lastLoadUpdate = now
        if chunkLen == 0:
            break

        let
            chunkInputEnd = input.getFilePos()
            loadedProgress = if config.limit > 0:
                    if eof: 1.0 else: min(1.0, (totalGames + chunkLen).float / config.limit.float)
                elif inputBytes > 0:
                    min(1.0, (chunkInputEnd - inputStart).float / inputBytes.float)
                else:
                    1.0
        progressLine.update(&"Chunk #{chunkNumber} loaded | {chunkLen} games, " &
            &"{chunkPositions} positions -> {config.threads} workers | " &
            &"Input {loadedProgress * 100:.3f}% | {formatDuration(epochTime() - loadStarted)}")

        for i in 0..<config.threads:
            workers[i].completedGames.store(0, moRelaxed)
            workers[i].completedPositions.store(0, moRelaxed)
            workers[i].inbox.send(RelabelWork(games: move(workerChunks[i])))

        var
            responses = newSeq[RelabelResult](config.threads)
            received = newSeq[bool](config.threads)
            receivedCount = 0
            lastProgressUpdate = epochTime()
        while receivedCount < config.threads:
            for i in 0..<config.threads:
                if received[i]:
                    continue
                let (available, response) = workers[i].outbox.tryRecv()
                if available:
                    responses[i] = response
                    received[i] = true
                    inc(receivedCount)

            let now = epochTime()
            if now - lastProgressUpdate >= 1.0 or receivedCount == config.threads:
                var
                    liveGames = 0
                    livePositions = 0
                for worker in workers.mitems():
                    inc(liveGames, worker.completedGames.load(moRelaxed))
                    inc(livePositions, worker.completedPositions.load(moRelaxed))
                let
                    chunkProgress = if chunkPositions > 0:
                            min(1.0, livePositions.float / chunkPositions.float)
                        elif chunkLen > 0:
                            min(1.0, liveGames.float / chunkLen.float)
                        else:
                            1.0
                    elapsed = now - started
                    progress = if config.limit > 0:
                            min(1.0, (totalGames.float + chunkLen.float * chunkProgress) / config.limit.float)
                        elif inputBytes > 0:
                            min(1.0, ((chunkInputStart - inputStart).float +
                                (chunkInputEnd - chunkInputStart).float * chunkProgress) / inputBytes.float)
                        else:
                            1.0
                    rate = if elapsed > 0: (totalPositions + livePositions).float / elapsed else: 0.0
                    eta = if progress > 0 and progress < 1:
                            formatDuration(elapsed * (1.0 - progress) / progress)
                        else:
                            "0s"
                progressLine.update(&"Relabel {progress * 100:>7.3f}% | ETA {eta} | " &
                    &"{rate:.1f} positions/s | {totalGames + liveGames} games, " &
                    &"{totalPositions + livePositions} positions | Chunk #{chunkNumber} " &
                    &"{livePositions}/{chunkPositions} | Elapsed {formatDuration(elapsed)}")
                lastProgressUpdate = now

            if receivedCount < config.threads:
                sleep(100)

        for i, response in responses:
            if response.error.len > 0:
                raise newException(ValueError, &"worker {i} failed: {response.error}")
            inc(totalGames, response.games)
            inc(totalPositions, response.positions)
            if response.bytes > 0:
                ranges.add((worker: i, offset: response.offset, bytes: response.bytes))

    for worker in workers.mitems():
        worker.inbox.send(RelabelWork(stop: true))
    for thread in threads.mitems():
        thread.joinThread()
    workersStopped = true

    progressLine.finish()
    if config.join:
        echo &"Joining {paths.len} shards into '{outputPath}'"
        joinShards(outputPath, paths, ranges, progressLine)
        progressLine.finish()
        for path in paths:
            removeFile(path)
    else:
        echo &"Wrote {paths.len} shards: {outputPath}.part-000 ... {paths[^1]}"

    let elapsed = epochTime() - started
    echo &"Finished: {totalGames} games / {totalPositions} positions in {elapsed:.2f} seconds"
