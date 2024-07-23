type
    LinearI* = uint8
    LinearW* = int8
    LinearB* = int32
    BitLinearWB* = int16

    Linear*[I, O: static[int]] = object
        weight*: array[O, array[I, LinearW]]
        bias*: array[O, LinearB]
    
    BitLinear*[I, O: static[int]] = object
        weight*: array[I, array[O, BitLinearWB]]
        bias*: array[O, BitLinearWB]
    
    Nnue* = object
        ft*: BitLinear[768, 256]
        l1*: Linear[512, 1]

proc forward*[I, O: static[int]](layer: Linear[I, O], input: array[I, LinearI], output: var array[O, LinearB]) =
    output = layer.bias
    for o in 0..<O:
        for i in 0..<I:
            output[o] += input[i].LinearB * layer.weight[o][i].LinearB

proc initAcc*[I, O: static[int]](layer: BitLinear[I, O], output: var array[O, BitLinearWB]) =
    output = layer.bias

proc addFeature*[I, O: static[int]](layer: BitLinear[I, O], index: int, output: var array[O, BitLinearWB]) =
    for o in 0..<O:
        output[o] += layer.weight[index][o].BitLinearWB

proc crelu*[I: static[int]](input: array[I, BitLinearWB], output: var array[I, LinearI]) =
    for i in  0..<I:
        output[i] = input[i].clamp(0, 255).LinearI
