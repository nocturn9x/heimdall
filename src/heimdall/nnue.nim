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


# Thanks @analog-hors for the contribution! The code below is heavily derived from hers :)
import heimdall/pieces
import std/streams

import heimdall/util/memory/aligned


when defined(simd):
    import heimdall/util/simd


const
    ALIGNMENT_BOUNDARY* = 64
    # Note: these variables can be controlled with -d:XX=YY options,
    # so check the Makefile for their actual values (if none is provided
    # via the define option then the value shown here is used instead).
    # Note to Nim users: please avoid using nim.cfg as it creates confusion
    # to have a variable be potentially defined in multiple places!
    FT_SIZE* {.define: "ftSize".} = 768
    L1_SIZE* {.define: "l1Size".} = 256
    L2_SIZE* {.define: "l2Size".} = 32
    L3_SIZE* {.define: "l3Size".} = 16
    EVAL_SCALE* {.define: "evalScale".} = 400
    # Controls for weight quantization (handled via shifts)
    FT_QUANT_BITS* {.define: "ftQuantBits".} = 8
    QA* = (1 shl FT_QUANT_BITS) - 1
    L1_QUANT_BITS* {.define: "l1QuantBits".} = 7
    QUANT_BITS* {.define: "quantBits".} = 6
    FT_SCALE_BITS* {.define: "ftScaleBits".} = 7
    # Number of king input buckets
    NUM_INPUT_BUCKETS* {.define: "inputBuckets".} = 4
    NUM_OUTPUT_BUCKETS* {.define: "outputBuckets".} = 8
    MERGED_KINGS* {.booldefine: "mergedKings".} = true
    MIRRORED* {.booldefine: "horizontalMirroring".} = true
    VERBATIM_NET* {.booldefine: "verbatimNet".} = true
    DUAL_ACTIVATION* {.booldefine: "dualActivation".} = true
    NET_ID* {.define: "netID".} = ""
    # LUT mapping king square to buckets (it's mirrored
    # because we do HM)
    INPUT_BUCKETS*: array[Square(0)..Square(63), int] = [
        0, 1, 2, 3, 3, 2, 1, 0,
        4, 5, 6, 7, 7, 6, 5, 4,
        8, 9, 10, 11, 11, 10, 9, 8,
        8, 9, 10, 11, 11, 10, 9, 8,
        12, 12, 13, 13, 13, 13, 12, 12,
        12, 12, 13, 13, 13, 13, 12, 12,
        14, 14, 15, 15, 15, 15, 14, 14,
        14, 14, 15, 15, 15, 15, 14, 14,
    ]
    DEFAULT_NET_PATH* {.define: "evalFile".} = ""
    DEFAULT_NET_WEIGHTS* = block:
        when not VERBATIM_NET:
            staticRead(DEFAULT_NET_PATH)
        else:
            ""
    VERBATIM_NET_DATA* = block:
        when not VERBATIM_NET:
            cstring("")
        else:
            staticRead(DEFAULT_NET_PATH).cstring

when not ((QA + 1).isPowerOfTwo()):
    import std/strformat

    {.fatal: &"L1 quantization must be a power of 2 minus one (got {QA} instead)".}


