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
import heimdall/eval
import heimdall/pieces

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

# This function required the help of not one, but TWO LLMs to get it to a state where it
# actually fucking works. I hope to never touch this piece of crap again
proc adjudicate*(self: ChessAdjudicator): Option[PieceColor] =
    if self.history.len() < self.minPly:
        return

    # Draw adjudication
    var drawCount = 0
    for it in self.history:
        if it.score in -self.rules.draw.threshold..self.rules.draw.threshold:
            inc(drawCount)
        if drawCount >= self.rules.draw.minPlies:
            return some(None)

    if self.history.len() >= self.rules.win.minPlies:
        var consecutiveWins = 0
        for i in 0..<self.rules.win.minPlies:
            let idx = self.history.len - 1 - i
            let entry = self.history[idx]
            let whiteScore = if entry.stm == Black: -entry.score else: entry.score

            if whiteScore >= self.rules.win.threshold:
                inc(consecutiveWins)
            else:
                break
        
        if consecutiveWins >= self.rules.win.minPlies:
            return some(White)

        # Check for Black win
        consecutiveWins = 0
        for i in 0..<self.rules.win.minPlies:
            let idx = self.history.len - 1 - i
            let entry = self.history[idx]
            let whiteScore = if entry.stm == Black: -entry.score else: entry.score

            if whiteScore <= -self.rules.win.threshold:
                inc(consecutiveWins)
            else:
                break

        if consecutiveWins >= self.rules.win.minPlies:
            return some(Black)


func update*(self: ChessAdjudicator, stm: PieceColor, score: Score) =
    if self.maxPly == 0:
        return
    self.history.add((score, stm))
    if self.history.len() > self.maxPly:
        self.history.delete(0)


func reset*(self: ChessAdjudicator) =
    self.history.setLen(0)


# Thanks claude.

when isMainModule:
    import unittest


    proc createTestAdjudicator(winThreshold: Score = 1200, drawThreshold: Score = 25, requiredPlies: int = 4): ChessAdjudicator =
        let winRule = createAdjudicationRule(winThreshold, requiredPlies)
        let drawRule = createAdjudicationRule(drawThreshold, requiredPlies)
        return newChessAdjudicator(winRule, drawRule)

    suite "Chess Adjudicator Tests":
        test "White win adjudication":
            var adjudicator = createTestAdjudicator()
            # All scores from White's perspective:
            # Position 1: White is winning (+1300)
            # Position 2: White is winning (+1250)
            # Position 3: White is winning (+1400)
            # Position 4: White is winning (+1350)
            adjudicator.update(White, 1300)  # White to move, sees +1300
            adjudicator.update(Black, -1250) # Black to move, sees -1250 (= +1250 for White)
            adjudicator.update(White, 1400)  # White to move, sees +1400
            adjudicator.update(Black, -1350) # Black to move, sees -1350 (= +1350 for White)

            let result = adjudicator.adjudicate()
            check result.isSome
            check result.get() == White

        test "Black win adjudication":
            var adjudicator = createTestAdjudicator()
            # All scores from White's perspective:
            # Position 1: Black is winning (-1300)
            # Position 2: Black is winning (-1250)
            # Position 3: Black is winning (-1400)
            # Position 4: Black is winning (-1350)
            adjudicator.update(White, -1300) # White to move, sees -1300
            adjudicator.update(Black, 1250)  # Black to move, sees +1250 (= -1250 for White)
            adjudicator.update(White, -1400) # White to move, sees -1400
            adjudicator.update(Black, 1350)  # Black to move, sees +1350 (= -1350 for White)

            let result = adjudicator.adjudicate()
            check result.isSome
            check result.get() == Black

        test "Draw adjudication":
            var adjudicator = createTestAdjudicator()
            # All scores within draw threshold of ±25
            adjudicator.update(White, 20)
            adjudicator.update(Black, -15)
            adjudicator.update(White, 10)
            adjudicator.update(Black, -25)

            let result = adjudicator.adjudicate()
            check result.isSome
            check result.get() == None

        test "No adjudication with mixed scores":
            var adjudicator = createTestAdjudicator()
            # Alternating good and bad positions
            adjudicator.update(White, 1300)
            adjudicator.update(Black, 800)
            adjudicator.update(White, -200)
            adjudicator.update(Black, -1300)

            let result = adjudicator.adjudicate()
            check result.isNone

        test "No adjudication with insufficient plies":
            var adjudicator = createTestAdjudicator()
            # Only 3 strongly winning positions when 4 are required
            adjudicator.update(White, 1300)
            adjudicator.update(Black, -1250)
            adjudicator.update(White, 1400)

            let result = adjudicator.adjudicate()
            check result.isNone

        test "No adjudication when score is below threshold":
            var adjudicator = createTestAdjudicator()
            # All positive scores but below win threshold
            adjudicator.update(White, 1100)
            adjudicator.update(Black, -1150)
            adjudicator.update(White, 1180)
            adjudicator.update(Black, -1190)

            let result = adjudicator.adjudicate()
            check result.isNone