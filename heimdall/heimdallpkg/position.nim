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
import std/strformat
import std/strutils


import bitboards
import magics
import pieces
import zobrist
import moves
import rays

export bitboards, magics, pieces, zobrist, moves, rays


type 
    Position* = object
        ## A chess position
        
        # Castling availability. The square represents the location of the rook
        # with which the king can castle on either side
        castlingAvailability*: array[PieceColor.White..PieceColor.Black, tuple[queen, king: Square]]
        # Number of half-moves that were performed
        # to reach this position starting from the
        # root of the tree
        plyFromRoot*: uint16
        # Number of half moves since
        # last piece capture or pawn movement.
        # Used for the 50-move rule
        halfMoveClock*: uint16
        # Full move counter. Increments
        # every 2 ply (half-moves)
        fullMoveCount*: uint16
        # En passant target square (see https://en.wikipedia.org/wiki/En_passant)
        enPassantSquare*: Square
        # The side to move
        sideToMove*: PieceColor
        # Positional bitboards for all pieces
        pieces*: array[PieceColor.White..PieceColor.Black, array[PieceKind.Pawn..PieceKind.King, Bitboard]]
        # Total occupancy by colors
        colors*: array[PieceColor.White..PieceColor.Black, Bitboard]
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


func toFEN*(self: Position): string


func inCheck*(self: Position): bool {.inline.} =
    ## Returns if the current side to move is in check
    return self.checkers != 0


func getBitboard*(self: Position, kind: PieceKind, color: PieceColor): Bitboard {.inline.} =
    ## Returns the positional bitboard for the given piece kind and color
    return self.pieces[color][kind]


func getBitboard*(self: Position, piece: Piece): Bitboard {.inline.} =
    ## Returns the positional bitboard for the given piece type
    return self.getBitboard(piece.kind, piece.color)


func getOccupancyFor*(self: Position, color: PieceColor): Bitboard {.inline.} =
    ## Get the occupancy bitboard for every piece of the given color
    result = self.colors[color]


func getOccupancy*(self: Position): Bitboard {.inline.} =
    ## Get the occupancy bitboard for every piece on
    ## the chessboard
    result = self.colors[White] or self.colors[Black]


proc getPawnAttackers*(self: Position, square: Square, attacker: PieceColor): Bitboard {.inline.} =
    ## Returns the locations of the pawns attacking the given square
    return self.getBitboard(Pawn, attacker) and getPawnAttacks(attacker, square)


proc getKingAttacker*(self: Position, square: Square, attacker: PieceColor): Bitboard {.inline.} =
    ## Returns the location of the king if it is attacking the given square
    result = Bitboard(0)
    let king = self.getBitboard(King, attacker)
    if king == 0:
        # The king was removed (probably by SEE or some
        # other internal machinery). This should never
        # occur during normal movegen!
        return
    if (getKingAttacks(king.toSquare()) and square.toBitboard()) != 0:
        return king


func getKnightAttackers*(self: Position, square: Square, attacker: PieceColor): Bitboard =
    ## Returns the locations of the knights attacking the given square
    return getKnightAttacks(square) and self.getBitboard(Knight, attacker)  


proc getSlidingAttackers*(self: Position, square: Square, attacker: PieceColor): Bitboard =
    ## Returns the locations of the sliding pieces attacking the given square
    let
        queens = self.getBitboard(Queen, attacker)
        rooks = self.getBitboard(Rook, attacker) or queens
        bishops = self.getBitboard(Bishop, attacker) or queens
        occupancy = self.getOccupancy()
    
    result = getBishopMoves(square, occupancy) and (bishops or queens)
    result = result or getRookMoves(square, occupancy) and (rooks or queens)


proc getAttackersTo*(self: Position, square: Square, attacker: PieceColor): Bitboard =
    ## Computes the attackers bitboard for the given square from
    ## the given side
    result = self.getPawnAttackers(square, attacker)
    result = result or self.getKingAttacker(square, attacker)
    result = result or self.getKnightAttackers(square, attacker)
    result = result or self.getSlidingAttackers(square, attacker)


proc isOccupancyAttacked*(self: Position, square: Square, occupancy: Bitboard): bool =
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

    if (getKnightAttacks(square) and knights) != 0:
        return true
    
    let king = self.getBitboard(King, nonSideToMove)

    if (getKingAttacks(square) and king) != 0:
        return true

    let 
        queens = self.getBitboard(Queen, nonSideToMove)
        bishops = self.getBitboard(Bishop, nonSideToMove) or queens

    if (getBishopMoves(square, occupancy) and bishops) != 0:
        return true

    let rooks = self.getBitboard(Rook, nonSideToMove) or queens

    if (getRookMoves(square, occupancy) and rooks) != 0:
        return true
    
    if self.getPawnAttackers(square, nonSideToMove) != 0:
        return true


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
    ## in algebraic notation
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


proc removePiece*(self: var Position, square: Square) {.inline.} =
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
    when defined(debug):
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
    A1 = makeSquare(7, 0)
    H1 = makeSquare(7, 7)
    B1 = makeSquare(7, 1)
    H8 = makeSquare(0, 7)
    A8 = makeSquare(0, 0)
    B8 = makeSquare(0, 1)


