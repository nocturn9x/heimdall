![Heimdall](Heimdall_logo_v2.png "Heimdall")

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/nocturn9x/heimdall)

# heimdall

Heimdall is a strong chess engine written in Nim. As far as I know, this is the strongest Nim engine that has ever been tested (please
let me know should that not be the case), sitting around the top 50 rank globally.


##### Logo by @kan, thank you!

## Building and Installation

**Note**: Do **not** run a bare `make` command! The default target is meant to be used by [OpenBench](https://gitbub.com/AndyGrant/OpenBench) only.

**Note 2**: To build from source, there's also a useful AI-generated guide you can find [here](https://deepwiki.com/nocturn9x/heimdall/2.1-building-from-source)


### Requirements
- The Nim compiler (2.2.6). See [here](https://codeberg.org/janAkali/grabnim) for more details
- The clang compiler (any reasonably modern version will do)
- The lld linker script (LLVM linker driver). This isn't installed on all systems even when clang is, so make sure it's there!
Running `make native` is the simplest option: it will build the most optimized executable possible, but your CPU needs to support at least AVX2 (AVX512 VNNI or AVX512 are used if available).

To produce a more generic binary that is still modern, run `make zen2`: the resulting executable will be able to run on more than just your specific processor family.

For older CPUs, and a much more generic binary, try `make modern`; For (very) old CPUs without AVX2 support, run `make legacy` instead.

There are also explicit `vnni` and `avx512` targets that can be built, though if your processor supports either AVX512 VNNI or AVX512 `make native` will catch that and use it for the build.

In every case, the resulting executable will be located at `bin/$(EXE)` (`bin/heimdall` by default).

You can also grab the latest stable version from the [releases](https://git.nocturn9x.space/nocturn9x/heimdall/releases) page, see [here](#how-to-pick-the-right-executable) for more details.

**Note for Nim users**: Building via `nimble build` is no longer supported, as it required me to duplicate flags and functionality across two files. The Makefile
is the only supported build method!

### How to pick the right executable

**Note**: This only applies to versions 1.3 or higher

In hopes of providing the best experience to as many users as possible, I target several machine types when building release binaries.

Targets from best to worst (speed-wise):
- `vnni`: Requires AVX512 VNNI support. Pick this over `avx512` only if your CPU explicitly supports AVX512 VNNI
- `avx512`: Requires a very modern processor with AVX512 support. The speed difference is generally measurable only the newest Ryzen 9000 series of processors (and contemporary Intel chips)
- `zen2`: Tuned for Zen 2 CPUs (later ones work too)
- `haswell`: Tuned for Haswell-era CPUs with AVX2 support. Most modern CPUs should be able to run this
- `core2`: Tuned for very old CPUs without AVX2 support. _Significantly_ slower than all of the above

All of the targets require a 64 bit processor: Heimdall does not (and will never) support 32 bit systems

## Testing

Just run `make test-suite`: sit back, relax, get yourself a cup of coffee and wait for it to finish (it _will_ take a long time)


**Note**: The test suite requires Python (stdlib only) and expects stockfish to be installed and in the system's PATH. Alternatively, it
is possible to specify the location of both Heimdall and Stockfish (run `python tests/suite.py -h` for more information)


## Configuration

Heimdall implements the [UCI](https://en.wikipedia.org/wiki/Universal_Chess_Interface) protocol to communicate with chess GUIs and other programs.
To use it at its best, you can add it to any number of chess GUIs like Arena, En Croissant or Cutechess. I strive to have Heimdall work flawlessly with
any GUI (within reason), so please let me know if you find any issues!

If you prefer to use it from the command line, there is a fairly advanced user interface supporting colored output, command history, line editing
and much more, powered by [nim-noise](https://github.com/jangko/nim-noise) (for all keyboard bindings see [here](https://github.com/jangko/nim-noise?tab=readme-ov-file#key-binding))


Heimdall supports the following UCI options:
- `HClear`: Clears all history tables. This is done automatically at every new game, so you shouldn't need to do this normally
- `TTClear`: Clears the transposition table. Like history clearing, this is done at every new game, so you shouldn't need this
- `Ponder`: Allows Heimdall to search while its opponent is also searching. A `go ponder` command will not start a ponder search unless this is set
- `UCI_ShowWDL`: Display the predicted win, draw and loss probability (see `NormalizeScore` below for more info). Not all GUIs support this, so only enable
  it if you know the one you're using does
- `UCI_Chess960`: Switches Heimdall to playing Fischer random chess (also known as chess960). Heimdall supports Double Fischer random chess as well
- `NormalizeScore`: Enables score normalization. This means that displayed scores will be normalized such that +1.0 means a 50% probability
   of winning against an equally strong opponent when there's around 58 points of material on the board (using the standard 1, 3, 3, 5, 9 weights
   for pawns, minor pieces, rooks and queens). Thanks to the stockfish folks who developed the [WDL model](https://github.com/official-stockfish/WDL_model)! This
   option is enabled by default
- `EnableWeirdTCs`: Allows Heimdall to play with untested/weird/outdaded time controls such as moves to go or sudden death: Heimdall will
   refuse to search with those unless this is set! See [here](#enableweirdtcs) for more details on why this exists
- `MultiPV`: The number of best moves to search for. The default value of one is best suited for strength, but you can set this to more
  if you want the engine to analyze different lines. Note that a time-limited search will share limits across all lines
- `Threads`: How many threads to allocate for search. By default Heimdall will only search with one thread
- `Hash`: The size of the hash table in mebibytes (aka REAL megabytes). The default is 64
- `MoveOverhead`: How much time (in milliseconds) Heimdall will subtract from its own remaining time to account for communication delays with an external
  program (usually a GUI or match manager). Particularly useful when playing games over a network (for example through a Lichess bot or on an internet chess
  server). This is set to 250 by default
- `Minimal`: Enables minimal logging, where only the final info line is printed instead of one for each depth searched
- `Contempt`: A static, side-to-move relative offset added to the static evaluation. Defaults to 0. The higher this is, the less willing Heimdall will be to draw

### Notes on command-line usage

For the fancy terminal interface, see [here](#built-in-tui)

To make command-line usage more friendly to us fleshy things, Heimdall implements a so-called "mixed mode": if it detects that it's connected to a TTY (a terminal)
it will start up a user interface that supports both UCI commands (with some slight tweaks) and a set of custom commands (type `help` for more info). The following
environment variables control the behavior of mixed mode:
- `NO_COLOR`: If set, colored output will be disabled
- `NO_TUI`  : If set, the engine will start up in UCI mode right away (no colored output)
- `NO_LOGO` : If set, heimdall's logo will not be printed on startup

Once `uci` is sent, Heimdall will switch to UCI mode: colored output will be turned off and mixed mode will be disabled; You can type `icu` to head back to mixed mode.

The mixed mode interface can be exited from by pressing either Ctrl+C, Ctrl+D (these also work for UCI) or Esc and then confirming when prompted (mixed mode only)


### Built-in TUI

Thanks to the power of AI (Claude Opus 4.6 and GPT 5.4, to be specific), Heimdall now features an advanced text user interface to perform game analysis and playing against
the engine, right from the terminal. It uses [Kitty](http://github.com/kovidgoyal/kitty/)'s graphics protocol to render a pretty chessboard to the screen, so this will only
work on terminal emulators that implement it (just use kitty, it's great). Once you launch it, type `:help` to learn how to use it!

The built-in TUI is currently supported on Linux only.

Many thanks to whoever runs [this](https://sashite.dev/assets/chess/) website: the chess assets are beautiful! <3

P.S.: This part of heimdall does not respect `NO_COLOR` (sorry!)

Known supported terminals:
- Kitty (perfect, recommended)
- Ghostty (perfect)
- WezTerm (near perfect)
- Konsole (decent)

Any other terminals are 99.99% likely NOT to work. Do report any issues, if they're easily fixable I'll merge a fix.

Note that Konsole has the following known issues:
- Mouse movement is jittery. This is unfixable: Konsole does not support reporting mouse movements in terms of pixels, just terminal cells.
  This means the mouse always snaps to the center of the closest cell, there is nothing I can do about that
- The image assets look a bit rough and artifact-y. Not sure if this is fixable

Here follows a brief usage guide for the TUI generated by Claude

#### Getting Started

Launch the TUI with `heimdall tui`. You'll see a chessboard on the left and an info panel on the right. Type `:help` to see all commands.

#### Making Moves

There are five ways to input moves:
- **Mouse click**: Click a piece to select it (legal moves are highlighted), then click the destination
- **Drag and drop**: Drag a piece to a legal destination square
- **UCI notation**: Type `e2e4` and press Enter
- **SAN notation**: Type `Nf3`, `O-O`, `e8=Q`, etc.
- **Square selection**: Type `e2` to select the piece, then `e4` to move it

#### General usage notes

- Promotions default to queen. Press `Shift+Q` to toggle auto-queen off; you'll then be prompted to choose Q/R/B/N when a pawn promotes.
- Right-click a square to toggle a square highlight. Right-drag on the board to draw a user arrow; drawing the same arrow again removes it, while right-drag with
  `Shift`/`Ctrl` draws red arrows, `Alt` draws blue arrows, and both modifier groups together draw yellow arrows (much like Lichess/Chess.com).
- User arrows and square highlights are stored per position, so when you navigate through a PGN and come back to a move your annotations are restored.
- The command line supports basic cursor movement and editing: use Left/Right to move one character, `Ctrl+A` to jump to the beginning and `Ctrl+E` to jump to the end.
- The board size scales down automatically to fit smaller terminals. If the window drops below the supported minimum size, the TUI shows a resize warning.
- Global keyboard shortcuts only fire when the input buffer is empty, so text input and pasted commands keep their literal characters.

#### Analysis

- `:go` starts/stops continuous engine analysis on the current position
- `:set multipv 3` shows multiple analysis lines (sorted by strength, with WDL probabilities)
- Press `Shift+M` to set a mate-finder limit in moves for analysis. Enter `none` to clear it. If analysis is already running, Heimdall restarts the search with the new mate target.
- `:arrows` toggles best-move arrows on the board. With MultiPV enabled, Heimdall shows the top move as the main arrow and additional candidate moves as lighter secondary arrows.
- `:stop` halts the current search
- Left/Right arrow keys undo/redo moves; the engine restarts analysis on each position change
- Press `Shift+S` to enter board setup mode: In board setup mode you can drag pieces freely between squares. Dropping a piece off the board deletes it.
  Type `p/n/b/r/q/k` to arm spawning a black piece; use `Shift+<key>` to arm the white version. Press `w`/`x` to toggle white queen-side/king-side castling
  rights. Press `y`/`z` to toggle black queen-side/king-side castling rights. Press `Esc` to validate the edited position and exit back to analysis. Invalid
  setups are rejected gracefully and keep you in board setup mode so you can fix them.

#### Playing Against the Engine

- `:play` starts a game setup wizard: choose variant, side, your clock (`5m+3s`, `10m`, `1h`, `none`), then the engine limits. Engine limits can be combined with commas, for example `5m+3s, depth 20`, `depth 20, nodes 200000`, or `same`.
- `:resign` forfeits the game, `:takeback` (or `:tb`) undoes your last move (if enabled)
- `:exit` leaves play mode
- `:rematch` begins a new game with the same settings as the just-finished one. If you picked randomized sides to move, a new one is picked.
- `softnodes N` uses a soft per-move node target; the setup wizard then asks whether to also set a hard cap. If you do, the hard cap must be at least `N`. This also works when `softnodes` is combined with other limits such as `5m+3s, depth 20, softnodes 100000`.
- While the engine is thinking, you can queue premoves by dragging one of your pieces, by square selection (`e2` then `e4`), or by typing a UCI move such as `e2e4`. Premoves resolve in queue order, with the first several highlighted using different colors on the board and the palette cycling after that. If the next premove becomes illegal after an engine move, the remaining queued premoves are cleared. Click a highlighted premove square to remove the most recently queued premove that touches that square.
- `:watch` is the engine-vs-engine equivalent of `:play` and configures Heimdall to play against itself.

#### PGN Support

- `:load game.pgn` loads a PGN for replay. If the file contains multiple games, specify which one: `:load game.pgn 3`
- Navigate with Left/Right arrows, Home/End to jump to start/end
- Press `Shift+L` or run `:analyse` / `:analyze` to request a full computer analysis of the loaded game. Heimdall asks for a per-position limit (`500ms`, `1s`, `depth 20`, `nodes 200000`, `mate 6`, etc.) and whether to analyze from the end or the beginning of the game. Reverse analysis is the default.
- `:stop` cancels a running computer analysis and keeps the positions analyzed so far.
- Once a report exists, Heimdall shows a `Computer Analysis` pane with per-side ACPL and accuracy plus move-specific details such as centipawn loss, best move and judgment.
- The move list is annotated with Lichess-style mistake markers during replay analysis, using color to distinguish inaccuracies, mistakes and blunders.
- A live graph is rendered below the board and follows the current move as you scroll through the PGN. It includes opening/midgame/endgame divider markers and a scale derived from the
  extrema encountered during the analysis run.
- Press `Shift+W` or use `:wdl` to toggle the graph between eval and WDL views
- Press `Shift+H` to hide/show the replay analysis graph without discarding the report
- `:pgn output.pgn` exports the current move history as a PGN file with metadata

#### Chess960 / DFRC

- `:frc 518` loads a Chess960 position by Scharnagl number (0-959)
- `:dfrc 123 456` loads a Double Fischer Random position
- `:chess960 on/off` toggles Chess960 mode manually

#### Engine Settings

`:set <option> <value>` configures the engine. Autocomplete is available (type `:set ` and use Tab/arrows). Options include:
`hash`, `threads`, `multipv`, `depth`, `contempt`, `moveoverhead`, `ponder`, `normalizescore`, `chess960`

Hash accepts human-readable sizes: `:set hash 1 GB`, `:set hash 256 MiB`, or bare numbers (interpreted as MiB).

`:set normalizescore on/off` controls score normalization for live analysis, cached analysis lines, game-analysis reports, and the replay graph.

`:clear` resets all engine state (transposition table, move ordering histories).

#### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `Shift+A` | Toggle best-move arrows |
| `Shift+F` | Flip board |
| `Shift+H` | Hide/show the replay analysis graph |
| `Shift+L` | Request computer analysis for the loaded PGN |
| `Shift+M` | Set mate-finder limit (analysis only) |
| `Shift+Q` | Toggle auto-queen promotion |
| `Shift+S` | Enter board setup mode (analysis only) |
| `Shift+W` | Toggle the replay report graph between eval and WDL |
| `w` / `x` | In board setup, toggle white queen-side / king-side castling |
| `y` / `z` | In board setup, toggle black queen-side / king-side castling |
| Left/Right | Undo/redo moves |
| Home/End | Go to first/last position |
| `Ctrl+A` / `Ctrl+E` | Move to the start / end of the input line |
| Ctrl+C | Quit immediately |
| Ctrl+D (x2) | Quit with confirmation |
| ESC | Cancel current action |
| Tab | Accept autocomplete suggestion |

#### Other Commands

- `:fen` copies the current FEN to clipboard; `:fen <fen>` loads a position
- `:reset` resets to the starting position
- `:flip` flips the board view
- `:arrows` toggles engine move arrows (primary line plus lighter MultiPV arrows)
- `:threats` toggles threat square highlighting

## Search

Heimdall implements [negamax](https://en.wikipedia.org/wiki/Negamax) search with [alpha-beta pruning](https://en.wikipedia.org/wiki/Alpha%E2%80%93beta_pruning) in a [PVS](https://en.wikipedia.org/wiki/Principal_variation_search) framework to search the game tree
and utilizes dozens of heuristics to help it navigate the gigantic search space of chess

## Evaluation

This branch uses the fixed hand-crafted evaluation from ancient Heimdall/HCE releases instead of NNUE. It includes the historical tapered
piece-square/material weights, mobility, king-zone safety, safe checks, pawn structure, rook file bonuses, bishop pair, strong pawns,
threats, and tempo terms, but not the old tuning support.


## EnableWeirdTCs

Heimdall is designed (and tested) to play at the standard time controls of time + increment: since I do not have the hardware nor
the time to test others (like sudden death or moves to go), support for outdated/nonstandard time controls has been hidden behind
the `EnableWeirdTCs` option. Unless this option is set, Heimdall will refuse to play either if its own increment is missing/zero
or if it is told to play with a cyclic time control, aka "moves to go" (this one is especially important because it is not taken
into account at all in time management!): this technically means Heimdall is not fully UCI compliant unless `EnableWeirdTCs` is
enabled, but I believe this trade-off is worth it, as it means that if it does indeed perform worse at untested time controls then
the tester will have full knowledge as to why that is. If that upsets you or makes you want to not test Heimdall, that's fine! I'm
sorry you feel that way, but this is my engine after all :)


## More info

Heimdall is sometimes available on [Lichess](https://lichess.org/@/Nimfish) under its old name (Nimfish), feel free to challenge it!
I try to keep the engine running on there always up to date with the changes on the master branch. The hardware running it is quite
heterogenous however, so expect big rating swings

## Strength

Lots of people are kind enough to test Heimdall on their own hardware. Here's a summary of the rating lists I'm aware of (please contact
me if you want me to add yours)


| Version   | Estimated | TCEC     | CCRL 40/15 1CPU | CCRL 40/15 4CPU | CCRL Chess324 1CPU | CCRL FRC 40/2 | CCRL DFRC 40/2 | CCRL Blitz 2+1 1CPU | CCRL Blitz 2+1 8CPU | MCERL | CEGT 40/20 | CEGT 5'+3'' | CEGT 40/4 |
| --------- | --------- | -------- | --------------- | --------------- | ------------------ | ------------- | -------------- | ------------------- | ------------------- | ----- | ---------- | ----------- | --------- |
| 0.1       | 2531      | -        | 2436            | -               | -                  | N/A           | N/A            | -                   | -                   | -     | -          | -           | -         |
| 0.2       | 2706      | -        | 2669            | -               | -                  | N/A           | N/A            | -                   | -                   | -     | -          | -           | -         |
| 0.3       | 2837      | -        | -               | -               | -                  | N/A           | N/A            | -                   | -                   | -     | -          | -           | -         |
| 0.4       | 2888      | -        | 2859            | -               | -                  | 2929          | -              | -                   | -                   | -     | -          | -           | -         |
| 1.0       | 3230      | 3163*    | 3192            | -               | -                  | 3376          | -              | -                   | -                   | -     | -          | -           | -         |
| 1.1       | 3370      | -        | -               | -               | -                  | -             | -              | -                   | -                   | -     | -          | -           | -         |
| 1.1.1     | 3390**    | -        | 3360            | -               | -                  | 3564          | -              | 3383                | -                   | 3440  | -          | 3286        | 3268      |
| 1.2       | 3490      | -        | -               | -               | -                  | -             | -              | -                   | -                   | 3470  | -          | -           | -         |
| 1.2.{1,2} | 3500      | -        | 3376            | 3439            | -                  | 3627          | -              | 3467                | -                   | 3479  | 3301       | -           |           |
| 1.3       | 3548***   | -        | 3419            | -               | -                  | -             | -              | 3510                | -                   | -     | 3337       | -           | 3373      |
| 1.3.{1,2} | 3530      | 3307**** | 3423            | -               | -                  | 3721          | -              | -                   | 3578                | -     | -          | 3404        | -         |
| 1.4       | 3626      | -        | 3494            | 3550            | -                  | 3823          | 3481\*\*\*\*\* | -                   | -                   | -     | 3443       | -           | -         |
| 1.4.1     | 3659      | -        | 3514            | -               | -                  | -             | -              | 3615                | -                   | -     | 3459       | -           | -         |
| 1.4.2     | 3660      | -        | 3503            | 3562            | 3542               | 3851          | -              | -                   | -                   | -     | -          | -           | -         |

*: Beta version, not final 1.0 release

**: Estimated at LTC (1CPU, 40+0.4s, 128MB hash) against Stash v36 (-0.2 +- 11.1)

***: Check 1.3's release notes for info about how this was calculated

\*\*\*\*: Version 1.4.0-beta-b89cb959 (+/- 50)

\*\*\*\*\*: Version 1.4.0-beta-301171


**Note**: Ratings of late versions are likely to fluctuate a lot as the number of games on the relevant list increases. They do eventually stabilize.


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
- @ciekce: for helping me debug countless issues. Also helping me on morelayers and with general net stuff. Cool cat indeed
- @sroelants: provided debugging help and lots of good ideas to steal
- @tsoj: Saved my ass by solving some major performance bottlenecks and helping me debug my broken threading code
- @viren, @zuppadcipolle, @toanth, @fuuryy: Debugging help
- @DarkNeutrino, @yoshie2000, @87flowers, @kazapps_08388, @swedishchef: for lending cores to my OB instance
- @Quinniboi10, @ksw0518: For joining [MattBench](https://chess.n9x.co) (best OB instance ever FYI). Y'all are the OGs
- All other Mattbench members <3
- @ceorwmt: for helping with datagen
- @cj5716, @affinelytyped: Provided lots of ideas to steal and helped with debugging
- @jw1912: For creating bullet (it's awesome, use it) and helping with debugging twofold LMR (+140 Elo!)
- @__arandomnoob: For debugging a critical bug in my alpha-beta pruning worth over 100 STC Elo. Very cool, very dangerous. Beware of HCE
- @agethereal (aka Andy Grant) for helping with debugging and creating the amazing piece of software that is [OpenBench](https://gitbub.com/AndyGrant/OpenBench)

Y'all are awesome! <3


**P.S.** I probably forgot someone, please let me know should that be the case!


**P.P.S**: If you read this far, congrats! Here's a free easter egg (there's more :)): set the environment variable `FUNNY_ESC` before starting
heimdall and press Esc :>
