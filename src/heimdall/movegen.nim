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

## Move generation logic

import std/strformat
import std/strutils
import std/tables


import heimdall/board
import heimdall/moves
import heimdall/pieces
import heimdall/position
import heimdall/bitboards
import heimdall/util/rays
import heimdall/util/magics
import heimdall/datagen/marlinformat


export bitboards, magics, pieces, moves, position, rays, board


proc isEPLegal*(self: var Position, friendlyKing, epTarget: Square, occupancy, pawns: Bitboard, sideToMove: PieceColor): tuple[left, right: Square] {.gcsafe.} =
    ## Checks if en passant is legal and returns the square of the 
    ## piece which can perform it on either side
    let epBitboard = if epTarget != nullSquare(): epTarget.toBitboard() else: Bitboard(0) 
    result.left = nullSquare()
    result.right = nullSquare() 
    if epBitboard != 0:
        # See if en passant would create a check
        let
            epPawn = epBitboard.backwardRelativeTo(sideToMove)
            epLeft = pawns.forwardLeftRelativeTo(sideToMove) and epBitboard
            epRight = pawns.forwardRightRelativeTo(sideToMove) and epBitboard
        # Note: it's possible for two pawns to both have rights to do an en passant! See 
        # 4k3/8/8/2PpP3/8/8/8/4K3 w - d6 0 1
        if epLeft != 0:
            # We basically simulate the en passant and see if the resulting
            # occupancy bitboard has the king in check
            let 
                friendlyPawn = epBitboard.backwardRightRelativeTo(sideToMove)
                newOccupancy = occupancy and not epPawn and not friendlyPawn or epBitboard
            # We also need to temporarily remove the en passant pawn from
            # our bitboards, or else functions like getPawnAttacks won't 
            # get the news that the pawn is gone and will still think the
            # king is in check after en passant when it actually isn't 
            # (see pos fen rnbqkbnr/pppp1ppp/8/2P5/K7/8/PPPP1PPP/RNBQ1BNR b kq - 0 1 moves b7b5 c5b6)
            let epPawnSquare = epPawn.toSquare()
            let epPiece = self.getPiece(epPawnSquare)
            self.removePiece(epPawnSquare)
            if not self.isOccupancyAttacked(friendlyKing, newOccupancy):
                result.left = friendlyPawn.toSquare()
            self.spawnPiece(epPawnSquare, epPiece)
        if epRight != 0:
            # Note that this isn't going to be the same pawn from the previous if block!
            let 
                friendlyPawn = epBitboard.backwardLeftRelativeTo(sideToMove)
                newOccupancy = occupancy and not epPawn and not friendlyPawn or epBitboard
            let epPawnSquare = epPawn.toSquare()
            let epPiece = self.getPiece(epPawnSquare)
            self.removePiece(epPawnSquare)
            if not self.isOccupancyAttacked(friendlyKing, newOccupancy):
                # En passant does not create a check on the king: all good
                result.right = friendlyPawn.toSquare()
            self.spawnPiece(epPawnSquare, epPiece)


