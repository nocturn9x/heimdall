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
import std/[strformat, strutils]

import heimdall/[bitboards, moves, pieces as pcs]
import heimdall/util/[magics, rays, zobrist]


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
        pieces*: array[White..Black, array[Pawn..King, Bitboard]]
        # Total occupancy by colors
        colors*: array[White..Black, Bitboard]
        # Pin rays for the current side to move
        diagonalPins*: Bitboard    # Rays from a bishop or queen
        orthogonalPins*: Bitboard  # Rays from a rook or queen
        # Pieces checking the current side to move
        checkers*: Bitboard
        # Zobrist hash of this position
        zobristKey*: ZobristKey
        # Pawn-only Zobrist hash of this position
        pawnKey*: ZobristKey
        # Zobrist hashes of the non-pawn pieces for black and white
        nonpawnKeys*: array[White..Black, ZobristKey]
        # Zobrist hash of the major pieces (queens, rooks) and the
        # kings
        majorKey*: ZobristKey
        # Zobrist hash of the minor pieces (knights, bishops) and the
        # kings
        minorKey*: ZobristKey
        # A mailbox for fast piece lookup by
        # location
        mailbox*: array[Square.smallest()..Square.biggest(), Piece]
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
    return not self.checkers.isEmpty()

func pieces*(self: Position, kind: PieceKind, color: PieceColor): Bitboard {.inline.} =
    return self.pieces[color][kind]

func pieces*(self: Position, piece: Piece): Bitboard {.inline.} =
    return self.pieces(piece.kind, piece.color)

func pieces*(self: Position, kind: PieceKind): Bitboard {.inline.} =
    return self.pieces[White][kind] or self.pieces[Black][kind]

func pieces*(self: Position, color: PieceColor): Bitboard {.inline.} =
    result = self.colors[color]

func pieces*(self: Position): Bitboard {.inline.} =
    result = self.colors[White] or self.colors[Black]

func material*(self: Position): int {.inline.} =
    return self.pieces(Pawn).count() +
           self.pieces(Bishop).count() * 3 +
           self.pieces(Knight).count() * 3 +
           self.pieces(Rook).count() * 5 +
           self.pieces(Queen).count() * 9


proc pawnAttackers*(self: Position, square: Square, attackingSide: PieceColor): Bitboard {.inline.} =
    return self.pieces(Pawn, attackingSide) and pawnAttackers(attackingSide, square)

proc pawnAttackers*(self: Position, square: Square, attackingSide: PieceColor, occupancy: Bitboard): Bitboard {.inline.} =
    return (self.pieces(Pawn, attackingSide) and occupancy) and pawnAttackers(attackingSide, square)

func knightAttackers*(self: Position, square: Square, attackingSide: PieceColor): Bitboard  {.inline.} =
    return knightMoves(square) and self.pieces(Knight, attackingSide)

func knightAttackers*(self: Position, square: Square, attackingSide: PieceColor, occupancy: Bitboard): Bitboard  {.inline.} =
    return knightMoves(square) and (self.pieces(Knight, attackingSide) and occupancy)


proc kingAttacker*(self: Position, square: Square, attackingSide: PieceColor): Bitboard {.inline.} =
    let king = self.pieces(King, attackingSide)
    doAssert not king.isEmpty()
    if not (kingMoves(king.toSquare()) and square.toBitboard()).isEmpty():
        result = king


proc kingAttacker*(self: Position, square: Square, attackingSide: PieceColor, occupancy: Bitboard): Bitboard {.inline.} =
    let king = self.pieces(King, attackingSide) and occupancy
    doAssert not king.isEmpty()
    if not (kingMoves(king.toSquare()) and square.toBitboard()).isEmpty():
        result = king


proc slidingAttackers*(self: Position, square: Square, attackingSide: PieceColor, occupancy: Bitboard): Bitboard {.inline.} =
    let
        queens = self.pieces(Queen, attackingSide)
        rooks = self.pieces(Rook, attackingSide) or queens
        bishops = self.pieces(Bishop, attackingSide) or queens

    result = bishopMoves(square, occupancy) and (bishops or queens)
    result = result or rookMoves(square, occupancy) and (rooks or queens)


