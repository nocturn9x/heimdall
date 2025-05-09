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

## Low-level handling of squares, board indeces and pieces
import std/strutils
import std/strformat


type
    Square* = distinct uint8
        ## A square

    PieceColor* = enum
        ## A piece color enumeration
        White = 0'i8
        Black = 1
        None

    PieceKind* = enum
        ## A chess piece enumeration
        Pawn = 0'i8
        Knight = 1
        Bishop = 2
        Rook = 3
        Queen = 4
        King = 5
        Empty = 6    # No piece


    Piece* = object
        ## A chess piece
        color*: PieceColor
        kind*: PieceKind

const opposites: array[PieceColor.White..PieceColor.Black, PieceColor] = [PieceColor.Black, PieceColor.White]

# Overridden operators for our distinct type
func `xor`*(a: Square, b: uint8): Square {.inline.} = Square(a.uint8 xor b)
func `==`*(a, b: Square): bool {.borrow, inline.}
func `<`*(a: Square, b: SomeInteger): bool {.inline.} = a.uint8 < b.uint8
func `>`*(a: SomeInteger, b: Square): bool {.inline.} = a.uint8 > b.uint8
func `<=`*(a: Square, b: SomeInteger): bool {.inline.} = a.uint8 <= b.uint8
func `>=`*(a: SomeInteger, b: Square): bool {.inline.} = a.uint8 >= b.uint8
func `<`*(a, b: Square): bool {.borrow, inline.}
func `<=`*(a, b: Square): bool {.borrow, inline.}
func `>=`*(a, b: Square): bool {.inline.} = a.uint8 >= b.uint8
func `-`*(a, b: Square): Square {.borrow, inline.}
func `-`*(a: Square, b: SomeInteger): Square {.inline.} = Square(a.uint8 - b.uint8)
func `-`*(a: SomeInteger, b: Square): Square {.inline.} = Square(a.uint8 - b.uint8)
func `+`*(a, b: Square): Square {.borrow.}
func `+`*(a: Square, b: SomeInteger): Square {.inline.} = Square(a.uint8 + b.uint8)
func `+`*(a: SomeInteger, b: Square): Square {.inline.} = Square(a.uint8 + b.uint8)

func fileFromSquare*(square: Square): uint8 {.inline.} = square.uint8 mod 8
func rankFromSquare*(square: Square): uint8 {.inline.} = square.uint8 div 8
func makeSquare*(rank, file: SomeInteger): Square {.inline.} = Square((rank * 8) + file)
func flipRank*(self: Square): Square {.inline.} = self xor 56
func flipFile*(self: Square): Square {.inline.} = self xor 7


func all*(self: typedesc[PieceKind]): auto = Pawn..King
func nullPiece*: Piece {.inline.} = Piece(kind: Empty, color: None)
func nullSquare*: Square {.inline.} = Square(64'u8)
func opposite*(c: PieceColor): PieceColor {.inline.} = return opposites[c]
func isValid*(a: Square): bool {.inline.} = a in Square(0)..Square(63)
func isLightSquare*(a: Square): bool {.inline.} = (a.uint8 and 2) == 0


proc toSquare*(s: string): Square {.discardable.} =
    ## Converts a square square from UCI
    ## notation to its corresponding row
    ## and column in the chess grid (0 indexed)
    when defined(checks):
        if len(s) != 2:
            raise newException(ValueError, "UCI square must be of length 2")

    var s = s.toLowerAscii()
    when defined(checks):
        if s[0] notin 'a'..'h':
            raise newException(ValueError, &"UCI square has invalid first character ('{s[0]}')")
        if s[1] notin '1'..'8':
            raise newException(ValueError, &"UCI square has invalid second character ('{s[1]}')")

    return Square((s[0].uint8 - uint8('a')) + ((s[1].uint8 - uint8('1')) xor 7) * 8)


func toUCI*(square: Square): string {.inline.} =
    ## Converts a square from our internal rank/file
    ## notation to a square in UCI notation
    if square == nullSquare():
        return "null"
    let 
        file = char('a'.uint8 + (square.uint64 and 7))
        rank = char('1'.uint8 + ((square.uint64 div 8) xor 7))
    return &"{file}{rank}"


func `$`*(square: Square): string = square.toUCI()


const
    F1* = makeSquare(7, 5)
    F8* = makeSquare(0, 5)
    G1* = makeSquare(7, 6)
    G8* = makeSquare(0, 6)
    D1* = makeSquare(7, 3)
    D8* = makeSquare(0, 3)
    C1* = makeSquare(7, 2)
    C8* = makeSquare(0, 2)


func kingSideCastling*(piece: Piece): Square {.inline.} =
    case piece.kind:
        of Rook:
            case piece.color:
                of White:
                    return F1
                of Black:
                    return F8
                else:
                    discard
        of King:
            case piece.color:
                of White:
                    return G1
                of Black:
                    return G8
                else:
                    discard
        else:
            discard


func queenSideCastling*(piece: Piece): Square {.inline.} =
    case piece.kind:
        of Rook:
            case piece.color:
                of White:
                    return D1
                of Black:
                    return D8
                else:
                    discard
        of King:
            case piece.color:
                of White:
                    return C1
                of Black:
                    return C8
                else:
                    discard
        else:
            discard


func toPretty*(piece: Piece): string {.inline.} =
    case piece.color:
        of White:
            case piece.kind:
                of King:
                    return "\U2654"
                of Queen:
                    return "\U2655"
                of Rook:
                    return "\U2656"
                of Bishop:
                    return "\U2657"
                of Knight:
                    return "\U2658"
                of Pawn:
                    return "\U2659"
                else:
                    discard
        of Black:
            case piece.kind:
                of King:
                    return "\U265A"
                of Queen:
                    return "\U265B"
                of Rook:
                    return "\U265C"
                of Bishop:
                    return "\U265D"
                of Knight:
                    return "\U265E"
                of Pawn:
                    return "\240\159\168\133"
                else:
                    discard
        else:
            discard


func toChar*(piece: Piece): char {.inline.} =
    case piece.kind:
        of Bishop:
            result = 'b'
        of King:
            result = 'k'
        of Knight:
            result = 'n'
        of Pawn:
            result = 'p'
        of Queen:
            result = 'q'
        of Rook:
            result = 'r'
        else:
            discard
    if piece.color == White:
        result = result.toUpperAscii()


func fromChar*(c: char): Piece {.inline.} =
    var 
        kind: PieceKind
        color = Black
    case c.toLowerAscii():
        of 'b':
            kind = Bishop
        of 'k':
            kind = King
        of 'n':
            kind = Knight
        of 'p':
            kind = Pawn
        of 'q':
            kind = Queen
        of 'r':
            kind = Rook
        else:
            discard
    if c.isUpperAscii():
        color = White
    result = Piece(kind: kind, color: color)