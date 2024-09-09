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
import heimdallpkg/eval
import heimdallpkg/pieces

import std/options


type
    AdjudicationRule* = object
        threshold: Score
        minPlies: int

    ChessAdjudicator* = ref object
        history: seq[tuple[score: Score, stm: PieceColor]]
        rules: tuple[win, draw: AdjudicationRule]
        maxPly: int
        minPly: int


func newChessAdjudicator*(winRule, drawRule: AdjudicationRule): ChessAdjudicator =
    new(result)
    result.rules.win = winRule
    result.rules.draw = drawRule
    result.maxPly = max(result.rules.win.minPlies, result.rules.draw.minPlies)
    result.minPly = min(result.rules.win.minPlies, result.rules.draw.minPlies)


func createAdjudicationRule*(threshold: Score, minPlies: int): AdjudicationRule =
    return AdjudicationRule(threshold: threshold, minPlies: minPlies)


proc adjudicate*(self: ChessAdjudicator): Option[PieceColor] =
    if self.history.len() < self.minPly:
        return
    for i, it in self.history:
        if it.score notin -self.rules.draw.threshold..self.rules.draw.threshold:
            break
        if (i + 1) == self.rules.draw.minPlies:
            return some(None)
    
    for i, it in self.history:
        let whiteScore = if it.stm == Black: -it.score else: it.score
        if (it.stm == White and whiteScore < self.rules.win.threshold) or (it.stm == Black and whiteScore > self.rules.win.threshold):
            break
        
        if (i + 1) == self.rules.win.minPlies:
            let difference = whiteScore - self.rules.win.threshold
            if difference >= 0:
                return some(White)
            else:
                return some(Black)


func update*(self: ChessAdjudicator, stm: PieceColor, score: Score) =
    if self.maxPly == 0:
        return
    self.history.add((score, stm))
    if self.history.len() > self.maxPly:
        self.history.delete(0)


func reset*(self: ChessAdjudicator) =
    self.history = @[]