proc attackers*(self: Position, square: Square, attackingSide: PieceColor): Bitboard {.inline.} =
    ## Computes the attackers bitboard for the given square from
    ## the given side
    result = self.pawnAttackers(square, attackingSide)
    result = result or self.kingAttacker(square, attackingSide)
    result = result or self.knightAttackers(square, attackingSide)
    result = result or self.slidingAttackers(square, attackingSide, self.pieces())


proc attackers*(self: Position, square: Square, attackingSide: PieceColor, occupancy: Bitboard): Bitboard {.inline.} =
    ## Computes the attackers bitboard for the given square from
    ## the given side using the provided occupancy bitboard instead
    ## of the one in the position
    result = self.pawnAttackers(square, attackingSide, occupancy)
    result = result or self.kingAttacker(square, attackingSide, occupancy)
    result = result or self.knightAttackers(square, attackingSide, occupancy)
    result = result or self.slidingAttackers(square, attackingSide, occupancy)


proc attackers*(self: Position, square: Square, occupancy: Bitboard): Bitboard {.inline.} =
    ## Computes the attackers bitboard for the given square for both
    ## sides using the provided occupancy bitboard
    result = self.pawnAttackers(square, White, occupancy) or self.pawnAttackers(square, Black, occupancy)
    result = result or self.kingAttacker(square, White, occupancy) or self.kingAttacker(square, Black, occupancy)
    result = result or self.knightAttackers(square, White, occupancy) or self.knightAttackers(square, Black, occupancy)
    result = result or self.slidingAttackers(square, White, occupancy) or self.slidingAttackers(square, Black, occupancy)


proc isAttacked*(self: Position, square: Square, occupancy: Bitboard): bool {.inline.} =
    ## Returns whether the given square would be attacked by the
    ## enemy side if the board had the given occupancy. Since this
    ## function doesn't need to generate all the attacks to know
    ## whether a given square is unsafe, it can short circuit at
    ## the first attack and exit early, unlike attackers()
    let
        nonSideToMove = self.sideToMove.opposite()
        knights = self.pieces(Knight, nonSideToMove)

    if not (knightMoves(square) and knights and occupancy).isEmpty():
        return true

    let king = self.pieces(King, nonSideToMove)

    if not (kingMoves(square) and king and occupancy).isEmpty():
        return true

    if not self.pawnAttackers(square, nonSideToMove, occupancy).isEmpty():
        return true

    let
        queens = self.pieces(Queen, nonSideToMove)
        bishops = self.pieces(Bishop, nonSideToMove) or queens

    if not (bishopMoves(square, occupancy) and bishops).isEmpty():
        return true

    let rooks = self.pieces(Rook, nonSideToMove) or queens

    if not (rookMoves(square, occupancy) and rooks).isEmpty():
        return true


proc isAnyAttacked*(self: Position, squares, occupancy: Bitboard): bool =
    ## Similar to isAttacked, but returns if any
    ## of the squares in the given bitboard are attacked
    ## by the enemy side
    for sq in squares:
        if self.isAttacked(sq, occupancy):
            return true
    return false


func on*(self: Position, square: Square): Piece {.inline.} =
    return self.mailbox[square]

func on*(self: Position, square: string): Piece {.inline.} =
    return self.on(square.toSquare())


func removeFromBitboard(self: var Position, square: Square) {.inline.} =
    let piece = self.on(square)
    self.pieces[piece.color][piece.kind].clearBit(square)
    self.colors[piece.color].clearBit(square)


func addToBitboard(self: var Position, square: Square, piece: Piece) {.inline.} =
    self.pieces[piece.color][piece.kind].setBit(square)
    self.colors[piece.color].setBit(square)


func toggleKeys*(self: var Position, square: Square, piece: Piece) {.inline.} =
    let key = piece.getKey(square)
    self.zobristKey = self.zobristKey xor key
    if piece.kind == Pawn:
        self.pawnKey = self.pawnKey xor key
    else:
        self.nonpawnKeys[piece.color] = self.nonpawnKeys[piece.color] xor key
        if piece.kind in [Rook, Queen, King]:
            self.majorKey = self.majorKey xor key
        if piece.kind in [Knight, Bishop, King]:
            self.minorKey = self.minorKey xor key


proc spawn*(self: var Position, square: Square, piece: Piece) {.inline.} =
    assert self.on(square).kind == Empty
    self.addToBitboard(square, piece)
    self.toggleKeys(square, piece)
    self.mailbox[square] = piece


