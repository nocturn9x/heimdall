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

## Search advances the shared TT generation once, after all workers finish.
## Build through make dev MAIN=tests/test_search_aging.nim IS_TEST=1
## EXE_BASE=bin/test-search-aging and an absolute EVALFILE (synthetic is fine).
import std/options
import heimdall/[eval, position, search, transpositions]
import heimdall/util/limits


proc checkSearchAging(workers: int) =
    let table = newTranspositionTable(1024 * 1024)
    let position = startpos()
    var manager = newSearchManager(@[position], table, evalState=newEvalState(verbose=false))
    try:
        manager.setWorkerCount(workers)
        manager.setBoard(@[position])
        doAssert table.age() == 0, "worker setup must not advance the generation"
        # Exercise the 31 -> 0 boundary through real searches too. Depth and
        # MultiPV must not change the number of birthdays per search.
        for birthday in 1..30:
            table.birthday()
        for iteration in 0..<4:
            let searchAge = uint8((30 + iteration) mod 32)
            doAssert table.age() == searchAge
            manager.limiter.clear()
            manager.limiter.addLimit(newDepthLimit(2))
            let multiPV = if iteration mod 2 == 0: 1 else: 3
            let lines = manager.search(silent=true, variations=multiPV)
            doAssert lines.len == multiPV
            for line in lines:
                doAssert line.length > 0, "test search must complete a variation"
            doAssert not manager.isSearching()
            doAssert table.age() == uint8((31 + iteration) mod 32),
                "a search must advance the shared TT once, regardless of worker count"
            let root = table.get(position.zobristKey)
            doAssert root.isSome()
            doAssert root.get().flag.age() == searchAge,
                "entries must retain the generation used during the search"

        # A deterministic hard budget aborts before a complete root iteration.
        let searchAge = table.age()
        manager.limiter.clear()
        manager.limiter.addLimit(newNodeLimit(1))
        discard manager.search(silent=true)
        doAssert not manager.isSearching()
        doAssert table.age() == uint8((searchAge.int + 1) mod 32),
            "a search stopped by a hard limit must still advance the age once"

        # Terminal positions also finish through the search lifecycle.
        for fen in ["7k/6Q1/5K2/8/8/8/8/8 b - - 0 1",
                    "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"]:
            manager.setBoard(@[fromFEN(fen)])
            let terminalAge = table.age()
            manager.limiter.clear()
            manager.limiter.addLimit(newDepthLimit(1))
            discard manager.search(silent=true)
            doAssert not manager.isSearching()
            doAssert table.age() == uint8((terminalAge.int + 1) mod 32)
    finally:
        manager.shutdownWorkers()


for workers in [0, 1, 2]:
    checkSearchAging(workers)

echo "Search TT aging: rollover, MultiPV, hard limits, terminal positions and shared workers passed"
