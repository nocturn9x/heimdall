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

## Position evaluation utilities
import heimdall/threats/[index, updates]
import heimdall/[board, moves, pieces, position, nnue]
import heimdall/util/memory/thp/alloc
when defined(simd):
    import heimdall/util/simd_dispatch
import std/typetraits

when defined(simd):
    import heimdall/util/simd

when not VERBATIM_NET:
    import std/streams


# One root accumulator plus the 255 plies that search can evaluate.
const MAX_ACCUMULATORS = 256

type

    Score* = int32

    Accumulator = object
        # Shared by the separate PSQ and TI stacks
        data {.align(ALIGNMENT_BOUNDARY).}: array[L1_SIZE, int16]
        kingSquare: Square

    CachedAccumulator* = object
        acc: Accumulator
        colors: array[White..Black, Bitboard]
        pieces: array[Pawn..King, Bitboard]

    # A record for an efficient update
    Update = tuple[move: Move, sideToMove: PieceColor, piece, captured: PieceKind, needsRefresh: bool, posIndex: int]

    # The accumulator stack alone is well over a megabyte and is read/written on
    # every node of the search, so the eval state is allocated on 2MB huge pages
    # (see EvalState/EvalStateOwner) to reduce TLB pressure. EvalStateObj holds
    # the storage while EvalState is the (auto-dereferencing) handle threaded
    # through the evaluation code
    EvalStateObj = object
        # Current accumulator
        current: int
        # Accumulator stacks. We keep one per ply
        # Separating threat and PSQ accumulators allows
        # us to keep efficiently updating threats even
        # after a PSQ refresh
        accumulators: array[White..Black, array[MAX_ACCUMULATORS, Accumulator]]
        threatAccumulators: array[White..Black, array[MAX_ACCUMULATORS, Accumulator]]
        # Pending updates
        updates: array[MAX_ACCUMULATORS, Update]
        # Number of pending updates
        pending: int
        # Board where moves are made
        board: Chessboard
        # Cache for accumulator refreshes, allows us
        # to make refreshes cheaper by only adding/removing
        # the features that changed instead of iterating over
        # the whole board to construct a new set of inputs
        cache: array[White..Black, array[NUM_INPUT_BUCKETS, array[bool, CachedAccumulator]]]

    EvalState* = ptr EvalStateObj
        ## Non-owning handle to a huge-page-backed eval state. Auto-dereferences,
        ## so it is used exactly like the previous ref type throughout the code.

    EvalStateOwner* = HugePtr[EvalStateObj]
        ## Unique owner of a huge-page-backed eval state. Holding one keeps the
        ## underlying EvalState alive; dropping it releases the huge pages.

when defined(simd):
    type AlignedArray[K: static[int], T] = object
        data {.align(ALIGNMENT_BOUNDARY).}: array[K, T]


func lowestEval*: Score {.inline.} = Score(-28_000)
func highestEval*: Score {.inline.} = Score(28_000)
func mateScore*: Score {.inline.} = Score(30_000)


# This mate score compression logic comes from the advice of @shaheryarsohail on Discord. Many thanks!
# More info: https://github.com/TheBlackPlague/StockDory/pull/57
const MATE_IN_MAX_PLY = mateScore() - 255

func isMateScore*(score: Score): bool {.inline.} = abs(score) >= MATE_IN_MAX_PLY
func isWinScore*(score: Score): bool {.inline.} = score >= MATE_IN_MAX_PLY
func isLossScore*(score: Score): bool {.inline.} = score <= -MATE_IN_MAX_PLY
func mateIn*(ply: int): Score {.inline.} = mateScore() - Score(ply)
func matedIn*(ply: int): Score {.inline.} = -mateScore() + Score(ply)
func compressScore*(score: Score, ply: int): Score = (if score.isWinScore(): score + Score(ply) elif score.isLossScore(): score - Score(ply) else: score)
func decompressScore*(score: Score, ply: int): Score = (if score.isWinScore(): score - Score(ply) elif score.isLossScore(): score + Score(ply) else: score)


const SCORE_INF* = mateIn(0) + 1

# Network is global for performance reasons!
var network*: Network

proc newEvalState*(networkPath: string = "", verbose: static bool = true): EvalStateOwner =
    # zero = true: EvalStateObj holds a managed board ref that must start nil
    result = allocHugePage[EvalStateObj](zero = true)
    if networkPath == "":
        when not VERBATIM_NET:
            when verbose:
                echo "info string loading built-in network"
            network = loadNet(newStringStream(DEFAULT_NET_WEIGHTS))
        else:
            when verbose:
                echo "info string using verbatim network"
            # Don't even bother asking me why I need these shenanigans. I couldn't tell you.
            # Nim generates invalid C code unless we do this weird dance
            let temp = cast[ptr UncheckedArray[byte]](VERBATIM_NET_DATA)
            network  = cast[ptr Network](temp)[]
    else:
        network = loadNet(networkPath)


