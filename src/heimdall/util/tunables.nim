# Copyright 2025 Mattia Giambirtone & All Contributors
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

import std/[math, tables, strutils, strformat]

import heimdall/pieces


const isTuningEnabled* {.booldefine:"enableTuning".} = false


const QUANTIZATION_FACTOR* = 1024


type
    TunableParameter* = object
        ## An SPSA-tunable parameter
        name*: string
        min*: int
        max*: int
        default*: int
        quantized*: bool

    SearchParameters* = ref object
        # NMP: Reduce search depth by min((staticEval - beta) / divisor, maxValue)
        nmpEvalDivisor*: tuple[quiet, noisy: int]

        # RFP: Prune only when staticEval - (depth * base - improving_margin * improving) >= beta
        rfpMargins*: tuple[base, improving: tuple[quiet, noisy: int]]

        # FP: Prune only when (staticEval + offset) + margin * (depth + improving) <= alpha
        fpEvalMargin*: int
        fpEvalOffset*: int

        # LMR: The divisors for history reductions
        historyLmrDivisor*: tuple[quiet, noisy: int]

        # Aspiration windows

        # Use this value as the initial
        # aspiration window size
        aspWindowInitialSize*: int
        # Give up and search the full range
        # of alpha beta values once the window
        # size gets to this value
        aspWindowMaxSize*: int
        # Delta widening divisors (delta = delta * 128 / divisor)
        # for fail low (score <= alpha) and fail high (score >= beta)
        aspWindowWideningFactor*: tuple[failLow, failHigh: int]

        # Only prune quiet/capture moves whose SEE score
        # is < this value times depth
        seePruningMargin*: tuple[capture, quiet: int]

        # Good/bad moves get their bonus/malus * depth in their
        # respective history tables
        moveBonuses*: tuple[quiet, capture: tuple[good, bad: int], conthist: tuple[ply1, ply2, ply4: tuple[good, bad: int]]]

        # Time management

        # Soft bound is scaled by nodeTmBaseOffset - f * nodeTmScaleFactor
        # where f is the fraction of total nodes that was
        # spent on a root move

        # These are tuned as integers and then divided by 1000
        # when loading them in
        nodeTmBaseOffset*: tuple[quiet, noisy: float]
        nodeTmScaleFactor*: tuple[quiet, noisy: float]

        # Eval margin for qsearch futility pruning
        qsearchFpEvalMargin*: int

        # Score margins for multiple extensions
        doubleExtMargin*: tuple[quiet, noisy: int]
        tripleExtMargin*: tuple[quiet, noisy: int]

        # Material scaling parameters
        materialScalingOffset*: int
        materialScalingDivisor*: int

        # Eval threshold for increasing depth
        # for move history updates
        historyDepthEvalThreshold*: tuple[quiet, noisy: int]

        # Tunable piece weights for SEE (split by context)
        seeWeights*: tuple[ordering, pruneQuiet, pruneNoisy: array[Pawn..Empty, int]]
        materialWeights*: array[Pawn..Empty, int]

        # LMR table parameters (tuned as integers, divided by 1000)
        lmrBase*: float
        lmrMultiplier*: float

        # Correction history
        corrHistMaxValue*: tuple[pawn, nonpawn, major, minor: int, continuation: tuple[one, two: int]]
        corrHistMinValue*: tuple[pawn, nonpawn, major, minor: int, continuation: tuple[one, two: int]]
        corrHistScale*: tuple[weight, eval: tuple[pawn, nonpawn, major, minor: int, continuation: tuple[one, two: int]]]


proc newTunableParameter*(name: string, min, max, default: int, quantized = false): TunableParameter =
    result.name = name
    result.min = min
    result.max = max
    result.default = default
    result.quantized = quantized