proc remove*(self: var Position, square: Square) {.inline, gcsafe.} =
    let piece = self.on(square)
    assert piece.kind != Empty and piece.color != None, self.toFEN()
    self.removeFromBitboard(square)
    self.toggleKeys(square, piece)
    self.mailbox[square] = nullPiece()


proc move*(self: var Position, move: Move) {.inline.} =
    let piece = self.on(move.startSquare)
    when defined(checks):
        let targetSquare = self.on(move.targetSquare)
        if targetSquare.color != None:
            raise newException(AccessViolationDefect, &"{piece} at {move.startSquare} attempted to overwrite {targetSquare} at {move.targetSquare}: {move}")
    # Update positional metadata
    self.remove(move.startSquare)
    self.spawn(move.targetSquare, piece)


proc move*(self: var Position, startSquare, targetSquare: Square) {.inline.} =
    self.move(createMove(startSquare, targetSquare))


# Note to self: toSquare() on strings is (probably) VERY bad for performance
const
    A1* = makeSquare(7, 0)
    H1* = makeSquare(7, 7)
    B1* = makeSquare(7, 1)
    H8* = makeSquare(0, 7)
    A8* = makeSquare(0, 0)
    B8* = makeSquare(0, 1)


proc longCastleRay(position: Position, color: PieceColor): Bitboard {.inline.} =
    return rayBetween(position.pieces(King, color).toSquare(), if color == White: B1 else: B8)

proc shortCastleRay(position: Position, color: PieceColor): Bitboard {.inline.} =
    return rayBetween(position.pieces(King, color).toSquare(), if color == White: H1 else: H8)


proc canCastle*(self: Position): tuple[queen, king: Square] {.inline.} =
    if self.inCheck():
        return (nullSquare(), nullSquare())
    let
        sideToMove = self.sideToMove
        kingSq     = self.pieces(King, sideToMove).toSquare()
        king       = self.on(kingSq)
        occupancy  = self.pieces()

    result = self.castlingAvailability[sideToMove]

    if result.king != nullSquare():
        let rook = self.on(result.king)
        # Mask off the rook we're castling with from the occupancy, as
        # it does not actually prevent castling. The majority of these
        # extra checks are necessary to support the extended castling
        # rules of chess960
        let
            occupancy = occupancy and not result.king.toBitboard() and not kingSq.toBitboard()
            target    = king.shortCastling().toBitboard()
            kingRay   = rayBetween(result.king, king.shortCastling()) or king.shortCastling().toBitboard()
            rookRay   = rayBetween(result.king, rook.shortCastling()) or rook.shortCastling().toBitboard()

        if (rayBetween(result.king, kingSq) and occupancy).isEmpty() and (kingRay and occupancy).isEmpty() and (rookRay and occupancy).isEmpty():
            # There are no pieces in between our friendly king and
            # rook and between the friendly king/rook and their respective
            # destinations: now we check for attacks on the squares where
            # the king will have to move
            for square in self.shortCastleRay(sideToMove) or target:
                # The "or target" part is needed because rays exclude
                # their ends (so a ray from a1 to h1 does not include
                # either of them). We also need to make sure the target
                # square is not attacked, after all!
                if self.isAttacked(square, occupancy):
                    result.king = nullSquare()
                    break
        else:
            result.king = nullSquare()

    if result.queen != nullSquare():
        let
            rook      = self.on(result.queen)
            occupancy = occupancy and not result.queen.toBitboard() and not kingSq.toBitboard()
            target    = king.longCastling().toBitboard()
            kingRay   = rayBetween(result.queen, king.longCastling()) or king.longCastling().toBitboard()
            rookRay   = rayBetween(result.queen, rook.longCastling()) or rook.longCastling().toBitboard()

        if (rayBetween(result.queen, kingSq) and occupancy).isEmpty() and (kingRay and occupancy).isEmpty() and (rookRay and occupancy).isEmpty():
            for square in self.longCastleRay(sideToMove) or target:
                if self.isAttacked(square, occupancy):
                    result.queen = nullSquare()
                    break
        else:
            result.queen = nullSquare()


proc revokeLongCastling*(self: var Position, side: PieceColor) {.inline.} =
    if self.castlingAvailability[side].queen != nullSquare():
        self.castlingAvailability[side].queen = nullSquare()
        self.zobristKey = self.zobristKey xor longCastlingKey(side)


