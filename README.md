![Heimdall](Heimdall_logo_v2.png "Heimdall")

# heimdall

Heimdall is a superhuman chess engine written in Nim. As far as I know, this is the strongest Nim engine that has ever been tested (please
let me know should that not be the case), sitting around the top 60 rank globally.


##### Logo by @kan, thank you!

## Building and Installation

**Note**: Do **not** run a bare `make` command! This will not update the neural networks submodule and is meant to be used by [OpenBench](https://gitbub.com/AndyGrant/OpenBench) only.

Just run `make native`, this is the easiest (Nim 2.2.0 is required, see [here](https://github.com/dom96/choosenim)). It will
build the most optimized executable possible, but AVX2/AVX512 support is expected on the target platform. Heimdall also requires
the clang compiler to be built, as executables generated by gcc are horrendously slow for some reason.

You can also run `make zen2` to build a modern version of Heimdall for slightly older CPUs that will run on more processors than just your exact one. For even slightly
older CPUs, and a more generic binary, try `make modern` instead. For (very) old CPUs without AVX2 support, run `make legacy`. In every case, the resulting executable
will be located at `bin/$(EXE)` (`bin/heimdall` by default).

Or you can grab the latest version from the [releases](https://git.nocturn9x.space/nocturn9x/heimdall/releases) page

**Note for Nim users**: Building via `nimble build` is no longer supported, as it required me to duplicate flags and functionality across two files. The Makefile
is the only supported build method!

### Advanced: Building with a custom network

**Note**: If you intend to use a network that has the same architecture as the one Heimdall ships with, you don't need to do this. Just
set the `EvalFile` UCI option to the path of the network file.


If you _do_ intend to embed a different neural network than the one heimdall defaults with, there are a bunch of things to change. You can see
that the Makefile defines the following options:
```Makefile
EVALFILE := ../networks/files/mistilteinn-v2.bin
# [...]
INPUT_BUCKETS := 16
OUTPUT_BUCKETS := 8
MERGED_KINGS := 1
EVAL_NORMALIZE_FACTOR := 259
HORIZONTAL_MIRRORING := 1
HL_SIZE := 1536
FT_SIZE := 704
```

These parameters fully describe Heimdall's network architecture (see [here](#evaluation) for details) and are what needs to change to allow
it to build with a different one. Specifically:
- `EVALFILE` is the path, relative to `src/`, where the network file is located (it will be embedded in the final executable)
- `INPUT_BUCKETS` and `OUTPUT_BUCKETS` are pretty self-explanatory (if you need me to explain, this section is not for you)
- `MERGED_KINGS` controls whether the network uses merged king planes (requires a bucket layout where no two kings can be in the same bucket).

  Note that this generally requires `FT_SIZE=704` unless you're using a custom feature transformer scheme (for which code modifications will be
  required)
- `EVAL_NORMALIZE_FACTOR`: The normalization factor as outputted by [this](https://github.com/official-stockfish/WDL_Model) program. Also make sure to modify the constants (`A_s` and `B_s`) in `src/heimdall/util/wdl.nim`
  
  Feel free to ask for help on how to do this. Not doing this will make Heimdall's normalized eval output completely unreliable, as it will be based
  on the parameters for a different network
- `HORIZONTAL_MIRRORING` enables supports for horizontal mirroring
- `HL_SIZE` controls the size of the first hidden layer
- `FT_SIZE` controls the size of the feature transformer (aka input layer)

The boolean options such as `HORIZONTAL_MIRRORING` and similar can be disabled by simply passing them to the make file like `HORIZONTAL_MIRRORING=`

You're also going to need to modify the input bucket layout in `src/heimdall/nnue/model.nim` (assumes a1=0). Be mindful of the horizontal symmetry if you're using a
horizontally mirrored network (look at how it's already done for Heimdall's network, it's not hard).

Then all you need to do is build the engine with `make <target> <variables>`. You're a smart guy (gal?), I'm sure you can figure it out. Do reach out if you have problems, though.

**Note**: Heimdall _requires_ perspective networks, where the first subnetwork is the side-to-move perspective and the second is the non-side-to-move

**Note 2**: Only single-(hidden-)layer networks are supported (for now)

## Testing

Just run `nimble test`: sit back, relax, get yourself a cup of coffee and wait for it to finish (it _will_ take a long time)


**Note**: The test suite requires Python and expects both heimdall and stockfish to be installed and in the system's PATH. Alternatively, it
is possible to specify the location of both Heimdall and Stockfish (run `python tests/suite.py -h` for more information)


## Configuration

Heimdall is a UCI engine, which means that it's not meant to be used as a standalone program (although you can do that, as it defaults
to a pretty-printed output unless the environment variable `NO_COLOR` is set or it detects that it's not attached to a TTY). To use it at
its best, you can add it to any number of chess GUIs like Arena, En Croissant or Cutechess. I strive to have Heimdall work flawlessly with
any GUI (within reason), so please let me know if you find any issues!


Heimdall supports the following UCI options:
- `HClear`: Clears all history tables. This is done automatically at every new game, so you shouldn't need to do this normally
- `TTClear`: Clears the transposition table. Like history clearing, this is done at every new game, so you shouldn't need this
- `Ponder`: Allows Heimdall to search while its opponent is also searching. A `go ponder` command will not start a ponder search unless this is set
- `ShowWDL`: Display the predicted win, draw and loss probability (see `NormalizeScore` below for more info). Not all GUIs support this, so only enable
  it if you know the one you're using does
- `UCI_Chess960`: Switches Heimdall to playing Fischer random chess (also known as chess960). Heimdall supports Double Fischer random chess as well
- `EvalFile`: Path to the neural network to use for evaluation. Its default value of `<default>` will cause Heimdall to use the network embedded in
  the executable. Do *not* set this to anything other than a valid path that the engine can access, or it _will_ crash (and no, empty strings don't work
  either!). Keep in mind that the network has to conform to the architecture of Heimdall's built-in one (check [here](#evaluation) for details)
- `NormalizeScore`: Enables score normalization. This means that displayed scores will be normalized such that +1.0 means a 50% probability
   of winning when there's around 58 points of material on the board (using the standard 1, 3, 3, 5, 9 weights for pawns, minor pieces,
   rooks and queens). Thanks to the stockfish folks who developed the [WDL model](https://github.com/official-stockfish/WDL_model)! This
   option is enabled by default
- `EnableWeirdTCs`: Allows Heimdall to play with untested/weird/outdaded time controls such as moves to go or sudden death: Heimdall will
   refuse to search with those unless this is set! See [here](#enableweirdtcs) for more details on why this exists
- `MultiPV`: The number of best moves to search for. The default value of one is best suited for strength, but you can set this to more
  if you want the engine to analyze different lines. Note that a time-limited search will share limits across all lines
- `Threads`: How many threads to allocate for search. By default Heimdall will only search with one thread
- `Hash`: The size of the hash table in mebibytes (aka REAL megabytes). The default is 64
- `MoveOverhead`: How much time (in milliseconds) Heimdall will subtract from its own remaining time to account for communication delays with an external
  program (usually a GUI or match manager). Particularly useful when playing games over a network (for example through a Lichess bot or on an internet chess
  server). This is set to 0 by default
- `Minimal`: Enables minimal logging, where only the final info line is printed instead of one for each depth searched

## Search

Heimdall implements negamax search with alpha-beta pruning in a PVS framework to search the game tree
and utilizes several heuristics to help it navigate the gigantic search space of chess

## Evaluation

Heimdall currently uses NNUE (Efficiently Updatable Neural Network) to evaluate positions. All of heimdall's networks
are trained with [bullet](https://github.com/jw1912/bullet) using data obtained from selfplay of previous versions,
while previous HCE releases used the lichess-big3 dataset for tuning. The current network architecture consists of a horizontally
mirrored perspective network using merged king planes, featuring a single hidden layer of 1536 neurons with 16 input buckets
and 8 output buckets, and is commonly represented as (704x16hm->1536)x2->1x8, for a total of ~18.53 million weights


## EnableWeirdTCs

Heimdall is designed (and tested) to play at the standard time controls of time + increment: since I do not have the hardware nor
the time to test others (like sudden death or moves to go), support for outdated/nonstandard time controls has been hidden behind
the `EnableWeirdTCs` option. Unless this option is set, Heimdall will refuse to play either if its own increment is missing/zero
or if it is told to play with a moves to go time control (this one is especially important because it is not taken into account at
all in time management!): this technically means Heimdall is not fully UCI compliant unless `EnableWeirdTCs` is enabled, but I believe this
trade-off is worth it, as it means that if it does indeed perform worse at untested time controls then the tester will have full knowledge
as to why that is. If that upsets you or makes you want to not test Heimdall, that's fine! I'm sorry you feel that way, but this is my engine
after all :)


## More info

Heimdall is sometimes available on [Lichess](https://lichess.org/@/Nimfish) under its old name (Nimfish), feel free to challenge it!
I try to keep the engine running on there always up to date with the changes on the master branch. The hardware running it is quite
heterogenous however, so expect big rating swings

## Strength

Lots of people are kind enough to test Heimdall on their own hardware. Here's a summary of the rating lists I'm aware of (please contact
me if you want me to add yours)


| Version   | Estimated | TCEC  | CCRL 40/15 (1CPU) | CCRL FRC 40/2 | CCRL Blitz 2+1 (1CPU) | CCRL 40/15 (4CPU) | MCERL | CEGT 40/20 | CEGT 5'+3'' | CEGT 40/4 |
| --------- | --------- | ----- | ----------------- | ------------- | --------------------- | ----------------- | ----- | ---------- | ----------- | --------- |
| 0.1       | 2531      | -     | 2436              | N/A           | -                     | -                 | -     | -          | -           | -         |
| 0.2       | 2706      | -     | 2669              | N/A           | -                     | -                 | -     | -          | -           | -         |
| 0.3       | 2837      | -     | -                 | N/A           | -                     | -                 | -     | -          | -           | -         |
| 0.4       | 2888      | -     | 2863              | 2926          | -                     | -                 | -     | -          | -           | -         |
| 1.0       | 3230      | 3163* | 3192              | 3372          | -                     | -                 | -     | -          | -           | -         |
| 1.1       | 3370      | -     | -                 | -             | -                     | -                 | -     | -          | -           | -         |
| 1.1.1     | 3390**    | -     | 3362              | 3557          | 3393                  | -                 | 3456  | -          | 3283        | 3266      |
| 1.2       | 3490      | -     | -                 | -             | -                     | -                 | 3470  | -          | -           | -         |
| 1.2.{1,2} | 3500      | -     | 3378              | 3621          | 3476                  | 3441              | 3479  | 3297       | -           |           |
| 1.3       | 3548***   | -     | 3431              | -             | 3512                  | -                 | -     | 3342       | -           | 3373      |

*: Beta version, not final 1.0 release

**: Estimated at LTC (1CPU, 40+0.4s, 128MB hash) against Stash v36 (-0.2 +- 11.1)

***: Check 1.3's release notes for info about how this was calculated


__Note__: Unless otherwise specified, estimated strenght is measured for standard chess at a short time control (8 seconds with 0.08 seconds increment)
with 1 search thread and a 16MB hash table over 1000 or 2000 game pairs against the previous version (except for version 0.1 where it was tested in a gauntlet)
using the Pohl opening book (up to version 1.0) and the UHO_Lichess_4852_v1 book for later versions, and is therefore not as accurate as the other ratings
which are provided by testers running the engine at longer TCs against a pool of different opponents.

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
- @cj5716, @affinelytyped: Provided lots of ideas to steal and helped with debugging
- @jw1912: For creating bullet (it's awesome, use it) and helping with debugging twofold LMR (+140 Elo!)
- @agethereal (aka Andy Grant) for helping with debugging and creating the amazing piece of software that is [OpenBench](https://gitbub.com/AndyGrant/OpenBench)

Y'all are awesome! <3


**P.S.** I probably forgot someone, please let me know should that be the case!
