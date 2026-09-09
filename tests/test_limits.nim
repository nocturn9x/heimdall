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
#
# Authored with assistance from AI agents.

## Deterministic limiter checks, including depth/MultiPV and mixed hard limits.
## Build via make dev MAIN=tests/test_limits.nim IS_TEST=1 with absolute EVALFILE.
import std/[atomics, monotimes, times]
import heimdall/eval
import heimdall/util/[limits, shared]

let
    state = newSearchState()
    stats = newSearchStatistics()
    child = newSearchStatistics()
var limiter = newSearchLimiter(state, stats)
state.isMainThread.store(true, moRelaxed)
state.searchStart.store(getMonoTime(), moRelaxed)
state.childrenStats = @[child]

# Depth is checked between complete iterations, never between MultiPV lines.
# Generous node/time limits must not bring back a hard-depth cutoff.
for withNodes in [false, true]:
    for withTime in [false, true]:
        limiter.clear()
        limiter.addLimit(newDepthLimit(2))
        if withNodes:
            limiter.addLimit(newNodeLimit(1_000_000))
        if withTime:
            limiter.addLimit(newTimeLimit(100_000, 0))
        stats.highestDepth.store(1, moRelaxed)
        doAssert not limiter.expiredSoft()
        for variation in 1..3:
            stats.currentVariation.store(variation, moRelaxed)
            stats.highestDepth.store(2, moRelaxed)
            doAssert not limiter.expiredHard()
        doAssert limiter.expiredSoft()

# Actual hard budgets can still interrupt an iteration, with either limit order.
for depthFirst in [false, true]:
    limiter.clear()
    if depthFirst:
        limiter.addLimit(newDepthLimit(2))
    limiter.addLimit(newNodeLimit(10))
    if not depthFirst:
        limiter.addLimit(newDepthLimit(2))
    stats.nodeCount.store(6, moRelaxed)
    child.nodeCount.store(3, moRelaxed)
    doAssert not limiter.expiredHard()
    child.nodeCount.store(4, moRelaxed)
    doAssert limiter.expiredHard()
    doAssert limiter.hardLimitReached()
    limiter.disable()
    doAssert not limiter.expiredHard()
    doAssert not limiter.expiredSoft()
    limiter.enable()
    doAssert limiter.expiredHard()
    limiter.clear()
    doAssert not limiter.expiredHard()
    doAssert not limiter.hardLimitReached()
    child.nodeCount.store(0, moRelaxed)

# A time limit must not gate node-budget checks on the 1024-node clock cadence.
for timeFirst in [false, true]:
    limiter.clear()
    if timeFirst:
        limiter.addLimit(newTimeLimit(100_000, 0))
    limiter.addLimit(newNodeLimit(10))
    if not timeFirst:
        limiter.addLimit(newTimeLimit(100_000, 0))
    stats.nodeCount.store(9, moRelaxed)
    doAssert not limiter.expiredHard()
    stats.nodeCount.store(10, moRelaxed)
    state.pondering.store(true, moRelaxed)
    doAssert not limiter.expiredHard()
    state.pondering.store(false, moRelaxed)
    doAssert limiter.expiredHard()

# Mate-only searches also stop between iterations, not inside the tree.
limiter.clear()
doAssert not limiter.expiredSoft()
doAssert not limiter.expiredHard()
limiter.addLimit(newMateLimit(2))
stats.bestRootScore.store(0, moRelaxed)
doAssert not limiter.expiredSoft()
stats.bestRootScore.store(mateIn(4), moRelaxed)
doAssert limiter.expiredSoft()
doAssert not limiter.expiredHard()
limiter.addLimit(newNodeLimit(10))
doAssert limiter.expiredHard()

# An expired clock is sampled at 1024-node boundaries, only by the main thread.
for withDepth in [false, true]:
    limiter.clear()
    if withDepth:
        limiter.addLimit(newDepthLimit(2))
    limiter.addLimit(newTimeLimit(1, 0))
    state.searchStart.store(getMonoTime() - initDuration(seconds=1), moRelaxed)
    stats.nodeCount.store(1023, moRelaxed)
    doAssert not limiter.expiredHard()
    stats.nodeCount.store(1024, moRelaxed)
    state.pondering.store(true, moRelaxed)
    doAssert not limiter.expiredHard()
    doAssert not limiter.expiredSoft()
    state.pondering.store(false, moRelaxed)
    state.isMainThread.store(false, moRelaxed)
    doAssert not limiter.expiredHard()
    state.isMainThread.store(true, moRelaxed)
    doAssert limiter.expiredHard()
    limiter.resetHardLimit()
    doAssert not limiter.hardLimitReached()
    doAssert limiter.expiredHard()
    limiter.clear()
    limiter.addLimit(newTimeLimit(100_000, 0))
    state.searchStart.store(getMonoTime() - initDuration(hours=1), moRelaxed)
    doAssert limiter.expiredHard()
    limiter.resetHardLimit()
    limiter.enable(overrideStartTime=true)
    doAssert not limiter.expiredHard()
    limiter.clear()
    limiter.addLimit(newTimeLimit(100_000, 0))
    doAssert limiter.expiredHard()

echo "Search limits: depth boundaries, mixed budgets, workers, clocks and resets passed"
