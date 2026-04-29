import std/[algorithm, httpclient, os, sequtils, strutils, tables]

import heimdall/[board, movegen]
import heimdall/tui/util/pgn


const
    SOURCE_URL = "https://raw.githubusercontent.com/lichess-org/chess-openings/master/"
    OUTPUT_PATH = "src/heimdall/resources/openings/lichess.tsv"


type
    OpeningRecord = object
        eco: string
        name: string
        plyCount: int


proc epdKey(board: Chessboard): string =
    let fields = board.position.toFEN(false).split(' ')
    if fields.len < 4:
        raise newException(ValueError, "invalid FEN while computing opening key")
    fields[0..3].join(" ")


proc syntheticPGN(moves: string): string =
    "[Event \"?\"]\n\n" & moves & " *\n"


when isMainModule:
    var client = newHttpClient()
    client.headers = newHttpHeaders({
        "User-Agent": "heimdall-openings-generator"
    })

    var openings = initTable[string, OpeningRecord]()

    for volume in ['a', 'b', 'c', 'd', 'e']:
        let content = client.getContent(SOURCE_URL & $volume & ".tsv")
        for lineNo, line in content.splitLines().pairs():
            if lineNo == 0 or line.len == 0:
                continue

            let parts = line.split('\t', maxsplit = 2)
            if parts.len < 3:
                continue

            let games = parsePGN(syntheticPGN(parts[2]))
            if games.len == 0:
                raise newException(ValueError, "failed to parse opening PGN: " & parts[2])

            var board = newDefaultChessboard()
            for move in games[0].moves:
                discard board.makeMove(move)

            let key = epdKey(board)
            let candidate = OpeningRecord(
                eco: parts[0],
                name: parts[1],
                plyCount: games[0].moves.len
            )

            if key notin openings or
               candidate.plyCount < openings[key].plyCount or
               (candidate.plyCount == openings[key].plyCount and candidate.name.len < openings[key].name.len):
                openings[key] = candidate

    createDir(parentDir(OUTPUT_PATH))

    var lines = @[
        "# Generated from lichess-org/chess-openings by scripts/build_openings_index.nim",
        "# Format: epd<TAB>eco<TAB>name"
    ]

    for key in toSeq(openings.keys).sorted(system.cmp[string]):
        let opening = openings[key]
        lines.add(key & '\t' & opening.eco & '\t' & opening.name)

    writeFile(OUTPUT_PATH, lines.join("\n") & "\n")
    echo "Wrote ", openings.len, " openings to ", OUTPUT_PATH
