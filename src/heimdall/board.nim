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

import heimdall/pieces
import heimdall/util/magics
import heimdall/moves
import heimdall/util/rays
import heimdall/bitboards
import heimdall/position
import heimdall/util/zobrist



export pieces, position, bitboards, moves, magics, rays, zobrist


type 
    Chessboard* = ref object
        ## A wrapper over a stack of positions
        
        # List of all reached positions
        positions*: seq[Position]


proc toFEN*(self: Chessboard): string


proc newChessboardFromFEN*(fen: string): Chessboard =
    ## Initializes a chessboard with the
    ## position encoded by the given FEN string
    new(result)
    result.positions.add(loadFEN(fen))


proc newDefaultChessboard*: Chessboard {.inline.} =
    ## Initializes a chessboard with the
    ## starting position
    return newChessboardFromFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")


proc newChessboard*(positions: seq[Position]): Chessboard =
    ## Initializes a new chessboard from the given
    ## set of positions
    new(result)
    for position in positions:
        result.positions.add(position.clone())


func position*(self: Chessboard): lent Position {.inline.} =
    ## Returns the current position in the chessboard
    ## without explicitly copying it
    return self.positions[^1]


func `$`*(self: Chessboard): string = $self.position


func drawnByRepetition*(self: Chessboard, ply: int): bool {.inline.} =
    ## Returns whether the current position is a draw
    ## by repetition
    let clock = self.positions[^1].halfMoveClock.int
    if clock < 4:
        # Can only repeat after 4 plies
        return false
    
    var ply = ply - 4
    var count = 0
    let key = self.positions[^1].zobristKey
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


proc isInsufficientMaterial*(self: Chessboard): bool {.inline.} =
    ## Returns whether the current position is drawn
    ## due to insufficient mating material. Note that
    ## this is not a strict implementation of the FIDE
    ## rule about material draws due to the fact that
    ## it would be basically impossible to implement those
    ## efficiently
    
    # Break out early if there's more than 4 pieces on the
    # board
    let occupancy = self.position.getOccupancy()
    if occupancy.countSquares() > 4:
        return false

    # KvK is a draw
    if occupancy.countSquares() == 2:
        # Only the two kings are left
        return true

    let
        sideToMove = self.position.sideToMove
        nonSideToMove = sideToMove.opposite()

    # Break out early if there's any pawns left on the board
    if not self.position.getBitboard(Pawn, sideToMove).isEmpty():
        return false
    if not self.position.getBitboard(Pawn, nonSideToMove).isEmpty():
        return false

    # If there's any queens or rooks on the board, break out early too
    let 
        friendlyQueens = self.position.getBitboard(Queen, sideToMove)
        enemyQueens = self.position.getBitboard(Queen, nonSideToMove)
        friendlyRooks = self.position.getBitboard(Rook, sideToMove)
        enemyRooks = self.position.getBitboard(Rook, nonSideToMove)
    
    if not (friendlyQueens or enemyQueens or friendlyRooks or enemyRooks).isEmpty():
        return false

    # KNvK is a draw

    let knightCount = (self.position.getBitboard(Knight, sideToMove) or self.position.getBitboard(Knight, nonSideToMove)).countSquares()

    # More than one knight (doesn't matter which side), not a draw
    if knightCount > 1:
        return false

    # KBvK is a draw
    let bishopCount = (self.position.getBitboard(Bishop, sideToMove) or self.position.getBitboard(Bishop, nonSideToMove)).countSquares()

    if bishopCount + knightCount > 1:
        return false

    # Maybe TODO: KBBvK and KBvKB (these should be handled by search anyway)

    return true


# Wrapper functions to make the chessboard marginally more
# useful (and so we don't have to type board.positions[^1]
# every time, which gets annoying after a while!)

func getPiece*(self: Chessboard, square: Square): Piece {.inline.} =
    ## Gets the piece at the given square in
    ## the position
    return self.position.getPiece(square)

func getPiece*(self: Chessboard, square: string): Piece {.inline.} =
    ## Gets the piece on the given square
    ## in UCI notation
    return self.position.getPiece(square)

func getBitboard*(self: Chessboard, kind: PieceKind, color: PieceColor): Bitboard {.inline.} =
    ## Returns the positional bitboard for the given piece kind and color
    return self.position.getBitboard(kind, color)

func getBitboard*(self: Chessboard, piece: Piece): Bitboard {.inline.} =
    ## Returns the positional bitboard for the given piece
    return self.getBitboard(piece.kind, piece.color)

func getBitboard*(self: Chessboard, kind: PieceKind): Bitboard {.inline.} =
    ## Returns the positional bitboard for the given
    ## piece type, for both colors
    return self.position.getBitboard(kind)

func getMaterial*(self: Chessboard): int {.inline.} =
    ## Returns an integer representation of the
    ## material in the current position
    return self.position.getMaterial()

func getOccupancyFor*(self: Chessboard, color: PieceColor): Bitboard {.inline.} =
    ## Get the occupancy bitboard for every piece of the given color
    return self.position.getOccupancyFor(color)

func getOccupancy*(self: Chessboard): Bitboard {.inline.} =
    ## Get the occupancy bitboard for every piece on
    ## the chessboard
    return self.position.getOccupancy()

func pretty*(self: Chessboard): string =
    ## Returns a colored version of the
    ## current position for easier visualization
    return self.position.pretty()

proc toFEN*(self: Chessboard): string =
    ## Returns a FEN string of the current
    ## position in the chessboard
    return self.position.toFEN()

func sideToMove*(self: Chessboard): PieceColor {.inline.} =
    ## Returns the side to move in the
    ## current position
    return self.position.sideToMove

func zobristKey*(self: Chessboard): ZobristKey {.inline.} =
    ## Returns the zobrist key of the
    ## current position
    return self.position.zobristKey

func pawnKey*(self: Chessboard): ZobristKey {.inline.} =
    ## Returns the pawn key of the
    ## current position
    return self.positions[^1].pawnKey

func nonpawnKey*(self: Chessboard, side: PieceColor): ZobristKey {.inline.} =
    ## Returns the pawn key of the
    ## current position
    return self.positions[^1].nonpawnKeys[side]

func majorKey*(self: Chessboard): ZobristKey {.inline.} =
    ## Returns the major key of the
    ## current position
    return self.positions[^1].majorKey

func minorKey*(self: Chessboard): ZobristKey {.inline.} =
    ## Returns the major key of the
    ## current position
    return self.positions[^1].minorKey

func inCheck*(self: Chessboard): bool {.inline.} =
    ## Returns whether the current side
    ## to move is in check
    return self.position.inCheck()

proc canCastle*(self: Chessboard): tuple[queen, king: Square] {.inline.} =
    ## Returns if the current side to move can castle
    return self.position.canCastle()
