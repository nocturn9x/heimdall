# Copyright 2026 Mattia Giambirtone & All Contributors
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

## Parsing of UCI commands into their structured representation

import heimdall/[board, movegen]
import heimdall/util/[scharnagl, move_parse]

import std/[atomics, options, strutils, strformat, sequtils]

import heimdall/uci/shared


proc parseUCIMove*(session: UCISession, position: Position, move: string): tuple[move: Move, command: UCICommand] =
    let parsed = move_parse.parseUCIMove(position, move, chess960=session.searcher.state.chess960.load(moRelaxed))
    result.move = parsed.move
    if parsed.error.hasError():
        let reason =
            if parsed.error.kind == umpChess960Disabled:
                formatUCIMoveParseError(
                    parsed.error,
                    chess960DisabledPrefix="received Chess960-style castling move",
                    chess960DisabledReason="UCI_Chess960 is not set"
                )
            else:
                formatUCIMoveParseError(parsed.error)
        result.command = UCICommand(kind: Unknown, reason: reason)


proc handleUCIMove*(session: UCISession, board: Chessboard, moveStr: string): tuple[move: Move, cmd: UCICommand] {.discardable.} =
    if session.debug:
        echo &"info string making move {moveStr}"
    let r = session.parseUCIMove(board.position, moveStr)
    if session.debug:
        echo &"info string {moveStr} parses to {r.move}"
    result.cmd = r.command
    result.move = r.move
    if result.move != nullMove():
        result.move = board.makeMove(r.move)
        if result.move == nullMove():
            result.cmd = UCICommand(kind: Unknown, reason: &"move is illegal")


proc handleUCIGoCommand*(session: UCISession, command: seq[string]): UCICommand =
    result = UCICommand(kind: Go)
    var current = 1   # Skip the "go"
    while current < command.len():
        let subcommand = command[current]
        inc(current)
        case subcommand:
            of "infinite":
                result.infinite = true
            of "ponder":
                result.ponder = true
            of "wtime":
                try:
                    result.wtime = some(command[current].parseInt())
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand}' subcommand")
            of "btime":
                try:
                    result.btime = some(command[current].parseInt())
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand}' subcommand")
            of "winc":
                try:
                    result.winc = some(command[current].parseInt())
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand}' subcommand")
            of "binc":
                try:
                    result.binc = some(command[current].parseInt())
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand}' subcommand")
            of "movestogo":
                try:
                    result.movesToGo = some(command[current].parseInt())
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand}' subcommand")
            of "depth":
                try:
                    result.depth = some(command[current].parseInt())
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand}' subcommand")
            of "movetime":
                try:
                    result.moveTime = some(command[current].parseInt())
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand}' subcommand")
            of "nodes":
                try:
                    result.nodes = some(command[current].parseBiggestUInt().uint64)
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand}' subcommand")
            of "mate":
                try:
                    let value = command[current].parseInt()
                    if value < 1:
                        return UCICommand(kind: Unknown, reason: &"invalid value '{command[current]} for '{subcommand}' subcommand (must be >= 1)")
                    result.mate = some(command[current].parseInt())
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand}' subcommand")
            of "searchmoves":
                while current < command.len():
                    if command[current] == "":
                        break
                    let move = session.parseUCIMove(session.board.position, command[current]).move
                    if move == nullMove():
                        return UCICommand(kind: Unknown, reason: &"invalid move '{command[current]}' for searchmoves")
                    result.searchmoves.add(move)
                    inc(current)
            of "perft":
                if current >= command.len():
                    return UCICommand(kind: Unknown, reason: "missing depth argument for '{subcommand}'")
                var depth: int
                try:
                    depth = command[current].parseInt()
                    inc(current)
                except ValueError:
                    return UCICommand(kind: Unknown, reason: &"invalid integer '{command[current]}' for '{subcommand} depth'")

                var tup = (depth: depth, verbose: false, capturesOnly: false, divide: true, bulk: false)

                while current < command.len():
                    if command[current] == "":
                        break
                    case command[current]:
                        of "bulk":
                            tup.bulk = true
                        of "verbose":
                            tup.verbose = true
                        of "captures":
                            tup.capturesOnly = true
                        of "nosplit":
                            tup.divide = false
                        else:
                            return UCICommand(kind: Unknown, reason: &"unknown option '{command[current]}' for '{subcommand}' subcommand")
                    inc(current)

                result.perft = some(tup)
            of "eval":
                result.eval = true
            else:
                return UCICommand(kind: Unknown, reason: &"unknown subcommand '{command[current - 1]}' for 'go'")

    let
        isLimitedSearch = anyIt([result.wtime, result.btime, result.winc, result.binc, result.movesToGo, result.depth, result.moveTime, result.mate], it.isSome()) or result.nodes.isSome()
        isPerftSearch = result.perft.isSome()
    if result.eval:
        # 'go eval' is a standalone command: it makes no sense alongside any
        # other search limit, perft or pondering
        if result.infinite or isLimitedSearch or isPerftSearch or result.ponder:
            return UCICommand(kind: Unknown, reason: "'go eval' does not make sense with other search limits, perft or pondering")
        return result
    if result.infinite:
        if result.ponder:
            return UCICommand(kind: Unknown, reason: "'go infinite' does not make sense with the 'ponder' option")
        if isLimitedSearch:
            return UCICommand(kind: Unknown, reason: "'go infinite' does not make sense with other search limits")
        if isPerftSearch:
            # Note: go perft <stuff> and go <limits> are already mutually exclusive because one
            # will be parsed as a subcommand of the other and will cause a parse error
            return UCICommand(kind: Unknown, reason: "'go infinite' and 'go perft' are mutually exclusive")
    if not isLimitedSearch and not isPerftSearch:
        # A bare 'go' is interpreted as 'go infinite'
        result.infinite = true


