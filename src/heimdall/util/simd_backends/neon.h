/* Copyright 2026 Mattia Giambirtone & All Contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Authored with assistance from AI agents.
 */
#ifndef HEIMDALL_NEON_H
#define HEIMDALL_NEON_H
#include <arm_neon.h>

#if !defined(__aarch64__) || __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "Heimdall NEON requires little-endian AArch64"
#endif

static inline int16x8_t heimdall_zero(void) { return vdupq_n_s16(0); }
static inline int16x8_t heimdall_set32(int32_t n) { return vreinterpretq_s16_s32(vdupq_n_s32(n)); }
static inline int16x8_t heimdall_load(const void *p) { return vld1q_s16((const int16_t *)p); }
static inline void heimdall_store(void *p, int16x8_t v) { vst1q_s16((int16_t *)p, v); }
static inline int16x8_t heimdall_load8(const void *p) { return vmovl_s8(vld1_s8((const int8_t *)p)); }

#define HEIMDALL_BINARY32(name, op) \
    static inline int16x8_t name(int16x8_t a, int16x8_t b) { \
        return vreinterpretq_s16_s32(op(vreinterpretq_s32_s16(a), vreinterpretq_s32_s16(b))); \
    }
HEIMDALL_BINARY32(heimdall_max32, vmaxq_s32)
HEIMDALL_BINARY32(heimdall_min32, vminq_s32)
HEIMDALL_BINARY32(heimdall_mul32, vmulq_s32)
HEIMDALL_BINARY32(heimdall_add32, vaddq_s32)
#undef HEIMDALL_BINARY32

static inline int16x8_t heimdall_mulhi(int16x8_t a, int16x8_t b) {
    return vcombine_s16(vshrn_n_s32(vmull_s16(vget_low_s16(a), vget_low_s16(b)), 16),
                        vshrn_n_s32(vmull_high_s16(a, b), 16));
}

static inline int16x8_t heimdall_madd(int16x8_t a, int16x8_t b) {
    int32x4_t lo = vmull_s16(vget_low_s16(a), vget_low_s16(b));
    int32x4_t hi = vmull_high_s16(a, b);
    return vreinterpretq_s16_s32(vpaddq_s32(lo, hi));
}

static inline int16x8_t heimdall_maddubs(int16x8_t a, int16x8_t b) {
    /* Unsigned x signed byte products fit int16, but pair sums need int32
     * before saturating. Widen unsigned inputs before reinterpreting them. */
    uint8x16_t u = vreinterpretq_u8_s16(a);
    int8x16_t s = vreinterpretq_s8_s16(b);
    int16x8_t lo = vmulq_s16(vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(u))), vmovl_s8(vget_low_s8(s)));
    int16x8_t hi = vmulq_s16(vreinterpretq_s16_u16(vmovl_high_u8(u)), vmovl_high_s8(s));
    return vcombine_s16(vqmovn_s32(vpaddlq_s16(lo)), vqmovn_s32(vpaddlq_s16(hi)));
}

static inline int16x8_t heimdall_pack(int16x8_t a, int16x8_t b) {
    return vreinterpretq_s16_u8(vcombine_u8(vqmovun_s16(a), vqmovun_s16(b)));
}
static inline int32_t heimdall_reduce(int16x8_t v) { return vaddvq_s32(vreinterpretq_s32_s16(v)); }

/* NEON variable shifts interpret only the low byte of the count. Clamp first
 * so oversized counts retain x86 zero/sign-fill semantics. These helpers also
 * fold to immediate shifts when the inference call site supplies a constant. */
static inline int16x8_t heimdall_lshift16(int16x8_t v, uint32_t n) {
    return n >= 16 ? heimdall_zero() : vshlq_s16(v, vdupq_n_s16((int16_t)n));
}
static inline int16x8_t heimdall_rshift16(int16x8_t v, uint32_t n) {
    return n >= 16 ? heimdall_zero() : vreinterpretq_s16_u16(vshlq_u16(vreinterpretq_u16_s16(v), vdupq_n_s16(-(int16_t)n)));
}
static inline int16x8_t heimdall_rashift16(int16x8_t v, uint32_t n) {
    return vshlq_s16(v, vdupq_n_s16(-(int16_t)(n > 15 ? 15 : n)));
}
static inline int16x8_t heimdall_lshift32(int16x8_t v, uint32_t n) {
    return n >= 32 ? heimdall_zero() : vreinterpretq_s16_s32(vshlq_s32(vreinterpretq_s32_s16(v), vdupq_n_s32((int32_t)n)));
}
static inline int16x8_t heimdall_rshift32(int16x8_t v, uint32_t n) {
    return n >= 32 ? heimdall_zero() : vreinterpretq_s16_u32(vshlq_u32(vreinterpretq_u32_s16(v), vdupq_n_s32(-(int32_t)n)));
}
static inline int16x8_t heimdall_rashift32(int16x8_t v, uint32_t n) {
    return vreinterpretq_s16_s32(vshlq_s32(vreinterpretq_s32_s16(v), vdupq_n_s32(-(int32_t)(n > 31 ? 31 : n))));
}
#endif
