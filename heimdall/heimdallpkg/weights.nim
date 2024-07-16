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

## Tuned weights for heimdall's evaluation function

# NOTE: This file is computer-generated. Any and all modifications will be overwritten

import pieces


type
    Weight* = int16

const
    TEMPO_BONUS* = Weight(10)

    PAWN_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        152, 201, 144, 146, 203, 159, 80, -51,
        30, 31, 116, 103, 164, 220, 134, 86,
        -15, 20, 31, 48, 90, 79, 25, 27,
        -24, -5, 26, 54, 59, 42, -1, 2,
        -36, -12, 2, 12, 34, 19, 28, 12,
        -15, 3, 11, 17, 36, 52, 51, 14,
        0, 0, 0, 0, 0, 0, 0, 0
    ]

    PAWN_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        276, 320, 273, 206, 250, 200, 221, 245,
        190, 253, 205, 209, 173, 115, 204, 177,
        128, 113, 92, 62, 60, 55, 91, 90,
        75, 86, 47, 46, 49, 41, 57, 41,
        68, 57, 56, 75, 73, 50, 40, 36,
        91, 76, 80, 87, 136, 76, 57, 41,
        0, 0, 0, 0, 0, 0, 0, 0
    ]

    PASSED_PAWN_MIDDLEGAME_BONUSES: array[Square(0)..Square(63), Weight] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        54, 90, 86, 93, -11, 59, 73, 57,
        83, 103, 5, 39, 26, 8, 17, -50,
        52, 26, 30, 15, -7, 1, -7, -5,
        18, -2, -19, -27, -55, -34, 8, 5,
        5, -25, -38, -31, -31, -28, -32, 21,
        -22, -5, -36, -22, 20, -35, 13, 8,
        0, 0, 0, 0, 0, 0, 0, 0
    ]

    PASSED_PAWN_ENDGAME_BONUSES: array[Square(0)..Square(63), Weight] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        223, 222, 188, 151, 107, 182, 269, 261,
        289, 262, 188, 63, 94, 208, 222, 293,
        180, 194, 134, 103, 104, 130, 175, 173,
        101, 104, 80, 62, 87, 87, 122, 114,
        12, 55, 38, -2, 24, 24, 73, 24,
        12, 18, 19, -25, -44, 0, 9, 20,
        0, 0, 0, 0, 0, 0, 0, 0
    ]

    ISOLATED_PAWN_MIDDLEGAME_BONUSES: array[Square(0)..Square(63), Weight] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        35, 58, 55, 70, 23, 6, -55, -60,
        13, 38, -2, 0, -8, -9, 36, -26,
        20, 7, -3, -8, -14, 28, 61, 16,
        -6, -5, -57, -51, -44, -24, -5, -17,
        -14, -20, -42, -10, -62, -28, -42, -47,
        -22, -43, -28, -71, -60, -22, -15, -59,
        0, 0, 0, 0, 0, 0, 0, 0
    ]

    ISOLATED_PAWN_ENDGAME_BONUSES: array[Square(0)..Square(63), Weight] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        55, -59, 64, 54, 70, 77, 93, 74,
        -10, -69, -16, 5, -8, -3, -23, -46,
        -33, -65, -47, -45, -48, -55, -58, -40,
        -10, -34, -24, -41, -52, -36, -39, -25,
        -10, -34, -23, -32, -34, -27, -31, -8,
        -22, -14, -42, 3, -47, -17, -25, -4,
        0, 0, 0, 0, 0, 0, 0, 0
    ]

    KNIGHT_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        -161, -87, -19, 34, 61, 8, -52, -73,
        24, 50, 60, 110, 67, 173, 97, 91,
        34, 128, 133, 170, 176, 198, 132, 96,
        77, 92, 139, 205, 146, 166, 75, 143,
        49, 63, 114, 129, 151, 134, 114, 92,
        7, 54, 88, 98, 132, 110, 105, 61,
        -5, 22, 46, 95, 96, 56, 27, 68,
        -94, 28, -9, 46, 60, 51, 39, -3
    ]

    KNIGHT_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        -20, 60, 90, 55, 80, 14, 48, -77,
        78, 81, 93, 102, 65, 32, 73, 51,
        100, 98, 142, 132, 107, 78, 72, 56,
        112, 132, 154, 152, 159, 157, 141, 93,
        134, 133, 162, 153, 157, 145, 112, 120,
        99, 100, 115, 145, 136, 102, 82, 109,
        107, 115, 93, 93, 103, 89, 90, 128,
        94, 93, 100, 105, 103, 82, 111, 127
    ]

    BISHOP_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        50, 9, 13, -53, -12, -3, 16, -12,
        63, 79, 68, 69, 74, 92, 56, 89,
        87, 126, 117, 141, 123, 160, 142, 120,
        62, 118, 116, 174, 161, 129, 114, 65,
        84, 73, 113, 160, 158, 112, 88, 119,
        76, 138, 127, 135, 138, 137, 137, 132,
        118, 130, 144, 103, 136, 126, 149, 135,
        79, 150, 101, 70, 79, 81, 96, 129
    ]

    BISHOP_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        146, 156, 138, 138, 146, 122, 158, 116,
        122, 150, 126, 130, 126, 123, 142, 106,
        153, 144, 158, 127, 138, 159, 148, 153,
        144, 158, 161, 198, 159, 167, 155, 143,
        138, 169, 172, 170, 166, 156, 159, 122,
        142, 157, 161, 153, 171, 156, 137, 129,
        144, 120, 106, 144, 143, 131, 137, 113,
        123, 123, 132, 125, 131, 165, 128, 93
    ]

    ROOK_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        150, 140, 155, 131, 153, 165, 174, 191,
        156, 137, 173, 215, 189, 218, 207, 236,
        120, 186, 181, 176, 242, 226, 307, 227,
        111, 153, 159, 172, 184, 199, 202, 186,
        94, 99, 118, 139, 144, 120, 166, 158,
        92, 101, 125, 144, 148, 164, 223, 187,
        98, 118, 147, 159, 173, 151, 182, 140,
        153, 150, 165, 174, 182, 162, 180, 149
    ]

    ROOK_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        318, 334, 350, 330, 320, 321, 322, 307,
        318, 351, 348, 312, 326, 301, 305, 284,
        315, 300, 314, 294, 270, 260, 257, 267,
        325, 312, 318, 297, 265, 265, 271, 262,
        306, 318, 299, 289, 277, 281, 271, 261,
        299, 281, 269, 268, 258, 239, 201, 221,
        284, 285, 272, 269, 247, 245, 226, 247,
        302, 288, 293, 285, 265, 288, 256, 266
    ]

    QUEEN_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        315, 354, 403, 444, 409, 455, 450, 373,
        342, 284, 299, 332, 304, 365, 331, 435,
        357, 353, 354, 339, 376, 397, 422, 367,
        326, 341, 332, 329, 347, 357, 365, 364,
        332, 306, 318, 341, 344, 338, 361, 370,
        330, 345, 343, 337, 346, 369, 394, 370,
        341, 351, 373, 381, 382, 373, 393, 409,
        317, 332, 348, 373, 366, 325, 355, 337
    ]

    QUEEN_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        589, 560, 606, 619, 638, 589, 526, 578,
        598, 622, 696, 684, 721, 677, 635, 636,
        596, 598, 650, 675, 698, 647, 590, 631,
        610, 663, 684, 697, 706, 674, 683, 668,
        632, 677, 711, 726, 685, 672, 664, 656,
        588, 663, 681, 658, 666, 646, 623, 622,
        586, 597, 588, 600, 616, 543, 501, 503,
        609, 568, 585, 616, 566, 559, 538, 556
    ]

    KING_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        -71, -29, -3, -32, -5, -7, -28, -11,
        -77, 57, 39, 125, 62, 49, 91, 6,
        -99, 169, 37, 72, 113, 192, 94, -46,
        -54, 1, 1, -79, -57, -34, -66, -182,
        -79, -35, -62, -130, -125, -61, -109, -221,
        -49, 36, -17, -47, -51, -34, 4, -105,
        66, 44, 25, -39, -35, -4, 61, 27,
        -8, 102, 47, -120, -15, -81, 42, -12
    ]

    KING_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        -209, -112, -75, 1, -21, -7, -26, -214,
        -62, 18, 77, 76, 99, 100, 70, -4,
        -16, 57, 116, 150, 150, 127, 105, 5,
        -50, 58, 133, 189, 192, 157, 96, 12,
        -71, 19, 104, 167, 166, 107, 42, -4,
        -77, -17, 49, 91, 85, 52, -7, -40,
        -100, -34, -8, 23, 29, 4, -43, -91,
        -162, -125, -68, -41, -76, -49, -109, -168
    ]

    # Piece weights
    MIDDLEGAME_WEIGHTS: array[PieceKind.Bishop..PieceKind.Rook, Weight] = [380, 0, 386, 125, 943, 487]
    ENDGAME_WEIGHTS: array[PieceKind.Bishop..PieceKind.Rook, Weight]    = [411, 0, 428, 178, 1005, 673]

    # Flat bonuses (middlegame, endgame)
    ROOK_OPEN_FILE_BONUS*: tuple[mg, eg: Weight] = (86, 26)
    ROOK_SEMI_OPEN_FILE_BONUS*: tuple[mg, eg: Weight] = (28, 30)
    DOUBLED_PAWNS_BONUS*: tuple[mg, eg: Weight] = (0, 0)
    BISHOP_PAIR_BONUS*: tuple[mg, eg: Weight] = (61, 142)
    CONNECTED_ROOKS_BONUS*: tuple[mg, eg: Weight] = (0, 0)
    STRONG_PAWNS_BONUS*: tuple[mg, eg: Weight] = (26, 21)
    PAWN_THREATS_MINOR_BONUS*: tuple[mg, eg: Weight] = (24, -40)
    PAWN_THREATS_MAJOR_BONUS*: tuple[mg, eg: Weight] = (15, -30)
    MINOR_THREATS_MAJOR_BONUS*: tuple[mg, eg: Weight] = (92, -14)
    ROOK_THREATS_QUEEN_BONUS*: tuple[mg, eg: Weight] = (171, -157)
    SAFE_CHECK_BISHOP_BONUS*: tuple[mg, eg: Weight] = (24, 67)
    SAFE_CHECK_KNIGHT_BONUS*: tuple[mg, eg: Weight] = (56, 15)
    SAFE_CHECK_ROOK_BONUS*: tuple[mg, eg: Weight] = (105, 14)
    SAFE_CHECK_QUEEN_BONUS*: tuple[mg, eg: Weight] = (32, 112)
    
    # Tapered mobility bonuses
    BISHOP_MOBILITY_MIDDLEGAME_BONUS: array[14, Weight] = [109, 130, 155, 175, 189, 199, 211, 210, 213, 217, 235, 233, 221, 192]
    BISHOP_MOBILITY_ENDGAME_BONUS: array[14, Weight] = [99, 127, 172, 201, 221, 249, 255, 267, 268, 263, 265, 254, 281, 252]
    KNIGHT_MOBILITY_MIDDLEGAME_BONUS: array[9, Weight] = [87, 131, 153, 166, 180, 192, 208, 219, 234]
    KNIGHT_MOBILITY_ENDGAME_BONUS: array[9, Weight] = [64, 137, 186, 217, 240, 257, 255, 245, 228]
    ROOK_MOBILITY_MIDDLEGAME_BONUS: array[15, Weight] = [173, 193, 198, 208, 204, 214, 217, 220, 229, 234, 234, 235, 241, 248, 206]
    ROOK_MOBILITY_ENDGAME_BONUS: array[15, Weight] = [302, 365, 371, 383, 397, 405, 423, 426, 429, 435, 437, 447, 450, 435, 457]
    QUEEN_MOBILITY_MIDDLEGAME_BONUS: array[28, Weight] = [378, 435, 415, 418, 431, 433, 441, 446, 453, 455, 456, 464, 472, 473, 481, 499, 496, 515, 558, 586, 621, 695, 668, 631, 642, 573, 378, 353]
    QUEEN_MOBILITY_ENDGAME_BONUS: array[28, Weight] = [305, 384, 551, 632, 672, 699, 737, 773, 790, 798, 817, 832, 825, 838, 838, 823, 828, 802, 776, 740, 707, 664, 646, 621, 601, 559, 417, 374]
    KING_MOBILITY_MIDDLEGAME_BONUS: array[28, Weight] = [0, 0, 0, 97, 121, 69, 43, 24, 12, 2, -2, -25, -28, -38, -59, -79, -100, -105, -116, -112, -84, -57, -38, -41, -53, -18, -64, -2]
    KING_MOBILITY_ENDGAME_BONUS: array[28, Weight] = [0, 0, 0, -72, -81, -20, -13, -16, -11, -14, -4, 15, 11, 25, 32, 35, 40, 34, 33, 23, 1, -5, -25, -44, -48, -86, -99, -123]

    KING_ZONE_ATTACKS_MIDDLEGAME_BONUS*: array[9, Weight] = [99, 83, 35, -27, -128, -230, -317, -386, -491]
    KING_ZONE_ATTACKS_ENDGAME_BONUS*: array[9, Weight] = [-19, -17, -9, -9, 2, 9, 32, 24, 7]

    MIDDLEGAME_PSQ_TABLES: array[PieceKind.Bishop..PieceKind.Rook, array[Square(0)..Square(63), Weight]] = [
        BISHOP_MIDDLEGAME_SCORES,
        KING_MIDDLEGAME_SCORES,
        KNIGHT_MIDDLEGAME_SCORES,
        PAWN_MIDDLEGAME_SCORES,
        QUEEN_MIDDLEGAME_SCORES,
        ROOK_MIDDLEGAME_SCORES
    ]

    ENDGAME_PSQ_TABLES: array[PieceKind.Bishop..PieceKind.Rook, array[Square(0)..Square(63), Weight]] = [
        BISHOP_ENDGAME_SCORES,
        KING_ENDGAME_SCORES,
        KNIGHT_ENDGAME_SCORES,
        PAWN_ENDGAME_SCORES,
        QUEEN_ENDGAME_SCORES,
        ROOK_ENDGAME_SCORES
    ]

