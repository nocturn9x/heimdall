# UCI and command-line usage

Heimdall implements the [UCI protocol](https://en.wikipedia.org/wiki/Universal_Chess_Interface)
and can be added to chess GUIs such as Arena, En Croissant, and Cutechess.

## UCI options

- `HClear`: clear history tables; this happens automatically at every new game.
- `TTClear`: clear the transposition table; this also happens automatically.
- `Ponder`: allow searching while the opponent searches.
- `UCI_ShowWDL`: show predicted win, draw, and loss probabilities.
- `UCI_Chess960`: enable Fischer Random and Double Fischer Random chess.
- `EvalFile`: path to a compatible external neural network; `<default>` restores the shipped network (embedded in ordinary builds, shared in the combined Linux executable).
- `NormalizeScore`: normalize displayed scores to a win probability. Enabled by default.
- `EnableWeirdTCs`: permit untested time controls such as sudden death and moves to go.
- `MultiPV`: number of principal variations; time limits are shared across lines.
- `Threads`: number of search threads; the default is one.
- `Hash`: transposition-table size in MiB; the default is 64.
- `MoveOverhead`: milliseconds reserved for GUI or network delays; the default is 250.
- `Minimal`: print only the final search information line.
- `Contempt`: side-to-move-relative draw avoidance offset; the default is 0.

## Root move restrictions

`go searchmoves e2e4 d2d4 depth 10` searches only the listed root moves.
Heimdall also supports the custom `excludemoves` subcommand:

```text
go depth 10 excludemoves e2e4 d2d4
```

This searches all legal root moves except `e2e4` and `d2d4`. Both lists use UCI
move notation and can appear before or after search limits. They can be combined,
for example `go depth 10 searchmoves e2e4 d2d4 excludemoves g1f3`. Heimdall rejects
the command if any move appears in both lists, regardless of their order.
If exclusions leave no legal root moves, Heimdall refuses to search and reports
`bestmove 0000`. Empty lists impose no restriction; illegal moves are ignored.
Restrictions apply to MultiPV, all search threads, and policy evaluation
(`go eval` or `go nodes 1`), and last only for that `go` command.

## Mixed mode

When connected to a TTY, Heimdall starts a command-line interface with color,
history, and line editing. `NO_COLOR` disables colors, `NO_TUI` starts directly
in UCI mode, and `NO_LOGO` suppresses the startup logo. Sending `uci` switches
to UCI mode; `icu` returns to mixed mode. Ctrl+C, Ctrl+D, or Esc exits the
interface.

The `genfens` command generates seeded openings, for example:

```sh
heimdall "genfens 100 seed 123 book None dfrc true" "quit"
```

The `relabel` command replaces move scores in a
[viriformat 3.0.0](https://docs.rs/viriformat/3.0.0/viriformat/) file:

```sh
heimdall relabel --input=games.vf --output=relabeled.vf \
  --nodes-soft=5000 --nodes-hard=1000000 --hash=1 --threads=8 --join
```

It accepts `--input`, `--output`, `--depth`, `--nodes-soft`, `--nodes-hard`,
`--hash`, `--threads`, `--chunk-size`, `--skip`, `--limit`, and `--join`.
Without `--join`, worker output remains in `OUTPUT.part-000` style shards.
