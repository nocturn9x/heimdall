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

## Implementation of a transposition table
##
## NUMA-aware first-touch placement is adapted from Soul:
## - https://github.com/Aethdv/Soul/blob/soul/src/engine/tt.rs
## - https://github.com/Aethdv/Soul/blob/soul/src/numa.rs
import std/[math, options]

import heimdall/[eval, moves]
import heimdall/util/zobrist
import heimdall/util/memory/thp/alloc
import heimdall/util/numa

import nint128


type

    TTFlag* = object
        data: uint8

    TTBound* = enum
        NoBound = 0'i8
        UpperBound = 1
        LowerBound = 2
        Exact = 3

    TTEntry* = object
        ## An entry in the transposition table
        # The best move that was found at the
        # depth this entry was created at
        bestMove*: Move
        # The position's raw static evaluation
        rawEval*: int16
        # For space efficiency purposes we only
        # store the low 16 bits of the 64 bit
        # zobrist hash of the position (making
        # sure to index the table with the high
        # bits so we can still tell collisions
        # apart from normal lookups!)
        hash*: TruncatedZobristKey
        # Scores are int32s for convenience (less chance
        # of overflows and stuff), but they are capped to
        # fit into an int16
        score*: int16
        # The entry's flag
        flag*: TTFlag
        # The depth this entry was created at
        depth*: uint8

    TranspositionTable* = object
        data*: ptr UncheckedArray[TTEntry]
        size: uint64
        # TODO: TT aging
        # age: uint8


func createTTFlag*(age: uint8, bound: TTBound, wasPV: bool): TTFlag = TTFlag(data: (age shl 3) or (wasPV.uint8 shl 2) or bound.uint8)

func size*(self: TranspositionTable): uint64 {.inline.} = self.size

func wasPV*(self: TTFlag): bool = (self.data and 0b100) != 0

func bound*(self: TTFlag): TTBound =
    case self.data and 0b11:
        of 0:
            return NoBound
        of 1:
            return UpperBound
        of 2:
            return LowerBound
        of 3:
            return Exact
        else:
            # Unreachable
            discard

# Currently unused
func age*(self: TTFlag): uint8 = self.data shr 3


