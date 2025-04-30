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

## Move generation logic. Shamelessly yoinked from Obsidian

import heimdall/board
import heimdall/moves
import heimdall/pieces
import heimdall/position
import heimdall/bitboards


export moves, pieces, position, bitboards


type
    MovegenFlags* = enum
        None = 0'u8
        Quiet = 1'u8
        Noisy = 2'u8
        All = 3'u8


proc isPseudoLegal*(self: Position, move: Move): bool {.inline.} =
    ## Returns whether the given move is pseudo-legal in the
    ## given position, meaning it satisfies all criteria for
    ## legality except that it may leave the king in check

    if move == nullMove():
        return false

    let
        sideToMove = self.sideToMove
        occupancy = self.getOccupancy()
        emptySquares = not occupancy
        movingPiece = self.getPiece(move.startSquare)
    
    if movingPiece == nullPiece() or sideToMove != movingPiece.color:
        # The piece has to exist and be of the right color
        return false
    
    if self.getOccupancyFor(sideToMove).contains(move.targetSquare) and not move.isCastling():
        # Can't capture your own pieces (except for castling which is
        # encoded as king takes own rook)
        return false

    if self.checkers.countSquares() > 1:
        # Double checks can only be resolved by king moves
        return movingPiece.kind == King and getKingMoves(move.startSquare).contains(move.targetSquare)

    if move.isCastling():
        let
            queenSide = move.targetSquare < move.startSquare
            (kingDst, rookDst) = CASTLING_DESTINATIONS[queenSide][sideToMove]
            castleableRook = self.castlingAvailability[sideToMove][queenSide]
            # Path from king start square to castleable rook (inclusive)
            kingRookPath = getRayBetween(move.startSquare, castleableRook) or castleableRook.toBitboard()
            # Path from king start square to castling target (inclusive)
            kingPath = getRayBetween(move.startSquare, kingDst) or kingDst.toBitboard()
            # Path from castleable rook to castling target (inclusive)
            rookPath = getRayBetween(castleableRook, rookDst) or rookDst.toBitboard()
            # Remove king and rook from occupancy to check for any blockers
            newOcc = occupancy xor self.getBitboard(King, sideToMove) xor castleableRook.toBitboard()

        # Ensure we're not in check, that castling rights allow us to castle
        # and that the path to our castling target is not blocked by any pieces
        return not self.inCheck() and castleableRook == move.targetSquare and
            (kingRookPath and newOcc).isEmpty() and (kingPath and newOcc).isEmpty() and
            (rookPath and newOcc).isEmpty()

    if move.isEnPassant() and self.enPassantSquare != nullSquare():
        # Ensure we are doing en passant on the correct square and that the pawn can
        # actually capture there
        return move.targetSquare == self.enPassantSquare and movingPiece.kind == Pawn and
            getPawnAttacks(sideToMove.opposite(), self.enPassantSquare).contains(move.startSquare)

    if move.isPromotion() and movingPiece.kind != Pawn:
        return false

    if movingPiece.kind == King:
        return getKingMoves(move.startSquare).contains(move.targetSquare)
    
    if self.inCheck():
        # We are in check (by a single piece) and are not the king: the only
        # legal moves are the ones blocking the check or capturing the checker
        let kingSq = self.getBitboard(King, sideToMove).toSquare()
        let checkerSq = self.checkers.lowestBit().toSquare()
        if not (getRayBetween(kingSq, checkerSq) or checkerSq.toBitboard()).contains(move.targetSquare):
            return false
    
    # Pawns require special handling
    if movingPiece.kind == Pawn:
        let sqBB = move.startSquare.toBitboard()
        var legalTo: Bitboard

        if sideToMove == White:
            const
                rank3BB = getRankMask(getRelativeRank(White, 2))
                fileHBB = getRightmostFile(White)
                fileABB = getLeftmostFile(White)
            # Single pushes
            legalTo = (sqBB shl 8) and emptySquares
            # Double pushes
            legalTo = legalTo or ((legalTo and rank3BB) shl 8) and emptySquares
            # Captures
            legalTo = legalTo or (((((sqBB and not fileHBB) shl 9)) or (((sqBB and not fileABB) shl 7))) and self.getOccupancyFor(Black))
        else:
            const
                rank3BB = getRankMask(getRelativeRank(Black, 2))
                fileHBB = getLeftmostFile(Black)
                fileABB = getRightmostFile(Black)
            legalTo = (sqBB shr 8) and emptySquares
            legalTo = legalTo or ((legalTo and rank3BB) shr 8) and emptySquares
            legalTo = legalTo or (((((sqBB and not fileHBB) shr 7)) or (((sqBB and not fileABB) shr 9))) and self.getOccupancyFor(White))

        return legalTo.contains(move.targetSquare)
    
    if self.kingBlockers[sideToMove].contains(move.startSquare):
        # Piece is pinned: ensure it can only move along its pin ray.
        # Does not handle pawns
        if not getRayIntersecting(move.startSquare, move.targetSquare).contains(self.getBitboard(King, sideToMove)):
            return false
    
    # Ensure the target square is reachable by the moving piece. This only takes
    # care of sliders and knights
    return getRelevantMoveset(movingPiece.kind, move.startSquare, occupancy).contains(move.targetSquare)


