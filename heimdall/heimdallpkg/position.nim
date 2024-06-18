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
        
        # Castling availability. This just keeps track
        # of whether the king or the rooks on either side
        # moved, the actual checks for the legality of castling
        # are done elsewhere
        castlingAvailability*: array[PieceColor.White..PieceColor.Black, tuple[queen, king: bool]]
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
        pieces*: array[PieceColor.White..PieceColor.Black, array[PieceKind.Bishop..PieceKind.Rook, Bitboard]]
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


proc toFEN*(self: Position): string


func inCheck*(self: Position): bool {.inline.} =
    ## Returns if the current side to move is in check
    return self.checkers != 0


func getKingStartingSquare*(color: PieceColor): Square {.inline.} =
    ## Retrieves the starting square of the king
    ## for the given color
    case color:
        of White:
            return "e1".toSquare()
        of Black:
            return "e8".toSquare()
        else:
            discard


func getBitboard*(self: Position, kind: PieceKind, color: PieceColor): Bitboard =
    ## Returns the positional bitboard for the given piece kind and color
    return self.pieces[color][kind]


func getBitboard*(self: Position, piece: Piece): Bitboard =
    ## Returns the positional bitboard for the given piece type
    return self.getBitboard(piece.kind, piece.color)


func getOccupancyFor*(self: Position, color: PieceColor): Bitboard =
    ## Get the occupancy bitboard for every piece of the given color
    result = Bitboard(0)
    for b in self.pieces[color]:
        result = result or b


func getOccupancy*(self: Position): Bitboard {.inline.} =
    ## Get the occupancy bitboard for every piece on
    ## the chessboard
    result = self.colors[White] or self.colors[Black]


proc getPawnAttacks*(self: Position, square: Square, attacker: PieceColor): Bitboard {.inline.} =
    ## Returns the locations of the pawns attacking the given square
    return self.getBitboard(Pawn, attacker) and getPawnAttacks(attacker, square)


proc getKingAttacks*(self: Position, square: Square, attacker: PieceColor): Bitboard {.inline.} =
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

func getKnightAttacks*(self: Position, square: Square, attacker: PieceColor): Bitboard =
    ## Returns the locations of the knights attacking the given square
    let 
        knights = self.getBitboard(Knight, attacker)
        squareBB = square.toBitboard()
    result = Bitboard(0)
    for knight in knights:
        if (getKnightAttacks(knight) and squareBB) != 0:
            result = result or knight.toBitboard()


proc getSlidingAttacks*(self: Position, square: Square, attacker: PieceColor): Bitboard =
    ## Returns the locations of the sliding pieces attacking the given square
    let
        queens = self.getBitboard(Queen, attacker)
        rooks = self.getBitboard(Rook, attacker) or queens
        bishops = self.getBitboard(Bishop, attacker) or queens
        occupancy = self.getOccupancy()
        squareBB = square.toBitboard()
    result = Bitboard(0)
    for rook in rooks:
        let 
            blockers = occupancy and Rook.getRelevantBlockers(rook)
            moves = getRookMoves(rook, blockers)
        # Attack set intersects our chosen square
        if (moves and squareBB) != 0:
            result = result or rook.toBitboard()
    for bishop in bishops:
        let 
            blockers = occupancy and Bishop.getRelevantBlockers(bishop)
            moves = getBishopMoves(bishop, blockers)
        if (moves and squareBB) != 0:
            result = result or bishop.toBitboard()


proc getAttackersTo*(self: Position, square: Square, attacker: PieceColor): Bitboard =
    ## Computes the attack bitboard for the given square from
    ## the given side
    result = Bitboard(0) or self.getPawnAttacks(square, attacker)
    result = result or self.getKingAttacks(square, attacker)
    result = result or self.getKnightAttacks(square, attacker)
    result = result or self.getSlidingAttacks(square, attacker)


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
    
    if self.getPawnAttacks(square, nonSideToMove) != 0:
        return true


