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

## Implementation of a simple chessboard

import heimdallpkg/pieces
import heimdallpkg/magics
import heimdallpkg/moves
import heimdallpkg/rays
import heimdallpkg/bitboards
import heimdallpkg/position
import heimdallpkg/zobrist



export pieces, position, bitboards, moves, magics, rays, zobrist



type 
    Chessboard* = ref object
        ## A chessboard
        
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


func `$`*(self: Chessboard): string = $self.positions[^1]


func drawnByRepetition*(self: Chessboard, twofold: bool = false): bool {.inline.} =
    ## Returns whether the current position is a draw
    ## by repetition
    # TODO: Improve this
    var i = self.positions.high() - 1
    var count = 0
    while i >= 0:
        if self.positions[^1].zobristKey == self.positions[i].zobristKey:
            inc(count)
            if (twofold and count == 1) or count == 2:
                return true
        if self.positions[i].halfMoveClock == 0:
            # Position was reached via a pawn move or
            # capture: cannot repeat beyond this point!
            return false
        dec(i)


proc isInsufficientMaterial*(self: Chessboard): bool {.inline.} =
    ## Returns whether the current position is drawn
    ## due to insufficient mating material. Note that
    ## this is not a strict implementation of the FIDE
    ## rule about material draws due to the fact that
    ## it would be basically impossible to implement those
    ## efficiently
    
    # Break out early if there's more than 4 pieces on the
    # board
    let occupancy = self.positions[^1].getOccupancy()
    if occupancy.countSquares() > 4:
        return false

    # KvK is a draw
    if occupancy.countSquares() == 2:
        # Only the two kings are left
        return true

    let
        sideToMove = self.positions[^1].sideToMove
        nonSideToMove = sideToMove.opposite()

    # Break out early if there's any pawns left on the board
    if self.positions[^1].getBitboard(Pawn, sideToMove) != 0:
        return false
    if self.positions[^1].getBitboard(Pawn, nonSideToMove) != 0:
        return false

    # If there's any queens or rooks on the board, break out early too
    let 
        friendlyQueens = self.positions[^1].getBitboard(Queen, sideToMove)
        enemyQueens = self.positions[^1].getBitboard(Queen, nonSideToMove)
        friendlyRooks = self.positions[^1].getBitboard(Rook, sideToMove)
        enemyRooks = self.positions[^1].getBitboard(Rook, nonSideToMove)
    
    if (friendlyQueens or enemyQueens or friendlyRooks or enemyRooks).countSquares() != 0:
        return false

    # KNvK is a draw

    let knightCount = (self.positions[^1].getBitboard(Knight, sideToMove) or self.positions[^1].getBitboard(Knight, nonSideToMove)).countSquares()

    # More than one knight (doesn't matter which side), not a draw
    if knightCount > 1:
        return false

    # KBvK is a draw
    let bishopCount = (self.positions[^1].getBitboard(Bishop, sideToMove) or self.positions[^1].getBitboard(Bishop, nonSideToMove)).countSquares()

    if bishopCount + knightCount > 1:
        return false

    # Maybe TODO: KBBvK and KBvKB (these should be handled by search anyway)

    return true


func isDrawn*(self: Chessboard, twofold: bool = false): bool {.inline.} =
    ## Returns whether the given position is
    ## drawn
    if self.positions[^1].halfMoveClock >= 100:
        # Draw by 50 move rule
        return true

    if self.isInsufficientMaterial():
        return true

    if self.drawnByRepetition(twofold):
        return true


# Wrapper functions to make the chessboard marginally more
# useful (and so we don't have to type board.positions[^1]
# every time, which gets annoying after a while!)

func getPiece*(self: Chessboard, square: Square): Piece {.inline.} =
    ## Gets the piece at the given square in
    ## the position
    return self.positions[^1].getPiece(square)

func getPiece*(self: Chessboard, square: string): Piece {.inline.} =
    ## Gets the piece on the given square
    ## in algebraic notation
    return self.positions[^1].getPiece(square)

func getBitboard*(self: Chessboard, kind: PieceKind, color: PieceColor): Bitboard {.inline.} =
    ## Returns the positional bitboard for the given piece kind and color
    return self.positions[^1].getBitboard(kind, color)

func getBitboard*(self: Chessboard, piece: Piece): Bitboard {.inline.} =
    ## Returns the positional bitboard for the given piece
    return self.getBitboard(piece.kind, piece.color)

func getBitboard*(self: Chessboard, kind: PieceKind): Bitboard {.inline.} =
    ## Returns the positional bitboard for the given
    ## piece type, for both colors
    return self.positions[^1].getBitboard(kind)

func getMaterial*(self: Chessboard): int {.inline.} =
    ## Returns an integer representation of the
    ## material in the current position
    return self.positions[^1].getMaterial()

func getOccupancyFor*(self: Chessboard, color: PieceColor): Bitboard {.inline.} =
    ## Get the occupancy bitboard for every piece of the given color
    return self.positions[^1].getOccupancyFor(color)

func getOccupancy*(self: Chessboard): Bitboard {.inline.} =
    ## Get the occupancy bitboard for every piece on
    ## the chessboard
    return self.positions[^1].getOccupancy()

func pretty*(self: Chessboard): string =
    ## Returns a colored version of the
    ## current position for easier visualization
    return self.positions[^1].pretty()

proc toFEN*(self: Chessboard): string =
    ## Returns a FEN string of the current
    ## position in the chessboard
    return self.positions[^1].toFEN()

func sideToMove*(self: Chessboard): PieceColor {.inline.} =
    ## Returns the side to move in the
    ## current position
    return self.positions[^1].sideToMove

func zobristKey*(self: Chessboard): ZobristKey {.inline.} =
    ## Returns the zobrist key of the
    ## current position
    return self.positions[^1].zobristKey

func inCheck*(self: Chessboard): bool {.inline.} =
    ## Returns whether the current side
    ## to move is in check
    return self.positions[^1].inCheck()

func position*(self: Chessboard): Position {.inline.} =
    ## Returns the current position in the chessboard
    return self.positions[^1]

proc canCastle*(self: Chessboard): tuple[queen, king: Square] {.inline.} =
    ## Returns if the current side to move can castle
    return self.positions[^1].canCastle()
