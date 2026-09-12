# Copyright 2026 Mattia Giambirtone & All Contributors
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
import std/[strutils, strformat]


type

    PieceColor* = enum
        White = 0'i8
        Black = 1
        None

    PieceKind* = enum
        Pawn = 0'i8
        Knight = 1
        Bishop = 2
        Rook = 3
        Queen = 4
        King = 5
        Empty = 6    # No piece

    Piece* = object
        # Piece information is packed into 8 bits as {unused:3}{color:2}{kind:3}.
        data: uint8

    SignedDistance* = distinct range[-7'i8..7'i8]
    File*   = distinct range[0'u8..7'u8]
    Rank*   = distinct range[0'u8..7'u8]
    Square* = distinct range[0'u8..64'u8]

{.push.}
# Nim is big stupid and we need operators that work on more than
# just the type itself.
when (NimMajor, NimMinor, NimPatch) >= (2, 2, 12):
    {.warning[InvalidCmpOp]:off.}

func asInt*(self: Piece): uint8 = self.data
# Boy oh boy am I glad we have generics. So much code space saved!
func `xor`*[T: Rank | File | Square](a: T, b: uint8): T {.inline.} = T(a.uint8 xor b)
func `and`*[T: Rank | File | Square](a: T, b: uint8): T {.inline.} = T(a.uint8 and b)
func `mod`*[T: Rank | File | Square](a: T, b: uint8): T {.inline.} = T(a.uint8 mod b)
func `div`*[T: Rank | File | Square](a: T, b: uint8): T {.inline.} = T(a.uint8 div b)
func `==`*[T: Rank | File | Square](a, b: T): bool {.inline.} = a.uint8 == b.uint8
func `==`*[T: Rank | File | Square](a: T, b: SomeInteger): bool {.inline.} = a.uint8 == b.uint8
func `<`*[T: Rank | File | Square](a: T, b: SomeInteger): bool {.inline.} = a.uint8 < b.uint8
func `<`*[T: Rank | File | Square](a, b: T): bool {.inline.} = a.uint8 < b.uint8
func `>`*[T: Rank | File | Square](a: SomeInteger, b: T): bool {.inline.} = a.uint8 > b.uint8
func `>`*[T: Rank | File | Square](a: T, b: SomeInteger): bool {.inline.} = a.uint8 > b.uint8
func `<=`*[T: Rank | File | Square](a: T, b: SomeInteger): bool {.inline.} = a.uint8 <= b.uint8
func `<=`*[T: Rank | File | Square](a, b: T): bool {.inline.} = a.uint8 <= b.uint8
func `>=`*[T: Rank | File | Square](a, b: T): bool {.inline.} = a.uint8 >= b.uint8
func `>=`*[T: Rank | File | Square](a: SomeInteger, b: T): bool {.inline.} = a.uint8 >= b.uint8
func `+`*[T: Rank | File | Square](a, b: T): T {.inline.} = T(a.uint8 + b.uint8)
func `+`*[T: Rank | File | Square](a: T, b: SomeInteger): T {.inline.} = T(a.uint8 + b.uint8)
func `+`*[T: Rank | File | Square](a: SomeInteger, b: T): T {.inline.} = T(a.uint8 + b.uint8)
func `-`*[T: Rank | File | Square](a, b: T): T {.inline.} = T(a.uint8 - b.uint8)
func `-`*[T: Rank | File | Square](a: T, b: SomeInteger): T {.inline.} = T(a.uint8 - b.uint8)
func `-`*[T: Rank | File | Square](a: SomeInteger, b: T): T {.inline.} = T(a.uint8 - b.uint8)
# TODO: Can we reuse the above helpers?
func `==`*(a, b: SignedDistance): bool {.borrow.}
func `==`*(a: SignedDistance, b: SomeInteger): bool {.inline.} = a.uint8 == b.uint8
func `<`*(a: SignedDistance, b: SomeInteger): bool {.inline.} = a.uint8 < b.uint8
func `<`*(a, b: SignedDistance): bool {.inline.} = a.uint8 < b.uint8
func `>`*(a: SomeInteger, b: SignedDistance): bool {.inline.} = a.uint8 > b.uint8
func `>`*(a: SignedDistance, b: SomeInteger): bool {.inline.} = a.uint8 > b.uint8
func `<=`*(a: SignedDistance, b: SomeInteger): bool {.inline.} = a.uint8 <= b.uint8
func `<=`*(a, b: SignedDistance): bool {.inline.} = a.uint8 <= b.uint8
func `>=`*(a, b: SignedDistance): bool {.inline.} = a.uint8 >= b.uint8
func `>=`*(a: SomeInteger, b: SignedDistance): bool {.inline.} = a.uint8 >= b.uint8
func `+`*(a, b: SignedDistance): SignedDistance {.inline.} = SignedDistance(a.uint8 + b.uint8)
func `+`*(a: SignedDistance, b: SomeInteger): SignedDistance {.inline.} = SignedDistance(a.uint8 + b.uint8)
func `+`*(a: SomeInteger, b: SignedDistance): SignedDistance {.inline.} = SignedDistance(a.uint8 + b.uint8)
func `-`*(a, b: SignedDistance): SignedDistance {.inline.} = SignedDistance(a.uint8 - b.uint8)
func `-`*(a: SignedDistance, b: SomeInteger): SignedDistance {.inline.} = SignedDistance(a.uint8 - b.uint8)
func `-`*(a: SomeInteger, b: SignedDistance): SignedDistance {.inline.} = SignedDistance(a.uint8 - b.uint8)
func signedDistance*[T: Rank | File](a, b: T): SignedDistance {.inline.} = SignedDistance(a.int - b.int)
func abs*(a: SignedDistance): SignedDistance {.inline.} = SignedDistance(abs(a.int))
func absDistance*[T: Rank | File](a, b: T): T {.inline.} = T(abs(signedDistance(a, b)))