proc handleUCIPositionCommand*(session: var UCISession, command: seq[string]): UCICommand =
    result = UCICommand(kind: Position)
    # Makes sure we don't leave the board in an invalid state if
    # some error occurs
    var chessboard: Chessboard
    if command[1] notin ["startpos", "kiwipete"] and len(command) < 3:
        return UCICommand(kind: Unknown, reason: &"missing FEN/scharnagl number for 'position {command[1]}' command")
    var args = command[2..^1]
    case command[1]:
        of "startpos", "fen", "kiwipete":
            if command[1] == "startpos":
                result.fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
            elif command[1] == "kiwipete":
                result.fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -"
            else:
                var fenString = ""
                var stop = 0
                for i, arg in args:
                    if arg == "moves":
                        break
                    if i > 0:
                        fenString &= " "
                    fenString &= arg
                    inc(stop)
                result.fen = fenString
                args = args[stop..^1]
            chessboard = newChessboardFromFEN(result.fen)
            let
                sideToMove = chessboard.sideToMove
                attackers = chessboard.position.attackers(chessboard.position.kingSquare(sideToMove.opposite()), sideToMove)
            if not attackers.isEmpty():
                return UCICommand(kind: Unknown, reason: "position is illegal: opponent must not be in check")
            if command.len() > 2 and args.len() > 0:
                var i = 0
                while i < args.len():
                    if args[i] == "moves":
                        var j = i + 1
                        while j < args.len():
                            let r = handleUCIMove(session, chessboard, args[j])
                            if r.move == nullMove():
                                if r.cmd.reason.len() > 0:
                                    return UCICommand(kind: Unknown, reason: &"move {args[j]} is invalid ({r.cmd.reason})")
                                else:
                                    return UCICommand(kind: Unknown, reason: &"move {args[j]} is invalid")
                            result.moves.add(args[j])
                            inc(j)
                    inc(i)
        of "frc":
            if len(args) < 1:
                return UCICommand(kind: Unknown, reason: "missing scharnagl number for 'position frc' command")
            if len(args) > 1:
                return UCICommand(kind: Unknown, reason: "too many arguments for 'position frc' command")
            try:
                let scharnaglNumber = args[0].parseInt()
                if scharnaglNumber notin 0..959:
                    return UCICommand(kind: Unknown, reason: &"scharnagl number must be 0 <= n < 960")
                result = session.handleUCIPositionCommand(@["position", "fen", scharnaglNumber.scharnaglToFEN()])
                if not session.searcher.state.chess960.load(moRelaxed):
                    if session.debug:
                        echo "info automatically enabling Chess960 support"
                    session.searcher.state.chess960.store(true, moRelaxed)
                return
            except ValueError:
                return UCICommand(kind: Unknown, reason: &"invalid integer for 'position frc' command")
        of "dfrc":
            if len(args) < 1:
                return UCICommand(kind: Unknown, reason: "missing white scharnagl number for 'position dfrc' command")
            if len(args) > 2:
                return UCICommand(kind: Unknown, reason: "too many arguments for 'position dfrc' command")

            try:
                var whiteScharnaglNumber: int
                var blackScharnaglNumber: int
                if len(args) == 2:
                    whiteScharnaglNumber = args[0].parseInt()
                    blackScharnaglNumber = args[1].parseInt()
                    if whiteScharnaglNumber notin 0..959 or blackScharnaglNumber notin 0..959:
                        return UCICommand(kind: Unknown, reason: &"scharnagl numbers must be 0 <= n < 960")
                else:
                    let n = args[0].parseInt()
                    if n >= 960 * 960:
                        return UCICommand(kind: Unknown, reason: &"scharnagl index must be 0 <= n < 921600")
                    whiteScharnaglNumber = n mod 960
                    blackScharnaglNumber = n div 960
                result = session.handleUCIPositionCommand(@["position", "fen", scharnaglToFEN(whiteScharnaglNumber, blackScharnaglNumber)])
                if not session.searcher.state.chess960.load(moRelaxed):
                    if session.debug:
                        echo "info automatically enabling Chess960 support"
                    session.searcher.state.chess960.store(true, moRelaxed)
                return
            except ValueError:
                return UCICommand(kind: Unknown, reason: &"invalid integer for 'position dfrc' command")
        else:
            return UCICommand(kind: Unknown, reason: &"unknown subcomponent '{command[1]}' for 'position' command")
    session.board.positions.setLen(0)
    for position in chessboard.positions:
        session.board.positions.add(position.clone())


