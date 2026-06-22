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

## Hand-crafted position evaluation utilities.
##
## This is the fixed HCE from the ancient hceimdall branch, adapted to the
## current engine API. Tuning support was intentionally left behind.

import heimdall/[board, hce_weights, moves, pieces, position]
import heimdall/util/memory/thp/alloc


type
    Score* = int32

    EvalStateObj = object
        unused: uint8

    EvalState* = ptr EvalStateObj
        ## Compatibility handle for the current search code. The HCE is
        ## stateless, so incremental accumulator operations are no-ops.

    EvalStateOwner* = HugePtr[EvalStateObj]


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
const EVAL_SCALE* {.define: "evalScale".} = 322


proc newEvalState*(networkPath: string = "", verbose: static bool = true): EvalStateOwner =
    discard networkPath
    when verbose:
        discard
    result = allocHugePage[EvalStateObj](zero = true)


proc clone*(self: EvalState, board: Chessboard): EvalStateOwner =
    discard self
    discard board
    result = allocHugePage[EvalStateObj](zero = true)


func init*(self: EvalState, board: Chessboard) {.inline.} =
    discard self
    discard board


func update*(self: EvalState, move: Move, sideToMove: PieceColor, piece, captured: PieceKind, kingSq: Square) {.inline.} =
    discard self
    discard move
    discard sideToMove
    discard piece
    discard captured
    discard kingSq


func undo*(self: EvalState) {.inline.} =
    discard self


func fileMask(file: int): Bitboard {.inline.} =
    fileMask(pieces.File(file))


func rankMask(rank: int): Bitboard {.inline.} =
    rankMask(Rank(rank))


func passedPawnMask(color: PieceColor, square: Square): Bitboard =
    let
        file = file(square).int
        rank = rank(square).int

    result = fileMask(file)
    if file + 1 in 0..7:
        result = result or fileMask(file + 1)
    if file - 1 in 0..7:
        result = result or fileMask(file - 1)

    if color == White:
        result = result shr (8 * (7 - rank))
    else:
        result = result shl (8 * rank)

    result = result and not rankMask(0)
    result = result and not rankMask(7)


func isolatedPawnMask(file: int): Bitboard =
    if file - 1 in 0..7:
        result = result or fileMask(file - 1)
    if file + 1 in 0..7:
        result = result or fileMask(file + 1)
    result = result and not rankMask(0)
    result = result and not rankMask(7)


func kingZoneMask(color: PieceColor, square: Square): Bitboard =
    let squareBB = square.toBitboard()
    result = squareBB.forward(color) or squareBB.forwardLeft(color) or squareBB.forwardRight(color)
    result = result or squareBB.backward(color) or squareBB.backwardLeft(color) or squareBB.backwardRight(color)
    result = result or squareBB.left(color) or squareBB.right(color)


func pawnAttackLookup(color: PieceColor, square: Square): Bitboard {.inline.} =
    ## Preserves the hceimdall helper's historical behavior: the per-square pawn
    ## lookup returns backward attacks, while aggregate pawn attacks below use
    ## forward shifts.
    let pawn = square.toBitboard()
    result = pawn.backwardLeft(color) or pawn.backwardRight(color)


func getGamePhase(position: Position): int {.inline.} =
    ## Computes the game phase according to
    ## how many pieces are left on the board
    result = 0
    for sq in position.pieces():
        case position.on(sq).kind:
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
        piece = position.on(square)
        scores = PIECE_SQUARE_TABLES[piece.color][piece.kind][square]
        middleGamePhase = position.getGamePhase()
        endGamePhase = 24 - middleGamePhase

    result = Score((scores.mg() * middleGamePhase + scores.eg() * endGamePhase) div 24)


proc getPieceScore*(position: Position, piece: Piece, square: Square): Score =
    ## Returns the value the given piece would have if it
    ## were at the given square given the current game phase
    let
        scores = PIECE_SQUARE_TABLES[piece.color][piece.kind][square]
        middleGamePhase = position.getGamePhase()
        endGamePhase = 24 - middleGamePhase

    result = Score((scores.mg() * middleGamePhase + scores.eg() * endGamePhase) div 24)


