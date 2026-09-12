<!--
Copyright 2026 Mattia Giambirtone & All Contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

![Heimdall](Heimdall_logo_v2.png "Heimdall")

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/nocturn9x/heimdall)

# heimdall

Heimdall is a strong chess engine written in Nim. As far as I know, this is the strongest Nim engine that has ever been tested, sitting around the top 40 rank globally.

##### Logo by @kan, thank you!

## Building and Installation

### How to pick the right executable

Fetching the latest stable release is the easiest way to install Heimdall. For
versions after **1.5**, choose the archive for your operating system and CPU
family. The universal binaries select the supported SIMD backend automatically.

| Your computer | Executable filename ends with |
| --- | --- |
| Windows on Intel or AMD | `windows-amd64-universal.exe` |
| Linux on Intel or AMD | `linux-amd64-universal` |
| Linux on ARM64 / AArch64 | `linux-arm64-universal` |
| macOS on Intel or Apple Silicon | `macos-universal` |

Download the matching `.zip` (Windows) or `.tar.gz` (Linux/macOS) archive from
the [latest release](https://git.nocturn9x.space/nocturn9x/heimdall/releases),
extract it, and select the executable in your chess GUI. All builds require a
64-bit system; the macOS build requires macOS 11 or later.

For source builds, platform-specific binaries, testing, and release details,
see the [building guide](docs/BUILDING.md). The [testing guide](docs/TESTING.md)
covers regression tests, focused correctness checks, and benchmarks.

## Documentation

- [Building and installation](docs/BUILDING.md)
- [Testing and benchmarks](docs/TESTING.md)
- [UCI and command-line usage](docs/UCI.md)
- [Built-in terminal UI](docs/TUI.md)
- [SIMD builds](docs/SIMD.md)
- [Release workflow](docs/RELEASES.md)

## Search

Heimdall implements [negamax](https://en.wikipedia.org/wiki/Negamax) search with [alpha-beta pruning](https://en.wikipedia.org/wiki/Alpha%E2%80%93beta_pruning) in a [PVS](https://en.wikipedia.org/wiki/Principal_variation_search) framework to search the game tree and utilizes dozens of heuristics to help it navigate the gigantic search space of chess.

## Evaluation

Heimdall currently uses [NNUE](https://en.wikipedia.org/wiki/Efficiently_updatable_neural_network) (Efficiently Updatable Neural Network) to evaluate positions. All of Heimdall's networks are trained with [bullet](https://github.com/jw1912/bullet) using data obtained from selfplay of previous versions, while previous HCE releases used the lichess-big3 dataset for tuning. The current network architecture consists of a threat-input, horizontally mirrored perspective network (with pairwise reduction) featuring a first layer of 512 neurons with 16 input buckets and two middle layers of 16 (dual-activated) and 32 neurons respectively (with 8 output buckets), which is commonly represented as `(768x16hm+60144hm->512)x2-pw->(16x2->32->1)x8`.

Network files must also match the feature indexing, king bucket table, and bias quantization used by the engine. Heimdall adds L1 biases before the requantization shift, while some networks store biases intended to be added after it. For those networks, set the Makefile's `L1_BIAS_SHIFT` to the number of requantization bits (8 with the current architecture) to rescale the biases during loading. Otherwise, the file can load successfully but produce incorrect evaluations. The default `L1_BIAS_SHIFT=0` preserves Heimdall's native bias format.

## EnableWeirdTCs

Heimdall is designed and tested to play at standard time controls of time plus increment. Since I do not have the hardware or time to test others, support for outdated or nonstandard time controls is hidden behind the `EnableWeirdTCs` option. Unless this option is set, Heimdall refuses to play if its increment is missing or zero, or if it is told to play with a cyclic time control such as moves to go. Moves to go are especially important because they are not taken into account in time management.

## Strength

Lots of people are kind enough to test Heimdall on their own hardware. Here's a summary of the rating lists I'm aware of (please contact me if you want me to add yours).

| Version   | Estimated | TCEC     | CCRL 40/15 1CPU | CCRL 40/15 4CPU | CCRL Chess324 1CPU | CCRL FRC 40/2 | CCRL Blitz 2+1 1CPU | CCRL Blitz 2+1 8CPU | CEGT 40/20 | CEGT 5'+3'' | CEGT 40/4 |
| --------- | --------- | -------- | --------------- | --------------- | ------------------ | ------------- | ------------------- | ------------------- | ---------- | ----------- | --------- |
| 0.1       | 2531      | -        | 2436            | -               | -                  | N/A           | -                   | -                   | -          | -           | -         |
| 0.2       | 2706      | -        | 2669            | -               | -                  | N/A           | -                   | -                   | -          | -           | -         |
| 0.3       | 2837      | -        | -               | -               | -                  | N/A           | -                   | -                   | -          | -           | -         |
| 0.4       | 2888      | -        | 2859            | -               | -                  | 2929          | -                   | -                   | -          | -           | -         |
| 1.0       | 3230      | 3163*    | 3192            | -               | -                  | 3376          | -                   | -                   | -          | -           | -         |
| 1.1       | 3370      | -        | -               | -               | -                  | -             | -                   | -                   | -          | -           | -         |
| 1.1.1     | 3390**    | -        | 3360            | -               | -                  | 3564          | 3383                | -                   | -          | 3286        | 3268      |
| 1.2       | 3490      | -        | -               | -               | -                  | -             | -                   | -                   | -          | -           | -         |
| 1.2.{1,2} | 3500      | -        | 3376            | 3439            | -                  | 3627          | 3467                | -                   | 3301       | -           |           |
| 1.3       | 3548***   | -        | 3419            | -               | -                  | -             | 3510                | -                   | 3337       | -           | 3373      |
| 1.3.{1,2} | 3530      | 3307**** | 3423            | -               | -                  | 3721          | -                   | 3578                | -          | 3404        | -         |
| 1.4       | 3626      | -        | 3494            | 3550            | -                  | 3823          | -                   | -                   | 3443       | -           | -         |
| 1.4.1     | 3659      | -        | 3514            | -               | -                  | -             | 3615                | -                   | 3459       | -           | -         |
| 1.4.2     | 3660      | -        | 3503            | 3562            | 3542               | 3851          | -                   | -                   | -          | -           | -         |
| 1.5.0     | 3750      | -        | 3554            | 3586            | -                  | 3911          | -                   | -                   | -          | -           | -         |

*: Beta version, not final 1.0 release

**: Estimated at LTC (1CPU, 40+0.4s, 128MB hash) against Stash v36 (-0.2 +- 11.1)

***: Check 1.3's release notes for info about how this was calculated

\*\*\*\*: Version 1.4.0-beta-b89cb959 (+/- 50)

\*\*\*\*\*: Version 1.4.0-beta-301171

**Note**: Ratings of late versions are likely to fluctuate a lot as the number of games on the relevant list increases. They do eventually stabilize.

__Note__: Unless otherwise specified, estimated strength is measured for standard chess at a short time control (8 seconds with 0.08 seconds increment), with 1 search thread and a 16MB hash table over 1000 or 2000 game pairs against the previous version, using the Pohl opening book (up to version 1.0) and the UHO_Lichess_4852_v1 book for later versions.

## Notes

This repository was extracted from a monorepo that you can check out [here](https://git.nocturn9x.space/nocturn9x/CPG) (look into the `Chess/` directory): all history before the first commit here can be found there.

## Credits

Many thanks to all the folks on the Engine Programming and Stockfish servers on Discord: your help has been invaluable and Heimdall literally would not exist without the help of all of you. In no particular order, I'd like to thank:

- @analog-hors (okay, she's first for a reason): for her awesome article about magic bitboards as well as providing the initial code for the HCE tuner and the NN inference to get me started on NNUE.
- @ciekce: for helping me debug countless issues, helping me on morelayers, and helping with general net stuff.
- @sroelants: for debugging help and lots of good ideas to steal.
- @tsoj: for solving major performance bottlenecks and helping me debug my broken threading code.
- @viren, @zuppadcipolle, @toanth, and @fuuryy: debugging help.
- @DarkNeutrino, @yoshie2000, @87flowers, @kazapps_08388, and @swedishchef: for lending cores to my OpenBench instance.
- @Quinniboi10 and @ksw0518: for joining [MattBench](https://chess.n9x.co), along with all other MattBench members.
- @ceorwmt: for helping with datagen.
- @cj5716 and @affinelytyped: for ideas and debugging help.
- @jw1912: for creating bullet and helping with debugging twofold LMR (+140 Elo!).
- @__arandomnoob: for debugging a critical bug in my alpha-beta pruning worth over 100 STC Elo.
- @agethereal (aka Andy Grant): for helping with debugging and creating the amazing [OpenBench](https://github.com/AndyGrant/OpenBench).

Y'all are awesome! <3
