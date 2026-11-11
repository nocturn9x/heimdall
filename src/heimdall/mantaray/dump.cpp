// Copyright 2026 Mattia Giambirtone & All Contributors
// SPDX-License-Identifier: Apache-2.0
#include "backend.hpp"
#include <MantaRay/IR/Dump.h>
#include <iostream>

int main() {
    using namespace MantaRay;
    using Model = MantaRay::Model<HeimdallMR::Model>;
    constexpr auto &program = HeimdallMR::StackProgram;
    constexpr auto explanations = Lowering::Explain(program,
        Lowering::CapabilitiesOf<Backend::ISAOf<Lowering::Native>>());
    constexpr auto plan = Detail::PlanOf<Model>(program);
    std::cout << "Canonical graph and inferred facts\n" << IR::Dump(Model::Graph, Model::Facts);
    std::cout << "\nTarget: " << Lowering::Native.Name << "\nAccumulator slots\n";
    for (s00 i = 0; i < program.SlotCount; ++i) {
        const auto &s = program.Slots[i];
        std::cout << i << ": root=%" << s.Root << " twin=" << s.Twin
                  << " type=" << Lowering::TypeNames[static_cast<s00>(s.Type)]
                  << " width=" << s.Width << " featureSets=" << s.FeatureSets
                  << " incremental=" << s.Incremental << '\n';
    }
    std::cout << "\nLowered stages\n";
    for (s00 i = 0; i < program.StageCount; ++i) {
        const auto &s = program.Stages[i];
        std::cout << i << ": " << Lowering::KindNames[static_cast<s00>(s.Kind)]
                  << " node=%" << s.Node
                  << " form=" << Lowering::FormNames[static_cast<s00>(s.Form)]
                  << " dot=" << Lowering::DotNames[static_cast<s00>(s.Dot)]
                  << " mode=" << Lowering::ModeNames[static_cast<s00>(s.Mode)]
                  << " input=" << Lowering::TypeNames[static_cast<s00>(s.Input)]
                  << " weight=" << Lowering::TypeNames[static_cast<s00>(s.Weight)]
                  << " output=" << Lowering::TypeNames[static_cast<s00>(s.Output)]
                  << " width=" << s.Width << " rows=" << s.Rows << " buckets=" << s.Buckets
                  << " vector=" << s.Vector << " bias=" << s.Bias << " biasInit=" << s.BiasInit
                  << " wide=" << s.Wide << " sparse=" << s.Sparse << " fused=" << s.Fused
                  << " activation=" << Lowering::ActivationNames[static_cast<s00>(s.Activation)]
                  << " then=" << Lowering::ActivationNames[static_cast<s00>(s.Then)]
                  << " shift=" << s.Shift << " thenShift=" << s.ThenShift << '\n';
        std::cout << std::string_view(explanations[i].data(), explanations[i].size()) << '\n';
    }
    std::cout << "\nRuntime buffer plan supported=" << plan.Supported << "\n";
    for (s00 i = 0; i < plan.Values.size(); ++i)
        if (plan.Values[i]) std::cout << Lowering::TypeNames[i] << " buffer elements=" << plan.Values[i] << '\n';
    std::cout << "Accumulator grouping: "
              << (HeimdallMR::Grouping == Accumulators::Combined ? "combined" : "split")
              << "\nStack bytes: " << sizeof(HeimdallMR::Stack) << '\n';
}
