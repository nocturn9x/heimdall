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
import std/sequtils


type
    AdjudicationRule* = object
        threshold: Score
        minPlies: int

    ChessAdjudicator* = ref object
        history: seq[tuple[score: Score, stm: PieceColor]]
        rules: tuple[win, draw: AdjudicationRule]
        maxPly: int



func newChessAdjudicator*(winRule, drawRule: AdjudicationRule): ChessAdjudicator =
    new(result)
    result.rules.win = winRule
    result.rules.draw = drawRule
    result.maxPly = max(result.rules.win.minPlies, result.rules.draw.minPlies)

func createAdjudicationRule*(threshold: Score, minPlies: int): AdjudicationRule =
    return AdjudicationRule(threshold: threshold, minPlies: minPlies)


func adjudicate*(self: ChessAdjudicator): Option[PieceColor] =
    if self.history.len() < self.maxPly:
        return
    if self.rules.draw.minPlies > 0 and allIt(self.history, it.score == self.rules.draw.threshold):
        # Draw
        return some(None)
    if self.rules.win.minPlies > 0 and allIt(self.history, it.score >= self.rules.win.threshold):
        return some(self.history[^1].stm)


func update*(self: ChessAdjudicator, stm: PieceColor, score: Score) =
    # Make the score white-relative internally so that adjudication
    # logic is simpler
    var score = if stm == White: score else: -score
    self.history.add((score, stm))
    if self.history.len() > self.maxPly:
        self.history.delete(0)