type
    Int32Layer*[I, O: static[int]] = object
        weight* {.align(ALIGNMENT_BOUNDARY).}: array[I, array[O, int32]]
        bias* {.align(ALIGNMENT_BOUNDARY).}: array[O, int32]

    Int16Layer*[I, O: static[int]] = object
        weight* {.align(ALIGNMENT_BOUNDARY).}: array[I, array[O, int16]]
        bias* {.align(ALIGNMENT_BOUNDARY).}: array[O, int16]
    
    Bucketed*[B: static[int], T: Int32Layer] = object
        buckets*: array[B, T]

    BucketedL1*[B, I, O: static[int]] = object
        weight* {.align(ALIGNMENT_BOUNDARY).}: array[B, array[I * O, int8]]
        bias* {.align(ALIGNMENT_BOUNDARY).}: array[B, array[O, int32]]

    Network* = object
        ft*: Int16Layer[FT_SIZE * NUM_INPUT_BUCKETS, L1_SIZE]
        # This is ugly, but since our indexing scheme into the L1 is not
        # representable with a 2D array (the dimensions are interleaved),
        # we must sacrifice abstraction for speed. The data is ordered the
        # way dpbusd expects it to be, so we have to adapt ourselves
        l1*: BucketedL1[NUM_OUTPUT_BUCKETS, L1_SIZE, L2_SIZE]
        # We multiply the L2 size by 2 because we do dual activations
        l2*: Bucketed[NUM_OUTPUT_BUCKETS, Int32Layer[(L2_SIZE * (1 + DUAL_ACTIVATION.int)), L3_SIZE]]
        l3*: Bucketed[NUM_OUTPUT_BUCKETS, Int32Layer[L3_SIZE, 1]]

    UpdateQueue* = object
        adds: array[2, int]
        addCount: int8
        subs: array[2, int]
        subCount: int8


proc loadNet*(stream: Stream): Network =
    ## Loads a network from the given stream. The
    ## network's architecture is fixed at compile
    ## time and this function expects the network to
    ## abide by it. The stream is not closed automatically!
    for i in 0..<FT_SIZE * NUM_INPUT_BUCKETS:
        for j in 0..<L1_SIZE:
            result.ft.weight[i][j] = stream.readInt16()

    for i in 0..<L1_SIZE:
        result.ft.bias[i] = stream.readInt16()

    # Note: we don't multiply by 2 like for single-layer nets: normally we
    # would do that so we load in both perspective networks, but since we
    # do pairwise multiplication (which halves the matmul size), that cancels
    # it out
    for bucket in 0..<NUM_OUTPUT_BUCKETS:
        for i in 0..<L1_SIZE * L2_SIZE:
            result.l1.weight[bucket][i] = stream.readInt8()

    for bucket in 0..<NUM_OUTPUT_BUCKETS:
        for i in 0..<L2_SIZE:
            result.l1.bias[bucket][i] = stream.readInt32()

    for bucket in 0..<NUM_OUTPUT_BUCKETS:
        # We have dual activation for the L2, so we effectively
        # have 2 of them
        for i in 0..<L2_SIZE * 2:
            for j in 0..<L3_SIZE:
                result.l2.buckets[bucket].weight[i][j] = stream.readInt32()

    for bucket in 0..<NUM_OUTPUT_BUCKETS:
        for i in 0..<L3_SIZE:
            result.l2.buckets[bucket].bias[i] = stream.readInt32()

    for bucket in 0..<NUM_OUTPUT_BUCKETS:
        for i in 0..<L3_SIZE:
            result.l3.buckets[bucket].weight[i][0] = stream.readInt32()

    for bucket in 0..<NUM_OUTPUT_BUCKETS:
        result.l3.buckets[bucket].bias[0] = stream.readInt32()


proc dumpNet*(net: Network, path: string) =
    let file = newFileStream(path, fmWrite)
    defer: file.close()

    for i in 0..<FT_SIZE * NUM_INPUT_BUCKETS:
        for j in 0..<L1_SIZE:
            file.writeData(addr net.ft.weight[i][j], sizeof(int16))

    for i in 0..<L1_SIZE:
        file.writeData(addr net.ft.bias[i], sizeof(int16))

    for bucket in 0..<NUM_OUTPUT_BUCKETS:
        for i in 0..<L1_SIZE * L2_SIZE:
            file.writeData(addr net.l1.weight[bucket][i], sizeof(int8))

    for bucket in 0..<NUM_OUTPUT_BUCKETS:
        for i in 0..<L2_SIZE:
            file.writeData(addr net.l1.bias[bucket][i], sizeof(int8))

    for bucket in 0..<NUM_OUTPUT_BUCKETS:
        for i in 0..<L2_SIZE * 2:
            for j in 0..<L3_SIZE:
                file.writeData(addr net.l2.buckets[bucket].weight[i][j], sizeof(int32))

    for bucket in 0..<NUM_OUTPUT_BUCKETS:
        for i in 0..<L3_SIZE:
            file.writeData(addr net.l2.buckets[bucket].bias[i], sizeof(int32))

    for bucket in 0..<NUM_OUTPUT_BUCKETS:
        for i in 0..<L3_SIZE:
            file.writeData(addr net.l3.buckets[bucket].weight[i][0], sizeof(int32))

    for bucket in 0..<NUM_OUTPUT_BUCKETS:
        file.writeData(addr net.l3.buckets[bucket].bias[0], sizeof(int32))  