proc parseUCICommand*(session: var UCISession, command: string): UCICommand =
    var cmd = command.replace("\t", "").splitWhitespace()
    result = UCICommand(kind: Unknown)
    var current = 0
    while current < cmd.len():
        # Try bare commands first, then simple commands, then standard UCI commands.
        # We call toLowerAscii because parseEnum does style-insensitive comparisons
        # and they bother me greatly
        try:
            let bareCmd = parseEnum[BareUCICommand](cmd[current].toLowerAscii())
            inc(current)
            if current != cmd.len() and bareCmd != Barbecue:
                return UCICommand(kind: Unknown, reason: &"too many arguments for '{cmd[current - 1]}' command")
            if bareCmd != Barbecue:
                # The easter egg is another special case which requires
                # more validation
                return UCICommand(kind: Bare, bareCmd: bareCmd)
        except ValueError:
            try:
                let simpleCmd = parseEnum[SimpleUCICommand](cmd[current].toLowerAscii())
                let argCount = cmd.high() - current
                if argCount > 1:
                    return UCICommand(kind: Unknown, reason: &"too many arguments for '{cmd[current]}' command")
                if argCount < 1 and simpleCmd != Help:
                    # Help is the only simple command taking in an *optional*
                    # argument!
                    return UCICommand(kind: Unknown, reason: &"insufficient arguments for '{cmd[current]}' command")
                if argCount > 0:
                    inc(current)
                    return UCICommand(kind: Simple, simpleCmd: simpleCmd, arg: cmd[current])
                else:
                    return UCICommand(kind: Simple, simpleCmd: simpleCmd, arg: "")
            except ValueError:
                discard
        case cmd[current]:
            of "getScale":
                inc(current)
                let currMean = parseFloat(cmd[current])
                inc(current)
                let newMean = parseFloat(cmd[current])
                return UCICommand(kind: GetScale, currAbsMean: currMean, newAbsMean: newMean)
            of "isready":
                return UCICommand(kind: IsReady)
            of "uci":
                return UCICommand(kind: Uci)
            of "stop":
                return UCICommand(kind: Stop)
            of "help":
                # TODO: Help with submenus
                return UCICommand(kind: Simple, arg: "")
            of "ucinewgame":
                return UCICommand(kind: NewGame)
            of "quit":
                return UCICommand(kind: Quit)
            of "ponderhit":
                return UCICommand(kind: PonderHit)
            of "debug":
                if current == cmd.high():
                    return UCICommand(kind: Unknown, reason: "expecting 'on' or 'off' after 'debug' command")
                case cmd[current + 1]:
                    of "on":
                        return UCICommand(kind: Debug, on: true)
                    of "off":
                        return UCICommand(kind: Debug, on: false)
                    else:
                        return UCICommand(kind: Unknown, reason: &"expecting 'on' or 'off' after 'debug' command, got '{cmd[current + 1]}' instead")
            of "position":
                return session.handleUCIPositionCommand(cmd[current..^1])
            of "go":
                return session.handleUCIGoCommand(cmd[current..^1])
            of "set":
                inc(current)
                result = UCICommand(kind: Set)
                if len(cmd) != 3:
                    return UCICommand(kind: Unknown, reason: &"wrong number of arguments for set")
                let cmd = session.parseUCICommand(&"setoption name {cmd[current]} value {cmd[current + 1]}")
                result.name = cmd.name
                result.value = cmd.value
                inc(current, 2)
            of "setoption":
                result = UCICommand(kind: SetOption)
                inc(current)
                while current < cmd.len():
                    case cmd[current]:
                        of "name":
                            inc(current)
                            result.name = cmd[current]
                        of "value":
                            inc(current)
                            result.value = cmd[current]
                        else:
                            discard
                    inc(current)
            of "Dont":
                inc(current)
                let base = current
                const words = "miss the ShredderChess Annual Barbeque".splitWhitespace()
                var i = 0
                while i < words.len() and current < cmd.len():
                    if cmd[base + i] != words[i]:
                        break
                    inc(i)
                    inc(current)
                if i == words.len():
                    return UCICommand(kind: Bare, bareCmd: Barbecue)
            else:
                if not session.isMixedMode:
                    # Unknown UCI commands should be ignored. Attempt
                    # to make sense of the input regardless
                    inc(current)
                else:
                    return UCICommand(kind: Unknown, reason: &"refusing to parse malformed input in mixed mode (stopped at '{cmd[current]}')")
