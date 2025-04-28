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
        # with which the king can castle with. true == queenside castling, false
        # == kingside castling
        castlingAvailability*: array[White..Black, array[bool, Square]]
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
        pieces*: array[White..Black, array[Pawn..King, Bitboard]]
        # Total occupancy by colors
        colors*: array[White..Black, Bitboard]
        # White pieces pinning black pieces and
        # vice-versa
        pinners*: array[White..Black, Bitboard]
        # Any pieces standing in front of the king.
        # Can either be friendly pieces (so they'd
        # be pinned), or enemy pieces (potential 
        # discovered checks)
        kingBlockers*: array[White..Black, Bitboard]
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


proc `=copy`(dest: var Position, source: Position) {.error: "use clone() to explicitly copy Position objects!".}

proc clone*(pos: Position): Position =
  for fieldA, fieldB in fields(pos, result):
    fieldB = fieldA

proc toFEN*(self: Position): string {.gcsafe.}


func inCheck*(self: Position): bool {.inline.} =
    ## Returns if the current side to move is in check
    return self.checkers.isNotEmpty()


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
    if (getKingMoves(king.toSquare()) and square.toBitboard()).isNotEmpty():
        return king


proc getKingAttacker*(self: Position, square: Square, attacker: PieceColor, occupancy: Bitboard): Bitboard {.inline.} =
    ## Returns the location of the king if it is attacking the given square
    ## given the provided occupancy
    result = Bitboard(0)
    let king = self.getBitboard(King, attacker) and occupancy
    if king.isEmpty():
        # The king is not included in the occupancy
        return
    if (getKingMoves(king.toSquare()) and square.toBitboard()).isNotEmpty():
        return king


func getKnightAttackers*(self: Position, square: Square, attacker: PieceColor): Bitboard  {.inline.} =
    ## Returns the locations of the knights attacking the given square
    return getKnightMoves(square) and self.getBitboard(Knight, attacker)


func getKnightAttackers*(self: Position, square: Square, attacker: PieceColor, occupancy: Bitboard): Bitboard  {.inline.} =
    ## Returns the locations of the knights attacking the given square
    return getKnightMoves(square) and (self.getBitboard(Knight, attacker) and occupancy)


proc getSlidingAttackers*(self: Position, square: Square, attacker: PieceColor, occupancy: Bitboard): Bitboard {.inline.} =
    ## Returns the locations of the sliding pieces attacking the given square
    let
        queens = self.getBitboard(Queen, attacker)
        rooks = self.getBitboard(Rook, attacker) or queens
        bishops = self.getBitboard(Bishop, attacker) or queens
    
    result = getBishopMoves(square, occupancy) and bishops
    result = result or (getRookMoves(square, occupancy) and rooks)


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
    ## enemy side if the board had the given occupancy. It also
    ## short-circuits at the first attack it detects and so should
    ## be slightly better than doing !getAttackersTo(square, occupancy).isEmpty()
    let nonSideToMove = self.sideToMove.opposite()

    if self.getKnightAttackers(square, nonSideToMove, occupancy).isNotEmpty():
        return true
    
    if self.getKingAttacker(square, nonSideToMove, occupancy).isNotEmpty():
        return true

    if self.getPawnAttackers(square, nonSideToMove, occupancy).isNotEmpty():
        return true

    if self.getSlidingAttackers(square, nonSideToMove, occupancy).isNotEmpty():
        return true

    return false


proc isAttacked*(self: Position, square: Square): bool {.inline.} =
    ## Returns whether the given square would be attacked by the
    ## enemy side in the given position. Identical to isOccupancyAttacked
    ## except is uses the current position's occupancy
    return self.isOccupancyAttacked(square, self.getOccupancy())


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


const
    A1* = toSquare("a1")
    H1* = toSquare("h1")
    B1* = toSquare("b1")
    H8* = toSquare("h8")
    A8* = toSquare("a8")
    B8* = toSquare("b8")
    # Indexed by [isQueenSide][kingColor]
    CASTLING_DESTINATIONS*: array[bool, array[White..Black, tuple[kingDst, rookDst: Square]]] = [[(G1, F1), (G8, F8)], [(C1, D1), (C8, D8)]]


proc revokeQueenSideCastlingRights*(self: var Position, side: PieceColor) {.inline.} =
    ## Revokes the queenside castling rights for the given side
    self.castlingAvailability[side][true] = nullSquare()
    self.zobristKey = self.zobristKey xor getQueenSideCastlingKey(side)


proc revokeKingSideCastlingRights*(self: var Position, side: PieceColor) {.inline.} =
    ## Revokes the kingside castling rights for the given side
    self.castlingAvailability[side][false] = nullSquare()
    self.zobristKey = self.zobristKey xor getKingSideCastlingKey(side)


