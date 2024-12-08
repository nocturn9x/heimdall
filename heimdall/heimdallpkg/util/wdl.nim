import heimdallpkg/eval
import heimdallpkg/util/shared


import std/sequtils
import std/math


# Yoinked from https://github.com/Ciekce/Stormphrax/blob/main/src/wdl.{cpp,h}
# Values computed with https://github.com/official-stockfish/WDL_model

const
    SCORE_NORMALIZATION_FACTOR* {.define: "evalNormalizeFactor".}: int = 200
    A_s = [-75.67430242'f64, 172.26207539, -173.94541603, 382.27877549]
    B_s = [-45.93901607'f64, 100.58513138, 41.81226223, 44.68337272]

const sum = round(foldl(A_s, a + b)).int

when sum != SCORE_NORMALIZATION_FACTOR:
    import std/strformat

    {.fatal: &"Expected sum(a_s[]) to be {SCORE_NORMALIZATION_FACTOR}, got {sum} instead".}


proc getWDLParameters(material: int): tuple[a, b: float64] =
    # Returns the parameters to be used for WDL estimation
    # and score normalization

    let m = material.clamp(17, 78).float64 / 58.0

    result.a = (((A_s[0] * m + A_s[1]) * m + A_s[2]) * m) + A_s[3]
    result.b = (((B_s[0] * m + B_s[1]) * m + B_s[2]) * m) + B_s[3]
    


proc getExpectedWDL*(score: Score, material: int): tuple[win, draw, loss: int] =
    ## Returns the expected win, loss and draw
    ## probabilities (multiplied by a thousand)
    ## with the given score and material values
    
    let
        (a, b) = material.getWDLParameters()
        x = score.float

    result.win = int(round(1000.0 / (1.0 + exp((a - x) / b))))
    result.loss = int(round(1000.0 / (1.0 + exp((a + x) / b))))
    result.draw = 1000 - result.win - result.loss


proc normalizeScore*(score: Score, material: int): Score =
    ## Normalizes the given score such that a value of
    ## 100 indicates a 50% probability of winning, based
    ## on the amount of material on the board in the scored
    ## position
    if score == 0 or abs(score) >= mateScore() - MAX_DEPTH:
        return score
    
    let (a, _) = material.getWDLParameters()
    
    return Score(round(100.0 * score.float / a))