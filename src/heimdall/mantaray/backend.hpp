// Copyright 2026 Mattia Giambirtone & All Contributors
// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "model.hpp"

namespace HeimdallMR {
using Net = MantaRay::Network<Model>;
constexpr auto Grouping = MantaRay::Accumulators::HD_MR_ACCUMULATORS;
using Stack = MantaRay::AccumulatorStack<Model, 256, MantaRay::UpdatePolicy::Lazy, Grouping>;
constexpr auto StackProgram = Grouping == MantaRay::Accumulators::Combined
    ? MantaRay::Lowering::Combine(Net::Program) : Net::Program;
}