proc revokeShortCastling*(self: var Position, side: PieceColor) {.inline.} =
    if self.castlingAvailability[side].king != nullSquare():
        self.castlingAvailability[side].king = nullSquare()
        self.zobristKey = self.zobristKey xor shortCastlingKey(side)


proc revokeCastling*(self: var Position, side: PieceColor) {.inline.} =
    self.revokeShortCastling(side)
    self.revokeLongCastling(side)


proc updateChecksAndPins*(self: var Position) {.inline.} =
    # *Ahem*, stolen from https://github.com/Ciekce/voidstar/blob/424ac4624011271c4d1dbd743602c23f6dbda1de/src/position.rs
    # Can you tell I'm a *great* coder?
    let
        sideToMove = self.sideToMove
        nonSideToMove = sideToMove.opposite()
        friendlyKing = self.pieces(King, sideToMove).toSquare()
        friendlyPieces = self.pieces(sideToMove)
        enemyPieces = self.pieces(nonSideToMove)

    self.checkers = self.attackers(friendlyKing, nonSideToMove)
    self.diagonalPins = Bitboard(0)
    self.orthogonalPins = Bitboard(0)

    let
        diagonalAttackers = self.pieces(Queen, nonSideToMove) or self.pieces(Bishop, nonSideToMove)
        orthogonalAttackers = self.pieces(Queen, nonSideToMove) or self.pieces(Rook, nonSideToMove)
        canPinDiagonally = diagonalAttackers and bishopMoves(friendlyKing, enemyPieces)
        canPinOrthogonally = orthogonalAttackers and rookMoves(friendlyKing, enemyPieces)

    for piece in canPinDiagonally:
        let pinningRay = rayBetween(friendlyKing, piece) or piece.toBitboard()
        # Is the pinning ray obstructed by any of our friendly pieces? If so, the
        # piece is pinned
        if (pinningRay and friendlyPieces).count() == 1:
            self.diagonalPins = self.diagonalPins or pinningRay

    for piece in canPinOrthogonally:
        let pinningRay = rayBetween(friendlyKing, piece) or piece.toBitboard()
        if (pinningRay and friendlyPieces).count() == 1:
            self.orthogonalPins = self.orthogonalPins or pinningRay

    self.threats = Bitboard(0)
    let occupancy = friendlyPieces or enemyPieces
    for square in enemyPieces:
        let piece = self.on(square)
        case piece.kind:
            of Pawn:
                self.threats = self.threats or pawnAttacks(nonSideToMove, square)
            of Rook:
                self.threats = self.threats or rookMoves(square, occupancy)
            of Bishop:
                self.threats = self.threats or bishopMoves(square, occupancy)
            of Knight:
                self.threats = self.threats or knightMoves(square)
            of King:
                self.threats = self.threats or kingMoves(square)
            of Queen:
                self.threats = self.threats or (bishopMoves(square, occupancy) or rookMoves(square, occupancy))
            else:
                discard


proc hash*(self: var Position) =
    ## Computes the various zobrist hashes of the
    ## position. This only needs to be called when
    ## a position is loaded the first time, as all
    ## subsequent hashes are updated incrementally
    ## at every call to doMove()
    self.zobristKey = ZobristKey(0)
    self.pawnKey = ZobristKey(0)
    self.nonpawnKeys = [ZobristKey(0), ZobristKey(0)]
    self.majorKey = ZobristKey(0)

    if self.sideToMove == Black:
        self.zobristKey = self.zobristKey xor blackToMoveKey()

    for sq in self.pieces():
        self.toggleKeys(sq, self.on(sq))

    if self.castlingAvailability[White].king != nullSquare():
        self.zobristKey = self.zobristKey xor shortCastlingKey(White)
    if self.castlingAvailability[White].queen != nullSquare():
        self.zobristKey = self.zobristKey xor longCastlingKey(White)
    if self.castlingAvailability[Black].king != nullSquare():
        self.zobristKey = self.zobristKey xor shortCastlingKey(Black)
    if self.castlingAvailability[Black].queen != nullSquare():
        self.zobristKey = self.zobristKey xor longCastlingKey(Black)

    if self.enPassantSquare != nullSquare():
        self.zobristKey = self.zobristKey xor enPassantKey(file(self.enPassantSquare))


