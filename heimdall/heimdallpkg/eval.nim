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


proc getMobility(position: Position, square: Square, moves: Bitboard, exclude: Bitboard): Bitboard =
    ## Returns the bitboard of moves a piece can make as far as our mobility
    ## calculation is concerned, starting from the given bitboard of attacking
    ## moves for the piece on the given square. This doesn't necessarily return
    ## legal moves of a piece (for example, queens may be allowed to X-ray through
    ## friendly bishops or rooks, or even other queens)
    let piece = position.getPiece(square)
    result = moves
    # We don't mask anything off when computing virtual queen
    # mobility because it is a representation of the potential
    # attack vectors of the opponent rather than a measure of 
    # how much a piece can/should move
    if piece.kind != King and result != 0:
        # Mask off friendly pieces
        result = result and not position.getOccupancyFor(piece.color)
        # Mask off any excluded squares (i.e. ones attacked by pawns)
        result = result and not exclude
        # TODO: Take pins into account
        # TODO: Allow X-rays


proc getAttackingMoves(position: Position, square: Square, piece: Piece = nullPiece()): Bitboard =
    ## Returns the bitboard of possible attacks from the
    ## piece on the given square. If a piece is provided
    ## then we pretend that the piece on the square is the
    ## given one rather than the one that's already there
    var piece = piece
    if piece == nullPiece():
        piece = position.getPiece(square)
    case piece.kind:
        of King:
            return getKingAttacks(square)
        of Knight:
            return getKnightAttacks(square)
        of Queen, Rook, Bishop:
            let occupancy = position.getOccupancy()
            if piece.kind in [Rook, Queen]:
                result = getRookMoves(square, occupancy)
            if piece.kind in [Bishop, Queen]:
                result = result or getBishopMoves(square, occupancy)
        of Pawn:
            return getPawnAttacks(piece.color, square)
        else:
            discard


