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

## Check the alignment contract with and without huge-page advice.
## Build with make dev MAIN=tests/test_alloc.nim EXE_BASE=bin/test-alloc.
import heimdall/util/memory/thp/alloc

type
    CacheAligned = object
        data {.align(64).}: array[8, uint64]
    OverAligned = object
        data {.align(128).}: array[16, uint64]

var
    cacheOwners: array[16, HugePtr[CacheAligned]]
    overOwners: array[16, HugePtr[OverAligned]]

for i in 0..<cacheOwners.len:
    # Keep allocations alive together so malloc cannot just reuse one lucky slot.
    cacheOwners[i] = allocHugePage[CacheAligned]()
    overOwners[i] = allocHugePage[OverAligned]()
    doAssert cast[uint](cacheOwners[i].raw) mod alignof(CacheAligned).uint == 0
    doAssert cast[uint](overOwners[i].raw) mod alignof(OverAligned).uint == 0
    cacheOwners[i].raw.data[0] = i.uint64
    overOwners[i].raw.data[0] = (i + 1).uint64

for i in 0..<cacheOwners.len:
    doAssert cacheOwners[i].raw.data[0] == i.uint64
    doAssert overOwners[i].raw.data[0] == (i + 1).uint64

echo "Allocation alignment: 64-byte and 128-byte objects passed"
