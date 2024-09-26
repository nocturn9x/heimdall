# Copyright 2024 Mattia Giambirtone & All Contributors
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

import heimdallpkg/movegen
import heimdallpkg/eval
import heimdallpkg/uci
import heimdallpkg/datagen/scharnagl


import std/strformat
import std/strutils
import std/times
import std/math


from std/lenientops import `/`


type
    CountData = tuple[nodes: uint64, captures: uint64, castles: uint64, checks: uint64,  promotions: uint64, enPassant: uint64, checkmates: uint64]


proc perft*(board: Chessboard, ply: int, verbose = false, divide = false, bulk = false, capturesOnly = false): CountData =
    ## Counts (and debugs) the number of legal positions reached after
    ## the given number of ply
    
    if ply == 0:
        result.nodes = 1
        return

    var moves = newMoveList()
    board.generateMoves(moves, capturesOnly=capturesOnly)
    if not bulk:
        if len(moves) == 0 and board.inCheck():
            result.checkmates = 1
        # TODO: Should we count stalemates/draws?
        if ply == 0:
            result.nodes = 1
            return
    elif ply == 1 and bulk:
        if divide:
            for move in moves:
                echo &"{move.toAlgebraic()}: 1"
                if verbose:
                    echo ""
        return (uint64(len(moves)), 0, 0, 0, 0, 0, 0)

    for move in moves:
        if verbose:
            let canCastle = board.canCastle()
            echo &"Move: {move.startSquare.toAlgebraic()}{move.targetSquare.toAlgebraic()}"
            echo &"Turn: {board.sideToMove}"
            echo &"Piece: {board.position.getPiece(move.startSquare).kind}"
            echo &"Flags: {move.getFlags()}"
            echo &"In check: {(if board.inCheck(): \"yes\" else: \"no\")}"
            echo &"Castling targets:\n  - King side: {(if canCastle.king != nullSquare(): canCastle.king.toAlgebraic() else: \"None\")}\n  - Queen side: {(if canCastle.queen != nullSquare(): canCastle.queen.toAlgebraic() else: \"None\")}"
            echo &"Position before move: {board.toFEN()}"
            echo &"Hash: {board.zobristKey}"
            stdout.write("En Passant target: ")
            if board.position.enPassantSquare != nullSquare():
                echo board.position.enPassantSquare.toAlgebraic()
            else:
                echo "None"
            echo "\n", board.pretty()
        board.doMove(move)
        when not defined(danger):
            let incHash = board.zobristKey
            board.positions[^1].hash()
            assert board.zobristKey == incHash, &"{board.zobristKey} != {incHash} at {move} ({board.positions[^2].toFEN()})"
        if ply == 1:
            if move.isCapture():
                inc(result.captures)
            if move.isCastling():
                inc(result.castles)
            if move.isPromotion():
                inc(result.promotions)
            if move.isEnPassant():
                inc(result.enPassant)
        if board.inCheck():
            # Opponent king is in check
            inc(result.checks)
        if verbose:
            let canCastle = board.canCastle()
            echo "\n"
            echo &"Opponent in check: {(if board.inCheck(): \"yes\" else: \"no\")}"
            echo &"Opponent castling targets:\n  - King side: {(if canCastle.king != nullSquare(): canCastle.king.toAlgebraic() else: \"None\")}\n  - Queen side: {(if canCastle.queen != nullSquare(): canCastle.queen.toAlgebraic() else: \"None\")}"
            echo &"Position after move: {board.toFEN()}"
            echo "\n", board.pretty()
            stdout.write("nextpos>> ")
            try:
                discard readLine(stdin)
            except IOError:
                discard
            except EOFError:
                discard
        let next = board.perft(ply - 1, verbose, bulk=bulk)
        board.unmakeMove()
        if divide and (not bulk or ply > 1):
            echo &"{move.toAlgebraic()}: {next.nodes}"
            if verbose:
                echo ""
        result.nodes += next.nodes
        result.captures += next.captures
        result.checks += next.checks
        result.promotions += next.promotions
        result.castles += next.castles
        result.enPassant += next.enPassant
        result.checkmates += next.checkmates


