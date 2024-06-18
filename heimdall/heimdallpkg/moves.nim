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

## Handling of moves
import pieces


import std/strformat

const MAX_MOVES* = 218

type
    MoveFlag* = enum
        ## An enumeration of move flags
        Default = 0'u16,    # No flag
        EnPassant = 1,      # Move is a capture with en passant
        Capture = 2,        # Move is a capture
        DoublePush = 4,     # Move is a double pawn push
        # Castling metadata
        Castle = 8,
        # Pawn promotion metadata
        PromoteToQueen = 16,
        PromoteToRook = 32,
        PromoteToBishop = 64,
        PromoteToKnight = 128    

    Move* = object
        ## A chess move
        startSquare*: Square
        targetSquare*: Square
        flags*: uint16

    MoveList* = object
        ## A list of moves
        data*: array[MAX_MOVES, Move]
        len*: int8

        

func `[]`*(self: MoveList, i: SomeInteger): Move =
    when defined(debug):
        if i >= self.len:
            raise newException(IndexDefect, &"move list access out of bounds ({i} >= {self.len})")
    result = self.data[i]


iterator items*(self: MoveList): Move =
    var i = 0
    while self.len > i:
        yield self.data[i]
        inc(i)


iterator pairs*(self: MoveList): tuple[i: int, move: Move] =
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


# A bunch of move creation utilities

func createMove*(startSquare, targetSquare: Square, flags: varargs[MoveFlag]): Move =
    result = Move(startSquare: startSquare, targetSquare: targetSquare, flags: Default.uint16)
    for flag in flags:
        result.flags = result.flags or flag.uint16


proc createMove*(startSquare, targetSquare: string, flags: varargs[MoveFlag]): Move =
    result = createMove(startSquare.toSquare(), targetSquare.toSquare(), flags)

func createMove*(startSquare, targetSquare: SomeInteger, flags: varargs[MoveFlag]): Move =
    result = createMove(Square(startSquare.int8), Square(targetSquare.int8), flags)


func createMove*(startSquare: Square, targetSquare: SomeInteger, flags: varargs[MoveFlag]): Move =
    result = createMove(startSquare, Square(targetSquare.int8), flags)


func nullMove*: Move {.inline.} = createMove(nullSquare(), nullSquare())


func isPromotion*(move: Move): bool {.inline.} =
    ## Returns whether the given move is a 
    ## pawn promotion
    for promotion in [PromoteToBishop, PromoteToKnight, PromoteToRook, PromoteToQueen]:
        if (move.flags and promotion.uint16) != 0:
            return true


func getPromotionType*(move: Move): MoveFlag {.inline.} =
    ## Returns the promotion type of the given move.
    ## The return value of this function is only valid
    ## if isPromotion() returns true
    for promotion in [PromoteToBishop, PromoteToKnight, PromoteToRook, PromoteToQueen]:
        if (move.flags and promotion.uint16) != 0:
            return promotion


func isCapture*(move: Move): bool {.inline.} =
    ## Returns whether the given move is a
    ## cature
    result = (move.flags and Capture.uint16) != 0


func isCastling*(move: Move): bool {.inline.} =
    ## Returns whether the given move is a
    ## castling move
    result = (move.flags and Castle.uint16) != 0


func isEnPassant*(move: Move): bool {.inline.} =
    ## Returns whether the given move is an
    ## en passant capture
    result = (move.flags and EnPassant.uint16) != 0


func isDoublePush*(move: Move): bool {.inline.} =
    ## Returns whether the given move is a
    ## double pawn push
    result = (move.flags and DoublePush.uint16) != 0


func isTactical*(self: Move): bool {.inline.} =
    ## Returns whether the given move 
    ## is considered tactical
    return self.isPromotion() or self.isCapture() or self.isEnPassant()


func isQuiet*(self: Move): bool {.inline.} = 
    ## Returns whether the given move is
    ## a quiet
    return not self.isCapture() and not self.isEnPassant() and not self.isPromotion()


func getFlags*(move: Move): seq[MoveFlag] =
    ## Gets all the flags of this move
    for flag in [EnPassant, Capture, DoublePush, Castle, 
                           PromoteToBishop, PromoteToKnight, PromoteToQueen,
                           PromoteToRook]:
        if (move.flags and flag.uint16) == flag.uint16:
            result.add(flag)
    if result.len() == 0:
        result.add(Default)


func `$`*(self: Move): string =
    ## Returns a string representation
    ## for the move
    if self == nullMove():
        return "null"
    result &= &"{self.startSquare}{self.targetSquare}"
    let flags = self.getFlags()
    if len(flags) > 0:
        result &= " ("
        for i, flag in flags:
            result &= $flag
            if i < flags.high():
                result &= ", "
        result &= ")"


func toAlgebraic*(self: Move): string =
    if self == nullMove():
        return "0000"
    result &= &"{self.startSquare}{self.targetSquare}"
    if self.isPromotion():
        case self.getPromotionType():
            of PromoteToBishop:
                result &= "b"
            of PromoteToKnight:
                result &= "n"
            of PromoteToQueen:
                result &= "q"
            of PromoteToRook:
                result &= "r"
            else:
                discard


proc newMoveList*: MoveList =
    for i in 0..result.data.high():
        result.data[i] = nullMove()