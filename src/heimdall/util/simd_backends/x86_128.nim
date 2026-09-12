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

## Shared SSE2/SSSE3/SSE4.1 integer SIMD. No AVX required.
import nimsimd/sse41

type
    VEPI16* = M128i
    VEPI32* = M128i

const
    CHUNK_SIZE* = 8
    REGISTER_SIZE* = 16
    backendNeon = false

when defined(runtimeSimd):
    {.pragma: simdInline, inline, codegenDecl: backendTargetDecl.}
else:
    {.pragma: simdInline, inline.}

func vecZero16*: VEPI16 {.simdInline.} = mm_setzero_si128()
func vecZero32*: VEPI32 {.simdInline.} = mm_setzero_si128()
func vecSetOne16*(n: int16): VEPI16 {.simdInline.} = mm_set1_epi16(n)
func vecSetOne32*(n: int32): VEPI32 {.simdInline.} = mm_set1_epi32(n)
func vecStore*(dst: pointer, vec: VEPI16) {.simdInline.} = mm_store_si128(dst, vec)
func vecLoad*(src: pointer): VEPI16 {.simdInline.} = mm_load_si128(src)
func vecLoadI8AsI16*(src: pointer): VEPI16 {.simdInline.} =
    ## Read exactly eight bytes at any alignment, then sign extend each lane.
    let bytes = mm_loadl_epi64(src)
    when backendSse41:
        mm_cvtepi8_epi16(bytes)
    else:
        mm_srai_epi16(mm_unpacklo_epi8(bytes, bytes), 8)
func vecMax16*(a, b: VEPI16): VEPI16 {.simdInline.} = mm_max_epi16(a, b)
func vecMin16*(a, b: VEPI16): VEPI16 {.simdInline.} = mm_min_epi16(a, b)
func vecMax32*(a, b: VEPI32): VEPI32 {.simdInline.} =
    when backendSse41:
        mm_max_epi32(a, b)
    else:
        let mask = mm_cmpgt_epi32(a, b)
        mm_or_si128(mm_and_si128(mask, a), mm_andnot_si128(mask, b))
func vecMin32*(a, b: VEPI32): VEPI32 {.simdInline.} =
    when backendSse41:
        mm_min_epi32(a, b)
    else:
        let mask = mm_cmpgt_epi32(a, b)
        mm_or_si128(mm_and_si128(mask, b), mm_andnot_si128(mask, a))
func vecMullo16*(a, b: VEPI16): VEPI16 {.simdInline.} = mm_mullo_epi16(a, b)
func vecMullo32*(a, b: VEPI32): VEPI32 {.simdInline.} =
    when backendSse41:
        mm_mullo_epi32(a, b)
    else:
        # SSE2 multiplies only the even unsigned lanes into int64. Low halves are
        # identical for signed multiplication; interleave the two sets of results.
        let even = mm_mul_epu32(a, b)
        let odd = mm_mul_epu32(mm_srli_si128(a, 4), mm_srli_si128(b, 4))
        mm_unpacklo_epi32(mm_shuffle_epi32(even, MM_SHUFFLE(2, 0, 2, 0)),
                         mm_shuffle_epi32(odd, MM_SHUFFLE(2, 0, 2, 0)))
func vecMaddubs16*(a, b: VEPI16): VEPI16 {.simdInline.} =
    when backendSsse3 or backendSse41:
        mm_maddubs_epi16(a, b)
    else:
        # SSE2: widen unsigned a and signed b, form int32 pair sums, then
        # saturate to int16. This exactly matches SSSE3's maddubs instruction.
        let zero = mm_setzero_si128()
        let sign = mm_cmpgt_epi8(zero, b)
        let lo = mm_madd_epi16(mm_unpacklo_epi8(a, zero), mm_unpacklo_epi8(b, sign))
        let hi = mm_madd_epi16(mm_unpackhi_epi8(a, zero), mm_unpackhi_epi8(b, sign))
        mm_packs_epi32(lo, hi)
func vecMulhi16*(a, b: VEPI16): VEPI16 {.simdInline.} = mm_mulhi_epi16(a, b)
func vecMadd16*(a, b: VEPI16): VEPI32 {.simdInline.} = mm_madd_epi16(a, b)
func vecAdd16*(a, b: VEPI16): VEPI16 {.simdInline.} = mm_add_epi16(a, b)
func vecAdd32*(a, b: VEPI32): VEPI32 {.simdInline.} = mm_add_epi32(a, b)
func vecSub16*(a, b: VEPI16): VEPI16 {.simdInline.} = mm_sub_epi16(a, b)
func vecLShift16*(v: VEPI16, shift: int32 | uint32): VEPI16 {.simdInline.} = mm_slli_epi16(v, shift)
func vecRShift16*(v: VEPI16, shift: int32 | uint32): VEPI16 {.simdInline.} = mm_srli_epi16(v, shift)
func vecRAShift16*(v: VEPI16, shift: int32 | uint32): VEPI16 {.simdInline.} = mm_srai_epi16(v, shift)
func vecLShift32*(v: VEPI32, shift: int32 | uint32): VEPI32 {.simdInline.} = mm_slli_epi32(v, shift)
func vecRShift32*(v: VEPI32, shift: int32 | uint32): VEPI32 {.simdInline.} = mm_srli_epi32(v, shift)
func vecRAShift32*(v: VEPI32, shift: int32 | uint32): VEPI32 {.simdInline.} = mm_srai_epi32(v, shift)
func vecPackI16toU8*(a, b: VEPI16): VEPI16 {.simdInline.} = mm_packus_epi16(a, b)
func vecPermute*(v: VEPI16): VEPI16 {.simdInline.} = v
func vecReduceAdd32*(v: VEPI32): int32 {.simdInline.} =
    let pairs = mm_add_epi32(v, mm_srli_si128(v, 8))
    mm_cvtsi128_si32(mm_add_epi32(pairs, mm_srli_si128(pairs, 4)))

include common
