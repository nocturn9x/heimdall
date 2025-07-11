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

## Time management routines for Heimdall's search
import std/times
import std/atomics
import std/options
import std/monotimes


import heimdall/eval
import heimdall/moves
import heimdall/util/shared
import heimdall/util/tunables


type
    LimitKind* = enum
        Time, Nodes, Depth, Mate
    
    SearchLimit* = object
        kind: LimitKind
        upperBound: uint64
        lowerBound: uint64
        origLowerBound: uint64
        scalable: bool

    SearchLimiter* = object
        enabled: bool
        hardTimeLimitReached: bool
        startTimeOverride: Option[MonoTime]
        limits: seq[SearchLimit]
        searchState: SearchState
        searchStats: SearchStatistics


func hardTimeLimitReached*(self: SearchLimiter): bool {.inline.} = self.hardTimeLimitReached


proc newSearchLimiter*(state: SearchState, statistics: SearchStatistics): SearchLimiter =
    ## Initializes a new, blank search
    ## clock
    result.enabled = true
    result.searchState = state
    result.searchStats = statistics


proc enable*(self: var SearchLimiter, overrideStartTime: bool = false) =
    self.enabled = true
    if overrideStartTime:
        self.startTimeOverride = some(getMonoTime())


proc disable*(self: var SearchLimiter) =
    self.enabled = false


proc newSearchLimit(kind: LimitKind, lowerBound, upperBound: uint64): SearchLimit =
    ## Initializes a limit with the given kind
    ## and upper/lower bounds
    result.kind = kind
    result.upperBound = upperBound
    result.lowerBound = lowerBound
    result.origLowerBound = lowerBound


proc newDepthLimit*(maxDepth: int): SearchLimit =
    ## Initializes a new depth limit with
    ## the given maximum depth
    return newSearchLimit(Depth, maxDepth.uint64, maxDepth.uint64)


proc newNodeLimit*(softLimit, hardLimit: uint64): SearchLimit =
    ## Initializes a new node limit with the given
    ## soft/hard constraints
    return newSearchLimit(Nodes, softLimit, hardLimit)


proc newNodeLimit*(maxNodes: uint64): SearchLimit =
    ## Initializes a new node hard limit
    return newSearchLimit(Nodes, maxNodes, maxNodes)


proc newTimeLimit*(remainingTime, increment, overhead: int64): SearchLimit =
    ## Initializes a new time limit with the given
    ## remaining time, increment and move overhead
    ## values
    
    let remainingTime = block:
        # If the remaining time is negative, assume we've been
        # given overtime and search for a sensible amount of time
        let t = remainingTime - overhead
        if t < 0:
            500
        else:
            t
    var hardLimit = remainingTime div 10 + (increment * 2) div 3
    var softLimit = hardLimit div 3
    hardLimit = hardLimit.clamp(0, remainingTime)
    softLimit = softLimit.clamp(0, hardLimit)
    result = newSearchLimit(Time, softLimit.uint64, hardLimit.uint64)
    result.scalable = true


proc newTimeLimit*(timePerMove, overhead: int64): SearchLimit =
    ## Initializes a new time limit with the
    ## given per-move time and overhead values

    let limit = block:
        let t = timePerMove - overhead
        if t < 0:
            500
        else:
            t
    return newSearchLimit(Time, limit.uint64, limit.uint64)


proc newMateLimit*(moves: int): SearchLimit =
    return newSearchLimit(Mate, moves.uint64, moves.uint64)


proc addLimit*(self: var SearchLimiter, limit: SearchLimit) =
    ## Adds the given limit to the limiter if
    ## not already present
    self.limits.add(limit)


proc clear*(self: var SearchLimiter) =
    ## Resets the given limiter, clearing all
    ## limits but without re-enabling it
    self.limits = @[]
    self.hardTimeLimitReached = false
    self.startTimeOverride = none(MonoTime)


proc elapsedMsec(startTime: MonoTime): int64 {.inline.} = (getMonoTime() - startTime).inMilliseconds()

