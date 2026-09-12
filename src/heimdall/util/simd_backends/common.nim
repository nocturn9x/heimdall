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

## Shared byte-dot and widening contracts, included by each register backend.
const
    I16_CHUNK_SIZE* = REGISTER_SIZE div sizeof(int16)
    I32_CHUNK_SIZE* = REGISTER_SIZE div sizeof(int32)

when REGISTER_SIZE == 16:
    func vecDpbusd*(acc: VEPI32, u8s, i8s: VEPI16): VEPI32 {.simdInline.} =
        let pairs = vecMaddubs16(u8s, i8s)
        when backendNeon:
            vecPairwiseAddAcc32(acc, pairs)
        else:
            vecAdd32(acc, vecMadd16(pairs, vecSetOne16(1)))

    func vecDpbusdx2*(acc: VEPI32, u8s0, i8s0, u8s1, i8s1: VEPI16): VEPI32 {.simdInline.} =
        let pairs = vecAdd16(vecMaddubs16(u8s0, i8s0), vecMaddubs16(u8s1, i8s1))
        when backendNeon:
            vecPairwiseAddAcc32(acc, pairs)
        else:
            vecAdd32(acc, vecMadd16(pairs, vecSetOne16(1)))

func vecLoadI8AsI16x2*(src: pointer): tuple[lo, hi: VEPI16] {.simdInline.} =
    ## Read two consecutive chunks of signed bytes, accepting unaligned input.
    when backendNeon:
        let bytes = vecLoad(src)
        (vecWidenLowI8(bytes), vecWidenHighI8(bytes))
    else:
        let bytes = cast[ptr UncheckedArray[int8]](src)
        (vecLoadI8AsI16(addr bytes[0]), vecLoadI8AsI16(addr bytes[I16_CHUNK_SIZE]))
