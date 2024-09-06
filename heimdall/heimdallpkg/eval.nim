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

## Position evaluation utilities
import heimdallpkg/pieces
import heimdallpkg/position
import heimdallpkg/board
import heimdallpkg/moves
import heimdallpkg/nnue/util

import nnue/model


import std/streams

const
    MAX_ACCUMULATORS = 256

type
    Score* = int32

    Update = tuple[move: Move, sideToMove: PieceColor, piece, captured: PieceKind]
    Accumulator = array[HL_SIZE, BitLinearWB]

    EvalState* = ref object
        # NNUE network
        network: Network
        # Current accumulator
        current: int
        # Accumulator stack. We keep one per ply (plus one, for simplicity's sake,
        # so it's easier to copy stuff)
        accumulators: array[White..Black, array[MAX_ACCUMULATORS, Accumulator]]
        # Pending updates
        updates: array[MAX_ACCUMULATORS, Update]
        # Number of pending updates
        pending: int
    

func lowestEval*: Score {.inline.} = Score(-30_000)
func highestEval*: Score {.inline.} = Score(30_000)
func mateScore*: Score {.inline.} = highestEval()


proc newEvalState*(networkPath: string = ""): EvalState =
    new(result)
    if networkPath == "":
        result.network = loadNet(newStringStream(DEFAULT_NET_WEIGHTS))
    else:
        result.network = loadNet(networkPath)


func feature(perspective: PieceColor, color: PieceColor, piece: PieceKind, square: Square): int =
    ## Constructs a feature from the given perspective for a piece
    ## of the given type and color on the given square
    let colorIndex = if perspective == color: 0 else: 1
    let pieceIndex = piece.int
    let squareIndex = if perspective == White: int(square.flip()) else: int(square)

    result = result * 2 + colorIndex
    result = result * 6 + pieceIndex
    result = result * 64 + squareIndex


proc init*(self: EvalState, position: Position) =
    ## Initializes a new persistent eval
    ## state
    
    self.current = 0
    self.pending = 0

    self.network.ft.initAccumulator(self.accumulators[White][self.current])
    self.network.ft.initAccumulator(self.accumulators[Black][self.current])

    # Add relevant features for both perspectives
    for sq in position.getOccupancy():
        let piece = position.getPiece(sq)
        self.network.ft.addFeature(feature(White, piece.color, piece.kind, sq), self.accumulators[White][self.current])
        self.network.ft.addFeature(feature(Black, piece.color, piece.kind, sq), self.accumulators[Black][self.current])



proc update*(self: EvalState, move: Move, sideToMove: PieceColor, piece: PieceKind, captured=Empty) =
    ## Enqueues an accumulator update with the given datastate
    self.updates[self.pending] = (move, sideToMove, piece, captured)
    inc(self.pending)


proc applyUpdate(self: EvalState, move: Move, sideToMove: PieceColor, piece: PieceKind, captured=Empty) =
    ## Updates the accumulators with the given move made by the given
    ## side with the given piece type. If the move is a capture, the
    ## captured piece type is expected as the captured argument
    let nonSideToMove = sideToMove.opposite()
    inc(self.current)
    for color in White..Black:
        self.accumulators[color][self.current] = self.accumulators[color][self.current - 1]
        if not move.isCastling():
            self.network.ft.removeFeature(feature(color, sideToMove, piece, move.startSquare), self.accumulators[color][self.current])
            if not move.isPromotion():
                self.network.ft.addFeature(feature(color, sideToMove, piece, move.targetSquare), self.accumulators[color][self.current])
            else:
                self.network.ft.addFeature(feature(color, sideToMove, move.getPromotionType().promotionToPiece(), move.targetSquare), self.accumulators[color][self.current])
        else:
            # Move the king and rook
            let kingTarget = if move.targetSquare < move.startSquare: Piece(kind: King, color: sideToMove).queenSideCastling() else: Piece(kind: King, color: sideToMove).kingSideCastling()
            let rookTarget = if move.targetSquare < move.startSquare: Piece(kind: Rook, color: sideToMove).queenSideCastling() else: Piece(kind: Rook, color: sideToMove).kingSideCastling()
            
            self.network.ft.removeFeature(feature(color, sideToMove, King, move.startSquare), self.accumulators[color][self.current])
            self.network.ft.addFeature(feature(color, sideToMove, King, kingTarget), self.accumulators[color][self.current])

            self.network.ft.removeFeature(feature(color, sideToMove, Rook, move.targetSquare), self.accumulators[color][self.current])
            self.network.ft.addFeature(feature(color, sideToMove, Rook, rookTarget), self.accumulators[color][self.current])
            # No need to do any further processing after castling (for this color)
            continue

        if move.isCapture():
            self.network.ft.removeFeature(feature(color, nonSideToMove, captured, move.targetSquare), self.accumulators[color][self.current])

        elif move.isEnPassant():
            # The xor trick is a faster way of doing +/-8 depending on the stm
            self.network.ft.removeFeature(feature(color, nonSideToMove, Pawn, move.targetSquare xor 8), self.accumulators[color][self.current])


proc undo*(self: EvalState) {.inline.} =
    ## Discards the previous accumulator update
    if self.pending > 0:
        dec(self.pending)
    else:
        dec(self.current)


proc evaluate*(position: Position, state: EvalState): Score =
    ## Evaluates the given position

    # Apply pending updates
    for update in 0..<state.pending:
        state.applyUpdate(state.updates[update].move, state.updates[update].sideToMove,
                          state.updates[update].piece, state.updates[update].captured)
    state.pending = 0

    # Activate inputs. stmHalf is the perspective of
    # the side to move, nstmHalf of the other side
    var stmHalf: array[HL_SIZE, LinearI]
    var nstmHalf: array[HL_SIZE, LinearI]

    screlu(state.accumulators[position.sideToMove][state.current], stmHalf)
    screlu(state.accumulators[position.sideToMove.opposite()][state.current], nstmHalf)

    # Concatenate the two input sets depending on which
    # side is to move. This allows the network to learn
    # tempo, which is extremely valuable!
    var ftOut: array[HL_SIZE * 2, LinearI]
    for i in 0..<HL_SIZE:
        ftOut[i] = stmHalf[i]
        ftOut[i + HL_SIZE] = nstmHalf[i]

    # Feed inputs through the network and retrieve the output
    var l1Out: array[1, LinearB]
    state.network.l1.forward(ftOut, l1Out)

    # Profit! Now we just need to scale the result
    return ((l1Out[0] div QA + state.network.l1.bias[0]) * EVAL_SCALE) div (QA * QB)


proc evaluate*(board: Chessboard, state: EvalState): Score {.inline.} =
    ## Evaluates the current position in the chessboard
    return board.position.evaluate(state)
