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
    WeightPair* = int32


func S(mg, eg: Weight): WeightPair {.inline.} =
    ## Packs a pair of weights into
    ## a single integer
    return WeightPair((eg.int32 shl 16) + mg.int32)

func mg*(weight: WeightPair): Weight {.inline.} =
    ## Returns the middlegame score
    ## of the weight pair
    return cast[int16](weight)

func eg*(weight: WeightPair): Weight {.inline.} =
    ## Returns the endgame score
    ## of the weight pair
    return cast[int16]((weight + 0x8000) shr 16)


const
    TEMPO_WEIGHT* = Weight(10)

    # Piece-square tables

    PAWN_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0),
    S(124, 250), S(183, 298), S(159, 252), S(175, 213), S(216, 242), S(180, 206), S(109, 253), S(4, 239),
    S(20, 151), S(83, 219), S(151, 187), S(127, 186), S(153, 180), S(205, 150), S(129, 202), S(38, 164),
    S(13, 112), S(16, 119), S(43, 100), S(73, 72), S(82, 66), S(68, 70), S(23, 109), S(24, 102),
    S(-9, 66), S(-3, 82), S(22, 57), S(45, 50), S(44, 49), S(27, 51), S(3, 66), S(-1, 56),
    S(-10, 60), S(-3, 66), S(3, 64), S(5, 69), S(15, 78), S(11, 67), S(11, 60), S(5, 41),
    S(-3, 65), S(10, 79), S(16, 96), S(13, 99), S(12, 107), S(39, 87), S(34, 66), S(16, 43),
    S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0)
    ]

    PASSED_PAWN_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0),
    S(88, 226), S(105, 240), S(111, 194), S(71, 150), S(69, 130), S(98, 174), S(116, 241), S(106, 262),
    S(88, 289), S(60, 240), S(1, 182), S(7, 115), S(6, 117), S(-41, 194), S(33, 220), S(40, 286),
    S(47, 166), S(36, 183), S(13, 137), S(-8, 117), S(-10, 111), S(-9, 137), S(19, 161), S(38, 161),
    S(32, 99), S(-11, 123), S(-37, 90), S(-22, 82), S(-37, 90), S(-35, 94), S(-17, 124), S(10, 98),
    S(-9, 32), S(-30, 45), S(-42, 36), S(-37, 23), S(-21, 19), S(-40, 19), S(-33, 58), S(9, 31),
    S(-23, 34), S(-2, 21), S(-22, 6), S(-10, 7), S(-10, 14), S(-8, -6), S(0, 19), S(-18, 30),
    S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0)
    ]

    ISOLATED_PAWN_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0),
    S(28, 22), S(4, -47), S(46, 17), S(39, 4), S(57, -12), S(16, 25), S(12, -4), S(9, 11),
    S(10, -26), S(8, -67), S(-23, -35), S(6, -50), S(-13, -62), S(-24, -23), S(13, -49), S(-2, -42),
    S(3, -30), S(20, -66), S(6, -50), S(-21, -48), S(-21, -49), S(11, -42), S(19, -62), S(8, -43),
    S(-18, -9), S(0, -43), S(-21, -24), S(-46, -46), S(-43, -46), S(-17, -21), S(2, -42), S(-12, -22),
    S(-22, -19), S(-18, -26), S(-40, -25), S(-31, -38), S(-48, -32), S(-35, -27), S(-33, -30), S(-40, -13),
    S(-22, -20), S(-42, -25), S(-39, -35), S(-44, -30), S(-44, -45), S(-55, -21), S(-31, -29), S(-34, -7),
    S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0)
    ]

    KNIGHT_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    S(-185, -47), S(-114, 31), S(-79, 81), S(3, 56), S(43, 50), S(-72, 60), S(-108, 42), S(-128, -107),
    S(-8, 16), S(2, 47), S(65, 54), S(121, 75), S(75, 89), S(117, 47), S(4, 37), S(10, 9),
    S(12, 57), S(121, 68), S(117, 132), S(120, 127), S(129, 119), S(139, 124), S(103, 62), S(19, 42),
    S(38, 59), S(55, 115), S(83, 155), S(131, 157), S(111, 169), S(109, 146), S(30, 131), S(42, 57),
    S(38, 83), S(69, 95), S(85, 130), S(92, 142), S(100, 134), S(84, 124), S(89, 95), S(55, 67),
    S(-13, 42), S(30, 51), S(53, 73), S(68, 99), S(69, 104), S(67, 75), S(51, 52), S(22, 35),
    S(-14, 55), S(-23, 65), S(10, 29), S(52, 64), S(51, 66), S(23, 28), S(-9, 49), S(13, 59),
    S(-57, -3), S(-9, 28), S(10, 21), S(10, 44), S(17, 53), S(11, 18), S(1, 37), S(-29, 6)
    ]

    BISHOP_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    S(-35, 130), S(-19, 114), S(-71, 119), S(-89, 130), S(-90, 144), S(-116, 131), S(-36, 114), S(-22, 138),
    S(-30, 115), S(25, 120), S(43, 125), S(4, 118), S(27, 117), S(32, 123), S(25, 133), S(-12, 98),
    S(50, 113), S(91, 145), S(104, 135), S(99, 120), S(119, 122), S(95, 142), S(107, 135), S(39, 132),
    S(36, 106), S(89, 136), S(83, 127), S(135, 148), S(128, 133), S(90, 124), S(81, 127), S(45, 114),
    S(57, 92), S(47, 116), S(85, 132), S(109, 131), S(104, 130), S(81, 133), S(71, 109), S(51, 91),
    S(47, 100), S(87, 116), S(75, 122), S(99, 118), S(84, 129), S(83, 113), S(83, 107), S(79, 100),
    S(81, 85), S(85, 68), S(80, 73), S(74, 101), S(80, 100), S(71, 93), S(96, 81), S(88, 79),
    S(84, 77), S(67, 87), S(64, 94), S(46, 74), S(38, 85), S(53, 106), S(50, 90), S(77, 66)
    ]

    ROOK_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    S(141, 313), S(130, 325), S(94, 339), S(92, 340), S(119, 340), S(99, 343), S(148, 326), S(161, 310),
    S(107, 307), S(99, 321), S(137, 321), S(170, 306), S(155, 316), S(166, 308), S(129, 315), S(134, 301),
    S(113, 300), S(211, 267), S(177, 286), S(205, 275), S(237, 254), S(185, 279), S(237, 246), S(147, 290),
    S(98, 280), S(132, 271), S(157, 279), S(191, 259), S(191, 250), S(167, 257), S(174, 259), S(134, 272),
    S(68, 249), S(91, 264), S(85, 261), S(101, 256), S(92, 261), S(86, 264), S(107, 256), S(84, 239),
    S(49, 224), S(102, 230), S(89, 220), S(95, 226), S(87, 214), S(88, 223), S(139, 209), S(86, 184),
    S(11, 226), S(65, 206), S(100, 216), S(105, 213), S(123, 204), S(107, 192), S(113, 181), S(32, 208),
    S(91, 232), S(112, 231), S(126, 238), S(142, 219), S(141, 213), S(127, 234), S(132, 223), S(108, 210)
    ]

    QUEEN_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    S(225, 571), S(249, 576), S(281, 591), S(297, 620), S(272, 626), S(295, 583), S(261, 586), S(234, 571),
    S(174, 587), S(126, 656), S(176, 670), S(130, 718), S(116, 783), S(212, 686), S(105, 689), S(178, 615),
    S(194, 597), S(215, 597), S(208, 638), S(215, 689), S(237, 682), S(208, 691), S(246, 616), S(190, 659),
    S(196, 594), S(225, 643), S(202, 650), S(206, 703), S(201, 707), S(205, 673), S(232, 667), S(210, 626),
    S(213, 567), S(221, 615), S(210, 628), S(209, 667), S(207, 645), S(212, 637), S(228, 600), S(234, 583),
    S(209, 521), S(232, 548), S(230, 565), S(220, 550), S(235, 551), S(233, 565), S(247, 525), S(228, 506),
    S(214, 489), S(235, 455), S(253, 446), S(259, 498), S(258, 498), S(257, 427), S(241, 447), S(212, 463),
    S(230, 455), S(241, 442), S(248, 451), S(256, 469), S(252, 452), S(244, 410), S(260, 423), S(228, 433)
    ]

    KING_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    S(-138, -224), S(-37, -100), S(-44, -77), S(-63, -11), S(-34, -37), S(-7, -51), S(38, -52), S(-116, -231),
    S(-87, -86), S(81, 50), S(47, 56), S(87, 40), S(92, 66), S(129, 76), S(86, 73), S(34, -63),
    S(-45, -9), S(188, 81), S(153, 129), S(106, 133), S(124, 133), S(223, 122), S(170, 97), S(1, -12),
    S(-77, -19), S(92, 66), S(101, 134), S(21, 185), S(45, 181), S(126, 137), S(91, 78), S(-130, -16),
    S(-75, -61), S(77, 22), S(57, 101), S(-3, 167), S(-4, 162), S(63, 103), S(48, 33), S(-129, -45),
    S(-81, -56), S(28, -17), S(31, 52), S(-11, 87), S(11, 85), S(-1, 58), S(24, -10), S(-97, -52),
    S(29, -81), S(27, -32), S(11, -3), S(-72, 31), S(-58, 23), S(-36, 10), S(33, -43), S(37, -99),
    S(-23, -181), S(29, -114), S(-23, -62), S(-120, -57), S(-58, -95), S(-102, -53), S(36, -110), S(-5, -196)
    ]

    # Piece values
    PIECE_VALUES: array[PieceKind.Pawn..PieceKind.King, WeightPair] = [S(118, 185), S(439, 533), S(427, 515), S(540, 784), S(1154, 1224), S(0, 0)]

    # Flat bonuses
    ROOK_OPEN_FILE_WEIGHT*: WeightPair = S(69, 23)
    ROOK_SEMI_OPEN_FILE_WEIGHT*: WeightPair = S(22, 21)
    BISHOP_PAIR_WEIGHT*: WeightPair = S(44, 159)
    STRONG_PAWNS_WEIGHT*: WeightPair = S(22, 17)
    PAWN_THREATS_MINOR_WEIGHT*: WeightPair = S(17, -16)
    PAWN_THREATS_MAJOR_WEIGHT*: WeightPair = S(18, -6)
    MINOR_THREATS_MAJOR_WEIGHT*: WeightPair = S(49, 4)
    ROOK_THREATS_QUEEN_WEIGHT*: WeightPair = S(96, -116)
    SAFE_CHECK_BISHOP_WEIGHT*: WeightPair = S(15, 15)
    SAFE_CHECK_KNIGHT_WEIGHT*: WeightPair = S(19, 19)
    SAFE_CHECK_ROOK_WEIGHT*: WeightPair = S(37, 37)
    SAFE_CHECK_QUEEN_WEIGHT*: WeightPair = S(36, 36)
    
    # Tapered mobility bonuses
    BISHOP_MOBILITY_WEIGHT: array[14, WeightPair] = [S(80, -40), S(102, 73), S(120, 133), S(133, 167), S(141, 198), S(148, 228), S(145, 248), S(152, 254), S(151, 262), S(159, 260), S(171, 252), S(184, 244), S(195, 257), S(205, 205)]
    KNIGHT_MOBILITY_WEIGHT: array[9, WeightPair] = [S(75, 17), S(91, 117), S(105, 162), S(113, 193), S(120, 212), S(129, 235), S(132, 231), S(156, 220), S(190, 181)]
    ROOK_MOBILITY_WEIGHT: array[15, WeightPair] = [S(134, 272), S(147, 318), S(151, 352), S(158, 373), S(159, 388), S(166, 404), S(168, 413), S(175, 421), S(179, 427), S(184, 440), S(188, 448), S(186, 442), S(185, 445), S(197, 422), S(234, 416)]
    QUEEN_MOBILITY_WEIGHT: array[28, WeightPair] = [S(260, 89), S(285, 191), S(303, 398), S(311, 549), S(321, 652), S(324, 694), S(332, 721), S(337, 747), S(347, 773), S(350, 786), S(347, 797), S(350, 814), S(358, 830), S(350, 849), S(347, 853), S(341, 872), S(339, 868), S(343, 861), S(358, 851), S(385, 823), S(405, 807), S(457, 774), S(458, 748), S(521, 717), S(526, 669), S(559, 636), S(465, 516), S(485, 536)]
    KING_MOBILITY_WEIGHT: array[28, WeightPair] = [S(0, 0), S(0, 0), S(0, 0), S(67, -34), S(71, -24), S(38, 36), S(25, 17), S(18, 14), S(9, 17), S(12, 14), S(12, 16), S(-8, 19), S(-11, 19), S(-25, 24), S(-29, 23), S(-50, 24), S(-59, 25), S(-66, 13), S(-79, 17), S(-83, 4), S(-74, -17), S(-71, -33), S(-75, -41), S(-77, -72), S(-101, -79), S(-101, -118), S(-170, -141), S(-81, -182)]

    KING_ZONE_ATTACKS_WEIGHT*: array[9, WeightPair] = [S(118, -24), S(96, -19), S(38, -16), S(-52, 1), S(-161, 7), S(-281, 23), S(-391, 45), S(-423, 32), S(-516, 13)]

    PIECE_TABLES: array[PieceKind.Pawn..PieceKind.King, array[Square(0)..Square(63), WeightPair]] = [
        PAWN_WEIGHTS,
        KNIGHT_WEIGHTS,
        BISHOP_WEIGHTS,
        ROOK_WEIGHTS,
        QUEEN_WEIGHTS,
        KING_WEIGHTS
    ]

    SAFE_CHECK_WEIGHT*: array[PieceKind.Pawn..PieceKind.King, WeightPair] = [0, SAFE_CHECK_KNIGHT_WEIGHT, SAFE_CHECK_BISHOP_WEIGHT, SAFE_CHECK_ROOK_WEIGHT, SAFE_CHECK_QUEEN_WEIGHT, 0]


