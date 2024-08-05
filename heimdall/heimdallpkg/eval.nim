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
import heimdallpkg/weights


import nnue/model
import nnue/data



type
    Update = tuple[move: Move, sideToMove: PieceColor, piece: PieceKind, captured: PieceKind]
    Score* = int32

    EvalState* = ref object
        # Current accumulator
        current: int
        # Accumulator stack
        accumulators*: array[White..Black, array[256, array[HL_SIZE, BitLinearWB]]]
    

func lowestEval*: Score {.inline.} = Score(-30_000)
func highestEval*: Score {.inline.} = Score(30_000)
func mateScore*: Score {.inline.} = highestEval()


func newEvalState*: EvalState =
    new(result)


func getGamePhase(position: Position): int {.inline.} =
    ## Computes the game phase according to
    ## how many pieces are left on the board
    result = 0
    for sq in position.getOccupancy():
        case position.getPiece(sq).kind:
            of Bishop, Knight:
                inc(result)
            of Queen:
                inc(result, 4)
            of Rook:
                inc(result, 2)
            else:
                discard
    # Caps the value in case of early 
    # promotions
    result = min(24, result)


proc getPieceScore*(position: Position, square: Square): Score =
    ## Returns the value of the piece located at
    ## the given square given the current game phase
    let
        piece = position.getPiece(square)
        scores = PIECE_SQUARE_TABLES[piece.color][piece.kind][square]
        middleGamePhase = position.getGamePhase()
        endGamePhase = 24 - middleGamePhase

    result = Score((scores.mg * middleGamePhase + scores.eg * endGamePhase) div 24)


proc getPieceScore*(position: Position, piece: Piece, square: Square): Score =
    ## Returns the value the given piece would have if it
    ## were at the given square given the current game phase
    let
        scores = PIECE_SQUARE_TABLES[piece.color][piece.kind][square]
        middleGamePhase = position.getGamePhase()
        endGamePhase = 24 - middleGamePhase

    result = Score((scores.mg * middleGamePhase + scores.eg * endGamePhase) div 24)


func pieceToIndex(kind: PieceKind): int =
    ## Fixes our funky™️ piece indexing
    ## so it is a bit more sane
    case kind
        of Pawn:
            return 0
        of Knight:
            return 1
        of Bishop:
            return 2
        of Rook:
            return 3
        of Queen:
            return 4
        of King:
            return 5
        of Empty:
            return 6


func feature(perspective: PieceColor, color: PieceColor, piece: PieceKind, square: Square): int =
    ## Constructs a feature from the given perspective for a piece
    ## of the given type and color on the given square
    let colorIndex = if perspective == color: 0 else: 1
    let pieceIndex = pieceToIndex(piece)
    let squareIndex = if perspective == White: int(square.flip()) else: int(square)

    var index = 0
    index = index * 2 + colorIndex
    index = index * 6 + pieceIndex
    index = index * 64 + squareIndex
    return index


proc init*(self: EvalState, position: Position) =
    ## Initializes a new persistent eval
    ## state
    
    data.NETWORK.ft.initAccumulator(self.accumulators[White][self.current])
    data.NETWORK.ft.initAccumulator(self.accumulators[Black][self.current])

    # Add relevant features for both perspectives
    for sq in position.getOccupancy():
        let piece = position.getPiece(sq)
        data.NETWORK.ft.addFeature(feature(White, piece.color, piece.kind, sq), self.accumulators[White][self.current])
        data.NETWORK.ft.addFeature(feature(Black, piece.color, piece.kind, sq), self.accumulators[Black][self.current])


proc update*(self: EvalState, move: Move, sideToMove: PieceColor, piece: PieceKind, captured=Empty) =
    ## Updates the accumulators with the given move made by the given
    ## side with the given piece type. If the move is a capture, the
    ## captured piece type is expected as the captured argument
    let nonSideToMove = sideToMove.opposite()
    inc(self.current)
    for color in White..Black:
        self.accumulators[color][self.current] = self.accumulators[color][self.current - 1]
        if not move.isCastling():
            data.NETWORK.ft.removeFeature(feature(color, sideToMove, piece, move.startSquare), self.accumulators[color][self.current])
            if not move.isPromotion():
                data.NETWORK.ft.addFeature(feature(color, sideToMove, piece, move.targetSquare), self.accumulators[color][self.current])
            else:
                data.NETWORK.ft.addFeature(feature(color, sideToMove, move.getPromotionType().promotionToPiece(), move.targetSquare), self.accumulators[color][self.current])
        else:
            # Move the king and rook
            let kingTarget = if move.targetSquare < move.startSquare: Piece(kind: King, color: sideToMove).queenSideCastling() else: Piece(kind: King, color: sideToMove).kingSideCastling()
            let rookTarget = if move.targetSquare < move.startSquare: Piece(kind: Rook, color: sideToMove).queenSideCastling() else: Piece(kind: Rook, color: sideToMove).kingSideCastling()
            
            data.NETWORK.ft.removeFeature(feature(color, sideToMove, King, move.startSquare), self.accumulators[color][self.current])
            data.NETWORK.ft.addFeature(feature(color, sideToMove, King, kingTarget), self.accumulators[color][self.current])

            data.NETWORK.ft.removeFeature(feature(color, sideToMove, Rook, move.targetSquare), self.accumulators[color][self.current])
            data.NETWORK.ft.addFeature(feature(color, sideToMove, Rook, rookTarget), self.accumulators[color][self.current])
            # No need to do any further processing after castling (for this color)
            continue

        if move.isCapture():
            data.NETWORK.ft.removeFeature(feature(color, nonSideToMove, captured, move.targetSquare), self.accumulators[color][self.current])

        if move.isEnPassant():
            # The xor trick is a faster way of doing +/-8 depending on the stm
            data.NETWORK.ft.removeFeature(feature(color, nonSideToMove, Pawn, move.targetSquare xor 8), self.accumulators[color][self.current])


func undo*(self: EvalState) {.inline.} =
    ## Discards the previous accumulator update
    dec(self.current)


proc evaluate*(position: Position, state: EvalState): Score =
    ## Evaluates the given position

    # Activate outputs. stmHalf is the perspective of
    # the side to move, nstmHalf of the other side
    var stmHalf: array[HL_SIZE, LinearI]
    var nstmHalf: array[HL_SIZE, LinearI]
    if position.sideToMove == White:
        crelu(state.accumulators[White][state.current], stmHalf)
        crelu(state.accumulators[Black][state.current], nstmHalf)
    else:
        crelu(state.accumulators[Black][state.current], stmHalf)
        crelu(state.accumulators[White][state.current], nstmHalf)

    # Concatenate the two input sets depending on which
    # side is to move. This allows the network to learn
    # tempo, which is extremely valuable!
    var ftOut: array[HL_SIZE * 2, LinearI]
    for i in 0..<HL_SIZE:
        ftOut[i] = stmHalf[i]
        ftOut[i + HL_SIZE] = nstmHalf[i]

    # Feed inputs through the network
    var l1Out: array[1, LinearB]
    data.NETWORK.l1.forward(ftOut, l1Out)

    # Profit! Now we just need to scale the result
    # so that it's not a teeny tiny integer and to
    # gain back some of the precision we lost during
    # quantization
    return l1Out[0] * EVAL_SCALE div QB div QA


proc evaluate*(board: Chessboard, state: EvalState): Score {.inline.} =
    ## Evaluates the current position in the chessboard
    return board.positions[^1].evaluate(state)


proc evaluate*(board: Chessboard): Score {.inline.} =
    var state = newEvalState()
    state.init(board.positions[^1])
    return board.evaluate(state)