proc isLegal*(self: Position, move: Move, pseudoLegal: static bool): bool =
    ## Returns whether the given move is legal
    ## in the given position. If pseudoLegal is
    ## true, the move is assumed to come from a
    ## trusted source (for example the move generator)
    ## and will be assumed to be pseudo-legal already
    
    when not pseudoLegal:
        if not self.isPseudoLegal(move):
            return false
    
    # From this point on we can make a bunch of assumptions (for example
    # that self.getPiece(move.startSquare).color == self.sideToMove). Refer
    # to isPseudoLegal for details

    let occupancy = self.getOccupancy()

    # Logic mostly yoinked from Obsidian
    if move.isCastling():
        let
            queenSide = move.targetSquare < move.startSquare
            (kingDst, _) = CASTLING_DESTINATIONS[queenSide][self.sideToMove]
            kingDstBB = kingDst.toBitboard()
            # Path from king start square to castling target
            kingPath = getRayBetween(move.startSquare, kingDst)
            startBB = move.startSquare.toBitboard()
            targetBB = move.targetSquare.toBitboard()

        if (self.kingBlockers[self.sideToMove] and move.targetSquare.toBitboard()).isNotEmpty():
            # Rook is pinned. Can only happen in chess960
            return false

        # We only need to check that none of the squares the king travels to
        # are attacked in our new occupancy. By removing the rook and king from
        # the occupancy we check for pinners as well
        return not self.isAnyAttacked(kingPath or kingDstBB, occupancy xor startBB xor targetBB)
    
    let 
        sideToMove = self.sideToMove
        nonSideToMove = sideToMove.opposite()
        movingPiece = self.mailbox[move.startSquare]
        startBB = move.startSquare.toBitboard()
        targetBB = move.targetSquare.toBitboard()

    if movingPiece.kind == King:
        # We remove the king from the occupancy to ensure it can't
        # escape check by moving along a slider's attack ray
        return not self.isOccupancyAttacked(move.targetSquare, occupancy xor startBB)

    if not self.inCheck():
        # We are not in check and the piece is moving
        # along its pin ray: move is guaranteed to be
        # legal
        if getRayIntersecting(move.targetSquare, move.startSquare).contains(self.getBitboard(King, sideToMove)):
            return true

    if move.isEnPassant():
        let captureSquare = if sideToMove == White: self.enPassantSquare - 8 else: self.enPassantSquare + 8
        # Ensure en passant pawn isn't pinned to the king
        return self.getSlidingAttackers(self.getBitboard(King, sideToMove).toSquare(), nonSideToMove, occupancy xor startBB xor targetBB xor captureSquare.toBitboard()).isEmpty()
    
    if movingPiece.kind == Pawn:
        # Ensure piece isn't pinned
        return not self.kingBlockers[sideToMove].contains(startBB)

    return true


