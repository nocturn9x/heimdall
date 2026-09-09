# Copyright 2026 Mattia Giambirtone & All Contributors
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

## Indexing utilities for threat inputs. Shameless pawnocchio yoink

import heimdall/[bitboards, pieces, nnue, position]
import heimdall/util/magics

import std/bitops
import std/endians

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
            # Heimdall indexes the *board* with a8=0, but it indexes
            # the *features* with a1=0. This is the same reason why
            # we flip the ranks for white and not for black during
            # inference, see kingBucket() in eval.nim. We do this to
            # stay consistent with the feature indexing every other
            # engine uses while not breaking existing board code that
            # expects a8=0. Pawns are the only pieces where this matters,
            # as all other attack geometries are the same in either direction
            result = pawnAttacks(piece.color.opposite(), square)
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
    # Counts how many targets each piece type has (see
    # the table above)
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



func perspectiveSquareMask(color: PieceColor, king: Square): uint8 {.inline.} =
    # Produces a bit mask that has the effect of both flipping
    # the ranks for the right side and mirroring the board if
    # necessary for the given king square. See flipFile()/flipRank()
    if color == White:
        result = result xor 56'u8

    if king.file() >= pieces.File(4):
        result = result xor 7'u8


proc threatIndex*(
    color: PieceColor,
    king: Square,
    attackerPiece: Piece,
    fromSquare: Square,
    victimPiece: Piece,
    targetSquare: Square
): tuple[idx: uint16, valid: bool] =
    ## Computes a threat input index given the provided parameters.
    ## Checks whether the index is actually valid
    let
        colorMask = uint8(color == Black) shl 3
        squareMask = color.perspectiveSquareMask(king)
        # We branched once in colorMask and now don't need to do
        # that for each piece. Just more efficient than two .opposite()
        # which would branch every time
        attacker = createPiece(attackerPiece.asInt() xor colorMask)
        attackerKind = ThreatPiece(attacker.kind.int)
        victim = createPiece(victimPiece.asInt() xor colorMask)
        victimKind = ThreatPiece(victim.kind.int)
        # Yes I'm overriding the input params, no it doesn't matter, shut up
        fromSquare = fromSquare xor squareMask
        targetSquare = targetSquare xor squareMask
        base = ATTACK_INDEX[attacker.color][attackerKind][victim.color][victimKind][fromSquare < targetSquare]
        squareOffset = OFFSETS.offsets[attacker.color][attackerKind][fromSquare]
        pieceIndex = PIECE_INDEX[attacker.color][attackerKind][fromSquare][targetSquare]
    
    return (idx: base + squareOffset + pieceIndex, valid: base != TOTAL_THREATS)


proc threatIndexUnchecked*(
    color: PieceColor,
    king: Square,
    attackerPiece: Piece,
    fromSquare: Square,
    victimPiece: Piece,
    targetSquare: Square
): uint16 =
    ## Computes a threat input index given the provided parameters.
    ## Does no validity checks
    let
        colorMask = uint8(color == Black) shl 3
        squareMask = color.perspectiveSquareMask(king)
        # We branched once in colorMask and now don't need to do
        # that for each piece. Just more efficient than two .opposite()
        # which would branch every time
        attacker = createPiece(attackerPiece.asInt() xor colorMask)
        attackerKind = ThreatPiece(attacker.kind.int)
        victim = createPiece(victimPiece.asInt() xor colorMask)
        victimKind = ThreatPiece(victim.kind.int)
        # Yes I'm overriding the input params, no it doesn't matter, shut up
        fromSquare = fromSquare xor squareMask
        targetSquare = targetSquare xor squareMask
        base = ATTACK_INDEX[attacker.color][attackerKind][victim.color][victimKind][fromSquare < targetSquare]
        squareOffset = OFFSETS.offsets[attacker.color][attackerKind][fromSquare]
        pieceIndex = PIECE_INDEX[attacker.color][attackerKind][fromSquare][targetSquare]
    
    return base + squareOffset + pieceIndex


proc perspectiveBelow(fromSquare: Square, squareMask: uint8): Bitboard =
    let fromI = fromSquare xor squareMask
    let flipFiles = squareMask.bitand(0b000111) != 0
    let flipRanks = squareMask.bitand(0b111000) != 0
    var below: uint64 = (1'u64 shl fromI.uint64) - 1'u64

    if flipFiles and flipRanks:
        below = reverseBits(below)
    elif flipFiles:
        let belowCopy = below
        swapEndian64(addr below, addr belowCopy)
        below = reverseBits(below)
    elif flipRanks:
        let belowCopy = below
        swapEndian64(addr below, addr belowCopy)
    return Bitboard(below)


proc collectRefreshThreats*(output: var openArray[uint16], position: Position, color: PieceColor): uint64 =
    let occ = position.pieces()
    let kingSquare = position.kingSquare(color)
    let pieceBBs = block:
        var res: array[ThreatPiece, Bitboard]

        for piece in ThreatPiece:
            res[piece] = position.pieces(PieceKind(piece.int))
        
        res
    
    let squareMask = color.perspectiveSquareMask(kingSquare)
    var victimMask: array[ThreatPiece, Bitboard]

    for attackerType in ThreatPiece:
        for victimType in ThreatPiece:
            if PIECE_TARGET_MAP[attackerType][victimType] != -1:
                victimMask[attackerType] = victimMask[attackerType] or pieceBBs[victimType]
    var n = 0'u64
    let attackersBB = occ xor position.pieces(King)

    for attackerSquare in attackersBB:
        let attackerPiece = position.on(attackerSquare)
        let attackerType = ThreatPiece(attackerPiece.kind.int)
        let attacks = threatAttacks(attackerPiece, attackerSquare, occ)
        let below = attackerSquare.perspectiveBelow(squareMask)
        var sameType = pieceBBs[attackerType]
        if attackerType == Pawn:
            # perspectiveBelow throws away same-type duplicate relationships (example: two
            # bishops attacking each other on a diagonal), but it doesn't know anything about
            # piece types. Friendly pawn defenses are a special case: not only do they not
            # attack backwards, so there is nothing to exclude: we already account for their
            # defenses when constructing their table, so we remove them from the set of pieces
            # which are subject to the remove-duplicate-attacks logic that happens later (or we'd
            # ignore them completely!)
            sameType = sameType and position.pieces(attackerPiece.color.opposite())
        let attacked = attacks and victimMask[attackerType] and (not sameType or below)

        for victimSquare in attacked:
            let victimPiece = position.on(victimSquare)
            let idx = color.threatIndexUnchecked(kingSquare, attackerPiece, attackerSquare, victimPiece, victimSquare)
            output[n] = idx
            inc(n)
    return n


