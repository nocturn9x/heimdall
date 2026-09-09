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

## Runtime threat attacks and full collection against independent board geometry.
## Build with make dev MAIN=tests/test_threats.nim IS_TEST=1
## EXE_BASE=bin/test-threats and an absolute EVALFILE path.
import std/[algorithm, random, strformat]
import heimdall/[board, movegen, nnue, pieces, position]
import heimdall/threats/index


const
    STARTPOS_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    KIWIPETE_FEN = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"

var attackChecks, collectionChecks, knownIndexChecks: int


proc geometricAttack(piece: Piece, origin, target: Square, occupancy: Bitboard): bool =
    # Use actual board coordinates (a8=0) and walk rays without magic tables
    # or the engine's attack helpers. The first blocker is an attacked square.
    let
        dr = target.rank.int - origin.rank.int
        df = target.file.int - origin.file.int
    if dr == 0 and df == 0:
        return false
    case piece.kind:
        of Pawn:
            return dr == (if piece.color == White: -1 else: 1) and abs(df) == 1
        of Knight:
            return (abs(dr) == 1 and abs(df) == 2) or (abs(dr) == 2 and abs(df) == 1)
        of Bishop:
            if abs(dr) != abs(df):
                return false
        of Rook:
            if dr != 0 and df != 0:
                return false
        of Queen:
            if dr != 0 and df != 0 and abs(dr) != abs(df):
                return false
        of King, Empty:
            return false
    let
        rankStep = if dr > 0: 1 elif dr < 0: -1 else: 0
        fileStep = if df > 0: 1 elif df < 0: -1 else: 0
    var
        rank = origin.rank.int + rankStep
        file = origin.file.int + fileStep
    while rank != target.rank.int or file != target.file.int:
        if occupancy.contains(makeSquare(rank, file)):
            return false
        rank += rankStep
        file += fileStep
    return true


# Include empty boards, immediately blocked rays, and blockers at mixed distances.
for occupancy in [Bitboard(0), Bitboard(uint64.high),
                  Bitboard(0xAA55AA55AA55AA55'u64), Bitboard(0x8100241818240081'u64)]:
    for side in White..Black:
        for kind in Pawn..Empty:
            let piece = createPiece(kind, side)
            for origin in Square.all():
                let attacks = threatAttacks(piece, origin, occupancy)
                for target in Square.all():
                    doAssert attacks.contains(target) == geometricAttack(piece, origin, target, occupancy),
                        &"wrong attack for {side} {kind} {origin}->{target}, occupancy={occupancy.uint64}"
                    inc attackChecks


proc verifyCollection(position: Position, expectedCount = -1) =
    let
        occupancy = position.pieces()
        candidates = occupancy and not position.pieces(King)
    for perspective in White..Black:
        # At most 30 non-king pieces give 30*29 directed relationships. Pass
        # a writable slice, with guards and an unwritten tail around the output.
        var storage: array[1026, uint16]
        for item in storage.mitems:
            item = uint16.high
        let
            count = collectRefreshThreats(storage.toOpenArray(1, storage.high - 1), position, perspective).int
            king = position.kingSquare(perspective)
            context = &"{perspective}: {position.toFEN()}"
        doAssert count >= 0 and count <= storage.len - 2, context
        doAssert storage[0] == uint16.high, context
        for i in count + 1..storage.high:
            doAssert storage[i] == uint16.high, &"write outside returned prefix: {context}"
        if expectedCount >= 0:
            doAssert count == expectedCount, &"expected {expectedCount} features, got {count}: {context}"

        var actual, expected: seq[uint16]
        for i in 1..count:
            doAssert storage[i].int < TOTAL_THREATS, context
            actual.add storage[i]
        # Deliberately omit the collector's victim/below masks. The checked
        # indexer applies exclusions after independent geometric enumeration.
        for origin in candidates:
            let attacker = position.on(origin)
            for target in candidates:
                if not geometricAttack(attacker, origin, target, occupancy):
                    continue
                let feature = threatIndex(perspective, king, attacker, origin, position.on(target), target)
                if feature.valid:
                    expected.add feature.idx
        actual.sort()
        expected.sort()
        doAssert actual == expected, &"collector differs from full enumeration: {context}"
        for i in 1..<actual.len:
            doAssert actual[i] != actual[i - 1], &"duplicate threat index: {context}"
        inc collectionChecks


# Isolate the pawn regression: each pair contributes exactly one feature in
# both perspectives, including when the friendly defense points 'above'.
for mirrored in [false, true]:
    let
        blackRank = if mirrored: "7k" else: "2k5"
        whiteRank = if mirrored: "7K" else: "2K5"
    for middle in ["8/8/3P4/2P5/8/8", "8/8/3p4/2p5/8/8", "8/8/3p4/2P5/8/8"]:
        verifyCollection(fromFEN(blackRank & "/" & middle & "/" & whiteRank & " w - - 0 1"), 1)

