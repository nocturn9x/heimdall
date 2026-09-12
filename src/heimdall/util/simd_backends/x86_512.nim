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

const backendNeon = false
import heimdall/util/avx/avx512_intrin
from nimsimd/avx import mm256_loadu_si256

type
    VEPI16* = M512i
    VEPI32* = M512i

export M512i

const CHUNK_SIZE* = 32
const REGISTER_SIZE* = 512 div 8

# Routines blatantly stolen from Alexandria. Many thanks cj!
when defined(runtimeSimd):
    {.pragma: simdInline, inline, codegenDecl: backendTargetDecl.}
else:
    {.pragma: simdInline, inline.}

func vecZero16*: VEPI16 {.simdInline.} = mm512_setzero_si512()
func vecZero32*: VEPI32 {.simdInline.} = mm512_setzero_si512()
func vecSetOne16*(n: int16): VEPI16 {.simdInline.} = mm512_set1_epi16(n)
func vecSetOne32*(n: int32): VEPI16 {.simdInline.} = mm512_set1_epi32(n)
func vecStore*(dst: pointer, vec: VEPI16) {.simdInline.} = mm512_store_si512(dst, vec)
func vecLoad*(src: pointer): VEPI16 {.simdInline.} = mm512_load_si512(src)
func vecLoadI8AsI16*(src: pointer): VEPI16 {.simdInline.} =
    ## Load 32 signed bytes at any alignment and widen them to 32 int16 lanes.
    mm512_cvtepi8_epi16(mm256_loadu_si256(src))
func vecMax16*(vec0, vec1: VEPI16): VEPI16 {.simdInline.} = mm512_max_epi16(vec0, vec1)
func vecMin16*(vec0, vec1: VEPI16): VEPI16 {.simdInline.} = mm512_min_epi16(vec0, vec1)
func vecMax32*(vec0, vec1: VEPI32): VEPI32 {.simdInline.} = mm512_max_epi32(vec0, vec1)
func vecMin32*(vec0, vec1: VEPI32): VEPI32 {.simdInline.} = mm512_min_epi32(vec0, vec1)
func vecMullo16*(vec0, vec1: VEPI16): VEPI16 {.simdInline.} = mm512_mullo_epi16(vec0, vec1)
func vecMullo32*(vec0, vec1: VEPI32): VEPI32 {.simdInline.} = mm512_mullo_epi32(vec0, vec1)
func vecMaddubs16*(vec0, vec1: VEPI16): VEPI16 {.simdInline.} = mm512_maddubs_epi16(vec0, vec1)
func vecMulhi16*(vec0, vec1: VEPI16): VEPI16 {.simdInline.} = mm512_mulhi_epi16(vec0, vec1)
func vecMadd16*(vec0, vec1: VEPI16): VEPI32 {.simdInline.} = mm512_madd_epi16(vec0, vec1)
func vecAdd16*(vec0, vec1: VEPI16): VEPI16 {.simdInline.} = mm512_add_epi16(vec0, vec1)
func vecAdd32*(vec0, vec1: VEPI32): VEPI32 {.simdInline.} = mm512_add_epi32(vec0, vec1)
func vecSub16*(vec0, vec1: VEPI16): VEPI16 {.simdInline.} = mm512_sub_epi16(vec0, vec1)
func vecLShift16*(vec: VEPI16, shift: int32 | uint32): VEPI16 {.simdInline.} = mm512_slli_epi16(vec, shift)
func vecRShift16*(vec: VEPI16, shift: int32 | uint32): VEPI16 {.simdInline.} = mm512_srli_epi16(vec, shift)
func vecRAShift16*(vec: VEPI16, shift: int32 | uint32): VEPI16 {.simdInline.} = mm512_srai_epi16(vec, shift)
func vecLShift32*(vec: VEPI32, shift: int32 | uint32): VEPI32 {.simdInline.} = mm512_slli_epi32(vec, shift)
func vecRShift32*(vec: VEPI32, shift: int32 | uint32): VEPI32 {.simdInline.} = mm512_srli_epi32(vec, shift)
func vecRAShift32*(vec: VEPI32, shift: int32 | uint32): VEPI32 {.simdInline.} = mm512_srai_epi32(vec, shift)
func vecPackI16toU8*(vec0, vec1: VEPI16): VEPI16 {.simdInline.} = mm512_packus_epi16(vec0, vec1)
func vecPermute*(vec: VEPI16): VEPI16 {.simdInline.} = mm512_permutexvar_epi64(mm512_setr_epi64(0, 2, 4, 6, 1, 3, 5, 7), vec)
func vecReduceAdd32*(vec: VEPI32): int32 {.simdInline.} = mm512_reduce_add_epi32(vec)

when backendVnni:
    func vecDpbusd*(acc: VEPI32, u8s, i8s: VEPI16): VEPI32 {.simdInline.} =
        ## Multiplies unsigned bytes in u8s with the corresponding signed
        ## bytes in i8s and accumulates each group of 4 adjacent products
        ## into the int32 lanes of acc
        mm512_dpbusd_epi32(acc, u8s, i8s)
    func vecDpbusdx2*(acc: VEPI32, u8s0, i8s0, u8s1, i8s1: VEPI16): VEPI32 {.simdInline.} =
        mm512_dpbusd_epi32(mm512_dpbusd_epi32(acc, u8s0, i8s0), u8s1, i8s1)
else:
    func vecDpbusd*(acc: VEPI32, u8s, i8s: VEPI16): VEPI32 {.simdInline.} =
        ## Emulates VNNI's dpbusd instruction: multiplies unsigned bytes in
        ## u8s with the corresponding signed bytes in i8s and accumulates each
        ## group of 4 adjacent products into the int32 lanes of acc. Note that
        ## unlike the real instruction, the intermediate pair sums saturate to
        ## 16 bits
        let pairs = mm512_maddubs_epi16(u8s, i8s)
        mm512_add_epi32(acc, mm512_madd_epi16(pairs, mm512_set1_epi16(1'i16)))
    func vecDpbusdx2*(acc: VEPI32, u8s0, i8s0, u8s1, i8s1: VEPI16): VEPI32 {.simdInline.} =
        let pairs0 = mm512_maddubs_epi16(u8s0, i8s0)
        let pairs1 = mm512_maddubs_epi16(u8s1, i8s1)
        mm512_add_epi32(acc, mm512_madd_epi16(mm512_add_epi16(pairs0, pairs1), mm512_set1_epi16(1'i16)))

include common
