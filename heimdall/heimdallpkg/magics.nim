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

## Low-level magic bitboard stuff

# Blatantly stolen from this amazing article: https://analog-hors.github.io/site/magic-bitboards/

import heimdallpkg/bitboards
import heimdallpkg/pieces


import std/options
import std/random
import std/tables

import jsony


export pieces
export bitboards


type
    MagicEntry = object
        ## A magic bitboard entry
        mask: Bitboard
        value: uint64
        shift: uint8


# Yeah uh, don't look too closely at this...
proc generateRookBlockers: array[Square(0)..Square(63), Bitboard] {.compileTime.} =
    ## Generates all blocker masks for rooks
    for rank in 0..7:
        for file in 0..7:
            let 
                square = makeSquare(rank, file)
                bitboard = square.toBitboard()
            var 
                current = bitboard
                last = makeSquare(rank, 7).toBitboard()
            while true:
                current = current.rightRelativeTo(White)
                if current == last or current == 0:
                    break
                result[square] = result[square] or current
            current = bitboard
            last = makeSquare(rank, 0).toBitboard()
            while true:
                current = current.leftRelativeTo(White)
                if current == last or current == 0:
                    break
                result[square] = result[square] or current
            current = bitboard
            last = makeSquare(0, file).toBitboard()
            while true:
                current = current.forwardRelativeTo(White)
                if current == last or current == 0:
                    break
                result[square] = result[square] or current
            current = bitboard
            last = makeSquare(7, file).toBitboard()
            while true:
                current = current.backwardRelativeTo(White)
                if current == last or current == 0:
                    break
                result[square] = result[square] or current


# Okay this is fucking clever tho. Which is obvious, considering I didn't come up with it.
# Or, well, the trick at the end isn't mine
func generateBishopBlockers: array[Square(0)..Square(63), Bitboard] {.compileTime.} =
    ## Generates all blocker masks for bishops
    for rank in 0..7:
        for file in 0..7:
            # Generate all possible movement masks
            let 
                square = makeSquare(rank, file)
                bitboard = square.toBitboard()
            var
                current = bitboard
            while true:
                current = current.backwardRightRelativeTo(White)
                if current == 0:
                    break
                result[square] = result[square] or current
            current = bitboard
            while true:
                current = current.backwardLeftRelativeTo(White)
                if current == 0:
                    break
                result[square] = result[square] or current
            current = bitboard
            while true:
                current = current.forwardLeftRelativeTo(White)
                if current == 0:
                    break
                result[square] = result[square] or current
            current = bitboard
            while true:
                current = current.forwardRightRelativeTo(White)
                if current == 0:
                    break
                result[square] = result[square] or current
            # Mask off the edges

            # Yeah, this is the trick. I know, not a big deal, but
            # I'm an idiot so what do I know. Credit to @__arandomnoob
            # on the engine programming discord server for the tip!
            result[square] = result[square] and not getFileMask(0)
            result[square] = result[square] and not getFileMask(7)
            result[square] = result[square] and not getRankMask(0)
            result[square] = result[square] and not getRankMask(7)
            

func getIndex*(magic: MagicEntry, blockers: Bitboard): uint {.inline.} =
    ## Computes an index into the magic bitboard table using
    ## the given magic entry and the blockers bitboard
    let 
        blockers = blockers and magic.mask
        hash = blockers * magic.value
        index = hash shr magic.shift
    return index.uint


# Magic number tables and their corresponding moves
var 
    # We compute the magic number tables as vectors for simplicity, but
    # for improved access speed we used fixed size arrays to store them.
    # This is a bit wasteful in terms of space because there are a number
    # of entries we will never access, but such is the price to be paid
    # for speed
    ROOK_MAGICS: array[Square(0)..Square(63), MagicEntry]
    ROOK_MOVES: array[Square(0)..Square(63), array[4096, Bitboard]]
    BISHOP_MAGICS: array[Square(0)..Square(63), MagicEntry]
    BISHOP_MOVES: array[Square(0)..Square(63), array[512, Bitboard]]


proc getRookMoves*(square: Square, blockers: Bitboard): Bitboard {.inline.} =
    ## Returns the move bitboard for the rook at the given
    ## square with the given blockers bitboard
    return ROOK_MOVES[square][getIndex(ROOK_MAGICS[square], blockers)]


proc getBishopMoves*(square: Square, blockers: Bitboard): Bitboard {.inline.} =
    ## Returns the move bitboard for the bishop at the given
    ## square with the given blockers bitboard
    return BISHOP_MOVES[square][getIndex(BISHOP_MAGICS[square], blockers)]


# Precomputed blocker masks. Only pieces on these bitboards
# are actually able to block the movement of a sliding piece,
# regardless of color
const 
    # mfw Nim's compile time VM *graciously* allows me to call perfectly valid code: :D
    ROOK_BLOCKERS    = generateRookBlockers()
    BISHOP_BLOCKERS  = generateBishopBlockers()