proc copyFrom*(self: EvalState, source: EvalState, board: Chessboard) =
    ## Reuse this state's storage, copying only the live accumulator/update
    ## prefixes. Frames beyond current are overwritten before they are read.
    ## Both states must be idle; each search worker owns its destination.
    static:
        doAssert supportsCopyMem(Accumulator) and supportsCopyMem(Update)
    if self != source:
        self.current = source.current
        self.pending = source.pending
        for side in White..Black:
            copyMem(addr self.accumulators[side][0], addr source.accumulators[side][0],
                    (source.current + 1) * sizeof(Accumulator))
            copyMem(addr self.threatAccumulators[side][0], addr source.threatAccumulators[side][0],
                    (source.current + 1) * sizeof(Accumulator))
        copyMem(addr self.updates[0], addr source.updates[0], source.pending * sizeof(Update))
        self.cache = source.cache
    self.board = board


proc clone*(self: EvalState, board: Chessboard): EvalStateOwner =
    ## Create independently owned storage for the live evaluation state.
    # The managed board ref must start nil before assignment.
    result = allocHugePage[EvalStateObj](zero = true)
    result.raw.copyFrom(self, board)


func shouldMirror(kingSq: Square): bool {.inline.} =
    ## Returns whether the king being on this location
    ## would cause horizontal mirroring of the board
    when MIRRORED:
        return file(kingSq) > 3
    else:
        return false


proc kingBucket*(side: PieceColor, square: Square): int {.inline.} =
    ## Returns the input bucket associated with the king
    ## of the given side located at the given square

    when NUM_INPUT_BUCKETS == 1:
        return 0
    else:
        # We flip for white instead of black because the
        # bucket layout assumes a1=0 and we use a8=0 instead
        if side == White:
            return INPUT_BUCKETS[square.flipRank()]
        else:
            return INPUT_BUCKETS[square]


func feature(perspective: PieceColor, color: PieceColor, piece: PieceKind, square, kingSquare: Square): int =
    ## Constructs a feature from the given perspective for a piece
    ## of the given type and color on the given square
    var colorIndex = block:
        when MERGED_KINGS:
            # We always use index 0 for the king because we do something called merged kings:
            # due to the layout of our input buckets (i.e. they don't span more than 2x2 squares),
            # it is impossible for two kings to be in the same bucket at any given time, so we can
            # save a bunch of space (about 8%) by only accounting for one king per bucket, shrinking
            # the size of the feature transformer from 768 inputs to 704
            if (perspective == color or piece == King): 0 else: 1
        else:
            if perspective == color: 0 else: 1

    let
        mirror = shouldMirror(kingSquare)
        bucket = kingBucket(perspective, kingSquare)
        pieceIndex = piece.int
        square = block:
            if mirror:
                square.flipFile()
            else:
                square
        squareIndex = if perspective == White: int(square.flipRank()) else: int(square)

    result = result * 2 + colorIndex
    result = result * 6 + pieceIndex
    result = result * 64 + squareIndex
    result += bucket * FT_SIZE


proc mustRefresh(self: EvalState, side: PieceColor, prevKingSq, currKingSq: Square): bool {.inline.} =
    ## Returns whether an accumulator refresh is required for the given side
    ## as opposed to an efficient update
    if shouldMirror(prevKingSq) != shouldMirror(currKingSq):
        return true
    return kingBucket(side, prevKingSq) != kingBucket(side, currKingSq)