proc doMove*(self: Chessboard, move: Move) =
    ## Makes a move on the board. Legality
    ## is assumed (use makeMove if unsure)
    let sideToMove = self.sideToMove
    let nonSideToMove = self.sideToMove.opposite()
    
    self.positions.add(self.position.clone())
    self.positions[^1].fromNull = false
    self.positions[^1].sideToMove = nonSideToMove

    # Unset previous en passant square
    if self.position.enPassantSquare != nullSquare():
        self.positions[^1].zobristKey = self.position.zobristKey xor getEnPassantKey(fileFromSquare(self.position.enPassantSquare))
        self.positions[^1].enPassantSquare = nullSquare()

    inc(self.positions[^1].halfMoveClock)
    if sideToMove == Black:
        inc(self.positions[^1].fullMoveCount)
    
    if move.isCastling():
        self.positions[^1].revokeCastlingRights(sideToMove)
        let
            kingSq = self.getBitboard(King, sideToMove).toSquare()
            king = self.getPiece(move.startSquare)
            rook = self.getPiece(move.targetSquare)
            queenSide = move.targetSquare < move.startSquare
            (kingTarget, rookTarget) = CASTLING_DESTINATIONS[queenSide][sideToMove]

        self.positions[^1].removePiece(kingSq)
        self.positions[^1].removePiece(move.targetSquare)
        self.positions[^1].spawnPiece(rookTarget, rook)
        self.positions[^1].spawnPiece(kingTarget, king)

    elif move.isEnPassant():
        self.positions[^1].halfMoveClock = 0
        let epTarget = if sideToMove == White: move.targetSquare - 8 else: move.targetSquare + 8
        self.positions[^1].removePiece(epTarget)
        self.positions[^1].movePiece(move)

    elif move.isPromotion():
        self.positions[^1].halfMoveClock = 0
        self.positions[^1].removePiece(move.startSquare)
        let capturedPiece = self.getPiece(move.targetSquare)

        if capturedPiece != nullPiece():
            self.positions[^1].removePiece(move.targetSquare)
            if capturedPiece.kind == Rook:
                self.positions[^1].revokeCastlingFor(nonSideToMove, move.targetSquare)

        self.positions[^1].spawnPiece(move.targetSquare, Piece(color: sideToMove, kind: move.getPromotionType().promotionToPiece()))

    else:
        let movingPiece = self.getPiece(move.startSquare)
        let capturedPiece = self.getPiece(move.targetSquare)

        if capturedPiece != nullPiece():
            self.positions[^1].halfMoveClock = 0
            self.positions[^1].removePiece(move.targetSquare)
            if capturedPiece.kind == Rook:
                self.positions[^1].revokeCastlingFor(nonSideToMove, move.targetSquare)

        self.positions[^1].movePiece(move)
        if movingPiece.kind == Rook:
            self.positions[^1].revokeCastlingFor(sideToMove, move.startSquare)
        elif movingPiece.kind == King:
            self.positions[^1].revokeCastlingRights(sideToMove) 
        elif movingPiece.kind == Pawn:
            self.positions[^1].halfMoveClock = 0
            if move.isDoublePush():
                # Set en passant square if the opponent
                # can do it on the next move
                let target = if sideToMove == White: move.targetSquare - 8 else: move.targetSquare + 8
                if (getPawnAttacks(sideToMove, target) and self.getBitboard(Pawn, nonSideToMove)).isNotEmpty():
                    self.positions[^1].enPassantSquare = target
                    self.positions[^1].zobristKey = self.position.zobristKey xor getEnPassantKey(fileFromSquare(target))
    
    self.positions[^1].updateAttacks()
    self.positions[^1].zobristKey = self.position.zobristKey xor getBlackToMoveKey()


