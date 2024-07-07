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
import std/tables
import std/strformat
import std/strutils


const isTuningEnabled* {.booldefine:"enableTuning".} = false


type
    TunableParameter* = ref object
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

        # Reverse futility pruning

        # Prune only when we're at least this
        # many engine units ahead in the static
        # evaluation (multiplied by depth)
        rfpEvalThreshold*: int
        # Prune only when depth <= this value
        rfpDepthLimit*: int

        # Futility pruning

        # Prune only when depth <= this value
        fpDepthLimit*: int
        # Prune only when (staticEval + margin) * (depth - improving)
        # is less than alpha
        fpEvalMargin*: int

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
        # Only prune quiet moves whose SEE score
        # is < this value
        seePruningQuietMargin*: int
    
        # Quiet history bonuses

        # Good quiets get a bonus of goodQuietBonus * depth in the
        # quiet history table, bad quiets get a malus of badQuietMalus *
        # depth instead
        goodQuietBonus*: int
        badQuietMalus*: int

        # Capture history bonuses

        # Good captures get a bonus of goodCaptureBonus * depth in the
        # capture history table, bad captures get a malus of badCaptureMalus *
        # depth instead
        goodCaptureBonus*: int
        badCaptureMalus*: int


        # Singular extensions
        seMinDepth*: int
        seDepthMultiplier*: int
        seReductionOffset*: int
        seReductionDivisor*: int
        seDepthIncrement*: int
        seDepthOffset*: int

    
var params = newTable[string, TunableParameter]()


proc newTunableParameter*(name: string, min, max, default: int): TunableParameter =
    ## Initializes a new tunable parameter
    new(result)
    result.name = name
    result.min = min
    result.max = max
    result.default = default


# Paste here the SPSA output from openbench and the values
# will be loaded automatically into the default field of each
# parameter
const SPSA_OUTPUT = """
IIRMinDepth, 4
FPDepthLimit, 5
LMPDepthMultiplier, 1
NMPDepthThreshold, 1
AspWindowInitialSize, 32
LMRPvMovenumber, 5
NMPDepthReduction, 3
RFPEvalThreshold, 119
GoodQuietBonus, 182
SEEPruningQuietMargin, 81
LMRNonPvMovenumber, 2
AspWindowMaxSize, 929
LMPDepthOffset, 5
NMPBaseReduction, 3
LMRMinDepth, 3
SEEPruningMaxDepth, 5
FPEvalMargin, 249
RFPDepthLimit, 7
AspWindowDepthThreshold, 5
BadQuietMalus, 418
""".replace(" ", "")


