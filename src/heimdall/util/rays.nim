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

import heimdall/bitboards
import heimdall/util/magics
import heimdall/pieces

export bitboards, pieces


# Stolen from https://github.com/Ciekce/voidstar/blob/main/src/rays.rs :D



proc computeRaysBetweenSquares: array[Square(0)..Square(63), array[Square(0)..Square(63), Bitboard]] =
    ## Computes all sliding rays between each pair of squares
    ## in the chessboard
    for source in Square(0)..Square(63):
        let 
            sourceBitboard = source.toBitboard()
            rooks = getRookMoves(source, Bitboard(0))
            bishops = getBishopMoves(source, Bitboard(0))
        for target in Square(0)..Square(63):
            if target == source:
                result[source][target] = Bitboard(0)
            else:
                let targetBitboard = target.toBitboard()
                if rooks.contains(target):
                    result[source][target] = getRookMoves(source, targetBitboard) and getRookMoves(target, sourceBitboard)
                elif bishops.contains(target):
                    result[source][target] = getBishopMoves(source, targetBitboard) and getBishopMoves(target, sourceBitboard)
                else:
                    result[source][target] = Bitboard(0)


proc computeInclusiveRays: array[Square(0)..Square(63), array[Square(0)..Square(63), Bitboard]] =
    ## Computes all sliding rays between each pair of squares
    ## in the chessboard, including the ends
    for source in Square(0)..Square(63):
        let
            sourceBitboard = source.toBitboard()
            rooks = getRookMoves(source, Bitboard(0))
            bishops = getBishopMoves(source, Bitboard(0))
        for target in Square(0)..Square(63):
            let targetBitboard = target.toBitboard()
            if bishops.contains(targetBitboard):
                result[source][target] = (bishops and getBishopMoves(target, Bitboard(0))) or sourceBitboard or targetBitboard
            if rooks.contains(targetBitboard):
                result[source][target] = (rooks and getRookMoves(target, Bitboard(0))) or sourceBitboard or targetBitboard




let BETWEEN_RAYS = computeRaysBetweenSquares()
let INTERSECTING_RAYS = computeInclusiveRays()


proc getRayBetween*(source, target: Square): Bitboard {.inline.} = BETWEEN_RAYS[source][target]
proc getRayIntersecting*(source, target: Square): Bitboard {.inline.} = INTERSECTING_RAYS[source][target]