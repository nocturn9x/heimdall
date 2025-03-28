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
import std/strformat
import std/strutils


import heimdall/bitboards
import heimdall/util/magics
import heimdall/pieces
import heimdall/util/zobrist
import heimdall/moves
import heimdall/util/rays

export bitboards, magics, pieces, zobrist, moves, rays


type 
    Position* = object
        ## A chess position
        
        # Castling availability. The square represents the location of the rook
        # with which the king can castle on either side
        castlingAvailability*: array[White..Black, tuple[queen, king: Square]]
        # Number of half moves since
        # last piece capture or pawn movement.
        # Used for the 50-move rule
        halfMoveClock*: uint8
        # Full move counter. Increments
        # every 2 ply (half-moves)
        fullMoveCount*: uint16
        # En passant target square (see https://en.wikipedia.org/wiki/En_passant)
        enPassantSquare*: Square
        # The side to move
        sideToMove*: PieceColor
        # Positional bitboards for all pieces
        pieces*: array[White..Black, array[PieceKind.Pawn..PieceKind.King, Bitboard]]
        # Total occupancy by colors
        colors*: array[White..Black, Bitboard]
        # Pin rays for the current side to move
        diagonalPins*: Bitboard    # Rays from a bishop or queen
        orthogonalPins*: Bitboard  # Rays from a rook or queen
        # Pieces checking the current side to move
        checkers*: Bitboard
        # Zobrist hash of this position
        zobristKey*: ZobristKey
        # A mailbox for fast piece lookup by
        # location
        mailbox*: array[Square(0)..Square(63), Piece]
        # Does this position come from a null move?
        fromNull*: bool
        # Squares attacked by the non-side-to-move
        threats*: Bitboard


proc `=copy`(dest: var Position, source: Position)  {.error: "use clone() to explicitly copy Position objects!".}

proc clone*(pos: Position): Position =
  for fieldA, fieldB in fields(pos, result):
    fieldB = fieldA

proc toFEN*(self: Position): string {.gcsafe.}


func inCheck*(self: Position): bool {.inline.} =
    ## Returns if the current side to move is in check
    return not self.checkers.isEmpty()


func getBitboard*(self: Position, kind: PieceKind, color: PieceColor): Bitboard {.inline.} =
    ## Returns the positional bitboard for the given piece kind and color
    return self.pieces[color][kind]


func getBitboard*(self: Position, piece: Piece): Bitboard {.inline.} =
    ## Returns the positional bitboard for the given piece
    return self.getBitboard(piece.kind, piece.color)


func getBitboard*(self: Position, kind: PieceKind): Bitboard {.inline.} =
    ## Returns the positional bitboard for the given
    ## piece type, for both colors
    return self.pieces[White][kind] or self.pieces[Black][kind]

func getMaterial*(self: Position): int {.inline.} =
    ## Returns an integer representation of the
    ## material in the current position
    return self.getBitboard(Pawn).countSquares() +
           self.getBitboard(Bishop).countSquares() * 3 +
           self.getBitboard(Knight).countSquares() * 3 +
           self.getBitboard(Rook).countSquares() * 5 +
           self.getBitboard(Queen).countSquares() * 9


func getOccupancyFor*(self: Position, color: PieceColor): Bitboard {.inline.} =
    ## Get the occupancy bitboard for every piece of the given color
    result = self.colors[color]


func getOccupancy*(self: Position): Bitboard {.inline.} =
    ## Get the occupancy bitboard for every piece on
    ## the chessboard
    result = self.colors[White] or self.colors[Black]


proc getPawnAttackers*(self: Position, square: Square, attacker: PieceColor): Bitboard {.inline.} =
    ## Returns the locations of the pawns attacking the given square
    return self.getBitboard(Pawn, attacker) and getPawnAttackers(attacker, square)


proc getPawnAttackers*(self: Position, square: Square, attacker: PieceColor, occupancy: Bitboard): Bitboard {.inline.} =
    ## Returns the locations of the pawns attacking the given square
    ## with the given occupancy
    return (self.getBitboard(Pawn, attacker) and occupancy) and getPawnAttackers(attacker, square)