# Paste here the SPSA output from OpenBench and the values
# will be loaded automatically into the default field of each
# parameter
const SPSA_OUTPUT = """
MaterialBishopWeight, 469
NonPawnCorrHistWeightScale, 254
AspWindowMaxSize, 980
NonPawnCorrHistEvalScale, 470
MaterialKnightWeight, 465
DoubleExtMarginQuiet, 15
DoubleExtMarginNoisy, 15
SEEOrdQueenWeight, 1257
SEEPruneQuietQueenWeight, 1257
SEEPruneNoisyQueenWeight, 1257
NodeTMBaseOffsetQuiet, 2861
NodeTMBaseOffsetNoisy, 2861
SEEPruningQuietMargin, 79
SEEPruningCaptureMargin, 124
NMPEvalDivisorQuiet, 243
NMPEvalDivisorNoisy, 243
RFPImprovingMarginQuiet, 135
RFPImprovingMarginNoisy, 135
HistoryDepthEvalThresholdQuiet, 53
HistoryDepthEvalThresholdNoisy, 53
BadQuietMalus, 280
ContHistMalusPly1, 280
ContHistMalusPly2, 280
ContHistMalusPly4, 280
SEEOrdKnightWeight, 465
SEEPruneQuietKnightWeight, 465
SEEPruneNoisyKnightWeight, 465
NonPawnCorrHistMinValue, -12428
RFPBaseMarginQuiet, 168
RFPBaseMarginNoisy, 168
HistoryLMRQuietDivisor, 10901
MajorCorrHistMaxValue, 12028
PawnCorrHistWeightScale, 255
SEEOrdPawnWeight, 99
SEEPruneQuietPawnWeight, 99
SEEPruneNoisyPawnWeight, 99
SEEOrdRookWeight, 691
SEEPruneQuietRookWeight, 691
SEEPruneNoisyRookWeight, 691
MinorCorrHistWeightScale, 260
AspWindowInitialSize, 19
MinorCorrHistMinValue, -12442
QSearchFPEvalMargin, 211
MajorCorrHistMinValue, -12308
TripleExtMarginQuiet, 50
TripleExtMarginNoisy, 50
MaterialRookWeight, 647
HistoryLMRNoisyDivisor, 13902
GoodCaptureBonus, 45
NodeTMScaleFactorQuiet, 1634
NodeTMScaleFactorNoisy, 1634
MatScalingOffset, 26283
GoodQuietBonus, 261
ContHistBonusPly1, 261
ContHistBonusPly2, 261
ContHistBonusPly4, 261
MajorCorrHistWeightScale, 257
PawnCorrHistMinValue, -12060
PawnCorrHistMaxValue, 12461
SEEOrdBishopWeight, 485
SEEPruneQuietBishopWeight, 485
SEEPruneNoisyBishopWeight, 485
FPBaseOffset, 5
BadCaptureMalus, 113
FPEvalMargin, 98
MatScalingDivisor, 28236
PawnCorrHistEvalScale, 476
MaterialQueenWeight, 1232
MinorCorrHistMaxValue, 11946
MaterialPawnWeight, 103
MajorCorrHistEvalScale, 250
NonPawnCorrHistMaxValue, 12125
MinorCorrHistEvalScale, 261
""".replace(" ", "")


template addTunableParameter(name: string, min, max, default: int, quantized = false) =
    result[name] = newTunableParameter(name, min, max, default, quantized)


