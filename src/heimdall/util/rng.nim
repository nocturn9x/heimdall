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

## Minimal Nim port of https://prng.di.unimi.it/xoshiro256plusplus.c


func rotl(x: uint64, k: int): uint64 =
    return (x shl k) or (x shr (64 - k))


proc next*(s: var array[4, uint64]): uint64 =
    result = rotl(s[0] + s[3], 23) + s[0]

    let t = s[1] shl 17
    s[2]  = s[2] xor s[0]
    s[3]  = s[3] xor s[1]
    s[1]  = s[1] xor s[2]
    s[0]  = s[0] xor s[3]
    s[2]  = s[2] xor t
    s[3]  = rotl(s[3], 45)
