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


# Thanks @analog-hors for the contribution! The code below is *all* hers :)

type
    LinearI* = uint8
    LinearW* = int8
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
        ft*: BitLinear[768, 256]
        l1*: Linear[512, 1]


proc forward*[I, O: static[int]](layer: Linear[I, O], input: array[I, LinearI], output: var array[O, LinearB]) =
    ## Performs a forward pass through the layer
    output = layer.bias
    for o in 0..<O:
        for i in 0..<I:
            output[o] += LinearB(input[i]) * LinearB(layer.weight[o][i])


proc initAccumulator*[I, O: static[int]](layer: BitLinear[I, O], output: var array[O, BitLinearWB]) =
    ## Initializes the given output array with
    ## the layer's biases
    output = layer.bias


proc addFeature*[I, O: static[int]](layer: BitLinear[I, O], index: int, output: var array[O, BitLinearWB]) =
    ## Adds the feature at the given index to the given
    ## output array
    for o in 0..<O:
        output[o] += BitLinearWB(layer.weight[index][o])


proc crelu*[I: static[int]](input: array[I, BitLinearWB], output: var array[I, LinearI]) =
    ## Clipped ReLU vectorized activation function
    for i in 0..<I:
        output[i] = LinearI(input[i].clamp(0, 255))
