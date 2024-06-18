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
        135, 188, 150, 157, 201, 150, 79, -43,
        29, 33, 134, 109, 161, 218, 129, 85,
        -16, 17, 32, 43, 89, 80, 29, 25,
        -26, -7, 22, 53, 60, 45, 3, -2,
        -39, -18, -1, 4, 31, 23, 28, 12,
        -10, 0, 13, 19, 39, 51, 51, 14,
        0, 0, 0, 0, 0, 0, 0, 0
    ]

    PAWN_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        269, 308, 275, 206, 249, 193, 208, 232,
        176, 238, 189, 208, 171, 112, 198, 182,
        126, 114, 90, 58, 59, 53, 90, 90,
        77, 84, 45, 48, 46, 34, 56, 35,
        64, 59, 54, 73, 70, 43, 40, 31,
        88, 77, 73, 84, 125, 73, 55, 37,
        0, 0, 0, 0, 0, 0, 0, 0
    ]

    PASSED_PAWN_MIDDLEGAME_BONUSES: array[Square(0)..Square(63), Weight] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        42, 91, 83, 97, -4, 55, 60, 61,
        88, 110, 15, 35, 3, -5, 2, -47,
        46, 30, 36, 9, -10, 18, -14, -1,
        12, 5, -13, -31, -52, -14, 5, 12,
        3, -34, -40, -25, -38, -23, -25, 22,
        -18, -2, -33, -37, 10, -24, 20, 14,
        0, 0, 0, 0, 0, 0, 0, 0
    ]

    PASSED_PAWN_ENDGAME_BONUSES: array[Square(0)..Square(63), Weight] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        220, 214, 185, 152, 114, 178, 244, 247,
        269, 260, 192, 65, 98, 189, 214, 281,
        174, 191, 123, 97, 105, 121, 168, 170,
        107, 110, 74, 62, 86, 85, 116, 105,
        19, 58, 37, 2, 17, 21, 69, 17,
        16, 19, 14, -14, -52, -2, 5, 17,
        0, 0, 0, 0, 0, 0, 0, 0
    ]

    ISOLATED_PAWN_MIDDLEGAME_BONUSES: array[Square(0)..Square(63), Weight] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        22, 42, 41, 84, 16, 3, -43, -58,
        22, 23, 5, 4, -15, 2, 41, -15,
        12, 8, 0, -4, -11, 37, 57, 12,
        -3, -15, -55, -49, -40, -21, 6, -15,
        -17, -16, -46, -14, -63, -27, -44, -48,
        -24, -39, -28, -81, -67, -31, -28, -58,
        0, 0, 0, 0, 0, 0, 0, 0
    ]

    ISOLATED_PAWN_ENDGAME_BONUSES: array[Square(0)..Square(63), Weight] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        51, -50, 56, 50, 56, 67, 71, 87,
        -7, -68, -25, 8, -5, -8, -22, -44,
        -30, -66, -40, -42, -52, -57, -66, -38,
        -7, -34, -19, -44, -48, -32, -40, -19,
        -12, -26, -20, -31, -36, -28, -26, -10,
        -23, -10, -36, -2, -41, -19, -32, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    ]

    KNIGHT_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        -187, -123, -35, 62, 88, 38, -3, -85,
        -2, 43, 81, 111, 95, 192, 92, 97,
        47, 128, 151, 175, 185, 198, 133, 103,
        74, 94, 142, 207, 147, 192, 71, 148,
        51, 71, 116, 130, 146, 141, 145, 91,
        10, 61, 86, 101, 133, 108, 103, 71,
        -10, 22, 50, 93, 101, 63, 43, 56,
        -76, 26, -8, 33, 54, 44, 45, -9
    ]

    KNIGHT_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        -35, 49, 83, 53, 87, 13, 28, -99,
        65, 83, 99, 82, 74, 49, 64, 35,
        83, 89, 148, 136, 124, 111, 79, 71,
        99, 123, 167, 156, 161, 157, 128, 95,
        132, 123, 167, 153, 165, 145, 116, 106,
        95, 94, 121, 154, 135, 94, 95, 108,
        112, 103, 92, 99, 101, 87, 94, 126,
        79, 77, 80, 95, 94, 68, 81, 112
    ]

    BISHOP_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        71, 0, -21, -35, -6, 9, 32, -7,
        77, 71, 80, 77, 71, 82, 48, 83,
        77, 118, 118, 145, 129, 169, 127, 115,
        56, 124, 118, 180, 166, 138, 118, 81,
        86, 65, 112, 163, 154, 110, 98, 109,
        80, 136, 130, 134, 130, 133, 126, 128,
        107, 128, 152, 106, 134, 127, 149, 127,
        91, 159, 102, 67, 76, 65, 92, 127
    ]

    BISHOP_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        137, 139, 141, 153, 150, 126, 133, 115,
        110, 140, 128, 132, 115, 124, 146, 96,
        160, 135, 154, 128, 128, 161, 136, 153,
        152, 159, 160, 174, 153, 166, 146, 139,
        136, 167, 174, 172, 163, 150, 139, 115,
        149, 149, 153, 163, 175, 155, 137, 128,
        158, 111, 115, 136, 133, 118, 128, 109,
        125, 119, 122, 125, 114, 161, 129, 89
    ]

    ROOK_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        147, 119, 129, 117, 140, 158, 124, 179,
        151, 132, 178, 207, 173, 219, 214, 243,
        134, 193, 185, 187, 262, 250, 343, 246,
        110, 165, 149, 172, 190, 202, 212, 203,
        96, 97, 107, 142, 145, 126, 185, 161,
        100, 101, 120, 145, 149, 163, 230, 174,
        102, 113, 141, 151, 167, 151, 196, 137,
        147, 152, 158, 165, 174, 145, 174, 151
    ]

    ROOK_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        314, 333, 340, 338, 321, 323, 329, 312,
        315, 336, 343, 310, 312, 294, 297, 273,
        310, 307, 304, 293, 266, 263, 251, 259,
        326, 303, 325, 300, 263, 267, 267, 261,
        309, 309, 300, 283, 283, 272, 256, 254,
        290, 292, 276, 268, 239, 243, 190, 217,
        274, 276, 261, 257, 241, 237, 216, 222,
        296, 277, 289, 275, 254, 274, 246, 263
    ]

    QUEEN_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        308, 349, 401, 428, 423, 447, 453, 378,
        356, 297, 307, 340, 321, 363, 352, 440,
        365, 367, 361, 357, 389, 421, 427, 400,
        336, 350, 346, 338, 353, 369, 382, 371,
        341, 334, 339, 363, 366, 358, 373, 393,
        342, 364, 359, 361, 364, 387, 405, 396,
        366, 359, 383, 393, 396, 389, 410, 420,
        327, 341, 359, 380, 380, 325, 368, 357
    ]

    QUEEN_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        625, 635, 634, 642, 658, 630, 575, 609,
        630, 692, 736, 733, 789, 721, 689, 676,
        634, 641, 714, 753, 750, 723, 673, 687,
        657, 697, 724, 759, 769, 761, 762, 731,
        668, 712, 724, 742, 734, 735, 718, 714,
        620, 674, 704, 693, 715, 697, 651, 648,
        614, 609, 609, 628, 633, 566, 525, 524,
        623, 603, 613, 640, 569, 576, 566, 561
    ]

    KING_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        -116, -122, -68, -138, -102, -23, 48, 4,
        -138, 43, -45, 82, 14, 37, 138, 56,
        -162, 103, -2, -22, 55, 172, 79, -54,
        -128, -8, -18, -112, -96, -30, -58, -197,
        -129, -23, -50, -151, -138, -61, -105, -260,
        -74, 40, -25, -62, -31, -43, -2, -126,
        59, 42, 36, -34, -33, -8, 75, 13,
        -14, 109, 49, -117, -7, -78, 53, -11
    ]

    KING_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = [
        -204, -108, -75, -3, -24, -19, -36, -197,
        -65, 36, 75, 79, 92, 116, 70, -12,
        -28, 57, 126, 169, 166, 151, 98, -4,
        -50, 56, 136, 202, 193, 157, 87, 11,
        -65, 31, 109, 178, 182, 107, 47, -14,
        -83, -8, 60, 97, 92, 53, -8, -45,
        -105, -32, -7, 19, 27, 7, -42, -93,
        -166, -138, -80, -46, -87, -55, -109, -184
    ]

    # Piece weights
    MIDDLEGAME_WEIGHTS: array[PieceKind.Bishop..PieceKind.Rook, Weight] = [387, 0, 387, 123, 928, 497]
    ENDGAME_WEIGHTS: array[PieceKind.Bishop..PieceKind.Rook, Weight]    = [416, 0, 424, 174, 1004, 668]

    # Flat bonuses (middlegame, endgame)
    ROOK_OPEN_FILE_BONUS*: tuple[mg, eg: Weight] = (83, 27)
    ROOK_SEMI_OPEN_FILE_BONUS*: tuple[mg, eg: Weight] = (29, 28)
    DOUBLED_PAWNS_BONUS*: tuple[mg, eg: Weight] = (0, 0)
    BISHOP_PAIR_BONUS*: tuple[mg, eg: Weight] = (62, 146)
    CONNECTED_ROOKS_BONUS*: tuple[mg, eg: Weight] = (0, 0)
    STRONG_PAWNS_BONUS*: tuple[mg, eg: Weight] = (24, 19)
    PAWN_THREATS_MINOR_BONUS*: tuple[mg, eg: Weight] = (17, -43)
    PAWN_THREATS_MAJOR_BONUS*: tuple[mg, eg: Weight] = (10, -29)
    MINOR_THREATS_MAJOR_BONUS*: tuple[mg, eg: Weight] = (91, -8)
    ROOK_THREATS_QUEEN_BONUS*: tuple[mg, eg: Weight] = (182, -152)
    
    # Tapered mobility bonuses
    BISHOP_MOBILITY_MIDDLEGAME_BONUS: array[14, Weight] = [103, 130, 159, 173, 191, 197, 208, 213, 216, 223, 239, 237, 205, 203]
    BISHOP_MOBILITY_ENDGAME_BONUS: array[14, Weight] = [89, 125, 161, 191, 217, 246, 250, 261, 268, 266, 255, 259, 272, 257]
    KNIGHT_MOBILITY_MIDDLEGAME_BONUS: array[9, Weight] = [90, 136, 157, 169, 182, 192, 207, 227, 246]
    KNIGHT_MOBILITY_ENDGAME_BONUS: array[9, Weight] = [57, 136, 187, 216, 235, 254, 256, 249, 214]
    ROOK_MOBILITY_MIDDLEGAME_BONUS: array[15, Weight] = [164, 193, 197, 206, 199, 213, 216, 212, 229, 229, 232, 233, 235, 230, 184]
    ROOK_MOBILITY_ENDGAME_BONUS: array[15, Weight] = [281, 343, 357, 372, 390, 399, 411, 415, 423, 434, 437, 447, 449, 432, 459]
    QUEEN_MOBILITY_MIDDLEGAME_BONUS: array[28, Weight] = [386, 439, 420, 427, 437, 445, 454, 451, 466, 463, 469, 472, 485, 483, 489, 492, 502, 518, 552, 574, 627, 702, 677, 685, 739, 701, 552, 549]
    QUEEN_MOBILITY_ENDGAME_BONUS: array[28, Weight] = [280, 366, 528, 597, 656, 673, 720, 762, 779, 795, 817, 823, 831, 845, 850, 857, 875, 868, 851, 838, 822, 794, 791, 772, 758, 737, 615, 568]
    KING_MOBILITY_MIDDLEGAME_BONUS: array[28, Weight] = [0, 0, 0, 127, 163, 112, 81, 61, 39, 23, 16, -5, -17, -45, -68, -94, -125, -162, -205, -226, -237, -238, -243, -261, -304, -269, -290, -221]
    KING_MOBILITY_ENDGAME_BONUS: array[28, Weight] = [0, 0, 0, -31, -52, 3, -1, -14, -4, -3, -4, 19, 10, 21, 24, 31, 28, 25, 27, 19, 4, -10, -27, -48, -68, -96, -116, -147]

    KING_ZONE_ATTACKS_MIDDLEGAME_BONUS*: array[9, Weight] = [102, 86, 43, -30, -132, -233, -326, -372, -465]
    KING_ZONE_ATTACKS_ENDGAME_BONUS*: array[9, Weight] = [-29, -27, -8, -9, 6, 23, 42, 46, 38]

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