proc initTunableParameters: Table[string, TunableParameter] =
    ## Adds all our tunable parameters to the global
    ## parameter list
    addTunableParameter("RFPBaseMarginQuiet", 1, 200, 100)
    addTunableParameter("RFPBaseMarginNoisy", 1, 200, 100)
    addTunableParameter("RFPImprovingMarginQuiet", 1, 200, 100)
    addTunableParameter("RFPImprovingMarginNoisy", 1, 200, 100)
    addTunableParameter("FPEvalMargin", 1, 500, 250)
    addTunableParameter("FPBaseOffset", 0, 200, 1)
    # Value asspulled by cj, btw
    addTunableParameter("HistoryLMRQuietDivisor", 6144, 24576, 12288, true)
    addTunableParameter("HistoryLMRNoisyDivisor", 6144, 24576, 12288, true)
    addTunableParameter("AspWindowInitialSize", 1, 60, 30)
    addTunableParameter("AspWindowMaxSize", 1, 2000, 1000)
    addTunableParameter("AspWindowWideningFailLow", 128, 384, 256)
    addTunableParameter("AspWindowWideningFailHigh", 128, 384, 256)
    addTunableParameter("SEEPruningQuietMargin", 1, 160, 80)
    addTunableParameter("SEEPruningCaptureMargin", 1, 320, 160)
    addTunableParameter("GoodQuietBonus", 1, 340, 170)
    addTunableParameter("BadQuietMalus", 1, 900, 450)
    addTunableParameter("GoodCaptureBonus", 1, 90, 45)
    addTunableParameter("BadCaptureMalus", 1, 224, 112)
    addTunableParameter("ContHistBonusPly1", 1, 340, 170)
    addTunableParameter("ContHistMalusPly1", 1, 900, 450)
    addTunableParameter("ContHistBonusPly2", 1, 340, 170)
    addTunableParameter("ContHistMalusPly2", 1, 900, 450)
    addTunableParameter("ContHistBonusPly4", 1, 340, 170)
    addTunableParameter("ContHistMalusPly4", 1, 900, 450)
    # Values yoinked from Stormphrax :3
    addTunableParameter("NodeTMBaseOffsetQuiet", 1000, 3000, 2630)
    addTunableParameter("NodeTMBaseOffsetNoisy", 1000, 3000, 2630)
    addTunableParameter("NodeTMScaleFactorQuiet", 1000, 2500, 1700)
    addTunableParameter("NodeTMScaleFactorNoisy", 1000, 2500, 1700)
    addTunableParameter("QSearchFPEvalMargin", 100, 400, 200)
    # We copying sf on this one
    addTunableParameter("DoubleExtMarginQuiet", 0, 80, 40)
    addTunableParameter("DoubleExtMarginNoisy", 0, 80, 40)
    addTunableParameter("TripleExtMarginQuiet", 50, 200, 100)
    addTunableParameter("TripleExtMarginNoisy", 50, 200, 100)

    addTunableParameter("MatScalingOffset", 13250, 53000, 26500)
    addTunableParameter("MatScalingDivisor", 16384, 65536, 32768)
    addTunableParameter("NMPEvalDivisorQuiet", 120, 350, 245)
    addTunableParameter("NMPEvalDivisorNoisy", 120, 350, 245)
    addTunableParameter("HistoryDepthEvalThresholdQuiet", 25, 100, 50)
    addTunableParameter("HistoryDepthEvalThresholdNoisy", 25, 100, 50)

    addTunableParameter("SEEOrdPawnWeight", 50, 200, 100)
    addTunableParameter("SEEOrdKnightWeight", 225, 900, 450)
    addTunableParameter("SEEOrdBishopWeight", 225, 900, 450)
    addTunableParameter("SEEOrdRookWeight", 325, 1300, 650)
    addTunableParameter("SEEOrdQueenWeight", 625, 2500, 1250)
    addTunableParameter("SEEPruneQuietPawnWeight", 50, 200, 100)
    addTunableParameter("SEEPruneQuietKnightWeight", 225, 900, 450)
    addTunableParameter("SEEPruneQuietBishopWeight", 225, 900, 450)
    addTunableParameter("SEEPruneQuietRookWeight", 325, 1300, 650)
    addTunableParameter("SEEPruneQuietQueenWeight", 625, 2500, 1250)
    addTunableParameter("SEEPruneNoisyPawnWeight", 50, 200, 100)
    addTunableParameter("SEEPruneNoisyKnightWeight", 225, 900, 450)
    addTunableParameter("SEEPruneNoisyBishopWeight", 225, 900, 450)
    addTunableParameter("SEEPruneNoisyRookWeight", 325, 1300, 650)
    addTunableParameter("SEEPruneNoisyQueenWeight", 625, 2500, 1250)
    addTunableParameter("MaterialPawnWeight", 50, 200, 100)
    addTunableParameter("MaterialKnightWeight", 225, 900, 450)
    addTunableParameter("MaterialBishopWeight", 225, 900, 450)
    addTunableParameter("MaterialRookWeight", 325, 1300, 650)
    addTunableParameter("MaterialQueenWeight", 625, 2500, 1250)

    addTunableParameter("PawnCorrHistMaxValue", 8000, 16384, 12288)
    addTunableParameter("PawnCorrHistMinValue", -16384, -8000, -12288)
    addTunableParameter("PawnCorrHistWeightScale", 32, 1024, 256)
    addTunableParameter("PawnCorrHistEvalScale", 32, 1024, 512)

    addTunableParameter("NonPawnCorrHistMaxValue", 8000, 16384, 12288)
    addTunableParameter("NonPawnCorrHistMinValue", -16384, -8000, -12288)
    addTunableParameter("NonPawnCorrHistWeightScale", 32, 1024, 256)
    addTunableParameter("NonPawnCorrHistEvalScale", 32, 1024, 512)

    addTunableParameter("MajorCorrHistMaxValue", 8000, 16384, 12288)
    addTunableParameter("MajorCorrHistMinValue", -16384, -8000, -12288)
    addTunableParameter("MajorCorrHistWeightScale", 32, 1024, 256)
    addTunableParameter("MajorCorrHistEvalScale", 32, 1024, 256)

    addTunableParameter("MinorCorrHistMaxValue", 8000, 16384, 12288)
    addTunableParameter("MinorCorrHistMinValue", -16384, -8000, -12288)
    addTunableParameter("MinorCorrHistWeightScale", 32, 512, 256)
    addTunableParameter("MinorCorrHistEvalScale", 32, 1024, 256)

    addTunableParameter("1PContCorrHistMaxValue", 8000, 16384, 12288)
    addTunableParameter("1PContCorrHistMinValue", -16384, -8000, -12288)
    addTunableParameter("1PContCorrHistWeightScale", 32, 512, 256)
    addTunableParameter("1PContCorrHistEvalScale", 32, 1024, 256)

    addTunableParameter("2PContCorrHistMaxValue", 8000, 16384, 12288)
    addTunableParameter("2PContCorrHistMinValue", -16384, -8000, -12288)
    addTunableParameter("2PContCorrHistWeightScale", 32, 512, 256)
    addTunableParameter("2PContCorrHistEvalScale", 32, 1024, 512)

    addTunableParameter("LMRBase", 400, 1200, 800)
    addTunableParameter("LMRMultiplier", 200, 800, 400)

    for line in SPSA_OUTPUT.splitLines(keepEol=false):
        if line.len() == 0:
            continue
        let splosh = line.split(",", maxsplit=2)
        result[splosh[0]].default = splosh[1].parseInt()


