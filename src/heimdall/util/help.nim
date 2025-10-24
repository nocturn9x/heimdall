# Copyright 2025 Mattia Giambirtone & All Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# TODO: Better help menu (colored) and with help <cmd> functionality.
# Right now we just use the old help menu from the TUI

const HELP_TEXT* = """heimdall help menu:
    Note: currently this only lists additional commands that
    are not part of the UCI specification or UCI commands that
    have additional meaning on top of their standard behavior

    Heimdall is a UCI engine, but by default it starts in "mixed" mode,
    meaning it will accept both standard UCI commands and a set of custom
    extensions listed below. When switching to UCI mode, all custom extensions
    are disabled (unless explicitly stated otherwise)

    - go             : Begin a search.
                       Subcommands:
                           - perft <depth> [options]: Run the performance test at the given depth (in ply) and
                           print the results
                           Options:
                               - bulk    : Enable bulk-counting (significantly faster, gives less statistics)
                               - verbose : Enable move debugging (for each and every move, not recommended on large searches)
                               - captures: Only generate capture moves
                               - nosplit : Do not print the number of legal moves after each root move
                        Example: go perft 5 bulk -> Run the performance test at depth 5 in bulk-counting mode
    - position       : Get/set board position
                       Subcommands:
                       - fen [string]: Set the board to the given fen string
                       - startpos: Set the board to the starting position
                       - frc <number>: Set the board to the given Chess960 (aka Fischer Random Chess) position
                       - dfrc <whiteNum> <blackNum>: Set a double fischer random chess position with the given 
                           white and black Chess960 positions
                       - dfrc <number>: Set a double fischer random chess position using a single index in the
                           format blackNum*960+whiteNum. For example 'position dfrc 308283' is equivalent to
                           'position dfrc 123 321'. Mostly meant for automation purposes
                       - kiwipete: Set the board to the famous kiwipete position
                       Options:
                           - moves {moveList}: Perform the given moves in UCI notation
                               after the position is loaded. This option only applies to the
                               subcommands that set a position, it is ignored otherwise
                       Examples:
                           - position startpos
                           - position fen <fen> moves a2a3 a7a6
                       Note: the frc and dfrc subcommands automatically set UCI_Chess960 to true
    - clear          : Clear the screen
    - move <move>    : Make the given move on the board (expects UCI notation, e.g. e2e4)
    - castle         : Print castling rights for the side to move
    - inCheck        : Print if the current side to move is in check
    - unmove         : Unmakes the last move, if there is one. Can be used in succession
    - stm            : Print which side is to move
    - epTarget       : Print the current en passant target
    - pretty         : Print a colored, Unicode chessboard representing the current position
    - print          : Like pretty, but uses ASCII only and no colors
    - fen            : Print the FEN of the current position
    - pos <args>     : Shorthand for "position <args>"
    - on <square>    : Get the piece on the given square
    - atk <square>   : Print which opponent pieces are attacking the given square
    - def <square>   : Print which friendly pieces are defending the given square
    - pins           : Print the current pin masks
    - checkers       : Print the current check mask
    - nullMove       : Make a "null move" (i.e. pass your turn). If ran after a null move was made, it is reverted
    - zobrist        : Print the zobrist key for the current position
    - pkey           : Print the pawn zobrist key for the current position
    - minkey         : Print the minor piece zobrist key for the current position
    - majKey         : Print the major piece zobrist key for the current position
    - npKeys         : Print the nonpawn zobrist keys for the current position
    - eval           : Print the static evaluation of the current position
    - repeated       : Print whether this position is drawn by repetition
    - status         : Print the status of the game
    - threats        : Print the current threats by the opponent
    - ibucket        : Print the current king input bucket
    - obucket        : Print the current output bucket
    - material       : Print the sum of material (using 1, 3, 3, 5, 9 as values) currently on the board
    - verbatim <path>: Dumps the built-in network to the specified path, straight from the binary
    - network        : Prints the name of the network embedded into the engine
    - uci            : Switches from mixed mode to UCI mode
    - icu            : The opposite of the uci command, reverts back to mixed mode.
                       This nonstandard command is (obviously) available even in UCI mode.
    - wait           : Stop processing input until the current search completes.
                       This nonstandard command is available even in UCI mode.
    - quit           : exit the program
    - set <n> <v>    : Shorthand for the UCI command setoption name <n> value <v>
"""