proc makeMove*(self: Chessboard, move: Move, pseudoLegal: static bool = true): Move {.inline, discardable.} =
    ## Makes a move on the board. If the move is
    ## not legal, a null move is returned, otherwise
    ## the original move is returned. The pseudoLegal
    ## argument is passed directly to isLegal()
    if not self.position.isLegal(move, pseudoLegal):
        return nullMove()
    self.doMove(move)
    return move


proc makeNullMove*(self: Chessboard) {.inline.} =
    ## Makes a "null" move, i.e. passes the turn
    ## to the opponent without making a move. This
    ## is obviously illegal and only to be used during
    ## search. The move can be undone via unmakeMove
    self.positions.add(self.position.clone())
    self.positions[^1].sideToMove = self.position.sideToMove.opposite()
    let previousEPTarget = self.positions[^2].enPassantSquare
    if previousEPTarget != nullSquare():
        self.positions[^1].zobristKey = self.position.zobristKey xor getEnPassantKey(fileFromSquare(previousEPTarget))
    self.positions[^1].enPassantSquare = nullSquare()
    self.positions[^1].fromNull = true
    self.positions[^1].updateAttacks()
    self.positions[^1].zobristKey = self.positions[^1].zobristKey xor getBlackToMoveKey()
    self.positions[^1].halfMoveClock = 0


func addDefaultMoves(list: var MoveList, startSquare: Square, targets: Bitboard, capture: static bool) {.inline.} =
    var targets = targets
    while targets.isNotEmpty():
        when not capture:
            list.add(createMove(startSquare, targets.popLowestBit().toSquare(), Default))
        else:
            list.add(createMove(startSquare, targets.popLowestBit().toSquare(), Capture))


func addPromotions(list: var MoveList, startSquare, targetSquare: Square, capture: static bool) =
    when not capture:
        list.add(createMove(startSquare, targetSquare, PromoteToBishop))
        list.add(createMove(startSquare, targetSquare, PromoteToKnight))
        list.add(createMove(startSquare, targetSquare, PromoteToRook))
        list.add(createMove(startSquare, targetSquare, PromoteToQueen))
    else:
        list.add(createMove(startSquare, targetSquare, PromoteToBishop, Capture))
        list.add(createMove(startSquare, targetSquare, PromoteToKnight, Capture))
        list.add(createMove(startSquare, targetSquare, PromoteToRook, Capture))
        list.add(createMove(startSquare, targetSquare, PromoteToQueen, Capture))


