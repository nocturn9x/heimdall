import std/[os, syncio, tempfiles, unittest]

import heimdall/[movegen, moves, pieces, position]
import heimdall/util/[marlinformat, viriformat]


func encodeMove(start, target: string, moveType: uint16 = 0,
                promotion: uint16 = 0): uint16 =
    let
        source = start.toSquare().flipRank().uint16
        destination = target.toSquare().flipRank().uint16
    source or (destination shl 6) or (promotion shl 12) or (moveType shl 14)


suite "viriformat 3.0.0":
    test "normal moves acquire Heimdall's implicit flags":
        var position = startpos()
        let move = position.parseViriformatMove(encodeMove("e2", "e4"))
        check move.toUCI() == "e2e4"
        check move.flag() == DoublePush

    test "special move types and square conversion":
        var ep = fromFEN("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1")
        let epMove = ep.parseViriformatMove(encodeMove("e5", "d6", moveType=1))
        check epMove.flag() == EnPassant

        var castle = fromFEN("4k3/8/8/8/8/8/8/4K2R w K - 0 1")
        let castleMove = castle.parseViriformatMove(encodeMove("e1", "h1", moveType=2))
        check castleMove.flag() == ShortCastling

        var promotion = fromFEN("4k3/P7/8/8/8/8/8/4K3 w - - 0 1")
        let promotionMove = promotion.parseViriformatMove(
            encodeMove("a7", "a8", moveType=3, promotion=3)
        )
        check promotionMove.flag() == PromotionQueen

    test "games round-trip with replacement little-endian scores":
        let record = createMarlinFormatRecord(startpos(), White, 0)
        let game = ViriformatGame(
            header: record.toMarlinformat(),
            moves: @[
                ViriformatScoredMove(move: encodeMove("e2", "e4"), score: 10),
                ViriformatScoredMove(move: encodeMove("e7", "e5"), score: -20)
            ]
        )
        let encoded = game.toViriformat([300'i16, -400'i16])
        let (file, path) = createTempFile("heimdall-viriformat-", ".vf")
        file.write(encoded)
        file.setFilePos(0)
        var decoded: ViriformatGame
        check file.readViriformatGame(decoded)
        check decoded.header == game.header
        check decoded.moves.len == 2
        check decoded.moves[0].move == game.moves[0].move
        check decoded.moves[0].score == 300
        check decoded.moves[1].score == -400
        check not file.readViriformatGame(decoded)
        file.close()
        removeFile(path)
