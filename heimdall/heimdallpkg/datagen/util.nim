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
import std/math
import std/strformat
import std/endians

import struct


import heimdallpkg/pieces
import heimdallpkg/position


type
    CompressedPosition* = object
        position*: Position
        wdl*: PieceColor
        eval*: int16
        extra*: byte


func createCompressedPosition*(position: Position, wdl: PieceColor, eval: int16, extra: byte = 0): CompressedPosition =
    ## Creates a new compressed position object
    result.position = position
    result.eval = eval
    result.wdl = wdl


func lerp*(a, b, t: float): float = (a * (1.0 - t)) + (b * t)
func sigmoid*(x: float): float = 1 / (1 + exp(-x))

# More code from analog-hors :>


# Marlinformat uses 6 to signal a rook that has not
# moved
const UNMOVED_ROOK = 6'u8
# The null square is 64 in marlinformat (we use -1)
const NO_SQUARE = Square(64)


proc encodePieces(position: Position): string =
    ## Encodes the pieces in the given position
    ## according to the marlinformat specification
    
    var pieces: seq[uint8] = @[]
    let occupancy = position.getOccupancy()
    
    for sq in occupancy:
        let piece = position.getPiece(sq)
        var encoded = piece.kind.uint8
        if sq == position.castlingAvailability[piece.color].king or sq == position.castlingAvailability[piece.color].queen:
            encoded = UNMOVED_ROOK
        if piece.color == PieceColor.Black:
            encoded = encoded or (1'u8 shl 3)
        pieces.add(encoded)
    # Pad to 32 bytes
    while pieces.len() < 32:
        pieces.add(0)
    # Pack each piece into 4 bits
    var packed: string
    # Marlinformat uses a square layout where a8=0, which is
    # the exact opposite of what we do
    echo "pack"
    for i in countdown(31, 0, 2):
        var hi = pieces[i - 1]
        var lo = pieces[i]
        packed &= (hi shl 4 or lo).char
        echo packed[^1].uint8
    echo "done"
    # Ensure little endian byte order for the occupancy
    var leOccupancy: uint64
    littleEndian64(addr leOccupancy, addr occupancy)
    for b in cast[array[8, char]](leOccupancy):
        result &= b
    result &= packed


func encodeStmAndEp(position: Position): string =
    ## Encodes the side to move and en passant
    ## squares in the given position according
    ## to the marlinformat specification
    let epTarget = if position.enPassantSquare != nullSquare(): position.enPassantSquare else: NO_SQUARE
    var stmAndEp = epTarget.uint8
    if position.sideToMove == PieceColor.Black:
        stmAndEp = stmAndEp or (1'u8 shl 7)
    result &= stmAndEp.char


func encodeMoveCounters(position: Position): string =
    ## Encodes the full and half move counters in
    ## the given position according to the marlinformat
    ## specification
    result &= position.halfMoveClock.char
    var fullMove: uint16
    littleEndian16(addr fullMove, addr position.fullMoveCount)
    for b in cast[array[2, char]](fullMove):
        result &= b


func encodeEval(position: Position, score: int16, wdl: PieceColor, extra: byte): string =
    ## Encodes the evaluation and wdl data of the given
    ## position according to the marlinformat specification
    var encodedWdl = 1'u8
    if wdl == PieceColor.White:
        encodedWdl = 2
    elif wdl == PieceColor.Black:
        encodedWdl = 0
    
    var encodedScore: int16
    littleEndian16(addr encodedScore, addr score)
    for b in cast[array[2, char]](encodedScore):
        result &= b
    result &= encodedWdl.char
    # Extra data
    result &= extra.char


proc dump*(self: CompressedPosition): string =
    ## Dumps the given compressed position instance
    ## to a stream of bytes according to the marlinformat
    ## specification
    result &= self.position.encodePieces()
    result &= self.position.encodeStmAndEp()
    result &= self.position.encodeMoveCounters()
    result &= self.position.encodeEval(self.eval, self.wdl, self.extra)


proc load*(data: string): CompressedPosition =
    ## Loads a compressed marlinformat record
    ## from the given stream of bytes
    doAssert len(data) == 32, &"compressed record must be 32 bytes long, not {len(data)}"
    var i = 0
    var rawOccupancy: array[8, char]
    for j, b in data[0..7]:
        rawOccupancy[j] = b
    inc(i, 8)
    var occupancy: Bitboard
    littleEndian64(addr occupancy, addr rawOccupancy)
    let rawPieces = data[i..<i+16]
    inc(i, 16)
    let meta = unpack("<bbHhbb", data[i..^1])
    let stmAndEpSquare = meta[0].getChar().uint8
    let halfMoveClock = meta[1].getChar().uint8
    let fullMoveCount = meta[2].getShort().uint16
    let eval = meta[3].getShort().int16
    let wdl = meta[4].getChar().uint8
    let extra = meta[5].getChar().byte
    let epSquare = stmAndEpSquare and 0b01111111
    let stm = stmAndEpSquare shr 7

    result = CompressedPosition()
    for sq in Square(0)..Square(63):
        result.position.mailbox[sq] = nullPiece()

    var castlingSquares: array[PieceColor.White..PieceColor.Black, array[2, Square]] = [[nullSquare(), nullSquare()], [nullSquare(), nullSquare()]]
    for i, sq in occupancy:
        let encodedPiece = rawPieces[i div 2].uint8 shr (i mod 2) * 4 and 0b1111
        let encodedColor = encodedPiece shr 3
        doAssert encodedColor in 0'u8..1'u8, &"invalid color identifier ({encodedColor}) in pieces section"
        let color = if encodedColor == 0: PieceColor.White else: PieceColor.Black
        var pieceNum = encodedPiece and 0b111
        doAssert pieceNum in 0'u8..6'u8, &"invalid piece identifier ({pieceNum}) in pieces section"
        if pieceNum == 6:
            if castlingSquares[color][0] == nullSquare():
                castlingSquares[color][0] = sq
            else:
                castlingSquares[color][1] = sq
            pieceNum = PieceKind.Rook.uint8
        result.position.spawnPiece(sq, Piece(kind: PieceKind(pieceNum), color: color))

    for color in PieceColor.Black..PieceColor.White:
        discard
    
    result.position.sideToMove = if stm == 0: PieceColor.White else: PieceColor.Black
    result.position.enPassantSquare = if epSquare == 64: nullSquare() else: Square(epSquare)
    result.position.halfMoveClock = halfMoveClock
    result.position.fullMoveCount = fullMoveCount
    result.wdl = if wdl == 1: PieceColor.None elif wdl == 2: PieceColor.White else: PieceColor.Black
    result.extra = extra
    result.eval = eval
    echo result.position.pretty()

    doAssert result.position.getBitboard(King, White) != 0
    doAssert result.position.getBitboard(King, Black) != 0
    result.position.updateChecksAndPins()
    result.position.hash()


when isMainModule:
    let s = createCompressedPosition(startpos(), White, 710).dump()
    writeFile("startpos.bin", s)
    discard s.load()