proc queenSideCastleRay(position: Position, color: PieceColor): Bitboard {.inline.} =
    return getRayBetween(position.getBitboard(King, color).toSquare(), if color == White: B1 else: B8)

proc kingSideCastleRay(position: Position, color: PieceColor): Bitboard {.inline.} =
    return getRayBetween(position.getBitboard(King, color).toSquare(), if color == White: H1 else: H8)


proc canCastle*(self: Position): tuple[queen, king: Square] =
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
        # extra checks are necessary to support the extended castliing
        # rules of chess960
        let occupancy = occupancy and not result.king.toBitboard() and not kingSq.toBitboard()
        let target = king.kingSideCastling().toBitboard()
        let kingRay = getRayBetween(result.king, king.kingSideCastling()) or king.kingSideCastling().toBitboard()
        let rookRay = getRayBetween(result.king, rook.kingSideCastling()) or rook.kingSideCastling().toBitboard()

        if (getRayBetween(result.king, kingSq) and occupancy) == 0 and (kingRay and occupancy) == 0 and (rookRay and occupancy) == 0:
            # There are no pieces in between our friendly king and
            # rook and between the friendly king/rook and their respective
            # destinations: now we check for attacks on the squares where
            # the king will have to move
            for square in self.kingSideCastleRay(sideToMove) or target:
                # The "or target" part is needed because rays exclude
                # their ends (so a ray from a1 to h1 does not include
                # either of them). We also need to make sure the target
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

        if (getRayBetween(result.queen, kingSq) and occupancy) == 0 and (kingRay and occupancy) == 0 and (rookRay and occupancy) == 0:
            for square in self.queenSideCastleRay(sideToMove) or target:
                if self.isOccupancyAttacked(square, occupancy):
                    result.queen = nullSquare()
                    break
        else:
            result.queen = nullSquare()


proc updateChecksAndPins*(self: var Position) =
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
                        result.castlingAvailability[White].king = "h1".toSquare()
                    of 'Q':
                        result.castlingAvailability[White].queen = "a1".toSquare()
                    of 'k':
                        result.castlingAvailability[Black].king = "h8".toSquare()
                    of 'q':
                        result.castlingAvailability[Black].queen = "a8".toSquare()
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
                # Backtrack so the space is seen by the
                # next iteration of the loop
                dec(index)
                result.halfMoveClock = parseInt(s).uint16
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
    result.updateChecksAndPins()
    result.hash()
    # Apparently, standard chess castling rights can be used for the chess960 games as long as
    # they are not not ambiguous, which means we need to correct the location of the rooks because
    # the FEN parser assumes the source of the position is not fucking bonkers (looking at you, Lichess)
    for i, sq in [result.castlingAvailability[White].king, result.castlingAvailability[White].queen,
               result.castlingAvailability[Black].king, result.castlingAvailability[Black].queen]:
        if sq == nullSquare():
            continue
        let piece = result.getPiece(sq)
        if piece.kind != Rook:
            # Go find the actual damn rook

            # The square might be empty, so we have to figure out
            # which color rook to look for by the iteration number
            let color = if i in 0..1: White else: Black
            let rank = if piece.color == White: 7 else: 0
            for file in 0..7:
                let newSq = makeSquare(rank, file)
                if result.getPiece(newSq).kind == Rook:
                    if newSq < result.getBitboard(King, color).toSquare():
                        result.castlingAvailability[color].queen = newSq
                    else:
                        result.castlingAvailability[color].king = newSq


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


func toFEN*(self: Position): string =
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
        let kings: array[PieceColor.White..PieceColor.Black, Square] = [self.getBitboard(King, White).toSquare(), self.getBitboard(King, Black).toSquare()]
        if castleWhite.king != nullSquare():
            if castleWhite.king == H1 and abs(fileFromSquare(kings[White]) - fileFromSquare(castleWhite.king)) > 1:
                result &= "K"
            else:
                result &= castleWhite.king.toAlgebraic()[0].toUpperAscii()
        if castleWhite.queen != nullSquare():
            if castleWhite.queen == A1 and abs(fileFromSquare(kings[White]) - fileFromSquare(castleWhite.queen)) > 1:
                result &= "Q"
            else:
                result &= castleWhite.queen.toAlgebraic()[0].toUpperAscii()
        if castleBlack.king != nullSquare():
            if castleBlack.king == H8 and abs(fileFromSquare(kings[Black]) - fileFromSquare(castleBlack.king)) > 1:
                result &= "k"
            else:
                result &= castleBlack.king.toAlgebraic()[0]
        if castleBlack.queen != nullSquare():
            if castleBlack.queen == A8 and abs(fileFromSquare(kings[Black]) - fileFromSquare(castleBlack.queen)) > 1:
                result &= "q"
            else:
                result &= castleBlack.queen.toAlgebraic()[0]
    result &= " "
    # En passant target
    if self.enPassantSquare == nullSquare():
        result &= "-"
    else:
        result &= self.enPassantSquare.toAlgebraic()
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