proc generatePawnMoves(self: var Position, moves: var MoveList, destinationMask: Bitboard) =
    let 
        sideToMove = self.sideToMove
        nonSideToMove = sideToMove.opposite()
        pawns = self.getBitboard(Pawn, sideToMove)
        occupancy = self.getOccupancy()
        # We can only capture enemy pieces
        enemyPieces = self.getOccupancyFor(nonSideToMove)
        epTarget = self.enPassantSquare
        diagonalPins = self.diagonalPins
        orthogonalPins = self.orthogonalPins
        promotionRank = sideToMove.getEighthRank()
        startingRank = sideToMove.getSecondRank()
        friendlyKing = self.getBitboard(King, sideToMove).toSquare()

    # Single and double pushes

    # If a pawn is pinned diagonally, it cannot push forward
    let 
        # If a pawn is pinned horizontally, it cannot move either. It can move vertically
        # though. Thanks to Twipply for the tip on how to get a horizontal pin mask out of
        # our orthogonal bitboard :)
        horizontalPins = Bitboard((0xFF'u64 shl (rankFromSquare(friendlyKing) * 8))) and orthogonalPins
        pushablePawns = pawns and not diagonalPins and not horizontalPins
        singlePushes = (pushablePawns.forwardRelativeTo(sideToMove) and not occupancy) and destinationMask
    # We do this weird dance instead of using doubleForwardRelativeTo() because that doesn't have any
    # way to check if there's pieces on the two squares ahead of the pawn and will just happily les
    # us phase through a piece
    var canDoublePush = pushablePawns and startingRank
    canDoublePush = canDoublePush.forwardRelativeTo(sideToMove) and not occupancy
    canDoublePush = canDoublePush.forwardRelativeTo(sideToMove) and not occupancy and destinationMask

    for pawn in singlePushes and not promotionRank:
        moves.add(createMove(pawn.toBitboard().backwardRelativeTo(sideToMove), pawn))
    
    for pawn in singlePushes and promotionRank:
        for promotion in [PromoteToBishop, PromoteToKnight, PromoteToQueen, PromoteToRook]:
            moves.add(createMove(pawn.toBitboard().backwardRelativeTo(sideToMove), pawn, promotion))

    for pawn in canDoublePush:
        moves.add(createMove(pawn.toBitboard().doubleBackwardRelativeTo(sideToMove), pawn, DoublePush))

    let 
        canCapture = pawns and not orthogonalPins
        canCaptureLeftUnpinned = (canCapture and not diagonalPins).forwardLeftRelativeTo(sideToMove) and enemyPieces and destinationMask
        canCaptureRightUnpinned = (canCapture and not diagonalPins).forwardRightRelativeTo(sideToMove) and enemyPieces and destinationMask

    for pawn in canCaptureRightUnpinned and not promotionRank:
        moves.add(createMove(pawn.toBitboard().backwardLeftRelativeTo(sideToMove), pawn, Capture))
    
    for pawn in canCaptureRightUnpinned and promotionRank:
        for promotion in [PromoteToBishop, PromoteToKnight, PromoteToQueen, PromoteToRook]:
            moves.add(createMove(pawn.toBitboard().backwardLeftRelativeTo(sideToMove), pawn, Capture, promotion))

    for pawn in canCaptureLeftUnpinned and not promotionRank:
        moves.add(createMove(pawn.toBitboard().backwardRightRelativeTo(sideToMove), pawn, Capture))
    
    for pawn in canCaptureLeftUnpinned and promotionRank:
        for promotion in [PromoteToBishop, PromoteToKnight, PromoteToQueen, PromoteToRook]:
            moves.add(createMove(pawn.toBitboard().backwardRightRelativeTo(sideToMove), pawn, Capture, promotion))

    # Special cases for pawns pinned diagonally that can capture their pinners

    let 
        canCaptureLeft = canCapture.forwardLeftRelativeTo(sideToMove) and enemyPieces and destinationMask
        canCaptureRight = canCapture.forwardRightRelativeTo(sideToMove) and enemyPieces and destinationMask
        leftPinnedCanCapture = (canCaptureLeft and diagonalPins) and not canCaptureLeftUnpinned
        rightPinnedCanCapture = ((canCaptureRight and diagonalPins) and not canCaptureRightUnpinned) and not canCaptureRightUnpinned

    for pawn in leftPinnedCanCapture and not promotionRank:
        moves.add(createMove(pawn.toBitboard().backwardRightRelativeTo(sideToMove), pawn, Capture))

    for pawn in leftPinnedCanCapture and promotionRank:
        for promotion in [PromoteToBishop, PromoteToKnight, PromoteToQueen, PromoteToRook]:
            moves.add(createMove(pawn.toBitboard().backwardRightRelativeTo(sideToMove), pawn, Capture, promotion))

    for pawn in rightPinnedCanCapture and not promotionRank:
        moves.add(createMove(pawn.toBitboard().backwardLeftRelativeTo(sideToMove), pawn, Capture))

    for pawn in rightPinnedCanCapture and promotionRank:
        for promotion in [PromoteToBishop, PromoteToKnight, PromoteToQueen, PromoteToRook]:
            moves.add(createMove(pawn.toBitboard().backwardLeftRelativeTo(sideToMove), pawn, Capture, promotion))

    # En passant captures
    let epLegality = self.isEPLegal(friendlyKing, epTarget, occupancy, pawns, sideToMove)
    if epLegality.left != nullSquare():
        moves.add(createMove(epLegality.left, epTarget, EnPassant))
    if epLegality.right != nullSquare():
        moves.add(createMove(epLegality.right, epTarget, EnPassant))


proc generateRookMoves(self: Position, moves: var MoveList, destinationMask: Bitboard) =
    let 
        sideToMove = self.sideToMove
        occupancy = self.getOccupancy()
        enemyPieces = self.getOccupancyFor(sideToMove.opposite())
        rooks = self.getBitboard(Rook, sideToMove)
        queens = self.getBitboard(Queen, sideToMove)
        movableRooks = not self.diagonalPins and (queens or rooks)
        pinMask = self.orthogonalPins
        pinnedRooks = movableRooks and pinMask
        unpinnedRooks = movableRooks and not pinnedRooks

    for square in pinnedRooks:
        let 
            moveset = getRookMoves(square, occupancy)
        for target in moveset and pinMask and destinationMask and not enemyPieces:
            moves.add(createMove(square, target))
        for target in moveset and enemyPieces and pinMask and destinationMask:
            moves.add(createMove(square, target, Capture))

    for square in unpinnedRooks:
        let moveset = getRookMoves(square, occupancy)
        for target in moveset and destinationMask and not enemyPieces:
            moves.add(createMove(square, target))
        for target in moveset and enemyPieces and destinationMask:
            moves.add(createMove(square, target, Capture))


proc generateBishopMoves(self: Position, moves: var MoveList, destinationMask: Bitboard) =
    let 
        sideToMove = self.sideToMove
        occupancy = self.getOccupancy()
        enemyPieces = self.getOccupancyFor(sideToMove.opposite())
        bishops = self.getBitboard(Bishop, sideToMove)
        queens = self.getBitboard(Queen, sideToMove)
        movableBishops = not self.orthogonalPins and (queens or bishops)
        pinMask = self.diagonalPins
        pinnedBishops = movableBishops and pinMask
        unpinnedBishops = movableBishops and not pinnedBishops
    for square in pinnedBishops:
        let moveset = getBishopMoves(square, occupancy)
        for target in moveset and pinMask and destinationMask and not enemyPieces:
            moves.add(createMove(square, target))
        for target in moveset and pinMask and enemyPieces and destinationMask:
            moves.add(createMove(square, target, Capture))
    for square in unpinnedBishops:
        let moveset = getBishopMoves(square, occupancy)
        for target in moveset and destinationMask and not enemyPieces:
            moves.add(createMove(square, target))
        for target in moveset and enemyPieces and destinationMask:
            moves.add(createMove(square, target, Capture))


proc generateKingMoves(self: Position, moves: var MoveList, capturesOnly=false) =
    let 
        sideToMove = self.sideToMove
        king = self.getBitboard(King, sideToMove)
        occupancy = self.getOccupancy()
        nonSideToMove = sideToMove.opposite()
        enemyPieces = self.getOccupancyFor(nonSideToMove)
        bitboard = getKingMoves(king.toSquare())
        noKingOccupancy = occupancy and not king
    if not capturesOnly:
        for square in bitboard and not occupancy:
            if not self.isOccupancyAttacked(square, noKingOccupancy):
                moves.add(createMove(king, square))
    for square in bitboard and enemyPieces:
        if not self.isOccupancyAttacked(square, noKingOccupancy):
            moves.add(createMove(king, square, Capture))


proc generateKnightMoves(self: Position, moves: var MoveList, destinationMask: Bitboard) =
    let 
        sideToMove = self.sideToMove
        knights = self.getBitboard(Knight, sideToMove)
        nonSideToMove = sideToMove.opposite()
        pinned = self.diagonalPins or self.orthogonalPins
        unpinnedKnights = knights and not pinned
        enemyPieces = self.getOccupancyFor(nonSideToMove) and not self.getBitboard(King, nonSideToMove)
    for square in unpinnedKnights:
        let bitboard = getKnightMoves(square)
        for target in bitboard and destinationMask and not enemyPieces:
            moves.add(createMove(square, target))
        for target in bitboard and destinationMask and enemyPieces:
            moves.add(createMove(square, target, Capture))


proc generateCastling(self: Position, moves: var MoveList) =
    let 
        sideToMove = self.sideToMove
        castlingRights = self.canCastle()
        kingSquare = self.getBitboard(King, sideToMove).toSquare()
    if castlingRights.king != nullSquare():
        moves.add(createMove(kingSquare, castlingRights.king, Castle))
    if castlingRights.queen != nullSquare():
        moves.add(createMove(kingSquare, castlingRights.queen, Castle))


proc generateMoves*(self: var Position, moves: var MoveList, capturesOnly: bool = false) {.inline.} =
    ## Generates the list of all possible legal moves
    ## in the current position. If capturesOnly is
    ## true, only capture moves are generated
    let 
        sideToMove = self.sideToMove
        nonSideToMove = sideToMove.opposite()
    self.generateKingMoves(moves, capturesOnly)
    if self.checkers.countSquares() > 1:
        # King is in double check: no need to generate any more
        # moves
        return
    
    self.generateCastling(moves)
    
    # We pass a mask to our move generators to remove stuff 
    # like our friendly pieces from the set of possible
    # target squares, as well as to ensure checks are not
    # ignored

    var destinationMask: Bitboard
    if not self.inCheck():
        # Not in check: cannot move over friendly pieces
        destinationMask = not self.getOccupancyFor(sideToMove)
    else:
        # We *are* in check (from a single piece, because the two checks
        # case was handled above already). If the piece is a slider, we'll
        # extract the ray from it to our king and add the checking piece to 
        # it, meaning the only legal moves are those that either block the 
        # check or capture the checking piece. For other non-sliding pieces
        # the ray will be empty so the only legal move will be to capture
        # the checking piece (or moving the king)
        let 
            checker = self.checkers.lowestSquare()
            checkerBB = checker.toBitboard()
            # epTarget = self.positions[^1].enPassantSquare
            # checkerPiece = self.positions[^1].getPiece(checker)
        destinationMask = getRayBetween(checker, self.getBitboard(King, sideToMove).toSquare()) or checkerBB
        # TODO: This doesn't really work. I've addressed the issue for now, but it's kinda ugly. Find a better
        # solution
        # if checkerPiece.kind == Pawn and checkerBB.backwardRelativeTo(checkerPiece.color).toSquare() == epTarget:
        #     # We are in check by a pawn that pushed two squares: add the ep target square to the set of
        #     # squares that our friendly pieces can move to in order to resolve it. This will do nothing
        #     # for most pieces, because the move generators won't allow them to move there, but it does matter
        #     # for pawns
        #     destinationMask = destinationMask or epTarget.toBitboard()
    if capturesOnly:
        # Note: This does not cover en passant (which is good because it's a capture,
        # but the "fix" stands on flimsy ground)
        destinationMask = destinationMask and self.getOccupancyFor(nonSideToMove)
    self.generatePawnMoves(moves, destinationMask)
    self.generateKnightMoves(moves, destinationMask)
    self.generateRookMoves(moves, destinationMask)
    self.generateBishopMoves(moves, destinationMask)
    # Queens are just handled as rooks + bishops
    

proc generateMoves*(self: Chessboard, moves: var MoveList, capturesOnly=false) {.inline.} =
    ## The same as Position.generateMoves()
    self.positions[^1].generateMoves(moves, capturesOnly)


proc revokeQueenSideCastlingRights(self: var Position, side: PieceColor) {.inline.} =
    ## Revokes the queenside castling rights for the given side
    if self.castlingAvailability[side].queen != nullSquare():
        self.castlingAvailability[side].queen = nullSquare()
        self.zobristKey = self.zobristKey xor getQueenSideCastlingKey(side)


proc revokeKingSideCastlingRights(self: var Position, side: PieceColor) {.inline.} =
    ## Revokes the kingside castling rights for the given side
    if self.castlingAvailability[side].king != nullSquare():
        self.castlingAvailability[side].king = nullSquare()
        self.zobristKey = self.zobristKey xor getKingSideCastlingKey(side)


proc revokeCastlingRights(self: var Position, side: PieceColor) {.inline.} =
    ## Revokes the castling rights for the given side
    self.revokeKingSideCastlingRights(side)
    self.revokeQueenSideCastlingRights(side)


proc doMove*(self: Chessboard, move: Move) {.gcsafe.} =
    ## Internal function called by makeMove after
    ## performing legality checks. Can be used in 
    ## performance-critical paths where a move is
    ## already known to be legal (i.e. during search)

    # Final checks
    let piece = self.getPiece(move.startSquare)
    
    assert piece.kind != Empty and piece.color != None, &"{move} {self.toFEN()}"

    let
        sideToMove = piece.color
        nonSideToMove = sideToMove.opposite()
        kingSideRook = self.positions[^1].castlingAvailability[sideToMove].king
        queenSideRook = self.positions[^1].castlingAvailability[sideToMove].queen
        kingSq = self.getBitboard(King, sideToMove).toSquare()
        king = self.getPiece(kingSq)

    var
        halfMoveClock = self.positions[^1].halfMoveClock
        fullMoveCount = self.positions[^1].fullMoveCount
        enPassantTarget = nullSquare()

    # Needed to detect draw by the 50 move rule
    if piece.kind == Pawn or move.isCapture() or move.isEnPassant():
        # Number of half-moves since the last reversible half-move
        halfMoveClock = 0
    else:
        inc(halfMoveClock)

    if piece.color == Black:
        inc(fullMoveCount)

    if move.isDoublePush():
        enPassantTarget = move.targetSquare.toBitboard().backwardRelativeTo(piece.color).toSquare()


    # Create new position
    self.positions.add(Position(halfMoveClock: halfMoveClock,
                                fullMoveCount: fullMoveCount,
                                sideToMove: nonSideToMove,
                                enPassantSquare: enPassantTarget,
                                pieces: self.positions[^1].pieces,
                                colors: self.positions[^1].colors,
                                castlingAvailability: self.positions[^1].castlingAvailability,
                                zobristKey: self.positions[^1].zobristKey,
                                mailbox: self.positions[^1].mailbox
                            ))
    # I HATE EN PASSANT!!!!!!
    let previousEPTarget = self.positions[^2].enPassantSquare
    if previousEPTarget != nullSquare():
        # Unset previous en passant target
        self.positions[^1].zobristKey = self.positions[^1].zobristKey xor getEnPassantKey(fileFromSquare(previousEPTarget))

    # Update position metadata

    if move.isEnPassant():
        # Make the en passant pawn disappear
        let epPawnSquare = move.targetSquare.toBitboard().backwardRelativeTo(sideToMove).toSquare()
        self.positions[^1].removePiece(epPawnSquare)

    if move.isCastling() or piece.kind == King:
        # If the king has moved, all castling rights for the side to
        # move are revoked
        self.positions[^1].revokeCastlingRights(sideToMove)

        if move.isCastling():
            # Move the rook and king

            # Castling is encoded as king takes own rook, hence the move's
            # target square is the rook's location!
            let
                rook = self.getPiece(move.targetSquare)
                isKingSide = move.targetSquare == kingSideRook
                rookTarget = if isKingSide: rook.kingSideCastling() else: rook.queenSideCastling()
                kingTarget = if isKingSide: king.kingSideCastling() else: king.queenSideCastling()
            
            self.positions[^1].removePiece(kingSq)
            self.positions[^1].removePiece(move.targetSquare)
            self.positions[^1].spawnPiece(rookTarget, rook)
            self.positions[^1].spawnPiece(kingTarget, king)

    if piece.kind == Rook:
        # If a rook on either side moves, castling rights are permanently revoked
        # on that side
        if move.startSquare == kingSideRook:
            self.positions[^1].revokeKingSideCastlingRights(sideToMove)

        if move.startSquare == queenSideRook:
            self.positions[^1].revokeQueenSideCastlingRights(sideToMove)

    if move.isCapture():
        # Get rid of captured pieces
        let captured = self.getPiece(move.targetSquare)
        self.positions[^1].removePiece(move.targetSquare)
        # If a rook on either side has been captured, castling on that side is prohibited
        if captured.kind == Rook:
            let availability = self.positions[^1].castlingAvailability[nonSideToMove]

            if move.targetSquare == availability.king:
                self.positions[^1].revokeKingSideCastlingRights(nonSideToMove)

            elif move.targetSquare == availability.queen:
                self.positions[^1].revokeQueenSideCastlingRights(nonSideToMove)

    if not move.isCastling():
        self.positions[^1].movePiece(move)

    if move.isPromotion():
        # Move is a pawn promotion: get rid of the pawn
        # and spawn a new piece
        self.positions[^1].removePiece(move.targetSquare)
        var spawnedPiece: Piece
        case move.getPromotionType():
            of PromoteToBishop:
                spawnedPiece = Piece(kind: Bishop, color: piece.color)
            of PromoteToKnight:
                spawnedPiece = Piece(kind: Knight, color: piece.color)
            of PromoteToRook:
                spawnedPiece = Piece(kind: Rook, color: piece.color)
            of PromoteToQueen:
                spawnedPiece = Piece(kind: Queen, color: piece.color)
            else:
                # Unreachable
                discard
        self.positions[^1].spawnPiece(move.targetSquare, spawnedPiece)

    if move.isDoublePush():
        let 
            epTarget = self.positions[^1].enPassantSquare
            pawns = self.getBitboard(Pawn, nonSideToMove)
            occupancy = self.getOccupancy()
            kingSq = self.getBitboard(King, nonSideToMove).toSquare()
        # This is very minor, but technically a square is a valid en passant target only if an enemy 
        # pawn can be captured by playing en passant. The only thing this changes is that we won't have
        # an ep square displayed in the FENs at every double push anymore (it should also make repetition
        # detection more reliable since we won't be considering an invalid ep target square in our
        # zobrist hashes)
        let legality = self.positions[^1].isEPLegal(kingSq, epTarget, occupancy, pawns, nonSideToMove)
        if legality.left == nullSquare() and legality.right == nullSquare():
            self.positions[^1].enPassantSquare = nullSquare()
        else:
            # EP is legal, update zobrist hash
            self.positions[^1].zobristKey = self.positions[^1].zobristKey xor getEnPassantKey(fileFromSquare(enPassantTarget))

    # Updates checks and pins for the new side to move
    self.positions[^1].updateChecksAndPins()
    # Swap the side to move
    self.positions[^1].zobristKey = self.positions[^1].zobristKey xor getBlackToMoveKey()


proc isLegal*(self: Chessboard, move: Move): bool {.inline.} =
    ## Returns whether the given move is legal
    var moves = newMoveList()
    self.generateMoves(moves)
    return move in moves


proc isLegal*(self: var Position, move: Move): bool {.inline.} =
    ## Returns whether the given move is legal
    var moves = newMoveList()
    self.generateMoves(moves)
    return move in moves


proc makeMove*(self: Chessboard, move: Move): Move {.inline, discardable.} =
    ## Makes a move on the board
    result = move
    if not self.isLegal(move):
        return nullMove()
    self.doMove(move)


proc makeNullMove*(self: Chessboard) {.inline.} =
    ## Makes a "null" move, i.e. passes the turn
    ## to the opponent without making a move. This
    ## is obviously illegal and only to be used during
    ## search. The move can be undone via unmakeMove
    self.positions.add(self.positions[^1])
    self.positions[^1].sideToMove = self.positions[^1].sideToMove.opposite()
    let previousEPTarget = self.positions[^2].enPassantSquare
    if previousEPTarget != nullSquare():
        self.positions[^1].zobristKey = self.positions[^1].zobristKey xor getEnPassantKey(fileFromSquare(previousEPTarget))
    self.positions[^1].enPassantSquare = nullSquare()
    self.positions[^1].fromNull = true
    self.positions[^1].updateChecksAndPins()
    self.positions[^1].zobristKey = self.positions[^1].zobristKey xor getBlackToMoveKey()


func canNullMove*(self: Chessboard): bool {.inline.} =
    ## Returns whether a null move can be made.
    ## Specifically, one cannot null move if a
    ## null move was already made previously or
    ## if the side to move is in check
    return not self.inCheck() and not self.positions[^1].fromNull


proc isCheckmate*(self: Chessboard): bool {.inline.} =
    ## Returns whether the game ended with a
    ## checkmate
    if not self.inCheck():
        return false
    var moves {.noinit.} = newMoveList()
    self.generateMoves(moves)
    return moves.len() == 0


proc isStalemate*(self: Chessboard): bool {.inline.} =
    ## Returns whether the game ended with a
    ## stalemate
    if self.inCheck():
        return false
    var moves {.noinit.} = newMoveList()
    self.generateMoves(moves)
    return moves.len() == 0


proc isDrawn*(self: Chessboard, twofold: bool = false): bool {.inline.} =
    ## Returns whether the given position is
    ## drawn
    if self.positions[^1].halfMoveClock >= 100:
        # Draw by 50 move rule. Note
        # that mate always takes priority over
        # the 50-move draw, so we need to account
        # for that
        return not self.isCheckmate()

    if self.isInsufficientMaterial():
        return true

    if self.drawnByRepetition(twofold):
        return true


proc isGameOver*(self: Chessboard): bool {.inline.} =
    ## Returns whether the game is over either
    ## by checkmate, draw or repetition
    if self.isDrawn():
        return true
    # No need to check for checks: we allow both
    # stalemate and checkmate
    var moves {.noinit.} = newMoveList()
    self.generateMoves(moves)
    return moves.len() == 0


proc unmakeMove*(self: Chessboard) {.inline.} =
    ## Reverts to the previous board position
    if self.positions.len() == 0:
        return
    discard self.positions.pop()


## Testing stuff


proc testPiece(piece: Piece, kind: PieceKind, color: PieceColor) =
    doAssert piece.kind == kind and piece.color == color, &"expected piece of kind {kind} and color {color}, got {piece.kind} / {piece.color} instead"


proc testPieceCount(board: Chessboard, kind: PieceKind, color: PieceColor, count: int) =
    let pieces = board.positions[^1].countPieces(kind, color)
    doAssert pieces == count, &"expected {count} pieces of kind {kind} and color {color}, got {pieces} instead"


proc testPieceBitboard(bitboard: Bitboard, squares: seq[Square]) =
    var i = 0
    for square in bitboard:
        doAssert squares[i] == square, &"squares[{i}] != bitboard[i]: {squares[i]} != {square}"
        inc(i)
    if i != squares.len():
        doAssert false, &"bitboard.len() ({i}) != squares.len() ({squares.len()})"

## Tests

const testFens* = staticRead("../../tests/standard.txt").splitLines()
const drawnFens = [("4k3/2b5/8/8/8/5B2/8/4K3 w - - 0 1", false),   # KBvKB (currently not handled)
                   ("4k3/2b5/8/8/8/8/8/4K3 w - - 0 1", true),      # KBvK
                   ("4k3/8/6b1/8/8/8/8/4K3 w - - 0 1", true),      # KvKB
                   ("4k3/8/8/6N1/8/8/8/4K3 w - - 0 1", true),      # KNvK
                   ("4k3/8/8/5n2/8/8/8/4K3 w - - 0 1", true),      # KvKN
                   ("4k3/8/8/5n2/8/5N2/8/4K3 w - - 0 1", false),   # KNvKN
                   ("4k3/8/6b1/7b/8/8/8/4K3 w - - 0 1", false),    # KvKBB with same color bishop (currently not handled)
                   ("4k3/8/8/5B2/6B1/8/8/4K3 w - - 0 1", false)    # KBBvK with same color bishop (currently not handled)
                  ]


proc basicTests* =

    # Test the FEN parser
    for fen in testFens:
        let f = loadFEN(fen).toFEN()
        doAssert fen == f, &"{fen} != {f}"
    
    # Test zobrist hashing
    for fen in testFens:
        var
            board = newChessboardFromFEN(fen)
            hashes = newTable[ZobristKey, Move]()
            moves = newMoveList()
        board.generateMoves(moves)
        for move in moves:
            board.makeMove(move)
            let 
                pos = board.positions[^1]
                key = pos.zobristKey
            board.unmakeMove()
            doAssert not hashes.contains(key), &"{fen} has zobrist collisions {move} -> {hashes[key]} (key is {key.uint64})"
            hashes[key] = move

    # Test detection of (some) draws by insufficient material
    for (fen, isDrawn) in drawnFens:
        doAssert newChessboardFromFEN(fen).isInsufficientMaterial() == isDrawn, &"draw check failed for {fen} (expected {isDrawn})"

    var board = newDefaultChessboard()
    # Ensure correct number of pieces
    testPieceCount(board, Pawn, White, 8)
    testPieceCount(board, Pawn, Black, 8)
    testPieceCount(board, Knight, White, 2)
    testPieceCount(board, Knight, Black, 2)
    testPieceCount(board, Bishop, White, 2)
    testPieceCount(board, Bishop, Black, 2)
    testPieceCount(board, Rook, White, 2)
    testPieceCount(board, Rook, Black, 2)
    testPieceCount(board, Queen, White, 1)
    testPieceCount(board, Queen, Black, 1)
    testPieceCount(board, King, White, 1)
    testPieceCount(board, King, Black, 1)

    # Ensure pieces are in the correct squares

    # Pawns
    for loc in ["a2", "b2", "c2", "d2", "e2", "f2", "g2", "h2"]:
        testPiece(board.positions[^1].getPiece(loc), Pawn, White)
    for loc in ["a7", "b7", "c7", "d7", "e7", "f7", "g7", "h7"]:
        testPiece(board.positions[^1].getPiece(loc), Pawn, Black)
    # Rooks
    testPiece(board.positions[^1].getPiece("a1"), Rook, White)
    testPiece(board.positions[^1].getPiece("h1"), Rook, White)
    testPiece(board.positions[^1].getPiece("a8"), Rook, Black)
    testPiece(board.positions[^1].getPiece("h8"), Rook, Black)
    # Knights
    testPiece(board.positions[^1].getPiece("b1"), Knight, White)
    testPiece(board.positions[^1].getPiece("g1"), Knight, White)
    testPiece(board.positions[^1].getPiece("b8"), Knight, Black)
    testPiece(board.positions[^1].getPiece("g8"), Knight, Black)
    # Bishops
    testPiece(board.positions[^1].getPiece("c1"), Bishop, White)
    testPiece(board.positions[^1].getPiece("f1"), Bishop, White)
    testPiece(board.positions[^1].getPiece("c8"), Bishop, Black)
    testPiece(board.positions[^1].getPiece("f8"), Bishop, Black)
    # Kings
    testPiece(board.positions[^1].getPiece("e1"), King, White)
    testPiece(board.positions[^1].getPiece("e8"), King, Black)
    # Queens
    testPiece(board.positions[^1].getPiece("d1"), Queen, White)
    testPiece(board.positions[^1].getPiece("d8"), Queen, Black)

    # Ensure our bitboards match with the board
    let 
        whitePawns = board.positions[^1].getBitboard(Pawn, White)
        whiteKnights = board.positions[^1].getBitboard(Knight, White)
        whiteBishops = board.positions[^1].getBitboard(Bishop, White)
        whiteRooks = board.positions[^1].getBitboard(Rook, White)
        whiteQueens = board.positions[^1].getBitboard(Queen, White)
        whiteKing = board.positions[^1].getBitboard(King, White)
        blackPawns = board.positions[^1].getBitboard(Pawn, Black)
        blackKnights = board.positions[^1].getBitboard(Knight, Black)
        blackBishops = board.positions[^1].getBitboard(Bishop, Black)
        blackRooks = board.positions[^1].getBitboard(Rook, Black)
        blackQueens = board.positions[^1].getBitboard(Queen, Black)
        blackKing = board.positions[^1].getBitboard(King, Black)
        whitePawnSquares = @[makeSquare(6'i8, 0'i8), makeSquare(6, 1), makeSquare(6, 2), makeSquare(6, 3), makeSquare(6, 4), makeSquare(6, 5), makeSquare(6, 6), makeSquare(6, 7)]
        whiteKnightSquares = @[makeSquare(7'i8, 1'i8), makeSquare(7, 6)]
        whiteBishopSquares = @[makeSquare(7'i8, 2'i8), makeSquare(7, 5)]
        whiteRookSquares = @[makeSquare(7'i8, 0'i8), makeSquare(7, 7)]
        whiteQueenSquares = @[makeSquare(7'i8, 3'i8)]
        whiteKingSquares = @[makeSquare(7'i8, 4'i8)]
        blackPawnSquares = @[makeSquare(1'i8, 0'i8), makeSquare(1, 1), makeSquare(1, 2), makeSquare(1, 3), makeSquare(1, 4), makeSquare(1, 5), makeSquare(1, 6), makeSquare(1, 7)]
        blackKnightSquares = @[makeSquare(0'i8, 1'i8), makeSquare(0, 6)]
        blackBishopSquares = @[makeSquare(0'i8, 2'i8), makeSquare(0, 5)]
        blackRookSquares = @[makeSquare(0'i8, 0'i8), makeSquare(0, 7)]
        blackQueenSquares = @[makeSquare(0'i8, 3'i8)]
        blackKingSquares = @[makeSquare(0'i8, 4'i8)]


    testPieceBitboard(whitePawns, whitePawnSquares)
    testPieceBitboard(whiteKnights, whiteKnightSquares)
    testPieceBitboard(whiteBishops, whiteBishopSquares)
    testPieceBitboard(whiteRooks, whiteRookSquares)
    testPieceBitboard(whiteQueens, whiteQueenSquares)
    testPieceBitboard(whiteKing, whiteKingSquares)
    testPieceBitboard(blackPawns, blackPawnSquares)
    testPieceBitboard(blackKnights, blackKnightSquares)
    testPieceBitboard(blackBishops, blackBishopSquares)
    testPieceBitboard(blackRooks, blackRookSquares)
    testPieceBitboard(blackQueens, blackQueenSquares)
    testPieceBitboard(blackKing, blackKingSquares)

    # Test repetition
    for move in ["b1c3", "g8f6", "c3b1", "f6g8", "b1c3", "g8f6", "c3b1", "f6g8"]:
        board.makeMove(createMove(move[0..1].toSquare(), move[2..3].toSquare()))
    doAssert board.drawnByRepetition()

    # Test the position serializer
    for fen in testFens:
        var board = newChessboardFromFEN(fen)
        var eval: int16
        for i in countup(0, 3):
            var available = newMoveList()
            board.generateMoves(available)
            board.doMove(available[0])
            if (i and 1) == 0:
                eval = 100
            else:
                eval = -100
            let game = createMarlinFormatRecord(board.positions[^1], board.sideToMove, eval)
            let pos = game.position
            let rebuilt = game.toMarlinformat().fromMarlinformat()
            let newPos = rebuilt.position
            # We could just check that game == rebuilt but this allows a more granular error message
            try:
                doAssert game.eval == eval, &"{eval} != {game.eval}"
                doAssert game.wdl == rebuilt.wdl, &"{game.wdl} != {rebuilt.wdl}"
                doAssert pos.pieces == newPos.pieces
                doAssert pos.castlingAvailability == newPos.castlingAvailability, &"{pos.castlingAvailability} != {newPos.castlingAvailability}"
                doAssert pos.enPassantSquare == newPos.enPassantSquare, &"{pos.enPassantSquare} != {newPos.enPassantSquare}"
                doAssert pos.halfMoveClock == newPos.halfMoveClock, &"{pos.halfMoveClock} != {newPos.halfMoveClock}"
                doAssert pos.fullMoveCount == newPos.fullMoveCount, &"{pos.fullMoveCount} != {newPos.fullMoveCount}"
                doAssert pos.sideToMove == newPos.sideToMove, &"{pos.sideToMove} != {newPos.sideToMove}"
                doAssert pos.checkers == newPos.checkers, &"{pos.checkers} != {newPos.checkers}"
                doAssert pos.orthogonalPins == newPos.orthogonalPins, &"{pos.orthogonalPins} != {newPos.orthogonalPins}"
                doAssert pos.diagonalPins == newPos.diagonalPins, &"{pos.orthogonalPins} != {newPos.orthogonalPins}"
                doAssert pos.zobristKey == newPos.zobristKey, &"{pos.zobristKey} != {newPos.zobristKey}"
                for sq in Square(0)..Square(63):
                    if pos.mailbox[sq] != newPos.mailbox[sq]:
                        echo &"Mailbox mismatch at {sq}: {pos.mailbox[sq]} != {newPos.mailbox[sq]}"
                        break
            except AssertionDefect:
                echo &"Test failed for {fen} -> {board.toFEN()}"
                raise getCurrentException()
