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
import std/math
import std/strformat
import std/strutils


import heimdallpkg/eval
import heimdallpkg/pieces
import heimdallpkg/position


type
    CompressedGame* = object
        position*: Position
        wdl*: PieceColor
        eval*: Score


func createCompressedGame*(position: Position, wdl: PieceColor, eval: Score): CompressedGame =
    result.position = position
    result.eval = eval
    result.wdl = wdl



func lerp*(a, b, t: float): float = (a * (1.0 - t)) + (b * t)
func sigmoid*(x: float): float = 1 / (1 + exp(-x))


proc dump*(self: CompressedGame): string = &"{self.position.toFEN()}|{(if self.wdl == White: 1.0 elif self.wdl == Black: 0 else: 0.5)}|{self.eval}"
proc load*(data: string): CompressedGame =
    let split = data.split("|", 3)
    return createCompressedGame(split[0].loadFEN(),
                                if split[1] == "1.0": White elif split[1] == "0.0": Black else: None,
                                Score(split[2].parseInt()))
    

