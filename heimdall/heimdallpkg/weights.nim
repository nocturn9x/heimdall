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
        150, 180, 136, 154, 205, 161, 95, -23,
        24, 34, 124, 111, 161, 212, 143, 82,
        -12, 23, 28, 53, 94, 80, 32, 29,
        -25, -3, 26, 54, 60, 44, 2, -1,
        -35, -20, -1, 8, 32, 19, 29, 11,
        -14, 7, 10, 16, 36, 49, 52, 18,
        0, 0, 0, 0, 0, 0, 0, 0
    ]

    PAWN_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        273, 296, 273, 202, 249, 199, 209, 236,
        180, 251, 193, 217, 167, 110, 198, 176,
        130, 112, 89, 63, 61, 55, 97, 89,
        77, 80, 50, 43, 44, 33, 55, 40,
        61, 51, 51, 70, 70, 45, 41, 33,
        90, 77, 78, 84, 126, 68, 55, 39,
        0, 0, 0, 0, 0, 0, 0, 0
    ]

    PASSED_PAWN_MIDDLEGAME_BONUSES: array[Square(0)..Square(63), Weight] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        43, 92, 89, 92, 16, 67, 81, 51,
        65, 93, -6, 35, 24, -12, 35, -46,
        43, 30, 43, 12, -6, 15, -8, 4,
        25, 1, -20, -29, -52, -16, 13, 5,
        5, -29, -30, -30, -30, -22, -21, 39,
        -18, -8, -41, -15, 0, -33, 14, 20,
        0, 0, 0, 0, 0, 0, 0, 0
    ]

    PASSED_PAWN_ENDGAME_BONUSES: array[Square(0)..Square(63), Weight] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        220, 215, 190, 146, 110, 172, 253, 238,
        279, 260, 182, 70, 88, 206, 208, 273,
        177, 192, 120, 94, 107, 131, 169, 156,
        110, 102, 78, 65, 77, 83, 124, 107,
        18, 58, 44, -2, 16, 30, 71, 18,
        13, 15, 13, -33, -39, 1, 11, 7,
        0, 0, 0, 0, 0, 0, 0, 0
    ]

    ISOLATED_PAWN_MIDDLEGAME_BONUSES: array[Square(0)..Square(63), Weight] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        37, 42, 52, 66, 18, 4, -52, -50,
        13, 20, 5, 12, -11, -8, 51, -21,
        22, 5, -5, -9, -11, 30, 53, 14,
        -1, -7, -50, -46, -32, -23, -8, -8,
        -14, -21, -44, -18, -58, -31, -37, -47,
        -27, -42, -27, -76, -76, -35, -22, -55,
        0, 0, 0, 0, 0, 0, 0, 0
    ]

    ISOLATED_PAWN_ENDGAME_BONUSES: array[Square(0)..Square(63), Weight] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        52, -49, 49, 51, 57, 79, 94, 89,
        -7, -69, -18, 5, -1, -11, -22, -32,
        -31, -64, -43, -40, -46, -46, -67, -45,
        -17, -40, -25, -36, -54, -34, -40, -17,
        -15, -28, -31, -26, -37, -32, -22, -9,
        -17, -4, -36, -4, -39, -19, -27, 1,
        0, 0, 0, 0, 0, 0, 0, 0
    ]

    KNIGHT_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        -176, -111, -19, 66, 87, 37, -8, -92,
        28, 71, 130, 146, 102, 214, 78, 102,
        56, 131, 169, 169, 220, 211, 159, 96,
        81, 99, 135, 210, 142, 194, 80, 146,
        56, 78, 118, 127, 148, 135, 142, 93,
        2, 52, 78, 96, 131, 106, 104, 65,
        -4, 14, 48, 91, 91, 55, 37, 58,
        -82, 22, -12, 40, 52, 43, 39, -40
    ]

    KNIGHT_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        -16, 55, 82, 61, 85, 24, 62, -81,
        69, 93, 93, 93, 81, 60, 83, 40,
        100, 93, 144, 136, 111, 110, 76, 72,
        101, 126, 165, 159, 169, 153, 138, 97,
        128, 130, 173, 163, 162, 131, 117, 115,
        92, 102, 117, 149, 132, 97, 84, 110,
        111, 99, 98, 104, 92, 91, 83, 126,
        76, 80, 80, 96, 90, 60, 89, 115
    ]

    BISHOP_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        46, 6, 2, -64, -7, 8, 31, -3,
        73, 122, 84, 74, 118, 97, 76, 84,
        84, 130, 134, 154, 140, 168, 141, 117,
        72, 119, 132, 177, 170, 133, 116, 72,
        80, 77, 117, 169, 155, 103, 101, 116,
        80, 136, 126, 130, 132, 133, 132, 124,
        117, 128, 148, 101, 132, 120, 147, 127,
        89, 152, 96, 69, 70, 67, 95, 122
    ]

    BISHOP_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        135, 147, 141, 142, 147, 122, 138, 109,
        105, 132, 135, 134, 125, 132, 150, 98,
        145, 150, 161, 125, 143, 158, 142, 150,
        141, 157, 159, 176, 161, 160, 149, 138,
        141, 170, 170, 165, 171, 164, 150, 104,
        137, 149, 155, 155, 174, 151, 137, 124,
        153, 113, 103, 138, 134, 123, 125, 118,
        124, 130, 123, 123, 122, 152, 135, 85
    ]

    ROOK_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        149, 125, 132, 125, 135, 165, 153, 182,
        138, 135, 170, 209, 178, 233, 206, 229,
        125, 194, 185, 201, 248, 246, 323, 247,
        113, 153, 157, 173, 190, 206, 218, 191,
        95, 88, 113, 150, 144, 119, 191, 158,
        99, 108, 119, 134, 149, 161, 229, 187,
        101, 109, 143, 158, 164, 159, 195, 135,
        146, 147, 155, 169, 172, 145, 178, 153
    ]

    ROOK_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        333, 329, 340, 327, 316, 323, 333, 310,
        318, 343, 341, 318, 314, 313, 307, 274,
        318, 306, 307, 298, 271, 271, 256, 266,
        311, 312, 321, 303, 267, 269, 266, 270,
        304, 315, 304, 292, 283, 281, 254, 262,
        285, 287, 279, 267, 250, 234, 193, 222,
        271, 270, 261, 256, 242, 240, 201, 236,
        293, 285, 279, 271, 253, 271, 250, 259
    ]

    QUEEN_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        303, 323, 410, 437, 409, 443, 450, 371,
        362, 292, 303, 329, 310, 359, 323, 443,
        353, 348, 360, 360, 376, 422, 426, 396,
        342, 348, 337, 335, 346, 370, 387, 380,
        349, 337, 341, 356, 364, 359, 382, 391,
        345, 365, 357, 350, 357, 378, 408, 394,
        368, 369, 387, 396, 398, 388, 401, 425,
        336, 347, 366, 384, 373, 324, 356, 372
    ]

    QUEEN_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        633, 625, 661, 639, 664, 622, 601, 603,
        630, 694, 753, 734, 775, 730, 699, 685,
        632, 654, 721, 752, 755, 728, 680, 690,
        667, 694, 717, 759, 782, 737, 764, 721,
        665, 703, 713, 749, 736, 742, 719, 699,
        632, 676, 692, 698, 706, 692, 654, 654,
        615, 597, 610, 629, 630, 570, 517, 514,
        607, 601, 600, 628, 580, 565, 549, 576
    ]

    KING_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        -156, -114, -89, -113, -99, -33, 63, -25,
        -134, 42, -22, 58, -1, 55, 126, 21,
        -152, 114, -8, -13, 72, 156, 77, -49,
        -117, -32, -41, -128, -99, -40, -69, -214,
        -106, -35, -67, -150, -138, -61, -103, -251,
        -53, 41, -33, -49, -36, -38, 1, -123,
        42, 43, 28, -28, -30, -4, 78, 17,
        -20, 100, 52, -114, -3, -83, 50, -13
    ]

    KING_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        -198, -89, -75, -6, -9, -3, -33, -199,
        -67, 29, 67, 85, 107, 97, 66, -11,
        -29, 55, 123, 156, 160, 140, 101, -3,
        -42, 59, 128, 198, 209, 150, 90, 6,
        -62, 23, 119, 186, 179, 113, 48, -12,
        -81, -10, 55, 97, 90, 56, -6, -43,
        -95, -33, -4, 25, 31, 9, -41, -96,
        -160, -136, -78, -51, -87, -58, -116, -177
    ]

    # Piece weights
    MIDDLEGAME_WEIGHTS: array[PieceKind.Bishop..PieceKind.Rook, Weight] = [387, 0, 389, 123, 929, 496]
    ENDGAME_WEIGHTS: array[PieceKind.Bishop..PieceKind.Rook, Weight]    = [418, 0, 422, 173, 1004, 671]

    # Flat bonuses (middlegame, endgame)
    ROOK_OPEN_FILE_BONUS*: tuple[mg, eg: Weight] = (81, 26)
    ROOK_SEMI_OPEN_FILE_BONUS*: tuple[mg, eg: Weight] = (32, 23)
    DOUBLED_PAWNS_BONUS*: tuple[mg, eg: Weight] = (0, 0)
    BISHOP_PAIR_BONUS*: tuple[mg, eg: Weight] = (62, 147)
    CONNECTED_ROOKS_BONUS*: tuple[mg, eg: Weight] = (0, 0)
    STRONG_PAWNS_BONUS*: tuple[mg, eg: Weight] = (22, 24)
    PAWN_THREATS_MINOR_BONUS*: tuple[mg, eg: Weight] = (0, 0)
    PAWN_THREATS_MAJOR_BONUS*: tuple[mg, eg: Weight] = (0, 0)
    MINOR_THREATS_MAJOR_BONUS*: tuple[mg, eg: Weight] = (0, 0)
    ROOK_THREATS_QUEEN_BONUS*: tuple[mg, eg: Weight] = (0, 0)
    
    # Tapered mobility bonuses
    BISHOP_MOBILITY_MIDDLEGAME_BONUS: array[14, Weight] = [106, 132, 158, 171, 193, 199, 210, 213, 217, 226, 238, 257, 247, 183]
    BISHOP_MOBILITY_ENDGAME_BONUS: array[14, Weight] = [88, 121, 159, 191, 220, 248, 260, 263, 264, 263, 258, 258, 282, 249]
    KNIGHT_MOBILITY_MIDDLEGAME_BONUS: array[9, Weight] = [95, 137, 161, 172, 182, 199, 210, 224, 244]
    KNIGHT_MOBILITY_ENDGAME_BONUS: array[9, Weight] = [74, 137, 188, 215, 243, 258, 254, 245, 224]
    ROOK_MOBILITY_MIDDLEGAME_BONUS: array[15, Weight] = [171, 193, 195, 206, 196, 213, 216, 218, 224, 224, 238, 231, 237, 229, 169]
    ROOK_MOBILITY_ENDGAME_BONUS: array[15, Weight] = [288, 347, 361, 370, 388, 400, 409, 420, 426, 437, 435, 441, 441, 434, 462]
    QUEEN_MOBILITY_MIDDLEGAME_BONUS: array[28, Weight] = [411, 446, 428, 435, 438, 445, 453, 456, 465, 463, 468, 473, 476, 477, 479, 496, 498, 513, 546, 583, 617, 701, 700, 698, 732, 686, 555, 560]
    QUEEN_MOBILITY_ENDGAME_BONUS: array[28, Weight] = [314, 401, 523, 580, 647, 672, 709, 764, 780, 786, 806, 829, 832, 854, 854, 866, 877, 865, 849, 838, 812, 800, 773, 779, 756, 739, 607, 571]
    KING_MOBILITY_MIDDLEGAME_BONUS: array[28, Weight] = [0, 0, 0, 140, 156, 112, 82, 59, 40, 20, 20, -12, -19, -42, -65, -99, -132, -167, -199, -217, -226, -249, -246, -251, -319, -272, -285, -248]
    KING_MOBILITY_ENDGAME_BONUS: array[28, Weight] = [0, 0, 0, -11, -53, 5, 3, -8, -4, -6, -9, 15, 8, 21, 19, 29, 30, 27, 27, 10, 9, -9, -31, -44, -52, -98, -108, -152]

    KING_ZONE_ATTACKS_MIDDLEGAME_BONUS*: array[9, Weight] = [97, 87, 47, -30, -135, -232, -322, -361, -459]
    KING_ZONE_ATTACKS_ENDGAME_BONUS*: array[9, Weight] = [-27, -16, -13, -12, 1, 20, 43, 33, 43]

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
