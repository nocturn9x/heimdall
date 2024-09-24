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


# Thanks @analog-hors for the contribution! The code below is *mostly* hers :)
import heimdallpkg/pieces


const
    ALIGNMENT_BOUNDARY* = 64
    FT_SIZE* {.define: "ftSize".} = 768
    HL_SIZE* {.define: "hlSize".} = 256
    EVAL_SCALE* {.define: "evalScale".} = 400
    # Quantization factors for the first
    # and second layer, respectively
    QA* {.define: "quantA".} = 255
    QB* {.define: "quantB".} = 64
    # Number of king input buckets
    NUM_INPUT_BUCKETS* {.define: "inputBuckets".} = 4
    # LUT mapping king square to buckets (it's mirrored
    # because we do HM)
    INPUT_BUCKETS*: array[Square(0)..Square(63), int] = [
        0, 0, 1, 1, 1, 1, 0, 0,
        2, 2, 2, 2, 2, 2, 2, 2,
        3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 3, 3, 3, 3, 3, 3,
        3, 3, 3, 3, 3, 3, 3, 3
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
    
    Network* = object
        ## A simple neural network
        ft*: BitLinear[FT_SIZE * NUM_INPUT_BUCKETS, HL_SIZE]
        l1*: Linear[HL_SIZE * 2, 1]


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

