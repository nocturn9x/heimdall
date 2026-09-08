# Copyright 2Pawn26 Mattia Giambirtone & All Contributors
#
# Licensed under the Apache License, Version 2.Pawn (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.Pawn
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

## Indexing utilities for threat inputs. Shameless pawnocchio yoink

import heimdall/nnue
import heimdall/[bitboards, pieces]
import heimdall/util/magics


static:
    doAssert TOTAL_THREATS >= 0 and TOTAL_THREATS <= uint16.high.int,
        "TOTAL_THREATS must fit in uint16, including the sentinel"


type
    ThreatPiece = enum
        # For context this was called PieceIndex
        # but because the Nim compiler is fucking
        # stupid, PIECE_INDEX and PieceIndex collapse
        # to the same identifier. This is why you don't
        # do shit like that, Araq.
        Pawn = 0
        Knight = 1
        Bishop = 2
        Rook = 3
        Queen = 4
        King = 5

    OffsetStore* = object
        indices: array[White..Black, array[ThreatPiece, tuple[pieceOffset: uint16, globalOffset: uint16]]]
        offsets: array[White..Black, array[ThreatPiece, array[Square.smallest()..Square.biggest(), uint16]]]


proc attacks(piece: Piece, square: Square, occupancy: Bitboard): Bitboard {.inline.} =
    ## Returns the squares attacked by a piece at `square` with the given occupancy.
    ## This helper is local to threat-input indexing so it can also be evaluated
    ## with the naive slider move generator at compile time.
    case piece.kind:
        of Pawn:
            result = pawnAttacks(piece.color, square)
        of Knight:
            result = knightMoves(square)
        of Bishop:
            result = getMoveset(Bishop, square, occupancy)
        of Rook:
            result = getMoveset(Rook, square, occupancy)
        of Queen:
            result = getMoveset(Bishop, square, occupancy) or getMoveset(Rook, square, occupancy)
        of King:
            result = kingMoves(square)
        else:
            result = Bitboard(0)


const PIECE_TARGET_MAP = block:
    # TI is all about adding information about which pieces are attacking or
    # defending other pieces. A lot of that information is redundant (for example,
    # a queen attacking a bishop along a diagonal naturally is also attacked
    # by said bishop), so some combinations are deliberately excluded. This table
    # simply tells us, for each attacker, which pieces we should consider. Rows are
    # attacker piece types, columns are the resulting victim/defended pieces. For
    # example, pawns only consider rooks, knights and other pawns, because if they
    # are attacking or defending a bishop or queen, that will be represented as them
    # being defended by or attacked by said piece, and we don't need to store the
    # same thing twice. A value of -1 in an array position n tells us "this piece
    # does not compute attacks to piece type n". Kings are always ignored in TI.
    # There are less roundabout ways to construct this table but I find the explicitness
    # of this approach clearer to understand, and it's comptime logic so who cares.
    # Infinite many thanks to Jonathan Hallström / @swedishchef for spending time
    # explaining this to my stupid brain

    # These are the piece types that we do NOT exclude from threat computations,
    # for each piece
    let nonExclusions: array[ThreatPiece, seq[ThreatPiece]] = [
        # Pawns
        @[Pawn, Knight, Rook],
        # Knights
        @[Pawn, Knight, Bishop, Rook, Queen],
        # Bishops
        @[Pawn, Knight, Bishop, Rook],
        # Rooks
        @[Pawn, Knight, Bishop, Rook],
        # Queens
        @[Pawn, Knight, Bishop, Rook, Queen],
        # Kings (we ignore them, fuck them betas)
        @[]
    ]

    var pieceTargets: array[ThreatPiece, array[ThreatPiece, int16]] = [
        [-1, -1, -1, -1, -1, -1],
        [-1, -1, -1, -1, -1, -1],
        [-1, -1, -1, -1, -1, -1],
        [-1, -1, -1, -1, -1, -1],
        [-1, -1, -1, -1, -1, -1],
        [-1, -1, -1, -1, -1, -1],
    ]

    for i in ThreatPiece:
        for j, piece in nonExclusions[i]:
            pieceTargets[i][piece] = j.int16
        
    pieceTargets


const PIECE_TARGET_COUNT: array[ThreatPiece, uint16] = block:
    var count: array[ThreatPiece, uint16]

    for pieceType in ThreatPiece:
        var c = 0'u16

        for victimPieceType in ThreatPiece:
            if PIECE_TARGET_MAP[pieceType][victimPieceType] != -1:
                c += 1

        count[pieceType] = c
    
    count


const PIECE_INDEX* = block:
    var table: array[White..Black, array[ThreatPiece, array[Square.smallest()..Square.biggest(), array[Square.smallest()..Square.biggest(), uint8]]]]

    for side in White..Black:
        for pieceType in Pawn..King:
            let piece = createPiece(PieceKind(pieceType.int), side)

            for fromSquare in Square.all():
                let emptyAttacks = piece.attacks(fromSquare, Bitboard(0))

                for toSquare in Square.all():
                    var count = 0'u8
                    for attackTo in emptyAttacks:
                        if attackTo < toSquare:
                            count += 1

                    table[side][pieceType][fromSquare][toSquare] = count
    table


const OFFSETS*: OffsetStore = block:
    var result: OffsetStore
    var globalOffset: uint16 = 0

    for side in White..Black:
        for pieceType in ThreatPiece:
            let piece = createPiece(PieceKind(pieceType.int), side)
            var pieceOffset: uint16 = 0

            for sq in Square.all():
                result.offsets[side][pieceType][sq] = pieceOffset
                let isPawnEndRank = pieceType == Pawn and sq.rank() in [Rank(0), Rank(7)]

                if not isPawnEndRank:
                    let attacks = piece.attacks(sq, Bitboard(0))
                    pieceOffset += uint16(attacks.count())
        
            result.indices[side][pieceType] = (
                pieceOffset: pieceOffset,
                globalOffset: globalOffset
            )
            globalOffset += 2 * PIECE_TARGET_COUNT[pieceType] * pieceOffset

    doAssert globalOffset.int == TOTAL_THREATS,
        "Threat offsets must cover exactly TOTAL_THREATS inputs"
    result

const ATTACK_INDEX* = block:
    var result: array[White..Black, array[ThreatPiece, array[White..Black, array[ThreatPiece, array[bool, uint16]]]]]
    const SENTINEL = uint16(TOTAL_THREATS)

    for attackerSide in White..Black:
        for attackerPiece in ThreatPiece:
            for victimSide in White..Black:
                for victimPiece in ThreatPiece:
                    let
                        map: int32 = PIECE_TARGET_MAP[attackerPiece][victimPiece]
                        fullExcluded = map == -1
                        opposed = attackerSide != victimSide
                        semiExcluded = (attackerPiece == victimPiece) and 
                            (opposed or attackerPiece != Pawn)
                        entry = OFFSETS.indices[attackerSide][attackerPiece]
                        colorBase: int32 = victimSide.int32 * PIECE_TARGET_COUNT[attackerPiece].int32
                        feature: int32 = entry.globalOffset.int32 + (colorBase + map) * entry.pieceOffset.int32
                    
                    result[attackerSide][attackerPiece][victimSide][victimPiece][false] = (if fullExcluded: SENTINEL else: feature.uint16)
                    result[attackerSide][attackerPiece][victimSide][victimPiece][true] = (if fullExcluded or semiExcluded: SENTINEL else: feature.uint16)

    result