func getRelevantBlockers*(kind: PieceKind, square: Square): Bitboard {.inline.} =
    ## Returns the relevant blockers mask for the given piece
    ## type at the given square
    case kind:
        of Rook:
            return ROOK_BLOCKERS[square]
        of Bishop:
            return BISHOP_BLOCKERS[square]
        else:
            discard

# Thanks analog :D
const 
    ROOK_DELTAS = [(1, 0), (0, -1), (-1, 0), (0, 1)]
    BISHOP_DELTAS =  [(1, 1), (1, -1), (-1, -1), (-1, 1)]
# These are technically (file, rank), but it's all symmetric anyway


func tryOffset(square: Square, df, dr: SomeInteger): Square =
    let
        file = fileFromSquare(square)
        rank = rankFromSquare(square)
    if file + df notin 0..7:
        return nullSquare()
    if rank + dr notin 0..7:
        return nullSquare()
    return makeSquare(rank + dr, file + df)


proc getMoveset*(kind: PieceKind, square: Square, blocker: Bitboard): Bitboard =
    ## A naive implementation of sliding attacks. Returns the moves that can
    ## be performed from the given piece at the given square with the given
    ## blocker mask
    result = Bitboard(0)
    let deltas = if kind == Rook: ROOK_DELTAS else: BISHOP_DELTAS
    for (file, rank) in deltas:
        var ray = square
        while not blocker.contains(ray):
            if (let shifted = ray.tryOffset(file, rank); shifted) != nullSquare():
                ray = shifted
                result = result or ray.toBitboard()
            else:
                break


