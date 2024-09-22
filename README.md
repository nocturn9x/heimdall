# heimdall

![Heimdall](Heimdall_logo_v2.png "Heimdall")


A superhuman UCI chess engine written in Nim


##### Logo by @kan, thank you!

## Installation


Just run `nimble install` (Nim 2.0.4 or greater is required, see [here](https://github.com/dom96/choosenim)).

Or you can grab the latest version from the [releases](https://git.nocturn9x.space/nocturn9x/heimdall/releases) page

## Testing

Just run `nimble test`: sit back, relax, get yourself a cup of coffee and wait for it to finish :)


**Note**: The test suite expects both heimdall and stockfish to be installed and in the system's PATH

## Features

List of features that are either already implemented or planned

### Search

- [X] Alpha-beta pruning
- [X] Null move pruning
- [X] Late move reductions (log formula)
- [X] Quiescent search
- [X] Aspiration windows
- [X] Futility pruning
- [X] Move reordering (hash -> good capture -> killer -> counter -> quiet -> bad capture)
- [X] Check extensions
- [X] QSEE pruning
- [X] Reverse futility pruning
- [X] Principal variation search
- [X] Iterative deepening
- [X] Transposition table
    - [X] TT Cutoffs
    - [X] TT Move ordering
- [X] Static exchange evaluation
- [X] Quiet history heuristic
    - [X] History gravity
    - [X] History malus
- [X] Improving heuristic
  - [ ] LMR
  - [X] FP
  - [X] RFP
  - [X] LMP
- [X] Killer heuristic
- [X] Null-window search
- [X] Counter moves
- [X] Late move pruning
- [X] SEE pruning
- [X] Internal iterative reductions
- [X] Singular extensions
    - [ ] Multi-cut pruning
    - [ ] Negative extensions
    - [ ] Double/triple extensions
- [X] Capture history
- [X] Cutnode LMR
- [X] History LMR
- [X] Continuation history
    - [X] 1 ply
    - [X] 2 ply
    - [ ] 4 ply
- [ ] Razoring
- [ ] Qsearch late move pruning
- [X] Qsearch futility pruning
- [ ] Correction history
  - [ ] Pawns
  - [ ] Material

### Eval

Heimdall uses NNUE (Efficiently Updatable Neural Network) to evaluate positions. All of heimdall's networks are
trained using data obtained from selfplay of previous versions.

- [X] Basic inference
- [ ] Bucketing
  - [ ] Input buckets
  - [ ] Output buckets
- [X] Horizontal mirroring
- [ ] More layers
- [X] Optimizations
  - [X] Efficient updates
  - [X] Lazy updates
  - [ ] Add/sub
  - [X] Explicit SIMD
    - [X] AVX2
    - [ ] AVX512


Network history:
- mjolnir: (768->64)x2->1
  - v1: Trained with 64240917 positions generated via self-play with Heimdall 0.4 (10 superbatches, LR drop every 4)
  - v2: Trained with 104501671 positions generated via self-play with Heimdall dev (mjolnir v1)
  - v3: Trained with the same data as v2, but with 40 superbatches instead of 10 (LR drop every 20)
- gungnir: (768->128)x2->1
  - v1: Trained with the same data and training regimen as mjolnir v3
  - v2: Trained with 119217929 positions generated by gungnir v1
  - v3: Trained with 223719600 positions obtained by merging the datasets generated by gungnir v1 and mjolnir v2
- sumarbrander: (768->256)x2->1
  - v1: Trained with 332049019 positions obtained by merging 3 datasets generated by gungnir v1 and v3 and mjolnir v2
  - v2: Trained with 335887535 positions generated by sumarbrander v1
  - v3: Trained with 356421019 positions generated by sumarbrander v2. First GPU net trained with 80 superbatches,
    cosine LR scheduling and 80% WDL
  - v4: Trained with the data from v2 plus an additional 333881249 positions generated by v3 with a 3k soft node limit (as opposed to 5k).
        The training schedule is the same as v3 except the number of superbatches doubled to 160
- angurvadal: (768->512)x2->1
  - v1: Trained with the datasets generated by sumarbrander v2 and v3 (356421019 + 333881249 = 690302268 positions), plus an additional
        472593216 positions generated by sumarbrander v4. The data contains a mix of 5k and 3k soft node searches. Net trained for 200
        superbatches on 80% WDL (other settings are analogous to sumarbrander v4)
  - v2: Trained with 409932840 positions generated by angurvadal v1 plus the data generated by sumarbrander v3 and v4 for 250 superbatches
        with 80% WDL and cosine LR decay
  - v3: Trained with the same data and training regimen as v2 plus 274391262 positions generated by v2 itself. First horizontally mirrored network
  - v4: Trained with the same data and training regimen as v3, but with WDL set to 100%
- ridill: (768->1024)x2->1
  - v1: Trained with positions generated by angurvadal v1, v2, v3 and v4 (409932840 + 274391262 + 91378568 + 241112579 = 1016815249 positions) along
        with the data generated by sumarbrander v4 and v3 (472593216 + 333881249 = 806474465 positions) using pure WDL

All networks up to angurvadal v2 are trained using [bullet](https://github.com/jw1912/bullet)'s simple example script. Unless otherwise specified,
the wdl ratio is set to 75%


### Time Management

- [X] Hard/Soft limit
- [ ] Node time management (WIP)
- [ ] Best move Stability
- [ ] Eval stability

### Nice-to-have

- [X] Chess960 support (FRC and DFRC)
- [X] MultiPV search
- [X] Parallel search (lazy SMP)
- [X] Pondering

## More info

Heimdall is available on [Lichess](https://lichess.org/@/Nimfish) under its old name (Nimfish), feel free to challenge it!
I try to keep the engine running on there always up to date with the changes on the master branch

## Strength

| Version     | Estimated   | CCRL 40/15  | TCEC     | CCRL FRC 40/2
| ----------- | ----------- | ----------- | -----    | -------------
| 0.1         | 2531        | 2436        | Unlisted | N/A
| 0.2         | 2706        | 2669        | Unlisted | N/A
| 0.3         | 2837        | Unlisted    | Unlisted | N/A
| 0.4         | 2888        | 2880        | Unlisted | 2934
| 1.0         | 3230        | TBD         | Unlisted | TBD



## Notes

This repository was extracted from a monorepo that you can check out [here](https://git.nocturn9x.space/nocturn9x/CPG) (look into the `Chess/`
directory): all history before the first commit here can be found there!


## Credits

Many thanks to all the folks on the Engine Programming and Stockfish servers on Discord: your help has been invaluable and Heimdall literally
would not exist without the help of all of you. In no particular order, I'd like to thank:
- @analog-hors (okay, she's first for a reason): for her awesome article about magic bitboards as well as providing the initial code for the
    HCE tuner and the NN inference to get me started on NNUE
- @ciekce: for helping me debug countless issues
- @sroelants: provided debugging help and lots of good ideas to steal
- @tsoj: Saved my ass by solving some major performance bottlenecks and helping me debug my broken threading code
- @viren, @zuppadcipolle, @toanth, @fuuryy: Debugging help
- @DarkNeutrino: for lending cores to my OB instance
- @ceorwmt: for helping with datagen

Y'all are awesome! <3


**P.S.** I'm sure I forgot someone, please let me know who it is!
