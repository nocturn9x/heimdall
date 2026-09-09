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
#
# Authored with assistance from AI agents.

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