proc refreshPSQ(self: EvalState, side: PieceColor, position: Position, useCache: static bool = true) =
    ## Performs an accumulator refresh for the PSQ part
    ## of the network, for the given side

    let
        kingSq = position.kingSquare(side)
        mirror = shouldMirror(kingSq)
        bucket = kingBucket(side, kingSq)

    # Update king location
    self.cache[side][bucket][mirror].acc.kingSquare = kingSq

    # We don't refresh from the cache but we still use it so it's
    # ready for the next refresh
    when not useCache:
        network.ft.initAccumulator(self.cache[side][bucket][mirror].acc.data)
        for color in White..Black:
            self.cache[side][bucket][mirror].colors[color] = position.pieces(color)
        for piece in PieceKind.all():
            self.cache[side][bucket][mirror].pieces[piece] = position.pieces(piece)

        for sq in position.pieces():
            let piece = position.on(sq)
            network.ft.addFeature(feature(side, piece.color, piece.kind, sq, kingSq), self.cache[side][bucket][mirror].acc.data)
    else:
        # Incrementally update from last known-good refresh and keep the cache
        # up to date
        var adds: array[32, int]
        var subs: array[32, int]
        var addCount = 0
        var subCount = 0
        for color in White..Black:
            for piece in PieceKind.all():
                let
                    previous = self.cache[side][bucket][mirror].pieces[piece] and self.cache[side][bucket][mirror].colors[color]
                    current = position.pieces(piece, color)
                # Add pieces that were added since last refresh
                for square in current and not previous:
                    adds[addCount] = feature(side, color, piece, square, kingSq)
                    inc(addCount)
                # Remove pieces that have gone since the last refresh
                for square in previous and not current:
                    subs[subCount] = feature(side, color, piece, square, kingSq)
                    inc(subCount)
        # Optimize finny table updates by fusing them when possible
        while addCount >= 4:
            network.ft.quadAdd(adds[addCount - 1], adds[addCount - 2], adds[addCount - 3], adds[addCount - 4], self.cache[side][bucket][mirror].acc.data)
            dec(addCount, 4)
        while subCount >= 4:
            network.ft.quadSub(subs[subCount - 1], subs[subCount - 2], subs[subCount - 3], subs[subCount - 4], self.cache[side][bucket][mirror].acc.data)
            dec(subCount, 4)
        while addCount > 0:
            network.ft.addFeature(adds[addCount - 1], self.cache[side][bucket][mirror].acc.data)
            dec(addCount)
        while subCount > 0:
            network.ft.removeFeature(subs[subCount - 1], self.cache[side][bucket][mirror].acc.data)
            dec(subCount)
        for color in White..Black:
            for piece in PieceKind.all():
                self.cache[side][bucket][mirror].pieces[piece] = position.pieces(piece)
            self.cache[side][bucket][mirror].colors[color] = position.pieces(color)
    # Copy cache to the current accumulator
    self.accumulators[side][self.current] = self.cache[side][bucket][mirror].acc


proc refreshThreats(self: EvalState, side: PieceColor, position: Position) =
    # On the 256, Mr. Jonathan Hallström had this to say about it:
    # "thats probably enough" - someone
    var indices: array[256, uint16]
    let n = indices.collectRefreshThreats(position, side)
    # toOpenArray(a, b) includes both ends.
    self.threatAccumulators[side][self.current].data.applyAllRowsZeroed(
        network.threatWeights, indices.toOpenArray(0, n.int - 1))


proc resetCache(self: EvalState) {.inline.} =
    for side in White..Black:
        for bucket in 0..<NUM_INPUT_BUCKETS:
            for mirror in false..true:
                network.ft.initAccumulator(self.cache[side][bucket][mirror].acc.data)
                for color in White..Black:
                    self.cache[side][bucket][mirror].colors[color] = Bitboard(0)
                for piece in PieceKind.all():
                    self.cache[side][bucket][mirror].pieces[piece] = Bitboard(0)


proc init*(self: EvalState, board: Chessboard) =
    ## Initializes a new persistent eval
    ## state

    self.current = 0
    self.pending = 0
    self.board = board
    self.resetCache()
    for side in White..Black:
        self.refreshPSQ(side, board.position)
        self.refreshThreats(side, board.position)


func getKingCastlingTarget(move: Move, sideToMove: PieceColor): Square {.inline.} =
    if move.targetSquare < move.startSquare:
        return createPiece(kind=King, color=sideToMove).longCastling()
    else:
        return createPiece(kind=King, color=sideToMove).shortCastling()


func getRookCastlingTarget(move: Move, sideToMove: PieceColor): Square {.inline.} =
    if move.targetSquare < move.startSquare:
        return createPiece(kind=Rook, color=sideToMove).longCastling()
    else:
        return createPiece(kind=Rook, color=sideToMove).shortCastling()


func getNextKingSquare(move: Move, piece: PieceKind, sideToMove: PieceColor, previousKingSq: Square): Square {.inline.} =
    if piece == King and not move.isCastling():
        return move.targetSquare
    elif move.isCastling():
        return move.getKingCastlingTarget(sideToMove)
    else:
        return previousKingSq


proc update*(self: EvalState, move: Move, sideToMove: PieceColor, piece: PieceKind, captured=Empty, kingSq: Square) {.inline.} =
    ## Enqueues an accumulator update with the given data
    let nextKingSq = move.getNextKingSquare(piece, sideToMove, kingSq)
    # Only the moving side's accumulator can ever need a refresh: its features
    # are relative to its own king, which is the only one that can have moved.
    # The opponent's accumulator sees our king as a regular piece and is always
    # updated incrementally
    let needsRefresh = self.mustRefresh(sideToMove, kingSq, nextKingSq)
    # We use len() instead of high() because update() is called before the move is made, so the length of the sequence
    # will be the index of the next position once doMove is called
    self.updates[self.pending] = (move, sideToMove, piece, captured, needsRefresh, self.board.positions.len())
    inc(self.pending)