proc isEPLegal*(self: var Position, friendlyKing, epTarget: Square, occupancy, pawns: Bitboard, sideToMove: PieceColor): tuple[left, right: Square] =
    ## Checks if en passant is legal and returns the square(s)
    ## of the pawn(s) which can perform it on either side
    let epBitboard = if epTarget != nullSquare(): epTarget.toBitboard() else: Bitboard(0)
    result.left = nullSquare()
    result.right = nullSquare()
    if not epBitboard.isEmpty():
        # See if en passant would create a check
        let
            # We don't and the destination mask with the ep target because we already check
            # whether the king ends up in check. TODO: Fix this in a more idiomatic way
            epPawn = epBitboard.backward(sideToMove)
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
            # our bitboards, or else functions like pawnAttacks won't
            # get the news that the pawn is gone and will still think the
            # king is in check after en passant when it actually isn't
            # (see pos fen rnbqkbnr/pppp1ppp/8/2P5/K7/8/PPPP1PPP/RNBQ1BNR b kq - 0 1 moves b7b5 c5b6)
            let epPawnSquare = epPawn.toSquare()
            let epPiece = self.on(epPawnSquare)
            self.remove(epPawnSquare)
            if not self.isAttacked(friendlyKing, newOccupancy):
                result.left = friendlyPawn.toSquare()
            self.spawn(epPawnSquare, epPiece)
        if not epRight.isEmpty():
            # Note that this isn't going to be the same pawn from the previous if block!
            let
                friendlyPawn = epBitboard.backwardLeftRelativeTo(sideToMove)
                newOccupancy = occupancy and not epPawn and not friendlyPawn or epBitboard
            let epPawnSquare = epPawn.toSquare()
            let epPiece = self.on(epPawnSquare)
            self.remove(epPawnSquare)
            if not self.isAttacked(friendlyKing, newOccupancy):
                result.right = friendlyPawn.toSquare()
            self.spawn(epPawnSquare, epPiece)


proc fromFEN*(fen: string): Position =
    result = Position(enPassantSquare: nullSquare())
    result.castlingAvailability[White] = (nullSquare(), nullSquare())
    result.castlingAvailability[Black] = (nullSquare(), nullSquare())
    var
        # Current square in the grid
        row = Rank(0)
        column = pcs.File(0)
        # Current section in the FEN string
        section = 0
        # Current index into the FEN string
        index = 0
        # Temporary variable to store a piece
        piece: Piece

    # Make sure the mailbox is actually empty
    for sq in Square.all():
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
                        result.spawn(square, piece)
                        inc(column)
                    of '/':
                        # Next row
                        inc(row)
                        column = pcs.File(0)
                    of '0'..'9':
                        # Skip x columns
                        let x = int(uint8(c) - uint8('0'))
                        if x > 8:
                            raise newException(ValueError, &"invalid FEN '{fen}': invalid file skip size ({x} > 8)")
                        if column + pcs.File(x - 1) < File.high():
                            # This ensures a file is never out of range (so
                            # this works in release mode with checks enabled)
                            column = column + pcs.File(x)
                        else:
                            # Skip a full file: if the FEN is well formed, we will encounter a / after this, so just
                            # zero out the file
                            column = pcs.File(0)
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
                        let rookSquare = makeSquare(if color == Black: Rank(0) else: Rank(7), pcs.File(lower.uint8 - 97))
                        let king = result.pieces(King, color).toSquare()
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

    doAssert result.pieces(King, White).count() == 1, &"invalid FEN '{fen}': exactly one king of each color is expected"
    doAssert result.pieces(King, Black).count() == 1, &"invalid FEN '{fen}': exactly one king of each color is expected"

    # This makes Heimdall support X-FEN (possibly one of the most retarded things I've heard of in this field)
    # since some developers are clearly too lazy to support the far more sensible Shredder notation for chess960
    for color in White..Black:
        let kingSq = result.pieces(King, color).toSquare()
        # Find the correct castleable rooks for this side
        var
            current = kingSq
            next = nullSquare()
            lastRook = nullSquare()
        if result.castlingAvailability[color].queen != nullSquare():
            # Left for the queenside, right for the kingside
            while rank(current) == rank(kingSq):
                # We convert to int here because when checks are on
                # we can't subtract from a file if it yields an illegal
                # value
                if file(current).int - 1 > File.high() or not isValidSquare(rank(current), file(current) - pcs.File(1)):
                    break
                next = makeSquare(rank(current), file(current) - pcs.File(1))
                # We need this check to avoid overflowing to a different rank
                if rank(next) != rank(kingSq):
                    break
                let piece = result.on(next)
                if piece.color == color and piece.kind == Rook:
                    lastRook = next
                current = next
            result.castlingAvailability[color].queen = lastRook

        if result.castlingAvailability[color].king != nullSquare():
            current = kingSq
            next = nullSquare()
            lastRook = nullSquare()
            while true:
                if file(current).int + 1 > File.high() or not isValidSquare(rank(current), file(current) + pcs.File(1)):
                    break
                next = makeSquare(rank(current), file(current) + pcs.File(1))
                if rank(next) != rank(kingSq):
                    break
                let piece = result.on(next)
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
        pawns = result.pieces(Pawn, result.sideToMove)
        occupancy = result.pieces()
        kingSq = result.pieces(King, result.sideToMove).toSquare()
    let legality = result.isEPLegal(kingSq, epTarget, occupancy, pawns, result.sideToMove)
    if legality.left == nullSquare() and legality.right == nullSquare():
        result.enPassantSquare = nullSquare()
    result.updateChecksAndPins()
    result.hash()


