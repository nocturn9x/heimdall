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

## Implementation of Zobrist hashing

import heimdall/util/rng

import heimdall/pieces


type
    ZobristKey* = distinct uint64
    TruncatedZobristKey* = distinct uint16


func `xor`*(a, b: ZobristKey): ZobristKey {.borrow.}

func `==`*(a, b: ZobristKey): bool {.borrow.}
func `$`*(a: ZobristKey): string {.borrow.}

func `==`*(a, b: TruncatedZobristKey): bool {.borrow.}
func `$`*(a: TruncatedZobristKey): string {.borrow.}


proc computeZobristKeys: array[781, ZobristKey] {.compileTime.} =
    # Generated with the following Python code:
    # ints = bytearray(secrets.randbits(256).to_bytes(256 // 8))
    # first, second, third, fourth = ints[0:8], ints[8:16], ints[16:24], ints[24:32]
    # a, b, c, d = int.from_bytes(first), int.from_bytes(second), int.from_bytes(third), int.from_bytes(fourth)
    var state = [6476102730656211459'u64, 14393871350966882219'u64, 15551353530918062426'u64, 12426697806977972640'u64]
    
    # One for each piece on each square
    for i in 0..767:
        result[i] = ZobristKey(rng.next(state))
    # One to indicate that it is black's turn
    # to move
    result[768] = ZobristKey(rng.next(state))
    # Four numbers to indicate castling rights
    for i in 769..772:
        result[i] = ZobristKey(rng.next(state))
    # Eight numbers to indicate the file of a valid
    # En passant square, if any
    for i in 773..780:
        result[i] = ZobristKey(rng.next(state))

const
    ZOBRIST_KEYS = computeZobristKeys()
    PIECE_TO_INDEX: array[White..Black, array[Pawn..King, int]] = [[3, 2, 0, 5, 4, 1], [9, 8, 6, 11, 10, 7]]


func getKey*(piece: Piece, square: Square): ZobristKey {.inline.} =
    return ZOBRIST_KEYS[PIECE_TO_INDEX[piece.color][piece.kind] * 64 + square.int]

func blackToMoveKey*: ZobristKey {.inline.} = ZOBRIST_KEYS[768]

func longCastlingKey*(color: PieceColor): ZobristKey {.inline.} =
    return ZOBRIST_KEYS[769 + 2 * color.int]

func shortCastlingKey*(color: PieceColor): ZobristKey {.inline.} =
    return ZOBRIST_KEYS[770 + 2 * color.int]

func enPassantKey*(file: pieces.File): ZobristKey {.inline.} = ZOBRIST_KEYS[773 + file.uint8]