proc applyPSQUpdate(self: EvalState, color: PieceColor, move: Move, sideToMove: PieceColor, piece: PieceKind, captured=Empty) =
    ## Updates the accumulators for the given color with the given move
    ## made by the given side with the given piece type. If the move is
    ## a capture, the captured piece type is expected as the captured argument

    # Copy previous king square
    self.accumulators[color][self.current].kingSquare = self.accumulators[color][self.current - 1].kingSquare
    var queue = UpdateQueue()

    let
        nonSideToMove = sideToMove.opposite()
        kingSq = self.accumulators[color][self.current].kingSquare

    if not move.isCastling():
        let newPieceIndex = feature(color, sideToMove, (if not move.isPromotion(): piece else: move.flag().promotionToPiece()), move.targetSquare, kingSq)
        let movingPieceIndex = feature(color, sideToMove, piece, move.startSquare, kingSq)

        # Quiets and non-capture promotions add one feature and remove one
        if move.isQuiet() or (not move.isCapture() and move.isPromotion()):
            queue.addSub(newPieceIndex, movingPieceIndex)
        else:
            # All captures (including ep) always add one feature and remove two.
            # captureSquare() locates the captured piece (the target square for
            # normal captures, the pawn behind it for en passant)
            let taron = feature(color, nonSideToMove, captured, move.captureSquare(), kingSq)
            queue.addSubSub(newPieceIndex, movingPieceIndex, taron)
    else:
        # Move the king and rook
        # Castling adds two features and removes two
        queue.addSub(feature(color, sideToMove, King, move.getKingCastlingTarget(sideToMove), kingSq), feature(color, sideToMove, King, move.startSquare, kingSq))
        queue.addSub(feature(color, sideToMove, Rook, move.getRookCastlingTarget(sideToMove), kingSq), feature(color, sideToMove, Rook, move.targetSquare, kingSq))

    # Apply all updates at once
    queue.apply(network.ft, self.accumulators[color][self.current - 1].data, self.accumulators[color][self.current].data)


proc applyPSQUpdatePair(self: EvalState, move: Move, sideToMove: PieceColor, piece: PieceKind, captured=Empty) =
    ## Update both PSQ accumulator perspectives with one shared move decode. The
    ## feature rows differ by perspective, but the move kind and control flow
    ## are identical and need only be worked out once.
    for color in White..Black:
        self.accumulators[color][self.current].kingSquare = self.accumulators[color][self.current - 1].kingSquare

    let nonSideToMove = sideToMove.opposite()
    template oldAcc(color: PieceColor): untyped = self.accumulators[color][self.current - 1].data
    template newAcc(color: PieceColor): untyped = self.accumulators[color][self.current].data
    template kingSq(color: PieceColor): untyped = self.accumulators[color][self.current].kingSquare

    if not move.isCastling():
        let
            newPiece = if not move.isPromotion(): piece else: move.flag().promotionToPiece()
            whiteNew = feature(White, sideToMove, newPiece, move.targetSquare, kingSq(White))
            whiteMoving = feature(White, sideToMove, piece, move.startSquare, kingSq(White))
            blackNew = feature(Black, sideToMove, newPiece, move.targetSquare, kingSq(Black))
            blackMoving = feature(Black, sideToMove, piece, move.startSquare, kingSq(Black))

        if move.isQuiet() or (not move.isCapture() and move.isPromotion()):
            network.ft.addSub(whiteNew, whiteMoving, oldAcc(White), newAcc(White))
            network.ft.addSub(blackNew, blackMoving, oldAcc(Black), newAcc(Black))
        else:
            let
                whiteCaptured = feature(White, nonSideToMove, captured, move.captureSquare(), kingSq(White))
                blackCaptured = feature(Black, nonSideToMove, captured, move.captureSquare(), kingSq(Black))
            network.ft.addSubSub(whiteNew, whiteMoving, whiteCaptured, oldAcc(White), newAcc(White))
            network.ft.addSubSub(blackNew, blackMoving, blackCaptured, oldAcc(Black), newAcc(Black))
    else:
        network.ft.addSubAddSub(
            feature(White, sideToMove, King, move.getKingCastlingTarget(sideToMove), kingSq(White)),
            feature(White, sideToMove, King, move.startSquare, kingSq(White)),
            feature(White, sideToMove, Rook, move.getRookCastlingTarget(sideToMove), kingSq(White)),
            feature(White, sideToMove, Rook, move.targetSquare, kingSq(White)), oldAcc(White), newAcc(White))
        network.ft.addSubAddSub(
            feature(Black, sideToMove, King, move.getKingCastlingTarget(sideToMove), kingSq(Black)),
            feature(Black, sideToMove, King, move.startSquare, kingSq(Black)),
            feature(Black, sideToMove, Rook, move.getRookCastlingTarget(sideToMove), kingSq(Black)),
            feature(Black, sideToMove, Rook, move.targetSquare, kingSq(Black)), oldAcc(Black), newAcc(Black))