proc handleMoveCommand(board: Chessboard, state: EvalState, command: seq[string]): Move {.discardable.} =
    if len(command) != 2:
        echo &"Error: move: invalid number of arguments"
        return
    let moveString = command[1]
    if len(moveString) notin 4..5:
        echo &"Error: move: invalid move syntax"
        return
    var
        startSquare: Square
        targetSquare: Square
        flags: seq[MoveFlag]
    
    try:
        startSquare = moveString[0..1].toSquare()
    except ValueError:
        echo &"Error: move: invalid start square ({moveString[0..1]})"
        return
    try:
        targetSquare = moveString[2..3].toSquare()
    except ValueError:
        echo &"Error: move: invalid target square ({moveString[2..3]})"
        return

    # Since the user tells us just the source and target square of the move,
    # we have to figure out all the flags by ourselves (whether it's a double
    # push, a capture, a promotion, etc.)
    
    if board.position.getPiece(targetSquare).color == board.sideToMove.opposite():
        flags.add(Capture)

    if board.position.getPiece(startSquare).kind == Pawn and abs(rankFromSquare(startSquare) - rankFromSquare(targetSquare)) == 2:
        flags.add(DoublePush)

    if len(moveString) == 5:
        # Promotion
        case moveString[4]:
            of 'b':
                flags.add(PromoteToBishop)
            of 'n':
                flags.add(PromoteToKnight)
            of 'q':
                flags.add(PromoteToQueen)
            of 'r':
                flags.add(PromoteToRook)
            else:
                echo &"Error: move: invalid promotion type"
                return
    
    
    var move = createMove(startSquare, targetSquare, flags)
    let piece = board.position.getPiece(move.startSquare)
    let canCastle = board.canCastle()
    if piece.kind == King and (move.targetSquare == canCastle.king or move.targetSquare == canCastle.queen):
        move.flags = move.flags or Castle.uint8
    elif piece.kind == Pawn and targetSquare == board.position.enPassantSquare:
        # I hate en passant I hate en passant I hate en passant I hate en passant I hate en passant I hate en passant 
        flags.add(EnPassant)
    if board.isLegal(move):
        let kingSq = board.getBitboard(King, board.sideToMove).toSquare()
        state.update(move, board.sideToMove, board.getPiece(move.startSquare).kind, board.getPiece(move.targetSquare).kind, kingSq)
        board.doMove(move)
        return move
    else:
        echo &"Error: move: {moveString} is illegal"


proc handleGoCommand(board: Chessboard, command: seq[string]) =
    if len(command) < 2:
        echo &"Error: go: invalid number of arguments"
        return
    case command[1]:
        of "perft":
            if len(command) == 2:
                echo &"Error: go: perft: invalid number of arguments"
                return
            var 
                args = command[2].splitWhitespace()
                bulk = false
                verbose = false
                captures = false
                divide = true
            if args.len() > 1:
                var ok = true
                for arg in args[1..^1]:
                    case arg:
                        of "bulk":
                            bulk = true
                        of "verbose":
                            verbose = true
                        of "captures":
                            captures = true
                        of "nosplit":
                            divide = false
                        else:
                            echo &"Error: go: {command[1]}: invalid argument '{args[1]}'"
                            ok = false
                            break
                if not ok:
                    return
            try:
                let ply = parseInt(args[0])
                if bulk:
                    let t = cpuTime()
                    let nodes = board.perft(ply, divide=divide, bulk=true, verbose=verbose, capturesOnly=captures).nodes
                    let tot = cpuTime() - t
                    if divide:
                        echo ""
                    echo &"Nodes searched (bulk-counting: on): {nodes}"
                    echo &"Time taken: {round(tot, 3)} seconds\nNodes per second: {round(nodes / tot).uint64}"
                else:
                    let t = cpuTime()
                    let data = board.perft(ply, divide=divide, verbose=verbose, capturesOnly=captures)
                    let tot = cpuTime() - t
                    if divide:
                        echo ""
                    echo &"Nodes searched (bulk-counting: off): {data.nodes}"
                    echo &"  - Captures: {data.captures}"
                    echo &"  - Checks: {data.checks}"
                    echo &"  - E.P: {data.enPassant}"
                    echo &"  - Checkmates: {data.checkmates}"
                    echo &"  - Castles: {data.castles}"
                    echo &"  - Promotions: {data.promotions}"
                    echo ""
                    echo &"Time taken: {round(tot, 3)} seconds\nNodes per second: {round(data.nodes / tot).uint64}"
            except ValueError:
                echo &"error: go: {command[1]}: invalid depth"
        else:
            echo &"error: go: unknown subcommand '{command[1]}'"


