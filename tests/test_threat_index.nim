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
#
# Authored with assistance from AI agents.

## Threat geometry, indexing, perspective masks, bounds and collision regressions.
## Build with make dev MAIN=tests/test_threat_index.nim IS_TEST=1
## EXE_BASE=bin/test-threat-index and an absolute EVALFILE path.
import std/strformat

# Inspect private indexing tables without expanding the engine's public API.
include heimdall/threats/index


const
    # Feature contract independent of PIECE_TARGET_MAP and PIECE_TARGET_COUNT.
    expectedTargets: array[ThreatPiece, set[ThreatPiece]] = [
        {Pawn, Knight, Rook},
        {Pawn, Knight, Bishop, Rook, Queen},
        {Pawn, Knight, Bishop, Rook},
        {Pawn, Knight, Bishop, Rook},
        {Pawn, Knight, Bishop, Rook, Queen},
        {}
    ]
    expectedCounts: array[ThreatPiece, int] = [84, 336, 560, 896, 1456, 420]


static:
    # PieceColor also contains None; no table may reserve a zero-filled entry
    # for it, including the victim-color dimension of ATTACK_INDEX.
    doAssert PIECE_INDEX.low == White and PIECE_INDEX.high == Black
    doAssert OFFSETS.indices.low == White and OFFSETS.indices.high == Black
    doAssert OFFSETS.offsets.low == White and OFFSETS.offsets.high == Black
    doAssert ATTACK_INDEX.low == White and ATTACK_INDEX.high == Black
    doAssert ATTACK_INDEX[White][Pawn].low == White
    doAssert ATTACK_INDEX[White][Pawn].high == Black
    doAssert TOTAL_THREATS == 60144


proc geometricAttack(piece: ThreatPiece, side: PieceColor, origin, target: Square): bool =
    # Deliberately avoid the engine's bitboards and attack generators.
    # These are feature coordinates (a1=0), not board coordinates (a8=0).
    let
        dr = target.rank.int - origin.rank.int
        df = target.file.int - origin.file.int
    if dr == 0 and df == 0:
        return false
    case piece:
        of Pawn:
            result = dr == (if side == White: 1 else: -1) and abs(df) == 1
        of Knight:
            result = (abs(dr) == 2 and abs(df) == 1) or (abs(dr) == 1 and abs(df) == 2)
        of Bishop:
            result = abs(dr) == abs(df)
        of Rook:
            result = dr == 0 or df == 0
        of Queen:
            result = dr == 0 or df == 0 or abs(dr) == abs(df)
        of King:
            result = abs(dr) <= 1 and abs(df) <= 1


proc retainDirection(attacker, victim: ThreatPiece, side, victimSide: PieceColor,
                     fromBelow: bool): bool =
    if victim notin expectedTargets[attacker]:
        return false
    # Different piece types and friendly pawn pairs retain both directions.
    # Other same-type pairs retain only the direction with origin > target.
    if attacker != victim or (attacker == Pawn and side == victimSide):
        return true
    return not fromBelow


proc boardSquare(square: Square, perspective: PieceColor, mirrored: bool): Square =
    # Convert a feature square back to the actual board using rank/file
    # arithmetic, independently of perspectiveSquareMask's XOR operations.
    let rank = if perspective == White: 7 - square.rank.int else: square.rank.int
    let file = if mirrored: 7 - square.file.int else: square.file.int
    return makeSquare(rank, file)


var
    pieceChecks, offsetChecks, baseChecks, featureChecks, excludedChecks: int
    indexChecks, belowChecks: int
    expectedGlobalOffset = 0
    maxIndex = -1
    seen = newSeq[string](TOTAL_THREATS)

