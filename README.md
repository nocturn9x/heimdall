![Heimdall](Heimdall_logo_v2.png "Heimdall")

# heimdall

Heimdall is a superhuman chess engine written in Nim. As far as I know, this is the strongest Nim engine that has ever been tested (please
let me know should that not be the case), sitting around the top 70-80 rank globally.


##### Logo by @kan, thank you!

## Installation


Just run `nimble install` (Nim 2.0.4 or greater is required, see [here](https://github.com/dom96/choosenim)).

Or you can grab the latest version from the [releases](https://git.nocturn9x.space/nocturn9x/heimdall/releases) page

__Note__: If you're trying to build Heimdall on a CPU without AVX2 support, comment out `-d:simd` in nim.cfg

__Note 2__: The Makefile in this repository is only meant for compatibility with [OpenBench](https://github.com/AndyGrant/OpenBench)
and _not_ for building release binaries. Using `nimble` is the only properly supported build method

## Testing

Just run `nimble test`: sit back, relax, get yourself a cup of coffee and wait for it to finish :)


**Note**: The test suite requires Python and expects both heimdall and stockfish to be installed and in the system's PATH


## Search

Heimdall implements negamax search with alpha-beta pruning in a PVS framework to search the game tree
and utilizes several heuristics to help it navigate the gigantic search space of chess

## Eval

Heimdall currently uses NNUE (Efficiently Updatable Neural Network) to evaluate positions. All of heimdall's networks
are trained with [bullet](https://github.com/jw1912/bullet) using data obtained from selfplay of previous versions,
while previous HCE releases used the lichess-big3 dataset for tuning. The current network architecture is a horizontally
mirrored perspective network with a single hidden layer of 1280 neurons, with 16 input buckets and 8 output buckets, commonly
represented as (768x16->1280)x2->1x8


## More info

Heimdall is sometimes available on [Lichess](https://lichess.org/@/Nimfish) under its old name (Nimfish), feel free to challenge it!
I try to keep the engine running on there always up to date with the changes on the master branch

## Strength

| Version | Estimated   | CCRL 40/15  | TCEC  | CCRL FRC 40/2 | CCRL Blitz 2+1 | MCERL | CEGT |
| ------- | ----------- | ----------- | ----  | ------------- | -------------- | ----- | ---- |
| 0.1     | 2531        | 2436        | -     | N/A           | -              | -     | -    |
| 0.2     | 2706        | 2669        | -     | N/A           | -              | -     | -    |
| 0.3     | 2837        | -           | -     | N/A           | -              | -     | -    |
| 0.4     | 2888        | 2865        | -     | 2925          | -              | -     | -    |
| 1.0     | 3230        | 3195        | 3163* | 3370          | -              | -     | -    |
| 1.1     | 3370        | -           | -     | -             | -              | -     | -    |
| 1.1.1   | 3390**      | 3362        | -     | 3555          | 3387           | 3440  | 3284 |

*: Beta version, not final 1.0 release

**: Estimated at LTC (40+0.4, 128MB hash) against Stash v36 (-0.2 +- 11.1)

__Note__: Unless otherwise specified, estimated strenght is measured for standard chess at a short time control (8 seconds with 0.08 seconds increment)
and a 16MB hash table over 1000 game pairs against the previous version (except for version 0.1 where it was tested in a gauntlet) using the Pohl opening
book (up to version 1.0) and the UHO_Lichess_4852_v1 book for later versions, and is therefore not as accurate as the other ratings which are provided by
testers running the engine at longer TCs against a pool of different opponents

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
- @cj5716: Provided lots of ideas to steal

Y'all are awesome! <3


**P.S.** I'm sure I forgot someone, please let me know who it is!