proc revokeCastlingFor*(self: var Position, side: PieceColor, rook: Square) {.inline.} =
    ## Revokes the appropriate side castling for the given
    ## side to move given the castelable rook's location
    if self.castlingAvailability[side][true] == rook:
        self.revokeQueenSideCastlingRights(side)
    elif self.castlingAvailability[side][false] == rook:
        self.revokeKingSideCastlingRights(side)


proc revokeCastlingRights*(self: var Position, side: PieceColor) {.inline.} =
    ## Revokes the castling rights for the given side
    if self.castlingAvailability[side][false] != nullSquare():
        self.revokeKingSideCastlingRights(side)
    if self.castlingAvailability[side][true] != nullSquare():
        self.revokeQueenSideCastlingRights(side)


proc updatePins*(self: var Position, side: PieceColor) {.inline.} =
    ## Updates internal metadata about
    ## pinned pieces, pinners and blockers
    let
        opponent = side.opposite()
        occupancy = self.getOccupancy()
        friendlyPieces = self.getOccupancyFor(side)
        friendlyKing = self.getBitboard(King, side).toSquare()
    
    self.pinners[opponent] = Bitboard(0)
    self.kingBlockers[side] = Bitboard(0)

    var snipers = self.getSlidingAttackers(friendlyKing, opponent, occupancy xor friendlyPieces)
    let newOcc = occupancy xor snipers

    while snipers.isNotEmpty():
        let 
            sniperBB = snipers.popLowestBit()
            sniperSquare = sniperBB.toSquare()
            ray = getRayBetween(friendlyKing, sniperSquare) and newOcc
        
        if ray.countSquares() == 1:
            self.kingBlockers[side] = self.kingBlockers[side] or ray
            if (ray and friendlyPieces).isNotEmpty():
                self.pinners[opponent] = self.kingBlockers[opponent] or sniperBB


proc updateAttacks*(self: var Position) {.inline.} =
    ## Updates internal metadata about checks,
    ## pinned pieces and threathened squares
    
    # Mostly yoinked from Obsidian btw
    let 
        sideToMove = self.sideToMove
        nonSideToMove = sideToMove.opposite()
        friendlyKing = self.getBitboard(King, sideToMove).toSquare()
        enemyPieces = self.getOccupancyFor(nonSideToMove)

    # Update checkers for the current side to move
    self.checkers = self.getAttackersTo(friendlyKing, nonSideToMove)

    self.updatePins(sideToMove)
    self.updatePins(nonSideToMove)

    # Update threats by the opponent
    self.threats = Bitboard(0)
    let occupancy = self.getOccupancy()
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

    if self.castlingAvailability[White][false] != nullSquare():
        self.zobristKey = self.zobristKey xor getKingSideCastlingKey(White)
    if self.castlingAvailability[White][true] != nullSquare():
        self.zobristKey = self.zobristKey xor getQueenSideCastlingKey(White)
    if self.castlingAvailability[Black][false] != nullSquare():
        self.zobristKey = self.zobristKey xor getKingSideCastlingKey(Black)
    if self.castlingAvailability[Black][true] != nullSquare():
        self.zobristKey = self.zobristKey xor getQueenSideCastlingKey(Black)

    if self.enPassantSquare != nullSquare():
        self.zobristKey = self.zobristKey xor getEnPassantKey(fileFromSquare(self.enPassantSquare))