proc getKingAttacker*(self: Position, square: Square, attacker: PieceColor): Bitboard {.inline.} =
    ## Returns the location of the king if it is attacking the given square
    result = Bitboard(0)
    let king = self.getBitboard(King, attacker)
    if king.isEmpty():
        # The king was removed (probably by SEE or some
        # other internal machinery). This should never
        # occur during normal movegen!
        return
    if not (getKingMoves(king.toSquare()) and square.toBitboard()).isEmpty():
        return king


proc getKingAttacker*(self: Position, square: Square, attacker: PieceColor, occupancy: Bitboard): Bitboard {.inline.} =
    ## Returns the location of the king if it is attacking the given square
    ## given the provided occupancy
    result = Bitboard(0)
    let king = self.getBitboard(King, attacker) and occupancy
    if king.isEmpty():
        # The king is not included in the occupancy
        return
    if not (getKingMoves(king.toSquare()) and square.toBitboard()).isEmpty():
        return king


func getKnightAttackers*(self: Position, square: Square, attacker: PieceColor): Bitboard  {.inline.} =
    ## Returns the locations of the knights attacking the given square
    return getKnightMoves(square) and self.getBitboard(Knight, attacker)


func getKnightAttackers*(self: Position, square: Square, attacker: PieceColor, occupancy: Bitboard): Bitboard  {.inline.} =
    ## Returns the locations of the knights attacking the given square
    return getKnightMoves(square) and (self.getBitboard(Knight) and occupancy)


proc getSlidingAttackers*(self: Position, square: Square, attacker: PieceColor, occupancy: Bitboard): Bitboard {.inline.} =
    ## Returns the locations of the sliding pieces attacking the given square
    let
        queens = self.getBitboard(Queen, attacker)
        rooks = self.getBitboard(Rook, attacker) or queens
        bishops = self.getBitboard(Bishop, attacker) or queens
    
    result = getBishopMoves(square, occupancy) and (bishops or queens)
    result = result or getRookMoves(square, occupancy) and (rooks or queens)


proc getAttackersTo*(self: Position, square: Square, attacker: PieceColor): Bitboard {.inline.} =
    ## Computes the attackers bitboard for the given square from
    ## the given side
    result = self.getPawnAttackers(square, attacker)
    result = result or self.getKingAttacker(square, attacker)
    result = result or self.getKnightAttackers(square, attacker)
    result = result or self.getSlidingAttackers(square, attacker, self.getOccupancy())


proc getAttackersTo*(self: Position, square: Square, attacker: PieceColor, occupancy: Bitboard): Bitboard {.inline.} =
    ## Computes the attackers bitboard for the given square from
    ## the given side using the provided occupancy bitboard instead
    ## of the one in the position
    result = self.getPawnAttackers(square, attacker, occupancy)
    result = result or self.getKingAttacker(square, attacker, occupancy)
    result = result or self.getKnightAttackers(square, attacker, occupancy)
    result = result or self.getSlidingAttackers(square, attacker, occupancy)


proc getAttackersTo*(self: Position, square: Square, occupancy: Bitboard): Bitboard {.inline.} =
    ## Computes the attackers bitboard for the given square for both
    ## sides using the provided occupancy bitboard
    result = self.getPawnAttackers(square, White, occupancy) or self.getPawnAttackers(square, Black, occupancy)
    result = result or self.getKingAttacker(square, White, occupancy) or self.getKingAttacker(square, Black, occupancy)
    result = result or self.getKnightAttackers(square, White, occupancy) or self.getKnightAttackers(square, Black, occupancy)
    result = result or self.getSlidingAttackers(square, White, occupancy) or self.getSlidingAttackers(square, Black, occupancy)


proc getRelevantMoveset*(self: PieceKind, startSquare: Square, occupancy: Bitboard): Bitboard {.inline.} =
    ## Returns the relevant move set for the given piece
    ## type. Return value is undefined for pawns
    case self:
        of King:
            return getKingMoves(startSquare)
        of Knight:
            return getKnightMoves(startSquare)
        of Bishop:
            return getBishopMoves(startSquare, occupancy)
        of Rook:
            return getRookMoves(startSquare, occupancy)
        of Queen:
            return getBishopMoves(startSquare, occupancy) or getRookMoves(startSquare, occupancy)
        else:
            discard