var
    PIECE_SQUARE_TABLES*: array[PieceColor.White..PieceColor.Black, array[PieceKind.Pawn..PieceKind.King, array[Square(0)..Square(63), WeightPair]]]
    PASSED_PAWN_TABLE*: array[PieceColor.White..PieceColor.Black, array[Square(0)..Square(63), WeightPair]]
    ISOLATED_PAWN_TABLE*: array[PieceColor.White..PieceColor.Black, array[Square(0)..Square(63), WeightPair]]


proc initializeTables =
    ## Initializes the piece-square tables with the correct values
    ## relative to the side that is moving (they are white-relative
    ## by default, so we need to flip the scores for black)
    for kind in PieceKind.all():
        for sq in Square(0)..Square(63):
            let flipped = sq.flip()
            PIECE_SQUARE_TABLES[White][kind][sq] = PIECE_VALUES[kind] + PIECE_TABLES[kind][sq]
            PIECE_SQUARE_TABLES[Black][kind][sq] = PIECE_VALUES[kind] + PIECE_TABLES[kind][flipped]
            PASSED_PAWN_TABLE[White][sq] = PASSED_PAWN_WEIGHTS[sq]
            PASSED_PAWN_TABLE[Black][sq] = PASSED_PAWN_WEIGHTS[flipped]
            ISOLATED_PAWN_TABLE[White][sq] = ISOLATED_PAWN_WEIGHTS[sq]
            ISOLATED_PAWN_TABLE[Black][sq] = ISOLATED_PAWN_WEIGHTS[flipped]


func getMobilityBonus*(kind: PieceKind, moves: int): WeightPair {.inline.} =
    ## Returns the mobility bonus for the given piece type
    ## with the given number of (potentially pseudo-legal) moves
    case kind:
        of Bishop:
            return BISHOP_MOBILITY_WEIGHT[moves]
        of Knight:
            return KNIGHT_MOBILITY_WEIGHT[moves]
        of Rook:
            return ROOK_MOBILITY_WEIGHT[moves]
        of Queen:
            return QUEEN_MOBILITY_WEIGHT[moves]
        of King:
            return KING_MOBILITY_WEIGHT[moves]
        else:
            return S(0, 0)


initializeTables()
