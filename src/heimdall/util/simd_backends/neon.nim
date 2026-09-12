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

## AArch64 NEON with the same opaque register type and integer semantics as x86.
## The small C adapter keeps reinterpret casts out of inference and works around
## the unsigned-only NEON bindings in the pinned nimsimd dependency.
import std/os
const neonHeader = currentSourcePath().parentDir / "neon.h"

when not defined(arm64):
    {.error: "The NEON backend requires AArch64 (--cpu:arm64 when cross-compiling)".}

type
    VEPI16* {.importc: "int16x8_t", header: neonHeader, bycopy.} = object
    VEPI32* = VEPI16

{.push header: neonHeader.}
func vecZero16*(): VEPI16 {.importc: "heimdall_zero".}
func vecZero32*(): VEPI32 {.importc: "heimdall_zero".}
func vecSetOne16*(n: int16): VEPI16 {.importc: "vdupq_n_s16".}
func vecSetOne32*(n: int32): VEPI32 {.importc: "heimdall_set32".}
func vecStore*(dst: pointer, v: VEPI16) {.importc: "heimdall_store".}
func vecLoad*(src: pointer): VEPI16 {.importc: "heimdall_load".}
func vecLoadI8AsI16*(src: pointer): VEPI16 {.importc: "heimdall_load8".}
func vecWidenLowI8*(v: VEPI16): VEPI16 {.importc: "heimdall_widen_low8".}
    ## Widen the low eight signed bytes to int16 lanes.
func vecWidenHighI8*(v: VEPI16): VEPI16 {.importc: "heimdall_widen_high8".}
    ## Widen the high eight signed bytes to int16 lanes.
func vecMax16*(a, b: VEPI16): VEPI16 {.importc: "vmaxq_s16".}
func vecMin16*(a, b: VEPI16): VEPI16 {.importc: "vminq_s16".}
func vecMax32*(a, b: VEPI32): VEPI32 {.importc: "heimdall_max32".}
func vecMin32*(a, b: VEPI32): VEPI32 {.importc: "heimdall_min32".}
func vecMullo16*(a, b: VEPI16): VEPI16 {.importc: "vmulq_s16".}
func vecMullo32*(a, b: VEPI32): VEPI32 {.importc: "heimdall_mul32".}
func vecMaddubs16*(a, b: VEPI16): VEPI16 {.importc: "heimdall_maddubs".}
func vecMulhi16*(a, b: VEPI16): VEPI16 {.importc: "heimdall_mulhi".}
func vecMadd16*(a, b: VEPI16): VEPI32 {.importc: "heimdall_madd".}
func vecPairwiseAddAcc32*(acc: VEPI32, pairs: VEPI16): VEPI32 {.importc: "heimdall_pairwise_add_acc".}
    ## Widen adjacent signed int16 pairs, sum them and accumulate into int32 lanes.
func vecAdd16*(a, b: VEPI16): VEPI16 {.importc: "vaddq_s16".}
func vecAdd32*(a, b: VEPI32): VEPI32 {.importc: "heimdall_add32".}
func vecSub16*(a, b: VEPI16): VEPI16 {.importc: "vsubq_s16".}
func vecLShift16*(v: VEPI16, shift: int32 | uint32): VEPI16 {.importc: "heimdall_lshift16".}
func vecRShift16*(v: VEPI16, shift: int32 | uint32): VEPI16 {.importc: "heimdall_rshift16".}
func vecRAShift16*(v: VEPI16, shift: int32 | uint32): VEPI16 {.importc: "heimdall_rashift16".}
func vecLShift32*(v: VEPI32, shift: int32 | uint32): VEPI32 {.importc: "heimdall_lshift32".}
func vecRShift32*(v: VEPI32, shift: int32 | uint32): VEPI32 {.importc: "heimdall_rshift32".}
func vecRAShift32*(v: VEPI32, shift: int32 | uint32): VEPI32 {.importc: "heimdall_rashift32".}
func vecPackI16toU8*(a, b: VEPI16): VEPI16 {.importc: "heimdall_pack".}
func vecReduceAdd32*(v: VEPI32): int32 {.importc: "heimdall_reduce".}
{.pop.}

func vecPermute*(v: VEPI16): VEPI16 {.inline.} = v

const
    CHUNK_SIZE* = 8
    REGISTER_SIZE* = 16
    backendNeon = true

{.pragma: simdInline, inline.}
include common