proc loadNet*(path: string): Network =
    let net = newFileStream(path, fmRead)
    defer: net.close()

    return net.loadNet()


proc dumpVerbatimNet*(path: string, network: Network) =
    var f = open(path, fmWrite)
    defer: f.close()
    doAssert f.writeBuffer(network.addr, sizeof(network)) == sizeof(network)


func initAccumulator*[I, O: static[int]](layer: Int16Layer[I, O], output: var array[O, int16]) {.inline.} =
    ## Initializes the given output array with
    ## the layer's biases
    output = layer.bias


proc addFeature*[I, O: static[int]](layer: Int16Layer[I, O], index: int, output: var array[O, int16]) {.inline.} =
    ## Adds the feature at the given index to the given
    ## output array
    when not defined(simd):
        for o in 0..<O:
            output[o] += layer.weight[index][o]
    else:
        var o = 0
        while o < O:
            let weight = vecLoad(addr layer.weight[index][o])
            let data = vecLoad(addr output[o])
            let sum = vecAdd16(weight, data)
            vecStore(addr output[o], sum)
            o += CHUNK_SIZE


proc removeFeature*[I, O: static[int]](layer: Int16Layer[I, O], index: int, output: var array[O, int16]) {.inline.} =
    ## Removes the feature at the given index from the given
    ## output array
    when not defined(simd):
        for o in 0..<O:
            output[o] -= layer.weight[index][o]
    else:
        var o = 0
        while o < O:
            let weight = vecLoad(addr layer.weight[index][o])
            let data = vecLoad(addr output[o])
            let sum = vecSub16(data, weight)
            vecStore(addr output[o], sum)
            o += CHUNK_SIZE



proc addSub[I, O: static[int]](layer: Int16Layer[I, O], i0, i1: int, previous, current: var array[O, int16]) {.inline.} =
    ## Equivalent to two calls to add/remove feature with i0 and i1
    ## as indeces
    when not defined(simd):
        for i in 0..<O:
            current[i] = previous[i] + layer.weight[i0][i] - layer.weight[i1][i]
    else:
        var i = 0
        while i < O:
            let a = vecLoad(addr layer.weight[i0][i])
            let b = vecLoad(addr layer.weight[i1][i])
            let prev = vecLoad(addr previous[i])
            let result = vecSub16(vecAdd16(prev, a), b)
            vecStore(addr current[i], result)
            i += CHUNK_SIZE


proc addSubAddSub*[I, O: static[int]](layer: Int16Layer[I, O], i0, i1, i2, i3: int, previous, current: var array[O, int16]) {.inline.} =
    ## Equivalent to two calls to addSub with i0, i1, i2 and
    ## i3 as indeces
    when not defined(simd):
        for i in 0..<O:
            current[i] = previous[i] + layer.weight[i0][i] - layer.weight[i1][i] + layer.weight[i2][i] - layer.weight[i3][i]
    else:
        var i = 0
        while i < O:
            let a = vecLoad(addr layer.weight[i0][i])
            let b = vecLoad(addr layer.weight[i1][i])
            let c = vecLoad(addr layer.weight[i2][i])
            let d = vecLoad(addr layer.weight[i3][i])
            let prev = vecLoad(addr previous[i])
            let result = vecSub16(vecAdd16(c, vecSub16(vecAdd16(prev, a), b)), d)
            vecStore(addr current[i], result)
            i += CHUNK_SIZE

# Helpers to speed up finny table updates, equivalent to 4 calls to add/remove feature