proc isOccupancyAttacked*(self: Position, square: Square, occupancy: Bitboard): bool {.inline.} =
    ## Returns whether the given square would be attacked by the
    ## enemy side if the board had the given occupancy. This function
    ## is necessary, for example, to make sure sliding attacks can check the
    ## king properly: due to how we generate our attack bitboards, if
    ## the king moved backwards along a ray from a slider we would not
    ## consider it to be in check (because the ray stops at the first
    ## blocker). In order to fix that, in generateKingMoves() we use this
    ## function and pass in the board's occupancy without the moving king so
    ## that we can pick the correct magic bitboard and ray. Also, since this
    ## function doesn't need to generate all the attacks to know whether a 
    ## given square is unsafe, it can short circuit at the first attack and 
    ## exit early, unlike getAttackersTo
    let 
        nonSideToMove = self.sideToMove.opposite()
        knights = self.getBitboard(Knight, nonSideToMove)

    if not (getKnightMoves(square) and knights and occupancy).isEmpty():
        return true
    
    let king = self.getBitboard(King, nonSideToMove)

    if not (getKingMoves(square) and king and occupancy).isEmpty():
        return true

    if not self.getPawnAttackers(square, nonSideToMove, occupancy).isEmpty():
        return true

    let 
        queens = self.getBitboard(Queen, nonSideToMove)
        bishops = self.getBitboard(Bishop, nonSideToMove) or queens

    if not (getBishopMoves(square, occupancy) and bishops).isEmpty():
        return true

    let rooks = self.getBitboard(Rook, nonSideToMove) or queens

    if not (getRookMoves(square, occupancy) and rooks).isEmpty():
        return true


proc isAnyAttacked*(self: Position, squares, occupancy: Bitboard): bool =
    ## Similar to isOccupancyAttacked, but returns if any
    ## of the squares in the given bitboard are attacked
    ## by the enemy side
    for sq in squares:
        if self.isOccupancyAttacked(sq, occupancy):
            return true
    return false


func countPieces*(self: Position, kind: PieceKind, color: PieceColor): int {.inline.} =
    ## Returns the number of pieces with
    ## the given color and type in the
    ## position
    return self.pieces[color][kind].countSquares()


func getPiece*(self: Position, square: Square): Piece {.inline.} =
    ## Gets the piece at the given square in
    ## the position
    return self.mailbox[square]


func getPiece*(self: Position, square: string): Piece {.inline.} =
    ## Gets the piece on the given square
    ## in UCI notation
    return self.getPiece(square.toSquare())


func removePieceFromBitboard(self: var Position, square: Square) {.inline.} =
    ## Removes a piece at the given square from
    ## its respective bitboard
    let piece = self.getPiece(square)
    self.pieces[piece.color][piece.kind].clearBit(square)
    self.colors[piece.color].clearBit(square)


func addPieceToBitboard(self: var Position, square: Square, piece: Piece) {.inline.} =
    ## Adds the given piece at the given square to
    ## its respective bitboard
    self.pieces[piece.color][piece.kind].setBit(square)
    self.colors[piece.color].setBit(square)


proc spawnPiece*(self: var Position, square: Square, piece: Piece) {.inline.} =
    ## Spawns a new piece at the given square
    assert self.getPiece(square).kind == Empty
    self.addPieceToBitboard(square, piece)
    self.zobristKey = self.zobristKey xor piece.getKey(square)
    self.mailbox[square] = piece


proc removePiece*(self: var Position, square: Square) {.inline, gcsafe.} =
    ## Removes a piece from the board, updating necessary
    ## metadata
    let piece = self.getPiece(square)
    assert piece.kind != Empty and piece.color != None, self.toFEN()
    self.removePieceFromBitboard(square)
    self.zobristKey = self.zobristKey xor piece.getKey(square)
    self.mailbox[square] = nullPiece()


