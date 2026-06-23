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
import std/[math, options, atomics]

import heimdall/[eval, moves]
import heimdall/util/zobrist
import heimdall/util/memory/thp/alloc
import heimdall/util/numa

import nint128


const
    TT_AGE_CYCLE_LENGTH = 32 # 1 << 5
    TT_AGE_MASK = TT_AGE_CYCLE_LENGTH - 1
    TT_ENTRIES_PER_CLUSTER = 3'u64
    TT_HASHFULL_SAMPLES = 1000 * TT_ENTRIES_PER_CLUSTER


when not TT_AGE_CYCLE_LENGTH.isPowerOfTwo():
    import std/strformat

    {.fatal: &"TT age cycle length must be a power of 2 and {TT_AGE_CYCLE_LENGTH} is not".}


type

    TTFlag* = object
        data: uint8

    TTBound* = enum
        NoBound = 0'i8
        UpperBound = 1
        LowerBound = 2
        Exact = 3

    ClusterEntry = object
        ## Private TT entry object as
        ## stored in the cluster
        bestMove: Move
        rawEval: int16
        score: int16
        flag: TTFlag
        depth: uint8
    
    Cluster = object
        ## Groups TT_ENTRIES_PER_CLUSTER TT entries
        entries: array[TT_ENTRIES_PER_CLUSTER, ClusterEntry]
        keys: array[4, TruncatedZobristKey]

    # Public TT entry object
    TTEntry* = object
        ## Public TT entry object
    
        # The best move that was found at the
        # depth this entry was created at
        bestMove*: Move
        # The position's raw static evaluation
        rawEval*: Score
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
        score*: Score
        # The entry's score bound
        bound*: TTBound
        # Was this node ever in a PV?
        wasPV*: bool
        # The depth this entry was created at
        depth*: int

    TranspositionTable* = object
        data*: Atomic[ptr UncheckedArray[Cluster]]
        numClusters: Atomic[uint64]
        size: Atomic[uint64]
        age: Atomic[uint8]


func find(self: ptr Cluster, key: TruncatedZobristKey): uint64 =
    # TODO: Can be more efficient (no iteration needed to
    # find a matching key) if we use this black fucking magic
    # here: https://github.com/codedeliveryservice/Reckless/blob/eb8335f95f60e1085b098df72194b587b162d1d1/src/transposition.rs#L123
    # I don't quite understand it yet so I'm not gonna bother
    # with it
    for i in 0..<TT_ENTRIES_PER_CLUSTER:
        if key == self.keys[i]:
            return i.uint64
    # Not found
    return TT_ENTRIES_PER_CLUSTER


func createTTFlag*(age: uint8, bound: TTBound, wasPV: bool): TTFlag = TTFlag(data: (age shl 3) or (wasPV.uint8 shl 2) or bound.uint8)
func size*(self: var TranspositionTable): uint64 {.inline.} = self.size.load(moRelaxed)
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

func age*(self: TTFlag): uint8 = self.data shr 3
func age*(self: var TranspositionTable): uint8 = self.age.load(moRelaxed)
func birthday*(self: var TranspositionTable)   = self.age.store((self.age() + 1) and TT_AGE_MASK, moRelaxed)
func rejuvenate*(self: var TranspositionTable) = self.age.store(0, moRelaxed)
func storage*(self: var TranspositionTable): ptr UncheckedArray[Cluster] = self.data.load(moRelaxed)
func numClusters*(self: var TranspositionTable): uint64 = self.numClusters.load(moRelaxed)

func relativeAge(self: ptr ClusterEntry, age: uint8): int32 = int32((TT_AGE_CYCLE_LENGTH + age - self.flag.age()) and TT_AGE_MASK)


func getFillEstimate*(self: var TranspositionTable): uint64 {.inline.} =
    # For performance reasons, we estimate the occupancy by
    # looking at the first 1000 entries in the table. Why 1000?
    # Because the "hashfull" info message is conventionally not a
    # percentage, but rather a per...millage? It's in thousandths
    # rather than hundredths, basically
    let size = self.size()
    let data = self.storage()
    if data == nil or size == 0:
        return 0
    var i = 0'u64
    var cluster = 0'u64
    while i < TT_HASHFULL_SAMPLES and cluster < self.numClusters():
        for j in 0..<TT_ENTRIES_PER_CLUSTER:
            if data[cluster].keys[j] != TruncatedZobristKey(0) and data[cluster].entries[j].flag.age() == self.age():
                inc(result)
            inc(i)
        inc(cluster)
    result = result div TT_ENTRIES_PER_CLUSTER


