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

"""Write deterministic, non-playing multilayer TI weights for correctness tests.

The default dimensions match `make dev SINGLE_LAYER=0`. Override --l1 for
smaller test builds and pass the same L1_SIZE to make. No trained weights used.
"""
import argparse
import struct
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--l1", type=int, default=768)
    parser.add_argument("--dual", type=int, choices=(0, 1), default=1)
    args = parser.parse_args()
    if args.l1 <= 0 or args.l1 % 128:
        parser.error("--l1 must be a positive multiple of 128")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    l1, l2, l3, ib, ob = args.l1, 16, 32, 16, 8
    with args.output.open("wb") as out:
        # Short repeating row tables keep generation quick even at full width.
        rows = [struct.pack("<" + "h" * l1,
                            *[((f * 3 + n * 5) % 7) - 3 for n in range(l1)])
                for f in range(7)]
        for feature in range(768 * ib):
            out.write(rows[feature % 7])
        rows = [bytes(((f * 3 + n * 7) % 5 - 2) & 255 for n in range(l1))
                for f in range(5)]
        for feature in range(60144):
            out.write(rows[feature % 5])
        out.write(struct.pack("<" + "h" * l1, *[80 + n % 101 for n in range(l1)]))
        for i in range(l1):
            for b in range(ob):
                out.write(bytes(((i * 11 + b * 3 + o * 5) % 15 - 7) & 255 for o in range(l2)))
        for b in range(ob):
            for o in range(l2):
                out.write(struct.pack("<i", (o - 7) * 127 + b * 31))
        for i in range(l2 * (1 + args.dual)):
            for b in range(ob):
                for o in range(l3):
                    out.write(struct.pack("<i", (i * 3 + b * 7 + o * 11) % 33 - 16))
        for b in range(ob):
            for o in range(l3):
                out.write(struct.pack("<i", (o - 15) * 97 + b * 211))
        for i in range(l3):
            for b in range(ob):
                out.write(struct.pack("<i", (i * 7 + b * 11) % 129 - 64))
        for b in range(ob):
            out.write(struct.pack("<i", (b - 3) * 12345))
    print(f"Wrote synthetic multilayer TI fixture: {args.output} ({args.output.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
