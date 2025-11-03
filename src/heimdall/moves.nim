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

## Handling of moves
import std/strformat

import heimdall/pieces

export pieces


const MAX_MOVES* = 218


type
    MoveFlag* = enum
        Normal          = 0x0,
        DoublePush      = 0x1,
        ShortCastling   = 0x2,
        LongCastling    = 0x3,
        PromotionQueen  = 0x4,
        PromotionRook   = 0x5,
        PromotionBishop = 0x6,
        PromotionKnight = 0x7,
        Capture         = 0x8,
        EnPassant       = 0x9,
        CapturePromotionQueen  = 0xC,
        CapturePromotionRook   = 0xD,
        CapturePromotionBishop = 0xE,
        CapturePromotionKnight = 0xF,

    Move* = object
        # Move information is packed into 16 bits as {from:6}{to:6}{flag:4}
        data: uint16

    MoveList* = object
        ## A list of moves
        data*: array[MAX_MOVES, Move]
        len*: int8


func `[]`*(self: MoveList, i: SomeInteger): Move {.inline.} =
    when defined(checks):
        if i >= self.len:
            raise newException(IndexDefect, &"move list access out of bounds ({i} >= {self.len})")
    result = self.data[i]


iterator items*(self: MoveList): Move {.inline.} =
    var i = 0
    while self.len > i:
        yield self.data[i]
        inc(i)


iterator pairs*(self: MoveList): tuple[i: int, move: Move] {.inline.} =
    var i = 0
    for item in self:
        yield (i, item)
        inc(i)


func `$`*(self: MoveList): string =
    result &= "["
    for i, move in self:
        result &= $move
        if i < self.len:
            result &= ", "
    result &= "]"


func add*(self: var MoveList, move: Move) {.inline.} =
    self.data[self.len] = move
    inc(self.len)

func clear*(self: var MoveList) {.inline.} =
    self.len = 0

func contains*(self: MoveList, move: Move): bool {.inline.} =
    for item in self:
        if move == item:
            return true
    return false

func len*(self: MoveList): int {.inline.} = self.len
func high*(self: MoveList): int {.inline.} = self.len - 1

func createMove*(startSquare, targetSquare: Square, flag: MoveFlag = Normal): Move {.inline, noinit.} =
    result = Move(data: (startSquare.uint16 shl 10) or (targetSquare.uint16 shl 4) or (flag.uint16))

func startSquare*(self: Move): Square {.inline, noinit.} = Square(self.data shr 10)

func targetSquare*(self: Move): Square {.inline, noinit.} = Square((self.data shr 4) and 0x3f)

func `startSquare=`*(self: var Move, square: Square) =
    self.data = (self.data and 0x3ff) or square.uint16 shl 10

func `targetSquare=`*(self: var Move, square: Square) =
    self.data = (self.data and 0xfc0f) or square.uint16 shl 4

func `flag=`*(self: var Move, flag: MoveFlag) =
    self.data = (self.data and 0xfff0) or flag.uint16

proc createMove*(startSquare, targetSquare: string, flag: MoveFlag): Move {.inline, noinit.} =
    result = createMove(startSquare.toSquare(), targetSquare.toSquare(), flag)

func createMove*(startSquare, targetSquare: SomeInteger, flag: MoveFlag): Move {.inline, noinit.} =
    result = createMove(Square(startSquare.int8), Square(targetSquare.int8), flag)

func createMove*(startSquare: Square, targetSquare: SomeInteger, flag: MoveFlag): Move {.inline, noinit.} =
    result = createMove(startSquare, Square(targetSquare.int8), flag)

func nullMove*: Move {.inline, noinit.} = createMove(Square(0), Square(0))


func flag*(self: Move): MoveFlag {.inline, noinit.} =
    {.push warning[HoleEnumConv]:off.}
    result = MoveFlag(self.data and 0xf)
    {.pop.}


func promotionToPiece*(flag: MoveFlag): PieceKind {.inline.} =
    ## Converts a promotion move flag to a
    ## piece kind. Returns the Empty piece
    ## if the flag does not represent a promotion
    case flag:
        of PromotionBishop, CapturePromotionBishop:
            return Bishop
        of PromotionKnight, CapturePromotionKnight:
            return Knight
        of PromotionRook, CapturePromotionRook:
            return Rook
        of PromotionQueen, CapturePromotionQueen:
            return Queen
        else:
            return Empty


func isPromotion*(move: Move): bool {.inline.} =
    return bool(move.flag().uint8 and 0x4)

func isCapture*(move: Move): bool {.inline.} =
    result = move.flag() != EnPassant and bool(move.flag().uint8 and 0x8)

func isCastling*(move: Move): bool {.inline.} =
    result = move.flag() in [LongCastling, ShortCastling]

func isLongCastling*(move: Move): bool {.inline.} =
    result = move.flag() == LongCastling

func isShortCastling*(move: Move): bool {.inline.} =
    result = move.flag() == ShortCastling

func isEnPassant*(move: Move): bool {.inline.} =
    result = move.flag() == EnPassant

func isDoublePush*(move: Move): bool {.inline.} =
    result = move.flag() == DoublePush

func isTactical*(self: Move): bool {.inline.} =
    ## Returns whether the given move
    ## is considered tactical (changes
    ## the material balance on the board)
    result = self.isPromotion() or self.isCapture() or self.isEnPassant()

func isQuiet*(self: Move): bool {.inline.} =
    result = not self.isTactical()


func `$`*(self: Move): string =
    if self == nullMove():
        return "null"
    result &= &"{self.startSquare}{self.targetSquare} ({self.flag})"


func toUCI*(self: Move): string =
    if self == nullMove():
        return "0000"
    result = &"{self.startSquare}{self.targetSquare}"
    case self.flag.promotionToPiece():
        of Bishop:
            result &= "b"
        of Knight:
            result &= "n"
        of Queen:
            result &= "q"
        of Rook:
            result &= "r"
        else:
            # Not a promotion
            discard


proc newMoveList*: MoveList {.inline, noinit.} =
    result.len = 0