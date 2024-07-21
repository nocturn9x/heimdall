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

import bitboards
import magics
import pieces

export bitboards, pieces


# Stolen from https://github.com/Ciekce/voidstar/blob/main/src/rays.rs :D



proc computeRaysBetweenSquares: array[64, array[64, Bitboard]] =
    ## Computes all sliding rays between each pair of squares
    ## in the chessboard
    for i in 0..63:
        let 
            source = Square(i)
            sourceBitboard = source.toBitboard()
            rooks = getRookMoves(source, Bitboard(0))
            bishops = getBishopMoves(source, Bitboard(0))
        for j in 0..63:
            let target = Square(j)
            if target == source:
                result[i][j] = Bitboard(0)
            else:
                let targetBitboard = target.toBitboard()
                if rooks.contains(target):
                    result[i][j] = getRookMoves(source, targetBitboard) and getRookMoves(target, sourceBitboard)
                elif bishops.contains(target):
                    result[i][j] = getBishopMoves(source, targetBitboard) and getBishopMoves(target, sourceBitboard)
                else:
                    result[i][j] = Bitboard(0)


let BETWEEN_RAYS = computeRaysBetweenSquares()


proc getRayBetween*(source, target: Square): Bitboard {.inline.} = BETWEEN_RAYS[source.int][target.int]