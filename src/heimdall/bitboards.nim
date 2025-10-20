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

import std/[sugar, bitops, strutils]

import heimdall/[moves, pieces]


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
func countSetBits*(a: Bitboard): int {.borrow.}
func countLeadingZeroBits(a: Bitboard): int {.borrow, inline.}
func countTrailingZeroBits(a: Bitboard): int {.borrow, inline.}
func clearBit*(a: var Bitboard, bit: SomeInteger) {.borrow, inline.}
func setBit*(a: var Bitboard, bit: SomeInteger) {.borrow, inline.}

func `==`*(a: Bitboard, b: SomeInteger): bool   {.inline.} = a.uint64 == b.uint64
func `!=`*(a, b: Bitboard): bool                {.inline.} = a.uint64 != b.uint64
func `!=`*(a: Bitboard, b: SomeInteger): bool   {.inline.} = a.uint64 != b.uint64
func clearBit*(a: var Bitboard, bit: Square)    {.inline.} = a.clearBit(bit.uint8)
func setBit*(a: var Bitboard, bit: Square)      {.inline.} = a.setBit(bit.uint8)
func removed*(a, b: Bitboard): Bitboard         {.inline.} = a and not b
func isEmpty*(self: Bitboard): bool             {.inline.} = self == Bitboard(0)
func count*(self: Bitboard): int                {.inline.} = self.countSetBits()
func lowestSquare*(self: Bitboard): Square      {.inline.} = Square(self.countTrailingZeroBits().uint8)
func highestSquare*(self: Bitboard): Square     {.inline.} = Square(self.countLeadingZeroBits().uint8 xor 0x3f)
func fileMask*(file: pieces.File): Bitboard     {.inline.} = Bitboard(0x101010101010101'u64) shl file.uint8
func rankMask*(rank: Rank): Bitboard            {.inline.} = Bitboard(0xff) shl uint64(8 * rank.uint8)
func toBitboard*(square: SomeInteger): Bitboard {.inline.} = Bitboard(1'u64) shl square
func toBitboard*(square: Square): Bitboard      {.inline.} = square.int8.toBitboard()
func toSquare*(b: Bitboard): Square             {.inline.} = Square(b.countTrailingZeroBits())

func lowestBit*(self: Bitboard): Bitboard {.inline.} =
    {.push overflowChecks:off.}
    result = self and Bitboard(-cast[int64](self))
    {.pop.}


func createMove*(startSquare: Bitboard, targetSquare: Square, flag: MoveFlag = Normal): Move {.inline, noinit.} =
    result = createMove(startSquare.toSquare(), targetSquare, flag)


func createMove*(startSquare: Square, targetSquare: Bitboard, flag: MoveFlag = Normal): Move {.inline, noinit.} =
    result = createMove(startSquare, targetSquare.toSquare(), flag)


func createMove*(startSquare, targetSquare: Bitboard, flag: MoveFlag = Normal): Move {.inline, noinit.} =
    result = createMove(startSquare.toSquare(), targetSquare.toSquare(), flag)


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

func generateShifters: array[White..Black, array[Direction, (Bitboard {.noSideEffect.} -> Bitboard)]] {.compileTime.} =
    result[White][Forward]       = (x: Bitboard) => x shr 8
    result[White][Backward]      = (x: Bitboard) => x shl 8
    result[White][Left]          = (x: Bitboard) => x shr 1
    result[White][Right]         = (x: Bitboard) => x shl 1
    result[White][ForwardRight]  = (x: Bitboard) => x shr 7
    result[White][ForwardLeft]   = (x: Bitboard) => x shr 9
    result[White][BackwardRight] = (x: Bitboard) => x shl 9
    result[White][BackwardLeft]  = (x: Bitboard) => x shl 7

    result[Black][Backward]      = (x: Bitboard) => x shr 8
    result[Black][Forward]       = (x: Bitboard) => x shl 8
    result[Black][Right]         = (x: Bitboard) => x shr 1
    result[Black][Left]          = (x: Bitboard) => x shl 1
    result[Black][BackwardLeft]  = (x: Bitboard) => x shr 7
    result[Black][BackwardRight] = (x: Bitboard) => x shr 9
    result[Black][ForwardLeft]   = (x: Bitboard) => x shl 9
    result[Black][ForwardRight]  = (x: Bitboard) => x shl 7


const shifters: array[White..Black, array[Direction, (Bitboard) {.noSideEffect.} -> Bitboard]] = generateShifters()


func directionMask*(bitboard: Bitboard, color: PieceColor, direction: Direction): Bitboard {.inline.} =
    ## Get a bitmask relative to the given bitboard
    ## for the given direction for a piece of the
    ## given color
    return shifters[color][direction](bitboard)

const relativeRanks: array[White..Black, array[Rank, Rank]] = [[Rank(7), Rank(6), Rank(5), Rank(4), Rank(3), Rank(2), Rank(1), Rank(0)], [Rank(0), Rank(1), Rank(2), Rank(3), Rank(4), Rank(5), Rank(6), Rank(7)]]

func relativeRank*(color: PieceColor, rank: Rank): Rank {.inline.} = relativeRanks[color][rank]


const
    eighthRanks: array[White..Black, Bitboard] = [rankMask(relativeRank(White, Rank(7))), rankMask(relativeRank(Black, Rank(7)))]
    firstRanks: array[White..Black, Bitboard] = [rankMask(relativeRank(White, Rank(0))), rankMask(relativeRank(Black, Rank(0)))]
    secondRanks: array[White..Black, Bitboard] = [rankMask(relativeRank(White, Rank(1))), rankMask(relativeRank(Black, Rank(1)))]
    seventhRanks: array[White..Black, Bitboard] = [rankMask(relativeRank(White, Rank(6))), rankMask(relativeRank(Black, Rank(6)))]
    leftmostFiles: array[White..Black, Bitboard] = [fileMask(pieces.File(0)), fileMask(pieces.File(7))]
    rightmostFiles: array[White..Black, Bitboard] = [fileMask(pieces.File(7)), fileMask(pieces.File(0))]


func eighthRank*(color: PieceColor): Bitboard {.inline.} = eighthRanks[color]
func firstRank*(color: PieceColor): Bitboard {.inline.} = firstRanks[color]
func seventhRank*(color: PieceColor): Bitboard {.inline.} = seventhRanks[color]
func secondRank*(color: PieceColor): Bitboard {.inline.} = secondRanks[color]
func leftmostFile*(color: PieceColor): Bitboard {.inline.}= leftmostFiles[color]
func rightmostFile*(color: PieceColor): Bitboard {.inline.} = rightmostFiles[color]


func directionMask*(square: Square, color: PieceColor, direction: Direction): Bitboard {.inline.} =
    ## Get a bitmask for the given direction for a piece
    ## of the given color located at the given square
    result = directionMask(square.toBitboard(), color, direction)


func forward*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = directionMask(self, side, Forward)
func doubleForward*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = self.forward(side).forward(side)

func backward*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = directionMask(self, side, Backward)
func doubleBackward*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = self.backward(side).backward(side)

func left*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = directionMask(self, side, Left) and not rightmostFile(side)
func right*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = directionMask(self, side, Right) and not leftmostFile(side)


# We mask off the opposite files to make sure there are
# no weird wraparounds when moving at the edges
func forwardRightRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} =
    directionMask(self, side, ForwardRight) and not leftmostFile(side)


func forwardLeftRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} =
    directionMask(self, side, ForwardLeft) and not rightmostFile(side)


func backwardRightRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} =
    directionMask(self, side, BackwardRight) and not leftmostFile(side)


func backwardLeftRelativeTo*(self: Bitboard, side: PieceColor): Bitboard {.inline.} =
    directionMask(self, side, BackwardLeft) and not rightmostFile(side)


func longKnightUpLeft*(self: Bitboard, side: PieceColor): Bitboard  {.inline.} = self.doubleForward(side).left(side)
func longKnightUpRight*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = self.doubleForward(side).right(side)
func longKnightDownLeft*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = self.doubleBackward(side).left(side)
func longKnightDownRight*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = self.doubleBackward(side).right(side)

func shortKnightUpLeft*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = self.forward(side).left(side).left(side)
func shortKnightUpRight*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = self.forward(side).right(side).right(side)
func shortKnightDownLeft*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = self.backward(side).left(side).left(side)
func shortKnightDownRight*(self: Bitboard, side: PieceColor): Bitboard {.inline.} = self.backward(side).right(side).right(side)

# We precompute as much stuff as possible: lookup tables are fast!


func computeKingBitboards: array[Square.smallest()..Square.biggest(), Bitboard] {.compileTime.} =
    ## Precomputes all the movement bitboards for the king
    for i in Square.all():
        let king = i.toBitboard()
        # It doesn't really matter which side we generate
        # the move for, they're identical for both
        var movements = king.forward(White)
        movements     = movements or king.forwardLeftRelativeTo(White)
        movements     = movements or king.left(White)
        movements     = movements or king.right(White)
        movements     = movements or king.backward(White)
        movements     = movements or king.forwardRightRelativeTo(White)
        movements     = movements or king.backwardRightRelativeTo(White)
        movements     = movements or king.backwardLeftRelativeTo(White)
        # We don't *need* to mask the king off: the engine already masks off
        # the board's occupancy when generating moves, but it may be useful for
        # other parts of the movegen for this stuff not to say "the king can just
        # stay still", so we do it anyway
        movements = movements and not king
        result[i] = movements