proc movePiece*(self: var Position, move: Move) {.inline.} =
    ## Internal helper to move a piece from
    ## its current square to a target square
    let piece = self.getPiece(move.startSquare)
    when defined(checks):
        let targetSquare = self.getPiece(move.targetSquare)
        if targetSquare.color != None:
            raise newException(AccessViolationDefect, &"{piece} at {move.startSquare} attempted to overwrite {targetSquare} at {move.targetSquare}: {move}")
    # Update positional metadata
    self.removePiece(move.startSquare)
    self.spawnPiece(move.targetSquare, piece)


proc movePiece*(self: var Position, startSquare, targetSquare: Square) {.inline.} =
    ## Moves a piece from the given start square to the given
    ## target square
    self.movePiece(createMove(startSquare, targetSquare))


func countPieces*(self: Position, piece: Piece): int {.inline.} =
    ## Returns the number of pieces in the position that
    ## are of the same type and color as the given piece
    return self.countPieces(piece.kind, piece.color)


# Note to self: toSquare() on strings is (probably) VERY bad for performance
const
    A1* = makeSquare(7, 0)
    H1* = makeSquare(7, 7)
    B1* = makeSquare(7, 1)
    H8* = makeSquare(0, 7)
    A8* = makeSquare(0, 0)
    B8* = makeSquare(0, 1)


proc queenSideCastleRay(position: Position, color: PieceColor): Bitboard {.inline.} =
    return getRayBetween(position.getBitboard(King, color).toSquare(), if color == White: B1 else: B8)

proc kingSideCastleRay(position: Position, color: PieceColor): Bitboard {.inline.} =
    return getRayBetween(position.getBitboard(King, color).toSquare(), if color == White: H1 else: H8)


proc canCastle*(self: Position): tuple[queen, king: Square] {.inline.} =
    ## Returns if the current side to move can castle
    if self.inCheck():
        return (nullSquare(), nullSquare())
    let sideToMove = self.sideToMove
    let kingSq = self.getBitboard(King, sideToMove).toSquare()
    let king = self.getPiece(kingSq)
    let occupancy = self.getOccupancy()
    result = self.castlingAvailability[sideToMove]

    if result.king != nullSquare():
        let rook = self.getPiece(result.king)
        # Mask off the rook we're castling with from the occupancy, as
        # it does not actually prevent castling. The majority of these
        # extra checks are necessary to support the extended castling
        # rules of chess960
        let occupancy = occupancy and not result.king.toBitboard() and not kingSq.toBitboard()
        let target = king.kingSideCastling().toBitboard()
        let kingRay = getRayBetween(result.king, king.kingSideCastling()) or king.kingSideCastling().toBitboard()
        let rookRay = getRayBetween(result.king, rook.kingSideCastling()) or rook.kingSideCastling().toBitboard()

        if (getRayBetween(result.king, kingSq) and occupancy).isEmpty() and (kingRay and occupancy).isEmpty() and (rookRay and occupancy).isEmpty():
            # There are no pieces in between our friendly king and
            # rook and between the friendly king/rook and their respective
            # destinations: now we check for attacks on the squares where
            # the king will have to move
            for square in self.kingSideCastleRay(sideToMove) or target:
                # The "or target" part is needed because rays exclude
                # their ends (so a ray from a1 to h1 does not include
                # either of them). We also need to make sure the target
                # square is not attacked, after all!
                if self.isOccupancyAttacked(square, occupancy):
                    result.king = nullSquare()
                    break
        else:
            result.king = nullSquare()

    if result.queen != nullSquare():
        let rook = self.getPiece(result.queen)
        let occupancy = occupancy and not result.queen.toBitboard() and not kingSq.toBitboard()
        let target = king.queenSideCastling().toBitboard()
        let kingRay = getRayBetween(result.queen, king.queenSideCastling()) or king.queenSideCastling().toBitboard()
        let rookRay = getRayBetween(result.queen, rook.queenSideCastling()) or rook.queenSideCastling().toBitboard()

        if (getRayBetween(result.queen, kingSq) and occupancy).isEmpty() and (kingRay and occupancy).isEmpty() and (rookRay and occupancy).isEmpty():
            for square in self.queenSideCastleRay(sideToMove) or target:
                if self.isOccupancyAttacked(square, occupancy):
                    result.queen = nullSquare()
                    break
        else:
            result.queen = nullSquare()