proc evaluate*(position: Position, mode: static EvalMode = EvalMode.Default, features: Features = nil): Score =
    ## Evaluates the current position
    when mode == Tune:
        doAssert not features.isNil()

    let 
        sideToMove = position.sideToMove
        nonSideToMove = sideToMove.opposite()
        middleGamePhase = position.getGamePhase()
        endGamePhase = 24 - middleGamePhase
        scaledMiddleGame = middleGamePhase / 24
        scaledEndGame = endGamePhase / 24
        occupancy = position.getOccupancy()
        kings: array[PieceColor.White..PieceColor.Black, Bitboard] = [position.getBitboard(King, White), position.getBitboard(King, Black)]
        pawns: array[PieceColor.White..PieceColor.Black, Bitboard] = [position.getBitboard(Pawn, White), position.getBitboard(Pawn, Black)]
        rooks: array[PieceColor.White..PieceColor.Black, Bitboard] = [position.getBitboard(Rook, White), position.getBitboard(Rook, Black)]
        queens: array[PieceColor.White..PieceColor.Black, Bitboard] = [position.getBitboard(Queen, White), position.getBitboard(Queen, Black)]
        bishops: array[PieceColor.White..PieceColor.Black, Bitboard] = [position.getBitboard(Bishop, White), position.getBitboard(Bishop, Black)]
        knights: array[PieceColor.White..PieceColor.Black, Bitboard] = [position.getBitboard(Knight, White), position.getBitboard(Knight, Black)]
        majors: array[PieceColor.White..PieceColor.Black, Bitboard] = [queens[White] or rooks[White], queens[Black] or rooks[Black]]
        minors: array[PieceColor.White..PieceColor.Black, Bitboard] = [bishops[White] or knights[White], bishops[Black] or knights[Black]]
        kingZones: array[PieceColor.White..PieceColor.Black, Bitboard] = [getKingZoneMask(White, position.getBitboard(King, White).toSquare()),
                                                                          getKingZoneMask(Black, position.getBitboard(King, Black).toSquare())]
        allPawns = pawns[White] or pawns[Black]
        pawnAttacks: array[PieceColor.White..PieceColor.Black, Bitboard] = [pawns[White].forwardLeftRelativeTo(White) or pawns[White].forwardRightRelativeTo(White),
                                                                            pawns[Black].forwardLeftRelativeTo(Black) or pawns[Black].forwardRightRelativeTo(Black)]

    var
        pieceAttacks: array[PieceColor.White..PieceColor.Black, array[PieceKind.Bishop..PieceKind.Rook, Bitboard]]
        attackedBy: array[PieceColor.White..PieceColor.Black, Bitboard]
        evalScores: array[PieceColor.White..PieceColor.Black, Score] = [0, 0]
        kingAttackers: array[PieceColor.White..PieceColor.Black, int] = [0, 0]

    # Material, position, threat and mobility evaluation
    for sq in occupancy:
        let piece = position.getPiece(sq)
        let enemyColor = piece.color.opposite()
        let attackingMoves = position.getAttackingMoves(sq)
        attackedBy[piece.color] = attackedBy[piece.color] or attackingMoves
        pieceAttacks[piece.color][piece.kind] = pieceAttacks[piece.color][piece.kind] or attackingMoves
        let attacksOnMinors = (attackingMoves and minors[enemyColor]).countSquares()
        let attacksOnMajors = (attackingMoves and majors[enemyColor]).countSquares()
        let attacksOnQueens = (attackingMoves and queens[enemyColor]).countSquares()
        kingAttackers[enemyColor] += (attackingMoves and kingZones[enemyColor]).countSquares()
        var mobilityMoves: int
        if piece.kind != King:
            mobilityMoves = position.getMobility(sq, attackingMoves, pawnAttacks[enemyColor]).countSquares()
        else:
            # We calculate a virtual mobility for the king as if it were a queen (for king safety)
            mobilityMoves = position.getMobility(sq, position.getAttackingMoves(sq, Piece(kind: Queen, color: piece.color)), pawnAttacks[enemyColor]).countSquares()
        when mode == Default:
            evalScores[piece.color] += PIECE_SQUARE_TABLES[piece.color][piece.kind][sq]
            evalScores[piece.color] += piece.kind.getMobilityBonus(mobilityMoves)
            case piece.kind:
                of Bishop, Knight:
                    evalScores[piece.color] += MINOR_THREATS_MAJOR_WEIGHT * Score(attacksOnMajors)
                of Pawn:
                    evalScores[piece.color] += PAWN_THREATS_MAJOR_WEIGHT * Score(attacksOnMajors)
                    evalScores[piece.color] += PAWN_THREATS_MINOR_WEIGHT * Score(attacksOnMinors)
                of Rook:
                    evalScores[piece.color] += ROOK_THREATS_QUEEN_WEIGHT * Score(attacksOnQueens)
                else:
                    discard
        else:
            # The target square for the piece square tables depends on
            # color, so we flip it for black
            let square = if piece.color == Black: sq.flip() else: sq
            let side = if piece.color == Black: -1.0 else: 1.0
            # PSQTs
            features.psqts[piece.kind][square].mg += scaledMiddleGame * side
            features.psqts[piece.kind][square].eg += scaledEndGame * side
            features.pieceWeights[piece.kind].mg += scaledMiddleGame * side
            features.pieceWeights[piece.kind].eg += scaledEndGame * side
            # Mobility and threats
            case piece.kind:
                of Bishop:
                    features.bishopMobility[mobilityMoves].mg += scaledMiddleGame * side
                    features.bishopMobility[mobilityMoves].eg += scaledEndGame * side
                    features.minorMajorThreats.mg += side * attacksOnMajors.float * scaledMiddleGame
                    features.minorMajorThreats.eg += side * attacksOnMajors.float * scaledEndGame
                of Knight:
                    features.knightMobility[mobilityMoves].mg += scaledMiddleGame * side
                    features.knightMobility[mobilityMoves].eg += scaledEndGame * side
                    features.minorMajorThreats.mg += side * attacksOnMajors.float * scaledMiddleGame
                    features.minorMajorThreats.eg += side * attacksOnMajors.float * scaledEndGame
                of Rook:
                    features.rookMobility[mobilityMoves].mg += scaledMiddleGame * side
                    features.rookMobility[mobilityMoves].eg += scaledEndGame * side
                    features.rookQueenThreats.mg += side * attacksOnQueens.float * scaledMiddleGame
                    features.rookQueenThreats.eg += side * attacksOnQueens.float * scaledEndGame
                of Queen:
                    features.queenMobility[mobilityMoves].mg += scaledMiddleGame * side
                    features.queenMobility[mobilityMoves].eg += scaledEndGame * side
                of King:
                    features.virtualQueenMobility[mobilityMoves].mg += scaledMiddleGame * side
                    features.virtualQueenMobility[mobilityMoves].eg += scaledEndGame * side
                of Pawn:
                    features.pawnMinorThreats.mg += side * attacksOnMinors.float * scaledMiddleGame
                    features.pawnMinorThreats.eg += side * attacksOnMinors.float * scaledEndGame
                    features.pawnMajorThreats.mg += side * attacksOnMajors.float * scaledMiddleGame
                    features.pawnMajorThreats.eg += side * attacksOnMajors.float * scaledEndGame
                else:
                    discard

    for color in PieceColor.White..PieceColor.Black:
        let side = if color == Black: -1.0 else: 1.0
        let enemyColor = color.opposite()

        # Safe checks
        for piece in PieceKind.Bishop..PieceKind.Rook:
            # Superpiece method: to find out which friendly
            # piece of a given type is attacking the enemy king,
            # we just place a virtual piece of that type where
            # the king is located and `and` the set of moves of
            # this virtual piece with the set of attacks we computed
            # during mobility calculations. We also mask off squares
            # attacked by the opponent for safety reasons (TODO: look
            # into checking for defended squares)
            let relevantAttacks = position.getAttackingMoves(kings[enemyColor].toSquare(),
                                                             Piece(kind: piece, color: color)) and pieceAttacks[color][piece] and not attackedBy[enemyColor]

            when mode == Tune:
                let numChecks = relevantAttacks.countSquares().float
                features.safeCheckBonuses[piece].mg += side * numChecks * scaledMiddleGame
                features.safeCheckBonuses[piece].eg += side * numChecks * scaledEndGame
            else:
                let numChecks = Score(relevantAttacks.countSquares())
                let weights = SAFE_CHECK_WEIGHT[piece]
                evalScores[color] += weights * numChecks
        # Bishop pair

        # We only count positions with exactly two bishops because
        # giving a bonus to a position with an underpromotion to a 
        # bishop seems silly. Also, we don't actually check that the
        # bishops are on different colored squares because having two
        # same colored bishops is quite rare and checking that would
        # be needlessly expensive for the vast majority of cases
        let bishopPair = bishops[color].countSquares() == 2
        when mode == Default:
            if bishopPair:
                evalScores[color] += BISHOP_PAIR_WEIGHT
        else:
            if bishopPair:
                features.bishopPair.mg += side * scaledMiddleGame
                features.bishopPair.eg += side * scaledEndGame

        # King zone attacks
        
        # We clamp the number of attacks we count in the king zone, for our own sanity
        let attacked = clamp(kingAttackers[color], 0, features.kingZoneAttacks.high())
        when mode == Default:
            evalScores[color] += KING_ZONE_ATTACKS_WEIGHT[attacked]
        else:
            features.kingZoneAttacks[attacked].mg += scaledMiddleGame * side
            features.kingZoneAttacks[attacked].eg += scaledEndGame * side

        # Pawn structure

        # Strong pawns
        let strongPawns = ((pawns[color].forwardLeftRelativeTo(color) or pawns[color].forwardRightRelativeTo(color)) and pawns[color]).countSquares()
        when mode == Default:
            evalScores[color] += STRONG_PAWNS_WEIGHT * Score(strongPawns)
        else:
            features.strongPawns.mg += strongPawns.float * side * scaledMiddleGame
            features.strongPawns.eg += strongPawns.float * side * scaledEndGame

        for pawn in pawns[color]:
            let square = if color == Black: pawn.flip() else: pawn

            # Passed pawns
            if (getPassedPawnMask(color, pawn) and pawns[color.opposite()]) == 0:
                when mode == Default:
                    evalScores[color] += PASSED_PAWN_TABLE[color][pawn]
                else:
                    features.passedPawnBonuses[square].mg += scaledMiddleGame * side
                    features.passedPawnBonuses[square].eg += scaledEndGame * side

            # Isolated pawns
            if (pawns[color] and getIsolatedPawnMask(fileFromSquare(pawn))) == 0:
                when mode == Default:
                    evalScores[color] += ISOLATED_PAWN_TABLE[color][pawn]
                else:
                    features.isolatedPawnBonuses[square].mg += scaledMiddleGame * side
                    features.isolatedPawnBonuses[square].eg += scaledEndGame * side
        
        for file in 0..7:
            let fileMask = getFileMask(file)
            let friendlyPawnsOnFile = pawns[color] and fileMask

            # Rooks on (semi-)open files

            if (fileMask and allPawns).countSquares() == 0:
                # Open file (no pawns in the way)
                for rook in rooks[color] and fileMask:
                    when mode == Default:
                        evalScores[color] += ROOK_OPEN_FILE_WEIGHT
                    else:
                        let piece = position.getPiece(rook)
                        let side = if piece.color == Black: -1.0 else: 1.0
                        features.rookOpenFile.mg += scaledMiddleGame * side
                        features.rookOpenFile.eg += scaledEndGame * side

            if friendlyPawnsOnFile == 0 and (fileMask and pawns[color.opposite()]).countSquares() == 1:
                # Semi-open file (no friendly pawns and only one enemy pawn in the way). We
                # deviate from the traditional definition of semi-open file (where any number
                # of enemy pawns greater than zero is okay), because it's more likely that a
                # position where a rook/queen can capture the only enemy pawn on the file and
                # open it are good as opposed to there being 2 or more pawns (which would keep
                # the file semi-open even after a capture). Maybe we can investigate different
                # definitions and see what works and what doesn't
                for rook in rooks[color] and fileMask:
                    when mode == Default:
                        evalScores[color] += ROOK_SEMI_OPEN_FILE_WEIGHT
                    else:
                        let piece = position.getPiece(rook)
                        let side = if piece.color == Black: -1.0 else: 1.0
                        features.rookSemiOpenFile.mg += scaledMiddleGame * side
                        features.rookSemiOpenFile.eg += scaledEndGame * side

    # Final score computation. We interpolate between middle and endgame scores
    # according to how many pieces are left on the board
    let finalScore = evalScores[sideToMove] - evalScores[nonSideToMove]
    result = Score((finalScore.mg() * middleGamePhase + finalScore.eg() * endGamePhase) div 24)

    when mode == Default:
        # Tempo bonus: gains 19.5 +/- 13.7
        result += TEMPO_WEIGHT
    else:
        features.tempo = 1.0