func getFillEstimate*(self: TranspositionTable): int64 {.inline.} =
    # For performance reasons, we estimate the occupancy by
    # looking at the first 1000 entries in the table. Why 1000?
    # Because the "hashfull" info message is conventionally not a
    # percentage, but rather a per...millage? It's in thousandths
    # rather than hundredths, basically
    if self.data == nil or self.size == 0:
        return 0
    let sampleCount = min(1000'u64, self.size).int
    for i in 0..<sampleCount:
        if self.data[i].hash != TruncatedZobristKey(0):
            inc(result)



type
    InitThreadArg = object
        data: ptr UncheckedArray[TTEntry]
        start, count: uint64
        node: int

    TThread = Thread[InitThreadArg]

const ENTRY_SIZE = sizeof(TTEntry).uint64


proc init*(self: var TranspositionTable, threads: int = 1) {.inline.} =
    ## Clears the transposition table
    ## without releasing the memory
    ## associated with it. The memory is
    ## cleared in chunks and in parallel
    ## by the specified number of threads

    doAssert threads > 0

    if self.data == nil or self.size == 0:
        return

    proc initWorker(args: InitThreadArg) {.thread.} =
        if args.node >= 0:
            discard bindToNUMANode(args.node)
        if args.count > 0:
            zeroMem(addr args.data[args.start], args.count * ENTRY_SIZE)

    let
        distribute = NUMAShouldDistribute(threads)
        workerCount = threads
    let chunkSize = ceilDiv(self.size, workerCount.uint64)
    var workers = newSeq[TThread](workerCount)

    for i, worker in workers.mpairs():
        let
            start = chunkSize * i.uint64
            count = if start < self.size: min(start + chunkSize, self.size) - start else: 0'u64
            node = if distribute: NUMANodeForThread(i, workerCount) else: -1
        worker.createThread(initWorker, InitThreadArg(data: self.data, start: start, count: count, node: node))

    joinThreads(workers)


proc newTranspositionTable*(size: uint64, threads: int = 1): TranspositionTable =
    ## Initializes a new transposition table of
    ## size bytes. The thread count is passed
    ## directly to init()
    let numEntries = size div ENTRY_SIZE
    result.data = cast[ptr UncheckedArray[TTEntry]](hugePageAlloc(int(ENTRY_SIZE * numEntries)))
    result.size = numEntries
    result.init(threads)


proc destroy*(self: var TranspositionTable) {.inline.} =
    ## Releases the storage owned by the transposition table.
    if self.data != nil:
        hugePageFree(self.data)
        self.data = nil
    self.size = 0


proc resize*(self: var TranspositionTable, newSize: uint64, threads: int = 1): bool {.inline.} =
    ## Resizes the transposition table. Note that
    ## this operation will also clear it, as changing
    ## the size invalidates all previous indeces. The
    ## thread count is passed directly to init()
    let numEntries = newSize div ENTRY_SIZE
    if numEntries == 0:
        return false

    let newData = cast[ptr UncheckedArray[TTEntry]](hugePageAlloc(int(ENTRY_SIZE * numEntries)))
    if newData == nil:
        return false

    let oldData = self.data
    self.data = newData
    self.size = numEntries
    self.init(threads)
    hugePageFree(oldData)
    result = true


proc distributes*(self: TranspositionTable): bool {.inline.} =
    ## Whether this machine has multiple NUMA nodes available to the process.
    NUMANodeCount() > 1


proc bindSearchThread*(self: TranspositionTable, threadId, threads: int) {.inline, gcsafe.} =
    ## Pins the calling search thread to its assigned L3 domain when there are
    ## multiple domains and multiple search threads. Best effort: failures leave
    ## the scheduler's current affinity untouched.
    if threadId notin 0..<threads or not NUMAShouldBind(threads):
        return
    let domain = NUMADomainForThread(threadId, threads)
    if domain >= 0:
        discard bindToNUMADomain(domain)


func getIndex*(self: TranspositionTable, key: ZobristKey): uint64 {.inline.} =
    # Apparently this is a trick to get fast arbitrary indexing into the
    # TT even when its size is not a multiple of 2. The alternative would
    # be a modulo operation (slooow) or restricting the TT size to be a
    # multiple of 2 and replacing x mod y with x and 1 (fast!), but thanks
    # to @ciekce on the Engine Programming discord we now have neither of
    # those limitations. Also, source: https://lemire.me/blog/2016/06/27/a-fast-alternative-to-the-modulo-reduction/
    result = (u128(key.uint64) * u128(self.size)).hi


func store*(self: var TranspositionTable, depth: uint8, score: Score, hash: ZobristKey, bestMove: Move, bound: TTBound, rawEval: int16, wasPV: bool) {.inline.} =
    self.data[self.getIndex(hash)] = TTEntry(flag: createTTFlag(0, bound, wasPV), score: int16(score), hash: TruncatedZobristKey(cast[uint16](hash)), depth: depth,
                                             bestMove: bestMove, rawEval: rawEval)


func prefetch*(p: ptr) {.importc: "__builtin_prefetch", noDecl, varargs, inline.}


func get*(self: var TranspositionTable, hash: ZobristKey): Option[TTEntry] {.inline.} =
    result = none(TTEntry)
    let entry = self.data[self.getIndex(hash)]
    if entry.hash == TruncatedZobristKey(cast[uint16](hash)):
        return some(entry)
    # Collision detected!

# We only ever use the TT through pointers, so we may as well make working
# with it as nice as possible

func get*(self: ptr TranspositionTable, hash: ZobristKey): Option[TTEntry] {.inline.} = self[].get(hash)
func store*(self: ptr TranspositionTable, depth: uint8, score: Score, hash: ZobristKey, bestMove: Move,  bound: TTBound, rawEval: int16, wasPV: bool) {.inline.} =
    self[].store(depth, score, hash, bestMove, bound, rawEval, wasPV)
proc resize*(self: ptr TranspositionTable, newSize: uint64, threads: int = 1): bool {.inline.} = self[].resize(newSize, threads)
proc init*(self: ptr TranspositionTable, threads: int = 1) {.inline.} = self[].init(threads)
func getFillEstimate*(self: ptr TranspositionTable): int64 {.inline.} = self[].getFillEstimate()
func size*(self: ptr TranspositionTable): uint64 {.inline.} = self.size
proc destroy*(self: ptr TranspositionTable) {.inline.} = self[].destroy()
proc distributes*(self: ptr TranspositionTable): bool {.inline.} = self[].distributes()
proc bindSearchThread*(self: ptr TranspositionTable, threadId, threads: int) {.inline, gcsafe.} = self[].bindSearchThread(threadId, threads)