proc getMobility(position: Position, square: Square, moves: Bitboard, exclude: Bitboard): Bitboard =
    ## Returns the bitboard of moves a piece can make as far as our mobility
    ## calculation is concerned, starting from the given bitboard of attacking
    ## moves for the piece on the given square. This doesn't necessarily return
    ## legal moves of a piece.
    let piece = position.on(square)
    result = moves
    # We don't mask anything off when computing virtual queen
    # mobility because it is a representation of the potential
    # attack vectors of the opponent rather than a measure of
    # how much a piece can/should move
    if piece.kind != King and not result.isEmpty():
        # Mask off friendly pieces
        result = result and not position.pieces(piece.color)
        # Mask off any excluded squares (i.e. ones attacked by pawns)
        result = result and not exclude


proc getAttackingMoves(position: Position, square: Square, piece: Piece = nullPiece()): Bitboard =
    ## Returns the bitboard of possible attacks from the
    ## piece on the given square. If a piece is provided
    ## then we pretend that the piece on the square is the
    ## given one rather than the one that's already there.
    var piece = piece
    if piece == nullPiece():
        piece = position.on(square)
    case piece.kind:
        of King:
            return kingMoves(square)
        of Knight:
            return knightMoves(square)
        of Queen, Rook, Bishop:
            let occupancy = position.pieces()
            if piece.kind in [Rook, Queen]:
                result = rookMoves(square, occupancy)
            if piece.kind in [Bishop, Queen]:
                result = result or bishopMoves(square, occupancy)
        of Pawn:
            return pawnAttackLookup(piece.color, square)
        else:
            discard


