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

## Shared stuff that can go across threads (somewhat) safely
import std/atomics
import std/monotimes


import heimdallpkg/eval
import heimdallpkg/moves
import heimdallpkg/pieces


type
    SearchStatistics* = ref object
        # The total number of nodes
        # explored
        nodeCount*: Atomic[uint64]
        # The highest depth we explored to, including extensions
        selectiveDepth*: Atomic[int]
        # The highest fully cleared depth
        highestDepth*: Atomic[int]
        # The current principal variation being
        # explored
        currentVariation*: Atomic[int]
        # The best score we found at root
        bestRootScore*: Atomic[Score]
        # The current best move
        bestMove*: Atomic[Move]
        # How many nodes were spent on each
        # move, indexed by from/to square,
        # across the entire search
        spentNodes*: array[Square(0)..Square(63), array[Square(0)..Square(63), Atomic[uint64]]]
    
    # Note: stuff that is not wrapped in an atomic is *not*
    # meant to be used outside of the search manager. Proceed
    # at your own risk


    SearchState* = ref object
        # Atomic booleans to control/inspect
        # the state of the search
        searching*: Atomic[bool]
        stop*: Atomic[bool]
        pondering*: Atomic[bool]
        # Has a call to limiter.expired() returned
        # true before? This allows us to avoid re-
        # checking for time once a limit expires
        expired*: Atomic[bool]
        # When was the search started?
        searchStart*: Atomic[MonoTime]
        # When pondering is disabled, this is the same
        # as searchStart. When it is enabled, this marks
        # the point in time when pondering stopped: this
        # is useful because we want to start accounting
        # for our own time only after we stop pondering!
        stoppedPondering*: Atomic[MonoTime]
        # Are we playing chess960?
        chess960*: Atomic[bool]
        # Are we in UCI mode?
        uciMode*: Atomic[bool]
        # Are we the main thread?
        isMainThread*: Atomic[bool]

        # This is contained in the search state to
        # avoid cyclic references inside SearchStatistics
        childrenStats*: seq[SearchStatistics]

        # All static evaluations
        # for every ply of the search
        evals* {.align(64).}: array[255, Score]
        # List of moves made for each ply
        moves* {.align(64).}: array[255, Move]
        # List of pieces that moved for each
        # ply
        movedPieces* {.align(64).}: array[255, Piece]
        # The set of principal variations for each ply
        # of the search. We keep one extra entry so we
        # don't need any special casing inside the search
        # function when constructing pv lines
        pvMoves* {.align(64).}: array[255 + 1, array[255 + 1, Move]]
        # The persistent evaluation state needed
        # for NNUE
        evalState*: EvalState
        # Has the internal clock been started yet?
        clockStarted*: bool

proc newSearchState*: SearchState =
    new(result)
    for i in 0..255:
        for j in 0..255:
            result.pvMoves[i][j] = nullMove()


proc newSearchStatistics*: SearchStatistics =
    new(result)
