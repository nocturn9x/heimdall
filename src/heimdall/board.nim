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

## Implementation of a simple chessboard

import heimdall/[pieces, moves, bitboards, position]
import heimdall/util/[magics, rays, zobrist]



export pieces, position, bitboards, moves, magics, rays, zobrist


type
    Chessboard* = ref object
        ## A wrapper over a stack of positions

        # List of all reached positions
        positions*: seq[Position]


proc newChessboardFromFEN*(fen: string): Chessboard =
    new(result)
    result.positions.add(fromFEN(fen))


proc newDefaultChessboard*: Chessboard {.inline.} =
    return newChessboardFromFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")


proc newChessboard*(positions: seq[Position]): Chessboard =
    new(result)
    for position in positions:
        result.positions.add(position.clone())


func position*(self: Chessboard): lent Position {.inline.} =
    ## Returns the current position in
    ## the chessboard *without* copying
    ## it
    return self.positions[^1]


func `$`*(self: Chessboard): string {.inline.} = $self.position

func on*(self: Chessboard, square: Square): Piece {.inline.} =
    return self.position.on(square)

func on*(self: Chessboard, square: string): Piece {.inline.} =
    return self.position.on(square)

func pieces*(self: Chessboard, kind: PieceKind, color: PieceColor): Bitboard {.inline.} =
    return self.position.pieces(kind, color)

func pieces*(self: Chessboard, piece: Piece): Bitboard {.inline.} =
    return self.pieces(piece.kind, piece.color)

func pieces*(self: Chessboard, kind: PieceKind): Bitboard {.inline.} =
    return self.position.pieces(kind)

func material*(self: Chessboard): int {.inline.} =
    return self.position.material()

func pieces*(self: Chessboard, color: PieceColor): Bitboard {.inline.} =
    return self.position.pieces(color)

func pieces*(self: Chessboard): Bitboard {.inline.} =
    return self.position.pieces()

func pretty*(self: Chessboard): string =
    return self.position.pretty()

proc toFEN*(self: Chessboard): string =
    return self.position.toFEN()

func sideToMove*(self: Chessboard): PieceColor {.inline.} =
    return self.position.sideToMove

func halfMoveClock*(self: Chessboard): uint16 {.inline.} =
    return self.position.halfMoveClock

func zobristKey*(self: Chessboard): ZobristKey {.inline.} =
    return self.position.zobristKey

func pawnKey*(self: Chessboard): ZobristKey {.inline.} =
    return self.positions[^1].pawnKey

func nonpawnKey*(self: Chessboard, side: PieceColor): ZobristKey {.inline.} =
    return self.positions[^1].nonpawnKeys[side]

func majorKey*(self: Chessboard): ZobristKey {.inline.} =
    return self.positions[^1].majorKey

func minorKey*(self: Chessboard): ZobristKey {.inline.} =
    return self.positions[^1].minorKey

func inCheck*(self: Chessboard): bool {.inline.} =
    return self.position.inCheck()

proc canCastle*(self: Chessboard): tuple[queen, king: Square] {.inline.} =
    return self.position.canCastle()


proc isInsufficientMaterial*(self: Chessboard): bool {.inline.} =
    ## Returns whether the current position is drawn
    ## due to insufficient mating material. Note that
    ## this is not a strict implementation of the FIDE
    ## rule about material draws due to the fact that
    ## it would be basically impossible to implement
    ## those efficiently

    # Break out early if there's more than 4 pieces on the
    # board
    let occupancy = self.position.pieces()
    if occupancy.count() > 4:
        return false

    # KvK is a draw
    if occupancy.count() == 2:
        # Only the two kings can be left
        return true

    let
        sideToMove = self.position.sideToMove
        nonSideToMove = sideToMove.opposite()

    # Break out early if there's any pawns left on the board
    if not self.position.pieces(Pawn, sideToMove).isEmpty():
        return false
    if not self.position.pieces(Pawn, nonSideToMove).isEmpty():
        return false

    # If there's any queens or rooks on the board, break out early too
    let
        friendlyQueens = self.position.pieces(Queen, sideToMove)
        enemyQueens = self.position.pieces(Queen, nonSideToMove)
        friendlyRooks = self.position.pieces(Rook, sideToMove)
        enemyRooks = self.position.pieces(Rook, nonSideToMove)

    if not (friendlyQueens or enemyQueens or friendlyRooks or enemyRooks).isEmpty():
        return false

    # KNvK is a draw

    let knightCount = (self.position.pieces(Knight, sideToMove) or self.position.pieces(Knight, nonSideToMove)).count()

    # More than one knight (doesn't matter which side), not a draw
    if knightCount > 1:
        return false

    # KBvK is a draw
    let bishopCount = (self.position.pieces(Bishop, sideToMove) or self.position.pieces(Bishop, nonSideToMove)).count()

    if bishopCount + knightCount > 1:
        return false

    # Maybe TODO: KBBvK and KBvKB (these should be handled by search anyway)

    return true


func drawnByRepetition*(self: Chessboard, ply: int): bool {.inline.} =
    let clock = self.halfMoveClock.int
    if clock < 4:
        # Can only repeat after 4 plies
        return false

    var ply = ply - 4
    var count = 0
    let key = self.zobristKey
    for i in countdown(max(0, self.positions.high() - 4), max(0, self.positions.high() - clock)):
        if self.positions[i].zobristKey == key:
            inc(count)
        # Require threefold repetition if it occurs
        # before root
        if count == 1 + (ply < 0).int:
            return true
        if self.positions[i].halfMoveClock == 0:
            return false
        dec(ply, 2)
    return false