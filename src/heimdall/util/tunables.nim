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


type
    TunableParameter* = object
        ## An SPSA-tunable parameter
        name*: string
        min*: int
        max*: int
        default*: int

    SearchParameters* = ref object
        # NMP: Reduce search depth by min((staticEval - beta) / divisor, maxValue)
        nmpEvalDivisor*: int

        # RFP: Prune only when staticEval - (depth * base - improving_margin * improving) >= beta
        rfpMargins*: tuple[base, improving: int]

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

        # Only prune quiet/capture moves whose SEE score
        # is < this value times depth
        seePruningMargin*: tuple[capture, quiet: int]

        # Good/bad moves get their bonus/malus * depth in their
        # respective history tables
        moveBonuses*: tuple[quiet, capture, conthist: tuple[good, bad: int]]

        # Time management

        # Soft bound is scaled by nodeTmBaseOffset - f * nodeTmScaleFactor
        # where f is the fraction of total nodes that was
        # spent on a root move

        # These are tuned as integers and then divided by 1000
        # when loading them in
        nodeTmBaseOffset*: float
        nodeTmScaleFactor*: float

        # Eval margin for qsearch futility pruning
        qsearchFpEvalMargin*: int

        # Score margins for multiple extensions
        doubleExtMargin*: int
        tripleExtMargin*: int

        # Material scaling parameters
        materialScalingOffset*: int
        materialScalingDivisor*: int

        # Eval threshold for increasing depth
        # for move history updates
        historyDepthEvalThreshold*: int

        # Tunable piece weights
        seeWeights*: array[Pawn..Empty, int]
        materialWeights*: array[Pawn..Empty, int]

        # Correction history
        corrHistMaxValue*: tuple[pawn, nonpawn, major, minor: int, continuation: tuple[one, two: int]]
        corrHistMinValue*: tuple[pawn, nonpawn, major, minor: int, continuation: tuple[one, two: int]]
        corrHistScale*: tuple[weight, eval: tuple[pawn, nonpawn, major, minor: int, continuation: tuple[one, two: int]]]


proc newTunableParameter*(name: string, min, max, default: int): TunableParameter =
    result.name = name
    result.min = min
    result.max = max
    result.default = default


# Paste here the SPSA output from OpenBench and the values
# will be loaded automatically into the default field of each
# parameter
const SPSA_OUTPUT = """
MaterialBishopWeight, 469
NonPawnCorrHistWeightScale, 254
AspWindowMaxSize, 980
NonPawnCorrHistEvalScale, 470
MaterialKnightWeight, 465
DoubleExtMargin, 15
SEEQueenWeight, 1257
NodeTMBaseOffset, 2861
SEEPruningQuietMargin, 79
SEEPruningCaptureMargin, 124
NMPEvalDivisor, 243
RFPImprovingMargin, 135
HistoryDepthEvalThreshold, 53
BadQuietMalus, 280
ContHistMalus, 280
SEEKnightWeight, 465
NonPawnCorrHistMinValue, -12428
RFPBaseMargin, 168
HistoryLMRQuietDivisor, 10901
MajorCorrHistMaxValue, 12028
PawnCorrHistWeightScale, 255
SEEPawnWeight, 99
SEERookWeight, 691
MinorCorrHistWeightScale, 260
AspWindowInitialSize, 19
MinorCorrHistMinValue, -12442
QSearchFPEvalMargin, 211
MajorCorrHistMinValue, -12308
TripleExtMargin, 50
MaterialRookWeight, 647
HistoryLMRNoisyDivisor, 13902
GoodCaptureBonus, 45
NodeTMScaleFactor, 1634
MatScalingOffset, 26283
GoodQuietBonus, 261
ContHistBonus, 261
MajorCorrHistWeightScale, 257
PawnCorrHistMinValue, -12060
PawnCorrHistMaxValue, 12461
SEEBishopWeight, 485
FPBaseOffset, 5
BadCaptureMalus, 113
FPEvalMargin, 196
MatScalingDivisor, 28236
PawnCorrHistEvalScale, 476
MaterialQueenWeight, 1232
MinorCorrHistMaxValue, 11946
MaterialPawnWeight, 103
MajorCorrHistEvalScale, 250
NonPawnCorrHistMaxValue, 12125
MinorCorrHistEvalScale, 261
""".replace(" ", "")