const params = initTunableParameters()


proc isParamName*(name: string): bool =
    ## Returns whether the given string
    ## represents a tunable parameter name
    name in params


proc setParameter*(self: SearchParameters, name: string, value: int) =
    ## Sets the tunable parameter with the given name
    ## to the given integer value

    # This is ugly, but short of macro shenanigans it's
    # the best we can do
    case name:
        of "RFPBaseMarginQuiet":
            self.rfpMargins.base.quiet = value
        of "RFPBaseMarginNoisy":
            self.rfpMargins.base.noisy = value
        of "RFPImprovingMarginQuiet":
            self.rfpMargins.improving.quiet = value
        of "RFPImprovingMarginNoisy":
            self.rfpMargins.improving.noisy = value
        of "FPEvalMargin":
            self.fpEvalMargin = value
        of "FPBaseOffset":
            self.fpEvalOffset = value
        of "HistoryLMRQuietDivisor":
            self.historyLmrDivisor.quiet = value
        of "HistoryLMRNoisyDivisor":
            self.historyLmrDivisor.noisy = value
        of "AspWindowInitialSize":
            self.aspWindowInitialSize = value
        of "AspWindowMaxSize":
            self.aspWindowMaxSize = value
        of "AspWindowWideningFailLow":
            self.aspWindowWideningFactor.failLow = value
        of "AspWindowWideningFailHigh":
            self.aspWindowWideningFactor.failHigh = value
        of "SEEPruningQuietMargin":
            self.seePruningMargin.quiet = value
        of "SEEPruningCaptureMargin":
            self.seePruningMargin.capture = value
        of "GoodQuietBonus":
            self.moveBonuses.quiet.good = value
        of "BadQuietMalus":
            self.moveBonuses.quiet.bad = value
        of "ContHistBonusPly1":
            self.moveBonuses.conthist.ply1.good = value
        of "ContHistMalusPly1":
            self.moveBonuses.conthist.ply1.bad = value
        of "ContHistBonusPly2":
            self.moveBonuses.conthist.ply2.good = value
        of "ContHistMalusPly2":
            self.moveBonuses.conthist.ply2.bad = value
        of "ContHistBonusPly4":
            self.moveBonuses.conthist.ply4.good = value
        of "ContHistMalusPly4":
            self.moveBonuses.conthist.ply4.bad = value
        of "GoodCaptureBonus":
            self.moveBonuses.capture.good = value
        of "BadCaptureMalus":
            self.moveBonuses.capture.bad = value
        of "NodeTMBaseOffsetQuiet":
            self.nodeTmBaseOffset.quiet = value / 1000
        of "NodeTMBaseOffsetNoisy":
            self.nodeTmBaseOffset.noisy = value / 1000
        of "NodeTMScaleFactorQuiet":
            self.nodeTmScaleFactor.quiet = value / 1000
        of "NodeTMScaleFactorNoisy":
            self.nodeTmScaleFactor.noisy = value / 1000
        of "QSearchFPEvalMargin":
            self.qsearchFpEvalMargin = value
        of "DoubleExtMarginQuiet":
            self.doubleExtMargin.quiet = value
        of "DoubleExtMarginNoisy":
            self.doubleExtMargin.noisy = value
        of "MatScalingDivisor":
            self.materialScalingDivisor = value
        of "MatScalingOffset":
            self.materialScalingOffset = value
        of "NMPEvalDivisorQuiet":
            self.nmpEvalDivisor.quiet = value
        of "NMPEvalDivisorNoisy":
            self.nmpEvalDivisor.noisy = value
        of "TripleExtMarginQuiet":
            self.tripleExtMargin.quiet = value
        of "TripleExtMarginNoisy":
            self.tripleExtMargin.noisy = value
        of "HistoryDepthEvalThresholdQuiet":
            self.historyDepthEvalThreshold.quiet = value
        of "HistoryDepthEvalThresholdNoisy":
            self.historyDepthEvalThreshold.noisy = value
        of "SEEOrdPawnWeight":
            self.seeWeights.ordering[Pawn] = value
        of "SEEOrdKnightWeight":
            self.seeWeights.ordering[Knight] = value
        of "SEEOrdBishopWeight":
            self.seeWeights.ordering[Bishop] = value
        of "SEEOrdRookWeight":
            self.seeWeights.ordering[Rook] = value
        of "SEEOrdQueenWeight":
            self.seeWeights.ordering[Queen] = value
        of "SEEPruneQuietPawnWeight":
            self.seeWeights.pruneQuiet[Pawn] = value
        of "SEEPruneQuietKnightWeight":
            self.seeWeights.pruneQuiet[Knight] = value
        of "SEEPruneQuietBishopWeight":
            self.seeWeights.pruneQuiet[Bishop] = value
        of "SEEPruneQuietRookWeight":
            self.seeWeights.pruneQuiet[Rook] = value
        of "SEEPruneQuietQueenWeight":
            self.seeWeights.pruneQuiet[Queen] = value
        of "SEEPruneNoisyPawnWeight":
            self.seeWeights.pruneNoisy[Pawn] = value
        of "SEEPruneNoisyKnightWeight":
            self.seeWeights.pruneNoisy[Knight] = value
        of "SEEPruneNoisyBishopWeight":
            self.seeWeights.pruneNoisy[Bishop] = value
        of "SEEPruneNoisyRookWeight":
            self.seeWeights.pruneNoisy[Rook] = value
        of "SEEPruneNoisyQueenWeight":
            self.seeWeights.pruneNoisy[Queen] = value
        of "MaterialPawnWeight":
            self.materialWeights[Pawn] = value
        of "MaterialKnightWeight":
            self.materialWeights[Knight] = value
        of "MaterialBishopWeight":
            self.materialWeights[Bishop] = value
        of "MaterialRookWeight":
            self.materialWeights[Rook] = value
        of "MaterialQueenWeight":
            self.materialWeights[Queen] = value
        of "PawnCorrHistMaxValue":
            self.corrHistMaxValue.pawn = value
        of "PawnCorrHistMinValue":
            self.corrHistMinValue.pawn = value
        of "PawnCorrHistEvalScale":
            self.corrHistScale.eval.pawn = value
        of "PawnCorrHistWeightScale":
            self.corrHistScale.weight.pawn = value
        of "NonPawnCorrHistMaxValue":
            self.corrHistMaxValue.nonpawn = value
        of "NonPawnCorrHistMinValue":
            self.corrHistMinValue.nonpawn = value
        of "NonPawnCorrHistEvalScale":
            self.corrHistScale.eval.nonpawn = value
        of "NonPawnCorrHistWeightScale":
            self.corrHistScale.weight.nonpawn = value
        of "MajorCorrHistMaxValue":
            self.corrHistMaxValue.major = value
        of "MajorCorrHistMinValue":
            self.corrHistMinValue.major = value
        of "MajorCorrHistEvalScale":
            self.corrHistScale.eval.major = value
        of "MajorCorrHistWeightScale":
            self.corrHistScale.weight.major = value
        of "MinorCorrHistMaxValue":
            self.corrHistMaxValue.minor = value
        of "MinorCorrHistMinValue":
            self.corrHistMinValue.minor = value
        of "MinorCorrHistEvalScale":
            self.corrHistScale.eval.minor = value
        of "MinorCorrHistWeightScale":
            self.corrHistScale.weight.minor = value
        of "1PContCorrHistMaxValue":
            self.corrHistMaxValue.continuation.one = value
        of "1PContCorrHistMinValue":
            self.corrHistMinValue.continuation.one = value
        of "1PContCorrHistEvalScale":
            self.corrHistScale.eval.continuation.one = value
        of "1PContCorrHistWeightScale":
            self.corrHistScale.weight.continuation.one = value
        of "2PContCorrHistMaxValue":
            self.corrHistMaxValue.continuation.two = value
        of "2PContCorrHistMinValue":
            self.corrHistMinValue.continuation.two = value
        of "2PContCorrHistEvalScale":
            self.corrHistScale.eval.continuation.two = value
        of "2PContCorrHistWeightScale":
            self.corrHistScale.weight.continuation.two = value
        of "LMRBase":
            self.lmrBase = value / 1000
        of "LMRMultiplier":
            self.lmrMultiplier = value / 1000
        else:
            raise newException(ValueError, &"invalid tunable parameter '{name}'")


