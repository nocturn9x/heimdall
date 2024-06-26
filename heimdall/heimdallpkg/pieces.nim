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

## Low-level handling of squares, board indeces and pieces
import std/strutils
import std/strformat


type
    Square* = distinct int8
        ## A square

    PieceColor* = enum
        ## A piece color enumeration
        White = 0'i8
        Black = 1
        None

    PieceKind* = enum
        ## A chess piece enumeration
        Bishop = 0'i8
        King = 1
        Knight = 2
        Pawn = 3
        Queen = 4
        Rook = 5 
        Empty = 6    # No piece


    Piece* = object
        ## A chess piece
        color*: PieceColor
        kind*: PieceKind
    

func nullPiece*: Piece {.inline.} = Piece(kind: Empty, color: None)
func nullSquare*: Square {.inline.} = Square(-1'i8)
func opposite*(c: PieceColor): PieceColor {.inline.} = (if c == White: Black else: White)
func isValid*(a: Square): bool {.inline.} = a.int8 in 0..63
func isLightSquare*(a: Square): bool {.inline.} = (a.int8 and 2) == 0

# Overridden operators for our distinct type
func `xor`*(a: Square, b: SomeInteger): Square {.inline.} = Square(a.int8 xor b)
func `==`*(a, b: Square): bool {.inline.} = a.int8 == b.int8
func `!=`*(a, b: Square): bool {.inline.} = a.int8 != b.int8
func `<`*(a: Square, b: SomeInteger): bool {.inline.} = a.int8 < b.int8
func `>`*(a: SomeInteger, b: Square): bool {.inline.} = a.int8 > b.int8
func `<=`*(a: Square, b: SomeInteger): bool {.inline.} = a.int8 <= b.int8
func `>=`*(a: SomeInteger, b: Square): bool {.inline.} = a.int8 >= b.int8
func `<`*(a, b: Square): bool {.inline.} = a.int8 < b.int8
func `>`*(a, b: Square): bool {.inline.} = a.int8 > b.int8
func `<=`*(a, b: Square): bool {.inline.} = a.int8 <= b.int8
func `>=`*(a, b: Square): bool {.inline.} = a.int8 >= b.int8
func `-`*(a, b: Square): Square {.inline.} = Square(a.int8 - b.int8)
func `-`*(a: Square, b: SomeInteger): Square {.inline.} = Square(a.int8 - b.int8)
func `-`*(a: SomeInteger, b: Square): Square {.inline.} = Square(a.int8 - b.int8)
func `+`*(a, b: Square): Square {.inline.} = Square(a.int8 + b.int8)
func `+`*(a: Square, b: SomeInteger): Square {.inline.} = Square(a.int8 + b.int8)
func `+`*(a: SomeInteger, b: Square): Square {.inline.} = Square(a.int8 + b.int8)

func fileFromSquare*(square: Square): int8 = square.int8 mod 8
func rankFromSquare*(square: Square): int8 = square.int8 div 8
func seventhRank*(piece: Piece): int8 = (if piece.color == White: 1 else: 6)

func makeSquare*(rank, file: SomeInteger): Square = Square((rank * 8) + file)

func flip*(self: Square): Square = self xor 56


proc toSquare*(s: string): Square {.discardable.} =
    ## Converts a square square from algebraic
    ## notation to its corresponding row and column
    ## in the chess grid (0 indexed)
    when defined(debug):
        if len(s) != 2:
            raise newException(ValueError, "algebraic position must be of length 2")

    var s = s.toLowerAscii()
    when defined(debug):
        if s[0] notin 'a'..'h':
            raise newException(ValueError, &"algebraic position has invalid first character ('{s[0]}')")
        if s[1] notin '1'..'8':
            raise newException(ValueError, &"algebraic position has invalid second character ('{s[1]}')")

    return Square((s[0].uint8 - uint8('a')) + ((s[1].uint8 - uint8('1')) xor 7) * 8)


proc toAlgebraic*(square: Square): string {.inline.} =
    ## Converts a square from our internal rank/file
    ## notation to a square in algebraic notation
    if square == nullSquare():
        return "null"
    let 
        file = char('a'.uint8 + (square.uint64 and 7))
        rank = char('1'.uint8 + ((square.uint64 div 8) xor 7))
    return &"{file}{rank}"


proc `$`*(square: Square): string = square.toAlgebraic()

func kingSideRook*(color: PieceColor): Square {.inline.} = (if color == White: "h1".toSquare() else: "h8".toSquare())
func queenSideRook*(color: PieceColor): Square {.inline.} = (if color == White: "a1".toSquare() else: "a8".toSquare())

func kingSideCastling*(piece: Piece): Square {.inline.} =
    case piece.kind:
        of Rook:
            case piece.color:
                of White:
                    return "f1".toSquare()
                of Black:
                    return "f8".toSquare()
                else:
                    discard
        of King:
            case piece.color:
                of White:
                    return "g1".toSquare()
                of Black:
                    return "g8".toSquare()
                else:
                    discard
        else:
            discard


func queenSideCastling*(piece: Piece): Square {.inline.} =
    case piece.kind:
        of Rook:
            case piece.color:
                of White:
                    return "d1".toSquare()
                of Black:
                    return "d8".toSquare()
                else:
                    discard
        of King:
            case piece.color:
                of White:
                    return "c1".toSquare()
                of Black:
                    return "c8".toSquare()
                else:
                    discard
        else:
            discard


proc toPretty*(piece: Piece): string =
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


func toChar*(piece: Piece): char =
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


func fromChar*(c: char): Piece =
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