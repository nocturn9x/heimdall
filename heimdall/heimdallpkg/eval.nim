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
import pieces
import position
import board
import weights


import model
import model_data



type
    Score* = int32



func lowestEval*: Score {.inline.} = Score(-30_000)
func highestEval*: Score {.inline.} = Score(30_000)
func mateScore*: Score {.inline.} = highestEval()


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
    let squareIndex = if perspective == PieceColor.White: int(square.flip()) else: int(square)

    var index = 0
    index = index * 2 + colorIndex
    index = index * 6 + pieceIndex
    index = index * 64 + squareIndex
    return index


proc evaluate*(position: Position): Score =
    ## Evaluates the given position

    # Pre-allocate accumulators for both sides
    var whiteAcc: array[256, BitLinearWB]
    var blackAcc: array[256, BitLinearWB]

    model_data.NETWORK.ft.initAccumulator(whiteAcc)
    model_data.NETWORK.ft.initAccumulator(blackAcc)

    # Add relevant features for both perspectives
    for sq in position.getOccupancy():
        let piece = position.getPiece(sq)
        model_data.NETWORK.ft.addFeature(feature(White, piece.color, piece.kind, sq), whiteAcc)
        model_data.NETWORK.ft.addFeature(feature(Black, piece.color, piece.kind, sq), blackAcc)

    # Activate outputs. stmHalf is the perspective of
    # the side to move, nstmHalf of the other side
    var stmHalf: array[256, LinearI]
    var nstmHalf: array[256, LinearI]
    if position.sideToMove == White:
        crelu(whiteAcc, stmHalf)
        crelu(blackAcc, nstmHalf)
    else:
        crelu(blackAcc, stmHalf)
        crelu(whiteAcc, nstmHalf)

    # Concatenate the two input sets depending on which
    # side is to move. This allows the network to learn
    # tempo, which is extremely valuable!
    var ftOut: array[512, LinearI]
    for i in 0..<256:
        ftOut[i] = stmHalf[i]
        ftOut[i + 256] = nstmHalf[i]

    # Feed inputs through the network
    var l1Out: array[1, LinearB]
    model_data.NETWORK.l1.forward(ftOut, l1Out)

    # Profit!
    return l1Out[0] * 300 div 64 div 255


proc evaluate*(board: Chessboard): Score {.inline.} =
    ## Evaluates the current position in the chessboard
    return board.positions[^1].evaluate()
