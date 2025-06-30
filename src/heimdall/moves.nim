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
import heimdall/pieces

import std/strformat


const MAX_MOVES* = 218


type
    MoveFlag* = enum
        Default = 0'u8
        DoublePush = 1
        Castle = 2
        EnPassant = 3
        Capture = 4
        PromoteToKnight = 8
        PromoteToBishop = 9
        PromoteToRook = 10
        PromoteToQueen = 11
        CapturePromoteToKnight = 12
        CapturePromoteToBishop = 13
        CapturePromoteToRook = 14
        CapturePromoteToQueen = 15


    Move* = object
        data*: uint16

    MoveList* = object
        ## A list of moves
        data*: array[MAX_MOVES, Move]
        len*: int8


func startSquare*(self: Move): Square {.inline.} = Square((self.data shr 10) and 0x3f)
func targetSquare*(self: Move): Square {.inline.} = Square((self.data shr 4) and 0x3f)
func flags*(self: Move): MoveFlag {.inline.} =
    {.push warning[HoleEnumConv]: off.}
    return MoveFlag((self.data and 0xf))
    {.pop.}


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

func createMove*(startSquare, targetSquare: Square, flag: MoveFlag): Move {.inline.} =
    return Move(data: uint16((startSquare.uint16 shl 10) or (targetSquare.uint16 shl 4)) or flag.uint16)


func nullMove*: Move {.inline, noinit.} = createMove(Square(0), Square(0), Default)
func isEnPassant*(self: Move): bool {.inline.} = self.flags() == MoveFlag.EnPassant
func isCastling*(self: Move): bool {.inline.} = self.flags() == MoveFlag.Castle
func isDoublePush*(self: Move): bool {.inline.} = self.flags() == MoveFlag.DoublePush
func isCapture*(self: Move): bool {.inline.} = (self.flags().uint8 and MoveFlag.Capture.uint8) != 0
func isPromotion*(self: Move): bool {.inline.} = (self.flags.uint8 and MoveFlag.PromoteToKnight.uint8) != 0
# Note: only valid if isPromotion() is true (obviously)
func promotionToPiece*(self: Move): PieceKind {.inline.} = PieceKind((self.flags().uint8 and 3) + 1)

func isTactical*(self: Move): bool {.inline.} =
    ## Returns whether the given move 
    ## is considered tactical (changes
    ## the material balance on the board)
    return self.isPromotion() or self.isCapture() or self.isEnPassant()

func isQuiet*(self: Move): bool {.inline.} = not self.isTactical()


func `$`*(self: Move): string =
    if self == nullMove():
        return "null"
    result &= &"{self.startSquare}{self.targetSquare} ({self.flags()})"


func toUCI*(self: Move): string =
    if self == nullMove():
        return "0000"
    result &= &"{self.startSquare}{self.targetSquare}"
    if self.isPromotion():
        result &= self.promotionToPiece().toChar()


proc newMoveList*: MoveList {.inline, noinit.} =
    result.len = 0