proc handlePositionCommand(board: var Chessboard, state: EvalState, command: seq[string]) =
    if len(command) < 2:
        echo "Error: position: invalid number of arguments"
        return
    # Makes sure we don't leave the board in an invalid state if
    # some error occurs
    var tempBoard: Chessboard
    case command[1]:
        of "startpos", "kiwipete":
            if command[1] == "kiwipete":
                tempBoard = newChessboardFromFen("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -")
            else:
                tempBoard = newDefaultChessboard()
            if command.len() > 2:
                let args = command[2].splitWhitespace()
                if args.len() > 0:
                    var i = 0
                    while i < args.len():
                        case args[i]:
                            of "moves":
                                var j = i + 1
                                while j < args.len():
                                    if handleMoveCommand(tempBoard, state, @["move", args[j]]) == nullMove():
                                        return
                                    inc(j)
                        inc(i)
            board = tempBoard
            state.init(board)
        of "frc":
            let args = command[2].splitWhitespace()
            if len(args) != 1:
                echo &"error: position: frc: invalid number of arguments"
                return
            try:
                let scharnaglNumber = args[0].parseInt()
                if scharnaglNumber notin 0..959:
                    echo &"error: position: frc: scharnagl number must be 0 <= 0 < 960"
                    return
                handlePositionCommand(board, state, @["position", "fen", scharnaglNumber.scharnaglToFEN()])
            except ValueError:
                echo &"error: position: frc: invalid scharnagl number"
                return
        of "dfrc":
            let args = command[2].splitWhitespace()
            if len(args) != 2:
                echo &"error: position: dfrc: invalid number of arguments"
                return
            try:
                let whiteScharnaglNumber = args[0].parseInt()
                let blackScharnaglNumber = args[1].parseInt()
                if whiteScharnaglNumber notin 0..959 or blackScharnaglNumber notin 0..959:
                    echo &"error: position: dfrc: scharnagl number must be 0 <= n < 960"
                    return
                handlePositionCommand(board, state, @["position", "fen", scharnaglToFEN(whiteScharnaglNumber, blackScharnaglNumber)])
            except ValueError:
                echo &"error: position: dfrc: invalid scharnagl number"
                return
        of "fen":
            if len(command) == 2:
                echo &"Current position: {board.toFEN()}"
                return
            var 
                args = command[2].splitWhitespace()
                fenString = ""
                stop = 0
            for i, arg in args:
                if arg in ["moves", ]:
                    break
                if i > 0:
                    fenString &= " "
                fenString &= arg
                inc(stop)
            args = args[stop..^1]
            try:
                tempBoard = newChessboardFromFEN(fenString)
                # Account for checkmated FENs with the wrong stm
                var moves = newMoveList()
                tempBoard.makeNullMove()
                tempBoard.generateMoves(moves)
                tempBoard.unmakeMove()
                if len(moves) == 0:
                    raise newException(ValueError, "illegal FEN: side to move has already checkmated")
            except ValueError:
                echo &"error: position: {getCurrentExceptionMsg()}"
                return
            if args.len() > 0:
                var i = 0
                while i < args.len():
                    case args[i]:
                        of "moves":
                            var j = i + 1
                            while j < args.len():
                                if handleMoveCommand(tempBoard, state, @["move", args[j]]) == nullMove():
                                    return
                                inc(j)
                    inc(i)
            board = tempBoard
            state.init(board)
        of "print":
            echo board
        of "pretty":
            echo board.pretty()
        else:
            echo &"error: position: unknown subcommand '{command[1]}'"
            return