# Kings occupy and block squares but contribute no threat features themselves.
verifyCollection(fromFEN("4k3/8/8/8/8/8/8/4K3 w - - 0 1"), 0)
verifyCollection(fromFEN("4k3/8/8/8/8/r7/K7/R7 w - - 0 1"), 0)


proc verifyKnownIndices(fen: string, whiteExpected, blackExpected: openArray[uint16]) =
    let position = fromFEN(fen)
    for perspective in White..Black:
        var output: array[1024, uint16]
        let count = collectRefreshThreats(output, position, perspective).int
        var actual: seq[uint16]
        for i in 0..<count:
            actual.add output[i]
        actual.sort()
        let expected = if perspective == White: @whiteExpected else: @blackExpected
        doAssert actual == expected,
            &"known index mismatch for {perspective}: {fen}\nexpected: {expected}\nactual: {actual}"
        inc knownIndexChecks


# Fixed expected indices from Viridithas, independent of Heimdall's indexer.
# https://github.com/cosmobobak/viridithas/blob/89a83b692e175eddaeeb1a626d314927e614d48d/src/nnue/network/threat_updates.rs#L765
# Both engines normalize features to a1=0, so board-coordinate differences
# must not change these row numbers. The starting position is symmetric.
const
    startposIndices = [
        506'u16, 525, 3878, 3879, 3899, 3900, 8351, 8449, 9240, 9344, 15603, 15604,
        15605, 18512, 32570, 32589, 36699, 36700, 36720, 36721, 42790, 42888, 43687,
        43791, 54247, 54248, 54249, 57166
    ]
    kiwipeteWhiteIndices = [
        34'u16, 95, 605, 606, 608, 1276, 2034, 2374, 2376, 2377, 4517, 8351, 8449,
        15907, 15908, 15919, 17370, 18821, 23190, 24659, 30086, 30134, 30195, 30397,
        30398, 30401, 30488, 30491, 30807, 30809, 30840, 32491, 32521, 33531, 35486,
        37185, 38306, 42786, 42888, 54045, 54050, 54054, 54055, 55505
    ]
    kiwipeteBlackIndices = [
        3'u16, 4, 7, 94, 97, 389, 581, 612, 1619, 2263, 2265, 2293, 4490, 5607,
        8355, 8449, 15752, 15753, 15758, 15765, 17213, 30107, 30143, 30372, 30489,
        30710, 30711, 30712, 32510, 32512, 32515, 33186, 33740, 35517, 37212, 42790,
        42888, 46560, 48008, 53839, 53847, 53848, 55300, 56761
    ]

verifyKnownIndices(STARTPOS_FEN, startposIndices, startposIndices)
verifyKnownIndices(KIWIPETE_FEN, kiwipeteWhiteIndices, kiwipeteBlackIndices)

var
    rng = initRand(90210)
    moveFlags: set[MoveFlag]
for fen in [
    STARTPOS_FEN,
    KIWIPETE_FEN,
    "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1",
    "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1",
    "4k3/8/8/8/3Pp3/8/8/4K3 b - d3 0 1",
    "1r2k3/P7/8/8/8/8/7p/4K3 w - - 0 1",
    "4k3/8/8/8/8/8/8/RK1R4 w AD - 0 1",
    "4k3/8/8/8/8/8/8/5KR1 w G - 0 1"
]:
    let game = newChessboardFromFEN(fen)
    verifyCollection(game.position)
    # Visit every initial move so special-move coverage doesn't depend on RNG.
    var initialMoves = newMoveList()
    game.generateMoves(initialMoves)
    for move in initialMoves:
        moveFlags.incl move.flag()
        game.doMove(move)
        verifyCollection(game.position)
        game.unmakeMove()
        verifyCollection(game.position)

    # Deterministic legal play adds varied slider blockers and piece identities.
    var played = 0
    for ply in 0..<80:
        var legal = newMoveList()
        game.generateMoves(legal)
        if legal.len == 0:
            break
        game.doMove(legal[rng.rand(legal.high)])
        inc played
        verifyCollection(game.position)
    for ply in 0..<played:
        game.unmakeMove()
        verifyCollection(game.position)

for flag in [Normal, DoublePush, Capture, EnPassant, ShortCastling, LongCastling,
             PromotionQueen, PromotionRook, PromotionBishop, PromotionKnight,
             CapturePromotionQueen, CapturePromotionRook, CapturePromotionBishop, CapturePromotionKnight]:
    doAssert flag in moveFlags, &"missing move coverage: {flag}"

echo &"Threat collection: {attackChecks} attack-square checks; {collectionChecks} full collector comparisons; " &
     &"{knownIndexChecks} known index comparisons"
