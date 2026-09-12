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
- `Shift+M` sets a mate-finder limit; `Shift+S` enters board setup mode.
- `:play` starts a game against the engine; `:watch` starts engine-vs-engine play.
- `:resign`, `:takeback`, `:rematch`, and `:exit` control a game.
- `:load game.pgn` loads a PGN; `Shift+L` or `:analyse` analyzes it.
- `:pgn output.pgn` exports the current game.
- `:frc 518` and `:dfrc 123 456` load Chess960 positions.

Analysis reports include ACPL, accuracy, move judgments, mistake markers, and a
graph that can be switched between evaluation and WDL with `Shift+W`. `Shift+H`
hides or shows the graph.

## Settings and shortcuts

`:set <option> <value>` configures `hash`, `threads`, `multipv`, `depth`,
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
