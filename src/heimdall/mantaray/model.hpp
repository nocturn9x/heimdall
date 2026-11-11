// Copyright 2026 Mattia Giambirtone & All Contributors
// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <MantaRay/MantaRay.h>

namespace HeimdallMR {
using namespace MantaRay;
constexpr auto Buckets = Mirrored(Array<u08, 32>{
    0,1,2,3, 4,5,6,7, 8,8,9,9, 10,10,11,11,
    12,12,13,13, 12,12,13,13, 14,14,15,15, 14,14,15,15
});

// All disk matrices are [input][bucket][output]. Keep this independent of
// Heimdall's native SIMD packing; MantaRay packs its own kernels at load time.
constexpr auto Model() {
    const auto [st, nt] = Input<Threats<TI60144>>();
    const auto [sp, np] = Input<KingBuckets<Buckets>>();
    const auto ps = Linear(768 * 16, HD_L1, Weights<i16>(255));
    const auto ti = Affine(60144, HD_L1, Weights<i08>(255), Biases<i16>(255));
    const auto l1 = Affine(HD_L1, HD_L2 * 8,
        Weights<i08>(Ratio(128 * 65536, 65025)), Biases<i32>(16384, Clip(1.98)));
    const auto l2 = Affine(HD_L2 * (1 + HD_DUAL), HD_L3 * 8,
        Weights<i16>(64, Clip(1.98)).Stored<i32>(), Biases<i32>(262144, Clip(1.98)));
    const auto l3 = Affine(HD_L3, 8,
        Weights<i32>(64, Clip(1.98)), Biases<i32>(16777216, Clip(1.98)));
    const auto s = Pairwise(ClippedReLU(Wrap<i16>(ps(sp) + ti(st)))) >> 9;
    const auto n = Pairwise(ClippedReLU(Wrap<i16>(ps(np) + ti(nt)))) >> 9;
    const auto h = Select<MaterialCount<8>>(l1(Concat(s, n))) >> 8;
#if HD_DUAL
    // Heimdall squares the signed value, including negative inputs.
    const auto a = Concat(ClippedReLU(h) << 6, Min(Square(h), 1));
#else
    const auto a = SquaredClippedReLU(h);
#endif
    const auto b = ClippedReLU(Select<MaterialCount<8>>(l2(a)));
    return Output(Select<MaterialCount<8>>(l3(b)), HD_SCALE,
        Bullet(ps.Weights(), ti.Weights(), ti.Biases(), l1.Weights(), l1.Biases(),
               l2.Weights(), l2.Biases(), l3.Weights(), l3.Biases()));
}
}
