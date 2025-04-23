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
import heimdall/board
import heimdall/moves
import heimdall/pieces
import heimdall/position
import heimdall/nnue/util
import heimdall/nnue/model

when defined(simd):
    import heimdall/util/simd

import std/streams


const MAX_ACCUMULATORS = 255

type

    Score* = int32

    Accumulator = object
        data {.align(ALIGNMENT_BOUNDARY).}: array[HL_SIZE, BitLinearWB]
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
func isMateScore*(score: Score): bool {.inline.} = abs(score) >= mateScore() - 255

# Network is global for performance reasons!
var network: Network


proc newEvalState*(networkPath: string = ""): EvalState =
    new(result)
    if networkPath == "":
        network = loadNet(newStringStream(DEFAULT_NET_WEIGHTS))
    else:
        network = loadNet(networkPath)


func feature(perspective: PieceColor, color: PieceColor, piece: PieceKind, square: Square): int =
    ## Constructs a feature from the given perspective for a piece
    ## of the given type and color on the given square
    
    var colorIndex: int
    when MERGED_KINGS:
        # We always use index 0 for the king because we do something called merged kings:
        # due to the layout of our input buckets (i.e. they don't span more than 2x2 squares),
        # it is impossible for two kings to be in the same bucket at any given time, so we can
        # save a bunch of space (about 8%) by only accounting for one king per bucket, shrinking
        # the size of the feature transformer from 768 inputs to 704
        colorIndex = if (perspective == color or piece == King): 0 else: 1
    else:
        colorIndex = if perspective == color: 0 else: 1
    let pieceIndex = piece.int
    let squareIndex = if perspective == White: int(square.flipRank()) else: int(square)

    result = result * 2 + colorIndex
    result = result * 6 + pieceIndex
    result = result * 64 + squareIndex


func shouldMirror(kingSq: Square): bool =
    ## Returns whether the king being on this location
    ## would cause horizontal mirroring of the board
    when MIRRORED:
        return fileFromSquare(kingSq) > 3
    else:
        return false


proc kingBucket*(side: PieceColor, square: Square): int =
    ## Returns the input bucket associated with the king
    ## of the given side located at the given square
    
    # We flip for white instead of black because the
    # bucket layout assumes a1=0 and we use a8=0 instead
    if side == White:
        return INPUT_BUCKETS[square.flipRank()]
    else:
        return INPUT_BUCKETS[square]


proc mustRefresh(self: EvalState, side: PieceColor, prevKingSq, currKingSq: Square): bool =
    ## Returns whether an accumulator refresh is required for the given side
    ## as opposed to an efficient update
    if shouldMirror(prevKingSq) != shouldMirror(currKingSq):
        return true
    return kingBucket(side, prevKingSq) != kingBucket(side, currKingSq)


proc refresh(self: EvalState, side: PieceColor, position: Position, useCache: static bool = true) =
    ## Performs an accumulator refresh for the given
    ## side

    let
        kingSq = position.getBitboard(King, side).toSquare()
        mirror = shouldMirror(kingSq)
        bucket = kingBucket(side, kingSq)

    # Update king location
    self.cache[side][bucket][mirror].acc.kingSquare = kingSq

    # We don't refresh from the cache but we still use it so it's
    # ready for the next refresh
    when not useCache:
        network.ft.initAccumulator(self.cache[side][bucket][mirror].acc.data)
        for color in White..Black:
            self.cache[side][bucket][mirror].colors[color] = position.getOccupancyFor(color)
        for piece in PieceKind.all():
            self.cache[side][bucket][mirror].pieces[piece] = position.getBitboard(piece)

        for sq in position.getOccupancy():
            var sq = sq
            let piece = position.getPiece(sq)
            if mirror:
                sq = sq.flipFile()
            network.ft.addFeature(feature(side, piece.color, piece.kind, sq), bucket, self.cache[side][bucket][mirror].acc.data)
    else:
        # Incrementally update from last known-good refresh and keep the cache
        # up to date
        for color in White..Black:
            for piece in PieceKind.all():
                let
                    previous = self.cache[side][bucket][mirror].pieces[piece] and self.cache[side][bucket][mirror].colors[color]
                    current = position.getBitboard(piece, color)
                # Add pieces that were added since last refresh
                for square in current and not previous:
                    var square = square
                    if mirror:
                        square = square.flipFile()
                    network.ft.addFeature(feature(side, color, piece, square), bucket, self.cache[side][bucket][mirror].acc.data)
                # Remove pieces that have gone since the last refresh
                for square in previous and not current:
                    var square = square
                    if mirror:
                        square = square.flipFile()
                    network.ft.removeFeature(feature(side, color, piece, square), bucket, self.cache[side][bucket][mirror].acc.data)
        for color in White..Black:
            for piece in PieceKind.all():
                self.cache[side][bucket][mirror].pieces[piece] = position.getBitboard(piece)
            self.cache[side][bucket][mirror].colors[color] = position.getOccupancyFor(color)
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
        return Piece(kind: King, color: sideToMove).queenSideCastling()
    else: 
        return Piece(kind: King, color: sideToMove).kingSideCastling()


func getRookCastlingTarget(move: Move, sideToMove: PieceColor): Square {.inline.} =
    if move.targetSquare < move.startSquare: 
        return Piece(kind: Rook, color: sideToMove).queenSideCastling()
    else: 
        return Piece(kind: Rook, color: sideToMove).kingSideCastling()


