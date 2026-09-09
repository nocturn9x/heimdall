<!--
Copyright 2026 Mattia Giambirtone & All Contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# TODO list for Heimdall releases

## 1.5 - ETA: ~1-2 month(s)

- [X] Train a new net with stage 1 of datagen experiment (in progress, waiting for full dataset to train final net)
- [X] Implement multilayer inference (scalar working, SIMD missing) and train a multilayer net with new data
- [X] Initial work on human-friendly terminal interface (TODO: autocomplete, help menu)
- [X] Full `NO_COLOR` support
- [X] General cleanup/refactor (yeet raw pointers, verbose comments, alignment, etc.)

## 1.6 - ETA: TBD

- [ ] Probcut (tweak: [here](https://github.com/codedeliveryservice/Reckless/commit/08adcffc89ed9a955a0053090d7cfe3e0440e96a))
- [ ] Quadruple extensions (SE)
- [ ] Low depth singular extensions
- [ ] Qsearch check evasions
- [ ] Simplify counter moves
- [ ] Simplify check extensions
- [X] Continuation correction history
- [ ] Pawn history
- [X] Fractional LMR
- [ ] SPSA
- [ ] (Maybe) Stage 2 of the datagen experiment
- [ ] (Maybe) New help menu in mixed mode, autocomplete support

Last updated: 18/06/2026