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

## Packed piece representation and public API checks.
## Build with make dev MAIN=tests/test_pieces.nim IS_TEST=1 EXE_BASE=bin/test-pieces
## and EVALFILE set to the absolute network path.
import heimdall/pieces

static:
    doAssert sizeof(Piece) == 1
    doAssert sizeof(array[64, Piece]) == 64
    doAssert default(Piece) == createPiece(Pawn, White)
    doAssert nullPiece().kind == Empty
    doAssert nullPiece().color == None

for color in White..None:
    for kind in Pawn..Empty:
        let piece = createPiece(kind, color)
        when defined(debug):
            doAssert cast[uint8](piece) shr 5 == 7
        else:
            doAssert cast[uint8](piece) shr 5 == 0
        doAssert piece.kind == kind
        doAssert piece.color == color
        doAssert (piece == nullPiece()) == (kind == Empty and color == None)
        for newKind in Pawn..Empty:
            var changed = piece
            changed.kind = newKind
            doAssert (cast[uint8](changed) and 0xe0) == (cast[uint8](piece) and 0xe0)
            doAssert changed == createPiece(newKind, color)
            doAssert piece.kind == kind
        for newColor in White..None:
            var changed = piece
            changed.color = newColor
            doAssert (cast[uint8](changed) and 0xe0) == (cast[uint8](piece) and 0xe0)
            doAssert changed == createPiece(kind, newColor)
            doAssert piece.color == color

for c in "PNBRQKpnbrqk":
    doAssert fromChar(c).toChar() == c

echo "Packed pieces: one-byte layout, sentinels, accessors, mutations and character round trips passed"
