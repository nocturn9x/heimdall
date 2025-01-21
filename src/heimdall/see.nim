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

## Implementation of Static Exchange Evaluation

import heimdall/position
import heimdall/pieces
import heimdall/board


const PIECE_SCORES: array[PieceKind.Pawn..PieceKind.Empty, int] = [100, 450, 450, 650, 1250, 0, 0]


func getStaticPieceScore*(kind: PieceKind): int =
    ## Returns a static score for the given piece
    ## type to be used inside SEE. This makes testing
    ## as well as general usage of SEE much more
    ## sane, because if SEE(move) == 0 then we know
    ## the capture sequence is balanced
    return PIECE_SCORES[kind]


func getStaticPieceScore*(piece: Piece): int {.inline.} =
    ## Returns a static score for the given piece
    ## to be used inside SEE. This makes testing
    ## as well as general usage of SEE much more
    ## sane, because if SEE(move) == 0 then we know
    ## the capture sequence is balanced
    return piece.kind.getStaticPieceScore()


func gain(position: Position, move: Move): int =
    ## Returns how much a single move gains in terms
    ## of static material value
    if move.isCastling():
        return 0
    if move.isEnPassant():
        return getStaticPieceScore(Pawn)

    result = getStaticPieceScore(position.getPiece(move.targetSquare))
    if move.isPromotion():
        result += getStaticPieceScore(move.getPromotionType().promotionToPiece()) - getStaticPieceScore(Pawn)


func popLeastValuable(position: Position, occupancy: var Bitboard, attackers: Bitboard, stm: PieceColor): PieceKind =
    ## Returns the piece type in the given position containing the lowest
    ## value victim in the given attackers bitboard
    for kind in PieceKind.all():
        let board = attackers and position.getBitboard(kind, stm)
        
        if board != 0:
            occupancy = occupancy xor board.lowestBit()
            return kind

    return PieceKind.Empty


proc see*(position: Position, move: Move, threshold: int): bool =
    ## Statically evaluates a sequence of exchanges
    ## starting from the given one and returns whether
    ## the exchange can beat the given (positive!) threshold.
    ## A sequence of moves leading to a losing capture (score < 0)
    ## will short-circuit and return false regardless of the value
    ## of the threshold
    
    # Yoinked from Stormphrax

    var score = gain(position, move) - threshold
    if score < 0:
        return false

    var next = if move.isPromotion(): move.getPromotionType().promotionToPiece() else: position.getPiece(move.startSquare).kind
    score -= next.getStaticPieceScore()

    if score >= 0:
        return true

    let 
        queens = position.getBitboard(Queen)
        bishops = queens or position.getBitboard(Bishop)
        rooks = queens or position.getBitboard(Rook)
    
    var
        occupancy = position.getOccupancy() xor move.startSquare.toBitboard() xor move.targetSquare.toBitboard()
        stm = position.sideToMove.opposite()
        attackers = position.getAttackersTo(move.targetSquare, occupancy)

    
    while true:
        let friendlyAttackers = attackers and position.getOccupancyFor(stm)

        if friendlyAttackers == 0:
            break
        
        next = position.popLeastValuable(occupancy, friendlyAttackers, stm)
        
        # Diagonal/orthogonal captures can add new diagonal/orthogonal attackers,
        # so handle this
        if next in [PieceKind.Pawn, PieceKind.Queen, PieceKind.Bishop]:
            attackers = attackers or (getBishopMoves(move.targetSquare, occupancy) and bishops)
        if next in [PieceKind.Rook, PieceKind.Queen]:
            attackers = attackers or (getRookMoves(move.targetSquare, occupancy) and rooks)
        
        attackers = attackers and occupancy

        score = -score - 1 - next.getStaticPieceScore()
        stm = stm.opposite()

        if score >= 0:
            if next == PieceKind.King and (attackers and position.getOccupancyFor(stm)) != 0:
                # Can't capture with the king if the other side has defenders on the
                # target square
                stm = stm.opposite()
            # We beat the threshold, hooray!
            break

    return position.sideToMove != stm