proc quadAdd*[I, O: static[int]](layer: Int16Layer[I, O], i0, i1, i2, i3: int, current: var array[O, int16]) {.inline.} =
    when not defined(simd):
        for i in 0..<O:
            current[i] += layer.weight[i0][i] + layer.weight[i1][i] + layer.weight[i2][i] + layer.weight[i3][i]
    else:
        var i = 0
        while i < O:
            let a = vecLoad(addr layer.weight[i0][i])
            let b = vecLoad(addr layer.weight[i1][i])
            let c = vecLoad(addr layer.weight[i2][i])
            let d = vecLoad(addr layer.weight[i3][i])
            let curr = vecLoad(addr current[i])
            let result = vecAdd16(curr, vecAdd16(vecAdd16(c, vecAdd16(a, b)), d))
            vecStore(addr current[i], result)
            i += CHUNK_SIZE


proc quadSub*[I, O: static[int]](layer: Int16Layer[I, O], i0, i1, i2, i3: int, current: var array[O, int16]) {.inline.} =
    when not defined(simd):
        for i in 0..<O:
            current[i] -= layer.weight[i0][i] + layer.weight[i1][i] + layer.weight[i2][i] + layer.weight[i3][i]
    else:
        var i = 0
        while i < O:
            let a = vecLoad(addr layer.weight[i0][i])
            let b = vecLoad(addr layer.weight[i1][i])
            let c = vecLoad(addr layer.weight[i2][i])
            let d = vecLoad(addr layer.weight[i3][i])
            let curr = vecLoad(addr current[i])
            let result = vecSub16(curr, vecAdd16(vecAdd16(c, vecAdd16(a, b)), d))
            vecStore(addr current[i], result)
            i += CHUNK_SIZE


proc addSubSub[I, O: static[int]](layer: Int16Layer[I, O], i0, i1, i2: int, previous, current: var array[O, int16]) {.inline.} =
    ## Equivalent to three calls to add/add/remove feature with i0, i1
    ## and i2 as indeces
    when not defined(simd):
        for i in 0..<O:
            current[i] = previous[i] + layer.weight[i0][i] - layer.weight[i1][i] - layer.weight[i2 ][i]
    else:
        var i = 0
        while i < O:
            let a = vecLoad(addr layer.weight[i0][i])
            let b = vecLoad(addr layer.weight[i1][i])
            let c = vecLoad(addr layer.weight[i2][i])
            let prev = vecLoad(addr previous[i])
            let result = vecSub16(vecSub16(vecAdd16(prev, a), b), c)
            vecStore(addr current[i], result)
            i += CHUNK_SIZE


func addSub*(self: var UpdateQueue, i0, i1: int) {.inline.} =
    self.adds[self.addCount] = i0
    inc(self.addCount)
    self.subs[self.subCount] = i1
    inc(self.subCount)


func addSubSub*(self: var UpdateQueue, i0, i1, i2: int) {.inline.} =
    self.adds[self.addCount] = i0
    inc(self.addCount)
    self.subs[self.subCount] = i1
    inc(self.subCount)
    self.subs[self.subCount] = i2
    inc(self.subCount)


func apply*[I, O: static[int]](self: var UpdateQueue, layer: Int16Layer[I, O], oldAcc, newAcc: var array[L1_SIZE, int16]) {.inline.} =
    ## Applies all accumulator updates stored in the given object
    if self.addCount == 0 and self.subCount == 0:
        return
    elif self.addCount == 1 and self.subCount == 1:
        layer.addSub(self.adds[0], self.subs[0], oldAcc, newAcc)
    elif self.addCount == 1 and self.subCount == 2:
        layer.addSubSub(self.adds[0], self.subs[0], self.subs[1], oldAcc, newAcc)
    elif self.addCount == 2 and self.subCount == 2:
        layer.addSubAddSub(self.adds[0], self.subs[0], self.adds[1], self.subs[1], oldAcc, newAcc)
    else:
        doAssert false, "invalid add/sub configuration"
    self.addCount = 0
    self.subCount = 0
