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

## Implements low-level bit operations


import std/bitops
import std/strutils


import pieces
import moves


type
    Bitboard* = distinct uint64
        ## A bitboard

    Direction* = enum
        ## A move direction enumeration
        Forward,
        Backward,
        Left,
        Right
        ForwardLeft,
        ForwardRight,
        BackwardLeft,
        BackwardRight

# Overloaded operators and functions for our bitboard type
func `shl`*(a: Bitboard, x: Natural): Bitboard {.borrow, inline.}
func `shr`*(a: Bitboard, x: Natural): Bitboard {.borrow, inline.}
func `and`*(a, b: Bitboard): Bitboard {.borrow, inline.}
func `or`*(a, b: Bitboard): Bitboard {.borrow, inline.}
func `not`*(a: Bitboard): Bitboard {.borrow, inline.}
func `shr`*(a, b: Bitboard): Bitboard {.borrow, inline.}
func `xor`*(a, b: Bitboard): Bitboard {.borrow, inline.}
func `+`*(a, b: Bitboard): Bitboard {.borrow, inline.}
func `-`*(a, b: Bitboard): Bitboard {.borrow, inline.}
func `div`*(a, b: Bitboard): Bitboard {.borrow, inline.}
func `*`*(a, b: Bitboard): Bitboard {.borrow, inline.}
func `+`*(a: Bitboard, b: SomeUnsignedInt): Bitboard {.borrow, inline.}
func `-`*(a: Bitboard, b: SomeUnsignedInt): Bitboard {.borrow, inline.}
func `div`*(a: Bitboard, b: SomeUnsignedInt): Bitboard {.borrow, inline.}
func `*`*(a: Bitboard, b: SomeUnsignedInt): Bitboard {.borrow, inline.}
func `*`*(a: SomeUnsignedInt, b: Bitboard): Bitboard {.borrow, inline.}
func `==`*(a, b: Bitboard): bool {.inline, borrow.}
func `==`*(a: Bitboard, b: SomeInteger): bool {.inline.} = a.uint64 == b.uint64
func `!=`*(a, b: Bitboard): bool {.inline.} = a.uint64 != b.uint64
func `!=`*(a: Bitboard, b: SomeInteger): bool {.inline.} = a.uint64 != b.uint64
func countSetBits*(a: Bitboard): int = a.uint64.countSetBits()
func countLeadingZeroBits*(a: Bitboard): int {.borrow, inline.}
func countTrailingZeroBits*(a: Bitboard): int {.borrow, inline.}
func clearBit*(a: var Bitboard, bit: SomeInteger) {.borrow, inline.}
func setBit*(a: var Bitboard, bit: SomeInteger) {.borrow, inline.}
func clearBit*(a: var Bitboard, bit: Square) {.borrow, inline.}
func setBit*(a: var Bitboard, bit: Square) {.borrow, inline.}
func removed*(a, b: Bitboard): Bitboard {.inline.} = a and not b


func countSquares*(self: Bitboard): int {.inline.} =
    ## Returns the number of active squares
    ## in the bitboard
    result = self.countSetBits()


func lowestSquare*(self: Bitboard): Square {.inline.} =
    ## Returns the index of the lowest set bit
    ## in the given bitboard as a square
    result = Square(self.countTrailingZeroBits().uint8)


func highestSquare*(self: Bitboard): Square {.inline.} =
    ## Returns the index of the highest set bit
    ## in the given bitboard as a square
    result = Square(self.countLeadingZeroBits().uint8 xor 0x3f)


