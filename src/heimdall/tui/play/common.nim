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


proc formatConfiguredLimit*(limit: PlayLimitConfig): string =
    var parts: seq[string]

    if limit.timeControl.isSome():
        let tc = limit.timeControl.get()
        let mins = tc.timeMs div 60_000
        let secs = (tc.timeMs mod 60_000) div 1000
        let incSecs = tc.incrementMs div 1000
        if incSecs > 0:
            parts.add(&"{mins}m+{incSecs}s")
        else:
            parts.add(&"{mins}m{secs}s")

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
