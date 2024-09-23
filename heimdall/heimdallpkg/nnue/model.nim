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

const
    FT_SIZE* {.define: "ftSize".} = 768
    HL_SIZE* {.define: "hlSize".} = 256
    EVAL_SCALE* {.define: "evalScale".} = 400
    # Quantization factors for the first
    # and second layer, respectively
    QA* {.define: "quantA".} = 255
    QB* {.define: "quantB".} = 64
    DEFAULT_NET_PATH* {.define: "evalFile".} = ""
    DEFAULT_NET_WEIGHTS* = staticRead(DEFAULT_NET_PATH)


type
    LinearI* = uint16
    LinearW* = int16
    LinearB* = int32
    BitLinearWB* = int16

    Linear*[I, O: static[int]] = object
        ## A linear layer
        weight*: array[O, array[I, LinearW]]
        bias*: array[O, LinearB]
    
    BitLinear*[I, O: static[int]] = object
        weight*: array[I, array[O, BitLinearWB]]
        bias*: array[O, BitLinearWB]
    
    Network* = object
        ## A simple neural network
        ft*: BitLinear[FT_SIZE, HL_SIZE]
        l1*: Linear[HL_SIZE * 2, 1]


func forward*[I, O: static[int]](layer: Linear[I, O], input: array[I, LinearI], output: var array[O, LinearB]) {.inline.} =
    ## Performs a forward pass through the layer
    output = layer.bias
    for o in 0..<O:
        for i in 0..<I:
            output[o] += LinearB(input[i]) * LinearB(layer.weight[o][i])


func initAccumulator*[I, O: static[int]](layer: BitLinear[I, O], output: var array[O, BitLinearWB]) {.inline.} =
    ## Initializes the given output array with
    ## the layer's biases
    output = layer.bias


func addFeature*[I, O: static[int]](layer: BitLinear[I, O], index: int, output: var array[O, BitLinearWB]) {.inline.} =
    ## Adds the feature at the given index to the given
    ## output array
    for o in 0..<O:
        output[o] += BitLinearWB(layer.weight[index][o])


func removeFeature*[I, O: static[int]](layer: BitLinear[I, O], index: int, output: var array[O, BitLinearWB]) {.inline.} =
    ## Removes the feature at the given index from the given
    ## output array
    for o in 0..<O:
        output[o] -= BitLinearWB(layer.weight[index][o])


func screlu*[I: static[int]](input: array[I, BitLinearWB], output: var array[I, LinearI]) {.inline.} =
    ## Square clipped ReLU vectorized activation function
    for i in 0..<I:
        var v = LinearI(input[i].clamp(0, 255))
        v *= v
        output[i] += v