proc undo*(self: EvalState) {.inline.} =
    ## Discards the previous accumulator update
    if self.pending > 0:
        dec(self.pending)
    else:
        dec(self.current)


proc updateThreats(self: EvalState, currentPositionIdx: uint64, who: PieceColor = None) =
    let before = self.board.positions[currentPositionIdx - 1]
    let after = self.board.positions[currentPositionIdx]
    var diff = collectThreatDiff(before, after)
    if who == None:
        for color in White..Black:
            diff.apply(network.threatWeights, color, self.threatAccumulators[color][self.current - 1].data, self.threatAccumulators[color][self.current].data)
    else:
        diff.apply(network.threatWeights, who, self.threatAccumulators[who][self.current - 1].data, self.threatAccumulators[who][self.current].data)


# Multilayer inference restored and wired to TI (slopped)
when SINGLE_LAYER:
    proc forwardScalar*(self: EvalState, sideToMove: PieceColor, outputBucket: int): Score =
        ## Single-layer SCReLU output from the prepared PSQ and TI accumulators.
        var sum = 0'i64
        for half, side in [sideToMove, sideToMove.opposite()]:
            for i in 0..<L1_SIZE:
                let
                    value = self.accumulators[side][self.current].data[i] +% self.threatAccumulators[side][self.current].data[i]
                    clipped = clamp(value, 0, QA).int64
                    weight = network.output.weight[outputBucket][half * L1_SIZE + i].int64
                sum += clipped * clipped * weight
        return Score(((sum div QA + network.output.bias[outputBucket]) * EVAL_SCALE) div (QA * QB))


    when defined(simd):
        proc forwardFast*(self: EvalState, sideToMove: PieceColor, outputBucket: int): Score =
            ## Keep the debugging head scalar; PSQ accumulator updates still use SIMD.
            self.forwardScalar(sideToMove, outputBucket)
