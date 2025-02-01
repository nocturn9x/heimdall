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
import std/algorithm


import struct


import heimdall/pieces
import heimdall/position

const RECORD_SIZE* = 32

type
    MarlinFormatRecord* = object
        position*: Position
        wdl*: PieceColor
        eval*: int16
        extra*: byte


func createMarlinFormatRecord*(position: Position, wdl: PieceColor, eval: int16, extra: byte = 0): MarlinFormatRecord =
    result.position = position
    result.eval = eval
    result.wdl = wdl
    result.extra = extra


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
    # Marlinformat uses a board layout where
    # a1=0, b1=1, etc., while we use a layout
    # where a8=0, b8=1, etc., so we need to account
    # for that by flipping our occupancy rank-wise
    var flippedArray: array[8, byte]
    for i, b in reversed(cast[array[8, byte]](occupancy)):
        flippedArray[i] = b
    
    let flippedOccupancy = cast[Bitboard](flippedArray)

    for sq in flippedOccupancy:
        # We flip the rank because while marlinformat uses
        # a1=0, we don't! If we didn't do this we'd be picking
        # the wrong pieces (swapping black/white)
        let sq = sq.flipRank()
        let piece = position.getPiece(sq)
        var encoded = piece.kind.uint8
        if sq == position.castlingAvailability[piece.color].king or sq == position.castlingAvailability[piece.color].queen:
            encoded = UNMOVED_ROOK
        if piece.color == Black:
            encoded = encoded or (1'u8 shl 3)
        pieces.add(encoded)

    # Pad to 32 bytes
    while pieces.len() < 32:
        pieces.add(0)
    # Pack each piece into 4 bits
    var packed: string
    for i in countup(0, 31, 2):
        var hi = pieces[i + 1]
        var lo = pieces[i]
        packed &= (hi shl 4 or lo).char
    # Ensure little endian byte order for the occupancy
    var leOccupancy: uint64
    littleEndian64(addr leOccupancy, addr flippedOccupancy)
    for b in cast[array[8, char]](leOccupancy):
        result &= b
    result &= packed


func encodeStmAndEp(position: Position): string =
    ## Encodes the side to move and en passant
    ## squares in the given position according
    ## to the marlinformat specification
    let epTarget = if position.enPassantSquare != nullSquare(): position.enPassantSquare.flipRank() else: NO_SQUARE
    var stmAndEp = epTarget.uint8
    if position.sideToMove == Black:
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
    if wdl == White:
        encodedWdl = 2
    elif wdl == Black:
        encodedWdl = 0
    
    var encodedScore: int16
    littleEndian16(addr encodedScore, addr score)
    for b in cast[array[2, char]](encodedScore):
        result &= b
    result &= encodedWdl.char
    # Extra data
    result &= extra.char


proc toMarlinformat*(self: MarlinFormatRecord): string =
    ## Dumps the given positional record to a stream
    ## of bytes according to the marlinformat
    ## specification
    result &= self.position.encodePieces()
    result &= self.position.encodeStmAndEp()
    result &= self.position.encodeMoveCounters()
    result &= self.position.encodeEval(self.eval, self.wdl, self.extra)


proc fromMarlinformat*(data: string): MarlinFormatRecord =
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
    # Metadata
    let meta = unpack("<bbHhbb", data[i..^1])
    inc(i, 8)

    result = MarlinFormatRecord()
    for sq in Square(0)..Square(63):
        result.position.mailbox[sq] = nullPiece()
    for color in White..Black:
        result.position.castlingAvailability[color] = (nullSquare(), nullSquare())

    var kingSeen: array[White..Black, bool]
    for i, sq in occupancy:
        # Flip the square back
        let sq = sq.flipRank()
        let encodedPiece = (rawPieces[i div 2].uint8 shr ((i mod 2) * 4)) and 0b1111
        let encodedColor = encodedPiece shr 3
        doAssert encodedColor in 0'u8..1'u8, &"invalid color identifier ({encodedColor}) in pieces section"
        let color = if encodedColor == 0: White else: Black
        var pieceNum = encodedPiece and 0b111
        doAssert pieceNum in 0'u8..6'u8, &"invalid piece identifier ({pieceNum}) in pieces section"
        if pieceNum == King.uint8:
            kingSeen[color] = true
        if pieceNum == 6:
            # Piece is a castleable rook
            pieceNum = PieceKind.Rook.uint8
            # If we've already seen the king then this rook is on the king side,
            # otherwise it's on the queen side
            if kingSeen[color]:
                result.position.castlingAvailability[color].king = sq
            else:
                result.position.castlingAvailability[color].queen = sq
        result.position.spawnPiece(sq, Piece(kind: PieceKind(pieceNum), color: color))
    

    let stmAndEpSquare = meta[0].getChar().uint8
    let halfMoveClock = meta[1].getChar().uint8
    let fullMoveCount = meta[2].getShort().uint16
    let eval = meta[3].getShort().int16
    let wdl = meta[4].getChar().uint8
    let extra = meta[5].getChar().byte
    let epSquare = stmAndEpSquare and 0b01111111
    let stm = stmAndEpSquare shr 7

    result.position.sideToMove = if stm == 0: White else: Black
    result.position.enPassantSquare = if epSquare == 64: nullSquare() else: Square(epSquare).flipRank()
    result.position.halfMoveClock = halfMoveClock
    result.position.fullMoveCount = fullMoveCount
    result.wdl = if wdl == 1: None elif wdl == 2: White else: Black
    result.extra = extra
    result.eval = eval
    
    result.position.updateChecksAndPins()
    result.position.hash()


when isMainModule:
    let g = createMarlinFormatRecord(startpos(), White, 710)
    let s = g.toMarlinformat()
    writeFile("startpos.bin", s)
    doAssert s.fromMarlinformat() == g