type
    InitThreadArg = object
        data: ptr UncheckedArray[Cluster]
        start, count: uint64
        node: int

    TThread = Thread[InitThreadArg]


const CLUSTER_SIZE = sizeof(Cluster).uint64


proc init*(self: var TranspositionTable, threads: int = 1) {.inline.} =
    ## Clears the transposition table
    ## without releasing the memory
    ## associated with it. The memory is
    ## cleared in chunks and in parallel
    ## by the specified number of threads.
    ## The TT's age is reset to zero

    doAssert threads > 0

    let clusters = self.numClusters()
    let data = self.storage()

    if data.isNil() or clusters == 0:
        return

    proc initWorker(args: InitThreadArg) {.thread.} =
        if args.node >= 0:
            discard bindToNUMANode(args.node)
        if args.count > 0:
            zeroMem(addr args.data[args.start], args.count * CLUSTER_SIZE)

    let
        distribute = NUMAShouldDistribute(threads)
        workerCount = threads
    let chunknumEntries = ceilDiv(clusters, workerCount.uint64)
    var workers = newSeq[TThread](workerCount)

    for i, worker in workers.mpairs():
        let
            start = chunknumEntries * i.uint64
            count = if start < clusters: min(start + chunknumEntries, clusters) - start else: 0'u64
            node = if distribute: NUMANodeForThread(i, workerCount) else: -1
        worker.createThread(initWorker, InitThreadArg(data: data, start: start, count: count, node: node))

    joinThreads(workers)
    self.rejuvenate()


proc newTranspositionTable*(size: uint64, threads: int = 1): TranspositionTable =
    ## Initializes a new transposition table of
    ## size bytes. The thread count is passed
    ## directly to init()
    let numClusters = size div CLUSTER_SIZE
    let sizeBytes = numClusters * CLUSTER_SIZE

    doAssert numClusters > 0

    var data = cast[ptr UncheckedArray[Cluster]](hugePageAlloc(int(sizeBytes)))

    doAssert not data.isNil()

    result.numClusters.store(numClusters, moRelaxed)
    result.data.store(data, moRelaxed)
    result.size.store(sizeBytes, moRelaxed)
    result.init(threads)


proc destroy*(self: var TranspositionTable) {.inline.} =
    ## Releases the storage owned by the transposition table.
    let data = self.storage()
    if not data.isNil():
        hugePageFree(data)
        self.data.store(nil, moRelaxed)
    self.size.store(0, moRelaxed)
    self.numClusters.store(0, moRelaxed)


proc resize*(self: var TranspositionTable, newSize: uint64, threads: int = 1): bool {.inline.} =
    ## resizes the transposition table. Note that
    ## this operation will also clear it, as changing
    ## the numEntries invalidates all previous indeces. The
    ## thread count is passed directly to init()
    let numClusters = newSize div CLUSTER_SIZE
    let sizeBytes = numClusters * CLUSTER_SIZE

    if numClusters == 0:
        return false

    let newData = cast[ptr UncheckedArray[Cluster]](hugePageAlloc(int(sizeBytes)))
    if newData.isNil():
        return false

    let oldData = self.storage()
    self.data.store(newData, moRelaxed)
    self.size.store(sizeBytes, moRelaxed)
    self.numClusters.store(numClusters, moRelaxed)
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


func getIndex*(self: var TranspositionTable, key: ZobristKey): uint64 {.inline.} =
    # Apparently this is a trick to get fast arbitrary indexing into the
    # TT even when its numEntries is not a multiple of 2. The alternative would
    # be a modulo operation (slooow) or restricting the TT numEntries to be a
    # multiple of 2 and replacing x mod y with x and 1 (fast!), but thanks
    # to @ciekce on the Engine Programming discord we now have neither of
    # those limitations. Also, source: https://lemire.me/blog/2016/06/27/a-fast-alternative-to-the-modulo-reduction/
    result = (u128(key.uint64) * u128(self.numClusters())).hi


