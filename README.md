# heimdall

A UCI chess engine written in Nim


## Installation


Just run `nimble install` (Nim 2.0.4 or greater is required, see [here](https://github.com/dom96/choosenim)).

Or you can grab the latest version from the [releases](https://git.nocturn9x.space/nocturn9x/heimdall/releases) page

## Testing

Just run `nimble test`: sit back, relax, get yourself a cup of coffee and wait for it to finish :)


**Note**: The test suite expects both heimdall and stockfish to be installed and in the system's PATH

## Features

List of features that are either already implemented ([X]) or planned ([ ])

### Search

- [X] Null move pruning
- [X] Late move reductions (log formula)
- [X] Quiescent search
- [X] Aspiration windows
- [X] Futility pruning
- [X] Move reordering
- [X] Alpha-beta pruning
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
- [X] Killer heuristic
- [X] Null-window search
- [X] Parallel search (lazy SMP)
- [X] Pondering
- [X] Counter moves
- [X] Late move pruning
- [X] SEE pruning
- [X] Internal iterative reductions
- [X] Singular extensions
    - [ ] Multi-cut pruning
    - [ ] Negative extensions
    - [ ] Double extensions
- [X] Capture history
- [X] Continuation history
    - [X] 1 ply
    - [X] 2 ply
    - [ ] 4 ply
- [ ] Razoring


### Eval

Heimdall uses NNUE (Efficiently Updatable Neural Network) to evaluate positions. 

Current networks:
- mjolnir: (768x64)x2->1
- gungnir: (768x128)x2->1


The data for mjolnir and gungnir has been generated using the latest release of Heimdall HCE (0.4), subsequent
networks will augment this data by generating more with the new NNUE evaluation.

More will come!


### Time Management

- [X] Hard/Soft limit
- [ ] Node TM
- [ ] BM Stability


## More info

Heimdall is available on [Lichess](https://lichess.org/@/Nimfish) under its old name (Nimfish), feel free to challenge it!
I try to keep the engine running on there always up to date with the changes on the master branch

## Strength

| Version     | Estimated   | CCRL 40/15  | CCRL Blitz
| ----------- | ----------- | ----------- | -----------
| 0.1         | 2531        | 2436        | N/A
| 0.2         | 2706        | 2669        | N/A
| 0.3         | 2837        | N/A         | N/A
| 0.4         | 2888        | 2858        | N/A


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

Y'all are awesome! <3


**P.S.** I'm sure I forgot someone, please let me know who it is!
