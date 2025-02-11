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

## Implementation of Zobrist hashing

import std/random


import heimdall/pieces


type
    ZobristKey* = distinct uint64
        ## A zobrist key

    TruncatedZobristKey* = distinct uint16
        ## A 16-bit truncated version
        ## of a full zobrist key


func `xor`*(a, b: ZobristKey): ZobristKey {.borrow.}

func `==`*(a, b: ZobristKey): bool {.borrow.}
func `$`*(a: ZobristKey): string {.borrow.}

func `==`*(a, b: TruncatedZobristKey): bool {.borrow.}
func `$`*(a: TruncatedZobristKey): string {.borrow.}


proc computeZobristKeys: array[781, ZobristKey] =
    ## Precomputes our zobrist keys
    var prng = initRand(69420)    # Nice.

    # One for each piece on each square
    for i in 0..767:
        result[i] = ZobristKey(prng.next())
    # One to indicate that it is black's turn
    # to move
    result[768] = ZobristKey(prng.next())
    # Four numbers to indicate castling rights
    for i in 769..772:
        result[i] = ZobristKey(prng.next())
    # Eight numbers to indicate the file of a valid
    # En passant square, if any
    for i in 773..780:
        result[i] = ZobristKey(prng.next())



let ZOBRIST_KEYS = computeZobristKeys()
const PIECE_TO_INDEX = [[3, 2, 0, 5, 4, 1], [9, 8, 6, 11, 10, 7]]


proc getKey*(piece: Piece, square: Square): ZobristKey {.inline.} =
    let index = PIECE_TO_INDEX[piece.color.int][piece.kind.int] * 64 + square.int
    return ZOBRIST_KEYS[index]


proc getBlackToMoveKey*: ZobristKey {.inline.} = ZOBRIST_KEYS[768]


proc getQueenSideCastlingKey*(color: PieceColor): ZobristKey {.inline.} =
    case color:
        of White:
            return ZOBRIST_KEYS[769]
        of Black:
            return ZOBRIST_KEYS[771]
        else:
            discard


proc getKingSideCastlingKey*(color: PieceColor): ZobristKey {.inline.} =
    case color:
        of White:
            return ZOBRIST_KEYS[770]
        of Black:
            return ZOBRIST_KEYS[772]
        else:
            discard


proc getEnPassantKey*(file: SomeInteger): ZobristKey {.inline.} = ZOBRIST_KEYS[773 + file]