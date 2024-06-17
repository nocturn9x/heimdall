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


import zobrist
import eval
import moves


import nint128


type
    TTentryFlag* = enum
        ## A flag for an entry in the
        ## transposition table
        Exact = 0'i8
        LowerBound = 1'i8
        UpperBound = 2'i8

    TTEntry* = object
        ## An entry in the transposition table
        hash*: ZobristKey
        depth*: uint8
        flag*: TTentryFlag
        # Scores are int32s for convenience (less chance
        # of overflows and stuff), but they are capped to
        # fit into an int16
        score*: int16
        # The best move that was found at the
        # depth this entry was created at
        bestMove*: Move

    TTable* = object
        ## A transposition table
        data: seq[TTEntry]
        when defined(debug):
            hits: uint64
            occupancy: uint64
            collisions: uint64
        size: uint64


func size*(self: TTable): uint64 = self.size


when defined(debug):
    func hits*(self: TTable): uint64 = self.hits
    func collisions*(self: TTable): uint64 = self.collisions
    func occupancy*(self: TTable): uint64 = self.occupancy


func getFillEstimate*(self: TTable): uint64 =
    # For performance reasons, we estimate the occupancy by
    # looking at the first 1000 entries in the table. Why 1000?
    # Because the "hashfull" info message is conventionally not a 
    # percentage, but rather a per...millage? It's in thousandths 
    # rather than hundredths, basically
    for i in 0..999:
        if self.data[i].hash != ZobristKey(0):
            inc(result)


func clear*(self: var TTable) {.inline.} =
    ## Clears the transposition table
    ## without releasing the memory
    ## associated with it
    for i in 0..self.data.high():
        self.data[i] = TTEntry(bestMove: nullMove())


func newTranspositionTable*(size: uint64): TTable =
    ## Initializes a new transposition table of
    ## size bytes
    let numEntries = size div sizeof(TTEntry).uint64
    result.data = newSeq[TTEntry](numEntries)
    result.size = numEntries
    result.clear()


func resize*(self: var TTable, newSize: uint64) =
    ## Resizes the transposition table. Note that
    ## this operation will also clear it, as changing
    ## the size invalidates all previous indeces
    let numEntries = newSize div sizeof(TTEntry).uint64
    self.data = newSeq[TTEntry](numEntries)
    self.size = numEntries


func getIndex(self: TTable, key: ZobristKey): uint64 = 
    ## Retrieves the index of the given
    ## zobrist key in our transposition table
    
    # Apparently this is a trick to get fast arbitrary indexing into the
    # TT even when its size is not a multiple of 2. The alternative would
    # be a modulo operation (slooow) or restricting the TT size to be a
    # multiple of 2 and replacing x mod y with x and 1 (fast!), but thanks
    # to @ciekce on the Engine Programming discord we now have neither of
    # those limitations. Also, source: https://lemire.me/blog/2016/06/27/a-fast-alternative-to-the-modulo-reduction/
    result = (u128(key.uint64) * u128(self.size)).hi


func store*(self: var TTable, depth: uint8, score: Score, hash: ZobristKey, bestMove: Move, flag: TTentryFlag) =
    ## Stores an entry in the transposition table
    when defined(debug):
        let idx = self.getIndex(hash)
        if self.data[idx].hash != ZobristKey(0):
            inc(self.collisions)
        else:
            inc(self.occupancy)
        self.data[idx] = TTEntry(flag: flag, score: int16(score), hash: hash, depth: depth, bestMove: bestMove)
    else:
        self.data[self.getIndex(hash)] = TTEntry(flag: flag, score: int16(score), hash: hash, depth: depth, bestMove: bestMove)


func get*(self: var TTable, hash: ZobristKey): Option[TTEntry] =
    ## Attempts to get the entry with the given
    ## zobrist key in the table. A none value is
    ## returned upon detection of a hash collision
    result = none(TTEntry)
    let entry = self.data[self.getIndex(hash)]
    if entry.hash == hash:
        return some(entry)
    when defined(debug):
        if result.isSome():
            inc(self.hits)