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

import heimdall/[bitboards, pieces]
import heimdall/util/magics


export bitboards, pieces


# Stolen from https://github.com/Ciekce/voidstar/blob/main/src/rays.rs :D



proc computeRaysBetweenSquares: array[Square.smallest()..Square.biggest(), array[Square.smallest()..Square.biggest(), Bitboard]] =
    ## Computes all sliding rays between each pair of squares
    ## in the chessboard
    for source in Square.all():
        let
            sourceBitboard = source.toBitboard()
            # This is slower than rookMoves(), but it's compile-time stuff anyway!
            rooks = getMoveset(Rook, source, Bitboard(0))
            bishops = getMoveset(Bishop, source, Bitboard(0))
        for target in Square.all():
            if target == source:
                result[source][target] = Bitboard(0)
            else:
                let tarpieces = target.toBitboard()
                if rooks.contains(target):
                    result[source][target] = getMoveset(Rook, source, tarpieces) and getMoveset(Rook, target, sourceBitboard)
                elif bishops.contains(target):
                    result[source][target] = getMoveset(Bishop, source, tarpieces) and getMoveset(Bishop, target, sourceBitboard)


proc computeIntersectingRays: array[Square.smallest()..Square.biggest(), array[Square.smallest()..Square.biggest(), Bitboard]] =
    ## Computes all sliding rays intersecting each pair of squares
    ## in the chessboard, including the ends
    for source in Square.all():
        let
            sourceBitboard = source.toBitboard()
            rooks = getMoveset(Rook, source, Bitboard(0))
            bishops = getMoveset(Bishop, source, Bitboard(0))
        for target in Square.all():
            let targetBitboard = target.toBitboard()
            if bishops.contains(target):
                result[source][target] = (bishops and getMoveset(Bishop, target, Bitboard(0))) or sourceBitboard or targetBitboard
            if rooks.contains(target):
                result[source][target] = (rooks and getMoveset(Rook, target, Bitboard(0))) or sourceBitboard or targetBitboard


const BETWEEN_RAYS = computeRaysBetweenSquares()
const INTERSECTING_RAYS = computeIntersectingRays()


proc rayBetween*(source, target: Square): Bitboard {.inline.} = BETWEEN_RAYS[source][target]
proc rayIntersecting*(source, target: Square): Bitboard {.inline.} = INTERSECTING_RAYS[source][target]