proc getParameter*(self: SearchParameters, name: string): int =
    ## Retrieves the value of the given search parameter.
    ## Not meant to be used during search

    # This is ugly, but short of macro shenanigans it's
    # the best we can do
    case name:
        of "RFPBaseMarginQuiet":
            self.rfpMargins.base.quiet
        of "RFPBaseMarginNoisy":
            self.rfpMargins.base.noisy
        of "RFPImprovingMarginQuiet":
            self.rfpMargins.improving.quiet
        of "RFPImprovingMarginNoisy":
            self.rfpMargins.improving.noisy
        of "FPEvalMargin":
            self.fpEvalMargin
        of "FPBaseOffset":
            self.fpEvalOffset
        of "HistoryLMRQuietDivisor":
            self.historyLmrDivisor.quiet
        of "HistoryLMRNoisyDivisor":
            self.historyLmrDivisor.noisy
        of "AspWindowInitialSize":
            self.aspWindowInitialSize
        of "AspWindowMaxSize":
            self.aspWindowMaxSize
        of "AspWindowWideningFailLow":
            self.aspWindowWideningFactor.failLow
        of "AspWindowWideningFailHigh":
            self.aspWindowWideningFactor.failHigh
        of "SEEPruningQuietMargin":
            self.seePruningMargin.quiet
        of "SEEPruningCaptureMargin":
            self.seePruningMargin.capture
        of "GoodQuietBonus":
            self.moveBonuses.quiet.good
        of "BadQuietMalus":
            self.moveBonuses.quiet.bad
        of "ContHistBonusPly1":
            self.moveBonuses.conthist.ply1.good
        of "ContHistMalusPly1":
            self.moveBonuses.conthist.ply1.bad
        of "ContHistBonusPly2":
            self.moveBonuses.conthist.ply2.good
        of "ContHistMalusPly2":
            self.moveBonuses.conthist.ply2.bad
        of "ContHistBonusPly4":
            self.moveBonuses.conthist.ply4.good
        of "ContHistMalusPly4":
            self.moveBonuses.conthist.ply4.bad
        of "GoodCaptureBonus":
            self.moveBonuses.capture.good
        of "BadCaptureMalus":
            self.moveBonuses.capture.bad
        of "NodeTMBaseOffsetQuiet":
            int(self.nodeTmBaseOffset.quiet * 1000)
        of "NodeTMBaseOffsetNoisy":
            int(self.nodeTmBaseOffset.noisy * 1000)
        of "NodeTMScaleFactorQuiet":
            int(self.nodeTmScaleFactor.quiet * 1000)
        of "NodeTMScaleFactorNoisy":
            int(self.nodeTmScaleFactor.noisy * 1000)
        of "QSearchFPEvalMargin":
            self.qsearchFpEvalMargin
        of "DoubleExtMarginQuiet":
            self.doubleExtMargin.quiet
        of "DoubleExtMarginNoisy":
            self.doubleExtMargin.noisy
        of "MatScalingDivisor":
            self.materialScalingDivisor
        of "MatScalingOffset":
            self.materialScalingOffset
        of "NMPEvalDivisorQuiet":
            self.nmpEvalDivisor.quiet
        of "NMPEvalDivisorNoisy":
            self.nmpEvalDivisor.noisy
        of "TripleExtMarginQuiet":
            self.tripleExtMargin.quiet
        of "TripleExtMarginNoisy":
            self.tripleExtMargin.noisy
        of "HistoryDepthEvalThresholdQuiet":
            self.historyDepthEvalThreshold.quiet
        of "HistoryDepthEvalThresholdNoisy":
            self.historyDepthEvalThreshold.noisy
        of "SEEOrdPawnWeight":
            self.seeWeights.ordering[Pawn]
        of "SEEOrdKnightWeight":
            self.seeWeights.ordering[Knight]
        of "SEEOrdBishopWeight":
            self.seeWeights.ordering[Bishop]
        of "SEEOrdRookWeight":
            self.seeWeights.ordering[Rook]
        of "SEEOrdQueenWeight":
            self.seeWeights.ordering[Queen]
        of "SEEPruneQuietPawnWeight":
            self.seeWeights.pruneQuiet[Pawn]
        of "SEEPruneQuietKnightWeight":
            self.seeWeights.pruneQuiet[Knight]
        of "SEEPruneQuietBishopWeight":
            self.seeWeights.pruneQuiet[Bishop]
        of "SEEPruneQuietRookWeight":
            self.seeWeights.pruneQuiet[Rook]
        of "SEEPruneQuietQueenWeight":
            self.seeWeights.pruneQuiet[Queen]
        of "SEEPruneNoisyPawnWeight":
            self.seeWeights.pruneNoisy[Pawn]
        of "SEEPruneNoisyKnightWeight":
            self.seeWeights.pruneNoisy[Knight]
        of "SEEPruneNoisyBishopWeight":
            self.seeWeights.pruneNoisy[Bishop]
        of "SEEPruneNoisyRookWeight":
            self.seeWeights.pruneNoisy[Rook]
        of "SEEPruneNoisyQueenWeight":
            self.seeWeights.pruneNoisy[Queen]
        of "MaterialPawnWeight":
            self.materialWeights[Pawn]
        of "MaterialKnightWeight":
            self.materialWeights[Knight]
        of "MaterialBishopWeight":
            self.materialWeights[Bishop]
        of "MaterialRookWeight":
            self.materialWeights[Rook]
        of "MaterialQueenWeight":
            self.materialWeights[Queen]
        of "PawnCorrHistMaxValue":
            self.corrHistMaxValue.pawn
        of "PawnCorrHistMinValue":
            self.corrHistMinValue.pawn
        of "PawnCorrHistEvalScale":
            self.corrHistScale.eval.pawn
        of "PawnCorrHistWeightScale":
            self.corrHistScale.weight.pawn
        of "NonPawnCorrHistMaxValue":
            self.corrHistMaxValue.nonpawn
        of "NonPawnCorrHistMinValue":
            self.corrHistMinValue.nonpawn
        of "NonPawnCorrHistEvalScale":
            self.corrHistScale.eval.nonpawn
        of "NonPawnCorrHistWeightScale":
            self.corrHistScale.weight.nonpawn
        of "MajorCorrHistMaxValue":
            self.corrHistMaxValue.major
        of "MajorCorrHistMinValue":
            self.corrHistMinValue.major
        of "MajorCorrHistEvalScale":
            self.corrHistScale.eval.major
        of "MajorCorrHistWeightScale":
            self.corrHistScale.weight.major
        of "MinorCorrHistMaxValue":
            self.corrHistMaxValue.minor
        of "MinorCorrHistMinValue":
            self.corrHistMinValue.minor
        of "MinorCorrHistEvalScale":
            self.corrHistScale.eval.minor
        of "MinorCorrHistWeightScale":
            self.corrHistScale.weight.minor
        of "1PContCorrHistMaxValue":
            self.corrHistMaxValue.continuation.one
        of "1PContCorrHistMinValue":
            self.corrHistMinValue.continuation.one
        of "1PContCorrHistEvalScale":
            self.corrHistScale.eval.continuation.one
        of "1PContCorrHistWeightScale":
            self.corrHistScale.weight.continuation.one
        of "2PContCorrHistMaxValue":
            self.corrHistMaxValue.continuation.two
        of "2PContCorrHistMinValue":
            self.corrHistMinValue.continuation.two
        of "2PContCorrHistEvalScale":
            self.corrHistScale.eval.continuation.two
        of "2PContCorrHistWeightScale":
            self.corrHistScale.weight.continuation.two
        of "LMRBase":
            int(self.lmrBase * 1000)
        of "LMRMultiplier":
            int(self.lmrMultiplier * 1000)
        else:
            raise newException(ValueError, &"invalid tunable parameter '{name}'")