func addPawnMoves(list: var MoveList, side: static PieceColor, position: Position, inCheckFilter: Bitboard, flags: MovegenFlags) {.inline.} =
    const
        ourRank3BB = getRankMask(getRelativeRank(side, 2))
        ourRank7BB = getSeventhRank(side)
        push = when side == White: 8 else: -8
        diag0 = when side == White: 7 else: -7
        diag1 = when side == White: 9 else: -9

    let
        nonSideToMove = side.opposite()
        emptySquares = not position.getOccupancy()
        ourPawnsNot7 = position.getBitboard(Pawn, side) and not ourRank7BB
        ourPawns7 = position.getBitboard(Pawn, side) and ourRank7BB

    if (flags.uint8 and Quiet.uint8) == Quiet.uint8:
        # Single and double pushes
        var push1 = ourPawnsNot7.forwardRelativeTo(side) and emptySquares
        var push2 = (push1 and ourRank3BB).forwardRelativeTo(side) and emptySquares and inCheckFilter
        push1 = push1 and inCheckFilter

        while push1.isNotEmpty():
            let to = push1.popLowestBit().toSquare()
            list.add(createMove(to - push, to, Default))

        while push2.isNotEmpty():
            let to = push2.popLowestBit().toSquare()
            list.add(createMove(to - 2 * push, to, DoublePush))
    
    if (flags.uint8 and Noisy.uint8) == Noisy.uint8:
        # Normal pawn captures
        var cap0 = ourPawnsNot7.forwardLeftRelativeTo(side) and position.getOccupancyFor(nonSideToMove) and inCheckFilter
        var cap1 = ourPawnsNot7.forwardRightRelativeTo(side) and position.getOccupancyFor(nonSideToMove) and inCheckFilter
        
        while cap0.isNotEmpty():
            let to = cap0.popLowestBit().toSquare()
            list.add(createMove(to - diag0, to, Capture))
        
        while cap1.isNotEmpty():
            let to = cap1.popLowestBit().toSquare()
            list.add(createMove(to - diag1, to, Capture))

    if position.enPassantSquare != nullSquare():
        # En passant captures
        var ourPawnsTakeEp = ourPawnsNot7 and getPawnAttacks(nonSideToMove, position.enPassantSquare)

        while ourPawnsTakeEp.isNotEmpty():
            let sq = ourPawnsTakeEp.popLowestBit().toSquare()
            list.add(createMove(sq, position.enPassantSquare, EnPassant))
    
    block:
        # Promotions
        var push1 = ourPawns7.forwardRelativeTo(side) and emptySquares and inCheckFilter

        var cap0 = ourPawns7.forwardLeftRelativeTo(side) and position.getOccupancyFor(nonSideToMove) and inCheckFilter
        var cap1 = ourPawns7.forwardRightRelativeTo(side) and position.getOccupancyFor(nonSideToMove) and inCheckFilter

        while cap0.isNotEmpty():
            let to = cap0.popLowestBit().toSquare()
            list.addPromotions(to - diag0, to, true)

        while cap1.isNotEmpty():
            let to = cap1.popLowestBit().toSquare()
            list.addPromotions(to - diag1, to, true)
        
        while push1.isNotEmpty():
            let to = push1.popLowestBit().toSquare()
            list.addPromotions(to - push, to, false)