proc elapsedMsec(self: SearchLimiter): uint64 {.inline.} =
    if self.startTimeOverride.isNone():
        return self.searchState.searchStart.load().elapsedMsec().uint64
    else:
        return self.startTimeOverride.get().elapsedMsec().uint64


proc totalNodes(self: SearchLimiter): uint64 {.inline.} =
    result = self.searchStats.nodeCount.load()
    for child in self.searchState.childrenStats:
        result += child.nodeCount.load()


proc expiredSoft(self: SearchLimit, limiter: SearchLimiter): bool {.inline.} =
    ## Returns whether the soft bound of
    ## the given limit has been reached
    case self.kind:
        of Mate:
            # Don't exit until we've looked at all options to ensure the mate
            # is sound
            return false
        of Depth:
            # No soft limit for depth
            return false
        of Nodes:
            return self.lowerBound > 0 and limiter.totalNodes() >= self.lowerBound
        of Time:
            if not limiter.searchState.isMainThread.load() or limiter.searchState.pondering.load():
                # We don't check for time if:
                # - We're pondering
                # - We're not the main thread
                # We don't check for the same nodes % 1024 condition
                # as in the hard limit because the soft limit is checked
                # far less often and that would basically always be false
                return false
            return limiter.elapsedMsec() >= self.lowerBound


proc expiredHard*(self: SearchLimit, limiter: var SearchLimiter): bool {.inline.} =
    ## Returns whether the hard bound of
    ## the given limit has been reached
    case self.kind:
        of Mate:
            let bestScore = limiter.searchStats.bestRootScore.load()
            if bestScore.isMateScore():
                # A mate is found
                let moves = uint64(if bestScore > 0: ((mateScore() - bestScore + 1) div 2) else: ((mateScore() + bestScore) div 2))
                return self.lowerBound == moves
            return false
        of Depth:
            return limiter.searchStats.highestDepth.load().uint64 >= self.upperBound
        of Nodes:
            return limiter.totalNodes() >= self.upperBound
        of Time:
            if not limiter.searchState.isMainThread.load() or limiter.searchState.pondering.load() or limiter.searchStats.nodeCount.load() mod 1024 != 0:
                # We don't check for time if:
                # - We're pondering
                # - We're not the main thread
                # - We are in the middle of an ID iteration and
                #   the node count for the main thread is not a
                #   multiple of 1024
                return false
            limiter.hardTimeLimitReached = limiter.elapsedMsec() >= self.upperBound
            return limiter.hardTimeLimitReached


proc expiredHard*(self: var SearchLimiter): bool {.inline.} =
    ## Returns whether any of hard the limits
    ## in the limiter have expired according
    ## to the current information about the
    ## ongoing search
    if not self.enabled:
        return false
    for limit in self.limits:
        if limit.expiredHard(self):
            return true


proc expiredSoft*(self: SearchLimiter): bool {.inline.} =
    ## Returns whether any of soft the limits
    ## in the limiter have expired according
    ## to the current information about the
    ## ongoing search
    if not self.enabled:
        return false
    for limit in self.limits:
        if limit.expiredSoft(self):
            return true



proc scale(self: var SearchLimit, limiter: SearchLimiter, params: SearchParameters) {.inline.} =
    const NODE_TM_DEPTH_THRESHOLD = 5

    if limiter.searchStats.highestDepth.load() < NODE_TM_DEPTH_THRESHOLD or not self.scalable:
        return
    let 
        move = limiter.searchStats.bestMove.load()
        totalNodes = limiter.searchStats.nodeCount.load()
        bestMoveNodes = limiter.searchStats.spentNodes[move.startSquare][move.targetSquare].load()
        bestMoveFrac = bestMoveNodes.float / totalNodes.float
        scaleFactor = params.nodeTmBaseOffset - bestMoveFrac * params.nodeTmScaleFactor
    self.lowerBound = min(self.upperBound, (self.origLowerBound.float * scaleFactor).uint64)


proc scale*(self: var SearchLimiter, params: SearchParameters) {.inline.} =
    ## Scales search limits (if they can be scaled)
    ## according to the current state of the search
    ## and the given set of parameters
    for limit in self.limits.mitems():
        limit.scale(self, params)
    