proc revokeQueenSideCastlingRights*(self: var Position, side: PieceColor) {.inline.} =
    ## Revokes the queenside castling rights for the given side
    if self.castlingAvailability[side].queen != nullSquare():
        self.castlingAvailability[side].queen = nullSquare()
        self.zobristKey = self.zobristKey xor getQueenSideCastlingKey(side)


proc revokeKingSideCastlingRights*(self: var Position, side: PieceColor) {.inline.} =
    ## Revokes the kingside castling rights for the given side
    if self.castlingAvailability[side].king != nullSquare():
        self.castlingAvailability[side].king = nullSquare()
        self.zobristKey = self.zobristKey xor getKingSideCastlingKey(side)


proc revokeCastlingRights*(self: var Position, side: PieceColor) {.inline.} =
    ## Revokes the castling rights for the given side
    self.revokeKingSideCastlingRights(side)
    self.revokeQueenSideCastlingRights(side)


proc updateChecksAndPins*(self: var Position) {.inline.} =
    ## Updates internal metadata about checks and
    ## pinned pieces
    
    # *Ahem*, stolen from https://github.com/Ciekce/voidstar/blob/424ac4624011271c4d1dbd743602c23f6dbda1de/src/position.rs
    # Can you tell I'm a *great* coder?
    let 
        sideToMove = self.sideToMove
        nonSideToMove = sideToMove.opposite()
        friendlyKing = self.getBitboard(King, sideToMove).toSquare()
        friendlyPieces = self.getOccupancyFor(sideToMove)
        enemyPieces = self.getOccupancyFor(nonSideToMove)
    
    # Update checks
    self.checkers = self.getAttackersTo(friendlyKing, nonSideToMove)
    # Update pins
    self.diagonalPins = Bitboard(0)
    self.orthogonalPins = Bitboard(0)

    let
        diagonalAttackers = self.getBitboard(Queen, nonSideToMove) or self.getBitboard(Bishop, nonSideToMove)
        orthogonalAttackers = self.getBitboard(Queen, nonSideToMove) or self.getBitboard(Rook, nonSideToMove)
        canPinDiagonally = diagonalAttackers and getBishopMoves(friendlyKing, enemyPieces)
        canPinOrthogonally = orthogonalAttackers and getRookMoves(friendlyKing, enemyPieces)

    for piece in canPinDiagonally:
        let pinningRay = getRayBetween(friendlyKing, piece) or piece.toBitboard()
        # Is the pinning ray obstructed by any of our friendly pieces? If so, the
        # piece is pinned
        if (pinningRay and friendlyPieces).countSquares() == 1:
            self.diagonalPins = self.diagonalPins or pinningRay

    for piece in canPinOrthogonally:
        let pinningRay = getRayBetween(friendlyKing, piece) or piece.toBitboard()
        if (pinningRay and friendlyPieces).countSquares() == 1:
            self.orthogonalPins = self.orthogonalPins or pinningRay
    
    self.threats = Bitboard(0)
    let occupancy = friendlyPieces or enemyPieces
    for square in enemyPieces:
        let piece = self.getPiece(square)
        case piece.kind:
            of Pawn:
                self.threats = self.threats or getPawnAttacks(nonSideToMove, square)
            of Rook:
                self.threats = self.threats or getRookMoves(square, occupancy)
            of Bishop:
                self.threats = self.threats or getBishopMoves(square, occupancy)
            of Knight:
                self.threats = self.threats or getKnightMoves(square)
            of King:
                self.threats = self.threats or getKingMoves(square)
            of Queen:
                self.threats = self.threats or (getBishopMoves(square, occupancy) or getRookMoves(square, occupancy))
            else:
                discard