const HELP_TEXT = """heimdall help menu:
    - go: Begin a search. Currently does not implement UCI search features (simply 
          switch to UCI mode for that)
          Subcommands: 
            - perft <depth> [options]: Run the performance test at the given depth (in ply) and
              print the results
              Options:
                - bulk: Enable bulk-counting (significantly faster, gives less statistics)
                - verbose: Enable move debugging (for each and every move, not recommended on large searches)
                - captures: Only generate capture moves
                - nosplit: Do not print the number of legal moves after each root move
        Example: go perft 5 bulk
    - position: Get/set board position
                Subcommands:
                  - fen [string]: Set the board to the given fen string if one is provided, or print
                    the current position as a FEN string if no arguments are given
                  - startpos: Set the board to the starting position
                  - frc <number>: Set the board to the given Chess960 (aka Fischer Random Chess) position
                  - dfrc <whiteNum> <blackNum>: Set a double fischer random chess position with the given white and black
                    Chess960 positions
                  - kiwipete: Set the board to the famous kiwipete position
                  - pretty: Pretty-print the current position
                  - print: Print the current position using ASCII characters only
                  Options:
                    - moves {moveList}: Perform the given moves in algebraic notation
                        after the position is loaded. This option only applies to the
                        subcommands that set a position, it is ignored otherwise
                Examples:
                    - position startpos
                    - position fen ... moves a2a3 a7a6
    - clear: Clear the screen
    - move <move>: Perform the given move in algebraic notation
    - castle: Print castling rights for the side to move
    - check: Print if the current side to move is in check
    - unmove, u: Unmakes the last move. Can be used in succession
    - stm: Print which side is to move
    - ep: Print the current en passant target
    - pretty: Shorthand for "position pretty"
    - print: Shorthand for "position print"
    - fen: Shorthand for "position fen"
    - pos <args>: Shorthand for "position <args>"
    - get <square>: Get the piece on the given square
    - atk <square>: Print which opponent pieces are attacking the given square
    - def <square>: Print which friendly pieces are attacking the given square
    - pins: Print the current pin masks, if any
    - checks: Print the current check mask, if in check
    - skip: Make a null move (i.e. pass your turn). Useful for debugging. Very much illegal
    - uci: enter UCI mode
    - quit: exit
    - zobrist: Print the zobrist hash for the current position
    - eval: Evaluate the current position
    - rep: Show whether this position is a draw by repetition
    - status: Print the status of the game
    - threats: Print the current threats by the opponent, if there are any
    """


