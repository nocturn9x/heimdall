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

import heimdall/nnue/model


import std/endians
import std/streams


func toLittleEndian[T: int16 or uint16](x: T): T =
    ## Helper around littleEndian16
    littleEndian16(addr result, addr x)


proc dumpNet*(net: Network, path: string) =
    ## Dumps a net to a binary file at the given
    ## path
    let file = newFileStream(path, fmWrite)
    defer: file.close()


    for i in 0..<(FT_SIZE * NUM_INPUT_BUCKETS):
        for j in 0..<HL_SIZE:
            file.writeData(addr net.ft.weight[i][j], 2)
    
    for i in 0..<HL_SIZE:
        file.writeData(addr net.ft.bias[i], 2)

    for i in 0..<(HL_SIZE * 2):
        for j in 0..<NUM_OUTPUT_BUCKETS:
            file.writeData(addr net.l1.weight[j][i], 2)

    for i in 0..<NUM_OUTPUT_BUCKETS:
        file.writeData(addr net.l1.bias[i], 2)    


proc loadNet*(stream: Stream): Network =
    ## Loads a network from the given stream. The
    ## network's architecture is fixed at compile
    ## time and this function expects the network to
    ## abide by it. The stream is not closed automatically!
    for i in 0..<(FT_SIZE * NUM_INPUT_BUCKETS):
        for j in 0..<HL_SIZE:
            result.ft.weight[i][j] = stream.readInt16().toLittleEndian()
    
    for i in 0..<HL_SIZE:
        result.ft.bias[i] = stream.readInt16().toLittleEndian()

    for i in 0..<NUM_OUTPUT_BUCKETS:
        for j in 0..<(HL_SIZE * 2):
            # Note to self: bullet already transposes the weights for us
            # so we don't need to do it manually (this is done because it
            # allows for faster CPU inference). Just something to keep in
            # mind!
            result.l1.weight[i][j] = stream.readInt16().toLittleEndian()
    
    for i in 0..<NUM_OUTPUT_BUCKETS:
        result.l1.bias[i] = stream.readInt16().toLittleEndian()


proc loadNet*(path: string): Network =
    ## Loads a network from the given file. The
    ## network's architecture is fixed at compile
    ## time and this function expects the network to
    ## abide by it
    let net = newFileStream(path, fmRead)
    defer: net.close()
    
    return net.loadNet()

