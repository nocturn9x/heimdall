![Heimdall](Heimdall_logo_v2.png "Heimdall")

# heimdall

Heimdall is a superhuman chess engine written in Nim. As far as I know, this is the strongest Nim engine that has ever been tested (please
let me know should that not be the case), sitting around the top 60 rank globally.


##### Logo by @kan, thank you!

## Installation


Just run `make`, this is the easiest (Nim 2.0.4 or greater is required, see [here](https://github.com/dom96/choosenim)). It will
build the most optimized executable possible, but AVX2 support is expected on the target platform.

You can also run `make modern` to build a modern version of Heimdall with a more generic instruction set (AVX2 support is still required here,
the target architecture will just not be `native`). This will allow the generated executable to run without issues on systems without the exact CPU
architecture the compile was done on (and is what you want for releases/sharing the result). For older CPUs without AVX2 support, run `make legacy`
(note that the resulting executable will be significantly slower though). In every case, the resulting executable will be located at `bin/$(EXE)`
(`bin/heimdall` by default).

Or you can grab the latest version from the [releases](https://git.nocturn9x.space/nocturn9x/heimdall/releases) page


**P.S.**: If you want to install Heimdall on your system you can also run `nimble install` (making sure that nimble's
own binary directory is in your system's path), which will build the same executable that a bare `make` would (no
legacy/generic installation support as of now)


## Testing

Just run `nimble test`: sit back, relax, get yourself a cup of coffee and wait for it to finish :)


**Note**: The test suite requires Python and expects both heimdall and stockfish to be installed and in the system's PATH


## ⚠️ ⚠️ Notes for engine testers ⚠️ ⚠️

Heimdall is designed (and tested) to play at the standard time controls of time + increment: since I do not have the hardware nor
the time to test others (like sudden death or moves to go), support for outdated/nonstandard time controls has been hidden behind
the `EnableWeirdTCs` option: unless this option is set to `true`, Heimdall will refuse to play either if its own increment is missing
or if it is told to play with a moves to go time control (this one is especially important because it is not taken into account at
all in time management!). This technically means Heimdall is not fully UCI compliant unless `EnableWeirdTCs` is enabled: I believe this
trade-off is worth it, as it means that if it does indeed perform worse at untested time controls then the tester will have full knowledge
as to why that is. If that upsets you or makes you want to not test Heimdall, that's fine! I'm sorry you feel that way, but this is my engine
after all :)


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

| Version   | Estimated   | CCRL 40/15  | TCEC  | CCRL FRC 40/2 | CCRL Blitz 2+1 | MCERL | CEGT |
| --------- | ----------- | ----------- | ----  | ------------- | -------------- | ----- | ---- |
| 0.1       | 2531        | 2436        | -     | N/A           | -              | -     | -    |
| 0.2       | 2706        | 2669        | -     | N/A           | -              | -     | -    |
| 0.3       | 2837        | -           | -     | N/A           | -              | -     | -    |
| 0.4       | 2888        | 2866        | -     | 2925          | -              | -     | -    |
| 1.0       | 3230        | 3194        | 3163* | 3370          | -              | -     | -    |
| 1.1       | 3370        | -           | -     | -             | -              | -     | -    |
| 1.1.1     | 3390**      | 3363        | -     | 3555          | 3390           | 3440  | 3284 |
| 1.2       | 3490        | -           | -     | -             | -              | 3470  | -    |
| 1.2.{1,2} | 3500        | 3368        | -     | 3621          | 3465           | -     | 3297 |


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