func getFileMask*(file: int): Bitboard {.inline.} = Bitboard(0x101010101010101'u64) shl file.uint64
func getRankMask*(rank: int): Bitboard {.inline.} = Bitboard(0xff) shl uint64(8 * rank)
func toBitboard*(square: SomeInteger): Bitboard {.inline.} = Bitboard(1'u64) shl square.uint64
func toBitboard*(square: Square): Bitboard {.inline.} = toBitboard(square.int8)
func toSquare*(b: Bitboard): Square {.inline.} = Square(b.uint64.countTrailingZeroBits())


func createMove*(startSquare: Bitboard, targetSquare: Square, flags: varargs[MoveFlag]): Move {.inline, noinit.} =
    result = createMove(startSquare.toSquare(), targetSquare, flags)


func createMove*(startSquare: Square, targetSquare: Bitboard, flags: varargs[MoveFlag]): Move {.inline, noinit.} =
    result = createMove(startSquare, targetSquare.toSquare(), flags)


func createMove*(startSquare, targetSquare: Bitboard, flags: varargs[MoveFlag]): Move {.inline, noinit.} =
    result = createMove(startSquare.toSquare(), targetSquare.toSquare(), flags)


func toBin*(x: Bitboard, b: Positive = 64): string {.inline.} = toBin(BiggestInt(x), b)
func toBin*(x: uint64, b: Positive = 64): string {.inline.} = toBin(Bitboard(x), b)
func contains*(self: Bitboard, square: Square): bool  {.inline.} = (self and square.toBitboard()) != 0


iterator items*(self: Bitboard): Square {.inline.} =
    ## Iterates ove the given bitboard
    ## and returns all the squares that 
    ## are set
    var bits = self
    while bits != 0:
        yield bits.toSquare()
        bits = bits and bits - 1


iterator subsets*(self: Bitboard): Bitboard =
    ## Iterates over all the subsets of the given
    ## bitboard using the Carry-Rippler trick

    # Thanks analog-hors :D
    var subset = Bitboard(0)
    while true:
        subset = (subset - self) and self
        yield subset
        if subset == 0:
            break


iterator pairs*(self: Bitboard): tuple[i: int, sq: Square] =
    var i = 0
    for item in self:
        yield (i, item)
        inc(i)


func pretty*(self: Bitboard): string =

    iterator items(self: Bitboard): uint8 =
        ## Iterates over all the bits in the
        ## given bitboard
        for i in 0..63:
            yield self.uint64.bitsliced(i..i).uint8


    iterator pairs(self: Bitboard): (int, uint8) =
        var i = 0
        for bit in self:
            yield (i, bit)
            inc(i)

    ## Returns a prettyfied version of
    ## the given bitboard
    result &= "- - - - - - - -\n"
    for i, bit in self:
        if i > 0 and i mod 8 == 0:
            result &= "\n"
        result &= $bit & " "
    result &= "\n- - - - - - - -"


func `$`*(self: Bitboard): string {.inline.} = self.pretty()


func getDirectionMask*(bitboard: Bitboard, color: PieceColor, direction: Direction): Bitboard {.inline.} =
    ## Get a bitmask relative to the given bitboard 
    ## for the given direction for a piece of the 
    ## given color 
    case color:
        of White:
            case direction:
                of Forward:
                    return bitboard shr 8
                of Backward:
                    return bitboard shl 8
                of ForwardRight:
                    return bitboard shr 7
                of ForwardLeft:
                    return bitboard shr 9
                of BackwardRight:
                    return bitboard shl 9
                of BackwardLeft:
                    return bitboard shl 7
                of Left:
                    return bitboard shr 1
                of Right:
                    return bitboard shl 1
        of Black:
            case direction:
                of Forward:
                    return bitboard shl 8
                of Backward:
                    return bitboard shr 8
                of ForwardRight:
                    return bitboard shl 7
                of ForwardLeft:
                    return bitboard shl 9
                of BackwardRight:
                    return bitboard shr 9
                of BackwardLeft:
                    return bitboard shr 7
                of Left:
                    return bitboard shl 1
                of Right:
                    return bitboard shr 1
        else:
            discard


func getEighthRank*(color: PieceColor): Bitboard {.inline.} = (if color == White: getRankMask(0) else: getRankMask(7))
func getFirstRank*(color: PieceColor): Bitboard {.inline.} = (if color == White: getRankMask(7) else: getRankMask(0))
func getSeventhRank*(color: PieceColor): Bitboard {.inline.} = (if color == White: getRankMask(1) else: getRankMask(6))
func getSecondRank*(color: PieceColor): Bitboard {.inline.} = (if color == White: getRankMask(6) else: getRankMask(1))
func getLeftmostFile*(color: PieceColor): Bitboard {.inline.}= (if color == White: getFileMask(0) else: getFileMask(7))
func getRightmostFile*(color: PieceColor): Bitboard {.inline.} = (if color == White: getFileMask(7) else: getFileMask(0))


func getDirectionMask*(square: Square, color: PieceColor, direction: Direction): Bitboard {.inline.} =
    ## Get a bitmask for the given direction for a piece
    ## of the given color located at the given square
    result = getDirectionMask(toBitboard(square), color, direction)


func forwardRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = getDirectionMask(self, side, Forward)
func doubleForwardRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = self.forwardRelativeTo(side).forwardRelativeTo(side)

func backwardRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = getDirectionMask(self, side, Backward)
func doubleBackwardRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = self.backwardRelativeTo(side).backwardRelativeTo(side)

func leftRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = getDirectionMask(self, side, Left) and not getRightmostFile(side)
func rightRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = getDirectionMask(self, side, Right) and not getLeftmostFile(side)


# We mask off the opposite files to make sure there are
# no weird wraparounds when moving at the edges
func forwardRightRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = 
    getDirectionMask(self, side, ForwardRight) and not getLeftmostFile(side)


func forwardLeftRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = 
    getDirectionMask(self, side, ForwardLeft) and not getRightmostFile(side)


func backwardRightRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} =
    getDirectionMask(self, side, BackwardRight) and not getLeftmostFile(side)


func backwardLeftRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} =
    getDirectionMask(self, side, BackwardLeft) and not getRightmostFile(side)