else:
    static:
        doAssert L1_SIZE mod 4 == 0

    # Logic entirely yoinked from Stormphrax. Thanks cie!
    proc forwardScalar*(self: EvalState, sideToMove: PieceColor, outputBucket: int): Score =
        ## Runs a forward pass through the given output bucket of the current network,
        ## using the given accumulator and side to move pair and returns the output.
        ## Fully scalar implementation (i.e. slow as hell but easier to debug)
        const
            PAIR_COUNT: uint64 = L1_SIZE div 2
            L1_SHIFT = 16 + QUANT_BITS - FT_SCALE_BITS - FT_QUANT_BITS - FT_QUANT_BITS - L1_QUANT_BITS
            QUANT = 1 shl QUANT_BITS

        var
            # Activated FT outputs (concated accumulators)
            ftOut: array[L1_SIZE, uint8]
            # Activated L1 outputs. Dual activation, so twice the outputs
            l1Out: array[L2_SIZE * (1 + DUAL_ACTIVATION.int), int32]
            # Unactivated L2 outputs
            l2Out: array[L3_SIZE, int32]

        # Activate the FT: We do pairwise activation to reduce the size of the
        # L1 matmul in half. See https://github.com/official-stockfish/Stockfish/blob/master/src/nnue/nnue_feature_transformer.h#L239
        # for more details on this shifting business and why we use it to perform
        # quantizations instead of simple division. The TLDR is that it's faster,
        # but we are limited to quantization constants that are powers of 2. In practice
        # this limitation doesn't matter, so it's free speed at no cost
        func activatePerspective(inputs, threats: Accumulator, outputOffset: uint64) =
            for inputIdx in 0..<PAIR_COUNT:
                var
                    i1 = inputs.data[inputIdx] +% threats.data[inputIdx]
                    i2 = inputs.data[inputIdx + PAIR_COUNT] +% threats.data[inputIdx + PAIR_COUNT]

                # Use crelu activation for both values (the "squaring" will just be
                # us multiplying them together)
                i1 = clamp(i1, 0, QA)
                # We can save a max operation (hence why we don't do clamp())
                # here thanks to that stockfish trick I mentioned earlier
                i2 = min(i2, QA)

                let
                    # Divide by the scale
                    s = i1 shl FT_SCALE_BITS
                    # Poor man's mulhi (AVX2 intrinsic). Uses the same fast modulo reduction
                    # trick that we use for indexing the transposition table!
                    p = (cast[int32](s) * cast[int32](i2)) shr 16
                    packed = cast[uint8](clamp(p, 0, 255))

                ftOut[outputOffset + inputIdx] = packed

        # Activate side-to-move accumulator into ftOut[0..L1_SIZE / 2]
        activatePerspective(self.accumulators[sideToMove][self.current], self.threatAccumulators[sideToMove][self.current], 0)
        # Activate non side-to-move accumulator into ftOut[L1_SIZE / 2..L1_SIZE]
        activatePerspective(self.accumulators[sideToMove.opposite()][self.current], self.threatAccumulators[sideToMove.opposite()][self.current], PAIR_COUNT)

        # Unactivated L1 outputs in the quantized space (FT quant * L1 quant)
        var intermediate: array[L2_SIZE, int32]

        # This is the actual layer 1 matmul operation
        for inputIdx in 0..<L1_SIZE:
            let i = ftOut[inputIdx]

            for outputIdx in 0..<L2_SIZE:
                # The indexing is weird instead of simply [inputIdx][outputIdx] (or
                # inputIdx * L2_SIZE + outputIdx) because dpbusd requires this ordering
                let
                    weightIdx = l1WeightIndex(inputIdx.int, outputIdx)
                    w = network.l1.weight[outputBucket][weightIdx]

                intermediate[outputIdx] += i.int32 * w.int32

        # Requantize, add biases and activate L1 output
        for i in 0'u64..<L2_SIZE:
            let bias = network.l1.bias[outputBucket][i]

            var output = intermediate[i]

            # Requantise to later layer quantization and undo FT
            # shift in one go (this is ultimately a shift down,
            # expressed as a negative shift up, so negate the
            # actual shift amount)

            output += bias
            output = output shr -L1_SHIFT

            when DUAL_ACTIVATION:
                # When doing dual activation we use both CReLU and
                # SCReLU
                var crelu = output
                var screlu = output

                # ReLU + clip
                crelu = crelu.clamp(0, QUANT)
                # Shift into Q*Q space (currently Q) to match squared side
                crelu = crelu shl QUANT_BITS

                screlu *= screlu
                # Clip in Q*Q space (we just squared this value, so we squared Q too)
                screlu = min(screlu, QUANT * QUANT)

                l1Out[i] = crelu
                l1Out[i + L2_SIZE] = screlu
            else:
                # Use SCReLU when doing single activation
                var crelu = clamp(output, 0, QUANT)
                l1Out[i] = crelu * crelu

        # Values are now in Q*Q space (see above)

        for i, bias in network.l2.buckets[outputBucket].bias:
            l2Out[i] = bias

        # Perform L2 matmul
        for inputIdx in 0..<L2_SIZE * (1 + DUAL_ACTIVATION.int):
            let i = l1Out[inputIdx]

            for outputIdx in 0..<L3_SIZE:
                let w = network.l2.buckets[outputBucket].weight[inputIdx][outputIdx]

                l2Out[outputIdx] += i * w

        # Values are now in Q*Q*Q space, we just multiplied Q*Q values by Q weights
        result = network.l3.buckets[outputBucket].bias[0]

        # Activate L2 outputs and do L3 matmul
        for inputIdx in 0..<L3_SIZE:
            var i = l2Out[inputIdx]

            let w = network.l3.buckets[outputBucket].weight[inputIdx][0]

            # crelu
            i = i.clamp(0, QUANT * QUANT * QUANT)

            result += i * w
        # Values are now in Q*Q*Q*Q space

        # Scale in int64 and dequantize once to preserve precision without
        # overflowing the intermediate
        result = Score(result.int64 * EVAL_SCALE div (QUANT.int64 * QUANT * QUANT * QUANT))


    when defined(simd):
        proc forwardFast*(self: EvalState, sideToMove: PieceColor, outputBucket: int): Score {.simdKernel.} =
            when not defined(simd) or L1_SIZE mod 128 != 0 or
                    L2_SIZE mod I32_CHUNK_SIZE != 0 or L3_SIZE mod I32_CHUNK_SIZE != 0:
                return self.forwardScalar(sideToMove, outputBucket)
            else:
                ## The same as forwardScalar but MUCH faster thanks to SIMD optimizations

                # https://cosmo.tardis.ac/files/2024-08-17-multilayer.html
                # https://github.com/Ciekce/stoat/blob/main/src/eval/nnue.cpp
                # https://github.com/PGG106/Alexandria/blob/fuckvinny/src/nnue.cpp
                const
                    PAIR_COUNT: uint64 = L1_SIZE div 2
                    QUANT = 1 shl QUANT_BITS
                    L1_SHIFT = 16 + QUANT_BITS - FT_SCALE_BITS - FT_QUANT_BITS - FT_QUANT_BITS - L1_QUANT_BITS
                let
                    zero = vecZero16()
                    one = vecSetOne16(QA)
                    l1CreluOne {.used.} = vecSetOne32(QUANT)
                    l1ScreluOne {.used.} = vecSetOne32(QUANT * QUANT)
                    l2One {.used.} = vecSetOne32(QUANT * QUANT * QUANT)

                var ftOut {.noinit.}: AlignedArray[L1_SIZE, uint8]
                for accNum, pov in [sideToMove, sideToMove.opposite()]:
                    template combined(offset: uint64): VEPI16 =
                        vecAdd16(vecLoad(addr self.accumulators[pov][self.current].data[offset]),
                                 vecLoad(addr self.threatAccumulators[pov][self.current].data[offset]))

                    # Load input activations
                    for packedOffset in countup(0'u64, PAIR_COUNT - 1, I16_CHUNK_SIZE * 2):
                        # Emulate AVX-512 packus on every width by pairing the lower
                        # and upper 32-product halves, then storing consecutively.
                        let
                            i = (packedOffset div 64) * 64 + (packedOffset mod 64) div 2
                            input0a = combined(i)
                            input0b = combined(i + 32)
                            input1a = combined(i + PAIR_COUNT)
                            input1b = combined(i + 32 + PAIR_COUNT)

                        # Clip the inputs between 0.0 and 1.0 (well, actually between zero and QA since
                        # we're in quantized space, but mathematically that's what it means)
                        let
                            clipped0a = vecMin16(vecMax16(input0a, zero), one)
                            clipped0b = vecMin16(vecMax16(input0b, zero), one)
                            # Here we skip the max operation for the same reason explained
                            # in the scalar inference, except we actually benefit from it
                            # in terms of speed
                            clipped1a = vecMin16(input1a, one)
                            clipped1b = vecMin16(input1b, one)

                        # Multiply clipped inputs and store result. We use mulhi instead of mullo
                        # because it preserves the sign (and lets us do that shifting magic from my
                        # boy cj. Read the stockfish comment mentioned in scalar inference for more
                        # info)
                        let
                            productA = vecMulhi16(vecLShift16(clipped0a, FT_SCALE_BITS.int32), clipped1a)
                            productB = vecMulhi16(vecLShift16(clipped0b, FT_SCALE_BITS.int32), clipped1b)
                            packed = vecPackI16toU8(productA, productB)

                        vecStore(addr ftOut.data[packedOffset + (PAIR_COUNT * accNum.uint64)], packed)

                let ftOutI32s = cast[array[L1_SIZE div 4, int32]](ftOut.data)
                # VEPI32 is already aligned. No need to use AlignedArray
                var intermediate {.noinit.}: array[L2_SIZE div I32_CHUNK_SIZE, VEPI32]
                # L1 propagation
                for i in 0..<L2_SIZE div I32_CHUNK_SIZE:
                    intermediate[i] = vecZero32()
                # Emulated byte dots need more temporaries: use one accumulation chain.
                # Preserve dpbusdx2 pair boundaries; only regroup wrapping int32 sums.
                const groupStep = when defined(neon) or defined(sse2): 2 else: 4
                when groupStep == 4:
                    var intermediate2 {.noinit.}: array[L2_SIZE div I32_CHUNK_SIZE, VEPI32]
                    for i in 0..<L2_SIZE div I32_CHUNK_SIZE:
                        intermediate2[i] = vecZero32()
                for group in countup(0, L1_SIZE div 4 - 1, groupStep):
                    let
                        inputs0 = vecSetOne32(ftOutI32s[group])
                        inputs1 = vecSetOne32(ftOutI32s[group + 1])
                    when groupStep == 4:
                        let
                            inputs2 = vecSetOne32(ftOutI32s[group + 2])
                            inputs3 = vecSetOne32(ftOutI32s[group + 3])
                    for j in 0..<L2_SIZE div I32_CHUNK_SIZE:
                        let
                            w0 = vecLoad(addr network.l1.weight[outputBucket][group * 4 * L2_SIZE + j * 4 * I32_CHUNK_SIZE])
                            w1 = vecLoad(addr network.l1.weight[outputBucket][(group + 1) * 4 * L2_SIZE + j * 4 * I32_CHUNK_SIZE])
                        intermediate[j] = vecDpbusdx2(intermediate[j], inputs0, w0, inputs1, w1)
                        when groupStep == 4:
                            let
                                w2 = vecLoad(addr network.l1.weight[outputBucket][(group + 2) * 4 * L2_SIZE + j * 4 * I32_CHUNK_SIZE])
                                w3 = vecLoad(addr network.l1.weight[outputBucket][(group + 3) * 4 * L2_SIZE + j * 4 * I32_CHUNK_SIZE])
                            intermediate2[j] = vecDpbusdx2(intermediate2[j], inputs2, w2, inputs3, w3)
                when groupStep == 4:
                    for j in 0..<L2_SIZE div I32_CHUNK_SIZE:
                        intermediate[j] = vecAdd32(intermediate[j], intermediate2[j])

                var l1Out {.noinit.}: AlignedArray[L2_SIZE * (1 + DUAL_ACTIVATION.int), int32]

                # Requantize, add biases, activate
                for j in 0..<L2_SIZE div I32_CHUNK_SIZE:
                    # Note to self: some arches do shift-then-add, some add-then shift. Something
                    # to keep in mind for future potential borkage
                    var output = vecRAShift32(vecAdd32(intermediate[j], vecLoad(addr network.l1.bias[outputBucket][j * I32_CHUNK_SIZE])), (-L1_SHIFT).int32)

                    when DUAL_ACTIVATION:
                        var crelu = output
                        var screlu = output

                        # crelu: clamp [0, QUANT], then lift into Q*Q space
                        crelu = vecLShift32(vecMin32(vecMax32(crelu, vecZero32()), l1CreluOne), QUANT_BITS.int32)
                        # screlu: square the *unclamped* value, then cap at QUANT^2 (no lower clamp needed)
                        screlu = vecMin32(vecMullo32(screlu, screlu), l1ScreluOne)

                        vecStore(addr l1Out.data[j * I32_CHUNK_SIZE], crelu)
                        vecStore(addr l1Out.data[L2_SIZE + j * I32_CHUNK_SIZE], screlu)
                    else:
                        let act = vecMin32(vecMax32(output, vecZero32()), l1CreluOne)
                        vecStore(addr l1Out.data[j * I32_CHUNK_SIZE], vecMullo32(act, act))

                # Load L2 biases, run l1Out through L2

                var l2Out {.noinit.}: array[L3_SIZE div I32_CHUNK_SIZE, VEPI32]

                for j in 0..<L3_SIZE div I32_CHUNK_SIZE:
                    l2Out[j] = vecLoad(addr network.l2.buckets[outputBucket].bias[j * I32_CHUNK_SIZE])

                for i in 0..<L2_SIZE * (1 + DUAL_ACTIVATION.int):
                    let inputs = vecSetOne32(l1Out.data[i])
                    for j in 0..<L3_SIZE div I32_CHUNK_SIZE:
                        l2Out[j] = vecAdd32(l2Out[j], vecMullo32(inputs, vecLoad(addr network.l2.buckets[outputBucket].weight[i][j * I32_CHUNK_SIZE])))

                # L3: Quantize, feed forward, activate

                var sum = vecZero32()
                for j in 0..<L3_SIZE div I32_CHUNK_SIZE:
                    # crelu in Q^3 space — clamp FIRST, then multiply (scalar clamps i before i * w)
                    let act = vecMin32(vecMax32(l2Out[j], vecZero32()), l2One)
                    let w   = vecLoad(addr network.l3.buckets[outputBucket].weight[j * I32_CHUNK_SIZE][0])
                    sum = vecAdd32(sum, vecMullo32(act, w))

                # Bias + final sum
                result = Score(network.l3.buckets[outputBucket].bias[0] + vecReduceAdd32(sum))
                # Match scalar rounding with a wide scaling intermediate.
                result = Score(result.int64 * EVAL_SCALE div (QUANT.int64 * QUANT * QUANT * QUANT))


proc evaluate*(position: Position, state: EvalState): Score {.inline.} =
    ## Evaluates the given position

    # Apply pending updates
    for i in 0..<state.pending:
        let update = state.updates[i]
        inc(state.current)
        let nstm = update.sideToMove.opposite()
        if not update.needsRefresh:
            state.applyPSQUpdatePair(update.move, update.sideToMove, update.piece, update.captured)
            state.updateThreats(update.posIndex.uint64)
        else:
            # Only the moving king can invalidate its perspective's bucket.
            state.refreshPSQ(update.sideToMove, state.board.positions[update.posIndex])
            state.refreshThreats(update.sideToMove, state.board.positions[update.posIndex])
            # Other side gets UE'd
            state.updateThreats(update.posIndex.uint64, nstm)
            state.applyPSQUpdate(nstm, update.move, update.sideToMove, update.piece, update.captured)
    state.pending = 0

    const divisor = 32 div NUM_OUTPUT_BUCKETS
    let outputBucket = (position.pieces().count() - 2) div divisor

    when not defined(simd):
        return state.forwardScalar(position.sideToMove, outputBucket)
    else:
        return state.forwardFast(position.sideToMove, outputBucket)


proc evaluate*(board: Chessboard, state: EvalState): Score {.inline.} =
    ## Evaluates the current position in the chessboard
    return board.position.evaluate(state)