func getNextKingSquare(move: Move, piece: PieceKind, sideToMove: PieceColor, previousKingSq: Square): Square {.inline.} =
    if piece == King and not move.isCastling():
        return move.targetSquare
    elif move.isCastling(): 
        return move.getKingCastlingTarget(sideToMove)
    else:
        return previousKingSq


proc update*(self: EvalState, move: Move, sideToMove: PieceColor, piece: PieceKind, captured=Empty, kingSq: Square) =
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
        mirror = shouldMirror(self.accumulators[color][self.current].kingSquare)
        startSquare = if not mirror: move.startSquare else: move.startSquare.flipFile()
        targetSquare = if not mirror: move.targetSquare else: move.targetSquare.flipFile()
        bucket = kingBucket(color, self.accumulators[color][self.current].kingSquare)

    if not move.isCastling():
        let newPieceIndex = feature(color, sideToMove, (if not move.isPromotion(): piece else: move.getPromotionType().promotionToPiece()), targetSquare)
        let movingPieceIndex = feature(color, sideToMove, piece, startSquare)
        
        # Quiets and non-capture promotions add one feature and remove one
        if move.isQuiet() or (not move.isCapture() and move.isPromotion()):
            queue.addSub(newPieceIndex, movingPieceIndex)
        else:
            # All captures (including ep) always add one feature and remove two

            # The xor trick is a faster way of doing +/-8 depending on the stm
            let targetPiece = if move.isCapture(): feature(color, nonSideToMove, captured, targetSquare) else: feature(color, nonSideToMove, Pawn, targetSquare xor 8)
            queue.addSubSub(newPieceIndex, movingPieceIndex, targetPiece)
    else:
        # Move the king and rook
        var kingTarget = move.getKingCastlingTarget(sideToMove)
        var rookTarget = move.getRookCastlingTarget(sideToMove)

        if mirror:
            kingTarget = kingTarget.flipFile()
            rookTarget = rookTarget.flipFile()

        # Castling adds two features and removes two
        queue.addSub(feature(color, sideToMove, King, kingTarget), feature(color, sideToMove, King, startSquare))
        queue.addSub(feature(color, sideToMove, Rook, rookTarget), feature(color, sideToMove, Rook, targetSquare))
    
    # Apply all updates at once
    queue.apply(network.ft, bucket, self.accumulators[color][self.current - 1].data, self.accumulators[color][self.current].data)


proc undo*(self: EvalState) {.inline.} =
    ## Discards the previous accumulator update
    if self.pending > 0:
        dec(self.pending)
    else:
        dec(self.current)


proc evaluate*(position: Position, state: EvalState): Score {.inline.} =
    ## Evaluates the given position

    # Apply pending updates
    for i in 0..<state.pending:
        let update = state.updates[i]
        inc(state.current)
        for color in White..Black:
            if update.needsRefresh[color]:
                state.refresh(color, state.board.positions[update.posIndex])
            else:
                state.applyUpdate(color, update.move, update.sideToMove, update.piece, update.captured)
    state.pending = 0

    const divisor = 32 div NUM_OUTPUT_BUCKETS
    let outputBucket = (position.getOccupancy().countSquares() - 2) div divisor

    # Fallback to fast autovec inference when SIMD is disabled at compile time
    when not defined(simd):
        # Instead of activating each side separately and then concatenating the
        # two input sets and doing a forward pass through the network, we do
        # everything on the fly to gain some extra speed. Stolen from Alexandria
        # (https://github.com/PGG106/Alexandria/blob/master/src/nnue.cpp#L174)
        var sum: LinearB
        var weightOffset = 0
        for accumulator in [state.accumulators[position.sideToMove][state.current].data,
                            state.accumulators[position.sideToMove.opposite()][state.current].data]:
            for i in 0..<HL_SIZE:
                let input = accumulator[i]
                let weight = network.l1.weight[outputBucket][i + weightOffset]
                let clipped = clamp(input, 0, QA)
                sum += int16(clipped * weight) * int32(clipped)
            weightOffset += HL_SIZE
        # Profit! Now we just need to scale the result
        return ((sum div QA + network.l1.bias[outputBucket]) * EVAL_SCALE) div (QA * QB)
    else:
        # AVX go brrrrrrrrrrr
        var 
            sum = vecZero32()
            zero = vecZero16()
            one = vecSetOne16(QA)
            weightOffset = 0
        for accumulator in [state.accumulators[position.sideToMove][state.current].data,
                            state.accumulators[position.sideToMove.opposite()][state.current].data]:
            var i = 0
            while i < HL_SIZE:
                var input = vecLoadU(addr accumulator[i])
                var weight = vecLoadU(addr network.l1.weight[outputBucket][i + weightOffset])
                var clipped = vecMin16(vecMax16(input, zero), one)

                var product = vecMadd16(vecMullo16(clipped, weight), clipped)
                sum = vecAdd32(sum, product)

                i += CHUNK_SIZE
            
            weightOffset += HL_SIZE
        return (vecReduceAdd32(sum) div QA + network.l1.bias[outputBucket]) * EVAL_SCALE div (QA * QB)


proc evaluate*(board: Chessboard, state: EvalState): Score {.inline.} =
    ## Evaluates the current position in the chessboard
    return board.position.evaluate(state)