proc evaluate*(board: Chessboard, mode: static EvalMode = EvalMode.Default, features: Features = nil): Score {.inline.} =
    ## Evaluates the current position in the chessboard
    return board.positions[^1].evaluate(mode, features)
    

func featureCount*(self: Features): int {.exportpy.} =
    ## Returns the number of features in
    ## the evaluation
    
    # One weight for tempo
    result = 1
    # Two PSTQs for each piece in each game phase
    result += len(self.psqts[PieceKind.Bishop]) * len(self.psqts) * 2
    # Two sets of piece weights for each game phase
    result += len(self.pieceWeights) * 2
    # Two weights for rooks on open files
    result += 2
    # Two weights for rooks on semi-open files
    result += 2
    # Weights for our passed pawn bonuses (one for
    # each game phase)
    result += len(self.passedPawnBonuses) * 2
    # Weights for our isolated pawn bonuses (one for
    # each game phase)
    result += len(self.isolatedPawnBonuses) * 2
    # Weights for piece mobility (one set per phase)
    result += len(self.bishopMobility) * 2
    result += len(self.knightMobility) * 2
    result += len(self.rookMobility) * 2
    result += len(self.queenMobility) * 2
    result += len(self.virtualQueenMobility) * 2
    # Weights for king zone attacks
    result += len(self.kingZoneAttacks) * 2
    # Flat bonuses for the bishop pair and strong pawns
    result += 4
    # Flat bonuses for threats
    result += 8
    # Flat bonuses for safe checks: note that while the
    # safeCheckBonuses array encompasses pawns and kings,
    # we don't actually use those slots and so training
    # them is useless
    result += 8


