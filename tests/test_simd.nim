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

## Integer vec* contract, independent of network weights and inference layout.
import std/random
import heimdall/util/simd

static: doAssert defined(simd)

func wrap16(n: int64): int16 = cast[int16](uint16(n and 0xffff))
func wrap32(n: int64): int32 = cast[int32](uint32(n and 0xffffffff))
func sar(n: int64, shift: int): int64 =
    if shift == 0: n
    elif n >= 0: n div (1'i64 shl shift)
    else: -1 - ((-1 - n) div (1'i64 shl shift))

template check16(value, expected: untyped) =
    block:
        var actual {.align(64).}: array[I16_CHUNK_SIZE, int16]
        vecStore(addr actual[0], value)
        for lane {.inject.} in 0..<actual.len:
            doAssert actual[lane] == expected, "int16 lane " & $lane

template check32(value, expected: untyped) =
    block:
        var actual {.align(64).}: array[I32_CHUNK_SIZE, int32]
        vecStore(addr actual[0], value)
        for lane {.inject.} in 0..<actual.len:
            doAssert actual[lane] == expected, "int32 lane " & $lane

var rng = initRand(0x128512)
for sample in 0..<256:
    var a16, b16 {.align(64).}: array[I16_CHUNK_SIZE, int16]
    var a32, b32 {.align(64).}: array[I32_CHUNK_SIZE, int32]
    var u0, u1 {.align(64).}: array[REGISTER_SIZE, uint8]
    var s0, s1 {.align(64).}: array[REGISTER_SIZE, int8]
    for i in 0..<I16_CHUNK_SIZE:
        a16[i] = wrap16(rng.rand(65535).int64)
        b16[i] = wrap16(rng.rand(65535).int64)
        if sample < 8:
            const edges = [low(int16), -32767'i16, -1'i16, 0'i16, 1'i16, 255'i16, 256'i16, high(int16)]
            a16[i] = edges[sample]
            b16[i] = edges[i mod edges.len]
    for i in 0..<I32_CHUNK_SIZE:
        a32[i] = wrap32(rng.rand(0xffffffff'i64))
        b32[i] = wrap32(rng.rand(0xffffffff'i64))
        if sample < 4:
            const edges = [low(int32), -1'i32, 0'i32, high(int32)]
            a32[i] = edges[sample]
            b32[i] = edges[i mod edges.len]
    for i in 0..<REGISTER_SIZE:
        u0[i] = rng.rand(255).uint8
        u1[i] = rng.rand(255).uint8
        s0[i] = (rng.rand(255) - 128).int8
        s1[i] = (rng.rand(255) - 128).int8
        if sample < 2:
            u0[i] = 255
            u1[i] = 255
            s0[i] = if sample == 0: -128 else: 127
            s1[i] = s0[i]
    let a = vecLoad(addr a16[0])
    let b = vecLoad(addr b16[0])
    let c = vecLoad(addr a32[0])
    let d = vecLoad(addr b32[0])
    check16(a, a16[lane])
    check32(c, a32[lane])
    check16(vecZero16(), 0)
    check32(vecZero32(), 0)
    check16(vecSetOne16(a16[0]), a16[0])
    check32(vecSetOne32(a32[0]), a32[0])
    check16(vecAdd16(a, b), wrap16(a16[lane].int64 + b16[lane].int64))
    check16(vecSub16(a, b), wrap16(a16[lane].int64 - b16[lane].int64))
    check16(vecMin16(a, b), min(a16[lane], b16[lane]))
    check16(vecMax16(a, b), max(a16[lane], b16[lane]))
    check16(vecMullo16(a, b), wrap16(a16[lane].int64 * b16[lane].int64))
    check16(vecMulhi16(a, b), sar(a16[lane].int64 * b16[lane].int64, 16).int16)
    check32(vecMin32(c, d), min(a32[lane], b32[lane]))
    check32(vecMax32(c, d), max(a32[lane], b32[lane]))
    check32(vecAdd32(c, d), wrap32(a32[lane].int64 + b32[lane].int64))
    check32(vecMullo32(c, d), wrap32(a32[lane].int64 * b32[lane].int64))
    check32(vecMadd16(a, b), wrap32(a16[lane * 2].int64 * b16[lane * 2].int64 +
                                  a16[lane * 2 + 1].int64 * b16[lane * 2 + 1].int64))
    var sum = 0'i64
    for n in a32: sum += n.int64
    doAssert vecReduceAdd32(c) == wrap32(sum)

    template shifts(n: static int) =
        check16(vecLShift16(a, n.int32), (if n >= 16: 0'i16 else: wrap16(a16[lane].int64 shl n)))
        check16(vecRShift16(a, n.int32), (if n >= 16: 0'i16 else: cast[int16](cast[uint16](a16[lane]) shr n)))
        check16(vecRAShift16(a, n.int32), sar(a16[lane].int64, min(n, 15)).int16)
        check32(vecLShift32(c, n.int32), (if n >= 32: 0'i32 else: wrap32(a32[lane].int64 shl n)))
        check32(vecRShift32(c, n.int32), (if n >= 32: 0'i32 else: cast[int32](cast[uint32](a32[lane]) shr n)))
        check32(vecRAShift32(c, n.int32), sar(a32[lane].int64, min(n, 31)).int32)
    shifts(0)
    shifts(1)
    shifts(7)
    shifts(15)
    shifts(16)
    shifts(31)
    shifts(32)
    shifts(63)

    var packed {.align(64).}: array[REGISTER_SIZE, uint8]
    vecStore(addr packed[0], vecPermute(vecPackI16toU8(a, b)))
    for i in 0..<I16_CHUNK_SIZE:
        doAssert packed[i] == clamp(a16[i].int, 0, 255).uint8
        doAssert packed[i + I16_CHUNK_SIZE] == clamp(b16[i].int, 0, 255).uint8

    var source: array[I16_CHUNK_SIZE + 1, int8]
    for i in 0..<I16_CHUNK_SIZE: source[i + 1] = cast[int8](((sample + i) and 255).uint8)
    check16(vecLoadI8AsI16(addr source[1]), source[lane + 1].int16)

    var pairs0, pairs1: array[I16_CHUNK_SIZE, int16]
    var dot, dot2: array[I32_CHUNK_SIZE, int32]
    for i in 0..<I16_CHUNK_SIZE:
        pairs0[i] = clamp(u0[2*i].int64 * s0[2*i].int64 + u0[2*i+1].int64 * s0[2*i+1].int64, -32768, 32767).int16
        pairs1[i] = clamp(u1[2*i].int64 * s1[2*i].int64 + u1[2*i+1].int64 * s1[2*i+1].int64, -32768, 32767).int16
    for i in 0..<I32_CHUNK_SIZE:
        when defined(vnni):
            var x, y: int64
            for k in 0..<4:
                x += u0[4*i+k].int64 * s0[4*i+k].int64
                y += u1[4*i+k].int64 * s1[4*i+k].int64
            dot[i] = wrap32(a32[i].int64 + x)
            dot2[i] = wrap32(a32[i].int64 + x + y)
        else:
            dot[i] = wrap32(a32[i].int64 + pairs0[2*i].int64 + pairs0[2*i+1].int64)
            dot2[i] = wrap32(a32[i].int64 + wrap16(pairs0[2*i].int64 + pairs1[2*i].int64).int64 +
                            wrap16(pairs0[2*i+1].int64 + pairs1[2*i+1].int64).int64)
    let vu0 = vecLoad(addr u0[0])
    let vs0 = vecLoad(addr s0[0])
    check16(vecMaddubs16(vu0, vs0), pairs0[lane])
    check32(vecDpbusd(c, vu0, vs0), dot[lane])
    check32(vecDpbusdx2(c, vu0, vs0, vecLoad(addr u1[0]), vecLoad(addr s1[0])), dot2[lane])

echo "vec* contract: 256 edge/random cases passed; register bytes=", REGISTER_SIZE