proc generateMoves*(self: Position, flags: MovegenFlags, moves: var MoveList) {.inline.} =
    ## Generates pseudo-legal moves according to the provided flags
    let
        sideToMove = self.sideToMove
        nonSideToMove = sideToMove.opposite()
        friendlyKing = self.getBitboard(King, sideToMove).toSquare()
        friendlyPieces = self.getOccupancyFor(sideToMove)
        enemyPieces = self.getOccupancyFor(nonSideToMove)
        occupancy = friendlyPieces or enemyPieces
        kingSq = self.getBitboard(King, sideToMove).toSquare()
        pinned = friendlyPieces and self.kingBlockers[sideToMove]

    var targets = Bitboard(0)
    if (flags.uint8 and Quiet.uint8) == Quiet.uint8:
        targets = not occupancy
    if (flags.uint8 and Noisy.uint8) == Noisy.uint8:
        targets = targets or enemyPieces
    
    var inCheckFilter = not Bitboard(0)

    if self.inCheck():
        if self.checkers.countSquares() > 1:
            # We are in double check: we can
            # only escape it by moving the king
            let moveset = getKingMoves(friendlyKing) and targets
            let captures = moveset and enemyPieces
            let quiets = moveset and not captures
            moves.addDefaultMoves(friendlyKing, quiets, true)
            moves.addDefaultMoves(friendlyKing, captures, true)
            return
        # The only legal moves are those which
        # block the check or capture the checking
        # piece
        inCheckFilter = getRayBetween(friendlyKing, self.checkers.lowestBit().toSquare()) or (enemyPieces and self.checkers)

    if sideToMove == White:
        moves.addPawnMoves(White, self, inCheckFilter, flags)
    else:
        moves.addPawnMoves(Black, self, inCheckFilter, flags)

    if (flags.uint8 and Quiet.uint8) == Quiet.uint8 and not self.inCheck():
        for queenSide in [false, true]:
            let castleableRook = self.castlingAvailability[sideToMove][queenSide]
            if castleableRook != nullSquare():
                let
                    (kingDst, rookDst) = CASTLING_DESTINATIONS[queenSide][sideToMove]
                    # Path from king start square to castling target (inclusive)
                    kingPath = getRayBetween(kingSq, kingDst) or kingDst.toBitboard()
                    # Path from castleable rook to castling target (inclusive)
                    rookPath = getRayBetween(castleableRook, rookDst) or rookDst.toBitboard()
                    # Remove king and rook from occupancy to check for any blockers
                    newOcc = occupancy xor self.getBitboard(King, sideToMove) xor castleableRook.toBitboard()

                if (kingPath and newOcc).isEmpty() and (rookPath and newOcc).isEmpty():
                    moves.add(createMove(kingSq, castleableRook, Castle))


    let pieceTargets = targets and inCheckFilter

    var knights = friendlyPieces and self.getBitboard(Knight) and not pinned
    while knights.isNotEmpty():
        let knight = knights.popLowestBit().toSquare()
        let attacks = getKnightMoves(knight) and pieceTargets

        let captures = attacks and enemyPieces
        let quiets = attacks and not captures
        moves.addDefaultMoves(knight, quiets, false)
        moves.addDefaultMoves(knight, captures, true)
    
    var bishops = friendlyPieces and (self.getBitboard(Queen) or self.getBitboard(Bishop))
    while bishops.isNotEmpty():
        let bishopBB = bishops.popLowestBit()
        let bishopSq = bishopBB.toSquare()
        var attacks = getBishopMoves(bishopSq, occupancy) and pieceTargets

        # Slider is pinned: can only move along the pinray
        if pinned.contains(bishopBB):
            attacks = attacks and getRayIntersecting(kingSq, bishopSq)
        
        let captures = attacks and enemyPieces
        let quiets = attacks and not captures
        moves.addDefaultMoves(bishopSq, quiets, false)
        moves.addDefaultMoves(bishopSq, captures, true)


    var rooks = friendlyPieces and (self.getBitboard(Queen) or self.getBitboard(Rook))
    while rooks.isNotEmpty():
        let rookBB = rooks.popLowestBit()
        let rookSq = rookBB.toSquare()
        var attacks = getRookMoves(rookSq, occupancy) and pieceTargets

        if pinned.contains(rookBB):
            attacks = attacks and getRayIntersecting(kingSq, rookSq)
        
        let captures = attacks and enemyPieces
        let quiets = attacks and not captures
        moves.addDefaultMoves(rookSq, quiets, false)
        moves.addDefaultMoves(rookSq, captures, true)

    block:
        let attacks = getKingMoves(friendlyKing) and targets
        let captures = attacks and enemyPieces
        let quiets = attacks and not captures
    
        moves.addDefaultMoves(friendlyKing, quiets, false)
        moves.addDefaultMoves(friendlyKing, captures, true)



func canNullMove*(self: Chessboard): bool {.inline.} =
    ## Returns whether a null move can be made.
    ## Specifically, one cannot null move if a
    ## null move was already made previously or
    ## if the side to move is in check
    return not self.inCheck() and not self.position.fromNull


proc isCheckmate*(self: Chessboard): bool {.inline.} =
    ## Returns whether the game ended with a
    ## checkmate
    if not self.inCheck():
        return false
    var moves {.noinit.} = newMoveList()
    self.position.generateMoves(All, moves)
    return moves.len() == 0


proc isCheckmate*(self: Position): bool {.inline.} =
    ## Returns whether the game ended with a
    ## checkmate
    if not self.inCheck():
        return false
    var moves {.noinit.} = newMoveList()
    self.generateMoves(All, moves)
    return moves.len() == 0


proc isStalemate*(self: Chessboard): bool {.inline.} =
    ## Returns whether the game ended with a
    ## stalemate
    if self.inCheck():
        return false
    var moves {.noinit.} = newMoveList()
    self.position.generateMoves(All, moves)
    return moves.len() == 0


proc isStalemate*(self: Position): bool {.inline.} =
    ## Returns whether the game ended with a
    ## stalemate
    if self.inCheck():
        return false
    var moves {.noinit.} = newMoveList()
    self.generateMoves(All, moves)
    return moves.len() == 0


