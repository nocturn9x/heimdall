# Copyright 2026 Mattia Giambirtone & All Contributors
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

## Bundled opening-name lookup for replay mode.

import std/[options, strutils, tables]

import heimdall/[board, moves, movegen, position]


type
    NamedOpening* = object
        eco*: string
        name*: string


const OPENING_DATA = staticRead("../../resources/openings/lichess.tsv")


var
    openingIndexLoaded = false
    openingsByEpd: Table[string, NamedOpening]


proc openingPositionKey*(position: Position, chess960 = false): string =
    let fields = position.toFEN(chess960).split(' ')
    if fields.len < 4:
        return ""
    fields[0..3].join(" ")


proc ensureOpeningIndexLoaded() =
    if openingIndexLoaded:
        return

    openingsByEpd = initTable[string, NamedOpening]()
    for line in OPENING_DATA.splitLines():
        if line.len == 0 or line[0] == '#':
            continue
        let parts = line.split('\t', maxsplit = 2)
        if parts.len < 3:
            continue
        openingsByEpd[parts[0]] = NamedOpening(eco: parts[1], name: parts[2])

    openingIndexLoaded = true


proc lookupNamedOpening*(position: Position, chess960 = false): Option[NamedOpening] =
    if chess960:
        return none(NamedOpening)

    ensureOpeningIndexLoaded()
    let key = openingPositionKey(position, chess960)
    if key.len == 0 or key notin openingsByEpd:
        return none(NamedOpening)
    some(openingsByEpd[key])


proc classifyReplayOpenings*(startPosition: Position, moves: seq[Move], chess960 = false): seq[Option[NamedOpening]] =
    result = newSeq[Option[NamedOpening]](moves.len + 1)
    if chess960:
        return result

    ensureOpeningIndexLoaded()

    var board = newChessboard(@[startPosition.clone()])
    var current = lookupNamedOpening(board.position, chess960)
    result[0] = current

    for i, move in moves:
        discard board.makeMove(move)
        let exact = lookupNamedOpening(board.position, chess960)
        if exact.isSome():
            current = exact
        result[i + 1] = current
