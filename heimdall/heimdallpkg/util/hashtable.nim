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


import heimdallpkg/zobrist


import nint128


type
    StaticHashEntry* = object
        data*: int16
    
    StaticHashTable* = object
        data: ptr UncheckedArray[StaticHashEntry]
        size: int


proc createStaticHashTable*(size: int): StaticHashTable =
    result = StaticHashTable(size: size, data: cast[ptr UncheckedArray[StaticHashEntry]](create(StaticHashEntry, size)))


func getIndex*(self: StaticHashTable, key: ZobristKey): uint64 {.inline.} =
    ## Retrieves the index of the given
    ## zobrist key in our transposition table
    result = (u128(key.uint64) * u128(self.size)).hi


func store*(self: StaticHashTable, key: ZobristKey, data: int16) {.inline.} =
    ## Stores the given piece of data in the hash table
    ## using the given key
    self.data[self.getIndex(key)] = StaticHashEntry(data: data)


func get*(self: StaticHashTable, key: ZobristKey): StaticHashEntry {.inline.} =
    ## Retrieves the entry located at the location
    ## specified by the given key
    return self.data[self.getIndex(key)]


func clear*(self: StaticHashTable) {.inline.} =
    ## Clears the hash table without
    ## releasing the memory associated
    ## with it
    for i in 0..self.size:
        self.data[i] = StaticHashEntry()


proc `destroy=`*(self: StaticHashTable) = dealloc(self.data)

# Helpers

func store*(self: ptr StaticHashTable, key: ZobristKey, data: int16) {.inline.} = self[].store(key, data)

func get*(self: ptr StaticHashTable, key: ZobristKey): StaticHashEntry {.inline.} = self[].get(key)

func clear*(self: ptr StaticHashTable) {.inline.} = self[].clear()