proc attemptMagicTableCreation(kind: PieceKind, square: Square, entry: MagicEntry): Option[seq[Bitboard]] =
    ## Tries to create a magic bitboard table for the given piece
    ## at the given square using the provided magic entry. Returns
    ## a none type if it fails
    
    # Initialize a new sequence with the right capacity
    var table = newSeqOfCap[Bitboard](1 shl (64'u8 - entry.shift))  # Just a fast way of doing 2 ** n
    for _ in 0..<table.capacity:
        table.add(Bitboard(0))
    # Iterate all possible blocker configurations
    for blocker in entry.mask.subsets():
        let index = getIndex(entry, blocker)
        # Get the moves the piece can make from the given
        # square with this specific blocker configuration.
        # Note that this will return the same set of moves
        # for several different blocker configurations, as
        # many of them (while different) produce the same
        # results
        var moves = kind.getMoveset(square, blocker)
        if table[index] == Bitboard(0):
            # No entry here, yet, so no problem!
            table[index] = moves
        elif table[index] != moves:
            # We found a non-constructive collision, fail :(
            # Notes for future self: A "constructive" collision
            # is one which doesn't affect the result, because some
            # blocker configurations will map to the same set of
            # resulting moves. This actually improves our chances 
            # of building our lovely perfect-hash-function-as-a-table 
            # because we don't actually need to map *all* blocker 
            # configurations uniquely, just the ones that lead to 
            # a different set of moves. This happens because we are
            # keeping track of a lot of redundant blockers that are
            # beyond squares a slider piece could go to: we could reduce
            # the table size if we didn't account for those, but this
            # would require us to have a loop going in every sliding
            # direction to find what pieces are actually blocking the
            # the slider's path and which aren't for every single lookup,
            # which is the whole thing we're trying to avoid by doing all 
            # this magic bitboard stuff, and it is basically how the old mailbox
            # move generator worked anyway (thanks to Sebastian Lague on YouTube
            # for the insight)
            return none(seq[Bitboard])
        # We have found a constructive collision: all good
    result = some(table)


proc findMagic(kind: PieceKind, square: Square, indexBits: uint8): tuple[entry: MagicEntry, table: seq[Bitboard], iterations: int] =
    ## Constructs a (sort of) perfect hash function that fits all
    ## the possible blocking configurations for the given piece at
    ## the given square into a table of size 2^indexBits
    let mask = kind.getRelevantBlockers(square)
    # The best way to find a good magic number? Literally just
    # bruteforce the shit out of it!
    var rand = initRand()
    result.iterations = 0
    while true:
        inc(result.iterations)
        # Again, this is stolen from the article. A magic number
        # is generally useful if it has high bit sparsity, so we AND
        # together a bunch of random values to get a number that's
        # hopefully better than a single one
        let 
            magic = rand.next() and rand.next() and rand.next()
            entry = MagicEntry(mask: mask, value: magic, shift: 64'u8 - indexBits)
        var attempt = attemptMagicTableCreation(kind, square, entry)
        if attempt.isSome():
            # Huzzah! Our search for the mighty magic number is complete
            # (for this square)
            result.entry = entry
            result.table = attempt.get()
            return
        # Not successful? No problem, we'll just try again until
        # the heat death of the universe! (Not really though: finding
        # magics is pretty fast even if you're unlucky)


proc computeMagics*: int {.discardable.} =
    ## Fills in our magic number tables and returns
    ## the total number of iterations that were performed
    ## to find them
    for square in Square(0)..Square(63):
        var magic = findMagic(Rook, square, Rook.getRelevantBlockers(square).countSquares().uint8)
        inc(result, magic.iterations)
        ROOK_MAGICS[square] = magic.entry
        for i, bb in magic.table:
            ROOK_MOVES[square][i] = bb
        magic = findMagic(Bishop, square, Bishop.getRelevantBlockers(square).countSquares().uint8)
        inc(result, magic.iterations)
        BISHOP_MAGICS[square] = magic.entry
        for i, bb in magic.table:
            BISHOP_MOVES[square][i] = bb


import std/strformat
import std/strutils
import std/times
import std/math
import std/os


proc magicWizard* =
    echo "Generating magic bitboards"
    let start = cpuTime()
    let it = computeMagics()
    let tot = round(cpuTime() - start, 3)

    echo &"Generated magic bitboards in {tot} seconds with {it} iterations"
    var 
        rookTableSize = 0
        rookTableCount = 0
        bishopTableSize = 0
        bishopTableCount = 0
        rookTableSizeNz = 0
        rookTableCountNz = 0
        bishopTableSizeNz = 0
        bishopTableCountNz = 0
    for sq in Square(0)..Square(63):
        var rookNonZero = 0
        var bishopNonZero = 0
        for bb in ROOK_MOVES[sq]:
            if bb != Bitboard(0):
                inc(rookNonZero)
        for bb in BISHOP_MOVES[sq]:
            if bb != Bitboard(0):
                inc(bishopNonZero)
        inc(rookTableCount, len(ROOK_MOVES[sq]))
        inc(rookTableCountNz, rookNonZero)
        inc(bishopTableCount, len(BISHOP_MOVES[sq]))
        inc(bishopTableCountNz, bishopNonZero)
        inc(rookTableSize, len(ROOK_MOVES[sq]) * sizeof(Bitboard) + sizeof(seq[Bitboard]))
        inc(bishopTableSize, len(BISHOP_MOVES[sq]) * sizeof(Bitboard) + sizeof(seq[Bitboard]))
        inc(rookTableSizeNz, rookNonZero * sizeof(Bitboard) + sizeof(seq[Bitboard]))
        inc(bishopTableSizeNz, bishopNonZero * sizeof(Bitboard) + sizeof(seq[Bitboard]))

    echo &"There are {rookTableCount} total entries ({rookTableCountNz} nonzero) in the move table for rooks (total size: ~{round(rookTableSize / 1024, 3)} KiB full, ~{round(rookTableSizeNz / 1024, 3)} KiB nonzero)"
    echo &"There are {bishopTableCount} entries ({bishopTableCountNz} nonzero) in the move table for bishops (total size: ~{round(bishopTableSize / 1024, 3)} KiB full, ~{round(bishopTableSizeNz / 1024, 3)} KiB nonzero)"
    var magics = newTable[string, array[Square(0)..Square(63), MagicEntry]]()

    magics["rooks"] = ROOK_MAGICS
    magics["bishops"] = BISHOP_MAGICS
    let
        magicsJson = magics.toJSON()
        rookMovesJson = ROOK_MOVES.toJSON()
        bishopMovesJson = BISHOP_MOVES.toJSON()
    var currentFile = currentSourcePath()
    var path = joinPath(currentFile.parentDir(), "resources/magics")
    writeFile(joinPath(path, "magics.json"), magicsJson)
    writeFile(joinPath(path, "rooks.json"), rookMovesJson)
    writeFile(joinPath(path, "bishops.json"), bishopMovesJson)

    echo &"Dumped data to disk (approx. {round(((len(rookMovesJson) + len(bishopMovesJson) + len(magicsJson)) / 1024) / 1024, 2)} MiB)"


when not isMainModule:
    import pathX

    type
        BuildOSAbsoFile = PathX[fdFile, arAbso, BuildOS, true]
        BuildOSRelaFile = PathX[fdFile, arRela, BuildOS, true]
        BuildOSRelaDire = PathX[fdDire, arRela, BuildOS, true]

    func buildPath: auto {.compileTime.} =
        result = currentSourcePath().BuildOSAbsoFile.parentDir() / BuildOSRelaDire("resources") / BuildOSRelaDire("magics")
    
    const
        path = buildPath()
        magicFile = staticRead($(path / BuildOSRelaFile("magics.json")))
        rookMovesFile = staticRead($(path / BuildOSRelaFile("rooks.json")))
        bishopMovesFile = staticRead($(path / BuildOSRelaFile("bishops.json")))
    var magics = magicFile.fromJson(TableRef[string, array[Square(0)..Square(63), MagicEntry]])
    var bishopMoves = bishopMovesFile.fromJSON(array[Square(0)..Square(63), array[512, Bitboard]])
    var rookMoves = rookMovesFile.fromJSON(array[Square(0)..Square(63), array[4096, Bitboard]])

    ROOK_MAGICS = magics["rooks"]
    BISHOP_MAGICS = magics["bishops"]
    ROOK_MOVES = rookMoves
    BISHOP_MOVES = bishopMoves