proc getParamCount*: int = len(params)

iterator getParameters*: TunableParameter =
    ## Yields all parameters that can be
    ## tuned
    for key in params.keys():
        yield params[key]


proc getDefaultParameters*: SearchParameters {.gcsafe.} =
    result = new(SearchParameters)
    for key in params.keys():
        result.setParameter(key, params[key].default)


proc getSPSAInput*(parameters: SearchParameters): string =
    var i = 0
    let count = getParamCount()
    for param in getParameters():
        let current = parameters.getParameter(param.name)
        result &= &"{param.name}, int, {current}, {param.min}, {param.max}, {max(0.5, round((param.max - param.min) / 20))}, 0.002"
        if i < count - 1:
            result &= "\n"
        inc(i)


func staticPieceScore*(parameters: SearchParameters, kind: PieceKind): int {.inline.} =
    ## Returns a static score for the given piece
    ## type using SEE ordering weights (used for MVV)
    parameters.seeWeights.ordering[kind]

func staticPieceScore*(parameters: SearchParameters, piece: Piece): int {.inline.} =
    ## Returns a static score for the given piece
    ## using SEE ordering weights (used for MVV)
    parameters.staticPieceScore(piece.kind)

func materialPieceScore*(parameters: SearchParameters, kind: PieceKind): int {.inline.} =
    ## Returns a static score for the given piece
    ## type to be used for material scaling
    parameters.materialWeights[kind]

func materialPieceScore*(parameters: SearchParameters, piece: Piece): int {.inline.} =
    ## Returns a static score for the given piece
    ## type to be used for material scaling
    parameters.staticPieceScore(piece.kind)