proc startpos*: Position = fromFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")


proc `$`*(self: Position): string =
    result &= "- - - - - - - -"
    var file = File.high()
    for rank in Rank.all():
        result &= "\n"
        for file in File.all():
            let piece = self.mailbox[makeSquare(rank, file)]
            if piece.kind == Empty:
                result &= "x "
                continue
            result &= &"{piece.toChar()} "
        result &= &"{file.uint8 + 1}"
        dec(file)
    result &= "\n- - - - - - - -"
    result &= "\na b c d e f g h"


proc toFEN*(self: Position): string =
    var skip: int
    # Piece placement data
    for rank in Rank.all():
        skip = 0
        for file in File.all():
            let piece = self.mailbox[makeSquare(rank, file)]
            if piece.kind == Empty:
                inc(skip)
            elif skip > 0:
                result &= &"{skip}{piece.toChar()}"
                skip = 0
            else:
                result &= piece.toChar()
        if skip > 0:
            result &= $skip
        if rank < 7:
            result &= "/"
    result &= " "
    result &= (if self.sideToMove == White: "w" else: "b")
    result &= " "
    let castleWhite = self.castlingAvailability[White]
    let castleBlack = self.castlingAvailability[Black]
    if not (castleBlack.king != nullSquare() or castleBlack.queen != nullSquare() or castleWhite.king != nullSquare() or castleWhite.queen != nullSquare()):
        result &= "-"
    else:
        let files: array[White..Black, pcs.File] = [self.pieces(King, White).toSquare().file(), self.pieces(King, Black).toSquare().file()]
        if castleWhite.king != nullSquare():
            if castleWhite.king == H1 and absDistance(files[White], castleWhite.king.file()) > 1:
                result &= "K"
            else:
                result &= castleWhite.king.toUCI()[0].toUpperAscii()
        if castleWhite.queen != nullSquare():
            if castleWhite.queen == A1 and absDistance(files[White], castleWhite.queen.file()) > 1:
                result &= "Q"
            else:
                result &= castleWhite.queen.toUCI()[0].toUpperAscii()
        if castleBlack.king != nullSquare():
            if castleBlack.king == H8 and absDistance(files[Black], castleBlack.king.file()) > 1:
                result &= "k"
            else:
                result &= castleBlack.king.toUCI()[0]
        if castleBlack.queen != nullSquare():
            if castleBlack.queen == A8 and absDistance(files[Black], castleBlack.queen.file()) > 1:
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
    var file = pcs.File(7)
    for rank in Rank.all():
        if rank > 0:
            result &= "\n"
        for file in File.all():
            # Equivalent to (rank + file) mod 2
            # (I'm just evil). Could also just
            # use isLightSquare, but again: evil
            if ((rank.uint8 + file.uint8) and 1) == 0:
                result &= "\x1b[39;44;1m"
            else:
                result &= "\x1b[39;40;1m"
            let piece = self.mailbox[makeSquare(rank, file)]
            if piece.kind == Empty:
                result &= "  \x1b[0m"
            else:
                result &= &"{piece.toPretty()} \x1b[0m"
        result &= &" \x1b[33;1m{file.uint8 + 1}\x1b[0m"
        dec(file)

    result &= "\n\x1b[31;1ma b c d e f g h"
    result &= "\x1b[0m"