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

import heimdall/[moves, movegen, pieces]

import std/strformat


type PerftData* = tuple[nodes: uint64, captures: uint64, castles: uint64, checks: uint64,  promotions: uint64, enPassant: uint64, checkmates: uint64]


proc perft*(board: Chessboard, ply: int, verbose = false, divide = false, bulk = false, capturesOnly = false): PerftData =
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
                echo &"{move.toUCI()}: 1"
                if verbose:
                    echo ""
        return (uint64(len(moves)), 0, 0, 0, 0, 0, 0)

    for move in moves:
        if verbose:
            let canCastle = board.canCastle()
            echo &"Move: {move.startSquare.toUCI()}{move.targetSquare.toUCI()}"
            echo &"Turn: {board.sideToMove}"
            echo &"Piece: {board.position.on(move.startSquare).kind}"
            echo &"Flag: {move.flag()}"
            echo &"In check: {(if board.inCheck(): \"yes\" else: \"no\")}"
            echo &"Castling targets:\n  - King side: {(if canCastle.king != nullSquare(): canCastle.king.toUCI() else: \"None\")}\n  - Queen side: {(if canCastle.queen != nullSquare(): canCastle.queen.toUCI() else: \"None\")}"
            echo &"Position before move: {board.toFEN()}"
            echo &"Hash: {board.zobristKey}"
            stdout.write("En Passant target: ")
            if board.position.enPassantSquare != nullSquare():
                echo board.position.enPassantSquare.toUCI()
            else:
                echo "None"
            echo "\n", board.pretty()
        board.doMove(move)
        when not defined(danger):
            let incHash = board.zobristKey
            let pawnKey = board.pawnKey
            board.positions[^1].hash()
            doAssert board.zobristKey == incHash, &"{board.zobristKey} != {incHash} at {move} ({board.positions[^2].toFEN()})"
            doAssert board.pawnKey == pawnKey, &"{board.pawnKey} != {pawnKey} at {move} ({board.positions[^2].toFEN()})"
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
            echo &"Opponent castling targets:\n  - King side: {(if canCastle.king != nullSquare(): canCastle.king.toUCI() else: \"None\")}\n  - Queen side: {(if canCastle.queen != nullSquare(): canCastle.queen.toUCI() else: \"None\")}"
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
            echo &"{move.toUCI()}: {next.nodes}"
            if verbose:
                echo ""
        result.nodes += next.nodes
        result.captures += next.captures
        result.checks += next.checks
        result.promotions += next.promotions
        result.castles += next.castles
        result.enPassant += next.enPassant
        result.checkmates += next.checkmates