proc commandLoop*: int =
    ## heimdall's control interface
    echo "Heimdall by nocturn9x (see LICENSE)"
    var 
        board = newDefaultChessboard()
        state = newEvalState()
        startUCI = false
    state.init(board)
    while true:
        var
            cmd: seq[string]
            cmdStr: string
        try:
            stdout.write(">>> ")
            stdout.flushFile()
            cmdStr = readLine(stdin).strip(leading=true, trailing=true, chars={'\t', ' '})
            if cmdStr.len() == 0:
                continue
            cmd = cmdStr.splitWhitespace(maxsplit=2)
            case cmd[0]:
                of "uci":
                    startUCI = true
                    break
                of "clear":
                    echo "\x1Bc"
                of "help":
                    echo HELP_TEXT
                of "skip":
                    if board.position.fromNull:
                        board.unmakeMove()
                    else:
                        board.makeNullMove()
                of "go":
                    handleGoCommand(board, cmd)
                of "position", "pos":
                    handlePositionCommand(board, state, cmd)
                of "move":
                    handleMoveCommand(board, state, cmd)
                of "pretty", "print", "fen":
                    handlePositionCommand(board, state, @["position", cmd[0]])
                of "unmove", "u":
                    if board.positions.len() == 1:
                        echo "No previous move to undo"
                    else:
                        state.undo()
                        board.unmakeMove()
                of "stm":
                    echo &"Side to move: {board.sideToMove}"
                of "atk":
                    if len(cmd) != 2:
                        echo "error: atk: invalid number of arguments"
                        continue
                    try:
                        echo board.position.getAttackersTo(cmd[1].toSquare(), board.sideToMove.opposite())
                    except ValueError:
                        echo "error: atk: invalid square"
                        continue
                of "def":
                    if len(cmd) != 2:
                        echo "error: def: invalid number of arguments"
                        continue
                    try:
                        echo board.position.getAttackersTo(cmd[1].toSquare(), board.sideToMove)
                    except ValueError:
                        echo "error: def: invalid square"
                        continue
                of "ep":
                    let target = board.position.enPassantSquare
                    if target != nullSquare():
                        echo &"En passant target: {target.toAlgebraic()}"
                    else:
                        echo "En passant target: None"
                of "get":
                    if len(cmd) != 2:
                        echo "error: get: invalid number of arguments"
                        continue
                    try:
                        echo board.position.getPiece(cmd[1])
                    except ValueError:
                        echo "error: get: invalid square"
                        continue                    
                of "castle":
                    let castleRights = board.position.castlingAvailability[board.sideToMove]
                    let canCastle = board.canCastle()
                    echo &"Castling targets for {($board.sideToMove).toLowerAscii()}:\n  - King side: {(if castleRights.king != nullSquare(): castleRights.king.toAlgebraic() else: \"None\")}\n  - Queen side: {(if castleRights.queen != nullSquare(): castleRights.queen.toAlgebraic() else: \"None\")}"
                    echo &"{($board.sideToMove)} can currently castle:\n  - King side: {(if canCastle.king != nullSquare(): \"yes\" else: \"no\")}\n  - Queen side: {(if canCastle.queen != nullSquare(): \"yes\" else: \"no\")}"
                of "check":
                    echo &"{board.sideToMove} king in check: {(if board.inCheck(): \"yes\" else: \"no\")}"
                of "pins":
                    if board.position.orthogonalPins != 0:
                        echo &"Orthogonal pins:\n{board.position.orthogonalPins}"
                    if board.position.diagonalPins != 0:
                        echo &"Diagonal pins:\n{board.position.diagonalPins}"
                of "checks":
                    if board.position.checkers != 0:
                        echo board.position.checkers
                of "quit":
                    return 0
                of "zobrist":
                    echo board.zobristKey.uint64
                of "rep":
                    echo "Position is drawn by repetition: ", if board.drawnByRepetition(): "yes" else: "no"
                of "eval":
                    echo &"Eval: {round(board.evaluate(state) / 100, 2)}"
                of "status":
                    if board.isStalemate():
                        echo "Draw by stalemate"
                    elif board.drawnByRepetition():
                        echo "Draw by repetition"
                    elif board.isDrawn():
                        echo "Draw"
                    elif board.isCheckmate():
                        echo &"{board.sideToMove.opposite()} wins by checkmate"
                    else:
                        echo "Game is not over"
                of "threats":
                    if board.position.threats != 0:
                        echo board.position.threats
                else:
                    echo &"Unknown command '{cmd[0]}'. Type 'help' for more information."
        except IOError:
            echo ""
            return 0
        except EOFError:
            echo ""
            return 0
    if startUCI:
        startUCISession()