proc addTunableParameters =
    ## Adds all our tunable parameters to the global
    ## parameter list
    params["NMPDepthThreshold"] = newTunableParameter("NMPDepthThreshold", 1, 4, 2)
    params["NMPBaseReduction"] = newTunableParameter("NMPBaseReduction", 1, 6, 3)
    params["NMPDepthReduction"] = newTunableParameter("NMPDepthReduction", 1, 6, 3)
    params["RFPEvalThreshold"] = newTunableParameter("RFPEvalThreshold", 1, 200, 100)
    params["RFPDepthLimit"] = newTunableParameter("RFPDepthLimit", 1, 14, 7)
    params["FPDepthLimit"] = newTunableParameter("FPDepthLimit", 1, 5, 2)
    params["FPEvalMargin"] = newTunableParameter("FPEvalMargin", 1, 500, 250)
    params["LMPDepthOffset"] = newTunableParameter("LMPDepthOffset", 1, 12, 6)
    params["LMPDepthMultiplier"] = newTunableParameter("LMPDepthMultiplier", 1, 4, 2)
    params["LMRMinDepth"] = newTunableParameter("LMRMinDepth", 1, 6, 3)
    params["LMRPvMovenumber"] = newTunableParameter("LMRPvMovenumber", 1, 10, 5)
    params["LMRNonPvMovenumber"] = newTunableParameter("LMRNonPvMovenumber", 1, 4, 2)
    params["IIRMinDepth"] = newTunableParameter("IIRMinDepth", 1, 8, 4)
    params["IIRDepthDifference"] = newTunableParameter("IIRDepthDifference", 1, 8, 4)
    params["AspWindowDepthThreshold"] = newTunableParameter("AspWindowDepthThreshold", 1, 10, 5)
    params["AspWindowInitialSize"] = newTunableParameter("AspWindowInitialSize", 1, 60, 30)
    params["AspWindowMaxSize"] = newTunableParameter("AspWindowMaxSize", 1, 2000, 1000)
    params["SEEPruningMaxDepth"] = newTunableParameter("SEEPruningMaxDepth", 1, 10, 5)
    params["SEEPruningQuietMargin"] = newTunableParameter("SEEPruningQuietMargin", 1, 160, 80)
    params["GoodQuietBonus"] = newTunableParameter("GoodQuietBonus", 1, 340, 170)
    params["BadQuietMalus"] = newTunableParameter("BadQuietMalus", 1, 900, 450)
    params["GoodCaptureBonus"] = newTunableParameter("GoodCaptureBonus", 1, 90, 45)
    params["BadCaptureMalus"] = newTunableParameter("BadCaptureMalus", 1, 224, 112)
    params["SEMinDepth"] = newTunableParameter("SEMinDepth", 3, 10, 5)
    params["SEDepthMultiplier"] = newTunableParameter("SEDepthMultiplier", 1, 4, 2)
    params["SEReductionOffset"] = newTunableParameter("SEReductionOffset", 0, 2, 1)
    params["SEReductionDivisor"] = newTunableParameter("SEReductionDivisor", 1, 4, 2)
    params["SEDepthIncrement"] = newTunableParameter("SEDepthIncrement", 1, 1, 1)
    params["SEDepthOffset"] = newTunableParameter("SEDepthOffset", 1, 8, 4)
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
        of "RFPEvalThreshold":
            self.rfpEvalThreshold = value
        of "RFPDepthLimit":
            self.rfpDepthLimit = value
        of "FPDepthLimit":
            self.fpDepthLimit = value
        of "FPEvalMargin":
            self.fpEvalMargin = value
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
            self.seePruningQuietMargin = value
        of "GoodQuietBonus":
            self.goodQuietBonus = value
        of "BadQuietMalus":
            self.badQuietMalus = value
        of "GoodCaptureBonus":
            self.goodCaptureBonus = value
        of "BadCaptureMalus":
            self.badCaptureMalus = value
        of "SEMinDepth":
            self.seMinDepth = value
        of "SEDepthMultiplier":
            self.seDepthMultiplier = value
        of "SEReductionOffset":
            self.seReductionOffset = value
        of "SEReductionDivisor":
            self.seReductionDivisor = value
        of "SEDepthIncrement":
            self.seDepthIncrement = value
        of "SEDepthOffset":
            self.seDepthOffset = value
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
        of "RFPEvalThreshold":
            return self.rfpEvalThreshold
        of "RFPDepthLimit":
            return self.rfpDepthLimit
        of "FPDepthLimit":
            return self.fpDepthLimit
        of "FPEvalMargin":
            return self.fpEvalMargin
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
            return self.seePruningQuietMargin
        of "GoodQuietBonus":
            return self.goodQuietBonus
        of "BadQuietMalus":
            return self.badQuietMalus
        of "GoodCaptureBonus":
            return self.goodCaptureBonus
        of "BadCaptureMalus":
            return self.badCaptureMalus
        of "SEMinDepth":
            return self.seMinDepth
        of "SEDepthMultiplier":
            return self.seDepthMultiplier
        of "SEReductionOffset":
            return self.seReductionOffset
        of "SEReductionDivisor":
            return self.seReductionDivisor
        of "SEDepthIncrement":
            return self.seDepthIncrement
        of "SEDepthOffset":
            return self.seDepthOffset
        else:
            raise newException(ValueError, &"invalid tunable parameter '{name}'")


iterator getParameters*: TunableParameter =
    ## Yields all parameters that can be
    ## tuned
    for key in params.keys():
        yield params[key]


proc getDefaultParameters*: SearchParameters =
    ## Returns the set of parameters to be
    ## used during search
    new(result)
    for key in params.keys():
        result.setParameter(key, params[key].default)


proc getSPSAInput*(parameters: SearchParameters): string =
    ## Returns the SPSA input to be passed to
    ## OpenBench for tuning
    for param in getParameters():
        let current = parameters.getParameter(param.name)
        result &= &"{param.name}, int, {current}, {param.min}, {param.max}, {max(0.5, round((param.max - param.min) / 20))}, 0.002\n"


addTunableParameters()