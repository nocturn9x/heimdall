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

## Implementation of Static Exchange Evaluation

import heimdall/[pieces, board, position]
import heimdall/util/tunables


func gain(parameters: SearchParameters, position: Position, move: Move): int =
    ## Returns how much a single move gains in terms
    ## of static material value
    if move.isCastling():
        return 0
    if move.isEnPassant():
        return parameters.getStaticPieceScore(Pawn)

    result = parameters.getStaticPieceScore(position.on(move.targetSquare))
    if move.isPromotion():
        result += parameters.getStaticPieceScore(move.flag().promotionToPiece()) - parameters.getStaticPieceScore(Pawn)


func popLeastValuable(position: Position, occupancy: var Bitboard, attackers: Bitboard, stm: PieceColor): PieceKind =
    ## Pops the piece type of the lowest value victim off
    ## the given attackers bitboard
    for kind in PieceKind.all():
        let board = attackers and position.pieces(kind, stm)

        if not board.isEmpty():
            occupancy = occupancy xor board.lowestBit()
            return kind

    return Empty


proc see*(parameters: SearchParameters, position: Position, move: Move, threshold: int): bool =
    ## Statically evaluates a sequence of exchanges
    ## starting from the given one and returns whether
    ## the exchange can beat the given threshold.
    ## A sequence of moves leading to a losing capture
    ## (score < 0) will short-circuit and return false
    ## regardless of the value of the threshold

    # Yoinked from Stormphrax

    var score = gain(parameters, position, move) - threshold
    if score < 0:
        return false

    var next = if move.isPromotion(): move.flag().promotionToPiece() else: position.on(move.startSquare).kind
    score -= parameters.getStaticPieceScore(next)

    if score >= 0:
        return true

    let
        queens = position.pieces(Queen)
        bishops = queens or position.pieces(Bishop)
        rooks = queens or position.pieces(Rook)

    var
        occupancy = position.pieces() xor move.startSquare.toBitboard() xor move.targetSquare.toBitboard()
        stm = position.sideToMove.opposite()
        attackers = position.attackers(move.targetSquare, occupancy)


    while true:
        let friendlyAttackers = attackers and position.pieces(stm)

        if friendlyAttackers.isEmpty():
            break

        next = position.popLeastValuable(occupancy, friendlyAttackers, stm)

        # Diagonal/orthogonal captures can add new diagonal/orthogonal attackers,
        # so handle this
        if next in [Pawn, Queen, Bishop]:
            attackers = attackers or (bishopMoves(move.targetSquare, occupancy) and bishops)
        if next in [Rook, Queen]:
            attackers = attackers or (rookMoves(move.targetSquare, occupancy) and rooks)

        attackers = attackers and occupancy

        score = -score - 1 - parameters.getStaticPieceScore(next)
        stm = stm.opposite()

        if score >= 0:
            if next == King and not (attackers and position.pieces(stm)).isEmpty():
                # Can't capture with the king if the other side has defenders on the
                # target square
                stm = stm.opposite()
            # We beat the threshold, hooray!
            break

    return position.sideToMove != stm