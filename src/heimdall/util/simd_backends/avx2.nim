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

const backendTargetDecl = "static inline __attribute__((target(\"avx2\"), always_inline)) $# $#$#"
const backendNeon = false
import nimsimd/avx2
import nimsimd/sse2

export MM_SHUFFLE


type
    VEPI16* = M256i
    VEPI32* = M256i

export M256i

const CHUNK_SIZE* = 16
const REGISTER_SIZE* = 256 div 8

when defined(runtimeSimd):
    {.pragma: simdInline, inline, codegenDecl: backendTargetDecl.}
else:
    {.pragma: simdInline, inline.}

func vecZero16*: VEPI16 {.simdInline.} = mm256_setzero_si256()
func vecZero32*: VEPI32 {.simdInline.} = mm256_setzero_si256()
func vecSetOne16*(n: int16): VEPI16 {.simdInline.} = mm256_set1_epi16(n)
func vecSetOne32*(n: int32): VEPI16 {.simdInline.} = mm256_set1_epi32(n)
func vecStore*(dst: pointer, vec: VEPI16) {.simdInline.} = mm256_store_si256(dst, vec)
func vecLoad*(src: pointer): VEPI16 {.simdInline.} = mm256_load_si256(src)
func vecLoadI8AsI16*(src: pointer): VEPI16 {.simdInline.} =
    ## Load 16 signed bytes at any alignment and widen them to 16 int16 lanes.
    mm256_cvtepi8_epi16(mm_loadu_si128(src))
func vecMax16*(vec0, vec1: VEPI16): VEPI16 {.simdInline.} = mm256_max_epi16(vec0, vec1)
func vecMin16*(vec0, vec1: VEPI16): VEPI16 {.simdInline.} = mm256_min_epi16(vec0, vec1)
func vecMax32*(vec0, vec1: VEPI32): VEPI32 {.simdInline.} = mm256_max_epi32(vec0, vec1)
func vecMin32*(vec0, vec1: VEPI32): VEPI32 {.simdInline.} = mm256_min_epi32(vec0, vec1)
func vecMullo16*(vec0, vec1: VEPI16): VEPI16 {.simdInline.} = mm256_mullo_epi16(vec0, vec1)
func vecMullo32*(vec0, vec1: VEPI32): VEPI32 {.simdInline.} = mm256_mullo_epi32(vec0, vec1)
func vecMaddubs16*(vec0, vec1: VEPI16): VEPI16 {.simdInline.} = mm256_maddubs_epi16(vec0, vec1)
func vecMulhi16*(vec0, vec1: VEPI16): VEPI16 {.simdInline.} = mm256_mulhi_epi16(vec0, vec1)
func vecMadd16*(vec0, vec1: VEPI16): VEPI32 {.simdInline.} = mm256_madd_epi16(vec0, vec1)
func vecAdd32*(vec0, vec1: VEPI32): VEPI32 {.simdInline.} = mm256_add_epi32(vec0, vec1)
func vecAdd16*(vec0, vec1: VEPI16): VEPI16 {.simdInline.} = mm256_add_epi16(vec0, vec1)
func vecSub16*(vec0, vec1: VEPI16): VEPI16 {.simdInline.} = mm256_sub_epi16(vec0, vec1)
func vecLShift16*(vec: VEPI16, shift: int32 | uint32): VEPI16 {.simdInline.} = mm256_slli_epi16(vec, shift)
func vecRShift16*(vec: VEPI16, shift: int32 | uint32): VEPI16 {.simdInline.} = mm256_srli_epi16(vec, shift)
func vecRAShift16*(vec: VEPI16, shift: int32 | uint32): VEPI16 {.simdInline.} = mm256_srai_epi16(vec, shift)
func vecLShift32*(vec: VEPI32, shift: int32 | uint32): VEPI32 {.simdInline.} = mm256_slli_epi32(vec, shift)
func vecRShift32*(vec: VEPI32, shift: int32 | uint32): VEPI32 {.simdInline.} = mm256_srli_epi32(vec, shift)
func vecRAShift32*(vec: VEPI32, shift: int32 | uint32): VEPI32 {.simdInline.} = mm256_srai_epi32(vec, shift)
func vecPackI16toU8*(vec0, vec1: VEPI16): VEPI16 {.simdInline.} = mm256_packus_epi16(vec0, vec1)
func vecPermute*(vec: VEPI16): VEPI16 {.simdInline.} = mm256_permute4x64_epi64(vec, MM_SHUFFLE(3, 1, 2, 0))
# AVX2 doesn't have an intrinsic for vec_reduce_add_epi32 (AVX512 does), but thankfully
# cj wrote the implementation for us!
func vecReduceAdd32*(vec: VEPI32): int32 {.simdInline.} =
    var
        lo128 = mm256_castsi256_si128(vec)
        hi128 = mm256_extracti128_si256(vec, 1)
        sum128 = mm_add_epi32(lo128, hi128)

        hi64 = mm_unpackhi_epi64(sum128, sum128)
        sum64 = mm_add_epi32(hi64, sum128)

        hi32 = mm_shuffle_epi32(sum64, 1)
        sum32 = mm_add_epi32(hi32, sum64)

    mm_cvtsi128_si32(sum32)

func vecDpbusd*(acc: VEPI32, u8s, i8s: VEPI16): VEPI32 {.simdInline.} =
    ## Emulates VNNI's dpbusd instruction: multiplies unsigned bytes in
    ## u8s with the corresponding signed bytes in i8s and accumulates each
    ## group of 4 adjacent products into the int32 lanes of acc. Note that
    ## unlike the real instruction, the intermediate pair sums saturate to
    ## 16 bits
    let pairs = mm256_maddubs_epi16(u8s, i8s)
    mm256_add_epi32(acc, mm256_madd_epi16(pairs, mm256_set1_epi16(1'i16)))

func vecDpbusdx2*(acc: VEPI32, u8s0, i8s0, u8s1, i8s1: VEPI16): VEPI32 {.simdInline.} =
    let pairs0 = mm256_maddubs_epi16(u8s0, i8s0)
    let pairs1 = mm256_maddubs_epi16(u8s1, i8s1)
    mm256_add_epi32(acc, mm256_madd_epi16(mm256_add_epi16(pairs0, pairs1), mm256_set1_epi16(1'i16)))

include common
