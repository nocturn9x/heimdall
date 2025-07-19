# Copyright 2025 Mattia Giambirtone & All Contributors
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
import heimdall/[board, moves, pieces, position, nnue]

when defined(simd):
    import heimdall/util/simd

when not VERBATIM_NET:
    import std/streams


const MAX_ACCUMULATORS = 255

type

    Score* = int32

    Accumulator = object
        data {.align(ALIGNMENT_BOUNDARY).}: array[L1_SIZE, int16]
        kingSquare: Square

    CachedAccumulator* = object
        acc: Accumulator
        colors: array[White..Black, Bitboard]
        pieces: array[Pawn..King, Bitboard]

    # A record for an efficient update
    Update = tuple[move: Move, sideToMove: PieceColor, piece, captured: PieceKind, needsRefresh: array[White..Black, bool], posIndex: int]

    EvalState* = ref object
        # Current accumulator
        current: int
        # Accumulator stack. We keep one per ply
        accumulators: array[White..Black, array[MAX_ACCUMULATORS, Accumulator]]
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


func lowestEval*: Score {.inline.} = Score(-30_000)
func highestEval*: Score {.inline.} = Score(30_000)
func mateScore*: Score {.inline.} = highestEval()


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


# Network is global for performance reasons!
var network*: Network

proc newEvalState*(networkPath: string = "", verbose: static bool = true): EvalState =
    new(result)
    if networkPath == "":
        when not VERBATIM_NET:
            when verbose:
                echo "info string loading built-in network"
            network = loadNet(newStringStream(DEFAULT_NET_WEIGHTS))
        else:
            when verbose:
                echo "info string using verbatim network"
            let temp = cast[ptr Network](VERBATIM_NET_DATA)
            network = temp[]
    else:
        network = loadNet(networkPath)


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


proc refresh(self: EvalState, side: PieceColor, position: Position, useCache: static bool = true) =
    ## Performs an accumulator refresh for the given
    ## side

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
    self.refresh(White, board.position)
    self.refresh(Black, board.position)


func getKingCastlingTarget(move: Move, sideToMove: PieceColor): Square {.inline.} =
    if move.targetSquare < move.startSquare:
        return Piece(kind: King, color: sideToMove).longCastling()
    else:
        return Piece(kind: King, color: sideToMove).shortCastling()


func getRookCastlingTarget(move: Move, sideToMove: PieceColor): Square {.inline.} =
    if move.targetSquare < move.startSquare:
        return Piece(kind: Rook, color: sideToMove).longCastling()
    else:
        return Piece(kind: Rook, color: sideToMove).shortCastling()


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
    let needsRefresh = [self.mustRefresh(White, kingSq, nextKingSq), self.mustRefresh(Black, kingSq, nextKingSq)]
    # We use len() instead of high() because update() is called before the move is made, so the length of the sequence
    # will be the index of the next position once doMove is called
    self.updates[self.pending] = (move, sideToMove, piece, captured, needsRefresh, self.board.positions.len())
    inc(self.pending)


proc applyUpdate(self: EvalState, color: PieceColor, move: Move, sideToMove: PieceColor, piece: PieceKind, captured=Empty) =
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
            # All captures (including ep) always add one feature and remove two

            # The xor trick is a faster way of doing +/-8 depending on the stm
            let taron = if move.isCapture(): feature(color, nonSideToMove, captured, move.targetSquare, kingSq) else: feature(color, nonSideToMove, Pawn, move.targetSquare xor 8, kingSq)
            queue.addSubSub(newPieceIndex, movingPieceIndex, taron)
    else:
        # Move the king and rook
        # Castling adds two features and removes two
        queue.addSub(feature(color, sideToMove, King, move.getKingCastlingTarget(sideToMove), kingSq), feature(color, sideToMove, King, move.startSquare, kingSq))
        queue.addSub(feature(color, sideToMove, Rook, move.getRookCastlingTarget(sideToMove), kingSq), feature(color, sideToMove, Rook, move.targetSquare, kingSq))

    # Apply all updates at once
    queue.apply(network.ft, self.accumulators[color][self.current - 1].data, self.accumulators[color][self.current].data)


proc undo*(self: EvalState) {.inline.} =
    ## Discards the previous accumulator update
    if self.pending > 0:
        dec(self.pending)
    else:
        dec(self.current)


