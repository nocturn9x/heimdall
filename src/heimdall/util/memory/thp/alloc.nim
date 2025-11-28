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

## Support for Transparent Huge Pages (THP)        
import std/[os, strutils, strformat]


const THP_SUPPORTED = block:
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