func longKnightUpLeftRelativeTo*(self: Bitboard, side: PieceColor): Bitboard  {.inline.} = self.doubleForwardRelativeTo(side).leftRelativeTo(side)
func longKnightUpRightRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = self.doubleForwardRelativeTo(side).rightRelativeTo(side)
func longKnightDownLeftRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = self.doubleBackwardRelativeTo(side).leftRelativeTo(side)
func longKnightDownRightRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = self.doubleBackwardRelativeTo(side).rightRelativeTo(side)

func shortKnightUpLeftRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = self.forwardRelativeTo(side).leftRelativeTo(side).leftRelativeTo(side)
func shortKnightUpRightRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = self.forwardRelativeTo(side).rightRelativeTo(side).rightRelativeTo(side)
func shortKnightDownLeftRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = self.backwardRelativeTo(side).leftRelativeTo(side).leftRelativeTo(side)
func shortKnightDownRightRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = self.backwardRelativeTo(side).rightRelativeTo(side).rightRelativeTo(side)

# We precompute as much stuff as possible: lookup tables are fast!


func computeKingBitboards: array[Square(0)..Square(63), Bitboard] {.compileTime.} =
    ## Precomputes all the movement bitboards for the king
    for i in Square(0)..Square(63):
        let king = i.toBitboard()
        # It doesn't really matter which side we generate
        # the move for, they're identical for both
        var movements = king.forwardRelativeTo(White)
        movements = movements or king.forwardLeftRelativeTo(White)
        movements = movements or king.leftRelativeTo(White)
        movements = movements or king.rightRelativeTo(White)
        movements = movements or king.backwardRelativeTo(White)
        movements = movements or king.forwardRightRelativeTo(White)
        movements = movements or king.backwardRightRelativeTo(White)
        movements = movements or king.backwardLeftRelativeTo(White)
        # We don't *need* to mask the king off: the engine already masks off
        # the board's occupancy when generating moves, but it may be useful for
        # other parts of the movegen for this stuff not to say "the king can just
        # stay still", so we do it anyway
        movements = movements and not king
        result[i] = movements


func computeKnightBitboards: array[Square(0)..Square(63), Bitboard] {.compileTime.} =
    ## Precomputes all the movement bitboards for knights
    for i in Square(0)..Square(63):
        let knight = i.toBitboard()
        # It doesn't really matter which side we generate
        # the move for, they're identical for both
        var movements = knight.longKnightDownLeftRelativeTo(White)
        movements = movements or knight.longKnightDownRightRelativeTo(White)
        movements = movements or knight.longKnightUpLeftRelativeTo(White)
        movements = movements or knight.longKnightUpRightRelativeTo(White)
        movements = movements or knight.shortKnightDownLeftRelativeTo(White)
        movements = movements or knight.shortKnightDownRightRelativeTo(White)
        movements = movements or knight.shortKnightUpLeftRelativeTo(White)
        movements = movements or knight.shortKnightUpRightRelativeTo(White)
        movements = movements and not knight
        result[i] = movements