proc canCastle*(self: Position): tuple[queen, king: bool] =
    ## Returns if the current side to move can castle
    if self.inCheck():
        return (false, false)
    let 
        sideToMove = self.sideToMove
        occupancy = self.getOccupancy()
    result = self.castlingAvailability[sideToMove]
    if result.king:
        result.king = (kingSideCastleRay(sideToMove) and occupancy) == 0
    if result.queen:
        result.queen = (queenSideCastleRay(sideToMove) and occupancy) == 0
    if result.king:
        # There are no pieces in between our friendly king and
        # rook: check for attacks
        let 
            king = self.getBitboard(King, sideToMove).toSquare()
        for square in getRayBetween(king, sideToMove.kingSideRook()):
            if self.isOccupancyAttacked(square, occupancy):
                result.king = false
                break

    if result.queen:
        let 
            king: Square = self.getBitboard(King, sideToMove).toSquare()
            # The king always moves two squares, but the queen side rook moves
            # 3 squares. We only need to check for attacks on the squares where
            # the king moves to and not any further. We subtract 3 instead of 2 
            # because getRayBetween ignores the start and target squares in the
            # ray it returns so we have to extend it by one
            destination = makeSquare(rankFromSquare(king), fileFromSquare(king) - 3)
        for square in getRayBetween(king, destination):
            if self.isOccupancyAttacked(square, occupancy):
                result.queen = false
                break


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


proc removePieceFromBitboard*(self: var Position, square: Square) =
    ## Removes a piece at the given square from
    ## its respective bitboard
    let piece = self.getPiece(square)
    self.pieces[piece.color][piece.kind].clearBit(square)
    self.colors[piece.color].clearBit(square)


proc addPieceToBitboard*(self: var Position, square: Square, piece: Piece) =
    ## Adds the given piece at the given square to
    ## its respective bitboard
    self.pieces[piece.color][piece.kind].setBit(square)
    self.colors[piece.color].setBit(square)


proc spawnPiece*(self: var Position, square: Square, piece: Piece) =
    ## Spawns a new piece at the given square
    assert self.getPiece(square).kind == Empty
    self.addPieceToBitboard(square, piece)
    self.mailbox[square] = piece


proc removePiece*(self: var Position, square: Square) =
    ## Removes a piece from the board, updating necessary
    ## metadata
    let piece = self.getPiece(square)
    assert piece.kind != Empty and piece.color != None, self.toFEN()
    self.removePieceFromBitboard(square)
    self.mailbox[square] = nullPiece()


proc movePiece*(self: var Position, move: Move) =
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


proc movePiece*(self: var Position, startSquare, targetSquare: Square) =
    ## Moves a piece from the given start square to the given
    ## target square
    self.movePiece(createMove(startSquare, targetSquare))


func countPieces*(self: Position, piece: Piece): int {.inline.} =
    ## Returns the number of pieces in the position that
    ## are of the same type and color as the given piece
    return self.countPieces(piece.kind, piece.color)


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

    if self.castlingAvailability[White].king:
        self.zobristKey = self.zobristKey xor getKingSideCastlingKey(White)
    if self.castlingAvailability[White].queen:
        self.zobristKey = self.zobristKey xor getQueenSideCastlingKey(White)
    if self.castlingAvailability[Black].king:
        self.zobristKey = self.zobristKey xor getKingSideCastlingKey(Black)
    if self.castlingAvailability[Black].queen:
        self.zobristKey = self.zobristKey xor getQueenSideCastlingKey(Black)

    if self.enPassantSquare != nullSquare():
        self.zobristKey = self.zobristKey xor getEnPassantKey(fileFromSquare(self.enPassantSquare))


proc loadFEN*(fen: string): Position =
    ## Initializes a position from the given
    ## FEN string
    result = Position(enPassantSquare: nullSquare())
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
                    # TODO
                    of '-':
                        discard
                    of 'K':
                        result.castlingAvailability[White].king = true
                    of 'Q':
                        result.castlingAvailability[White].queen = true
                    of 'k':
                        result.castlingAvailability[Black].king = true
                    of 'q':
                        result.castlingAvailability[Black].queen = true
                    else:
                        raise newException(ValueError, &"invalid FEN '{fen}': unknown symbol '{c}' found in castlingRights availability section")
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
    if not (castleBlack.king or castleBlack.queen or castleWhite.king or castleWhite.queen):
        result &= "-"
    else:
        if castleWhite.king:
            result &= "K"
        if castleWhite.queen:
            result &= "Q"
        if castleBlack.king:
            result &= "k"
        if castleBlack.queen:
            result &= "q"
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