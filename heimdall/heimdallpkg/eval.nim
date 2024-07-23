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

import nimpy
import scinim/numpyarrays
import arraymancer

import model
import model_data



type
    Score* = int32

    Features* = ref object of PyNimObjectExperimental
        ## The features of our evaluation
        ## represented as a linear system
        
        # Our piece-square tables contain positional bonuses
        # (and maluses). We have one for each game phase (middle
        # and end game) for each piece
        psqts: array[PieceKind.Bishop..PieceKind.Rook, array[Square(0)..Square(63), tuple[mg, eg: float]]]
        # These are the relative values of each piece in the middle game and endgame
        pieceWeights: array[PieceKind.Bishop..PieceKind.Rook, tuple[mg, eg: float]]
        # Bonus for being the side to move
        tempo: float
        # Bonuses for rooks on open files
        rookOpenFile: tuple[mg, eg: float]
        # Bonuses for rooks on semi-open files
        rookSemiOpenFile: tuple[mg, eg: float]
        # PSQTs for passed pawns (2 per phase)
        passedPawnBonuses: array[Square(0)..Square(63), tuple[mg, eg: float]]
        # PSQTs for isolated pawns (2 per phase)
        isolatedPawnBonuses: array[Square(0)..Square(63), tuple[mg, eg: float]]
        # Mobility bonuses
        bishopMobility: array[14, tuple[mg, eg: float]]
        knightMobility: array[9, tuple[mg, eg: float]]
        rookMobility: array[15, tuple[mg, eg: float]]
        queenMobility: array[28, tuple[mg, eg: float]]
        virtualQueenMobility: array[28, tuple[mg, eg: float]]
        # King zone attacks
        kingZoneAttacks: array[9, tuple[mg, eg: float]]
        # Bonuses for having the bishop pair
        bishopPair: tuple[mg, eg: float]
        # Bonuses for strong pawns
        strongPawns: tuple[mg, eg: float]
        # Threats

        # Pawns attacking minor pieces
        pawnMinorThreats: tuple[mg, eg: float]
        # Pawns attacking major pieces
        pawnMajorThreats: tuple[mg, eg: float]
        # Minor pieces attacking major ones
        minorMajorThreats: tuple[mg, eg: float]
        # Rooks attacking queens
        rookQueenThreats: tuple[mg, eg: float]

        # Bonuses for safe checks to the
        # enemy king
        safeCheckBonuses*: array[PieceKind.Bishop..PieceKind.Rook, tuple[mg, eg: float]]

    EvalMode* = enum
        ## An enumeration of evaluation
        ## modes
        Default,   # Run the evaluation as normal
        Tune       # Run the evaluation in tuning mode:
                   # this turns the evaluation into a
                   # 1D feature vector to be used for
                   # tuning purposes


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

proc pieceToIndex(kind: PieceKind): int =
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

proc feature(perspective: PieceColor, color: PieceColor, piece: PieceKind, square: Square): int =
    let colorIndex = if perspective == color: 0 else: 1
    let pieceIndex = pieceToIndex(piece)
    let squareIndex = if perspective == PieceColor.White: int(square.flip()) else: int(square)

    var index = 0
    index = index * 2 + colorIndex
    index = index * 6 + pieceIndex
    index = index * 64 + squareIndex
    return index

proc evaluate*(position: Position, mode: static EvalMode = EvalMode.Default, features: Features = nil): Score =
    var whiteAcc: array[256, BitLinearWB]
    var blackAcc: array[256, BitLinearWB]

    NETWORK.ft.initAcc(whiteAcc)
    NETWORK.ft.initAcc(blackAcc)
    for sq in position.getOccupancy():
        let piece = position.getPiece(sq)
        NETWORK.ft.addFeature(feature(White, piece.color, piece.kind, sq), whiteAcc)
        NETWORK.ft.addFeature(feature(Black, piece.color, piece.kind, sq), blackAcc)

    var stmHalf: array[256, LinearI]
    var nstmHalf: array[256, LinearI]
    if position.sideToMove == White:
        crelu(whiteAcc, stmHalf)
        crelu(blackAcc, nstmHalf)
    else:
        crelu(blackAcc, stmHalf)
        crelu(whiteAcc, nstmHalf)

    var ftOut: array[512, LinearI]
    for i in 0..<256:
        ftOut[i] = stmHalf[i]
        ftOut[i + 256] = nstmHalf[i]

    var l1Out: array[1, LinearB]
    NETWORK.l1.forward(ftOut, l1Out)

    return l1Out[0] * 300 div 64 div 255

proc evaluate*(board: Chessboard, mode: static EvalMode = EvalMode.Default, features: Features = nil): Score {.inline.} =
    ## Evaluates the current position in the chessboard
    return board.positions[^1].evaluate(mode, features)
