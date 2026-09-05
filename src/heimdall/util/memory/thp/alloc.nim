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

## Support for Transparent Huge Pages (THP)
import heimdall/util/memory/aligned

when not defined(windows) and not defined(noTHP):
    import std/[os, strutils, strformat]


const THP_SUPPORTED = when defined(windows) or defined(noTHP):
    false
else:
    block:
        const output = staticExec(&"""{getCurrentCompilerExe()} --hints:off --warnings:off r helper""")
        if parseInt(output.strip(chars={'\n'})) == 1:
            true
        else:
            false

when THP_SUPPORTED:
    const PAGE_ALIGNMENT {.define: "thpPageAlignment".} = 2097152
    let MADV_HUGEPAGE {.importc: "MADV_HUGEPAGE", header: "sys/mman.h", nodecl.}: cint
    proc madvise(address: pointer, length, advice: int): cint {.importc: "madvise", header: "sys/mman.h", nodecl.}


proc hugePageAlloc*(size: int, alignment: static int = 64): pointer =
    ## Allocate at least cache-line-aligned storage, honoring larger requested
    ## alignments too. When available, align and advise whole huge pages.
    static:
        doAssert alignment.isPowerOfTwo()
    const allocationAlignment = when THP_SUPPORTED: max(alignment, PAGE_ALIGNMENT)
                                else: max(alignment, 64)
    static:
        doAssert allocationAlignment.isPowerOfTwo()
    let allocatedSize = ((size + allocationAlignment - 1) div allocationAlignment) * allocationAlignment
    result = allocHeapAligned(allocatedSize, allocationAlignment)
    when THP_SUPPORTED:
        # allocHeapAligned rounds up to whole pages. Advise that entire range:
        # a shorter advice splits the mapping and prevents its last huge page
        # from becoming eligible (the eval state is smaller than one page).
        discard madvise(result, allocatedSize, MADV_HUGEPAGE)


proc hugePageFree*(p: pointer) =
    ## Frees memory allocated by hugePageAlloc using the matching allocator.
    if p == nil:
        return
    freeHeapAligned(p)


type
    HugePtr*[T] = object
        ## An owning handle to a single object of type T that lives on
        ## (transparent) huge pages instead of the GC heap. The backing
        ## memory is released automatically when the handle goes out of
        ## scope, so it composes with the destructors of any object that
        ## stores it as a field (no manual teardown required).
        raw*: ptr T


func nilHugePtr*[T]: HugePtr[T] = HugePtr[T](raw: nil)

proc `=copy`*[T](dest: var HugePtr[T], source: HugePtr[T]) {.error: "HugePtr objects are unique owners and cannot be copied, only moved".}


proc `=destroy`*[T](self: HugePtr[T]) =
    if self.raw != nil:
        # Run T's own destructor first so any managed fields it
        # contains are released, then hand the raw storage back to
        # the huge page allocator.
        `=destroy`(self.raw[])
        hugePageFree(self.raw)


proc allocHugePage*[T](zero: static bool = false): HugePtr[T] =
    ## Allocates a single object of type T on huge pages and returns an
    ## owning handle to it. The storage is left uninitialized by default,
    ## since callers typically overwrite it immediately; pass zero = true
    ## to get new()-like zero initialization. Note that T's destructor runs
    ## over this memory when the handle is freed, so any type with managed
    ## fields (refs, seqs, strings, ...) MUST be allocated with zero = true
    ## (or have every such field assigned before the first teardown) to avoid
    ## running a destructor over garbage.
    result.raw = cast[ptr T](hugePageAlloc(sizeof(T), alignof(T)))
    when zero:
        zeroMem(result.raw, sizeof(T))
