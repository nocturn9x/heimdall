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
import std/algorithm


import position
import pieces
import board



func getStaticPieceScore*(kind: PieceKind): int =
    ## Returns a static score for the given piece
    ## type to be used inside SEE. This makes testing
    ## as well as general usage of SEE much more
    ## sane, because if SEE(move) == 0 then we know
    ## the capture sequence is balanced
    case kind:
        of Pawn:
            return 100
        of Knight:
            return 450
        of Bishop:
            return 450
        of Rook:
            return 650
        of Queen:
            return 1250
        of King:
            # The king has a REALLY large value so
            # that capturing it is always losing
            return 100000
        else:
            return 0


func getStaticPieceScore*(piece: Piece): int {.inline.} =
    ## Returns a static score for the given piece
    ## to be used inside SEE. This makes testing
    ## as well as general usage of SEE much more
    ## sane, because if SEE(move) == 0 then we know
    ## the capture sequence is balanced
    return piece.kind.getStaticPieceScore()


proc pickLeastValuableAttacker(position: Position, attackers: Bitboard): Square =
    ## Returns the square in the given position containing the lowest
    ## value piece in the given attackers bitboard
    if attackers == 0:
        return nullSquare()

    var attacks: seq[tuple[score: int, square: Square]] = @[]
    for attacker in attackers:
        attacks.add((position.getPiece(attacker).getStaticPieceScore(), attacker))

    proc orderer(a, b: tuple[score: int, square: Square]): int {.closure.} =
        return cmp(a.score, b.score)


    attacks.sort(orderer)
    return attacks[0].square


proc see(position: Position, square: Square): int =
    ## Recursive implementation of static exchange evaluation
    
    # Keeping the position updated is way too much trouble, we just
    # copy it and modify the local copy instead. Waaay easier
    var position = position
    let sideToMove = position.sideToMove
    let attackers = position.getAttackersTo(square, sideToMove)
    if attackers == 0:
        return 0

    let 
        attacker = position.pickLeastValuableAttacker(attackers)
        attackerPiece = position.getPiece(attacker)
    
    var
        victimPiece = position.getPiece(square)
        victim = victimPiece.getStaticPieceScore()
    
    if victimPiece != nullPiece():
        position.removePiece(square)
        position.movePiece(attacker, square)
        # En passant capture
        if attackerPiece.kind == Pawn and square == position.enPassantSquare:
            let 
                epTarget = position.enPassantSquare.toBitboard()
                epPawn = epTarget.backwardRelativeTo(sideToMove).toSquare()
            if position.getPiece(epPawn) != nullPiece():
                victimPiece = position.getPiece(epPawn)
                victim = victimPiece.getStaticPieceScore()
                position.removePiece(epPawn)

        # Capture with promotion
        if attackerPiece.kind == Pawn and getRankMask(rankFromSquare(square)) == attackerPiece.color.getEighthRank():
            # SEE is meant to simulate the best possible sequence of moves, so we always
            # promote to a queen
            position.removePiece(square)
            position.spawnPiece(square, Piece(kind: Queen, color: sideToMove))
            result = Queen.getStaticPieceScore() - Pawn.getStaticPieceScore()
        position.sideToMove = position.sideToMove.opposite()
        # We don't want to lose material, so the maximum score is
        # zero
        result = max(0, result + victim - position.see(square))


proc see*(position: Position, move: Move): int =
    ## Statically evaluates a sequence of exchanges
    ## starting from the given one
    var position = position
    var capturedPiece = position.getPiece(move.targetSquare)
    if move.isCapture():
        position.removePiece(move.targetSquare)
    if move.isEnPassant():
        let 
            epTarget = position.enPassantSquare.toBitboard()
            epPawn = epTarget.backwardRelativeTo(position.sideToMove).toSquare()
        capturedPiece = Piece(kind: Pawn, color: position.sideToMove.opposite())
        position.removePiece(epPawn)
    if move.isPromotion():
        position.removePiece(move.startSquare)
        var promoted = Piece(color: position.sideToMove)
        case move.getPromotionType():
            of PromoteToKnight:
                promoted.kind = Knight
            of PromoteToBishop:
                promoted.kind = Bishop
            of PromoteToRook:
                promoted.kind = Rook
            of PromoteToQueen:
                promoted.kind = Queen
            else:
                discard  # Unreachable
        
        position.spawnPiece(move.targetSquare, promoted)
        result += promoted.getStaticPieceScore() - Pawn.getStaticPieceScore()
    if position.getPiece(move.targetSquare) == nullPiece():
        position.movePiece(move.startSquare, move.targetSquare)
    position.sideToMove = position.sideToMove.opposite()
    result += capturedPiece.getStaticPieceScore() - position.see(move.targetSquare)