proc hash*(self: var Position) = 
    ## Computes the zobrist hash of the position
    ## This only needs to be called when a position
    ## is loaded the first time, as all subsequent 
    ## hashes are updated incrementally at every 
    ## call to doMove()
    self.zobristKey = ZobristKey(0)

    if self.sideToMove == Black:
        self.zobristKey = self.zobristKey xor getBlackToMoveKey()

    for sq in self.getOccupancy():
        self.zobristKey = self.zobristKey xor self.getPiece(sq).getKey(sq)

    if self.castlingAvailability[White].king != nullSquare():
        self.zobristKey = self.zobristKey xor getKingSideCastlingKey(White)
    if self.castlingAvailability[White].queen != nullSquare():
        self.zobristKey = self.zobristKey xor getQueenSideCastlingKey(White)
    if self.castlingAvailability[Black].king != nullSquare():
        self.zobristKey = self.zobristKey xor getKingSideCastlingKey(Black)
    if self.castlingAvailability[Black].queen != nullSquare():
        self.zobristKey = self.zobristKey xor getQueenSideCastlingKey(Black)

    if self.enPassantSquare != nullSquare():
        self.zobristKey = self.zobristKey xor getEnPassantKey(fileFromSquare(self.enPassantSquare))


proc isEPLegal*(self: var Position, friendlyKing, epTarget: Square, occupancy, pawns: Bitboard, sideToMove: PieceColor): tuple[left, right: Square] =
    ## Checks if en passant is legal and returns the square of piece
    ## which can perform it on either side
    let epBitboard = if epTarget != nullSquare(): epTarget.toBitboard() else: Bitboard(0) 
    result.left = nullSquare()
    result.right = nullSquare() 
    if not epBitboard.isEmpty():
        # See if en passant would create a check
        let 
            # We don't and the destination mask with the ep target because we already check
            # whether the king ends up in check. TODO: Fix this in a more idiomatic way
            epPawn = epBitboard.backwardRelativeTo(sideToMove)
            epLeft = pawns.forwardLeftRelativeTo(sideToMove) and epBitboard
            epRight = pawns.forwardRightRelativeTo(sideToMove) and epBitboard
        # Note: it's possible for two pawns to both have rights to do an en passant! See 
        # 4k3/8/8/2PpP3/8/8/8/4K3 w - d6 0 1
        if not epLeft.isEmpty():
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
        if not epRight.isEmpty():
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


