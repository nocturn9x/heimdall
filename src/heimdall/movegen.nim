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

import std/[strformat, strutils, tables]

import heimdall/[board, moves, pieces, position, bitboards]
import heimdall/util/[rays, magics, marlinformat]


export bitboards, magics, pieces, moves, position, rays, board


proc generatePawnMoves(self: var Position, moves: var MoveList, destinationMask: Bitboard) =
    let
        sideToMove = self.sideToMove
        nonSideToMove = sideToMove.opposite()
        pawns = self.pieces(Pawn, sideToMove)
        occupancy = self.pieces()
        # We can only capture enemy pieces
        enemyPieces = self.pieces(nonSideToMove)
        epTarget = self.enPassantSquare
        diagonalPins = self.diagonalPins
        orthogonalPins = self.orthogonalPins
        promotionRank = sideToMove.eighthRank()
        startingRank = sideToMove.secondRank()
        friendlyKing = self.kingSquare(sideToMove)

    # If a pawn is pinned diagonally, it cannot push forward
    let
        # If a pawn is pinned horizontally, it cannot move either. It can move vertically
        # though. Thanks to Twipply for the tip on how to get a horizontal pin mask out of
        # our orthogonal bitboard :)
        horizontalPins = Bitboard((0xFF'u64 shl (rank(friendlyKing).uint8 * 8))) and orthogonalPins
        pushablePawns = pawns and not diagonalPins and not horizontalPins
        singlePushes = (pushablePawns.forward(sideToMove) and not occupancy) and destinationMask
    # We do this weird dance instead of using doubleForward() because that doesn't have any
    # way to check if there's pieces on the two squares ahead of the pawn and will just happily
    # let us phase through a piece
    var canDoublePush = pushablePawns and startingRank
    canDoublePush = canDoublePush.forward(sideToMove) and not occupancy
    canDoublePush = canDoublePush.forward(sideToMove) and not occupancy and destinationMask

    for pawn in singlePushes and not promotionRank:
        moves.add(createMove(pawn.toBitboard().backward(sideToMove), pawn))

    for pawn in singlePushes and promotionRank:
        for promotion in [PromotionBishop, PromotionKnight, PromotionRook, PromotionQueen]:
            moves.add(createMove(pawn.toBitboard().backward(sideToMove), pawn, promotion))

    for pawn in canDoublePush:
        moves.add(createMove(pawn.toBitboard().doubleBackward(sideToMove), pawn, DoublePush))

    let
        canCapture = pawns and not orthogonalPins
        canCaptureLeftUnpinned = (canCapture and not diagonalPins).forwardLeft(sideToMove) and enemyPieces and destinationMask
        canCaptureRightUnpinned = (canCapture and not diagonalPins).forwardRight(sideToMove) and enemyPieces and destinationMask

    for pawn in canCaptureRightUnpinned and not promotionRank:
        moves.add(createMove(pawn.toBitboard().backwardLeft(sideToMove), pawn, Capture))

    for pawn in canCaptureRightUnpinned and promotionRank:
        for promotion in [CapturePromotionBishop, CapturePromotionKnight, CapturePromotionRook, CapturePromotionQueen]:
            moves.add(createMove(pawn.toBitboard().backwardLeft(sideToMove), pawn, promotion))

    for pawn in canCaptureLeftUnpinned and not promotionRank:
        moves.add(createMove(pawn.toBitboard().backwardRight(sideToMove), pawn, Capture))

    for pawn in canCaptureLeftUnpinned and promotionRank:
        for promotion in [CapturePromotionBishop, CapturePromotionKnight, CapturePromotionRook, CapturePromotionQueen]:
            moves.add(createMove(pawn.toBitboard().backwardRight(sideToMove), pawn, promotion))

    # Special cases for pawns pinned diagonally that can capture their pinners

    let
        canCaptureLeft = canCapture.forwardLeft(sideToMove) and enemyPieces and destinationMask
        canCaptureRight = canCapture.forwardRight(sideToMove) and enemyPieces and destinationMask
        leftPinnedCanCapture = (canCaptureLeft and diagonalPins) and not canCaptureLeftUnpinned
        rightPinnedCanCapture = ((canCaptureRight and diagonalPins) and not canCaptureRightUnpinned) and not canCaptureRightUnpinned

    for pawn in leftPinnedCanCapture and not promotionRank:
        moves.add(createMove(pawn.toBitboard().backwardRight(sideToMove), pawn, Capture))

    for pawn in leftPinnedCanCapture and promotionRank:
        for promotion in  [CapturePromotionBishop, CapturePromotionKnight, CapturePromotionRook, CapturePromotionQueen]:
            moves.add(createMove(pawn.toBitboard().backwardRight(sideToMove), pawn, promotion))

    for pawn in rightPinnedCanCapture and not promotionRank:
        moves.add(createMove(pawn.toBitboard().backwardLeft(sideToMove), pawn, Capture))

    for pawn in rightPinnedCanCapture and promotionRank:
        for promotion in [CapturePromotionBishop, CapturePromotionKnight, CapturePromotionRook, CapturePromotionQueen]:
            moves.add(createMove(pawn.toBitboard().backwardLeft(sideToMove), pawn, promotion))

    let epLegality = self.isEPLegal(friendlyKing, epTarget, occupancy, pawns, sideToMove)
    if epLegality.left != nullSquare():
        moves.add(createMove(epLegality.left, epTarget, EnPassant))
    if epLegality.right != nullSquare():
        moves.add(createMove(epLegality.right, epTarget, EnPassant))


proc generateRookMoves(self: Position, moves: var MoveList, destinationMask: Bitboard) =
    let
        sideToMove = self.sideToMove
        occupancy = self.pieces()
        enemyPieces = self.pieces(sideToMove.opposite())
        rooks = self.pieces(Rook, sideToMove)
        queens = self.pieces(Queen, sideToMove)
        movableRooks = not self.diagonalPins and (queens or rooks)
        pinMask = self.orthogonalPins
        pinnedRooks = movableRooks and pinMask
        unpinnedRooks = movableRooks and not pinnedRooks

    for square in pinnedRooks:
        let
            moveset = rookMoves(square, occupancy)
        for target in moveset and pinMask and destinationMask and not enemyPieces:
            moves.add(createMove(square, target))
        for target in moveset and enemyPieces and pinMask and destinationMask:
            moves.add(createMove(square, target, Capture))

    for square in unpinnedRooks:
        let moveset = rookMoves(square, occupancy)
        for target in moveset and destinationMask and not enemyPieces:
            moves.add(createMove(square, target))
        for target in moveset and enemyPieces and destinationMask:
            moves.add(createMove(square, target, Capture))


proc generateBishopMoves(self: Position, moves: var MoveList, destinationMask: Bitboard) =
    let
        sideToMove = self.sideToMove
        occupancy = self.pieces()
        enemyPieces = self.pieces(sideToMove.opposite())
        bishops = self.pieces(Bishop, sideToMove)
        queens = self.pieces(Queen, sideToMove)
        movableBishops = not self.orthogonalPins and (queens or bishops)
        pinMask = self.diagonalPins
        pinnedBishops = movableBishops and pinMask
        unpinnedBishops = movableBishops and not pinnedBishops
    for square in pinnedBishops:
        let moveset = bishopMoves(square, occupancy)
        for target in moveset and pinMask and destinationMask and not enemyPieces:
            moves.add(createMove(square, target))
        for target in moveset and pinMask and enemyPieces and destinationMask:
            moves.add(createMove(square, target, Capture))
    for square in unpinnedBishops:
        let moveset = bishopMoves(square, occupancy)
        for target in moveset and destinationMask and not enemyPieces:
            moves.add(createMove(square, target))
        for target in moveset and enemyPieces and destinationMask:
            moves.add(createMove(square, target, Capture))


proc generateKingMoves(self: Position, moves: var MoveList, capturesOnly=false) =
    let
        sideToMove = self.sideToMove
        king = self.pieces(King, sideToMove)
        occupancy = self.pieces()
        nonSideToMove = sideToMove.opposite()
        enemyPieces = self.pieces(nonSideToMove)
        bitboard = kingMoves(king.toSquare())
        noKingOccupancy = occupancy and not king
    if not capturesOnly:
        for square in bitboard and not occupancy:
            if not self.isAttacked(square, noKingOccupancy):
                moves.add(createMove(king, square))
    for square in bitboard and enemyPieces:
        if not self.isAttacked(square, noKingOccupancy):
            moves.add(createMove(king, square, Capture))


proc generateKnightMoves(self: Position, moves: var MoveList, destinationMask: Bitboard) =
    let
        sideToMove = self.sideToMove
        knights = self.pieces(Knight, sideToMove)
        nonSideToMove = sideToMove.opposite()
        pinned = self.diagonalPins or self.orthogonalPins
        unpinnedKnights = knights and not pinned
        enemyPieces = self.pieces(nonSideToMove) and not self.pieces(King, nonSideToMove)
    for square in unpinnedKnights:
        let bitboard = knightMoves(square)
        for target in bitboard and destinationMask and not enemyPieces:
            moves.add(createMove(square, target))
        for target in bitboard and destinationMask and enemyPieces:
            moves.add(createMove(square, target, Capture))


proc generateCastling(self: Position, moves: var MoveList) =
    let
        sideToMove = self.sideToMove
        castlingRights = self.canCastle()
        kingSquare = self.kingSquare(sideToMove)
    if castlingRights.king != nullSquare():
        moves.add(createMove(kingSquare, castlingRights.king, ShortCastling))
    if castlingRights.queen != nullSquare():
        moves.add(createMove(kingSquare, castlingRights.queen, LongCastling))


proc generateMoves*(self: var Position, moves: var MoveList, capturesOnly: bool = false) {.inline.} =
    ## Generates the list of all possible legal moves
    ## in the current position. If capturesOnly is
    ## true, only capture moves are generated
    let
        sideToMove = self.sideToMove
        nonSideToMove = sideToMove.opposite()
    self.generateKingMoves(moves, capturesOnly)
    if self.checkers.count() > 1:
        # King is in double check: can only be resolved
        # by a king move
        return

    self.generateCastling(moves)

    # We pass a mask to our move generators to remove stuff
    # like our friendly pieces from the set of possible
    # target squares, as well as to ensure checks are not
    # ignored

    var destinationMask: Bitboard
    if not self.inCheck():
        # Not in check: cannot move over friendly pieces
        destinationMask = not self.pieces(sideToMove)
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
        destinationMask = rayBetween(checker, self.kingSquare(sideToMove)) or checkerBB
    if capturesOnly:
        # Note: This does not cover en passant (which is OK because it's a capture)
        destinationMask = destinationMask and self.pieces(nonSideToMove)
    self.generatePawnMoves(moves, destinationMask)
    self.generateKnightMoves(moves, destinationMask)
    self.generateRookMoves(moves, destinationMask)
    self.generateBishopMoves(moves, destinationMask)
    # Queens are just handled as rooks + bishops


proc generateMoves*(self: Chessboard, moves: var MoveList, capturesOnly=false) {.inline.} =
    self.positions[^1].generateMoves(moves, capturesOnly)


proc doMove*(self: Chessboard, move: Move) {.gcsafe.} =
    ## Internal function called by makeMove after
    ## performing legality checks. Can be used in
    ## performance-critical paths where a move is
    ## already known to be legal (i.e. during search)

    # Final checks
    let piece = self.on(move.startSquare)

    assert piece.kind != Empty and piece.color != None, &"{move} {self.toFEN()}"

    let
        sideToMove = piece.color
        nonSideToMove = sideToMove.opposite()
        kingSideRook = self.position.castlingAvailability[sideToMove].king
        queenSideRook = self.position.castlingAvailability[sideToMove].queen
        kingSq = self.position.kingSquare(sideToMove)
        king = self.on(kingSq)

    self.positions.add(self.position.clone())

    if piece.kind == Pawn or move.isCapture() or move.isEnPassant():
        self.positions[^1].halfMoveClock = 0
    else:
        inc(self.positions[^1].halfMoveClock)

    if piece.color == Black:
        inc(self.positions[^1].fullMoveCount)

    if move.isDoublePush():
        self.positions[^1].enPassantSquare = move.targetSquare.toBitboard().backward(piece.color).toSquare()
    else:
        self.positions[^1].enPassantSquare = nullSquare()

    self.positions[^1].sideToMove = nonSideToMove
    self.positions[^1].fromNull = false

    # I HATE EN PASSANT!!!!!!
    let previousEPTarget = self.positions[^2].enPassantSquare
    if previousEPTarget != nullSquare():
        self.positions[^1].zobristKey = self.position.zobristKey xor enPassantKey(file(previousEPTarget))

    if move.isEnPassant():
        let epPawnSquare = move.targetSquare.toBitboard().backward(sideToMove).toSquare()
        self.positions[^1].remove(epPawnSquare)

    if move.isCastling() or piece.kind == King:
        self.positions[^1].revokeCastling(sideToMove)

        if move.isCastling():
            # Castling is encoded as king takes own rook, hence the move's
            # target square is the rook's location!
            let
                rook = self.on(move.targetSquare)
                isKingSide = move.targetSquare == kingSideRook
                rookTarget = if isKingSide: rook.shortCastling() else: rook.longCastling()
                kingTarget = if isKingSide: king.shortCastling() else: king.longCastling()

            self.positions[^1].remove(kingSq)
            self.positions[^1].remove(move.targetSquare)
            self.positions[^1].spawn(rookTarget, rook)
            self.positions[^1].spawn(kingTarget, king)

    if piece.kind == Rook:
        if move.startSquare == kingSideRook:
            self.positions[^1].revokeShortCastling(sideToMove)

        if move.startSquare == queenSideRook:
            self.positions[^1].revokeLongCastling(sideToMove)

    if move.isCapture():
        let captured = self.on(move.targetSquare)
        self.positions[^1].remove(move.targetSquare)

        if captured.kind == Rook:
            let availability = self.position.castlingAvailability[nonSideToMove]

            if move.targetSquare == availability.king:
                self.positions[^1].revokeShortCastling(nonSideToMove)

            elif move.targetSquare == availability.queen:
                self.positions[^1].revokeLongCastling(nonSideToMove)

    if not move.isCastling() and not move.isPromotion():
        self.positions[^1].move(move)

    if move.isPromotion():
        self.positions[^1].remove(move.startSquare)
        self.positions[^1].spawn(move.targetSquare, Piece(color: piece.color, kind: move.flag().promotionToPiece()))

    if move.isDoublePush():
        let
            epTarget = self.position.enPassantSquare
            pawns = self.pieces(Pawn, nonSideToMove)
            occupancy = self.pieces()
            kingSq = self.position.kingSquare(nonSideToMove)
        # This is very minor, but technically a square is a valid en passant target only if an enemy
        # pawn can be captured by playing en passant. The only thing this changes is that we won't have
        # an ep square displayed in the FENs at every double push anymore (it should also make repetition
        # detection more reliable since we won't be considering an invalid ep target square in our zobrist
        # hashes)
        let legality = self.positions[^1].isEPLegal(kingSq, epTarget, occupancy, pawns, nonSideToMove)
        if legality.left == nullSquare() and legality.right == nullSquare():
            self.positions[^1].enPassantSquare = nullSquare()
        else:
            # EP is legal, update zobrist hash
            self.positions[^1].zobristKey = self.position.zobristKey xor enPassantKey(file(self.position.enPassantSquare))

    self.positions[^1].updateChecksAndPins()
    # Swap the side to move
    self.positions[^1].zobristKey = self.position.zobristKey xor blackToMoveKey()


proc isLegal*(self: Chessboard, move: Move): bool {.inline.} =
    var moves = newMoveList()
    self.generateMoves(moves)
    return move in moves


proc isLegal*(self: var Position, move: Move): bool {.inline.} =
    var moves = newMoveList()
    self.generateMoves(moves)
    return move in moves


proc makeMove*(self: Chessboard, move: Move): Move {.inline, discardable.} =
    result = move
    if not self.isLegal(move):
        return nullMove()
    self.doMove(move)


proc makeNullMove*(self: Chessboard) {.inline.} =
    ## Makes a "null" move, i.e. passes the turn
    ## to the opponent without making a move. This
    ## is obviously illegal and only to be used during
    ## search. The move can be undone via unmakeMove
    self.positions.add(self.position.clone())
    self.positions[^1].sideToMove = self.position.sideToMove.opposite()
    let previousEPTarget = self.positions[^2].enPassantSquare
    if previousEPTarget != nullSquare():
        self.positions[^1].zobristKey = self.position.zobristKey xor enPassantKey(file(previousEPTarget))
    self.positions[^1].enPassantSquare = nullSquare()
    self.positions[^1].fromNull = true
    self.positions[^1].updateChecksAndPins()
    self.positions[^1].zobristKey = self.position.zobristKey xor blackToMoveKey()
    self.positions[^1].halfMoveClock = 0


func canNullMove*(self: Chessboard): bool {.inline.} =
    return not self.inCheck() and not self.position.fromNull


proc isCheckmate*(self: Chessboard): bool {.inline.} =
    if not self.inCheck():
        return false
    var moves {.noinit.} = newMoveList()
    self.generateMoves(moves)
    return moves.len() == 0


proc isCheckmate*(self: var Position): bool {.inline.} =
    if not self.inCheck():
        return false
    var moves {.noinit.} = newMoveList()
    self.generateMoves(moves)
    return moves.len() == 0


proc isStalemate*(self: Chessboard): bool {.inline.} =
    if self.inCheck():
        return false
    var moves {.noinit.} = newMoveList()
    self.generateMoves(moves)
    return moves.len() == 0


proc isDrawn*(self: Chessboard, ply: int): bool {.inline.} =
    if self.position.halfMoveClock >= 100:
        # Draw by 50 move rule. Note that mate
        # always takes priority over the 50-move
        # draw, so we need to account for that
        return not self.isCheckmate()

    if self.isInsufficientMaterial():
        return true

    if self.drawnByRepetition(ply):
        return true


proc isGameOver*(self: Chessboard): bool {.inline.} =
    if self.isDrawn(0):
        return true
    var moves {.noinit.} = newMoveList()
    self.generateMoves(moves)
    return moves.len() == 0


proc unmakeMove*(self: Chessboard) {.inline.} =
    if self.positions.len() == 1:
        return
    discard self.positions.pop()


## Testing stuff

proc testPiece(piece: Piece, kind: PieceKind, color: PieceColor) =
    doAssert piece.kind == kind and piece.color == color, &"expected piece of kind {kind} and color {color}, got {piece.kind} / {piece.color} instead"

proc testPieceCount(board: Chessboard, kind: PieceKind, color: PieceColor, count: int) =
    let pieces = board.pieces(kind, color).count()
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

    for fen in testFens:
        let f = fromFEN(fen).toFEN()
        doAssert fen == f, &"{fen} != {f}"

    for fen in testFens:
        var
            board = newChessboardFromFEN(fen)
            hashes = newTable[ZobristKey, Move]()
            moves = newMoveList()
        board.generateMoves(moves)
        for move in moves:
            board.makeMove(move)
            let key = board.position.zobristKey
            board.unmakeMove()
            doAssert not hashes.contains(key), &"{fen} has zobrist collisions {move} -> {hashes[key]} (key is {key.uint64})"
            hashes[key] = move

    for (fen, isDrawn) in drawnFens:
        doAssert newChessboardFromFEN(fen).isInsufficientMaterial() == isDrawn, &"draw check failed for {fen} (expected {isDrawn})"

    var board = newDefaultChessboard()
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
        testPiece(board.on(loc), Pawn, White)
    for loc in ["a7", "b7", "c7", "d7", "e7", "f7", "g7", "h7"]:
        testPiece(board.on(loc), Pawn, Black)
    # Rooks
    testPiece(board.on("a1"), Rook, White)
    testPiece(board.on("h1"), Rook, White)
    testPiece(board.on("a8"), Rook, Black)
    testPiece(board.on("h8"), Rook, Black)
    # Knights
    testPiece(board.on("b1"), Knight, White)
    testPiece(board.on("g1"), Knight, White)
    testPiece(board.on("b8"), Knight, Black)
    testPiece(board.on("g8"), Knight, Black)
    # Bishops
    testPiece(board.on("c1"), Bishop, White)
    testPiece(board.on("f1"), Bishop, White)
    testPiece(board.on("c8"), Bishop, Black)
    testPiece(board.on("f8"), Bishop, Black)
    # Kings
    testPiece(board.on("e1"), King, White)
    testPiece(board.on("e8"), King, Black)
    # Queens
    testPiece(board.on("d1"), Queen, White)
    testPiece(board.on("d8"), Queen, Black)

    let
        whitePawns         = board.pieces(Pawn, White)
        whiteKnights       = board.pieces(Knight, White)
        whiteBishops       = board.pieces(Bishop, White)
        whiteRooks         = board.pieces(Rook, White)
        whiteQueens        = board.pieces(Queen, White)
        whiteKing          = board.pieces(King, White)
        blackPawns         = board.pieces(Pawn, Black)
        blackKnights       = board.pieces(Knight, Black)
        blackBishops       = board.pieces(Bishop, Black)
        blackRooks         = board.pieces(Rook, Black)
        blackQueens        = board.pieces(Queen, Black)
        blackKing          = board.pieces(King, Black)
        whitePawnSquares   = @[makeSquare(6, 0), makeSquare(6, 1), makeSquare(6, 2), makeSquare(6, 3), makeSquare(6, 4), makeSquare(6, 5), makeSquare(6, 6), makeSquare(6, 7)]
        whiteKnightSquares = @[makeSquare(7, 1), makeSquare(7, 6)]
        whiteBishopSquares = @[makeSquare(7, 2), makeSquare(7, 5)]
        whiteRookSquares   = @[makeSquare(7, 0), makeSquare(7, 7)]
        whiteQueenSquares  = @[makeSquare(7, 3)]
        whiteKingSquares   = @[makeSquare(7, 4)]
        blackPawnSquares   = @[makeSquare(1, 0), makeSquare(1, 1), makeSquare(1, 2), makeSquare(1, 3), makeSquare(1, 4), makeSquare(1, 5), makeSquare(1, 6), makeSquare(1, 7)]
        blackKnightSquares = @[makeSquare(0, 1), makeSquare(0, 6)]
        blackBishopSquares = @[makeSquare(0, 2), makeSquare(0, 5)]
        blackRookSquares   = @[makeSquare(0, 0), makeSquare(0, 7)]
        blackQueenSquares  = @[makeSquare(0, 3)]
        blackKingSquares   = @[makeSquare(0, 4)]


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

    for move in ["b1c3", "g8f6", "c3b1", "f6g8", "b1c3", "g8f6", "c3b1", "f6g8"]:
        board.makeMove(createMove(move[0..1].toSquare(), move[2..3].toSquare()))
    doAssert board.drawnByRepetition(0)

    var available = newMoveList()
    for fen in testFens:
        var board = newChessboardFromFEN(fen)
        var eval: int16
        for i in countup(0, 3):
            board.generateMoves(available)
            board.doMove(available[0])
            if (i and 1) == 0:
                eval = 100
            else:
                eval = -100
            let game = createMarlinFormatRecord(board.position, board.sideToMove, eval)
            let rebuilt = game.toMarlinformat().fromMarlinformat()
            let newPos = rebuilt.position
            # We could just check that game == rebuilt, but this allows a more granular error message
            try:
                doAssert game.eval == eval, &"{eval} != {game.eval}"
                doAssert game.wdl == rebuilt.wdl, &"{game.wdl} != {rebuilt.wdl}"
                doAssert game.position.pieces == newPos.pieces
                doAssert game.position.castlingAvailability == newPos.castlingAvailability, &"{game.position.castlingAvailability} != {newPos.castlingAvailability}"
                doAssert game.position.enPassantSquare == newPos.enPassantSquare, &"{game.position.enPassantSquare} != {newPos.enPassantSquare}"
                doAssert game.position.halfMoveClock == newPos.halfMoveClock, &"{game.position.halfMoveClock} != {newPos.halfMoveClock}"
                doAssert game.position.fullMoveCount == newPos.fullMoveCount, &"{game.position.fullMoveCount} != {newPos.fullMoveCount}"
                doAssert game.position.sideToMove == newPos.sideToMove, &"{game.position.sideToMove} != {newPos.sideToMove}"
                doAssert game.position.checkers == newPos.checkers, &"{game.position.checkers} != {newPos.checkers}"
                doAssert game.position.orthogonalPins == newPos.orthogonalPins, &"{game.position.orthogonalPins} != {newPos.orthogonalPins}"
                doAssert game.position.diagonalPins == newPos.diagonalPins, &"{game.position.diagonalPins} != {newPos.diagonalPins}"
                doAssert game.position.zobristKey == newPos.zobristKey, &"{game.position.zobristKey} != {newPos.zobristKey}"
                for sq in Square.all():
                    doAssert game.position.mailbox[sq] == newPos.mailbox[sq], &"Mailbox mismatch at {sq}: {game.position.mailbox[sq]} != {newPos.mailbox[sq]}"
            except AssertionDefect:
                echo &"Test failed for {fen} -> {board.toFEN()}"
                raise getCurrentException()
            available.clear()
