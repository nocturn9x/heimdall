![Heimdall](Heimdall_logo_v2.png "Heimdall")

# heimdall

Heimdall is a superhuman chess engine written in Nim. As far as I know, this is the strongest Nim engine that has ever been tested (please
let me know should that not be the case), sitting around the top 60 rank globally.


##### Logo by @kan, thank you!

## Building and Installation


Just run `make`, this is the easiest (Nim 2.0.4 is required, see [here](https://github.com/dom96/choosenim)). It will
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

Just run `nimble test`: sit back, relax, get yourself a cup of coffee and wait for it to finish (it WILL take a long time :))


**Note**: The test suite requires Python and expects both heimdall and stockfish to be installed and in the system's PATH. Alternatively, it
is possible to specify the location of both Heimdall and Stockfish (run `python tests/suite.py -h` for more information)


## Configuration

Heimdall is a UCI engine, which means that it's not meant to be used as a stand-alone program (although you can do that, as it defaults
to a pretty-printed output unless the environment variable `NO_COLOR` is set or it detects that it's not attached to a TTY). To use it at
its best, you can add it to any number of chess GUIs like Arena, En Croissant or Cutechess. I strive to have Heimdall work flawlessly with
any GUI, so please let me know if you find any issues!


Heimdall supports the following UCI options:
- `HClear`: Clears all history tables. This is done automatically at every new game, so you shouldn't need to do this normally
- `TTClear`: Clears the transposition table. Like history clearing, this is done at every new game, so you shouldn't need this
- `Ponder`: Allows Heimdall to search while its opponent is also searching. A `go ponder` command will not start a ponder search unless this is set!
- `ShowWDL`: Display the predicted win, draw and loss probability (see `NormalizeScore` below for more info). Not all GUIs support this, so only enable
  it if you know the one you're using does!
- `UCI_Chess960`: Switches Heimdall to playing Fischer random chess (also known as chess960). Heimdall supports Double Fischer random chess as well!
- `EvalFile`: Path to the neural network to use for evaluation. Its default value of `<default>` will cause Heimdall to use the network embedded in
  the executable. Do *not* set this to anything other than a valid path that the engine can access, or it _will_ crash (and no, empty strings don't work
  either!). Keep in mind that the network has to be of the same size and architecture as Heimdall's own (check [here](#evaluation) for details)
- `NormalizeScore`: Enables score normalization. This means that displayed scores will be normalized such that +1.0 means a 50% probability
   of winning when there's around 58 points of material on the board (using the standard 1, 3, 3, 5, 9 weights for pawns, minor pieces,
   rooks and queens). Thanks to the stockfish folks who developed the [WDL model](https://github.com/official-stockfish/WDL_model)! This
   option is enabled by default
- `EnableWeirdTCs`: Allows Heimdall to play with untested/weird/outdaded time controls such as moves to go or sudden death: Heimdall will
   refuse to search with those unless this is set! See [here](#️notes-for-engine-testers) for more details on why this exists
- `MultiPV`: The number of best moves to search for. The default value of one is best suited for strength, but you can set this to more
  if you want the engine to analyze different lines. Note that a time-limited search will share limits across all lines!
- `Threads`: How many threads to allocate for search. By default Heimdall will only search with one thread
- `Hash`: The size of the hash table in mebibytes (aka REAL megabytes). The default is 64
- `MoveOverhead`: How much time (in milliseconds) Heimdall will subtract from its own remaining time to account for communication delays with an external
  program (usually a GUI or match manager). Particularly useful when playing games over a network (for example through a Lichess bot or on an internet chess
  server). This is set to 0 by default


## Search

Heimdall implements negamax search with alpha-beta pruning in a PVS framework to search the game tree
and utilizes several heuristics to help it navigate the gigantic search space of chess

## Evaluation

Heimdall currently uses NNUE (Efficiently Updatable Neural Network) to evaluate positions. All of heimdall's networks
are trained with [bullet](https://github.com/jw1912/bullet) using data obtained from selfplay of previous versions,
while previous HCE releases used the lichess-big3 dataset for tuning. The current network architecture is a horizontally
mirrored perspective network with a single hidden layer of 1280 neurons, with 16 input buckets and 8 output buckets, commonly
represented as (768x16->1280)x2->1x8


## Notes for engine testers

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
me if you want me to add yours!)


| Version   | Estimated   | CCRL 40/15 (1CPU) | TCEC  | CCRL FRC 40/2 | CCRL Blitz 2+1 (1CPU) | MCERL | CEGT 40/20 | CCRL 40/15 (4CPU)
| --------- | ----------- | ----------------- | ----  | ------------- | --------------------- | ----- | ---------- | -----------------
| 0.1       | 2531        | 2436              | -     | N/A           | -                     | -     | -          | -
| 0.2       | 2706        | 2669              | -     | N/A           | -                     | -     | -          | -
| 0.3       | 2837        | -                 | -     | N/A           | -                     | -     | -          | -
| 0.4       | 2888        | 2865              | -     | 2926          | -                     | -     | -          | -
| 1.0       | 3230        | 3194              | 3163* | 3372          | -                     | -     | -          | -
| 1.1       | 3370        | -                 | -     | -             | -                     | -     | -          | -
| 1.1.1     | 3390**      | 3363              | -     | 3556          | 3393                  | 3440  | 3284       | -
| 1.2       | 3490        | -                 | -     | -             | -                     | 3470  | -          | -
| 1.2.{1,2} | 3500        | 3374              | -     | 3621          | 3474                  | 3479  | 3297       | 3436


*: Beta version, not final 1.0 release

**: Estimated at LTC (1CPU, 40+0.4s, 128MB hash) against Stash v36 (-0.2 +- 11.1)

__Note__: Unless otherwise specified, estimated strenght is measured for standard chess at a short time control (8 seconds with 0.08 seconds increment)
with 1 search thread and a 16MB hash table over 1000 game pairs against the previous version (except for version 0.1 where it was tested in a gauntlet)
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
- @cj5716: Provided lots of ideas to steal
- @jw1912: For creating bullet and helping with debugging twofold LMR (+140 Elo!)

Y'all are awesome! <3


**P.S.** I probably forgot someone, please let me know should that be the case!
