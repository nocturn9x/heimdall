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

## Memory aligned (de)allocation routines

# Note-to-self: aligning allocations is *very* important in multithreaded environments,
# we have to avoid any two threads sharing critical information accidentally (i.e. one
# thread accidentally loads another thread's stuff in cache). All critical structures
# used during search are aligned to 64 bytes (the typical size of a cache line) for this
# reason


# Source: https://github.com/mratsim/constantine/blob/777cf55/constantine/platforms/allocs.nim#L101-L134

when defined(windows):
  proc aligned_alloc_windows(size, alignment: int): pointer {.importc:"_aligned_malloc", header:"<malloc.h>".}
    # Beware of the arg order!
  proc aligned_alloc(alignment, size: int): pointer {.inline.} =
    aligned_alloc_windows(size, alignment)
  proc aligned_free(p: pointer){.importc:"_aligned_free", header:"<malloc.h>".}
elif defined(osx):
  proc posix_memalign(mem: var pointer, alignment, size: int){.importc, header:"<stdlib.h>".}
  proc aligned_alloc(alignment, size: int): pointer {.inline.} =
    posix_memalign(result, alignment, size)
  proc aligned_free(p: pointer) {. importc: "free", header: "<stdlib.h>".}
else:
  proc aligned_alloc(alignment, size: int): pointer {.importc, header:"<stdlib.h>".}
  proc aligned_free(p: pointer) {. importc: "free", header: "<stdlib.h>".}

proc isPowerOfTwo(n: int): bool {.inline.} =
  (n and (n - 1)) == 0 and (n != 0)


func roundNextMultipleOf(x: int, n: static int): int {.inline.} =
  ## Round the input to the next multiple of "n"
  when n.isPowerOfTwo():
    # n is a power of 2. (If compiler cannot prove that x>0 it does not make the optim)
    result = (x + n - 1) and not(n - 1)
  else:
    result = x.ceilDiv_vartime(n) * n


proc allocHeapAligned*(T: typedesc, alignment: static Natural): ptr T {.inline.} =
  # aligned_alloc requires allocating in multiple of the alignment.
  let # Cannot be static with bitfields. Workaround https://github.com/nim-lang/Nim/issues/19040
    size = sizeof(T)
    requiredMem = size.roundNextMultipleOf(alignment)

  cast[ptr T](aligned_alloc(alignment, requiredMem))


proc allocHeapArrayAligned*(T: typedesc, len: int, alignment: static Natural): ptr UncheckedArray[T] {.inline.} =
  # aligned_alloc requires allocating in multiple of the alignment.
  let
    size = sizeof(T) * len
    requiredMem = size.roundNextMultipleOf(alignment)

  cast[ptr UncheckedArray[T]](aligned_alloc(alignment, requiredMem))


proc freeHeapAligned*(p: pointer) {.inline.} =
  aligned_free(p)