proc reset(self: Features) =
    ## Resets the feature metadata
    for kind in PieceKind.Bishop..PieceKind.Rook:
        self.pieceWeights[kind] = (0, 0)
        self.safeCheckBonuses[kind] = (0, 0)
        for square in Square(0)..Square(63):
            self.psqts[kind][square] = (0, 0)
    self.tempo = 0
    self.rookOpenFile = (0, 0)
    self.rookSemiOpenFile = (0, 0)
    for square in Square(0)..Square(63):
        self.passedPawnBonuses[square] = (0, 0)
        self.isolatedPawnBonuses[square] = (0, 0)
    for i in 0..self.bishopMobility.high():
        self.bishopMobility[i] = (0, 0)
    for i in 0..self.knightMobility.high():
        self.knightMobility[i] = (0, 0)
    for i in 0..self.rookMobility.high():
        self.rookMobility[i] = (0, 0)
    for i in 0..self.queenMobility.high():
        self.queenMobility[i] = (0, 0)
    for i in 0..self.virtualQueenMobility.high():
        self.virtualQueenMobility[i] = (0, 0)
    for i in 0..self.kingZoneAttacks.high():
        self.kingZoneAttacks[i] = (0, 0)
    self.bishopPair = (0, 0)
    self.strongPawns = (0, 0)
    self.pawnMajorThreats = (0, 0)
    self.pawnMinorThreats = (0, 0)
    self.minorMajorThreats = (0, 0)
    self.rookQueenThreats = (0, 0)


