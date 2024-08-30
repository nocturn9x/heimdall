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
import std/times


import heimdallpkg/eval
import heimdallpkg/moves


type
    LimitKind* = enum
        TimePerMove, MovesToGo, Time,
        Infinite, Nodes, Depth
    
    SearchLimit* = ref object
        kind: LimitKind
        upperBound: uint64
        lowerBound: uint64

    SearchLimiter* = ref object
        limits: seq[SearchLimit]
        searchStart: MonoTime
        highestDepth: uint64
        totalNodes: uint64
        bestScore: Score
        bestMove: Move
        pondering: bool


proc newSearchLimiter*: SearchLimiter =
    ## Initializes a new, blank search
    ## clock
    new(result)


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


proc init*(self: SearchLimiter, searchStart=getMonoTime()) =
    ## Initializes the limiter
    self.searchStart = searchStart
    self.totalNodes = 0
    self.highestDepth = 0


proc update*(self: SearchLimiter, highestDepth: uint64, bestScore: Score, bestMove: Move, totalNodes: uint64, pondering: bool) =
    ## Updates time limits with the given information
    ## about the ongoing search, if necessary
    self.highestDepth = highestDepth
    self.totalNodes = totalNodes
    self.bestMove = bestMove
    self.bestScore = bestScore
    self.pondering = pondering


proc elapsedMsec(startTime: MonoTime): int64 {.inline.} = (getMonoTime() - startTime).inMilliseconds()


proc expired(self: SearchLimit, limiter: SearchLimiter, inTree=true): bool =
    ## Returns whether the given limit
    ## has expired
    case self.kind:
        of Depth:
            return limiter.highestDepth >= self.upperBound
        of Nodes:
            if limiter.totalNodes >= self.upperBound:
                return true
            if not inTree and self.lowerBound > 0 and limiter.totalNodes >= self.lowerBound:
                return true
        of Time:
            if limiter.pondering:
                return false
            let elapsed = limiter.searchStart.elapsedMsec().uint64
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