func computeKnightBitboards: array[Square.smallest()..Square.biggest(), Bitboard] {.compileTime.} =
    ## Precomputes all the movement bitboards for knights
    for i in Square.all():
        let knight = i.toBitboard()
        # It doesn't really matter which side we generate
        # the move for, they're identical for both
        var movements = knight.longKnightDownLeft(White)
        movements     = movements or knight.longKnightDownRight(White)
        movements     = movements or knight.longKnightUpLeft(White)
        movements     = movements or knight.longKnightUpRight(White)
        movements     = movements or knight.shortKnightDownLeft(White)
        movements     = movements or knight.shortKnightDownRight(White)
        movements     = movements or knight.shortKnightUpLeft(White)
        movements     = movements or knight.shortKnightUpRight(White)
        movements     = movements and not knight
        result[i]     = movements


func computePawnAttackers(color: PieceColor): array[Square.smallest()..Square.biggest(), Bitboard] {.compileTime.} =
    ## Precomputes all the attacker bitboards for pawns
    ## of the given color
    for i in Square.all():
        let pawn = i.toBitboard()
        result[i] = pawn.backwardLeftRelativeTo(color) or pawn.backwardRightRelativeTo(color)


func computePawnAttacks(color: PieceColor): array[Square.smallest()..Square.biggest(), Bitboard] {.compileTime.} =
    ## Precomputes all the attack bitboards for pawns
    ## of the given color
    for i in Square.all():
        let pawn = i.toBitboard()
        result[i] = pawn.forwardLeftRelativeTo(color) or pawn.forwardRightRelativeTo(color)


const
    KING_BITBOARDS = computeKingBitboards()
    KNIGHT_BITBOARDS = computeKnightBitboards()
    PAWN_ATTACKERS: array[White..Black, array[Square.smallest()..Square.biggest(), Bitboard]] = [computePawnAttackers(White), computePawnAttackers(Black)]
    PAWN_ATTACKS: array[White..Black, array[Square.smallest()..Square.biggest(), Bitboard]] = [computePawnAttacks(White), computePawnAttacks(Black)]


func kingMoves*(square: Square): Bitboard {.inline.} = KING_BITBOARDS[square]
func knightMoves*(square: Square): Bitboard {.inline.} = KNIGHT_BITBOARDS[square]
func pawnAttackers*(color: PieceColor, square: Square): Bitboard {.inline.} = PAWN_ATTACKERS[color][square]
func pawnAttacks*(color: PieceColor, square: Square): Bitboard {.inline.} = PAWN_ATTACKS[color][square]
