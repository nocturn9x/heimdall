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

## Implements low-level bit operations

import std/sugar
import std/bitops
import std/strutils


import heimdall/moves
import heimdall/pieces


type
    Bitboard* = distinct uint64
        ## A bitboard

    Direction* = enum
        ## A move direction enumeration
        Forward = 0,
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
func countSetBits*(a: Bitboard): int {.borrow.}
func countLeadingZeroBits*(a: Bitboard): int {.borrow, inline.}
func countTrailingZeroBits*(a: Bitboard): int {.borrow, inline.}
func clearBit*(a: var Bitboard, bit: SomeInteger) {.borrow, inline.}
func setBit*(a: var Bitboard, bit: SomeInteger) {.borrow, inline.}
func clearBit*(a: var Bitboard, bit: Square) {.borrow, inline.}
func setBit*(a: var Bitboard, bit: Square) {.borrow, inline.}
func removed*(a, b: Bitboard): Bitboard {.inline.} = a and not b
func isEmpty*(self: Bitboard): bool {.inline.} = self == Bitboard(0)

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

func lowestBit*(self: Bitboard): Bitboard {.inline.} =
    ## Returns the least significant bit of the bitboard
    result = self and Bitboard(-cast[int64](self))


func getFileMask*(file: int): Bitboard {.inline.} = Bitboard(0x101010101010101'u64) shl file
func getRankMask*(rank: int): Bitboard {.inline.} = Bitboard(0xff) shl uint64(8 * rank)
func toBitboard*(square: SomeInteger): Bitboard {.inline.} = Bitboard(1'u64) shl square
func toBitboard*(square: Square): Bitboard {.inline.} = square.int8.toBitboard()
func toSquare*(b: Bitboard): Square {.inline.} = Square(b.countTrailingZeroBits())


func createMove*(startSquare: Bitboard, targetSquare: Square, flags: varargs[MoveFlag]): Move {.inline, noinit.} =
    result = createMove(startSquare.toSquare(), targetSquare, flags)


func createMove*(startSquare: Square, targetSquare: Bitboard, flags: varargs[MoveFlag]): Move {.inline, noinit.} =
    result = createMove(startSquare, targetSquare.toSquare(), flags)


func createMove*(startSquare, targetSquare: Bitboard, flags: varargs[MoveFlag]): Move {.inline, noinit.} =
    result = createMove(startSquare.toSquare(), targetSquare.toSquare(), flags)


func toBin*(x: Bitboard, b: Positive = 64): string {.inline.} = toBin(BiggestInt(x), b)
func toBin*(x: uint64, b: Positive = 64): string {.inline.} = toBin(Bitboard(x), b)
func contains*(self: Bitboard, square: Square): bool  {.inline.} = not (self and square.toBitboard()).isEmpty()


iterator items*(self: Bitboard): Square {.inline.} =
    ## Iterates ove the given bitboard
    ## and returns all the squares that 
    ## are set
    var bits = self
    while not bits.isEmpty():
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
        if subset.isEmpty():
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

func generateShifters: array[PieceColor.White..PieceColor.Black, array[Direction, (Bitboard {.noSideEffect.} -> Bitboard)]] {.compileTime.} =
    result[White][Forward] = (x: Bitboard) => x shr 8
    result[White][Backward] = (x: Bitboard) => x shl 8
    result[White][Left] = (x: Bitboard) => x shr 1
    result[White][Right] = (x: Bitboard) => x shl 1
    result[White][ForwardRight] = (x: Bitboard) => x shr 7
    result[White][ForwardLeft] = (x: Bitboard) => x shr 9
    result[White][BackwardRight] = (x: Bitboard) => x shl 9
    result[White][BackwardLeft] = (x: Bitboard) => x shl 7

    result[Black][Backward] = (x: Bitboard) => x shr 8
    result[Black][Forward] = (x: Bitboard) => x shl 8
    result[Black][Right] = (x: Bitboard) => x shr 1
    result[Black][Left] = (x: Bitboard) => x shl 1
    result[Black][BackwardLeft] = (x: Bitboard) => x shr 7
    result[Black][BackwardRight] = (x: Bitboard) => x shr 9
    result[Black][ForwardLeft] = (x: Bitboard) => x shl 9
    result[Black][ForwardRight] = (x: Bitboard) => x shl 7


const shifters: array[PieceColor.White..PieceColor.Black, array[Direction, (Bitboard) {.noSideEffect.} -> Bitboard]] = generateShifters()


func getDirectionMask*(bitboard: Bitboard, color: PieceColor, direction: Direction): Bitboard {.inline.} =
    ## Get a bitmask relative to the given bitboard 
    ## for the given direction for a piece of the 
    ## given color 
    return shifters[color][direction](bitboard)

const relativeRanks: array[PieceColor.White..PieceColor.Black, array[8, int]] = [[7, 6, 5, 4, 3, 2, 1, 0], [0, 1, 2, 3, 4, 5, 6, 7]]

func getRelativeRank*(color: PieceColor, rank: int): int {.inline.} = relativeRanks[color][rank]

const
    eighthRanks: array[PieceColor.White..PieceColor.Black, Bitboard] = [getRankMask(getRelativeRank(White, 7)), getRankMask(getRelativeRank(Black, 7))]
    firstRanks: array[PieceColor.White..PieceColor.Black, Bitboard] = [getRankMask(getRelativeRank(White, 0)), getRankMask(getRelativeRank(Black, 0))]
    secondRanks: array[PieceColor.White..PieceColor.Black, Bitboard] = [getRankMask(getRelativeRank(White, 1)), getRankMask(getRelativeRank(Black, 1))]
    seventhRanks: array[PieceColor.White..PieceColor.Black, Bitboard] = [getRankMask(getRelativeRank(White, 6)), getRankMask(getRelativeRank(Black, 6))]
    leftmostFiles: array[PieceColor.White..PieceColor.Black, Bitboard] = [getFileMask(0), getFileMask(7)]
    rightmostFiles: array[PieceColor.White..PieceColor.Black, Bitboard] = [getFileMask(7), getFileMask(0)]


func getEighthRank*(color: PieceColor): Bitboard {.inline.} = eighthRanks[color]
func getFirstRank*(color: PieceColor): Bitboard {.inline.} = firstRanks[color]
func getSeventhRank*(color: PieceColor): Bitboard {.inline.} = seventhRanks[color]
func getSecondRank*(color: PieceColor): Bitboard {.inline.} = secondRanks[color]
func getLeftmostFile*(color: PieceColor): Bitboard {.inline.}= leftmostFiles[color]
func getRightmostFile*(color: PieceColor): Bitboard {.inline.} = rightmostFiles[color]


func getDirectionMask*(square: Square, color: PieceColor, direction: Direction): Bitboard {.inline.} =
    ## Get a bitmask for the given direction for a piece
    ## of the given color located at the given square
    result = getDirectionMask(square.toBitboard(), color, direction)


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


func computePawnAttackers(color: PieceColor): array[Square(0)..Square(63), Bitboard] {.compileTime.} =
    ## Precomputes all the attacker bitboards for pawns
    ## of the given color
    for i in Square(0)..Square(63):
        let pawn = i.toBitboard()
        result[i] = pawn.backwardLeftRelativeTo(color) or pawn.backwardRightRelativeTo(color)


func computePawnAttacks(color: PieceColor): array[Square(0)..Square(63), Bitboard] {.compileTime.} =
    ## Precomputes all the attack bitboards for pawns
    ## of the given color
    for i in Square(0)..Square(63):
        let pawn = i.toBitboard()
        result[i] = pawn.forwardLeftRelativeTo(color) or pawn.forwardRightRelativeTo(color)


const 
    KING_BITBOARDS = computeKingBitboards()
    KNIGHT_BITBOARDS = computeKnightBitboards()
    PAWN_ATTACKERS: array[White..Black, array[Square(0)..Square(63), Bitboard]] = [computePawnAttackers(White), computePawnAttackers(Black)]
    PAWN_ATTACKS: array[White..Black, array[Square(0)..Square(63), Bitboard]] = [computePawnAttacks(White), computePawnAttacks(Black)]


func getKingMoves*(square: Square): Bitboard {.inline.} = KING_BITBOARDS[square]
func getKnightMoves*(square: Square): Bitboard {.inline.} = KNIGHT_BITBOARDS[square]
func getPawnAttackers*(color: PieceColor, square: Square): Bitboard {.inline.} = PAWN_ATTACKERS[color][square]
func getPawnAttacks*(color: PieceColor, square: Square): Bitboard {.inline.} = PAWN_ATTACKS[color][square]