proc evaluate*(position: Position): Score =
    ## Evaluates the current position
    let
        sideToMove = position.sideToMove
        nonSideToMove = sideToMove.opposite()
        middleGamePhase = position.getGamePhase()
        endGamePhase = 24 - middleGamePhase
        occupancy = position.pieces()
        kings: array[White..Black, Bitboard] = [position.pieces(King, White), position.pieces(King, Black)]
        pawns: array[White..Black, Bitboard] = [position.pieces(Pawn, White), position.pieces(Pawn, Black)]
        rooks: array[White..Black, Bitboard] = [position.pieces(Rook, White), position.pieces(Rook, Black)]
        queens: array[White..Black, Bitboard] = [position.pieces(Queen, White), position.pieces(Queen, Black)]
        bishops: array[White..Black, Bitboard] = [position.pieces(Bishop, White), position.pieces(Bishop, Black)]
        knights: array[White..Black, Bitboard] = [position.pieces(Knight, White), position.pieces(Knight, Black)]
        majors: array[White..Black, Bitboard] = [queens[White] or rooks[White], queens[Black] or rooks[Black]]
        minors: array[White..Black, Bitboard] = [bishops[White] or knights[White], bishops[Black] or knights[Black]]
        kingZones: array[White..Black, Bitboard] = [kingZoneMask(White, kings[White].toSquare()),
                                                    kingZoneMask(Black, kings[Black].toSquare())]
        allPawns = pawns[White] or pawns[Black]
        pawnAttacks: array[White..Black, Bitboard] = [pawns[White].forwardLeft(White) or pawns[White].forwardRight(White),
                                                      pawns[Black].forwardLeft(Black) or pawns[Black].forwardRight(Black)]

    var
        pieceAttacks: array[White..Black, array[Pawn..King, Bitboard]]
        attackedBy: array[White..Black, Bitboard]
        evalScores: array[White..Black, Score] = [0, 0]
        kingAttackers: array[White..Black, int] = [0, 0]

    # Material, position, threat and mobility evaluation
    for sq in occupancy:
        let piece = position.on(sq)
        let enemyColor = piece.color.opposite()
        let attackingMoves = position.getAttackingMoves(sq)
        attackedBy[piece.color] = attackedBy[piece.color] or attackingMoves
        pieceAttacks[piece.color][piece.kind] = pieceAttacks[piece.color][piece.kind] or attackingMoves
        let attacksOnMinors = (attackingMoves and minors[enemyColor]).count()
        let attacksOnMajors = (attackingMoves and majors[enemyColor]).count()
        let attacksOnQueens = (attackingMoves and queens[enemyColor]).count()
        kingAttackers[enemyColor] += (attackingMoves and kingZones[enemyColor]).count()
        var mobilityMoves: int
        if piece.kind != King:
            mobilityMoves = position.getMobility(sq, attackingMoves, pawnAttacks[enemyColor]).count()
        else:
            # We calculate a virtual mobility for the king as if it were a queen (for king safety)
            mobilityMoves = position.getMobility(sq, position.getAttackingMoves(sq, Piece(kind: Queen, color: piece.color)), pawnAttacks[enemyColor]).count()
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

    for color in White..Black:
        let enemyColor = color.opposite()

        # Safe checks
        for piece in Pawn..King:
            # Superpiece method: to find out which friendly
            # piece of a given type is attacking the enemy king,
            # we just place a virtual piece of that type where
            # the king is located and `and` the set of moves of
            # this virtual piece with the set of attacks we computed
            # during mobility calculations. We also mask off squares
            # attacked by the opponent for safety reasons.
            let relevantAttacks = position.getAttackingMoves(kings[enemyColor].toSquare(),
                                                             Piece(kind: piece, color: color)) and pieceAttacks[color][piece] and not attackedBy[enemyColor]
            let numChecks = Score(relevantAttacks.count())
            let weights = SAFE_CHECK_WEIGHT[piece]
            evalScores[color] += weights * numChecks

        # Bishop pair
        #
        # We only count positions with exactly two bishops because
        # giving a bonus to a position with an underpromotion to a
        # bishop seems silly.
        if bishops[color].count() == 2:
            evalScores[color] += BISHOP_PAIR_WEIGHT

        # King zone attacks
        let attacked = max(0, min(kingAttackers[color], KING_ZONE_ATTACKS_WEIGHT.high()))
        evalScores[color] += KING_ZONE_ATTACKS_WEIGHT[attacked]

        # Pawn structure

        # Strong pawns
        let strongPawns = ((pawns[color].forwardLeft(color) or pawns[color].forwardRight(color)) and pawns[color]).count()
        evalScores[color] += STRONG_PAWNS_WEIGHT * Score(strongPawns)

        for pawn in pawns[color]:
            # Passed pawns
            if (passedPawnMask(color, pawn) and pawns[color.opposite()]).isEmpty():
                evalScores[color] += PASSED_PAWN_TABLE[color][pawn]

            # Isolated pawns
            if (pawns[color] and isolatedPawnMask(file(pawn).int)).isEmpty():
                evalScores[color] += ISOLATED_PAWN_TABLE[color][pawn]

        for file in 0..7:
            let fileMask = fileMask(file)
            let friendlyPawnsOnFile = pawns[color] and fileMask

            # Rooks on open files
            if (fileMask and allPawns).isEmpty():
                for rook in rooks[color] and fileMask:
                    discard rook
                    evalScores[color] += ROOK_OPEN_FILE_WEIGHT

            # Rooks on semi-open files
            if friendlyPawnsOnFile.isEmpty() and (fileMask and pawns[color.opposite()]).count() == 1:
                for rook in rooks[color] and fileMask:
                    discard rook
                    evalScores[color] += ROOK_SEMI_OPEN_FILE_WEIGHT

    # Final score computation. We interpolate between middle and endgame scores
    # according to how many pieces are left on the board
    let finalScore = evalScores[sideToMove] - evalScores[nonSideToMove]
    result = Score((finalScore.mg() * middleGamePhase + finalScore.eg() * endGamePhase) div 24)

    # Tempo bonus
    result += TEMPO_WEIGHT


proc evaluate*(position: Position, state: EvalState): Score {.inline.} =
    discard state
    return position.evaluate()


proc evaluate*(board: Chessboard, state: EvalState): Score {.inline.} =
    return board.position.evaluate(state)
