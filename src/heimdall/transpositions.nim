# Copyright 2025 Mattia Giambirtone & All Contributors
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
import std/math
import std/options


import heimdall/eval
import heimdall/moves
import heimdall/util/zobrist


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

    TTable* = object
        ## A transposition table
        data*: ptr UncheckedArray[TTEntry]
        size: uint64
        age: uint8


func birthday*(self: var TTable) =
    ## Increases the TT's age. Happy birthday TT!
    if self.age == uint8.high():
        self.age = 0
    else:
        inc(self.age)


func createTTFlag*(age: uint8, bound: TTBound, wasPV: bool): TTFlag = TTFlag(data: (age shl 3) or (wasPV.uint8 shl 2) or bound.uint8)

func size*(self: TTable): uint64 {.inline.} = self.size

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


func getFillEstimate*(self: TTable): int64 {.inline.} =
    # For performance reasons, we estimate the occupancy by
    # looking at the first 1000 entries in the table. Why 1000?
    # Because the "hashfull" info message is conventionally not a 
    # percentage, but rather a per...millage? It's in thousandths 
    # rather than hundredths, basically
    for i in 0..999:
        if self.data[i].hash != TruncatedZobristKey(0):
            inc(result)



type TThread = Thread[tuple[self: TTable, chunkSize, i: uint64]]
const ENTRY_SIZE = sizeof(TTEntry).uint64


func init*(self: var TTable, threads: int = 1) {.inline.} =
    ## Clears the transposition table
    ## without releasing the memory
    ## associated with it. The memory is
    ## cleared in chunks and in parallel 
    ## by the specified number of threads

    doAssert threads > 0

    # Yoinked from Stormphrax
    func initWorker(args: tuple[self: TTable, chunkSize, i: uint64]) {.thread.} =
        let
            start = args.chunkSize * args.i
            stop = min(start + args.chunkSize, args.self.size)
            count = stop - start

        zeroMem(addr args.self.data[start], count * ENTRY_SIZE)
    
    let chunkSize = ceilDiv(self.size, threads.uint64)
    var workers = newSeq[TThread](threads)

    for i, worker in workers.mpairs():
        worker.createThread(initWorker, (self, chunkSize, i.uint64))

    joinThreads(workers)


proc newTranspositionTable*(size: uint64, threads: int = 1): TTable =
    ## Initializes a new transposition table of
    ## size bytes. The thread count is passed directly
    ## to init()
    let numEntries = size div ENTRY_SIZE
    result.data = cast[ptr UncheckedArray[TTEntry]](alloc(ENTRY_SIZE * numEntries))
    result.size = numEntries
    result.init(threads)


proc resize*(self: var TTable, newSize: uint64, threads: int = 1) {.inline.} =
    ## Resizes the transposition table. Note that
    ## this operation will also clear it, as changing
    ## the size invalidates all previous indeces. The
    ## thread count is passed directly to init()
    let numEntries = newSize div ENTRY_SIZE
    dealloc(self.data)
    self.data = cast[ptr UncheckedArray[TTEntry]](alloc(ENTRY_SIZE * numEntries))
    self.size = numEntries
    self.init(threads)


func getIndex*(self: TTable, key: ZobristKey): uint64 {.inline.} =
    ## Retrieves the index of the given
    ## zobrist key in our transposition table
    
    # Apparently this is a trick to get fast arbitrary indexing into the
    # TT even when its size is not a multiple of 2. The alternative would
    # be a modulo operation (slooow) or restricting the TT size to be a
    # multiple of 2 and replacing x mod y with x and 1 (fast!), but thanks
    # to @ciekce on the Engine Programming discord we now have neither of
    # those limitations. Also, source: https://lemire.me/blog/2016/06/27/a-fast-alternative-to-the-modulo-reduction/
    result = (u128(key.uint64) * u128(self.size)).hi


func store*(self: var TTable, depth: uint8, score: Score, hash: ZobristKey, bestMove: Move, bound: TTBound, rawEval: int16, wasPV: bool) {.inline.} =
    ## Stores an entry in the transposition table
    self.data[self.getIndex(hash)] = TTEntry(flag: createTTFlag(self.age, bound, wasPV), score: int16(score), hash: TruncatedZobristKey(cast[uint16](hash)), depth: depth,
                                             bestMove: bestMove, rawEval: rawEval)


func prefetch*(p: ptr) {.importc: "__builtin_prefetch", noDecl, varargs, inline.}


func get*(self: var TTable, hash: ZobristKey): Option[TTEntry] {.inline.} =
    ## Attempts to get the entry matching the given
    ## zobrist key. A none value is returned upon
    ## detection of a hash collision
    result = none(TTEntry)
    let entry = self.data[self.getIndex(hash)]
    if entry.hash == TruncatedZobristKey(cast[uint16](hash)):
        return some(entry)

# We only ever use the TT through pointers, so we may as well make working
# with it as nice as possible

func get*(self: ptr TTable, hash: ZobristKey): Option[TTEntry] {.inline.} = self[].get(hash)
func store*(self: ptr TTable, depth: uint8, score: Score, hash: ZobristKey, bestMove: Move,  bound: TTBound, rawEval: int16, wasPV: bool) {.inline.} = 
    self[].store(depth, score, hash, bestMove, bound, rawEval, wasPV)
proc resize*(self: ptr TTable, newSize: uint64, threads: int = 1) {.inline.} = self[].resize(newSize, threads)
func init*(self: ptr TTable, threads: int = 1) {.inline.} = self[].init(threads)
func getFillEstimate*(self: ptr TTable): int64 {.inline.} = self[].getFillEstimate()
func size*(self: ptr TTable): uint64 {.inline.} = self.size
