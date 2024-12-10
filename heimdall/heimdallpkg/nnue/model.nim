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


# Thanks @analog-hors for the contribution! The code below is heavily derived from hers :)
import heimdallpkg/pieces


const
    ALIGNMENT_BOUNDARY* = 64
    # Note: these variables can be controlled with -d:XX=YY options,
    # so check nim.cfg for their actual values (if none is provided
    # via the define option then the value shown here is used instead)
    FT_SIZE* {.define: "ftSize".} = 768
    HL_SIZE* {.define: "hlSize".} = 256
    EVAL_SCALE* {.define: "evalScale".} = 400
    # Quantization factors for the first
    # and second layer, respectively
    QA* {.define: "quantA".} = 255
    QB* {.define: "quantB".} = 64
    # Number of king input buckets
    NUM_INPUT_BUCKETS* {.define: "inputBuckets".} = 4
    NUM_OUTPUT_BUCKETS* {.define: "outputBuckets".} = 8
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
    DEFAULT_NET_WEIGHTS* = staticRead(DEFAULT_NET_PATH)


type
    LinearI* = uint16
    LinearW* = int16
    LinearB* = int32
    BitLinearWB* = int16

    Linear*[I, O: static[int]] = object
        ## A linear layer
        weight* {.align(ALIGNMENT_BOUNDARY).}: array[O, array[I, LinearW]]
        bias* {.align(ALIGNMENT_BOUNDARY).}: array[O, LinearB]
    
    BitLinear*[I, O: static[int]] = object
        weight* {.align(ALIGNMENT_BOUNDARY).}: array[I, array[O, BitLinearWB]]
        bias* {.align(ALIGNMENT_BOUNDARY).}: array[O, BitLinearWB]
    
    UpdateQueue* = object
        adds: array[2, int]
        addCount: int8
        subs: array[2, int]
        subCount: int8

    Network* = object
        ## A simple neural network
        ft*: BitLinear[FT_SIZE * NUM_INPUT_BUCKETS, HL_SIZE]
        l1*: Linear[HL_SIZE * 2, NUM_OUTPUT_BUCKETS]


func initAccumulator*[I, O: static[int]](layer: BitLinear[I, O], output: var array[O, BitLinearWB]) {.inline.} =
    ## Initializes the given output array with
    ## the layer's biases
    output = layer.bias


func addFeature*[I, O: static[int]](layer: BitLinear[I, O], index, bucket: int, output: var array[O, BitLinearWB]) {.inline.} =
    ## Adds the feature at the given index to the given
    ## output array
    for o in 0..<O:
        output[o] += BitLinearWB(layer.weight[index + (bucket * FT_SIZE)][o])


func removeFeature*[I, O: static[int]](layer: BitLinear[I, O], index, bucket: int, output: var array[O, BitLinearWB]) {.inline.} =
    ## Removes the feature at the given index from the given
    ## output array
    for o in 0..<O:
        output[o] -= BitLinearWB(layer.weight[index + (bucket * FT_SIZE)][o])


func addSub[I, O: static[int]](layer: BitLinear[I, O], i0, i1, bucket: int, previous, current: var array[O, BitlinearWB]) {.inline.} =
    ## Equivalent to two calls to add/remove feature with i0 and i1
    ## as indeces
    for i in 0..<O:
        current[i] = previous[i] + layer.weight[i0 + (bucket * FT_SIZE)][i] - layer.weight[i1 + (bucket * FT_SIZE)][i]


func addSubAddSub[I, O: static[int]](layer: BitLinear[I, O], i0, i1, i2, i3, bucket: int, previous, current: var array[O, BitlinearWB]) {.inline.} =
    ## Equivalent to two calls to addSub with i0, i1, i2 and
    ## i3 as indeces
    for i in 0..<O:
        current[i] = (previous[i] + layer.weight[i0 + (bucket * FT_SIZE)][i] - layer.weight[i1 + (bucket * FT_SIZE)][i] +
                      layer.weight[i2 + (bucket * FT_SIZE)][i] - layer.weight[i3 + (bucket * FT_SIZE)][i])
    

func addSubSub[I, O: static[int]](layer: BitLinear[I, O], i0, i1, i2, bucket: int, previous, current: var array[O, BitlinearWB]) {.inline.} =
    ## Equivalent to three calls to add/add/remove feature with i0, i1
    ## and i2 as indeces
    for i in 0..<O:
        current[i] = previous[i] + layer.weight[i0 + (bucket * FT_SIZE)][i] - layer.weight[i1 + (bucket * FT_SIZE)][i] - layer.weight[i2 + (bucket * FT_SIZE)][i]


func addSub*(self: var UpdateQueue, i0, i1: int) {.inline.} =
    ## Enqueues an addSub call to be applied with apply()
    self.adds[self.addCount] = i0
    inc(self.addCount)
    self.subs[self.subCount] = i1
    inc(self.subCount)


func addSubSub*(self: var UpdateQueue, i0, i1, i2: int) {.inline.} =
    ## Enqueues an addSubSub call to be applied with apply()
    self.adds[self.addCount] = i0
    inc(self.addCount)
    self.subs[self.subCount] = i1
    inc(self.subCount)
    self.subs[self.subCount] = i2
    inc(self.subCount)


func apply*[I, O: static[int]](self: var UpdateQueue, layer: BitLinear[I, O], bucket: int, oldAcc, newAcc: var array[HL_SIZE, BitLinearWB]) {.inline.} =
    ## Applies all accumulator updates stored in the given object
    let bucketOffset = bucket * FT_SIZE

    if self.addCount == 0 and self.subCount == 0:
        return
    elif self.addCount == 1 and self.subCount == 1:
        layer.addSub(self.adds[0], self.subs[0], bucket, oldAcc, newAcc)
    elif self.addCount == 1 and self.subCount == 2:
        layer.addSubSub(self.adds[0], self.subs[0], self.subs[1], bucket, oldAcc, newAcc)
    elif self.addCount == 2 and self.subCount == 2:
        layer.addSubAddSub(self.adds[0], self.subs[0], self.adds[1], self.subs[1], bucket, oldAcc, newAcc)
    else:
        doAssert false, "invalid add/sub configuration"
    self.addCount = 0
    self.subCount = 0
