# Copyright 2024 Mattia Giambirtone & All Contributors
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
import std/options


import heimdallpkg/zobrist
import heimdallpkg/eval
import heimdallpkg/moves
import heimdallpkg/util/aligned


import nint128


# Note: Aging scheme shamelessly yoinked from https://github.com/cosmobobak/viridithas/blob/master/src/transpositiontable.rs

const
    # Number of entries per TT bucket
    TT_BUCKET_SIZE = 5   # 5 12-byte entries add up to 60 bytes (+4 for padding)
    # How many bytes each bucket is aligned to
    TT_BUCKET_ALIGNMENT = 64
    # This must be a power of 2
    TT_MAX_AGE = 1 shl 5
    TT_AGE_MASK = TT_MAX_AGE - 1

when not TT_MAX_AGE.isPowerOfTwo():
    {.fatal: "TT_MAX_AGE must be a power of two!".}


type
    TTFlag* = object
        data: uint8

    TTBound* = enum
        ## A flag for an entry in the
        ## transposition table
        NoBound = 0'i8
        UpperBound = 1
        LowerBound = 2
        Exact = 3
    
    TTEntry* = object
        ## An entry in the transposition table
        # The best move that was found at the
        # depth this entry was created at
        bestMove*: Move
        # The position's static evaluation
        staticEval*: int16
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

    TTBucket = object
        entries {.align(TT_BUCKET_ALIGNMENT).}: array[TT_BUCKET_SIZE, TTEntry]

    TTable* = object
        ## A transposition table
        buckets*: ptr UncheckedArray[TTBucket]
        size: uint64
        age: uint8


func size*(self: TTable): uint64 {.inline.} = self.size

func birthday*(self: var TTable) =
    ## Increases the TT's age. Happy birthday TT!
    inc(self.age)


func createTTFlag(age: uint8, bound: TTBound, wasPV: bool): TTFlag =
    return TTFlag(data: (age shl 3) or (bound.uint8 shl 2) or wasPV.uint8)

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
    var hits = 0
    for i in 0..<2000:
        for entry in self.buckets[i].entries:
            if entry.hash != TruncatedZobristKey(0):
                inc(hits)
    return hits div (2 * TT_BUCKET_SIZE)


func clear*(self: var TTable) {.inline.} =
    ## Clears the transposition table
    ## without releasing the memory
    ## associated with it
    for i in 0..<self.size:
        for j in 0..<TT_BUCKET_SIZE:
            self.buckets[i].entries[j] = TTEntry(bestMove: nullMove())
    self.age = 0


proc newTranspositionTable*(size: uint64): TTable =
    ## Initializes a new transposition table of
    ## size bytes
    let numBuckets = size div sizeof(TTBucket).uint64
    result.buckets = cast[ptr UncheckedArray[TTBucket]](create(TTBucket, numBuckets))
    result.size = numBuckets


proc resize*(self: var TTable, newSize: uint64) {.inline.} =
    ## Resizes the transposition table. Note that
    ## this operation will also clear it, as changing
    ## the size invalidates all previous indeces
    let numBuckets = newSize div sizeof(TTBucket).uint64
    dealloc(self.buckets)
    self.buckets = cast[ptr UncheckedArray[TTBucket]](create(TTBucket, numBuckets))
    self.size = numBuckets
    self.age = 0


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


func store*(self: var TTable, depth: uint8, score: Score, hash: ZobristKey, bestMove: Move, bound: TTBound, staticEval: int16, wasPV: bool) {.inline.} =
    ## Stores an entry in the transposition table
    let
        truncated = TruncatedZobristKey(cast[uint16](hash))
        bucket = self.getIndex(hash)

    var 
        bucketIdx = 0
        toReplace = self.buckets[bucket].entries[bucketIdx]

    if not (toReplace.hash == TruncatedZobristKey(0) or toReplace.hash == truncated):
        for i, entry in self.buckets[self.getIndex(hash)].entries:
            if entry.hash == truncated or entry.hash == TruncatedZobristKey(0):
                # Matching older entry or empty slot
                # was found
                bucketIdx = i
                toReplace = entry
                break
            # Aging scheme yoinked from viri
            if toReplace.depth - ((TT_MAX_AGE + self.age - toReplace.flag.age()) and TT_AGE_MASK) * 4 > entry.depth - ((TT_MAX_AGE + self.age - entry.flag.age()) and TT_AGE_MASK):
                bucketIdx = i
                toReplace = entry

    var bestMove = bestMove
    # Don't throw away the best move of a previous entry from the same position
    # if we don't have a new one
    if toReplace.hash == truncated and bestMove == nullMove():
        bestMove = toReplace.bestMove

    # Entries with Exact scores are given a bonus of
    # 3, LowerBound ones are given a bonus of 2, UpperBound
    # a bonus of one and None scores are given no bonus
    let
        newBonus = bound.int()
        oldBonus = toReplace.flag.bound().int()
        # Prefer overwriting entries from earlier positions
        ageDiff = (TT_MAX_AGE + self.age.int - toReplace.flag.age().int) and TT_AGE_MASK
        # Quadratic scaling: prefer keeping entries with high depths, but don't keep
        # ones that are too old
        insertPriority = depth.int + newBonus + (ageDiff * ageDiff) div 4 + wasPV.int
        recordPriority = toReplace.depth.int + oldBonus

    # Replace the old entry if it comes from a different position, if the old entry's
    # priority is lower than the new one's, or if the old one's bound is not exact and
    # the new one is
    if toReplace.hash != truncated or (bound == Exact and toReplace.flag.bound() != Exact) or (insertPriority * 3 >= recordPriority * 2):
        self.buckets[bucket].entries[bucketIdx] = TTEntry(flag: createTTFlag(self.age, bound, wasPV), score: int16(score), hash: truncated, depth: depth, bestMove: bestMove, staticEval: staticEval)


func get*(self: var TTable, hash: ZobristKey): Option[TTEntry] {.inline.} =
    ## Attempts to get the entry with the given
    ## zobrist key in the table. A none value is
    ## returned upon detection of a hash collision
    result = none(TTEntry)
    let truncated = TruncatedZobristKey(cast[uint16](hash))
    for entry in self.buckets[self.getIndex(hash)].entries:
        if entry.hash == truncated:
            return some(entry)


func prefetch*(p: ptr) {.importc: "__builtin_prefetch", noDecl, varargs, inline.}


# We only ever use the TT through pointers, so we may as well make working
# with it as nice as possible

func get*(self: ptr TTable, hash: ZobristKey): Option[TTEntry] {.inline.} = self[].get(hash)
func store*(self: ptr TTable, depth: uint8, score: Score, hash: ZobristKey, bestMove: Move, flag: TTBound, staticEval: int16, wasPV: bool) {.inline.} =
    self[].store(depth, score, hash, bestMove, flag, staticEval, wasPV)
proc resize*(self: ptr TTable, newSize: uint64) {.inline.} = self[].resize(newSize)
func clear*(self: ptr TTable) {.inline.} = self[].clear()
func getFillEstimate*(self: ptr TTable): int64 {.inline.} = self[].getFillEstimate()
func size*(self: ptr TTable): uint64 {.inline.} = self.size
