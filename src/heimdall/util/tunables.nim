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

        # Start pruning moves when depth > this
        # value
        nmpDepthThreshold*: int
        # Reduce search depth by at least this value
        nmpBaseReduction*: int
        # Reduce search depth proportionally to the
        # current depth divided by this value, plus
        # the base reduction
        nmpDepthReduction*: int
        # Reduce search depth by min((staticEval - beta) / divisor, maximum)
        nmpEvalDivisor*: int
        nmpEvalMaximum*: int

        # Reverse futility pruning

        # Prune only when staticEval - (depth * base - improving_margin * improving) >= beta
        rfpMargins*: tuple[base, improving: int]
        # Prune only when depth <= this value
        rfpDepthLimit*: int

        # Futility pruning

        # Prune only when depth <= this value
        fpDepthLimit*: int
        # Prune only when (staticEval + offset) + margin * (depth + improving)
        # is less than or equal to alpha
        fpEvalMargin*: int
        fpEvalOffset*: int

        # Late move pruning

        # Start pruning after at least lmpDepthOffset + (lmpDepthMultiplier * depth ^ 2)
        # moves have been played
        lmpDepthOffset*: int
        lmpDepthMultiplier*: int

        # Late move reductions

        # Reduce when depth is >= this value
        lmrMinDepth*: int
        # Reduce when the number of moves yielded by the move
        # picker reaches this value in either a pv or non-pv
        # node
        lmrMoveNumber*: tuple[pv, nonpv: int]
        # The divisors for history reductions
        historyLmrDivisor*: tuple[quiet, noisy: int]

        # Internal Iterative reductions

        # Reduce only when depth >= this value
        iirMinDepth*: int
        # IIR always reduces when there is no TT
        # hit: this value gives additional granularity
        # on top of that, reducing if there is a TT hit
        # whose depth + this value is less than the current
        # one
        iirDepthDifference*: int

        # Aspiration windows
        
        # Use aspiration windows when depth >
        # this value
        aspWindowDepthThreshold*: int
        # Use this value as the initial
        # aspiration window size
        aspWindowInitialSize*: int
        # Give up and search the full range
        # of alpha beta values once the window
        # size gets to this value
        aspWindowMaxSize*: int

        # SEE pruning

        # Only prune when depth <= this value
        seePruningMaxDepth*: int
        # Only prune quiet/capture moves whose SEE score
        # is < this value times depth
        seePruningMargin*: tuple[capture, quiet: int]
    
        # Quiet history bonuses

        # Good/bad moves get their bonus/malus * depth in their
        # respective history tables
        
        moveBonuses*: tuple[quiet, capture: tuple[good, bad: int]]

        # Singular extensions
        seMinDepth*: int
        seDepthMultiplier*: int
        seReductionOffset*: int
        seReductionDivisor*: int
        seDepthOffset*: int

        # Time management stuff

        # Only begin scaling the soft bound
        # based on spent nodes when search
        # depth >= this value
        nodeTmDepthThreshold*: int
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

        previousLmrMinimum*: int
        previousLmrDivisor*: int

        historyDepthEvalThreshold*: int

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
FPDepthLimit, 7
IIRMinDepth, 3
AspWindowMaxSize, 944
LMRPvMovenumber, 4
AspWindowInitialSize, 15
QSearchFPEvalMargin, 202
AspWindowDepthThreshold, 5
NMPBaseReduction, 3
DoubleExtMargin, 38
NodeTMBaseOffset, 2670
NMPEvalMaximum, 3
HistoryLMRNoisyDivisor, 13073
GoodCaptureBonus, 44
NodeTMDepthThreshold, 5
NMPDepthReduction, 4
LMRMinDepth, 3
LMRNonPvMovenumber, 2
SEEPruningQuietMargin, 76
SEEPruningCaptureMargin, 149
LMPDepthOffset, 4
GoodQuietBonus, 209
RFPBaseMargin, 143
RFPImprovingMargin, 143
NodeTMScaleFactor, 1682
RFPDepthLimit, 8
MatScalingOffset, 23993
SEReductionOffset, 1
BadQuietMalus, 342
NMPEvalDivisor, 237
FPBaseOffset, 0
SEReductionDivisor, 2
BadCaptureMalus, 117
FPEvalMargin, 253
NMPDepthThreshold, 1
SEEPruningMaxDepth, 5
MatScalingDivisor, 32600
SEDepthMultiplier, 1
LMPDepthMultiplier, 1
IIRDepthDifference, 4
HistoryLMRQuietDivisor, 11265
SEMinDepth, 4
SEDepthOffset, 4
""".replace(" ", "")


template addTunableParameter(name: string, min, max, default: int) =
    params[name] = newTunableParameter(name, min, max, default)


proc addTunableParameters =
    ## Adds all our tunable parameters to the global
    ## parameter list
    addTunableParameter("NMPDepthThreshold", 1, 4, 2)
    addTunableParameter("NMPBaseReduction", 1, 6, 3)
    addTunableParameter("NMPDepthReduction", 1, 6, 3)
    addTunableParameter("RFPBaseMargin", 1, 200, 100)
    addTunableParameter("RFPImprovingMargin", 1, 200, 100)
    addTunableParameter("RFPDepthLimit", 1, 14, 7)
    addTunableParameter("FPDepthLimit", 1, 10, 2)
    addTunableParameter("FPEvalMargin", 1, 500, 250)
    addTunableParameter("FPBaseOffset", 0, 200, 1)
    addTunableParameter("LMPDepthOffset", 1, 12, 6)
    addTunableParameter("LMPDepthMultiplier", 1, 4, 2)
    addTunableParameter("LMRMinDepth", 1, 6, 3)
    addTunableParameter("LMRPvMovenumber", 1, 10, 5)
    addTunableParameter("LMRNonPvMovenumber", 1, 4, 2)
    # Value asspulled by cj, btw
    addTunableParameter("HistoryLMRQuietDivisor", 6144, 24576, 12288)
    addTunableParameter("HistoryLMRNoisyDivisor", 6144, 24576, 12288)
    addTunableParameter("IIRMinDepth", 1, 8, 4)
    addTunableParameter("IIRDepthDifference", 1, 8, 4)
    addTunableParameter("AspWindowDepthThreshold", 1, 10, 5)
    addTunableParameter("AspWindowInitialSize", 1, 60, 30)
    addTunableParameter("AspWindowMaxSize", 1, 2000, 1000)
    addTunableParameter("SEEPruningMaxDepth", 1, 10, 5)
    addTunableParameter("SEEPruningQuietMargin", 1, 160, 80)
    addTunableParameter("SEEPruningCaptureMargin", 1, 320, 160)
    addTunableParameter("GoodQuietBonus", 1, 340, 170)
    addTunableParameter("BadQuietMalus", 1, 900, 450)
    addTunableParameter("GoodCaptureBonus", 1, 90, 45)
    addTunableParameter("BadCaptureMalus", 1, 224, 112)
    addTunableParameter("SEMinDepth", 3, 10, 5)
    addTunableParameter("SEDepthMultiplier", 1, 4, 2)
    addTunableParameter("SEReductionOffset", 0, 2, 1)
    addTunableParameter("SEReductionDivisor", 1, 4, 2)
    addTunableParameter("SEDepthOffset", 1, 8, 4)
    addTunableParameter("NodeTMDepthThreshold", 1, 10, 5)
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
    addTunableParameter("NMPEvalMaximum", 1, 5, 3)
    addTunableParameter("PreviousLMRMinimum", 3, 8, 5)
    addTunableParameter("PreviousLMRDivisor", 2, 10, 5)
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
        of "NMPDepthThreshold":
            self.nmpDepthThreshold = value
        of "NMPBaseReduction":
            self.nmpDepthReduction = value
        of "NMPDepthReduction":
            self.nmpBaseReduction = value
        of "RFPBaseMargin":
            self.rfpMargins.base = value
        of "RFPImprovingMargin":
            self.rfpMargins.improving = value
        of "RFPDepthLimit":
            self.rfpDepthLimit = value
        of "FPDepthLimit":
            self.fpDepthLimit = value
        of "FPEvalMargin":
            self.fpEvalMargin = value
        of "FPBaseOffset":
            self.fpEvalOffset = value
        of "LMPDepthOffset":
            self.lmpDepthOffset = value
        of "LMPDepthMultiplier":
            self.lmpDepthMultiplier = value
        of "LMRMinDepth":
            self.lmrMinDepth = value
        of "LMRPvMovenumber":
            self.lmrMoveNumber.pv = value
        of "LMRNonPvMovenumber":
            self.lmrMoveNumber.nonpv = value
        of "HistoryLMRQuietDivisor":
            self.historyLmrDivisor.quiet = value
        of "HistoryLMRNoisyDivisor":
            self.historyLmrDivisor.noisy = value
        of "IIRMinDepth":
            self.iirMinDepth = value
        of "IIRDepthDifference":
            self.iirDepthDifference = value
        of "AspWindowDepthThreshold":
            self.aspWindowDepthThreshold = value
        of "AspWindowInitialSize":
            self.aspWindowInitialSize = value
        of "AspWindowMaxSize":
            self.aspWindowMaxSize = value
        of "SEEPruningMaxDepth":
            self.seePruningMaxDepth = value
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
        of "SEMinDepth":
            self.seMinDepth = value
        of "SEDepthMultiplier":
            self.seDepthMultiplier = value
        of "SEReductionOffset":
            self.seReductionOffset = value
        of "SEReductionDivisor":
            self.seReductionDivisor = value
        of "SEDepthOffset":
            self.seDepthOffset = value
        of "NodeTMDepthThreshold":
            self.nodeTmDepthThreshold = value
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
        of "NMPEvalMaximum":
            self.nmpEvalMaximum = value
        of "TripleExtMargin":
            self.tripleExtMargin = value
        of "PreviousLMRMinimum":
            self.previousLmrMinimum = value
        of "PreviousLMRDivisor":
            self.previousLmrDivisor = value
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
        of "NMPDepthThreshold":
            return self.nmpDepthThreshold
        of "NMPBaseReduction":
            return self.nmpBaseReduction
        of "NMPDepthReduction":
            return self.nmpDepthReduction
        of "RFPBaseMargin":
            return self.rfpMargins.base
        of "RFPImprovingMargin":
            return self.rfpMargins.improving
        of "RFPDepthLimit":
            return self.rfpDepthLimit
        of "FPDepthLimit":
            return self.fpDepthLimit
        of "FPEvalMargin":
            return self.fpEvalMargin
        of "FPBaseOffset":
            return self.fpEvalOffset
        of "LMPDepthOffset":
            return self.lmpDepthOffset
        of "LMPDepthMultiplier":
            return self.lmpDepthMultiplier
        of "LMRMinDepth":
            return self.lmrMinDepth
        of "LMRPvMovenumber":
            return self.lmrMoveNumber.pv
        of "LMRNonPvMovenumber":
            return self.lmrMoveNumber.nonpv
        of "HistoryLMRQuietDivisor":
            return self.historyLmrDivisor.quiet
        of "HistoryLMRNoisyDivisor":
            self.historyLmrDivisor.noisy
        of "IIRMinDepth":
            return self.iirMinDepth
        of "IIRDepthDifference":
            return self.iirDepthDifference
        of "AspWindowDepthThreshold":
            return self.aspWindowDepthThreshold
        of "AspWindowInitialSize":
            return self.aspWindowInitialSize
        of "AspWindowMaxSize":
            return self.aspWindowMaxSize
        of "SEEPruningMaxDepth":
            return self.seePruningMaxDepth
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
        of "SEMinDepth":
            return self.seMinDepth
        of "SEDepthMultiplier":
            return self.seDepthMultiplier
        of "SEReductionOffset":
            return self.seReductionOffset
        of "SEReductionDivisor":
            return self.seReductionDivisor
        of "SEDepthOffset":
            return self.seDepthOffset
        of "NodeTMDepthThreshold":
            return self.nodeTmDepthThreshold
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
        of "NMPEvalMaximum":
            return self.nmpEvalMaximum
        of "TripleExtMargin":
            return self.tripleExtMargin
        of "PreviousLMRMinimum":
            return self.previousLmrMinimum
        of "PreviousLMRDivisor":
            return self.previousLmrDivisor
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