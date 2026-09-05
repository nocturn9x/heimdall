## Measure repeated position setup, including worker NNUE state preparation.
## Build with make dev MAIN=tests/bench_setup.nim EXE_BASE=bin/bench-setup
## and an absolute EVALFILE path. Arguments: threads (default 8), repetitions.
import std/[os, strutils, times, strformat]
import heimdall/[search, position, transpositions]

let
    threads = if paramCount() > 0: paramStr(1).parseInt() else: 8
    repetitions = if paramCount() > 1: paramStr(2).parseInt() else: 1000
    positions = @[startpos()]
doAssert threads > 0 and repetitions > 0
var manager = newSearchManager(positions, newTranspositionTable(16 * 1024 * 1024))
manager.setWorkerCount(threads - 1)
manager.setBoard(positions)
let start = cpuTime()
for i in 0..<repetitions:
    manager.setBoard(positions)
let elapsed = cpuTime() - start
echo &"Position setup: {threads} threads, {repetitions} positions, {elapsed:.6f} seconds"
manager.shutdownWorkers()
