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


# Shared constants

const
    MAX_DEPTH* = 255

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
    

    SearchState* = ref object
        ## A container for the the portion of
        ## search state that is meant to be accessed
        ## from outside of the search manager in a
        ## thread-safe manner

        # Atomic booleans to control/inspect
        # the state of the search
        searching*: Atomic[bool]
        stop*: Atomic[bool]
        pondering*: Atomic[bool]
        # When was the search started?
        searchStart*: Atomic[MonoTime]
        # Are we playing chess960?
        chess960*: Atomic[bool]
        # Are we in UCI mode?
        uciMode*: Atomic[bool]
        # Are we the main thread?
        isMainThread*: Atomic[bool]
        # Do we print normalized scores?
        normalizeScore*: Atomic[bool]
        # Do we print predicted win/draw/loss probabilities?
        showWDL*: Atomic[bool]

        # This is contained in the search state to
        # avoid cyclic references inside SearchStatistics
        childrenStats*: seq[SearchStatistics]



proc newSearchState*: SearchState =
    new(result)


proc newSearchStatistics*: SearchStatistics =
    new(result)
