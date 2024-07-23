import sys, json, numpy as np

ACTIVATION_RANGE = 255
WEIGHT_SCALE = 64

STATE = { k: np.array(v) for k, v in json.load(sys.stdin).items() }

def dump_tensor(tensor: np.ndarray, scale: float) -> str:
    if len(tensor.shape) == 0:
        return str(round(tensor.item() * scale))
    return f"[{','.join(dump_tensor(t, scale) for t in tensor)}]"

def dump_struct(type: str, fields: dict[str, str]) -> str:
    return f"{type}({','.join(f'{k}:{v}' for k, v in fields.items())})"

def dump_ft() -> str:
    weights = STATE["ft.weight"].transpose()
    biases = STATE["ft.bias"]
    i, o = weights.shape
    return dump_struct(f"BitLinear[{i},{o}]", {
        "weight": dump_tensor(weights, ACTIVATION_RANGE),
        "bias": dump_tensor(biases, ACTIVATION_RANGE)
    })

def dump_linear(field: str) -> str:
    weights = STATE[f"{field}.weight"]
    biases = STATE[f"{field}.bias"]
    o, i = weights.shape
    return dump_struct(f"Linear[{i},{o}]", {
        "weight": dump_tensor(weights, WEIGHT_SCALE),
        "bias": dump_tensor(biases, WEIGHT_SCALE * ACTIVATION_RANGE)
    })

print("import model")
print("let NETWORK* = " + dump_struct("Nnue", {
    "ft": dump_ft(),
    "l1": dump_linear("out")
}))
