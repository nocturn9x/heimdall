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

## ThreatDiff arithmetic, independent of chess geometry or network fixtures.
## Build through make dev MAIN=tests/test_threat_diff.nim IS_TEST=1.
include heimdall/threats/updates

# Deliberately vary both feature and neuron axes, including signed i8 limits.
# Row zero is nonzero so accidentally reading an unused queue slot is visible.
var weights: ThreatWeights
for neuron in 0..<L1_SIZE:
    weights[0][neuron] = 71
    weights[5][neuron] = -128
    weights[97][neuron] = 127
    weights[TOTAL_THREATS - 1][neuron] = (neuron mod 15 - 7).int8

var cases = 0

proc check(diff: var ThreatDiff, whiteDelta, blackDelta: array[L1_SIZE, int16]) =
    for side in White..Black:
        var parent {.align(ALIGNMENT_BOUNDARY).}: array[L1_SIZE, int16]
        var child {.align(ALIGNMENT_BOUNDARY).}: array[L1_SIZE, int16]
        for neuron in 0..<L1_SIZE:
            parent[neuron] = (300 - 23 * (neuron mod 32)).int16
            child[neuron] = -999
        let saved = parent
        let delta = if side == White: whiteDelta else: blackDelta
        diff.apply(weights, side, parent, child)
        doAssert parent == saved, "applying a diff modified its parent"
        for neuron in 0..<L1_SIZE:
            doAssert child[neuron] == saved[neuron] + delta[neuron],
                "wrong TI arithmetic for " & $side & " at lane " & $neuron
        inc(cases)

# Empty, additions only, removals only, and unequal mixed counts. Each
# perspective intentionally uses different rows and different prefix lengths.
for hasAdds in [false, true]:
    for hasSubs in [false, true]:
        var diff: ThreatDiff
        var whiteDelta, blackDelta: array[L1_SIZE, int16]
        if hasAdds:
            diff.adds.whiteCnt = 2
            diff.adds.white[0] = 5
            diff.adds.white[1] = 97
            diff.adds.blackCnt = 1
            diff.adds.black[0] = (TOTAL_THREATS - 1).uint16
        if hasSubs:
            diff.subs.whiteCnt = 1
            diff.subs.white[0] = (TOTAL_THREATS - 1).uint16
            diff.subs.blackCnt = 2
            diff.subs.black[0] = 5
            diff.subs.black[1] = 97
        for neuron in 0..<L1_SIZE:
            let last = (neuron mod 15 - 7).int16
            whiteDelta[neuron] = (if hasAdds: -1'i16 else: 0) - (if hasSubs: last else: 0)
            blackDelta[neuron] = (if hasAdds: last else: 0) + (if hasSubs: 1'i16 else: 0)
        check(diff, whiteDelta, blackDelta)

# Equal add/remove features must cancel exactly, including repeated indices.
block cancelling:
    var diff: ThreatDiff
    diff.adds.whiteCnt = 3
    diff.adds.white[0..2] = [5'u16, 97, 5]
    diff.adds.blackCnt = 2
    diff.adds.black[0..1] = [97'u16, 5]
    diff.subs = diff.adds
    check(diff, default(array[L1_SIZE, int16]), default(array[L1_SIZE, int16]))

# Use every slot, then exercise large unmatched remainders. These are queue
# capacity checks, not claims that a legal move can produce 128 equal threats.
for counts in [(128, 128), (128, 1), (1, 128), (128, 0), (0, 128)]:
    var diff: ThreatDiff
    diff.adds.whiteCnt = counts[0]
    diff.subs.whiteCnt = counts[1]
    diff.adds.blackCnt = counts[1]
    diff.subs.blackCnt = counts[0]
    for i in 0..<128:
        diff.adds.white[i] = 97
        diff.subs.white[i] = 97
        diff.adds.black[i] = 5
        diff.subs.black[i] = 5
    var whiteDelta, blackDelta: array[L1_SIZE, int16]
    for neuron in 0..<L1_SIZE:
        whiteDelta[neuron] = ((counts[0] - counts[1]) * 127).int16
        blackDelta[neuron] = ((counts[0] - counts[1]) * 128).int16
    check(diff, whiteDelta, blackDelta)

block fullRefresh:
    var accumulator {.align(ALIGNMENT_BOUNDARY).}: array[L1_SIZE, int16]
    var repeated = newSeq[uint16](128)
    for feature in repeated.mitems:
        feature = 5
    for indices in [newSeq[uint16](), @[5'u16], @[(TOTAL_THREATS - 1).uint16],
                    @[5'u16, 97, (TOTAL_THREATS - 1).uint16], repeated]:
        for value in accumulator.mitems:
            value = 1234
        accumulator.applyAllRowsZeroed(weights, indices)
        # Independent scalar sum, including the empty-list zeroing case.
        for neuron in 0..<L1_SIZE:
            var expected = 0'i32
            for feature in indices:
                expected += weights[feature][neuron].int32
            doAssert accumulator[neuron].int32 == expected,
                "wrong TI rebuild at lane " & $neuron
        inc(cases)

when defined(simd):
    block signedByteLoad:
        # Exercise every signed byte value and a deliberately unaligned source.
        var source {.align(ALIGNMENT_BOUNDARY).}: array[CHUNK_SIZE + 1, int8]
        var widened {.align(ALIGNMENT_BOUNDARY).}: array[CHUNK_SIZE, int16]
        for base in countup(0, 255, CHUNK_SIZE):
            for lane in 0..<CHUNK_SIZE:
                source[lane + 1] = (base + lane - 128).int8
            vecStore(addr widened[0], vecLoadI8AsI16(addr source[1]))
            for lane in 0..<CHUNK_SIZE:
                doAssert widened[lane] == (base + lane - 128).int16
    echo "TI backend: SIMD; all 256 signed-byte values widened correctly"
else:
    echo "TI backend: scalar"

echo "ThreatDiff: ", cases, " arithmetic/rebuild cases passed at width ", L1_SIZE

printSimdInfo()
