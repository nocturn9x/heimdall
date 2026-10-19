# Built-in terminal UI

The built-in TUI provides analysis and play from a terminal. It uses Kitty's
graphics protocol and currently supports Linux. Start it with:

```sh
heimdall tui
```

Kitty, Ghostty, WezTerm, and Konsole are supported, with Kitty recommended.
Other terminals may not implement the required graphics protocol. Konsole has
known issues with mouse positioning and image quality. The TUI does not honor
`NO_COLOR`.

## Moving and annotating

Moves can be entered by clicking, dragging, UCI notation such as `e2e4`, SAN
notation such as `Nf3`, or square selection (`e2`, then `e4`). Promotions
default to a queen; `Shift+Q` toggles auto-queen. Right-click highlights a
square and right-drag draws arrows. Shift/Ctrl, Alt, or both modifier groups
choose red, blue, or yellow arrows.

The board scales down to fit the terminal. Use `:help` for the complete command
list. The input line supports Left/Right, `Ctrl+A`, and `Ctrl+E`.

## Analysis and play

- `:go` starts or stops continuous analysis.
- `:set multipv 3` shows multiple lines; `:arrows` toggles engine arrows.
- PV moves use SAN by default. `:set pvnotation uci` switches to UCI coordinates;
  `:set pvnotation san` restores SAN, including during analysis.
- `Shift+M` sets a mate-finder limit; `Shift+S` enters board setup mode.
- `:play` starts a game against the engine; `:watch` starts engine-vs-engine play.
- `:resign`, `:takeback`, `:rematch`, and `:exit` control a game.
- `:load game.pgn` loads a PGN; `Shift+L` or `:analyse` analyzes it.
- `:pgn output.pgn` exports the current game.
- `:frc 518` and `:dfrc 123 456` load Chess960 positions.

Analysis reports include ACPL, accuracy, move judgments, mistake markers, and a
graph that can be switched between evaluation and WDL with `Shift+W`. `Shift+H`
hides or shows the graph.

SAN castling is displayed as `O-O` or `O-O-O`. UCI castling uses the king's
destination in standard chess (for example, `e1g1`), and the rook's origin when
Chess960 mode is enabled (for example, `e1h1`).

## Watching external UCI engines

`:watch` accepts an engine command for either color. Omitted colors use the
built-in Heimdall engine:

```text
:watch --white "stockfish" --black "/path/to/another-engine --argument"
:watch --black "stockfish"
:watch --white "stockfish" --white-option "UCI_LimitStrength=true" --white-option "UCI_Elo=1800"
```

Use `--white-option "Name=value"`, `--black-option "Name=value"`, or
`--option "Name=value"` for both external engines. Commands run directly, with
quoted arguments supported. Complete the usual variant, limits, threads, hash,
and pondering prompts. Threads and hash are sent to external engines that
advertise those options; explicit command-line options override these defaults.
Chess960 requires the external engine to advertise `UCI_Chess960`. Pondering is
used only when the engine advertises `Ponder`.

External searches support time controls, depth and node limits. A soft node limit
uses the hard cap when one is configured, otherwise it becomes a UCI node limit.
Without any search limit, external engines receive a one-second move budget.
Engine names, scores, PVs, nodes and speed appear in the watch display, and PGN
exports include the engine names and move statistics.
The eval bar includes a numeric score and retains the last live evaluation
between turns while the next engine starts searching.

During setup or a game, set an additional external-engine option with:

```text
:ucioption white "Option Name" value
:ucioption black Hash=128
:ucioption both "Option Name=value with spaces"
```

Use `:exit` to stop the game and close its external engines. Human `:play` games
continue to use the built-in engine.

## Settings and shortcuts

`:set <option> <value>` configures `hash`, `threads`, `multipv`, `pvnotation`, `depth`,
`contempt`, `moveoverhead`, `ponder`, `normalizescore`, `evalfile`, and
`chess960`. Hash values accept units such as `1 GB` and `256 MiB`. `:clear`
resets engine state. Other useful commands are `:fen`, `:reset`, `:flip`,
`:arrows`, and `:threats`.

| Key | Action |
| --- | --- |
| `Shift+A` | Toggle best-move arrows |
| `Shift+F` | Flip the board |
| `Shift+H` | Hide/show the analysis graph |
| `Shift+L` | Analyze the loaded PGN |
| `Shift+M` | Set a mate-finder limit |
| `Shift+Q` | Toggle auto-queen |
| `Shift+S` | Enter board setup |
| `Shift+W` | Toggle evaluation/WDL graph |
| Left/Right | Undo/redo moves |
| Home/End | First/last position |
| `Ctrl+C` | Quit immediately |
| `Esc` | Cancel the current action |