# Logic entirely yoinked from Stormphrax. Thanks cie!
proc forward*(self: EvalState, sideToMove: PieceColor, outputBucket: int): Score =
    ## Runs a forward pass through the given output bucket, using the given accumulator
    ## and side to move pair, and returns the output
    const 
        PAIR_COUNT: uint64 = L1_SIZE div 2
        L1_SHIFT = 16 + QUANT_BITS - FT_SCALE_BITS - FT_QUANT_BITS - FT_QUANT_BITS - L1_QUANT_BITS
        QUANT = 1 shl QUANT_BITS

    type AlignedArray[K: static[int], T] = object
        data {.align(ALIGNMENT_BOUNDARY).}: array[K, T]

    var
        # Activated FT outputs (concated accumulators)
        ftOut: AlignedArray[L1_SIZE, uint8]
        # Activated L1 outputs. Dual activation, so twice the outputs
        l1Out: AlignedArray[L2_SIZE * 2, int32]
        # Unactivated L2 outputs
        l2Out: AlignedArray[L3_SIZE, int32]

    # Activate the FT: We do pairwise activation to reduce the size of the
    # L1 matmul in half. See https://github.com/official-stockfish/Stockfish/blob/master/src/nnue/nnue_feature_transformer.h#L278
    # for more details on this shifting business and why we use it to perform
    # quantizations instead of simple division. The TLDR is that it's faster,
    # but we are limited to quantization constants that are powers of 2. In practice
    # this limitation doesn't matter, so it's free speed at no cost
    func activatePerspective(inputs: Accumulator, outputOffset: uint64) =
        for inputIdx in 0..<PAIR_COUNT:
            var
                i1 = inputs.data[inputIdx]
                i2 = inputs.data[inputIdx + PAIR_COUNT]

            # Use crelu activation for both values (the "squaring" will just be
            # us multiplying them together)
            i1 = clamp(i1, 0, (1 shl FT_QUANT_BITS) - 1)
            # We can save a max operation (hence why we don't do clamp())
            # here thanks to that stockfish trick I mentioned earlier
            i2 = min(i2, (1 shl FT_QUANT_BITS) - 1)
            
            let
                # Divide by the scale
                s = i1 shl FT_SCALE_BITS
                # Poor man's mulhi (AVX2 intrinsic). Uses the same fast modulo reduction
                # trick that we use for indexing the transposition table!
                p = (cast[int32](s) * cast[int32](i2)) shr 16
                packed = cast[uint8](clamp(p, 0, 255))
            
            ftOut.data[outputOffset + inputIdx] = packed
    
    # Activate side-to-move accumulator into ftOut[0..L1_SIZE / 2]
    activatePerspective(self.accumulators[sideToMove][self.current], 0)
    # Activate non side-to-move accumulator into ftOut[L1_SIZE / 2..L1_SIZE]
    activatePerspective(self.accumulators[sideToMove.opposite()][self.current], PAIR_COUNT)

    # Unactivated L1 outputs in the quantized space (FT quant * L1 quant)
    var intermediate: array[L2_SIZE, int32]

    # This is the actual layer 1 matmul operation
    for inputIdx in 0..<L1_SIZE:
        let i = ftOut.data[inputIdx]

        for outputIdx in 0..<L2_SIZE:
            # The indexing is weird instead of simply [inputIdx][outputIdx] (or
            # inputIdx * L2_SIZE + outputIdx) because dpbusd requires this ordering
            let
                weightIdx = (inputIdx - (inputIdx mod 4)) * L2_SIZE + outputIdx * 4 + (inputIdx mod 4)
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

        output = output shr -L1_SHIFT
        output += bias

        var crelu = output
        var screlu = output

        # ReLU + clip
        crelu = crelu.clamp(0, QUANT)
        # Shift into Q*Q space (currently Q) to match squared side
        crelu = crelu shl QUANT_BITS

        screlu *= screlu
        # Clip in Q*Q space (we just squared this value, so we squared Q too)
        screlu = min(screlu, QUANT * QUANT)

        l1Out.data[i] = crelu
        l1Out.data[i + L2_SIZE] = screlu

    # Values are now in Q*Q space (see above)

    for i, bias in network.l2.buckets[outputBucket].bias:
        l2Out.data[i] = bias

    # Perform L2 matmul
    for inputIdx in 0..<L2_SIZE * 2:
        let i = l1Out.data[inputIdx]

        for outputIdx in 0..<L3_SIZE:
            let w = network.l2.buckets[outputBucket].weight[inputIdx][outputIdx]

            l2Out.data[outputIdx] += i * w

    # Values are now in Q*Q*Q space, we just multiplied Q*Q values by Q weights
    result = network.l3.buckets[outputBucket].bias[0]

    # Activate L2 outputs and do L3 matmul
    for inputIdx in 0..<L3_SIZE:
        var i = l2Out.data[inputIdx]

        let w = network.l3.buckets[outputBucket].weight[inputIdx][0]

        # crelu
        i = i.clamp(0, QUANT * QUANT * QUANT)

        result += i * w
    # Values are now in Q*Q*Q*Q space

    # Dequantise by one step before scaling to avoid overflow
    result = result div QUANT
    result *= EVAL_SCALE
    # Dequantize the rest
    result = result div (QUANT * QUANT * QUANT)


proc evaluate*(position: Position, state: EvalState): Score {.inline.} =
    ## Evaluates the given position

    # Apply pending updates
    for i in 0..<state.pending:
        let update = state.updates[i]
        inc(state.current)
        for color in White..Black:
            if update.needsRefresh[color]:
                # TODO: There's a chance for an optimization here: once we find
                # an accumulator that needs a refresh, we can just refresh from
                # the last position and stop updating for that side. This would
                # allow us to get rid of the posIndex field and should be a nice
                # speedup
                state.refresh(color, state.board.positions[update.posIndex])
            else:
                state.applyUpdate(color, update.move, update.sideToMove, update.piece, update.captured)
    state.pending = 0

    const divisor = 32 div NUM_OUTPUT_BUCKETS
    let outputBucket = (position.pieces().count() - 2) div divisor

    when true:
        # TODO: SIMD
        return state.forward(position.sideToMove, outputBucket)
    else:
        discard


proc evaluate*(board: Chessboard, state: EvalState): Score {.inline.} =
    ## Evaluates the current position in the chessboard
    return board.position.evaluate(state)