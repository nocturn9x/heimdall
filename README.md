# heimdall

A UCI chess engine written in Nim

## Installation


Just run `nimble install` (Nim 2.0.4 or greater is required, see [here](https://github.com/dom96/choosenim))


## Testing

Just run `nimble test`: sit back, relax, get yourself a cup of coffee and wait for it to finish :)


## Features

List of features that are either already implemented or planned

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
    - [X] Cutoffs
    - [X] Move ordering
- [X] MVV-LVA
- [X] Static exchange evaluation
- [X] History heuristic
    - [X] History gravity
    - [ ] History malus
    - [X] History aging
- [X] Killer heuristic
- [X] Null-window search
- [X] Parallel search (lazy SMP)
- [X] Pondering
- [ ] Capture history
- [ ] Continuation history
- [ ] Late move pruning
- [ ] Counter moves
- [ ] Razoring
- [ ] Internal iterative reductions
- [ ] Internal iterative deepening


### Eval

- [X] Piece-square tables
- [X] Material
- [X] Tempo
- [ ] King safety
    - [X] Virtual queen mobility
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
- [ ] Threats
    - [ ] Pieces attacked by pawns
    - [ ] Major pieces attacked by minor pieces
    - [ ] Queens attacked by rooks
- [X] Pawn structure
    - [X] Isolated pawns
    - [X] Strong (aka protected) pawns
    - [ ] Doubled pawns
    - [X] Passed pawns
    - [ ] Phalanx pawns


## More info

Heimdall is available on [Lichess](https://lichess.org/@/Nimfish) under its old name (Nimfish), feel free to challenge it!
I try to keep the engine running on there always up to date with the changes on the master branch

## Notes

This repository was extracted from a monorepo that you can check out [here](https://git.nocturn9x.space/nocturn9x/CPG) (look into the `Chess/`
directory): all history before the first commit here can be found there!
