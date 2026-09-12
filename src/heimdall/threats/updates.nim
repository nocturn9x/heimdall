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

## Threat input update collection and accumulator row arithmetic.
## Yoinked from Pawnocchio and Quanticade. Thanks!

import heimdall/[nnue, pieces, position]
import heimdall/threats/index
import heimdall/util/simd_dispatch

when defined(simd):
    import heimdall/util/simd

    static:
        doAssert L1_SIZE mod CHUNK_SIZE == 0, "TI accumulator width must be a multiple of the SIMD lane count"


type
    ThreatList* = object
        whiteCnt: int
        blackCnt: int
        # Entirely arbitrary constant, just has to be >= the max
        # number of added/removed threats per move (~80ish according
        # to @swedishcef), and powers of two are nice.
        white: array[128, uint16]
        black: array[128, uint16]

    ThreatDiff* = object
        adds*: ThreatList
        subs*: ThreatList


func add*(self: var ThreatList,
          kings: array[White..Black, Square],
          attackerPiece: Piece,
          fromSquare: Square,
          victimPiece: Piece,
          targetSquare: Square
    ) =
    ## Append the relation for each perspective whose index is valid.
    let whiteThreat = White.threatIndex(kings[White], attackerPiece, fromSquare, victimPiece, targetSquare)

    if whiteThreat.valid:
        self.white[self.whiteCnt] = whiteThreat.idx
        inc(self.whiteCnt)

    let blackThreat = Black.threatIndex(kings[Black], attackerPiece, fromSquare, victimPiece, targetSquare)

    if blackThreat.valid:
        self.black[self.blackCnt] = blackThreat.idx
        inc(self.blackCnt)


func apply*(self: var ThreatDiff, weights: ThreatWeights, perspective: PieceColor, oldAcc, newAcc: var array[L1_SIZE, int16]) {.inline, simdKernel.} =
    ## Copy the parent and apply only this perspective's added/removed rows.
    ## In SIMD builds, accumulator buffers must be aligned to ALIGNMENT_BOUNDARY.
    var added: ptr array[128, uint16]
    var addCnt: int
    var removed: ptr array[128, uint16]
    var subCnt: int

    if perspective == White:
        added = addr self.adds.white
        removed = addr self.subs.white
        addCnt = self.adds.whiteCnt
        subCnt = self.subs.whiteCnt
    else:
        added = addr self.adds.black
        removed = addr self.subs.black
        addCnt = self.adds.blackCnt
        subCnt = self.subs.blackCnt

    when not defined(simd):
        for neuron in 0..<L1_SIZE:
            var value = oldAcc[neuron]

            for activeThreat in added[].toOpenArray(0, addCnt - 1):
                value = value +% weights[activeThreat][neuron].int16

            for activeThreat in removed[].toOpenArray(0, subCnt - 1):
                value = value -% weights[activeThreat][neuron].int16

            newAcc[neuron] = value
    else:
        var offset = 0
        # Reuse each threat index and row address across four registers.
        # Keep the single-register loop below for smaller widths and tails.
        while offset + 4 * CHUNK_SIZE <= L1_SIZE:
            var
                v0 = vecLoad(addr oldAcc[offset])
                v1 = vecLoad(addr oldAcc[offset + CHUNK_SIZE])
                v2 = vecLoad(addr oldAcc[offset + 2 * CHUNK_SIZE])
                v3 = vecLoad(addr oldAcc[offset + 3 * CHUNK_SIZE])
            for activeThreat in added[].toOpenArray(0, addCnt - 1):
                let row = unsafeAddr weights[activeThreat]
                let (w0, w1) = vecLoadI8AsI16x2(unsafeAddr row[][offset])
                let (w2, w3) = vecLoadI8AsI16x2(unsafeAddr row[][offset + 2 * CHUNK_SIZE])
                v0 = vecAdd16(v0, w0)
                v1 = vecAdd16(v1, w1)
                v2 = vecAdd16(v2, w2)
                v3 = vecAdd16(v3, w3)
            for activeThreat in removed[].toOpenArray(0, subCnt - 1):
                let row = unsafeAddr weights[activeThreat]
                let (w0, w1) = vecLoadI8AsI16x2(unsafeAddr row[][offset])
                let (w2, w3) = vecLoadI8AsI16x2(unsafeAddr row[][offset + 2 * CHUNK_SIZE])
                v0 = vecSub16(v0, w0)
                v1 = vecSub16(v1, w1)
                v2 = vecSub16(v2, w2)
                v3 = vecSub16(v3, w3)
            vecStore(addr newAcc[offset], v0)
            vecStore(addr newAcc[offset + CHUNK_SIZE], v1)
            vecStore(addr newAcc[offset + 2 * CHUNK_SIZE], v2)
            vecStore(addr newAcc[offset + 3 * CHUNK_SIZE], v3)
            offset += 4 * CHUNK_SIZE
        while offset < L1_SIZE:
            var values = vecLoad(addr oldAcc[offset])
            for activeThreat in added[].toOpenArray(0, addCnt - 1):
                values = vecAdd16(values, vecLoadI8AsI16(unsafeAddr weights[activeThreat][offset]))
            for activeThreat in removed[].toOpenArray(0, subCnt - 1):
                values = vecSub16(values, vecLoadI8AsI16(unsafeAddr weights[activeThreat][offset]))
            vecStore(addr newAcc[offset], values)
            offset += CHUNK_SIZE


