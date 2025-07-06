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

import std/math
import std/tables
import std/strutils
import std/strformat

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
        ## A set of search parameters
        
        # Null move pruning

        # Reduce search depth by min((staticEval - beta) / divisor, maximum)
        nmpEvalDivisor*: int

        # Reverse futility pruning

        # Prune only when staticEval - (depth * base - improving_margin * improving) >= beta
        rfpMargins*: tuple[base, improving: int]

        # Futility pruning

        # Prune only when (staticEval + offset) + margin * (depth + improving) <= alpha
        fpEvalMargin*: int
        fpEvalOffset*: int

        # Late move reductions

        # The divisors for history reductions
        historyLmrDivisor*: tuple[quiet, noisy: int]

        # Aspiration windows
        
        # Use this value as the initial
        # aspiration window size
        aspWindowInitialSize*: int
        # Give up and search the full range
        # of alpha beta values once the window
        # size gets to this value
        aspWindowMaxSize*: int

        # SEE pruning

        # Only prune quiet/capture moves whose SEE score
        # is < this value times depth
        seePruningMargin*: tuple[capture, quiet: int]
    
        # Quiet history bonuses

        # Good/bad moves get their bonus/malus * depth in their
        # respective history tables
        
        moveBonuses*: tuple[quiet, capture: tuple[good, bad: int]]

        # Time management stuff

        # Soft bound is scaled by nodeTmBaseOffset - f * nodeTmScaleFactor
        # where f is the fraction of total nodes that was
        # spent on a root move

        # These are tuned as integers and then divided by 1000
        # when loading them in
        nodeTmBaseOffset*: float
        nodeTmScaleFactor*: float

        # Margin for qsearch futility pruning
        qsearchFpEvalMargin*: int

        # Multiple extensions
        doubleExtMargin*: int
        tripleExtMargin*: int

        # Eval corrections
        materialScalingOffset*: int
        materialScalingDivisor*: int

        historyDepthEvalThreshold*: int

        # Tunable piece weights
        seeWeights*: array[Pawn..Empty, int]
        materialWeights*: array[Pawn..Empty, int]
    

var params = newTable[string, TunableParameter]()

proc newTunableParameter*(name: string, min, max, default: int): TunableParameter =
    ## Initializes a new tunable parameter
    result.name = name
    result.min = min
    result.max = max
    result.default = default


# Paste here the SPSA output from openbench and the values
# will be loaded automatically into the default field of each
# parameter
const SPSA_OUTPUT = """
AspWindowMaxSize, 944
AspWindowInitialSize, 15
QSearchFPEvalMargin, 202
DoubleExtMargin, 38
NodeTMBaseOffset, 2670
HistoryLMRNoisyDivisor, 13073
GoodCaptureBonus, 44
SEEPruningQuietMargin, 76
SEEPruningCaptureMargin, 149
GoodQuietBonus, 209
RFPBaseMargin, 143
RFPImprovingMargin, 143
NodeTMScaleFactor, 1682
MatScalingOffset, 23993
BadQuietMalus, 342
NMPEvalDivisor, 237
FPBaseOffset, 0
BadCaptureMalus, 117
FPEvalMargin, 253
MatScalingDivisor, 32600
HistoryLMRQuietDivisor, 11265
""".replace(" ", "")


template addTunableParameter(name: string, min, max, default: int) =
    params[name] = newTunableParameter(name, min, max, default)


proc addTunableParameters =
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

    for line in SPSA_OUTPUT.splitLines(keepEol=false):
        if line.len() == 0:
            continue
        let splosh = line.split(",", maxsplit=2)
        params[splosh[0]].default = splosh[1].parseInt()


proc isParamName*(name: string): bool =
    ## Returns whether the given string
    ## represents a tunable parameter name
    return name in params


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
        else:
            raise newException(ValueError, &"invalid tunable parameter '{name}'")