{.pop.}

const opposites: array[White..Black, PieceColor] = [Black, White]

func makeSquare*(rank: Rank, file: File): Square {.inline.} = Square((rank.uint8 * 8) + file.uint8)
func makeSquare*(rank, file: SomeInteger): Square {.inline.} = makeSquare(Rank(rank), File(file))
func file*(square: Square): File {.inline.} = File(square mod 8)
func rank*(square: Square): Rank {.inline.} = Rank(square div 8)
func flipRank*(self: Square): Square {.inline.} = self xor 56
func flipFile*(self: Square): Square {.inline.} = self xor 7
func smallest*(T: typedesc[Square]): Square {.inline.} = Square(0)
func biggest*(T: typedesc[Square]): Square {.inline.} = Square(63)
func all*(T: typedesc[Square]): auto = T.smallest()..T.biggest()
func all*[T: File | Rank](x: typedesc[T]): auto = x.low()..x.high()
func all*(self: typedesc[PieceKind]): auto = Pawn..King

iterator items*(T: typedesc[File]): File =
    for value in 0'u8..7'u8:
        yield File(value)

iterator items*(T: typedesc[Rank]): Rank =
    for value in 0'u8..7'u8:
        yield Rank(value)

iterator items*(T: typedesc[Square]): Square =
    for value in 0'u8..63'u8:
        yield Square(value)

func createPiece*(kind: PieceKind, color: PieceColor): Piece {.inline.} =
    ## Creates a packed piece, including the Empty and None sentinel values.
    result = Piece(data: (color.uint8 shl 3) or kind.uint8)
    when defined(debug):
        # Couldn't decide between 6 and 7
        result.data = result.data or (7'u8 shl 5)

func createPiece*(data: uint8): Piece {.inline.} =
    ## Creates a packed piece, from the given
    ## already packed data
    result = Piece(data: data)
    when defined(debug):
        # Couldn't decide between 6 and 7
        result.data = result.data or (7'u8 shl 5)

when defined(debug):
    func `==`*(a, b: Piece): bool {.inline.} =
        # Ignore padding so zero-initialized pieces retain their equality semantics.
        (a.data and 0x1f) == (b.data and 0x1f)

func kind*(self: Piece): PieceKind {.inline.} =
    ## Returns the piece kind.
    PieceKind(self.data and 0x7)

func color*(self: Piece): PieceColor {.inline.} =
    ## Returns the piece color.
    PieceColor((self.data shr 3) and 0x3)

func `kind=`*(self: var Piece, kind: PieceKind) {.inline.} =
    ## Changes the kind while preserving the color.
    self.data = (self.data and 0xf8) or kind.uint8

func `color=`*(self: var Piece, color: PieceColor) {.inline.} =
    ## Changes the color while preserving the kind.
    self.data = (self.data and 0xe7) or (color.uint8 shl 3)

func nullPiece*: Piece {.inline.} = createPiece(Empty, None)
func nullSquare*: Square {.inline.} = Square(64'u8)
func opposite*(c: PieceColor): PieceColor {.inline.} = return opposites[c]
func isLightSquare*(a: Square): bool {.inline.} = (a and 2) == 0
func isValidSquare*(rank: Rank, file: File): bool = (rank.uint8 * 8) + file.uint8 in 0'u8..63'u8


proc toSquare*(s: string, checked: static bool = false): Square {.discardable.} =
    ## Converts a square square from UCI
    ## notation to its corresponding row
    ## and column in the chess grid (0 indexed)
    const checks = defined(checks) or checked
    when checks:
        if len(s) != 2:
            raise newException(ValueError, "UCI square must be of length 2")

    var s = s.toLowerAscii()
    when checks:
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
        file = char('a'.uint8 + (square.uint8 and 7))
        rank = char('1'.uint8 + ((square.uint8 div 8) xor 7))
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


func shortCastling*(piece: Piece): Square {.inline.} =
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


func longCastling*(piece: Piece): Square {.inline.} =
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
    result = createPiece(kind=kind, color=color)
