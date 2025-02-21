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

# This code also comes from the analog brain of a certain code horse. Many thanks!

import heimdall/pieces

import std/enumerate
import std/strformat


func scharnaglConfig(scharnagl_number: int): array[8, PieceKind] =
    var config: array[8, PieceKind]
    for slot in config.mitems:
        slot = Empty

    func placeInNthFree(n: int, pieceKind: PieceKind) =
        var n = n
        for slot in config.mitems:
            if slot == Empty:
                if n > 0:
                    dec(n)
                else:
                    slot = pieceKind
                    break

    func unpackKnights(n: int): (int, int) =
        case n:
            of 0: return (0, 1)
            of 1: return (0, 2)
            of 2: return (0, 3)
            of 3: return (0, 4)
            of 4: return (1, 2)
            of 5: return (1, 3)
            of 6: return (1, 4)
            of 7: return (2, 3)
            of 8: return (2, 4)
            of 9: return (3, 4)
            else: discard

    var n = scharnagl_number
    
    let lightBishopIndex = n mod 4
    n = n div 4

    let darkBishopIndex = n mod 4
    n = n div 4

    let queenIndex = n mod 6
    n = n div 6

    let (leftKnightIndex, rightKnightIndex) = unpackKnights(n);

    config[lightBishopIndex * 2 + 1] = Bishop
    config[darkBishopIndex * 2] = Bishop
    placeInNthFree(queenIndex, Queen)
    placeInNthFree(leftKnightIndex, Knight)
    placeInNthFree(rightKnightIndex - 1, Knight)
    placeInNthFree(0, Rook)
    placeInNthFree(0, King)
    placeInNthFree(0, Rook)

    return config


func scharnaglToFEN*(whiteScharnaglNumber: int, blackScharnaglNumber: int): string =
    var castleRights: string

    var whiteConfig: string
    for file, pieceKind in enumerate(scharnaglConfig(whiteScharnaglNumber)):
        whiteConfig &= Piece(color: White, kind: pieceKind).toChar()
        if pieceKind == Rook:
            castleRights &= char('A'.uint8 + file.uint8)

    var blackConfig: string
    for file, pieceKind in enumerate(scharnaglConfig(blackScharnaglNumber)):
        blackConfig &= Piece(color: Black, kind: pieceKind).toChar()
        if pieceKind == Rook:
            castleRights &= char('a'.uint8 + file.uint8)

    return fmt"{blackConfig}/pppppppp/8/8/8/8/PPPPPPPP/{whiteConfig} w {castleRights} - 0 1"


func scharnaglToFEN*(scharnaglNumber: int): string = scharnaglToFEN(scharnaglNumber, scharnaglNumber)