proc applyAllRowsZeroed*(accumulator: var array[L1_SIZE, int16], weights: ThreatWeights, activeThreats: openArray[uint16]) {.simdKernel.} =
    ## Replace the accumulator with the sum of active threat rows, without bias.
    ## In SIMD builds, the accumulator must be aligned to ALIGNMENT_BOUNDARY.
    when not defined(simd):
        for i in 0..<L1_SIZE:
            accumulator[i] = 0

        for threat in activeThreats:
            let row = weights[threat]

            for i in 0..<L1_SIZE:
                accumulator[i] = accumulator[i] +% row[i].int16
    else:
        var offset = 0
        while offset + 4 * CHUNK_SIZE <= L1_SIZE:
            var
                v0 = vecZero16()
                v1 = vecZero16()
                v2 = vecZero16()
                v3 = vecZero16()
            for threat in activeThreats:
                let row = unsafeAddr weights[threat]
                let (w0, w1) = vecLoadI8AsI16x2(unsafeAddr row[][offset])
                let (w2, w3) = vecLoadI8AsI16x2(unsafeAddr row[][offset + 2 * CHUNK_SIZE])
                v0 = vecAdd16(v0, w0)
                v1 = vecAdd16(v1, w1)
                v2 = vecAdd16(v2, w2)
                v3 = vecAdd16(v3, w3)
            vecStore(addr accumulator[offset], v0)
            vecStore(addr accumulator[offset + CHUNK_SIZE], v1)
            vecStore(addr accumulator[offset + 2 * CHUNK_SIZE], v2)
            vecStore(addr accumulator[offset + 3 * CHUNK_SIZE], v3)
            offset += 4 * CHUNK_SIZE
        while offset < L1_SIZE:
            var values = vecZero16()
            for threat in activeThreats:
                values = vecAdd16(values, vecLoadI8AsI16(unsafeAddr weights[threat][offset]))
            vecStore(addr accumulator[offset], values)
            offset += CHUNK_SIZE


# yoinked from https://github.com/Quanticade/Quanticade/blob/0c30c9290b5557eb34d9f7234b59a91791511c72/Source/nnue.c#L1346
proc processChangedSquares(position: Position, changedSquares: Bitboard, lst: var ThreatList) =
    let
        occupancy = position.pieces()
        kings: array[White..Black, Square] = [position.kingSquare(White), position.kingSquare(Black)]
        nonKings = position.pieces() and not position.pieces(King)

    for fromSquare in changedSquares and nonKings:
        let attacker = position.on(fromSquare)
        let attacks = threatAttacks(attacker, fromSquare, occupancy) and nonKings

        for targetSquare in attacks:
            let victim = position.on(targetSquare)
            lst.add(kings, attacker, fromSquare, victim, targetSquare)

    # Same as above, instead collecting victims instead of attackers (notice
    # how source and destination are inverted)
    for targetSquare in changedSquares and nonKings:
        let victim = position.on(targetSquare)
        let attackers = position.attackers(targetSquare, occupancy) and nonKings and not changedSquares

        for fromSquare in attackers:
            let attacker = position.on(fromSquare)
            lst.add(kings, attacker, fromSquare, victim, targetSquare)


proc processSliderDeltas(before, after: Position, affectedSliders, changedSquares: Bitboard, adds, subs: var ThreatList) =
    let
        occupancyBefore = before.pieces()
        occupancyAfter = after.pieces()
        kings: array[White..Black, Square] = [after.kingSquare(White), after.kingSquare(Black)]
        nonKingsBefore = before.pieces() and not before.pieces(King)
        nonKingsAfter = after.pieces() and not after.pieces(King)

    for fromSquare in affectedSliders and nonKingsAfter:
        let
            piece = after.on(fromSquare)
            oldAttacks = threatAttacks(piece, fromSquare, occupancyBefore) and nonKingsBefore and not changedSquares
            newAttacks = threatAttacks(piece, fromSquare, occupancyAfter) and nonKingsAfter and not changedSquares
            dropped = oldAttacks and not newAttacks
            gained = newAttacks and not oldAttacks

        for targetSquare in dropped:
            let victim = before.on(targetSquare)
            subs.add(kings, piece, fromSquare, victim, targetSquare)

        for targetSquare in gained:
            let victim = before.on(targetSquare)
            adds.add(kings, piece, fromSquare, victim, targetSquare)


proc collectThreatDiff*(before, after: Position): ThreatDiff =
    ## Collect changed endpoints and stationary slider rays for one move.
    ## A perspective whose king orientation changed must be rebuilt instead
    ## of applying these indices to its old accumulator.
    var changedSquares = Bitboard(0)
    for side in White..Black:
        for piece in PieceKind.Pawn..PieceKind.King:
            changedSquares = changedSquares or (before.pieces(piece, side) xor after.pieces(piece, side))
    let
        occBefore = before.pieces()
        occAfter = after.pieces()
        rooksBefore = before.pieces(Queen) or before.pieces(Rook)
        bishopsBefore = before.pieces(Queen) or before.pieces(Bishop)
        rooksAfter = after.pieces(Queen) or after.pieces(Rook)
        bishopsAfter = after.pieces(Queen) or after.pieces(Bishop)

    var slidersBefore = Bitboard(0)
    var slidersAfter = Bitboard(0)

    for square in changedSquares:
        slidersBefore = slidersBefore or bishopMoves(square, occBefore) and bishopsBefore
        slidersBefore = slidersBefore or rookMoves(square, occBefore) and rooksBefore

        slidersAfter = slidersAfter or bishopMoves(square, occAfter) and bishopsAfter
        slidersAfter = slidersAfter or rookMoves(square, occAfter) and rooksAfter

    let affectedSliders = (slidersBefore or slidersAfter) and not changedSquares

    before.processChangedSquares(changedSquares, result.subs)
    after.processChangedSquares(changedSquares, result.adds)
    before.processSliderDeltas(after, affectedSliders, changedSquares, result.adds, result.subs)
