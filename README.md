# heimdall

A UCI chess engine written in Nim

## Installation


Just run `nimble install` (Nim 2.0.4 or greater is required, see [here](https://github.com/dom96/choosenim)).

Or you can grab the latest version from the [releases](https://git.nocturn9x.space/nocturn9x/heimdall/releases) page

## Testing

Just run `nimble test`: sit back, relax, get yourself a cup of coffee and wait for it to finish :)


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

- [X] Piece-square tables
- [X] Material
- [X] Tempo
- [X] King safety
    - [X] Virtual king mobility
    - [ ] Pawn shield
    - [ ] Pawn storm
    - [X] King zone attacks
- [X] Mobility (sliders and knights)
    - [X] Mask off pawn attacks
    - [ ] Consider pins
- [ ] Minor piece outpost
- [X] Bishop pair
- [X] Rook on (semi-)open file
- [ ] Queen on (semi-)open file
- [ ] Connected rooks
- [X] Threats
    - [X] Pieces attacked by pawns
    - [X] Major pieces attacked by minor pieces
    - [X] Queens attacked by rooks
- [X] Safe checks to enemy king
    - [ ] Consider defended squares
- [X] Pawn structure
    - [X] Isolated pawns
    - [X] Strong (aka protected) pawns
    - [ ] Doubled pawns
    - [X] Passed pawns
    - [ ] Phalanx pawns


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

## Notes

This repository was extracted from a monorepo that you can check out [here](https://git.nocturn9x.space/nocturn9x/CPG) (look into the `Chess/`
directory): all history before the first commit here can be found there!