var
    MIDDLEGAME_VALUE_TABLES*: array[PieceColor.White..PieceColor.Black, array[PieceKind.Bishop..PieceKind.Rook, array[Square(0)..Square(63), Weight]]]
    ENDGAME_VALUE_TABLES*: array[PieceColor.White..PieceColor.Black, array[PieceKind.Bishop..PieceKind.Rook, array[Square(0)..Square(63), Weight]]]
    PASSED_PAWN_MIDDLEGAME_TABLES*: array[PieceColor.White..PieceColor.Black, array[Square(0)..Square(63), Weight]]
    PASSED_PAWN_ENDGAME_TABLES*: array[PieceColor.White..PieceColor.Black, array[Square(0)..Square(63), Weight]]
    ISOLATED_PAWN_MIDDLEGAME_TABLES*: array[PieceColor.White..PieceColor.Black, array[Square(0)..Square(63), Weight]]
    ISOLATED_PAWN_ENDGAME_TABLES*: array[PieceColor.White..PieceColor.Black, array[Square(0)..Square(63), Weight]]


proc initializeTables =
    ## Initializes the piece-square tables with the correct values
    ## relative to the side that is moving (they are white-relative
    ## by default, so we need to flip the scores for black)
    for kind in PieceKind.Bishop..PieceKind.Rook:
        for sq in Square(0)..Square(63):
            let flipped = sq.flip()
            MIDDLEGAME_VALUE_TABLES[White][kind][sq] = MIDDLEGAME_WEIGHTS[kind] + MIDDLEGAME_PSQ_TABLES[kind][sq]
            ENDGAME_VALUE_TABLES[White][kind][sq] = ENDGAME_WEIGHTS[kind] + ENDGAME_PSQ_TABLES[kind][sq]
            MIDDLEGAME_VALUE_TABLES[Black][kind][sq] = MIDDLEGAME_WEIGHTS[kind] + MIDDLEGAME_PSQ_TABLES[kind][flipped]
            ENDGAME_VALUE_TABLES[Black][kind][sq] = ENDGAME_WEIGHTS[kind] + ENDGAME_PSQ_TABLES[kind][flipped]
            PASSED_PAWN_MIDDLEGAME_TABLES[White][sq] = PASSED_PAWN_MIDDLEGAME_BONUSES[sq]
            PASSED_PAWN_MIDDLEGAME_TABLES[Black][sq] = PASSED_PAWN_MIDDLEGAME_BONUSES[flipped]
            PASSED_PAWN_ENDGAME_TABLES[White][sq] = PASSED_PAWN_ENDGAME_BONUSES[sq]
            PASSED_PAWN_ENDGAME_TABLES[Black][sq] = PASSED_PAWN_ENDGAME_BONUSES[flipped]
            ISOLATED_PAWN_MIDDLEGAME_TABLES[White][sq] = ISOLATED_PAWN_MIDDLEGAME_BONUSES[sq]
            ISOLATED_PAWN_MIDDLEGAME_TABLES[Black][sq] = ISOLATED_PAWN_MIDDLEGAME_BONUSES[flipped]
            ISOLATED_PAWN_ENDGAME_TABLES[White][sq] = ISOLATED_PAWN_ENDGAME_BONUSES[sq]
            ISOLATED_PAWN_ENDGAME_TABLES[Black][sq] = ISOLATED_PAWN_ENDGAME_BONUSES[flipped]


proc getMobilityBonus*(kind: PieceKind, moves: int): tuple[mg, eg: Weight] =
    ## Returns the mobility bonus for the given piece type
    ## with the given number of (potentially pseudo-legal) moves
    case kind:
        of Bishop:
            return (BISHOP_MOBILITY_MIDDLEGAME_BONUS[moves], BISHOP_MOBILITY_ENDGAME_BONUS[moves])
        of Knight:
            return (KNIGHT_MOBILITY_MIDDLEGAME_BONUS[moves], KNIGHT_MOBILITY_ENDGAME_BONUS[moves])
        of Rook:
            return (ROOK_MOBILITY_MIDDLEGAME_BONUS[moves], ROOK_MOBILITY_ENDGAME_BONUS[moves])
        of Queen:
            return (QUEEN_MOBILITY_MIDDLEGAME_BONUS[moves], QUEEN_MOBILITY_ENDGAME_BONUS[moves])
        of King:
            return (KING_MOBILITY_MIDDLEGAME_BONUS[moves], KING_MOBILITY_ENDGAME_BONUS[moves])
        else:
            return (0, 0)


initializeTables()
