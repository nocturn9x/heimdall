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
        case kind: LimitKind
            of Time:
                startTime: MonoTime
            of Depth:
                currentDepth: uint64
            of Nodes:
                currentNodes: uint64
            else:
                discard
        upperBound: uint64
        lowerBound: uint64

    SearchLimiter* = ref object
        limits: seq[SearchLimit]
        searchStart: MonoTime


proc newSearchLimiter*(searchStart=getMonoTime()): SearchLimiter =
    ## Initializes a new, blank search
    ## clock
    new(result)
    result.searchStart = searchStart


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


proc init(self: SearchLimit, limiter: SearchLimiter) =
    ## Initializes the given limit wrt.
    ## the given limiter
    case self.kind:
        of Time:
            self.startTime = limiter.searchStart
        of Nodes:
            self.currentNodes = 0
        of Depth:
            self.currentDepth = 0
        else:
            discard


proc init*(self: SearchLimiter, searchStart=getMonoTime()) =
    ## Initializes the limiter
    self.searchStart = searchStart
    for limit in self.limits:
        limit.init(self)


proc update*(self: SearchLimit, depth: uint64, eval: Score, bestMove: Move, nodes: uint64) =
    ## Updates the given limit with the given information
    ## about the ongoing search, if necessary
    case self.kind:
        of Depth:
            self.currentDepth = depth
        of Nodes:
            self.currentNodes = nodes
        else:
            discard


proc update(self: SearchLimiter, depth: uint64, eval: Score, bestMove: Move, nodes: uint64) =
    ## Updates time limits with the given information
    ## about the ongoing search, if necessary
    for limit in self.limits:
        limit.update(depth, eval, bestMove, nodes)


proc elapsedMsec(startTime: MonoTime): int64 = (getMonoTime() - startTime).inMilliseconds()


proc expired(self: SearchLimit, pondering: bool, inTree=true): bool =
    ## Returns whether the given limit
    ## has expired
    case self.kind:
        of Depth:
            return self.currentDepth >= self.upperBound
        of Nodes:
            if self.currentNodes >= self.upperBound:
                return true
            if not inTree and self.lowerBound > 0 and self.currentNodes >= self.lowerBound:
                return true
        of Time:
            if pondering:
                return false
            let elapsed = self.startTime.elapsedMsec().uint64
            if elapsed >= self.upperBound:
                return true
            if not inTree and elapsed >= self.lowerBound:
                return true
        else:
            # TODO
            discard


proc expired*(self: SearchLimiter, depth: uint64, eval: Score, bestMove: Move, nodes: uint64, pondering: bool, inTree=true): bool =
    ## Returns whether any of the limits
    ## in the limiter has expired according
    ## to the given information about the
    ## ongoing search. If inTree equals true,
    ## soft limits will not apply
    self.update(depth, eval, bestMove, nodes)

    for limit in self.limits:
        if limit.expired(pondering, inTree):
            return true