proc isDrawn*(self: Chessboard, ply: int): bool {.inline.} =
    ## Returns whether the given position is
    ## drawn
    if self.position.halfMoveClock >= 100:
        # Draw by 50 move rule. Note
        # that mate always takes priority
        # over the 50-move draw, so we need
        # to account for that
        return not self.isCheckmate()

    if self.isInsufficientMaterial():
        return true

    if self.drawnByRepetition(ply):
        return true


proc isGameOver*(self: Chessboard): bool {.inline.} =
    ## Returns whether the game is over either
    ## by checkmate, draw or repetition
    if self.isDrawn(0):
        return true
    # No need to check for checks: we allow both
    # stalemate and checkmate
    var moves {.noinit.} = newMoveList()
    self.position.generateMoves(All, moves)
    return moves.len() == 0


proc unmakeMove*(self: Chessboard) {.inline.} =
    ## Reverts to the previous board position
    if self.positions.len() == 0:
        return
    discard self.positions.pop()


## Testing stuff

import std/strformat
import std/strutils
import std/tables

import heimdall/datagen/marlinformat


proc testPiece(piece: Piece, kind: PieceKind, color: PieceColor) =
    doAssert piece.kind == kind and piece.color == color, &"expected piece of kind {kind} and color {color}, got {piece.kind} / {piece.color} instead"


proc testPieceCount(board: Chessboard, kind: PieceKind, color: PieceColor, count: int) =
    let pieces = board.positions[^1].countPieces(kind, color)
    doAssert pieces == count, &"expected {count} pieces of kind {kind} and color {color}, got {pieces} instead"


