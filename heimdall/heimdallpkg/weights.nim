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

import heimdallpkg/pieces


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
    return weight.int16()

func eg*(weight: WeightPair): Weight {.inline.} =
    ## Returns the endgame score
    ## of the weight pair
    return ((weight + 0x8000) shr 16).int16()


const
    TEMPO_WEIGHT* = Weight(10)

    # Piece-square tables

    PAWN_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0),
    S(132, 281), S(178, 308), S(133, 276), S(150, 215), S(201, 253), S(166, 201), S(93, 213), S(-29, 240),
    S(22, 184), S(20, 245), S(123, 199), S(100, 208), S(160, 177), S(217, 111), S(136, 202), S(82, 182),
    S(-16, 128), S(18, 116), S(30, 95), S(46, 67), S(90, 63), S(82, 52), S(28, 94), S(21, 96),
    S(-26, 70), S(-4, 78), S(21, 51), S(58, 46), S(57, 50), S(44, 39), S(-1, 57), S(1, 40),
    S(-34, 66), S(-15, 56), S(2, 52), S(10, 70), S(30, 73), S(17, 47), S(26, 42), S(10, 35),
    S(-16, 88), S(1, 80), S(15, 78), S(16, 75), S(38, 133), S(54, 76), S(53, 54), S(11, 44),
    S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0)
    ]

    PASSED_PAWN_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0),
    S(47, 229), S(98, 221), S(96, 201), S(87, 158), S(3, 112), S(68, 166), S(67, 262), S(53, 249),
    S(76, 281), S(101, 264), S(-2, 191), S(40, 60), S(19, 102), S(-6, 212), S(27, 201), S(-46, 289),
    S(49, 175), S(25, 194), S(31, 127), S(9, 96), S(-5, 108), S(11, 128), S(-12, 182), S(-10, 175),
    S(23, 107), S(0, 105), S(-23, 79), S(-24, 59), S(-52, 86), S(-25, 91), S(3, 126), S(0, 120),
    S(-5, 20), S(-32, 56), S(-37, 38), S(-40, -2), S(-41, 16), S(-24, 28), S(-28, 63), S(31, 26),
    S(-13, 16), S(-3, 28), S(-36, 17), S(-13, -22), S(14, -37), S(-22, 3), S(17, 7), S(11, 19),
    S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0)
    ]

    ISOLATED_PAWN_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0),
    S(44, 48), S(57, -66), S(62, 48), S(55, 63), S(28, 71), S(20, 75), S(-68, 89), S(-52, 86),
    S(11, -15), S(27, -66), S(2, -31), S(4, 0), S(1, -9), S(-11, -7), S(30, -29), S(-14, -39),
    S(18, -32), S(4, -71), S(5, -45), S(-1, -36), S(-13, -48), S(32, -54), S(64, -57), S(12, -46),
    S(0, -13), S(-12, -38), S(-53, -28), S(-51, -39), S(-38, -55), S(-24, -32), S(-3, -29), S(-11, -27),
    S(-13, -12), S(-17, -33), S(-43, -24), S(-13, -34), S(-61, -34), S(-23, -34), S(-38, -27), S(-46, -9),
    S(-22, -21), S(-40, -16), S(-26, -34), S(-75, 7), S(-66, -39), S(-20, -19), S(-20, -29), S(-58, -4),
    S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0), S(0, 0)
    ]

    KNIGHT_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    S(-177, -22), S(-91, 53), S(-35, 86), S(48, 42), S(69, 84), S(5, 25), S(-58, 55), S(-66, -66),
    S(16, 71), S(67, 90), S(80, 100), S(94, 101), S(78, 70), S(182, 42), S(90, 73), S(113, 52),
    S(41, 91), S(128, 96), S(138, 147), S(174, 135), S(179, 112), S(200, 84), S(131, 68), S(78, 80),
    S(80, 112), S(98, 126), S(140, 159), S(210, 153), S(142, 157), S(162, 160), S(82, 143), S(136, 102),
    S(50, 151), S(82, 133), S(122, 156), S(132, 157), S(146, 156), S(135, 148), S(124, 113), S(91, 116),
    S(8, 107), S(53, 97), S(87, 119), S(109, 149), S(134, 138), S(108, 99), S(113, 85), S(72, 119),
    S(-7, 109), S(23, 130), S(56, 110), S(92, 101), S(96, 104), S(63, 84), S(42, 92), S(72, 129),
    S(-65, 90), S(28, 84), S(-8, 95), S(49, 99), S(62, 101), S(54, 78), S(50, 101), S(-26, 116)
    ]

    BISHOP_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    S(44, 123), S(10, 162), S(5, 141), S(-42, 157), S(5, 139), S(-2, 118), S(31, 142), S(1, 121),
    S(54, 118), S(79, 140), S(79, 128), S(72, 144), S(76, 124), S(89, 113), S(65, 148), S(92, 102),
    S(77, 151), S(115, 151), S(121, 155), S(154, 134), S(136, 134), S(162, 156), S(121, 141), S(120, 152),
    S(62, 163), S(117, 157), S(119, 161), S(171, 184), S(153, 159), S(123, 165), S(111, 149), S(74, 141),
    S(83, 136), S(76, 162), S(108, 173), S(159, 171), S(160, 174), S(114, 153), S(87, 147), S(115, 114),
    S(82, 149), S(142, 150), S(125, 161), S(131, 161), S(132, 179), S(140, 150), S(136, 140), S(122, 127),
    S(116, 160), S(131, 122), S(149, 106), S(105, 137), S(136, 136), S(121, 130), S(148, 143), S(127, 100),
    S(82, 128), S(149, 129), S(110, 131), S(80, 133), S(83, 138), S(76, 162), S(99, 140), S(132, 90)
    ]

    ROOK_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    S(165, 313), S(131, 317), S(137, 356), S(134, 344), S(159, 315), S(155, 313), S(137, 326), S(207, 315),
    S(140, 321), S(135, 339), S(180, 346), S(211, 317), S(181, 316), S(236, 309), S(199, 306), S(225, 285),
    S(128, 317), S(195, 307), S(184, 301), S(183, 291), S(250, 271), S(231, 256), S(318, 261), S(228, 258),
    S(119, 324), S(156, 314), S(153, 321), S(179, 298), S(191, 268), S(193, 269), S(195, 280), S(187, 268),
    S(105, 315), S(89, 306), S(112, 309), S(138, 295), S(139, 282), S(112, 283), S(171, 262), S(167, 261),
    S(100, 294), S(109, 287), S(125, 272), S(142, 272), S(154, 256), S(154, 244), S(218, 207), S(194, 217),
    S(102, 280), S(116, 289), S(137, 275), S(148, 271), S(166, 243), S(156, 249), S(180, 222), S(130, 238),
    S(148, 300), S(148, 285), S(166, 300), S(173, 282), S(181, 266), S(161, 287), S(179, 254), S(159, 264)
    ]

    QUEEN_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    S(319, 601), S(354, 574), S(400, 617), S(436, 613), S(418, 640), S(447, 596), S(446, 521), S(386, 576),
    S(344, 606), S(282, 637), S(297, 699), S(328, 676), S(320, 737), S(351, 700), S(337, 638), S(439, 640),
    S(362, 589), S(352, 597), S(351, 643), S(340, 675), S(372, 682), S(393, 638), S(412, 596), S(371, 632),
    S(327, 606), S(329, 670), S(330, 675), S(328, 695), S(351, 714), S(353, 670), S(363, 686), S(360, 657),
    S(329, 630), S(317, 675), S(308, 704), S(341, 728), S(345, 684), S(341, 674), S(361, 660), S(366, 661),
    S(330, 603), S(346, 654), S(336, 682), S(337, 666), S(343, 663), S(368, 640), S(390, 619), S(369, 619),
    S(344, 585), S(347, 590), S(371, 582), S(379, 605), S(376, 602), S(375, 547), S(388, 492), S(413, 486),
    S(302, 592), S(340, 580), S(353, 585), S(372, 618), S(371, 566), S(316, 566), S(339, 546), S(344, 549)
    ]

    KING_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    S(-90, -208), S(-36, -106), S(25, -64), S(-44, 4), S(-31, -23), S(-13, -5), S(-33, -51), S(-33, -216),
    S(-88, -58), S(57, 42), S(14, 60), S(108, 62), S(73, 102), S(70, 110), S(105, 53), S(0, -12),
    S(-80, -24), S(163, 59), S(45, 108), S(72, 145), S(133, 160), S(193, 133), S(89, 102), S(-7, 6),
    S(-24, -48), S(7, 51), S(-1, 133), S(-79, 186), S(-53, 193), S(-28, 149), S(-39, 103), S(-194, 8),
    S(-71, -66), S(-15, 26), S(-48, 108), S(-140, 175), S(-115, 171), S(-72, 107), S(-106, 48), S(-230, -11),
    S(-61, -73), S(61, -12), S(-22, 57), S(-58, 93), S(-35, 91), S(-40, 50), S(5, 0), S(-124, -41),
    S(60, -92), S(31, -31), S(23, -6), S(-36, 14), S(-34, 27), S(-16, 8), S(64, -42), S(27, -96),
    S(-11, -147), S(101, -138), S(46, -72), S(-124, -39), S(-16, -72), S(-83, -47), S(47, -109), S(-15, -167)
    ]

    # Piece values
    PIECE_VALUES: array[PieceKind.Bishop..PieceKind.Rook, WeightPair] = [S(382, 415), S(0, 0), S(385, 425), S(123, 177), S(940, 1003), S(489, 674)]

    # Flat bonuses
    ROOK_OPEN_FILE_WEIGHT*: WeightPair = S(81, 24)
    ROOK_SEMI_OPEN_FILE_WEIGHT*: WeightPair = S(26, 28)
    BISHOP_PAIR_WEIGHT*: WeightPair = S(61, 145)
    STRONG_PAWNS_WEIGHT*: WeightPair = S(24, 22)
    PAWN_THREATS_MINOR_WEIGHT*: WeightPair = S(19, -41)
    PAWN_THREATS_MAJOR_WEIGHT*: WeightPair = S(17, -28)
    MINOR_THREATS_MAJOR_WEIGHT*: WeightPair = S(86, -12)
    ROOK_THREATS_QUEEN_WEIGHT*: WeightPair = S(166, -150)
    SAFE_CHECK_BISHOP_WEIGHT*: WeightPair = S(26, 64)
    SAFE_CHECK_KNIGHT_WEIGHT*: WeightPair = S(53, 17)
    SAFE_CHECK_ROOK_WEIGHT*: WeightPair = S(104, 20)
    SAFE_CHECK_QUEEN_WEIGHT*: WeightPair = S(27, 114)
    
    # Tapered mobility bonuses
    BISHOP_MOBILITY_WEIGHT: array[14, WeightPair] = [S(107, 97), S(131, 131), S(157, 168), S(172, 202), S(192, 222), S(199, 248), S(208, 253), S(210, 263), S(217, 273), S(225, 269), S(232, 263), S(246, 259), S(230, 289), S(194, 253)]
    KNIGHT_MOBILITY_WEIGHT: array[9, WeightPair] = [S(87, 58), S(136, 133), S(153, 190), S(168, 216), S(175, 239), S(194, 257), S(211, 264), S(227, 249), S(238, 223)]
    ROOK_MOBILITY_WEIGHT: array[15, WeightPair] = [S(169, 302), S(192, 359), S(197, 374), S(207, 378), S(200, 399), S(213, 403), S(219, 421), S(223, 423), S(234, 429), S(233, 443), S(235, 439), S(237, 445), S(243, 443), S(240, 436), S(205, 459)]
    QUEEN_MOBILITY_WEIGHT: array[28, WeightPair] = [S(394, 289), S(426, 394), S(424, 536), S(424, 615), S(425, 670), S(438, 692), S(447, 738), S(444, 774), S(456, 797), S(456, 803), S(460, 813), S(468, 827), S(471, 827), S(467, 845), S(472, 833), S(497, 827), S(500, 832), S(516, 801), S(552, 769), S(596, 730), S(622, 706), S(687, 662), S(667, 646), S(621, 628), S(648, 602), S(551, 571), S(369, 411), S(384, 394)]
    KING_MOBILITY_WEIGHT: array[28, WeightPair] = [S(0, 0), S(0, 0), S(0, 0), S(91, -69), S(116, -85), S(68, -15), S(41, -24), S(26, -26), S(5, -3), S(-2, -15), S(3, -9), S(-30, 20), S(-30, 12), S(-45, 21), S(-63, 33), S(-76, 40), S(-87, 36), S(-103, 31), S(-110, 30), S(-111, 26), S(-92, 3), S(-63, -9), S(-60, -23), S(-24, -45), S(-67, -47), S(-16, -87), S(-69, -90), S(16, -120)]

    KING_ZONE_ATTACKS_WEIGHT*: array[9, WeightPair] = [S(99, -22), S(86, -15), S(42, -13), S(-26, -13), S(-137, 1), S(-234, 18), S(-323, 29), S(-388, 29), S(-499, 18)]

    PIECE_TABLES: array[PieceKind.Bishop..PieceKind.Rook, array[Square(0)..Square(63), WeightPair]] = [
        BISHOP_WEIGHTS,
        KING_WEIGHTS,
        KNIGHT_WEIGHTS,
        PAWN_WEIGHTS,
        QUEEN_WEIGHTS,
        ROOK_WEIGHTS
    ]


var
    PIECE_SQUARE_TABLES*: array[PieceColor.White..PieceColor.Black, array[PieceKind.Bishop..PieceKind.Rook, array[Square(0)..Square(63), WeightPair]]]
    PASSED_PAWN_TABLE*: array[PieceColor.White..PieceColor.Black, array[Square(0)..Square(63), WeightPair]]
    ISOLATED_PAWN_TABLE*: array[PieceColor.White..PieceColor.Black, array[Square(0)..Square(63), WeightPair]]


proc initializeTables =
    ## Initializes the piece-square tables with the correct values
    ## relative to the side that is moving (they are white-relative
    ## by default, so we need to flip the scores for black)
    for kind in PieceKind.Bishop..PieceKind.Rook:
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