proc isEPLegal*(self: var Position, friendlyKing, epTarget: Square, occupancy, pawns: Bitboard, sideToMove: PieceColor): tuple[left, right: Square] =
    ## Checks if en passant is legal and returns the square of piece
    ## which can perform it on either side
    let epBitboard = if epTarget != nullSquare(): epTarget.toBitboard() else: Bitboard(0) 
    result.left = nullSquare()
    result.right = nullSquare() 
    if epBitboard.isNotEmpty():
        # See if en passant would create a check
        let 
            # We don't and the destination mask with the ep target because we already check
            # whether the king ends up in check. TODO: Fix this in a more idiomatic way
            epPawn = epBitboard.backwardRelativeTo(sideToMove)
            epLeft = pawns.forwardLeftRelativeTo(sideToMove) and epBitboard
            epRight = pawns.forwardRightRelativeTo(sideToMove) and epBitboard
        # Note: it's possible for two pawns to both have rights to do an en passant! See 
        # 4k3/8/8/2PpP3/8/8/8/4K3 w - d6 0 1
        if epLeft.isNotEmpty():
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
        if epRight.isNotEmpty():
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
    result.castlingAvailability[White] = [nullSquare(), nullSquare()]
    result.castlingAvailability[Black] = [nullSquare(), nullSquare()]
    var
        # Current square in the grid
        row: int8 = 7
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
                        dec(row)
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
                        result.castlingAvailability[White][false] = H1
                    of 'Q':
                        result.castlingAvailability[White][true] = A1
                    of 'k':
                        result.castlingAvailability[Black][false] = H8
                    of 'q':
                        result.castlingAvailability[Black][true] = A8
                    else:
                        # Chess960
                        let lower = c.toLowerAscii()
                        if lower notin 'a'..'h':
                            raise newException(ValueError, &"invalid FEN '{fen}': unknown symbol '{c}' found in castling availability section")
                        let color = if lower == c: Black else: White
                        # Construct castling destination
                        let rookSquare = makeSquare(if color == Black: 7 else: 0, (lower.uint8 - 97).int)
                        let king = result.getBitboard(King, color).toSquare()
                        if rookSquare < king:
                            # Queenside
                            result.castlingAvailability[color][true] = rookSquare
                        else:
                            # Kingside
                            result.castlingAvailability[color][false] = rookSquare
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
        if result.castlingAvailability[color][true] != nullSquare():
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
            result.castlingAvailability[color][true] = lastRook

        if result.castlingAvailability[color][false] != nullSquare():
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
            result.castlingAvailability[color][false] = lastRook

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
    result.updateAttacks()
    result.hash()


proc startpos*: Position = loadFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")


proc `$`*(self: Position): string =
    result &= "- - - - - - - -"
    for rank in countdown(7, 0):
        result &= "\n"
        for file in 0..7:
            let piece = self.mailbox[makeSquare(rank, file)]
            if piece.kind == Empty:
                result &= "x "
                continue
            result &= &"{piece.toChar()} "
        result &= &"| {rank + 1}"
    result &= "\n- - - - - - - -"
    result &= "\na b c d e f g h"


proc toFEN*(self: Position): string =
    ## Returns a FEN string of the
    ## position
    var skip: int
    # Piece placement data
    for i in countdown(7, 0):
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
        if i > 0:
            result &= "/"
    result &= " "
    # Active color
    result &= (if self.sideToMove == White: "w" else: "b")
    result &= " "
    # Castling availability
    let castleWhite = self.castlingAvailability[White]
    let castleBlack = self.castlingAvailability[Black]
    if not (castleBlack[false] != nullSquare() or castleBlack[true] != nullSquare() or castleWhite[false] != nullSquare() or castleWhite[true] != nullSquare()):
        result &= "-"
    else:
        let kings: array[White..Black, Square] = [self.getBitboard(King, White).toSquare(), self.getBitboard(King, Black).toSquare()]
        if castleWhite[false] != nullSquare():
            if castleWhite[false] == H1 and abs(fileFromSquare(kings[White]).int - fileFromSquare(castleWhite[false]).int) > 1:
                result &= "K"
            else:
                result &= castleWhite[false].toUCI()[0].toUpperAscii()
        if castleWhite[true] != nullSquare():
            if castleWhite[true] == A1 and abs(fileFromSquare(kings[White]).int - fileFromSquare(castleWhite[true]).int) > 1:
                result &= "Q"
            else:
                result &= castleWhite[true].toUCI()[0].toUpperAscii()
        if castleBlack[false] != nullSquare():
            if castleBlack[false] == H8 and abs(fileFromSquare(kings[Black]).int - fileFromSquare(castleBlack[false]).int) > 1:
                result &= "k"
            else:
                result &= castleBlack[false].toUCI()[0]
        if castleBlack[true] != nullSquare():
            if castleBlack[true] == A8 and abs(fileFromSquare(kings[Black]).int - fileFromSquare(castleBlack[true]).int) > 1:
                result &= "q"
            else:
                result &= castleBlack[true].toUCI()[0]
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
    for rank in countdown(7, 0):
        if rank < 7:
            result &= "\n"
        for file in 0..7:
            # Equivalent to (i + j) mod 2
            # (I'm just evil)
            if ((rank + file) and 1) == 0:
                result &= "\x1b[39;44;1m"
            else:
                result &= "\x1b[39;40;1m"
            let piece = self.mailbox[makeSquare(rank, file)]
            if piece.kind == Empty:
                result &= "  \x1b[0m"
            else:
                result &= &"{piece.toPretty()} \x1b[0m"
        result &= &" \x1b[33;1m{rank + 1}\x1b[0m"

    result &= "\n\x1b[31;1ma b c d e f g h"
    result &= "\x1b[0m"