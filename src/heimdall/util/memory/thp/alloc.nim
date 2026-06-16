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
when not defined(windows):
    import std/[os, strutils, strformat]


const THP_SUPPORTED = when defined(windows):
    false
else:
    block:
        const output = staticExec(&"""{getCurrentCompilerExe()} --hints:off --warnings:off r helper""")
        if parseInt(output.strip(chars={'\n'})) == 1:
            true
        else:
            false

when THP_SUPPORTED:
    import heimdall/util/memory/aligned

    const PAGE_ALIGNMENT {.define: "thpPageAlignment".} = 2097152
    let MADV_HUGEPAGE {.importc: "MADV_HUGEPAGE", header: "sys/mman.h", nodecl.}: cint
    proc madvise(address: pointer, length, advice: int): cint {.importc: "madvise", header: "sys/mman.h", nodecl.}


proc hugePageAlloc*(size: int): pointer =
    ## Allocates size bytes (aligned to the configured
    ## page size) advising the kernel to use Transparent
    ## Huge Pages. If support for THP is not available,
    ## the allocation is done normally and without alignment
    when THP_SUPPORTED:
        result = allocHeapAligned(size, PAGE_ALIGNMENT)
        discard madvise(result, size, MADV_HUGEPAGE)
    else:
        result = alloc(size)


proc hugePageFree*(p: pointer) =
    ## Frees memory allocated by hugePageAlloc using the matching allocator.
    if p == nil:
        return
    when THP_SUPPORTED:
        freeHeapAligned(p)
    else:
        dealloc(p)


type
    HugePtr*[T] = object
        ## An owning handle to a single object of type T that lives on
        ## (transparent) huge pages instead of the GC heap. The backing
        ## memory is released automatically when the handle goes out of
        ## scope, so it composes with the destructors of any object that
        ## stores it as a field (no manual teardown required).
        raw*: ptr T


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
    result.raw = cast[ptr T](hugePageAlloc(sizeof(T)))
    when zero:
        zeroMem(result.raw, sizeof(T))