proc getParameter*(self: SearchParameters, name: string): int =
    # Retrieves the value of the given search parameter.
    # This is not meant to be used during search (it's
    # not the fastest thing ever), but rather for SPSA
    # tuning!

    # This is ugly, but short of macro shenanigans it's
    # the best we can do
    case name:
        of "RFPBaseMargin":
            return self.rfpMargins.base
        of "RFPImprovingMargin":
            return self.rfpMargins.improving
        of "FPEvalMargin":
            return self.fpEvalMargin
        of "FPBaseOffset":
            return self.fpEvalOffset
        of "HistoryLMRQuietDivisor":
            return self.historyLmrDivisor.quiet
        of "HistoryLMRNoisyDivisor":
            self.historyLmrDivisor.noisy
        of "AspWindowInitialSize":
            return self.aspWindowInitialSize
        of "AspWindowMaxSize":
            return self.aspWindowMaxSize
        of "SEEPruningQuietMargin":
            return self.seePruningMargin.quiet
        of "SEEPruningCaptureMargin":
            return self.seePruningMargin.capture
        of "GoodQuietBonus":
            return self.moveBonuses.quiet.good
        of "BadQuietMalus":
            return self.moveBonuses.quiet.bad
        of "GoodCaptureBonus":
            return self.moveBonuses.capture.good
        of "BadCaptureMalus":
            return self.moveBonuses.capture.bad
        of "NodeTMBaseOffset":
            return int(self.nodeTmBaseOffset * 1000)
        of "NodeTMScaleFactor":
            return int(self.nodeTmScaleFactor * 1000)
        of "QSearchFPEvalMargin":
            return self.qsearchFpEvalMargin
        of "DoubleExtMargin":
            return self.doubleExtMargin
        of "MatScalingDivisor":
            return self.materialScalingDivisor
        of "MatScalingOffset":
            return self.materialScalingOffset
        of "NMPEvalDivisor":
            return self.nmpEvalDivisor
        of "TripleExtMargin":
            return self.tripleExtMargin
        of "HistoryDepthEvalThreshold":
            return self.historyDepthEvalThreshold
        of "SEEPawnWeight":
            return self.seeWeights[Pawn]
        of "SEEKnightWeight":
            return self.seeWeights[Knight]   
        of "SEEBishopWeight":
            return self.seeWeights[Bishop]
        of "SEERookWeight":
            return self.seeWeights[Rook]
        of "SEEQueenWeight":
            return self.seeWeights[Queen]
        of "MaterialPawnWeight":
            return self.materialWeights[Pawn]
        of "MaterialKnightWeight":
            return self.materialWeights[Knight]   
        of "MaterialBishopWeight":
            return self.materialWeights[Bishop]
        of "MaterialRookWeight":
            return self.materialWeights[Rook]
        of "MaterialQueenWeight":
            return self.materialWeights[Queen]
        else:
            raise newException(ValueError, &"invalid tunable parameter '{name}'")


iterator getParameters*: TunableParameter =
    ## Yields all parameters that can be
    ## tuned
    for key in params.keys():
        yield params[key]


proc getParamCount*: int = len(params)


proc getDefaultParameters*: SearchParameters {.gcsafe.} =
    ## Returns the set of parameters to be
    ## used during search
    new(result)
    # TODO: This is ugly, find a way around it
    {.cast(gcsafe).}:
        for key in params.keys():
            result.setParameter(key, params[key].default)


proc getSPSAInput*(parameters: SearchParameters): string =
    ## Returns the SPSA input to be passed to
    ## OpenBench for tuning
    var i = 0
    let count = getParamCount()
    for param in getParameters():
        let current = parameters.getParameter(param.name)
        result &= &"{param.name}, int, {current}, {param.min}, {param.max}, {max(0.5, round((param.max - param.min) / 20))}, 0.002"
        if i < count - 1:
            result &= "\n"
        inc(i)

func getStaticPieceScore*(parameters: SearchParameters, kind: PieceKind): int {.inline.} =
    ## Returns a static score for the given piece
    ## type to be used inside SEE. This makes testing
    ## as well as general usage of SEE much more
    ## sane, because if SEE(move) == 0 then we know
    ## the capture sequence is balanced
    return parameters.seeWeights[kind]


func getStaticPieceScore*(parameters: SearchParameters, piece: Piece): int {.inline.} =
    ## Returns a static score for the given piece
    ## to be used inside SEE. This makes testing
    ## as well as general usage of SEE much more
    ## sane, because if SEE(move) == 0 then we know
    ## the capture sequence is balanced
    return parameters.getStaticPieceScore(piece.kind)


func getMaterialPieceScore*(parameters: SearchParameters, kind: PieceKind): int {.inline.} =
    ## Returns a static score for the given piece
    ## type to be used for material scaling
    return parameters.materialWeights[kind]


func getMaterialPieceScore*(parameters: SearchParameters, piece: Piece): int {.inline.} =
    ## Returns a static score for the given piece
    ## type to be used for material scaling
    return parameters.getStaticPieceScore(piece.kind)


addTunableParameters()