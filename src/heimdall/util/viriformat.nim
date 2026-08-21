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

## Reader, writer and move decoder for viriformat 3.0.0.
##
## A game is a marlinformat position followed by (move, score) pairs and a
## four-byte zero terminator. Viriformat numbers squares from a1 while
## Heimdall numbers them from a8, so both move squares need a rank flip.

import std/[endians, strformat, syncio]

import heimdall/[board, movegen, moves, position]
import heimdall/util/marlinformat


const VIRIFORMAT_MOVE_SIZE* = 4


type
    ViriformatScoredMove* = object
        move*: uint16
        score*: int16

    ViriformatGame* = object
        ## `header` is kept verbatim so relabelling does not perturb metadata
        ## that is unrelated to the move scores.
        header*: string
        initial*: MarlinFormatRecord
        moves*: seq[ViriformatScoredMove]


func readUint16LE(data: string, offset: int): uint16 {.inline.} =
    littleEndian16(addr result, unsafeAddr data[offset])


func readInt16LE(data: string, offset: int): int16 {.inline.} =
    cast[int16](readUint16LE(data, offset))


proc readExact(file: syncio.File, size: int, allowEof: bool): string =
    result = newString(size)
    let read = file.readBuffer(addr result[0], size)
    if read == 0 and allowEof:
        result.setLen(0)
    elif read != size:
        raise newException(IOError, &"truncated viriformat record: expected {size} bytes, read {read}")


proc readViriformatGame*(file: syncio.File, game: var ViriformatGame): bool =
    ## Reads one game. Returns false only for a clean EOF at a game boundary.
    let header = file.readExact(RECORD_SIZE, allowEof=true)
    if header.len == 0:
        return false

    game.header = header
    game.initial = fromMarlinformat(header)
    game.moves.setLen(0)

    while true:
        let entry = file.readExact(VIRIFORMAT_MOVE_SIZE, allowEof=false)
        let
            rawMove = readUint16LE(entry, 0)
            score = readInt16LE(entry, 2)
        if rawMove == 0 and score == 0:
            break
        if rawMove == 0:
            raise newException(ValueError, "invalid viriformat move: the all-zero move encoding is reserved for the game terminator")
        game.moves.add(ViriformatScoredMove(move: rawMove, score: score))
    result = true


func appendUint16LE(result: var string, value: uint16) {.inline.} =
    var encoded: uint16
    littleEndian16(addr encoded, unsafeAddr value)
    for b in cast[array[2, char]](encoded):
        result.add(b)


func appendInt16LE(result: var string, value: int16) {.inline.} =
    result.appendUint16LE(cast[uint16](value))


func toViriformat*(game: ViriformatGame, scores: openArray[int16]): string =
    ## Serialises a game with replacement move scores.
    doAssert scores.len == game.moves.len
    result = newStringOfCap(game.header.len + (game.moves.len + 1) * VIRIFORMAT_MOVE_SIZE)
    result.add(game.header)
    for i, entry in game.moves:
        result.appendUint16LE(entry.move)
        result.appendInt16LE(scores[i])
    result.add("\0\0\0\0")


proc parseViriformatMove*(position: var Position, encoded: uint16): Move =
    ## Converts a viriformat move to Heimdall's move representation. Matching
    ## against the generated legal moves supplies flags viriformat does not
    ## encode explicitly, such as captures and double pawn pushes.
    if encoded == 0:
        raise newException(ValueError, "cannot decode viriformat's null/terminator move")

    let
        start = Square(encoded and 0x3f).flipRank()
        target = Square((encoded shr 6) and 0x3f).flipRank()
        promotion = int((encoded shr 12) and 0x3)
        moveType = int(encoded shr 14)

    var legalMoves = newMoveList()
    position.generateMoves(legalMoves)
    for candidate in legalMoves:
        if candidate.startSquare != start or candidate.targetSquare != target:
            continue

        let matches = case moveType:
            of 0:
                not candidate.isPromotion() and not candidate.isEnPassant() and not candidate.isCastling()
            of 1:
                candidate.isEnPassant()
            of 2:
                candidate.isCastling()
            of 3:
                candidate.isPromotion() and candidate.flag().promotionToPiece() ==
                    [Knight, Bishop, Rook, Queen][promotion]
            else:
                false
        if matches:
            return candidate

    raise newException(ValueError, &"viriformat move 0x{encoded:04x} is illegal in position {position.toFEN()}")