proc testPieceBitboard(bitboard: Bitboard, squares: openarray[Square]) =
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
        board.position.generateMoves(All, moves)
        for move in moves:
            if board.position.isLegal(move, true):
                board.doMove(move)
                let key = board.zobristKey
                board.unmakeMove()
                doAssert not hashes.contains(key), &"{fen} has zobrist collisions {move} -> {hashes[key]} (key is {key.uint64})"
                hashes[key] = move

    # Test detection of (some) draws by insufficient material
    for (fen, isDrawn) in drawnFens:
        doAssert newChessboardFromFEN(fen).isInsufficientMaterial() == isDrawn, &"insufficient material draw check failed for {fen} (expected {isDrawn})"

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
        testPiece(board.getPiece(loc), Pawn, White)
    for loc in ["a7", "b7", "c7", "d7", "e7", "f7", "g7", "h7"]:
        testPiece(board.getPiece(loc), Pawn, Black)
    # Rooks
    testPiece(board.getPiece("a1"), Rook, White)
    testPiece(board.getPiece("h1"), Rook, White)
    testPiece(board.getPiece("a8"), Rook, Black)
    testPiece(board.getPiece("h8"), Rook, Black)
    # Knights
    testPiece(board.getPiece("b1"), Knight, White)
    testPiece(board.getPiece("g1"), Knight, White)
    testPiece(board.getPiece("b8"), Knight, Black)
    testPiece(board.getPiece("g8"), Knight, Black)
    # Bishops
    testPiece(board.getPiece("c1"), Bishop, White)
    testPiece(board.getPiece("f1"), Bishop, White)
    testPiece(board.getPiece("c8"), Bishop, Black)
    testPiece(board.getPiece("f8"), Bishop, Black)
    # Kings
    testPiece(board.getPiece("e1"), King, White)
    testPiece(board.getPiece("e8"), King, Black)
    # Queens
    testPiece(board.getPiece("d1"), Queen, White)
    testPiece(board.getPiece("d8"), Queen, Black)

    # Ensure our bitboards match with the board
    let 
        whitePawns = board.getBitboard(Pawn, White)
        whiteKnights = board.getBitboard(Knight, White)
        whiteBishops = board.getBitboard(Bishop, White)
        whiteRooks = board.getBitboard(Rook, White)
        whiteQueens = board.getBitboard(Queen, White)
        whiteKing = board.getBitboard(King, White)
        blackPawns = board.getBitboard(Pawn, Black)
        blackKnights = board.getBitboard(Knight, Black)
        blackBishops = board.getBitboard(Bishop, Black)
        blackRooks = board.getBitboard(Rook, Black)
        blackQueens = board.getBitboard(Queen, Black)
        blackKing = board.getBitboard(King, Black)
        # TODO: Change these
        whitePawnSquares   =  [toSquare("a2"), toSquare("b2"), toSquare("c2"), toSquare("d2"), toSquare("e2"), toSquare("f2"), toSquare("g2"), toSquare("h2")]
        whiteKnightSquares =  [toSquare("b1"), toSquare("g1")]
        whiteBishopSquares =  [toSquare("c1"), toSquare("f1")]
        whiteRookSquares   =  [toSquare("a1"), toSquare("h1")]
        whiteQueenSquares  =  [toSquare("d1")]
        whiteKingSquares   =  [toSquare("e1")]
        blackPawnSquares   =  [toSquare("a7"), toSquare("b7"), toSquare("c7"), toSquare("d7"), toSquare("e7"), toSquare("f7"), toSquare("g7"), toSquare("h7")]
        blackKnightSquares =  [toSquare("b8"), toSquare("g8")]
        blackBishopSquares =  [toSquare("c8"), toSquare("f8")]
        blackRookSquares   =  [toSquare("a8"), toSquare("h8")]
        blackQueenSquares  =  [toSquare("d8")]
        blackKingSquares   =  [toSquare("e8")]


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
    doAssert board.drawnByRepetition(0)

    # Test the position serializer
    for i, fen in testFens:
        let eval: int16 = if i mod 2 == 0: 100 else: -100
        var board = newChessboardFromFEN(fen)
        let game = createMarlinFormatRecord(loadFEN(fen), board.sideToMove, eval)
        let rebuilt = game.toMarlinformat().fromMarlinformat()
        let newPos = rebuilt.position
        # We could just check that game == rebuilt but this allows a more granular error message
        try:
            doAssert game.eval == eval, &"{eval} != {game.eval}"
            doAssert game.wdl == rebuilt.wdl, &"{game.wdl} != {rebuilt.wdl}"
            doAssert game.position.pieces == newPos.pieces
            doAssert game.position.sideToMove == newPos.sideToMove, &"{game.position.sideToMove} != {newPos.sideToMove}"
            doAssert game.position.castlingAvailability == newPos.castlingAvailability, &"{game.position.castlingAvailability} != {newPos.castlingAvailability}"
            doAssert game.position.enPassantSquare == newPos.enPassantSquare, &"{game.position.enPassantSquare} != {newPos.enPassantSquare}"
            doAssert game.position.halfMoveClock == newPos.halfMoveClock, &"{game.position.halfMoveClock} != {newPos.halfMoveClock}"
            doAssert game.position.fullMoveCount == newPos.fullMoveCount, &"{game.position.fullMoveCount} != {newPos.fullMoveCount}"
            doAssert game.position.sideToMove == newPos.sideToMove, &"{game.position.sideToMove} != {newPos.sideToMove}"
            doAssert game.position.checkers == newPos.checkers, &"{game.position.checkers} != {newPos.checkers}"
            doAssert game.position.kingBlockers == newPos.kingBlockers, &"{game.position.kingBlockers} != {newPos.kingBlockers}"
            doAssert game.position.pinners == newPos.pinners, &"{game.position.pinners} != {newPos.pinners}"
            doAssert game.position.zobristKey == newPos.zobristKey, &"{game.position.zobristKey} != {newPos.zobristKey}"
            for sq in Square(0)..Square(63):
                if game.position.mailbox[sq] != newPos.mailbox[sq]:
                    echo &"Mailbox mismatch at {sq}: {game.position.mailbox[sq]} != {newPos.mailbox[sq]}"
                    break
        except AssertionDefect:
            echo &"Test failed for {game.position.toFEN()} -> {newPos.toFEN()}"
            raise getCurrentException()