proc extract*(self: Features, fen: string): Tensor[float] =
    ## Extracts the features of the evaluation
    ## into a 1-D column vector to be used for
    ## tuning purposes
    
    # In order to avoid messing our tuning by carrying
    # over data from previously analyzed positions, we
    # zero the metadata at every call to extract
    self.reset()
    var position = loadFEN(fen)
    result = newTensor[float](1, self.featureCount())
    discard position.evaluate(EvalMode.Tune, self)
    for kind in PieceKind.Bishop..PieceKind.Rook:
        for square in Square(0)..Square(63):
            var idx = kind.int * len(self.psqts[kind]) + square.int
            # All middle-game weights come first, then all engdame ones
            result[0, idx] = self.psqts[kind][square].mg
            # Skip to the corresponding endgame entry
            idx += 64 * 6
            result[0, idx] = self.psqts[kind][square].eg

    # Skip the piece-square tables
    var offset = 64 * 6 * 2
    for kind in PieceKind.Bishop..PieceKind.Rook:
        var idx = offset + kind.int
        result[0, idx] = self.pieceWeights[kind].mg
        # Skip to the corresponding end-game piece weight entry
        idx += 6
        result[0, idx] = self.pieceWeights[kind].eg
    offset += 12
    # Bonuses for rooks on (semi-)open files
    result[0, offset] = self.rookOpenFile.mg
    result[0, offset + 1] = self.rookOpenFile.eg
    result[0, offset + 2] = self.rookSemiOpenFile.mg
    result[0, offset + 3] = self.rookSemiOpenFile.eg
    offset += 4
    # Bonuses for passed pawns
    for square in Square(0)..Square(63):
        var idx = square.int + offset
        result[0, idx] = self.passedPawnBonuses[square].mg
        idx += 64
        result[0, idx] = self.passedPawnBonuses[square].eg
    offset += 128
    # "Bonuses" for isolated pawns
    for square in Square(0)..Square(63):
        var idx = square.int + offset
        result[0, idx] = self.isolatedPawnBonuses[square].mg
        idx += 64
        result[0, idx] = self.isolatedPawnBonuses[square].eg
    offset += 128
    # Mobility bonuses

    # Bishops
    for i in 0..self.bishopMobility.high():
        let idx = offset + i * 2
        result[0, idx] = self.bishopMobility[i].mg
        result[0, idx + 1] = self.bishopMobility[i].eg

    offset += len(self.bishopMobility) * 2

    # Knights
    for i in 0..self.knightMobility.high():
        let idx = offset + i * 2
        result[0, idx] = self.knightMobility[i].mg
        result[0, idx + 1] = self.knightMobility[i].eg

    offset += len(self.knightMobility) * 2
    
    # Rooks
    for i in 0..self.rookMobility.high():
        let idx = offset + i * 2
        result[0, idx] = self.rookMobility[i].mg
        result[0, idx + 1] = self.rookMobility[i].eg
    
    offset += len(self.rookMobility) * 2
    
    # Queens
    for i in 0..self.queenMobility.high():
        let idx = offset + i * 2
        result[0, idx] = self.queenMobility[i].mg
        result[0, idx + 1] = self.queenMobility[i].eg
    
    offset += len(self.queenMobility) * 2

    # King
    for i in 0..self.virtualQueenMobility.high():
        let idx = offset + i * 2
        result[0, idx] = self.virtualQueenMobility[i].mg
        result[0, idx + 1] = self.virtualQueenMobility[i].eg
    
    offset += len(self.virtualQueenMobility) * 2
    
    # King zone attacks
    for i in 0..self.kingZoneAttacks.high():
        let idx = offset + i * 2
        result[0, idx] = self.kingZoneAttacks[i].mg
        result[0, idx + 1] = self.kingZoneAttacks[i].eg
    
    offset += len(self.kingZoneAttacks) * 2

    # Bishop pair bonuses

    result[0, offset] = self.bishopPair.mg
    result[0, offset + 1] = self.bishopPair.eg

    offset += 2

    # Strong pawn bonuses
    result[0, offset] = self.strongPawns.mg
    result[0, offset + 1] = self.strongPawns.eg

    offset += 2

    # Threats

    result[0, offset] = self.pawnMinorThreats.mg
    result[0, offset + 1] = self.pawnMinorThreats.eg

    offset += 2

    result[0, offset] = self.pawnMajorThreats.mg
    result[0, offset + 1] = self.pawnMajorThreats.eg

    offset += 2

    result[0, offset] = self.minorMajorThreats.mg
    result[0, offset + 1] = self.minorMajorThreats.eg

    offset += 2

    result[0, offset] = self.rookQueenThreats.mg
    result[0, offset + 1] = self.rookQueenThreats.eg

    offset += 2

    # Safe checks

    result[0, offset] = self.safeCheckBonuses[Bishop].mg
    result[0, offset + 1] = self.safeCheckBonuses[Bishop].mg

    offset += 2

    result[0, offset] = self.safeCheckBonuses[Knight].mg
    result[0, offset + 1] = self.safeCheckBonuses[Knight].mg

    offset += 2

    result[0, offset] = self.safeCheckBonuses[Rook].mg
    result[0, offset + 1] = self.safeCheckBonuses[Rook].mg

    offset += 2

    result[0, offset] = self.safeCheckBonuses[Queen].mg
    result[0, offset + 1] = self.safeCheckBonuses[Queen].mg

    offset += 2

    # Tempo is always last in the feature vector
    result[0, ^1] = self.tempo


proc extractFeatures*(self: Features, fen: string): auto {.exportpy.} =
    ## Version of extract() exported to Python that returns
    ## a numpy array
    result = self.extract(fen).toNdArray()
