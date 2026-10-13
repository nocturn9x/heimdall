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
#
# Authored with assistance from AI agents.

## Move notation used by the TUI's analysis display.

import std/strutils

import heimdall/[board, moves, movegen]
import heimdall/pieces as pcs
import heimdall/tui/util/san


type
    PVNotation* = enum
        SANNotation
        UCINotation


func toTUIUCI*(move: Move, chess960 = false): string =
    ## Formats castling with the king's destination in standard chess and
    ## the rook's origin in Chess960, preserving the internal move.
    var displayMove = move
    if move.isCastling() and not chess960:
        let targetFile = if move.isShortCastling(): pcs.File(6) else: pcs.File(2)
        displayMove.targetSquare = makeSquare(move.startSquare().rank(), targetFile)
    displayMove.toUCI()


proc formatPV*(board: Chessboard, pv: openArray[Move], notation = SANNotation,
               chess960 = false, maxWidth = int.high): string =
    ## Formats a PV from its root position without changing the displayed board.
    ## Stops at null/invalid SAN moves and fits complete moves within maxWidth.
    if maxWidth <= 0:
        return ""
    let preview = if notation == SANNotation: newChessboard(@[board.position]) else: nil
    for move in pv:
        if move == nullMove():
            break
        var moveStr: string
        if notation == SANNotation:
            if not preview.isLegal(move):
                break
            moveStr = preview.toSAN(move)
        else:
            moveStr = move.toTUIUCI(chess960)

        let separator = if result.len > 0: " " else: ""
        if result.len + separator.len + moveStr.len > maxWidth:
            let marker = if maxWidth >= 2: ".." else: "."
            while result.len + marker.len > maxWidth:
                let lastSpace = result.rfind(' ')
                result.setLen(if lastSpace >= 0: lastSpace else: 0)
            result &= marker
            break
        result &= separator & moveStr
        if notation == SANNotation:
            preview.doMove(move)
