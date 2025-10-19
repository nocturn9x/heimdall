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

## A simple hash table with a statically defined size. Used for correction history

import nint128

import heimdall/util/zobrist


type
    StaticHashEntry* = object
        data*: int16

    StaticHashTable*[S: static[int]] = object
        data*: array[S, StaticHashEntry]


func getIndex*[S: static[int]](self: StaticHashTable[S],
        key: uint64): uint64 {.inline.} =
    when S != 0 and (S and (S - 1)) != 0:
        # If size is a power of two, modulo division is
        # fine!
        result = key.uint64 mod S.uint64
    else:
        result = (u128(key.uint64) * u128(S)).hi


func store*[S: static[int]](self: var StaticHashTable[S], key: uint64, data: int16) {.inline.} =
    self.data[self.getIndex(key)] = StaticHashEntry(data: data)


func get*[S: static[int]](self: StaticHashTable[S], key: uint64): StaticHashEntry {.inline.} =
    return self.data[self.getIndex(key)]


func clear*[S: static[int]](self: var StaticHashTable[S]) {.inline.} =
    for i in 0..<S:
        self.data[i] = StaticHashEntry()

# Helpers

func store*[S: static[int]](self: var StaticHashTable[S], key: ZobristKey, data: int16) {.inline.} = self.store(key.uint64, data)
func get*[S: static[int]](self: StaticHashTable[S], key: ZobristKey): StaticHashEntry {.inline.} = self.get(key.uint64)

func store*[S: static[int]](self: ptr StaticHashTable[S], key: uint64, data: int16) {.inline.} = self[].store(key, data)
func get*[S: static[int]](self: ptr StaticHashTable[S], key: uint64): StaticHashEntry {.inline.} = self[].get(key)
func store*[S: static[int]](self: ptr StaticHashTable[S], key: ZobristKey, data: int16) {.inline.} = self[].store(key.uint64, data)
func get*[S: static[int]](self: ptr StaticHashTable[S], key: ZobristKey): StaticHashEntry {.inline.} = self[].get(key.uint64)

func clear*[S: static[int]](self: ptr StaticHashTable[S]) {.inline.} = self[].clear()