proc loadFEN*(fen: string): Position =
    ## Initializes a position from the given
    ## FEN string
    result = Position(enPassantSquare: nullSquare())
    result.castlingAvailability[White] = (nullSquare(), nullSquare())
    result.castlingAvailability[Black] = (nullSquare(), nullSquare())
    var
        # Current square in the grid
        row: int8 = 0
        column: int8 = 0
        # Current section in the FEN string
        section = 0
        # Current index into the FEN string
        index = 0
        # Temporary variable to store a piece
        piece: Piece
    
    # Make sure the mailbox is actually empty
    for sq in Square(0)..Square(63):
        result.mailbox[sq] = nullPiece()
        
    # See https://en.wikipedia.org/wiki/Forsyth%E2%80%93Edwards_Notation
    while index <= fen.high():
        var c = fen[index]
        if c == ' ':
            # Next section
            inc(section)
            inc(index)
            continue
        case section:
            of 0:
                # Piece placement data
                case c.toLowerAscii():
                    # Piece
                    of 'r', 'n', 'b', 'q', 'k', 'p':
                        let square = makeSquare(row, column)
                        piece = c.fromChar()
                        result.spawnPiece(square, piece)
                        inc(column)
                    of '/':
                        # Next row
                        inc(row)
                        column = 0
                    of '0'..'9':
                        # Skip x columns
                        let x = int(uint8(c) - uint8('0'))
                        if x > 8:
                            raise newException(ValueError, &"invalid FEN '{fen}': invalid column skip size ({x} > 8)")
                        column += int8(x)
                    else:
                        raise newException(ValueError, &"invalid FEN '{fen}': unknown piece identifier '{c}'")
            of 1:
                # Active color
                case c:
                    of 'w':
                        result.sideToMove = White
                    of 'b':
                        result.sideToMove = Black
                    else:
                        raise newException(ValueError, &"invalid FEN '{fen}': invalid active color identifier '{c}'")
            of 2:
                # Castling availability
                case c:
                    of '-':
                        discard
                    # Standard chess
                    of 'K':
                        result.castlingAvailability[White].king = H1
                    of 'Q':
                        result.castlingAvailability[White].queen = A1
                    of 'k':
                        result.castlingAvailability[Black].king = H8
                    of 'q':
                        result.castlingAvailability[Black].queen = A8
                    else:
                        # Chess960
                        let lower = c.toLowerAscii()
                        if lower notin 'a'..'h':
                            raise newException(ValueError, &"invalid FEN '{fen}': unknown symbol '{c}' found in castling availability section")
                        let color = if lower == c: Black else: White
                        # Construct castling destination
                        let rookSquare = makeSquare(if color == Black: 0 else: 7, (lower.uint8 - 97).int)
                        let king = result.getBitboard(King, color).toSquare()
                        if rookSquare < king:
                            # Queenside
                            result.castlingAvailability[color].queen = rookSquare
                        else:
                            # Kingside
                            result.castlingAvailability[color].king = rookSquare
            of 3:
                # En passant target square
                case c:
                    of '-':
                        # Field is already uninitialized to the correct state
                        discard
                    else:
                        result.enPassantSquare = fen[index..index+1].toSquare()
                        # Square metadata is 2 bytes long
                        inc(index)
            of 4:
                # Halfmove clock
                var s = ""
                while not fen[index].isSpaceAscii():
                    s.add(fen[index])
                    inc(index)
                    # Handle FENs with no full move number
                    # (implicit 0)
                    if index > fen.high():
                        break
                # Backtrack so the space is seen by the
                # next iteration of the loop
                dec(index)
                result.halfMoveClock = parseInt(s).uint8
            of 5:
                # Fullmove number
                var s = ""
                while index <= fen.high():
                    s.add(fen[index])
                    inc(index)
                result.fullMoveCount = parseInt(s).uint16
            else:
                raise newException(ValueError, &"invalid FEN '{fen}': too many fields in FEN string")
        inc(index)

    doAssert result.getBitboard(King, White).countSquares() == 1, &"invalid FEN '{fen}': exactly one king of each color is expected"
    doAssert result.getBitboard(King, Black).countSquares() == 1, &"invalid FEN '{fen}': exactly one king of each color is expected"

    # This makes Heimdall support X-FEN (possibly one of the most retarded things I've heard of in this field)
    # since some developers are clearly too lazy to support the far more sensible Shredder notation for chess960
    for color in White..Black:
        let kingSq = result.getBitboard(King, color).toSquare()
        # Find the correct castleable rooks for this side
        var
            current = kingSq
            direction = -1
            next = nullSquare()
            lastRook = nullSquare()
        if result.castlingAvailability[color].queen != nullSquare():
            # Left for the queenside, right for the kingside
            while rankFromSquare(current) == rankFromSquare(kingSq):
                next = makeSquare(rankFromSquare(current).int, fileFromSquare(current).int + direction)
                # We need this check to avoid overflowing to a different rank
                if not next.isValid() or rankFromSquare(next) != rankFromSquare(kingSq):
                    break
                let piece = result.getPiece(next)
                if piece.color == color and piece.kind == Rook:
                    lastRook = next
                current = next
            result.castlingAvailability[color].queen = lastRook

        if result.castlingAvailability[color].king != nullSquare():
            current = kingSq
            next = nullSquare()
            lastRook = nullSquare()
            direction = 1
            while true:
                next = makeSquare(rankFromSquare(current).int, fileFromSquare(current).int + direction)
                if not next.isValid() or rankFromSquare(next) != rankFromSquare(kingSq):
                    break
                let piece = result.getPiece(next)
                if piece.color == color and piece.kind == Rook:
                    lastRook = next
                current = next
            result.castlingAvailability[color].king = lastRook

    # Check EP legality. Since we don't trust the source of the FEN, 
    # they might not be handling en passant with quite the same strictness
    # as we do. Since this doesn't actually affect any functionality, we're
    # lenient and don't error out if we find out ep is actually not legal
    # here (just resetting the ep target)
    let 
        epTarget = result.enPassantSquare
        pawns = result.getBitboard(Pawn, result.sideToMove)
        occupancy = result.getOccupancy()
        kingSq = result.getBitboard(King, result.sideToMove).toSquare()
    let legality = result.isEPLegal(kingSq, epTarget, occupancy, pawns, result.sideToMove)
    if legality.left == nullSquare() and legality.right == nullSquare():
        result.enPassantSquare = nullSquare()
    result.updateChecksAndPins()
    result.hash()


