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

type Score* = int32

func lowestEval*: Score {.inline.} = Score(-28_000)
func highestEval*: Score {.inline.} = Score(28_000)
func mateScore*: Score {.inline.} = Score(30_000)


# This mate score compression logic comes from the advice of @shaheryarsohail on Discord. Many thanks!
# More info: https://github.com/TheBlackPlague/StockDory/pull/57
const MATE_IN_MAX_PLY = mateScore() - 255

func isMateScore*(score: Score): bool {.inline.} = abs(score) >= MATE_IN_MAX_PLY
func isWinScore*(score: Score): bool {.inline.} = score >= MATE_IN_MAX_PLY
func isLossScore*(score: Score): bool {.inline.} = score <= -MATE_IN_MAX_PLY
func mateIn*(ply: int): Score {.inline.} = mateScore() - Score(ply)
func matedIn*(ply: int): Score {.inline.} = -mateScore() + Score(ply)
func compressScore*(score: Score, ply: int): Score = (if score.isWinScore(): score + Score(ply) elif score.isLossScore(): score - Score(ply) else: score)
func decompressScore*(score: Score, ply: int): Score = (if score.isWinScore(): score - Score(ply) elif score.isLossScore(): score + Score(ply) else: score)


const SCORE_INF* = mateIn(0) + 1
