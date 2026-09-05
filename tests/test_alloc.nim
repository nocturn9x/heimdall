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
