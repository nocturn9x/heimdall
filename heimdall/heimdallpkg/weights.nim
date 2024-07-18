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
    WeightPair* = tuple[mg, eg: Weight]

const
    TEMPO_WEIGHT* = Weight(10)

    # Piece-square tables

    PAWN_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0),
    (132, 281), (178, 308), (133, 276), (150, 215), (201, 253), (166, 201), (93, 213), (-29, 240),
    (22, 184), (20, 245), (123, 199), (100, 208), (160, 177), (217, 111), (136, 202), (82, 182),
    (-16, 128), (18, 116), (30, 95), (46, 67), (90, 63), (82, 52), (28, 94), (21, 96),
    (-26, 70), (-4, 78), (21, 51), (58, 46), (57, 50), (44, 39), (-1, 57), (1, 40),
    (-34, 66), (-15, 56), (2, 52), (10, 70), (30, 73), (17, 47), (26, 42), (10, 35),
    (-16, 88), (1, 80), (15, 78), (16, 75), (38, 133), (54, 76), (53, 54), (11, 44),
    (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0)
    ]

    PASSED_PAWN_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0),
    (47, 229), (98, 221), (96, 201), (87, 158), (3, 112), (68, 166), (67, 262), (53, 249),
    (76, 281), (101, 264), (-2, 191), (40, 60), (19, 102), (-6, 212), (27, 201), (-46, 289),
    (49, 175), (25, 194), (31, 127), (9, 96), (-5, 108), (11, 128), (-12, 182), (-10, 175),
    (23, 107), (0, 105), (-23, 79), (-24, 59), (-52, 86), (-25, 91), (3, 126), (0, 120),
    (-5, 20), (-32, 56), (-37, 38), (-40, -2), (-41, 16), (-24, 28), (-28, 63), (31, 26),
    (-13, 16), (-3, 28), (-36, 17), (-13, -22), (14, -37), (-22, 3), (17, 7), (11, 19),
    (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0)
    ]

    ISOLATED_PAWN_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0),
    (44, 48), (57, -66), (62, 48), (55, 63), (28, 71), (20, 75), (-68, 89), (-52, 86),
    (11, -15), (27, -66), (2, -31), (4, 0), (1, -9), (-11, -7), (30, -29), (-14, -39),
    (18, -32), (4, -71), (5, -45), (-1, -36), (-13, -48), (32, -54), (64, -57), (12, -46),
    (0, -13), (-12, -38), (-53, -28), (-51, -39), (-38, -55), (-24, -32), (-3, -29), (-11, -27),
    (-13, -12), (-17, -33), (-43, -24), (-13, -34), (-61, -34), (-23, -34), (-38, -27), (-46, -9),
    (-22, -21), (-40, -16), (-26, -34), (-75, 7), (-66, -39), (-20, -19), (-20, -29), (-58, -4),
    (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0)
    ]

    KNIGHT_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    (-177, -22), (-91, 53), (-35, 86), (48, 42), (69, 84), (5, 25), (-58, 55), (-66, -66),
    (16, 71), (67, 90), (80, 100), (94, 101), (78, 70), (182, 42), (90, 73), (113, 52),
    (41, 91), (128, 96), (138, 147), (174, 135), (179, 112), (200, 84), (131, 68), (78, 80),
    (80, 112), (98, 126), (140, 159), (210, 153), (142, 157), (162, 160), (82, 143), (136, 102),
    (50, 151), (82, 133), (122, 156), (132, 157), (146, 156), (135, 148), (124, 113), (91, 116),
    (8, 107), (53, 97), (87, 119), (109, 149), (134, 138), (108, 99), (113, 85), (72, 119),
    (-7, 109), (23, 130), (56, 110), (92, 101), (96, 104), (63, 84), (42, 92), (72, 129),
    (-65, 90), (28, 84), (-8, 95), (49, 99), (62, 101), (54, 78), (50, 101), (-26, 116)
    ]

    BISHOP_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    (44, 123), (10, 162), (5, 141), (-42, 157), (5, 139), (-2, 118), (31, 142), (1, 121),
    (54, 118), (79, 140), (79, 128), (72, 144), (76, 124), (89, 113), (65, 148), (92, 102),
    (77, 151), (115, 151), (121, 155), (154, 134), (136, 134), (162, 156), (121, 141), (120, 152),
    (62, 163), (117, 157), (119, 161), (171, 184), (153, 159), (123, 165), (111, 149), (74, 141),
    (83, 136), (76, 162), (108, 173), (159, 171), (160, 174), (114, 153), (87, 147), (115, 114),
    (82, 149), (142, 150), (125, 161), (131, 161), (132, 179), (140, 150), (136, 140), (122, 127),
    (116, 160), (131, 122), (149, 106), (105, 137), (136, 136), (121, 130), (148, 143), (127, 100),
    (82, 128), (149, 129), (110, 131), (80, 133), (83, 138), (76, 162), (99, 140), (132, 90)
    ]

    ROOK_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    (165, 313), (131, 317), (137, 356), (134, 344), (159, 315), (155, 313), (137, 326), (207, 315),
    (140, 321), (135, 339), (180, 346), (211, 317), (181, 316), (236, 309), (199, 306), (225, 285),
    (128, 317), (195, 307), (184, 301), (183, 291), (250, 271), (231, 256), (318, 261), (228, 258),
    (119, 324), (156, 314), (153, 321), (179, 298), (191, 268), (193, 269), (195, 280), (187, 268),
    (105, 315), (89, 306), (112, 309), (138, 295), (139, 282), (112, 283), (171, 262), (167, 261),
    (100, 294), (109, 287), (125, 272), (142, 272), (154, 256), (154, 244), (218, 207), (194, 217),
    (102, 280), (116, 289), (137, 275), (148, 271), (166, 243), (156, 249), (180, 222), (130, 238),
    (148, 300), (148, 285), (166, 300), (173, 282), (181, 266), (161, 287), (179, 254), (159, 264)
    ]

    QUEEN_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    (319, 601), (354, 574), (400, 617), (436, 613), (418, 640), (447, 596), (446, 521), (386, 576),
    (344, 606), (282, 637), (297, 699), (328, 676), (320, 737), (351, 700), (337, 638), (439, 640),
    (362, 589), (352, 597), (351, 643), (340, 675), (372, 682), (393, 638), (412, 596), (371, 632),
    (327, 606), (329, 670), (330, 675), (328, 695), (351, 714), (353, 670), (363, 686), (360, 657),
    (329, 630), (317, 675), (308, 704), (341, 728), (345, 684), (341, 674), (361, 660), (366, 661),
    (330, 603), (346, 654), (336, 682), (337, 666), (343, 663), (368, 640), (390, 619), (369, 619),
    (344, 585), (347, 590), (371, 582), (379, 605), (376, 602), (375, 547), (388, 492), (413, 486),
    (302, 592), (340, 580), (353, 585), (372, 618), (371, 566), (316, 566), (339, 546), (344, 549)
    ]

    KING_WEIGHTS: array[Square(0)..Square(63), WeightPair] = [
    (-90, -208), (-36, -106), (25, -64), (-44, 4), (-31, -23), (-13, -5), (-33, -51), (-33, -216),
    (-88, -58), (57, 42), (14, 60), (108, 62), (73, 102), (70, 110), (105, 53), (0, -12),
    (-80, -24), (163, 59), (45, 108), (72, 145), (133, 160), (193, 133), (89, 102), (-7, 6),
    (-24, -48), (7, 51), (-1, 133), (-79, 186), (-53, 193), (-28, 149), (-39, 103), (-194, 8),
    (-71, -66), (-15, 26), (-48, 108), (-140, 175), (-115, 171), (-72, 107), (-106, 48), (-230, -11),
    (-61, -73), (61, -12), (-22, 57), (-58, 93), (-35, 91), (-40, 50), (5, 0), (-124, -41),
    (60, -92), (31, -31), (23, -6), (-36, 14), (-34, 27), (-16, 8), (64, -42), (27, -96),
    (-11, -147), (101, -138), (46, -72), (-124, -39), (-16, -72), (-83, -47), (47, -109), (-15, -167)
    ]

    # Piece values
    PIECE_VALUES: array[PieceKind.Bishop..PieceKind.Rook, WeightPair] = [(382, 415), (0, 0), (385, 425), (123, 177), (940, 1003), (489, 674)]

    # Flat bonuses
    ROOK_OPEN_FILE_WEIGHT*: WeightPair = (81, 24)
    ROOK_SEMI_OPEN_FILE_WEIGHT*: WeightPair = (26, 28)
    BISHOP_PAIR_WEIGHT*: WeightPair = (61, 145)
    STRONG_PAWNS_WEIGHT*: WeightPair = (24, 22)
    PAWN_THREATS_MINOR_WEIGHT*: WeightPair = (19, -41)
    PAWN_THREATS_MAJOR_WEIGHT*: WeightPair = (17, -28)
    MINOR_THREATS_MAJOR_WEIGHT*: WeightPair = (86, -12)
    ROOK_THREATS_QUEEN_WEIGHT*: WeightPair = (166, -150)
    SAFE_CHECK_BISHOP_WEIGHT*: WeightPair = (26, 64)
    SAFE_CHECK_KNIGHT_WEIGHT*: WeightPair = (53, 17)
    SAFE_CHECK_ROOK_WEIGHT*: WeightPair = (104, 20)
    SAFE_CHECK_QUEEN_WEIGHT*: WeightPair = (27, 114)
    
    # Tapered mobility bonuses
    BISHOP_MOBILITY_WEIGHT: array[14, WeightPair] = [(107, 97), (131, 131), (157, 168), (172, 202), (192, 222), (199, 248), (208, 253), (210, 263), (217, 273), (225, 269), (232, 263), (246, 259), (230, 289), (194, 253)]
    KNIGHT_MOBILITY_WEIGHT: array[9, WeightPair] = [(87, 58), (136, 133), (153, 190), (168, 216), (175, 239), (194, 257), (211, 264), (227, 249), (238, 223)]
    ROOK_MOBILITY_WEIGHT: array[15, WeightPair] = [(169, 302), (192, 359), (197, 374), (207, 378), (200, 399), (213, 403), (219, 421), (223, 423), (234, 429), (233, 443), (235, 439), (237, 445), (243, 443), (240, 436), (205, 459)]
    QUEEN_MOBILITY_WEIGHT: array[28, WeightPair] = [(394, 289), (426, 394), (424, 536), (424, 615), (425, 670), (438, 692), (447, 738), (444, 774), (456, 797), (456, 803), (460, 813), (468, 827), (471, 827), (467, 845), (472, 833), (497, 827), (500, 832), (516, 801), (552, 769), (596, 730), (622, 706), (687, 662), (667, 646), (621, 628), (648, 602), (551, 571), (369, 411), (384, 394)]
    KING_MOBILITY_WEIGHT: array[28, WeightPair] = [(0, 0), (0, 0), (0, 0), (91, -69), (116, -85), (68, -15), (41, -24), (26, -26), (5, -3), (-2, -15), (3, -9), (-30, 20), (-30, 12), (-45, 21), (-63, 33), (-76, 40), (-87, 36), (-103, 31), (-110, 30), (-111, 26), (-92, 3), (-63, -9), (-60, -23), (-24, -45), (-67, -47), (-16, -87), (-69, -90), (16, -120)]

    KING_ZONE_ATTACKS_WEIGHT*: array[9, WeightPair] = [(99, -22), (86, -15), (42, -13), (-26, -13), (-137, 1), (-234, 18), (-323, 29), (-388, 29), (-499, 18)]

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
            PIECE_SQUARE_TABLES[White][kind][sq] = (PIECE_VALUES[kind].mg + PIECE_TABLES[kind][sq].mg, PIECE_VALUES[kind].eg + PIECE_TABLES[kind][sq].eg)
            PIECE_SQUARE_TABLES[Black][kind][sq] = (PIECE_VALUES[kind].mg + PIECE_TABLES[kind][flipped].mg, PIECE_VALUES[kind].eg + PIECE_TABLES[kind][flipped].eg)
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
            return (0, 0)


initializeTables()
