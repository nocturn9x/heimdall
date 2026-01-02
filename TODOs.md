# TODO list for Heimdall releases

## 1.5 - ETA: ~1-2 month(s)

- [ ] Train a new net with stage 1 of datagen experiment (in progress, waiting for full dataset to train final net)
- [ ] Implement multilayer inference (scalar working, SIMD missing) and train a multilayer net with new data
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
- [ ] Continuation correction history
- [ ] Pawn history
- [ ] Fractional LMR
- [ ] SPSA
- [ ] (Maybe) Stage 2 of the datagen experiment
- [ ] (Maybe) New help menu in mixed mode, autocomplete support

Last updated: 02/01/2026