proc startpos*: Position = loadFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")


proc `$`*(self: Position): string =
    result &= "- - - - - - - -"
    var file = 8
    for i in 0..7:
        result &= "\n"
        for j in 0..7:
            let piece = self.mailbox[makeSquare(i, j)]
            if piece.kind == Empty:
                result &= "x "
                continue
            result &= &"{piece.toChar()} "
        result &= &"{file}"
        dec(file)
    result &= "\n- - - - - - - -"
    result &= "\na b c d e f g h"


proc toFEN*(self: Position): string =
    ## Returns a FEN string of the
    ## position
    var skip: int
    # Piece placement data
    for i in 0..7:
        skip = 0
        for j in 0..7:
            let piece = self.mailbox[makeSquare(i, j)]
            if piece.kind == Empty:
                inc(skip)
            elif skip > 0:
                result &= &"{skip}{piece.toChar()}"
                skip = 0
            else:
                result &= piece.toChar()
        if skip > 0:
            result &= $skip
        if i < 7:
            result &= "/"
    result &= " "
    # Active color
    result &= (if self.sideToMove == White: "w" else: "b")
    result &= " "
    # Castling availability
    let castleWhite = self.castlingAvailability[White]
    let castleBlack = self.castlingAvailability[Black]
    if not (castleBlack.king != nullSquare() or castleBlack.queen != nullSquare() or castleWhite.king != nullSquare() or castleWhite.queen != nullSquare()):
        result &= "-"
    else:
        let kings: array[White..Black, Square] = [self.getBitboard(King, White).toSquare(), self.getBitboard(King, Black).toSquare()]
        if castleWhite.king != nullSquare():
            if castleWhite.king == H1 and abs(fileFromSquare(kings[White]).int - fileFromSquare(castleWhite.king).int) > 1:
                result &= "K"
            else:
                result &= castleWhite.king.toUCI()[0].toUpperAscii()
        if castleWhite.queen != nullSquare():
            if castleWhite.queen == A1 and abs(fileFromSquare(kings[White]).int - fileFromSquare(castleWhite.queen).int) > 1:
                result &= "Q"
            else:
                result &= castleWhite.queen.toUCI()[0].toUpperAscii()
        if castleBlack.king != nullSquare():
            if castleBlack.king == H8 and abs(fileFromSquare(kings[Black]).int - fileFromSquare(castleBlack.king).int) > 1:
                result &= "k"
            else:
                result &= castleBlack.king.toUCI()[0]
        if castleBlack.queen != nullSquare():
            if castleBlack.queen == A8 and abs(fileFromSquare(kings[Black]).int - fileFromSquare(castleBlack.queen).int) > 1:
                result &= "q"
            else:
                result &= castleBlack.queen.toUCI()[0]
    result &= " "
    # En passant target
    if self.enPassantSquare == nullSquare():
        result &= "-"
    else:
        result &= self.enPassantSquare.toUCI()
    result &= " "
    # Halfmove clock
    result &= $self.halfMoveClock
    result &= " "
    # Fullmove number
    result &= $self.fullMoveCount


proc pretty*(self: Position): string =
    ## Returns a colored version of the
    ## position for easier visualization
    var file = 8
    for i in 0..7:
        if i > 0:
            result &= "\n"
        for j in 0..7:
            # Equivalent to (i + j) mod 2
            # (I'm just evil)
            if ((i + j) and 1) == 0:
                result &= "\x1b[39;44;1m"
            else:
                result &= "\x1b[39;40;1m"
            let piece = self.mailbox[makeSquare(i, j)]
            if piece.kind == Empty:
                result &= "  \x1b[0m"
            else:
                result &= &"{piece.toPretty()} \x1b[0m"
        result &= &" \x1b[33;1m{file}\x1b[0m"
        dec(file)

    result &= "\n\x1b[31;1ma b c d e f g h"
    result &= "\x1b[0m"