func computePawnAttacks(color: PieceColor): array[Square(0)..Square(63), Bitboard] {.compileTime.} =
    ## Precomputes all the attack bitboards for pawns
    ## of the given color
    for i in Square(0)..Square(63):
        let pawn = i.toBitboard()
        result[i] = pawn.backwardLeftRelativeTo(color) or pawn.backwardRightRelativeTo(color)


func computePassedPawnMasks(color: PieceColor): array[Square(0)..Square(63), Bitboard] = 
    ## Precomputes all the masks for passed pawns of the
    ## given color
    for square in Square(0)..Square(63):
        let file = fileFromSquare(square)
        let rank = rankFromSquare(square)
        result[square] = getFileMask(file)
        if file + 1 in 0..7:
            result[square] = result[square] or (getFileMask(file + 1))
        if file - 1 in 0..7:
            result[square] = result[square] or (getFileMask(file - 1))
        if color == White:
            result[square] = result[square] shr (8 * (7 - rank))
        else:
            result[square] = result[square] shl (8 * (rank))
        result[square] = result[square] and not getRankMask(0)
        result[square] = result[square] and not getRankMask(7)


func computeIsolatedPawnMasks: array[8, Bitboard] {.compileTime.} =
    ## Computes all the masks for isolated pawns
    for file in 0..7:
        if file - 1 in 0..7:
            result[file] = result[file] or getFileMask(file - 1)
        if file + 1 in 0..7:
            result[file] = result[file] or getFileMask(file + 1)
        result[file] = result[file] and not getRankMask(0)
        result[file] = result[file] and not getRankMask(7)


func computeKingZoneMasks(color: PieceColor): array[64, Bitboard] {.compileTime.} =
    ## Computes the king zone masks for the given
    ## color at compile time
    for square in Square(0)..Square(63):
        let squareBB = square.toBitboard()
        # Front side
        result[square.int] = squareBB.forwardRelativeTo(color) or squareBB.forwardLeftRelativeTo(color) or squareBB.forwardRightRelativeTo(color)
        # Back side
        result[square.int] = result[square.int] or (squareBB.backwardRelativeTo(color) or squareBB.backwardLeftRelativeTo(color) or squareBB.backwardRightRelativeTo(color))
        # Flanks
        result[square.int] = result[square.int] or (squareBB.leftRelativeTo(color) or squareBB.rightRelativeTo(color))


const 
    KING_BITBOARDS = computeKingBitboards()
    KNIGHT_BITBOARDS = computeKnightBitboards()
    PAWN_ATTACKS: array[White..Black, array[Square(0)..Square(63), Bitboard]] = [computePawnAttacks(White), computePawnAttacks(Black)]
    KING_ZONE_MASKS: array[White..Black, array[Square(0)..Square(63), Bitboard]] = [computeKingZoneMasks(White),
                                                                                                                 computeKingZoneMasks(Black)]
    ISOLATED_PAWNS = computeIsolatedPawnMasks()

let PASSED_PAWNS: array[White..Black, array[Square(0)..Square(63), Bitboard]] = [computePassedPawnMasks(White), computePassedPawnMasks(Black)]


func getKingAttacks*(square: Square): Bitboard {.inline.} = KING_BITBOARDS[square]
func getKnightAttacks*(square: Square): Bitboard {.inline.} = KNIGHT_BITBOARDS[square]
func getPawnAttacks*(color: PieceColor, square: Square): Bitboard {.inline.} = PAWN_ATTACKS[color][square]
proc getPassedPawnMask*(color: PieceColor, square: Square): Bitboard {.inline.} = PASSED_PAWNS[color][square]
proc getKingZoneMask*(color: PieceColor, square: Square): Bitboard {.inline.} = KING_ZONE_MASKS[color][square]
func getIsolatedPawnMask*(file: int): Bitboard {.inline.} = ISOLATED_PAWNS[file]