for side in White..Black:
    for attacker in ThreatPiece:
        var expectedSquareOffset = 0
        for origin in Square.all():
            doAssert OFFSETS.offsets[side][attacker][origin].int == expectedSquareOffset,
                &"wrong square offset for {side} {attacker} on {origin}"
            inc offsetChecks
            var attackRank = 0
            for target in Square.all():
                doAssert PIECE_INDEX[side][attacker][origin][target].int == attackRank,
                    &"wrong attack rank for {side} {attacker} {origin}->{target}"
                inc pieceChecks
                if geometricAttack(attacker, side, origin, target):
                    inc attackRank
            # Neither first-rank nor eighth-rank pawns have feature slots.
            if attacker != Pawn or origin.rank.int notin [0, 7]:
                expectedSquareOffset += attackRank

        doAssert expectedSquareOffset == expectedCounts[attacker]
        let entry = OFFSETS.indices[side][attacker]
        doAssert entry.pieceOffset.int == expectedCounts[attacker],
            &"wrong total attack count for {side} {attacker}"
        doAssert entry.globalOffset.int == expectedGlobalOffset,
            &"wrong global offset for {side} {attacker}"

        # Allocate one complete square-attack block per retained target type
        # AND target color. This catches the missing factor of two regression.
        for victimSide in White..Black:
            for victim in ThreatPiece:
                let expectedBase = expectedGlobalOffset
                if victim in expectedTargets[attacker]:
                    expectedGlobalOffset += expectedCounts[attacker]
                for fromBelow in [false, true]:
                    let expected = if retainDirection(attacker, victim, side, victimSide, fromBelow):
                        expectedBase
                    else:
                        TOTAL_THREATS
                    doAssert ATTACK_INDEX[side][attacker][victimSide][victim][fromBelow].int == expected,
                        &"wrong base for {side} {attacker}->{victimSide} {victim}, fromBelow={fromBelow}"
                    inc baseChecks

                for origin in Square.all():
                    if attacker == Pawn and origin.rank.int in [0, 7]:
                        continue
                    for target in Square.all():
                        if victim == Pawn and target.rank.int in [0, 7]:
                            continue
                        if not geometricAttack(attacker, side, origin, target):
                            continue
                        let
                            base = ATTACK_INDEX[side][attacker][victimSide][victim][origin < target]
                            squareOffset = OFFSETS.offsets[side][attacker][origin]
                            pieceIndex = PIECE_INDEX[side][attacker][origin][target]
                            wideIndex = base.int + squareOffset.int + pieceIndex.int
                            narrowIndex = base + squareOffset + pieceIndex.uint16
                        # Check the stored-width arithmetic against a widened sum,
                        # including sentinel-based sums that must never be used.
                        doAssert wideIndex <= uint16.high.int
                        doAssert narrowIndex.int == wideIndex
                        let retained = retainDirection(attacker, victim, side, victimSide, origin < target)
                        # Exercise the public indexers with real board coordinates
                        # and packed pieces. This catches flipping a kind bit instead
                        # of the color bit, and flipping ranks for the wrong side.
                        for perspective in White..Black:
                            for mirrored in [false, true]:
                                let
                                    king = makeSquare(if perspective == White: 7 else: 0,
                                                      if mirrored: 7 else: 2)
                                    fromSquare = boardSquare(origin, perspective, mirrored)
                                    toSquare = boardSquare(target, perspective, mirrored)
                                    attackerPiece = createPiece(PieceKind(attacker.int),
                                        if perspective == White: side else: side.opposite())
                                    victimPiece = createPiece(PieceKind(victim.int),
                                        if perspective == White: victimSide else: victimSide.opposite())
                                    checked = threatIndex(perspective, king, attackerPiece,
                                                          fromSquare, victimPiece, toSquare)
                                doAssert checked.valid == retained,
                                    &"wrong exclusion for {perspective}: {attackerPiece} {fromSquare}->{victimPiece} {toSquare}, mirrored={mirrored}"
                                if retained:
                                    doAssert checked.idx.int == wideIndex,
                                        &"wrong index for {perspective}: {attackerPiece} {fromSquare}->{victimPiece} {toSquare}, mirrored={mirrored}"
                                    doAssert threatIndexUnchecked(perspective, king, attackerPiece,
                                        fromSquare, victimPiece, toSquare) == checked.idx
                                inc indexChecks
                        if not retained:
                            doAssert base.int == TOTAL_THREATS
                            inc excludedChecks
                            continue
                        let description = &"{side} {attacker} {origin}->{victimSide} {victim} {target}"
                        doAssert wideIndex >= 0 and wideIndex < TOTAL_THREATS, description
                        doAssert seen[wideIndex].len == 0,
                            &"feature {wideIndex} shared by {seen[wideIndex]} and {description}"
                        seen[wideIndex] = description
                        maxIndex = max(maxIndex, wideIndex)
                        inc featureChecks

doAssert expectedGlobalOffset == TOTAL_THREATS
doAssert maxIndex == TOTAL_THREATS - 1
doAssert pieceChecks == 49152
doAssert offsetChecks == 768
doAssert baseChecks == 288
doAssert featureChecks == 50626
doAssert excludedChecks > 0

# The mask is returned in board coordinates, even though the ordering is in
# feature coordinates. Include both endpoints (indices 0 and 63) and all flips.
for mask in [0'u8, 7'u8, 56'u8, 63'u8]:
    for origin in Square.all():
        let below = perspectiveBelow(origin, mask)
        for target in Square.all():
            doAssert below.contains(target) == ((target xor mask) < (origin xor mask)),
                &"wrong below mask for {origin}->{target}, mask={mask}"
            inc belowChecks

# A known baseline TI row anchors the numeric layout as well as its invariants.
doAssert threatIndex(White, "c1".toSquare(), createPiece(pieces.Knight, White),
    "e5".toSquare(), createPiece(pieces.Pawn, Black), "d7".toSquare()) == (2384'u16, true)

echo &"Threat indexing: {pieceChecks} attack ranks, {offsetChecks} square offsets, {baseChecks} bases; " &
     &"{featureChecks} retained threats without collisions; {excludedChecks} excluded threats; " &
     &"{indexChecks} perspective index checks; {belowChecks} mask checks"
