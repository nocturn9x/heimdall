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

## Public TT aging, packed flags and lifecycle regressions; no weights needed.
## Build with make dev MAIN=tests/test_transpositions.nim IS_TEST=1
## EXE_BASE=bin/test-transpositions EMBED_NET=0.
import std/options
import heimdall/[moves, transpositions]
import heimdall/util/zobrist


const ENTRY_BYTES = sizeof(TTEntry).uint64


proc storeSample(table: TranspositionTable, key: ZobristKey,
                 bound = Exact, wasPV = true) =
    table.store(17, -1234, key, createMove("e2", "e4", DoublePush), bound, 2345, wasPV)


proc checkSample(entry: TTEntry, key: ZobristKey, age: uint8,
                 bound = Exact, wasPV = true) =
    doAssert entry.flag.age() == age
    doAssert entry.flag.bound() == bound
    doAssert entry.flag.wasPV() == wasPV
    doAssert entry.hash == TruncatedZobristKey(key.uint64.uint16)
    doAssert entry.depth == 17
    doAssert entry.score == -1234
    doAssert entry.rawEval == 2345
    doAssert entry.bestMove == createMove("e2", "e4", DoublePush)


block flagRoundTrips:
    let table = newTranspositionTable(ENTRY_BYTES)
    doAssert table.age() == 0
    # Exhaust all 256 packed flags over several cycles, also crossing the
    # full uint8 boundary in the number of birthdays performed.
    for generation in 0..<320:
        let expectedAge = uint8(generation mod 32)
        doAssert table.age() == expectedAge
        for bound in NoBound..Exact:
            for wasPV in [false, true]:
                let key = ZobristKey(0x1234)
                table.storeSample(key, bound, wasPV)
                let found = table.get(key)
                doAssert found.isSome()
                found.get().checkSample(key, expectedAge, bound, wasPV)
                doAssert table.age() == expectedAge, "storing must not advance the age"
        table.birthday()
    doAssert table.age() == 0


block retainedGenerations:
    let table = newTranspositionTable(32 * ENTRY_BYTES)
    var keys: array[32, ZobristKey]
    var saved: array[32, TTEntry]
    for generation in 0..<32:
        # Separate high bits select distinct slots; nonzero low tags let a
        # cleared entry be distinguished from a stored one through get().
        let key = ZobristKey((generation.uint64 shl 59) or (generation + 1).uint64)
        keys[generation] = key
        table.storeSample(key)
        saved[generation] = table.get(key).get()
        saved[generation].checkSample(key, generation.uint8)
        table.birthday()
        for previous in 0..generation:
            doAssert table.get(keys[previous]).get() == saved[previous],
                "a birthday must not rewrite or invalidate older entries"
    doAssert table.age() == 0
    for generation in 0..<32:
        doAssert table.get(keys[generation]).get() == saved[generation]
    # Reusing the same position in the next cycle records the current age.
    table.storeSample(keys[31], UpperBound, false)
    table.get(keys[31]).get().checkSample(keys[31], 0, UpperBound, false)
    doAssert table.get(keys[0]).get() == saved[0]


block collisionGetsCurrentAge:
    let table = newTranspositionTable(ENTRY_BYTES)
    let oldKey = ZobristKey(1)
    let newKey = ZobristKey(2)
    table.storeSample(oldKey)
    table.birthday()
    table.storeSample(newKey, LowerBound, false)
    doAssert table.get(oldKey).isNone()
    table.get(newKey).get().checkSample(newKey, 1, LowerBound, false)


block tableLifecycles:
    let table = newTranspositionTable(2 * ENTRY_BYTES)
    let other = newTranspositionTable(ENTRY_BYTES)
    let alias = table
    let key = ZobristKey(1)
    for birthday in 1..31:
        table.birthday()
    table.storeSample(key)
    doAssert alias.age() == 31
    doAssert other.age() == 0, "tables must have independent generations"

    # A rejected resize leaves both the generation and entries intact.
    for invalidSize in [0'u64, ENTRY_BYTES - 1]:
        doAssert not table.resize(invalidSize)
        doAssert table.size() == 2
        doAssert table.age() == 31
        table.get(key).get().checkSample(key, 31)

    for threads in [1, 2]:
        doAssert table.resize(4 * ENTRY_BYTES, threads)
        doAssert alias.age() == 0
        doAssert alias.size() == 4
        doAssert table.get(key).isNone()
        table.storeSample(key)
        table.get(key).get().checkSample(key, 0)
        table.birthday()
        table.init(threads)
        doAssert table.get(key).isNone()
        # init clears storage; stores still use the table's current generation.
        let currentAge = table.age()
        table.storeSample(key)
        table.get(key).get().checkSample(key, currentAge)

echo "TT aging: flag round trips, rollover, retained entries, collisions and lifecycle checks passed"
