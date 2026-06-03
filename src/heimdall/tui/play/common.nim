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

## Shared play-mode limit and clock helpers.

import std/[options, strformat, strutils]

import heimdall/util/limits
import heimdall/tui/state
import heimdall/tui/util/clock


template startTrackedClock*(clock, moveStartRemainingMs: untyped) =
    moveStartRemainingMs = clock.remainingMs
    clock.start()


const
    EngineLimitExamples* = "same | 5m+3s | depth 20 | 5m+3s, depth 20 | softnodes 100000"
    WatchLimitExamples* = "5m+3s | depth 20 | 5m+3s, depth 20 | softnodes 100000 | none"
    WatchBlackLimitExamples* = "same | 5m+3s | depth 20 | 5m+3s, depth 20 | softnodes 100000"


proc newUnlimitedPlayLimit*(): PlayLimitConfig =
    PlayLimitConfig()


proc newTimeOrUnlimitedLimit*(timeMs, incrementMs: int64): PlayLimitConfig =
    if timeMs == 0:
        result = newUnlimitedPlayLimit()
    else:
        result.timeControl = some(TimeControlConfig(timeMs: timeMs, incrementMs: incrementMs))


proc newDepthPlayLimit*(depth: int): PlayLimitConfig =
    PlayLimitConfig(depth: some(depth))


proc newNodePlayLimit*(nodes: uint64): PlayLimitConfig =
    PlayLimitConfig(nodeLimit: some(NodeLimitConfig(softNodes: none(uint64), hardNodes: some(nodes))))


proc newSoftNodePlayLimit*(softNodes: uint64, hardNodes: Option[uint64]): PlayLimitConfig =
    PlayLimitConfig(nodeLimit: some(NodeLimitConfig(softNodes: some(softNodes), hardNodes: hardNodes)))


proc limitClock*(limit: PlayLimitConfig): ChessClock =
    if limit.timeControl.isSome():
        let tc = limit.timeControl.get()
        return newClock(tc.timeMs, tc.incrementMs)
    return newClock(int64.high div 2, 0)


proc isTimeManaged*(limit: PlayLimitConfig): bool =
    limit.timeControl.isSome()


proc formatClockComponent(ms: int64): string =
    ## Compact, exact rendering of a duration, e.g. "5m", "1m30s", "20s", "0.1s".
    ## Zero components are omitted; sub-second values keep their fractional part.
    let totalMs = max(0'i64, ms)
    let hours = totalMs div 3_600_000
    let mins = (totalMs mod 3_600_000) div 60_000
    let secMs = totalMs mod 60_000
    if hours > 0:
        result &= &"{hours}h"
    if mins > 0:
        result &= &"{mins}m"
    if secMs > 0 or result.len == 0:
        let whole = secMs div 1000
        let frac = secMs mod 1000
        if frac == 0:
            result &= &"{whole}s"
        else:
            let fracStr = align($frac, 3, '0').strip(leading = false, chars = {'0'})
            result &= &"{whole}.{fracStr}s"


proc formatConfiguredLimit*(limit: PlayLimitConfig): string =
    var parts: seq[string]

    if limit.timeControl.isSome():
        let tc = limit.timeControl.get()
        var tcStr = formatClockComponent(tc.timeMs)
        if tc.incrementMs > 0:
            tcStr &= "+" & formatClockComponent(tc.incrementMs)
        parts.add(tcStr)

    if limit.depth.isSome():
        parts.add("depth " & $limit.depth.get())

    if limit.nodeLimit.isSome():
        let nodeLimit = limit.nodeLimit.get()
        if nodeLimit.softNodes.isSome():
            parts.add("softnodes " & $nodeLimit.softNodes.get())
        if nodeLimit.hardNodes.isSome():
            parts.add("nodes " & $nodeLimit.hardNodes.get())

    if parts.len == 0:
        return "unlimited"
    parts.join(", ")


proc buildSearchLimits*(limit: PlayLimitConfig, clock: ChessClock): seq[SearchLimit] =
    if limit.timeControl.isSome():
        result.add(newTimeLimit(clock.remainingMs, clock.incrementMs, 250))
    if limit.depth.isSome():
        result.add(newDepthLimit(limit.depth.get()))
    if limit.nodeLimit.isSome():
        let nodeLimit = limit.nodeLimit.get()
        if nodeLimit.softNodes.isSome() and nodeLimit.hardNodes.isSome():
            result.add(newNodeLimit(nodeLimit.softNodes.get(), nodeLimit.hardNodes.get()))
        elif nodeLimit.hardNodes.isSome():
            result.add(newNodeLimit(nodeLimit.hardNodes.get()))
        elif nodeLimit.softNodes.isSome():
            result.add(newNodeLimit(nodeLimit.softNodes.get(), uint64.high))