template addTunableParameter(name: string, min, max, default: int) =
    result[name] = newTunableParameter(name, min, max, default)


proc initTunableParameters: Table[string, TunableParameter] =
    ## Adds all our tunable parameters to the global
    ## parameter list
    addTunableParameter("RFPBaseMargin", 1, 200, 100)
    addTunableParameter("RFPImprovingMargin", 1, 200, 100)
    addTunableParameter("FPEvalMargin", 1, 500, 250)
    addTunableParameter("FPBaseOffset", 0, 200, 1)
    # Value asspulled by cj, btw
    addTunableParameter("HistoryLMRQuietDivisor", 6144, 24576, 12288)
    addTunableParameter("HistoryLMRNoisyDivisor", 6144, 24576, 12288)
    addTunableParameter("AspWindowInitialSize", 1, 60, 30)
    addTunableParameter("AspWindowMaxSize", 1, 2000, 1000)
    addTunableParameter("SEEPruningQuietMargin", 1, 160, 80)
    addTunableParameter("SEEPruningCaptureMargin", 1, 320, 160)
    addTunableParameter("GoodQuietBonus", 1, 340, 170)
    addTunableParameter("BadQuietMalus", 1, 900, 450)
    addTunableParameter("GoodCaptureBonus", 1, 90, 45)
    addTunableParameter("BadCaptureMalus", 1, 224, 112)
    addTunableParameter("ContHistBonus", 1, 340, 170)
    addTunableParameter("ContHistMalus", 1, 900, 450)
    # Values yoinked from Stormphrax :3
    addTunableParameter("NodeTMBaseOffset", 1000, 3000, 2630)
    addTunableParameter("NodeTMScaleFactor", 1000, 2500, 1700)
    addTunableParameter("QSearchFPEvalMargin", 100, 400, 200)
    # We copying sf on this one
    addTunableParameter("DoubleExtMargin", 0, 80, 40)
    addTunableParameter("TripleExtMargin", 50, 200, 100)

    addTunableParameter("MatScalingOffset", 13250, 53000, 26500)
    addTunableParameter("MatScalingDivisor", 16384, 65536, 32768)
    addTunableParameter("NMPEvalDivisor", 120, 350, 245)
    addTunableParameter("HistoryDepthEvalThreshold", 25, 100, 50)

    addTunableParameter("SEEPawnWeight", 50, 200, 100)
    addTunableParameter("SEEKnightWeight", 225, 900, 450)
    addTunableParameter("SEEBishopWeight", 225, 900, 450)
    addTunableParameter("SEERookWeight", 325, 1300, 650)
    addTunableParameter("SEEQueenWeight", 625, 2500, 1250)
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
        of "RFPBaseMargin":
            self.rfpMargins.base = value
        of "RFPImprovingMargin":
            self.rfpMargins.improving = value
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
        of "SEEPruningQuietMargin":
            self.seePruningMargin.quiet = value
        of "SEEPruningCaptureMargin":
            self.seePruningMargin.capture = value
        of "GoodQuietBonus":
            self.moveBonuses.quiet.good = value
        of "BadQuietMalus":
            self.moveBonuses.quiet.bad = value
        of "ContHistBonus":
            self.moveBonuses.conthist.good = value
        of "ContHistMalus":
            self.moveBonuses.conthist.bad = value
        of "GoodCaptureBonus":
            self.moveBonuses.capture.good = value
        of "BadCaptureMalus":
            self.moveBonuses.capture.bad = value
        of "NodeTMBaseOffset":
            self.nodeTmBaseOffset = value / 1000
        of "NodeTMScaleFactor":
            self.nodeTmScaleFactor = value / 1000
        of "QSearchFPEvalMargin":
            self.qsearchFpEvalMargin = value
        of "DoubleExtMargin":
            self.doubleExtMargin = value
        of "MatScalingDivisor":
            self.materialScalingDivisor = value
        of "MatScalingOffset":
            self.materialScalingOffset = value
        of "NMPEvalDivisor":
            self.nmpEvalDivisor = value
        of "TripleExtMargin":
            self.tripleExtMargin = value
        of "HistoryDepthEvalThreshold":
            self.historyDepthEvalThreshold = value
        of "SEEPawnWeight":
            self.seeWeights[Pawn] = value
        of "SEEKnightWeight":
            self.seeWeights[Knight] = value
        of "SEEBishopWeight":
            self.seeWeights[Bishop] = value
        of "SEERookWeight":
            self.seeWeights[Rook] = value
        of "SEEQueenWeight":
            self.seeWeights[Queen] = value
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
        else:
            raise newException(ValueError, &"invalid tunable parameter '{name}'")


