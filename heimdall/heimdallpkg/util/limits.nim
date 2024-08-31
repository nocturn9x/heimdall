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

## Time management routines for Heimdall's search
import std/monotimes
import std/atomics
import std/times


import heimdallpkg/moves
import heimdallpkg/util/shared
import heimdallpkg/util/tunables


type
    LimitKind* = enum
        MovesToGo, Time,
        Infinite, Nodes,
        Depth
    
    SearchLimit* = ref object
        kind: LimitKind
        upperBound: uint64
        lowerBound: uint64

    SearchLimiter* = ref object
        limits: seq[SearchLimit]
        searchState: SearchState
        searchStats: SearchStatistics


proc newSearchLimiter*(state: SearchState, statistics: SearchStatistics): SearchLimiter =
    ## Initializes a new, blank search
    ## clock
    new(result)
    result.searchState = state
    result.searchStats = statistics


proc newSearchLimit(kind: LimitKind, lowerBound, upperBound: uint64): SearchLimit =
    ## Initializes a limit with the given kind
    ## and upper/lower bounds
    new(result)
    result.kind = kind
    result.upperBound = upperBound
    result.lowerBound = lowerBound


proc newDepthLimit*(maxDepth: int): SearchLimit =
    ## Initializes a new depth limit with
    ## the given maximum depth
    return newSearchLimit(Depth, maxDepth.uint64, maxDepth.uint64)


proc newNodeLimit*(softLimit, hardLimit: uint64): SearchLimit =
    ## Initializes a new node limit with the given
    ## soft/hard limits
    return newSearchLimit(Nodes, softLimit, hardLimit)


proc newNodeLimit*(maxNodes: uint64): SearchLimit =
    ## Initializes a new node hard limit
    return newSearchLimit(Nodes, maxNodes, maxNodes)


proc newTimeLimit*(remainingTime, increment, overhead: int64): SearchLimit =
    ## Initializes a new time limit with the given
    ## remaining time, increment and move overhead
    ## values

    # If the remaining time is negative, assume we've been
    # given overtime and search for a sensible amount of time
    var remainingTime = if remainingTime < 0: 500 else: remainingTime
    remainingTime -= overhead
    let hardLimit = (remainingTime div 10) + ((increment div 3) * 2)
    let softLimit = hardLimit div 3
    result = newSearchLimit(Time, softLimit.uint64, hardLimit.uint64)


proc newTimeLimit*(timePerMove, overhead: uint64): SearchLimit =
    ## Initializes a new time limit with the
    ## given per-move time and overhead values

    let limit = timePerMove - overhead
    return newSearchLimit(Time, limit, limit)


proc addLimit*(self: SearchLimiter, limit: SearchLimit) =
    ## Adds the given limit to the limiter if
    ## not already present
    if limit notin self.limits:
        self.limits.add(limit)


proc removeLimit*(self: SearchLimiter, limit: SearchLimit) =
    ## Removes the given limit from the limiter, if
    ## present
    let idx = self.limits.find(limit)
    if idx != -1:
        self.limits.delete(idx)


proc reset*(self: SearchLimiter) =
    ## Resets the given limiter, clearing all
    ## limits, so it can be initialized again
    ## with fresh ones
    self.limits = @[]

proc elapsedMsec(startTime: MonoTime): int64 {.inline.} = (getMonoTime() - startTime).inMilliseconds()


proc expired(self: SearchLimit, limiter: SearchLimiter, inTree=true): bool =
    ## Returns whether the given limit
    ## has expired
    case self.kind:
        of Depth:
            return limiter.searchStats.highestDepth.load().uint64 >= self.upperBound
        of Nodes:
            let nodes = limiter.searchStats.nodeCount.load()
            if nodes >= self.upperBound:
                return true
            if not inTree and self.lowerBound > 0 and nodes >= self.lowerBound:
                return true
        of Time:
            if limiter.searchState.pondering.load() or (inTree and limiter.searchStats.nodeCount.load() mod 1024 != 0):
                return false
            let elapsed = limiter.searchState.searchStart.load().elapsedMsec().uint64
            if elapsed >= self.upperBound:
                return true
            if not inTree and elapsed >= self.lowerBound:
                return true
        else:
            # TODO
            discard


proc expired*(self: SearchLimiter, inTree=true): bool {.inline.} =
    ## Returns whether any of the limits
    ## in the limiter has expired according
    ## to the current information about the
    ## ongoing search. If inTree equals true,
    ## soft limits will not apply
    for limit in self.limits:
        if limit.expired(self, inTree):
            return true

proc scale(self: SearchLimit, limiter: SearchLimiter, params: SearchParameters) {.inline.} =
    if self.kind != Time or self.upperBound == self.lowerBound or limiter.searchStats.highestDepth.load() < params.nodeTmDepthThreshold:
        # Nothing to scale (limit is not time
        # based or it's a movetime limit) or
        # depth is too shallow
        return
    let 
        move = limiter.searchStats.bestMove.load()
        totalNodes = limiter.searchStats.nodeCount.load()
        bestMoveNodes = limiter.searchStats.spentNodes[move.startSquare][move.targetSquare].load()
        bestMoveFrac = bestMoveNodes.float / totalNodes.float
        newSoftBound = params.nodeTmBaseOffset - bestMoveFrac * params.nodeTmScaleFactor
    self.lowerBound = min(self.upperBound, uint64(newSoftBound * 1000))


proc scale*(self: SearchLimiter, params: SearchParameters) {.inline.} =
    ## Scales search limits (if they can be scaled)
    ## according to the current state of the search
    ## and the given set of parameters
    for limit in self.limits:
        limit.scale(self, params)
    