func store*(self: var TranspositionTable, depth: uint8, ply: int, score: Score, hash: ZobristKey, bestMove: Move, bound: TTBound, rawEval: int16, wasPV: bool,
            force: bool) {.inline.} =
    
    # Shameless Reckless yoink. https://github.com/codedeliveryservice/Reckless/blob/eb8335f95f60e1085b098df72194b587b162d1d1/src/transposition.rs
    let storedKey = hash.shorten()
    let cluster = addr self.storage()[self.getIndex(hash)]
    let age = self.age()

    let replacementIndex = block:
        let idx = cluster.find(storedKey)
        if idx < cluster.entries.len().uint64:
            # Matching cluster slot: use that one
            idx
        else:
            # Evict a slot from the cluster
            var candidate = none(uint64)
            var worst = int32.high()
            
            for i in countup(0'u64, cluster.entries.high()):
                let entry = addr cluster.entries[i]

                if entry.depth == 0:
                    # Zero-depth stuff is the least
                    # meaningful (qsearch/eval cache)
                    candidate = some(i)
                    break
                
                # Score entries by depth and their age relative to the
                # TT (high depth = good but too old = bad)
                let score = entry.depth.int32 - 4 * entry.relativeAge(age)

                if score < worst:
                    worst = score
                    candidate = some(i)
            
            candidate.get()

    let currentKey = cluster.keys[replacementIndex]
    let replaced = addr cluster.entries[replacementIndex]

    if not (currentKey == storedKey and bestMove == nullMove()):
        # Preserve previous best move in the same position if
        # current best move is null (due to fail lows)
        replaced.bestMove = bestMove

    if not force and storedKey == currentKey and depth.int16 + 4 + 2 * wasPV.int16 <= replaced.depth.int16 and replaced.flag.age() == age:
        return
    
    replaced.depth = depth
    replaced.score = int16(score.compressScore(ply))
    replaced.rawEval = rawEval
    replaced.flag = createTTFlag(age, bound, wasPV)
    # Publish the key last: important to minimize the damage from race
    # conditions. On x86 and other strongly ordered ISAs this gives us
    # lockless, cheap and concurrent access with minimal tearing
    cluster.keys[replacementIndex] = storedKey


func prefetch*(p: ptr) {.importc: "__builtin_prefetch", noDecl, varargs, inline.}


func get*(self: var TranspositionTable, hash: ZobristKey, ply: int): Option[TTEntry] {.inline.} =
    let
        cluster = addr self.storage()[self.getIndex(hash)]
        key = hash.shorten()
        idx = cluster.find(key)
    
    if idx < cluster.entries.len().uint64:
        let internal = addr cluster.entries[idx]

        let entry = TTEntry(
            bestMove: internal.bestMove,
            hash: key,
            score: Score(internal.score.decompressScore(ply)),
            rawEval: Score(internal.rawEval),
            depth: internal.depth.int,
            bound: internal.flag.bound(),
            wasPV: internal.flag.wasPV()
        )
        return some(entry)
    else:
        # Collision detected!
        return none(TTEntry)

# We only ever use the TT through pointers, so we may as well make working
# with it as nice as possible

func store*(self: ptr TranspositionTable, depth: uint8, ply: int, score: Score, hash: ZobristKey, bestMove: Move, 
            bound: TTBound, rawEval: int16, wasPV: bool, force: bool) {.inline.} =
    self[].store(depth, ply, score, hash, bestMove, bound, rawEval, wasPV, force)

func get*(self: ptr TranspositionTable, hash: ZobristKey, ply: int): Option[TTEntry] {.inline.} = self[].get(hash, ply)
proc resize*(self: ptr TranspositionTable, newSize: uint64, threads: int = 1): bool {.inline.} = self[].resize(newSize, threads)
proc init*(self: ptr TranspositionTable, threads: int = 1) {.inline.} = self[].init(threads)
func getFillEstimate*(self: ptr TranspositionTable): uint64 {.inline.} = self[].getFillEstimate()
func size*(self: ptr TranspositionTable): uint64 {.inline.} = self[].size()
proc destroy*(self: ptr TranspositionTable) {.inline.} = self[].destroy()
proc distributes*(self: ptr TranspositionTable): bool {.inline.} = self[].distributes()
proc bindSearchThread*(self: ptr TranspositionTable, threadId, threads: int) {.inline, gcsafe.} = self[].bindSearchThread(threadId, threads)
func birthday*(self: ptr TranspositionTable) {.inline.} = self[].birthday()
func storage*(self: ptr TranspositionTable): ptr UncheckedArray[Cluster] {.inline.} = self[].storage()
func numClusters*(self: ptr TranspositionTable): uint64 {.inline.} = self[].numClusters()