proc getParameter*(self: SearchParameters, name: string): int =
    ## Retrieves the value of the given search parameter.
    ## Not meant to be used during search

    # This is ugly, but short of macro shenanigans it's
    # the best we can do
    case name:
        of "RFPBaseMargin":
            self.rfpMargins.base
        of "RFPImprovingMargin":
            self.rfpMargins.improving
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
        of "SEEPruningQuietMargin":
            self.seePruningMargin.quiet
        of "SEEPruningCaptureMargin":
            self.seePruningMargin.capture
        of "GoodQuietBonus":
            self.moveBonuses.quiet.good
        of "BadQuietMalus":
            self.moveBonuses.quiet.bad
        of "ContHistBonus":
            self.moveBonuses.conthist.good
        of "ContHistMalus":
            self.moveBonuses.conthist.bad
        of "GoodCaptureBonus":
            self.moveBonuses.capture.good
        of "BadCaptureMalus":
            self.moveBonuses.capture.bad
        of "NodeTMBaseOffset":
            int(self.nodeTmBaseOffset * 1000)
        of "NodeTMScaleFactor":
            int(self.nodeTmScaleFactor * 1000)
        of "QSearchFPEvalMargin":
            self.qsearchFpEvalMargin
        of "DoubleExtMargin":
            self.doubleExtMargin
        of "MatScalingDivisor":
            self.materialScalingDivisor
        of "MatScalingOffset":
            self.materialScalingOffset
        of "NMPEvalDivisor":
            self.nmpEvalDivisor
        of "TripleExtMargin":
            self.tripleExtMargin
        of "HistoryDepthEvalThreshold":
            self.historyDepthEvalThreshold
        of "SEEPawnWeight":
            self.seeWeights[Pawn]
        of "SEEKnightWeight":
            self.seeWeights[Knight]
        of "SEEBishopWeight":
            self.seeWeights[Bishop]
        of "SEERookWeight":
            self.seeWeights[Rook]
        of "SEEQueenWeight":
            self.seeWeights[Queen]
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
    ## type to be used inside SEE
    parameters.seeWeights[kind]

func staticPieceScore*(parameters: SearchParameters, piece: Piece): int {.inline.} =
    ## Returns a static score for the given piece
    ## to be used inside SEE
    parameters.staticPieceScore(piece.kind)

func materialPieceScore*(parameters: SearchParameters, kind: PieceKind): int {.inline.} =
    ## Returns a static score for the given piece
    ## type to be used for material scaling
    parameters.materialWeights[kind]

func materialPieceScore*(parameters: SearchParameters, piece: Piece): int {.inline.} =
    ## Returns a static score for the given piece
    ## type to be used for material scaling
    parameters.staticPieceScore(piece.kind)