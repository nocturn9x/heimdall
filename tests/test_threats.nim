## Runtime threat attacks and full collection against independent board geometry.
## Build with make dev MAIN=tests/test_threats.nim IS_TEST=1
## EXE_BASE=bin/test-threats and an absolute EVALFILE path.
import std/[algorithm, random, strformat]
import heimdall/[board, movegen, nnue, pieces, position]
import heimdall/threats/index


var attackChecks, collectionChecks: int


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

var
    rng = initRand(90210)
    moveFlags: set[MoveFlag]
for fen in [
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
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

echo &"Threat collection: {attackChecks} attack-square checks; {collectionChecks} full collector comparisons"
