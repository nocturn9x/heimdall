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

## Search routines for heimdall
import board
import movegen
import eval
import see
import tunables
import transpositions


import std/math
import std/times
import std/options
import std/atomics
import std/monotimes
import std/strformat


# Miscellaneous parameters that are not meant to be tuned
const
   
    # TODO
    # Constants to configure razoring

    # Only prune when depth <= this value
    RAZORING_DEPTH_LIMIT {.used.} = 4

    # Only consider razoring positions
    # whose static eval + (this value * depth) 
    # is <= alpha
    RAZORING_EVAL_THRESHOLD {.used.} = 400

    # Miscellaneaus configuration

    NUM_KILLERS* = 2
    MAX_DEPTH* = 255
    # Constants used during move ordering

    MVV_LVA_MULTIPLIER = 10
    PROMOTION_MULTIPLIER = 2
    # These offsets are used in the move
    # ordering step to ensure moves from
    # different heuristics don't have
    # overlapping scores. Heuristics with
    # higher offsets will always be placed
    # first
    TTMOVE_OFFSET = 700_000
    GOOD_SEE_OFFSET = 600_000
    KILLERS_OFFSET = 500_000
    COUNTER_OFFSET = 400_000
    QUIET_OFFSET = 200_000
    BAD_SEE_OFFSET = 50_000

    # Max value for scores in our quiet
    # history
    HISTORY_SCORE_CAP = 16384

func computeLMRTable: array[MAX_DEPTH, array[MAX_MOVES, int]] {.compileTime.} =
    ## Precomputes the table containing reduction offsets at compile
    ## time
    for i in 1..result.high():
        for j in 1..result[0].high():
            result[i][j] = round(0.8 + ln(i.float) * ln(j.float) * 0.4).int


const LMR_TABLE = computeLMRTable()


type
    HistoryTable* = array[PieceColor.White..PieceColor.Black, array[Square(0)..Square(63), array[Square(0)..Square(63), Score]]]
    CountersTable* = array[Square(0)..Square(63), array[Square(0)..Square(63), Move]]
    KillersTable* = array[MAX_DEPTH, array[NUM_KILLERS, Move]]
    SearchManager* = ref object
        ## A simple state storage
        ## for our search
        searching: Atomic[bool]
        stop: Atomic[bool]
        pondering: Atomic[bool]
        board*: Chessboard
        bestRootScore: Score
        searchStart: MonoTime
        hardLimit: MonoTime
        softLimit: MonoTime
        nodeCount: uint64
        maxNodes: uint64
        searchMoves: seq[Move]
        transpositionTable: ptr TTable
        history: ptr HistoryTable
        killers: ptr KillersTable
        counters: ptr CountersTable
        maxSearchTime: int64
        # We keep one extra entry so we don't need any special casing
        # inside the search function when constructing pv lines
        pvMoves: array[MAX_DEPTH + 1, array[MAX_DEPTH + 1, Move]]
        # The highest depth we explored to, including extensions
        selectiveDepth: int
        # The highest depth we cleared fully (without being stopped
        # or cancelled)
        highestDepth: int
        # Are we the main worker?
        isMainWorker: bool
        # We keep track of all the worker
        # threads' respective search states
        # to collect statistics efficiently
        children: seq[SearchManager]
        # All static evaluations
        # for every ply of the search
        evals: array[MAX_DEPTH, Score]
        # The move that lead to the position
        # currently being searched
        previousMove: Move
        # The piece that moved in the previous
        # move
        previousPiece: Piece
        # The set of parameters used by search
        parameters: SearchParameters


proc newSearchManager*(positions: seq[Position], transpositions: ptr TTable,
                       history: ptr HistoryTable, killers: ptr KillersTable, 
                       counters: ptr CountersTable, parameters: SearchParameters,
                       mainWorker=true): SearchManager =
    ## Initializes a new search manager
    new(result)
    result = SearchManager(transpositionTable: transpositions, history: history,
                           killers: killers, counters: counters, isMainWorker: mainWorker,
                           parameters: parameters)
    new(result.board)
    result.board.positions = positions
    for i in 0..MAX_DEPTH:
        for j in 0..MAX_DEPTH:
            result.pvMoves[i][j] = nullMove()


proc `destroy=`*(self: SearchManager) =
    ## Ensures our manually allocated objects
    ## are deallocated correctly upon destruction
    if not self.isMainWorker:
        # This state is thread-local and is fine to
        # destroy *unless* we're the main worker. This
        # is because the main worker copies these to other
        # threads when the search begins, and they are passed
        # in from somewhere else, meaning that the main worker
        # technically doesn't own them
        dealloc(self.killers)
        dealloc(self.history)


func isSearching*(self: SearchManager): bool {.inline.} =
    ## Returns whether a search for the best
    ## move is in progress
    result = self.searching.load()


func stop*(self: SearchManager) =
    ## Stops the search if it is
    ## running
    if self.isSearching():
        self.stop.store(true)
    # Stop all worker threads
    for child in self.children:
        stop(child)


func isKillerMove(self: SearchManager, move: Move, ply: int): bool =
    ## Returns whether the given move is a killer move
    for killer in self.killers[ply]:
        if killer == move:
            return true


func getHistoryScore(self: SearchManager, sideToMove: PieceColor, move: Move): Score =
    ## Returns the score for the given move and side to move
    ## in our quiet history table
    result = self.history[sideToMove][move.startSquare][move.targetSquare]


func storeHistoryScore(self: SearchManager, sideToMove: PieceColor, move: Move, depth: int, good: bool) {.inline.} =
    ## Stores a move for the given side in our quiet history table,
    ## tweaking the score appropriately if it failed high or low
    
    let bonus = if good: self.parameters.goodQuietBonus * depth else: -self.parameters.badQuietMalus * depth
    # We use this formula to evenly spread the improvement the more we increase it (or decrease it) 
    # while keeping it constrained to a maximum (or minimum) value so it doesn't (over|under)flow.
    self.history[sideToMove][move.startSquare][move.targetSquare] += Score(bonus) - abs(bonus.int32) * self.getHistoryScore(sideToMove, move) div HISTORY_SCORE_CAP


proc getEstimatedMoveScore(self: SearchManager, hashMove: Move, move: Move, ply: int): int =
    ## Returns an estimated static score for the move used
    ## during move ordering
    let sideToMove = self.board.positions[^1].sideToMove

    if move == hashMove:
        # The TT move always goes first
        return TTMOVE_OFFSET

    if ply > 0 and self.isKillerMove(move, ply):
        # Killer moves come second
        return KILLERS_OFFSET

    if move == self.counters[self.previousMove.startSquare][self.previousMove.targetSquare]:
        # Counter moves come third
        return COUNTER_OFFSET

    # Good/bad tacticals
    if move.isTactical():
        let seeScore = self.board.positions[^1].see(move)
        # We want to prioritize good captures (see > 0), but if the capture
        # is bad then at least we sort it with MVVLVA
        if seeScore < 0 and move.isCapture():   # TODO: En passant!
            # Implementation of MVVLVA: Most Valuable Victim Least Valuable Aggressor.
            # We prioritize moves that capture the most valuable pieces, and as a
            # second goal we want to use our least valuable pieces to do so (this
            # is why we multiply the score of the captured piece by a constant, to give
            # it priority)
            let capturedScore = MVV_LVA_MULTIPLIER * self.board.positions[^1].getPieceScore(move.targetSquare)
            result = capturedScore - self.board.positions[^1].getPieceScore(move.startSquare)
        
            # If the capture is also a promotion we want to give it an even bigger bonus
            if move.isPromotion():
                var piece: Piece
                case move.getPromotionType():
                    of PromoteToBishop:
                        piece = Piece(kind: Bishop, color: sideToMove)
                    of PromoteToKnight:
                        piece = Piece(kind: Knight, color: sideToMove)
                    of PromoteToRook:
                        piece = Piece(kind: Rook, color: sideToMove)
                    of PromoteToQueen:
                        piece = Piece(kind: Queen, color: sideToMove)
                    else:
                        discard  # Unreachable
                result += PROMOTION_MULTIPLIER * self.board.positions[^1].getPieceScore(piece, move.targetSquare)

            return result + BAD_SEE_OFFSET
        else:
            # If the capture is good then we just use the SEE score + the offset
            return seeScore + GOOD_SEE_OFFSET

    if move.isQuiet():
        # History heuristic bonus
        let score = self.getHistoryScore(sideToMove, move)
        # We use an explicit offset for quiet moves because
        # we want to place bad captures behind them
        return QUIET_OFFSET + score


iterator pickMoves(self: SearchManager, hashMove: Move, ply: int, qsearch: bool = false): Move =
    ## Abstracts movegen away from search by picking moves using
    ## our move orderer
    
    var moves = newMoveList()
    self.board.generateMoves(moves, capturesOnly=qsearch)
    var scores: array[MAX_MOVES, int]
    # Precalculate the move scores
    for i, move in moves:
        scores[i] = self.getEstimatedMoveScore(hashMove, move, ply)
    # Incremental selection sort: we lazily sort the move list
    # as we yield elements from it, which is on average faster than
    # sorting the entire move list with e.g. quicksort, due to the fact
    # that thanks to our pruning we don't actually explore all the moves
    for startIndex in 0..<moves.len():
        var
            bestMoveIndex = moves.len()
            bestScore = int.low()
        for i in startIndex..<moves.len():
            if scores[i] > bestScore:
                bestScore = scores[i]
                bestMoveIndex = i
        if bestMoveIndex == moves.len():
            break
        yield moves[bestMoveIndex]
        # To avoid having to keep track of the moves we've
        # already returned, we just move them to a side of
        # the list that we won't iterate anymore. This has
        # the added benefit of sorting the list of moves
        # incrementally
        let move = moves[startIndex]
        let score = scores[startIndex]
        # Swap the moves and their respective scores
        moves.data[startIndex] = moves[bestMoveIndex]
        scores[startIndex] = scores[bestMoveIndex]
        moves.data[bestMoveIndex] = move
        scores[bestMoveIndex] = score


proc timedOut(self: SearchManager): bool = getMonoTime() >= self.hardLimit
func isPondering*(self: SearchManager): bool = self.pondering.load()
func cancelled(self: SearchManager): bool = self.stop.load()
proc elapsedTime(self: SearchManager): int64 = (getMonoTime() - self.searchStart).inMilliseconds()


proc stopPondering*(self: SearchManager) =
    ## Stop pondering and switch to regular search.
    ## Search deadlines are updated according to the
    ## current time, but still within the limits of
    ## the search when it was first started
    self.pondering.store(false)
    let t = getMonoTime()
    self.hardLimit = t + initDuration(milliseconds=self.maxSearchTime)
    self.softLimit = t + initDuration(milliseconds=self.maxSearchTime div 3)
    # Propagate the stop of pondering search to children
    for child in self.children:
        child.stopPondering()


func nodes*(self: SearchManager): uint64 =
    ## Returns the number of nodes that
    ## have been analyzed
    result = self.nodeCount
    for child in self.children:
        result += child.nodeCount


proc log(self: SearchManager, depth: int) =
    if not self.isMainWorker:
        # We restrict logging to the main worker to reduce
        # noise and simplify things
        return
    # Using an atomic for such frequently updated counters kills
    # performance and cripples nps scaling, so instead we let each
    # thread have its own local counters and then aggregate the results
    # here
    var
        nodeCount = self.nodeCount
        selDepth = self.selectiveDepth
    for child in self.children:
        nodeCount += child.nodeCount
        selDepth = max(selDepth, child.selectiveDepth)
    let 
        elapsedMsec = self.elapsedTime().uint64
        nps = 1000 * (nodeCount div max(elapsedMsec, 1))
    var logMsg = &"info depth {depth} seldepth {selDepth}"
    if abs(self.bestRootScore) >= mateScore() - MAX_DEPTH:
        if self.bestRootScore > 0:
            logMsg &= &" score mate {((mateScore() - self.bestRootScore + 1) div 2)}"
        else:
            logMsg &= &" score mate {(-(mateScore() + self.bestRootScore) div 2)}"
    else:
        logMsg &= &" score cp {self.bestRootScore}"
    logMsg &= &" hashfull {self.transpositionTable[].getFillEstimate()} time {elapsedMsec} nodes {nodeCount} nps {nps}"
    if self.pvMoves[0][0] != nullMove():
        logMsg &= " pv "
        for move in self.pvMoves[0]:
            if move == nullMove():
                break
            logMsg &= &"{move.toAlgebraic()} "
    echo logMsg


proc shouldStop(self: SearchManager): bool =
    ## Returns whether searching should
    ## stop
    if self.cancelled():
        # Search has been cancelled!
        return true
    # Checking the time for every. single. node. seems wasteful,
    # considering we go through several thousands in the blink of
    # an eye, so we only check every 1024 nodes instead. Future me
    # reference: mod by a constant is not as slow as you think.
    if (self.nodeCount mod 1024'u64) == 0 and not self.isPondering() and self.timedOut():
        # We ran out of time!
        return true
    if self.maxNodes > 0 and self.nodeCount >= self.maxNodes:
        # Ran out of nodes
        return true


proc getReduction(self: SearchManager, move: Move, depth, ply, moveNumber: int, isPV, improving: bool): int =
    ## Returns the amount a search depth should be reduced to
    let moveCount = if isPV: self.parameters.lmrMoveNumber.pv else: self.parameters.lmrMoveNumber.nonpv
    if moveNumber > moveCount and depth >= self.parameters.lmrMinDepth:
        result = LMR_TABLE[depth][moveNumber]
        if isPV:
            # Reduce PV nodes less
            # Gains: 37.8 +/- 20.7
            dec(result)

        if self.board.inCheck():
            # Reduce less when opponent is in check
            dec(result)

        # Keep the reduction in the right range
        result = result.clamp(0, depth - 1)


proc qsearch(self: SearchManager, ply: int, alpha, beta: Score): Score =
    ## Negamax search with a/b pruning that is restricted to
    ## capture moves (commonly called quiescent search). The
    ## purpose of this extra search step is to mitigate the 
    ## so called horizon effect that stems from the fact that,
    ## at some point, the engine will have to stop searching, possibly
    ## thinking a bad move is good because it couldn't see far enough
    ## ahead (this usually results in the engine blundering captures
    ## or sacking pieces for apparently no reason: the reason is that it
    ## did not look at the opponent's responses, because it stopped earlier. 
    ## That's the horizon). To address this, we look at all possible captures
    ## in the current position and make sure that a position is evaluated as 
    ## bad if only bad capture moves are possible, even if good non-capture moves
    ## exist
    if self.board.isDrawn():
        return Score(0)
    # We don't care about the depth of cutoffs in qsearch, anything will do
    # Gains: 23.2 +/- 15.4
    let query = self.transpositionTable[].get(self.board.positions[^1].zobristKey)
    let hashMove = if query.isSome(): query.get().bestMove else: nullMove()
    if query.isSome():
        let entry = query.get()
        var score = entry.score
        if abs(score) >= mateScore() - MAX_DEPTH:
            score -= int16(score.int.sgn() * ply)
        case entry.flag:
            of Exact:
                return score
            of LowerBound:
                if score >= beta:
                    return score
            of UpperBound:
                if score <= alpha:
                    return score
    let score = self.board.positions[^1].evaluate(EvalMode.Default)
    if score >= beta:
        # Stand-pat evaluation
        return score
    var bestScore = score
    var alpha = max(alpha, score)
    for move in self.pickMoves(hashMove, ply, qsearch=true):
        # Skip bad captures (gains 52.9 +/- 25.2)
        if self.board.positions[^1].see(move) < 0:
            continue
        self.previousMove = move
        self.previousPiece = self.board.positions[^1].getPiece(self.previousMove.startSquare)
        self.board.doMove(move)
        inc(self.nodeCount)
        let score = -self.qsearch(ply + 1, -beta, -alpha)
        self.board.unmakeMove()
        bestScore = max(score, bestScore)
        if score >= beta:
            # This move was too good for us, opponent will not search it
            break
        if score > alpha:
            alpha = score
    return bestScore


proc storeKillerMove(self: SearchManager, ply: int, move: Move) {.used.} =
    ## Stores a killer move into our killers table at the given
    ## ply

    # Stolen from https://rustic-chess.org/search/ordering/killers.html

    # First killer move must not be the same as the one we're storing
    let first = self.killers[][ply][0]
    if first == move:
        return
    var j = self.killers[][ply].len() - 2
    while j >= 0:
        # Shift moves one spot down
        self.killers[][ply][j + 1] = self.killers[][ply][j];
        dec(j)
    self.killers[][ply][0] = move


func clearPV(self: SearchManager, ply: int) =
    ## Clears the table used to store the
    ## principal variation at the given
    ## ply
    for i in 0..self.pvMoves[ply].high():
        self.pvMoves[ply][i] = nullMove()


proc search(self: SearchManager, depth, ply: int, alpha, beta: Score, isPV: bool): Score {.discardable.} =
    ## Negamax search with various optimizations and features
    assert alpha < beta
    assert isPV or alpha + 1 == beta

    if depth > 1 and self.shouldStop():
        # We do not let ourselves get cancelled until we have
        # cleared at least depth 1
        return

    # Clear the PV table for this ply
    self.clearPV(ply)

    let originalAlpha = alpha
    self.selectiveDepth = max(self.selectiveDepth, ply)
    if self.board.isDrawn():
        return Score(0)
    var depth = depth
    let sideToMove = self.board.positions[^1].sideToMove
    if self.board.positions[^1].inCheck():
        # Check extension. We perform it now instead
        # of in the move loop because this avoids us
        # dropping into quiescent search when we are
        # in check. We also use max() instead of just
        # adding one to the depth because, due to our
        # reduction scheme, it may be negative and so
        # the simple addition might not be enough to
        # make the depth > 0 again
        depth = max(depth + 1, 1)
    if depth <= 0:
        # Quiescent search gain: 264.8 +/- 71.6
        return self.qsearch(ply, alpha, beta)
    # Probe the transposition table to see if we can cause an early cutoff
    let query = self.transpositionTable[].get(self.board.positions[^1].zobristKey)
    let hashMove = if query.isNone(): nullMove() else: query.get().bestMove
    let staticEval = if query.isNone(): self.board.positions[^1].evaluate(EvalMode.Default) else: query.get().staticEval
    self.evals[ply] = staticEval
    # If the static eval from this position is greater than that from 2 plies
    # ago (our previous turn), then we are improving our position
    var improving = false
    if ply > 2 and not self.board.inCheck():
        improving = staticEval > self.evals[ply - 2]
    # Only cut off in non-pv nodes
    # to avoid random blunders
    if not isPV and query.isSome():
        let entry = query.get()
        # We can not trust a TT entry score for cutting off
        # this node if it comes from a shallower search than
        # the one we're currently doing, because it will not
        # have looked at all the possibilities
        if entry.depth >= depth.uint8:
            var score = entry.score
            if abs(score) >= mateScore() - MAX_DEPTH:
                score -= int16(score.int.sgn() * ply)
            case entry.flag:
                of Exact:
                    return score
                of LowerBound:
                    if score >= beta:
                        return score
                of UpperBound:
                    if score <= alpha:
                        return score
    if ply > 0 and depth >= self.parameters.iirMinDepth and query.isNone():
        # Internal iterative reductions: if there is no best move in the TT
        # for this node, it's not worth it to search it at full depth, so we
        # reduce it and hope that the next search iteration yields better
        # results
        depth -= 1
    if not isPV and not self.board.inCheck() and depth <= self.parameters.rfpDepthLimit and staticEval - self.parameters.rfpEvalThreshold * depth >= beta:
        # Reverse futility pruning: if the side to move has a significant advantage
        # in the current position and is not in check, return the position's static
        # evaluation to encourage the engine to deal with any potential threats from
        # the opponent. Since this optimization technique is not sound, we limit the
        # depth at which it can trigger for safety purposes (it is also the reason
        # why the "advantage" threshold scales with depth: the deeper we go, the more
        # careful we want to be with our estimate for how much of an advantage we may
        # or may not have)
        return staticEval
    if not isPV and depth > self.parameters.nmpDepthThreshold and self.board.canNullMove() and staticEval >= beta:
        # Null move pruning: it is reasonable to assume that
        # it is always better to make a move than not to do
        # so (with some exceptions noted below). To take advantage
        # of this assumption, we bend the rules a little and perform
        # a so-called "null move", basically passing our turn doing
        # nothing, and then perform a shallower search for our opponent.
        # If the shallow search fails high (i.e. produces a beta cutoff),
        # then it is useless for us to search this position any further
        # and we can just return the score outright. Since we only care about
        # whether the opponent can beat beta and not the actual value, we
        # can do a null window search and save some time, too. There are a
        # few rules that need to be followed to use NMP properly, though: we
        # must not be in check and we also must have not null-moved before
        # (that's what board.canNullMove() is checking) and the static 
        # evaluation of the position needs to already be better than or 
        # equal to beta
        let
            friendlyPawns = self.board.positions[^1].getBitboard(Pawn, sideToMove)
            friendlyKing = self.board.positions[^1].getBitboard(King, sideToMove)
            friendlyPieces = self.board.positions[^1].getOccupancyFor(sideToMove)
        if (friendlyPieces and not (friendlyKing or friendlyPawns)) != 0:
            # NMP is disabled in endgame positions where only kings
            # and (friendly) pawns are left because those are the ones
            # where it is most likely that the null move assumption will
            # not hold true due to zugzwang (fancy engines do zugzwang
            # verification, but I literally cba to do that)
            # TODO: Look into verification search
            self.board.makeNullMove()
            # We perform a shallower search because otherwise there would be no point in
            # doing NMP at all!
            let reduction = self.parameters.nmpBaseReduction + depth div self.parameters.nmpDepthReduction
            let score = -self.search(depth - reduction, ply + 1, -beta - 1, -beta, isPV=false)
            self.board.unmakeMove()
            if score >= beta:
                return score
    when defined(razoring):
        if not isPV and depth <= RAZORING_DEPTH_LIMIT and not self.board.inCheck() and staticEval + RAZORING_EVAL_THRESHOLD * depth <= alpha:
            # Razoring: if we're in a non-pv node and not in check, and the static
            # evaluation of the position is significantly below alpha (or doesn't
            # beat it), we perform a quiescent search: if that still doesn't beat
            # alpha, we prune the branch. We only do this at shallow depths and 
            # increase the threshold the deeper we go, as this optimization is
            # unsound. We can do a null-window search to save time time as well (
            # this is handled implicitly by the fact that all non pv-nodes are
            # searched with a null window, so we don't actually need to modify
            # alpha and beta)

            # We're looking to evaluate our own position, so there's no minus sign here
            let score = self.qsearch(ply, alpha, beta)
            if score <= alpha:
                return score

    var 
        bestMove = hashMove
        bestScore = lowestEval()
        # playedMoves counts how many moves we called makeMove() on, while i counts how
        # many moves were yielded by the move picker
        playedMoves = 0
        i = 0
        alpha = alpha
        # Quiets that failed low
        failedQuiets = newMoveList()
    for move in self.pickMoves(hashMove, ply):
        if ply == 0 and self.searchMoves.len() > 0 and move notin self.searchMoves:
            inc(i)
            continue
        # Ensures we don't prune moves that stave off checkmate
        let isNotMated = bestScore > -mateScore() + MAX_DEPTH
        if not isPV and move.isQuiet() and depth <= self.parameters.fpDepthLimit and staticEval + self.parameters.fpEvalMargin * (depth + improving.int) < alpha and isNotMated:
            # Futility pruning: If a (quiet) move cannot meaningfully improve alpha, prune it from the
            # tree. Much like RFP, this is an unsound optimization (and a riskier one at that,
            # apparently), so our depth limit and evaluation margins are very conservative
            # compared to RFP. Also, we need to make sure the best score is not a mate score, or
            # we'd risk pruning moves that evade checkmate
            inc(i)
            continue
        if ply > 0 and move.isQuiet() and isNotMated and playedMoves >= (self.parameters.lmpDepthOffset + self.parameters.lmpDepthMultiplier * depth * depth) div (2 - improving.int):
            # Late move pruning: prune moves when we've played enough of them. Since the optimization
            # is unsound, we want to make sure we don't accidentally miss a move that staves off
            # checkmate
            inc(i)
            continue
        if ply > 0 and isNotMated and depth <= self.parameters.seePruningMaxDepth and move.isQuiet():
            # SEE pruning: prune moves with a bad SEE score
            let seeScore = self.board.positions[^1].see(move)
            let margin = -depth * self.parameters.seePruningQuietMargin
            if seeScore < margin:
                inc(i)
                continue
        self.previousMove = move
        self.previousPiece = self.board.positions[^1].getPiece(self.previousMove.startSquare)
        self.board.doMove(move)
        let reduction = self.getReduction(move, depth, ply, i, isPV, improving)
        inc(self.nodeCount)
        # Find the best move for us (worst move
        # for our opponent, hence the negative sign)
        var score: Score
        # Implementation of Principal Variation Search (PVS)
        if i == 0:
            # Due to our move ordering scheme, the first move is always the "best", so
            # search it always at full depth with the full search window
            score = -self.search(depth - 1, ply + 1, -beta, -alpha, isPV)
        elif reduction > 0:
            # Late Move Reductions: assume our move orderer did a good job,
            # so it is not worth it to look at all moves at the same depth equally.
            # If this move turns out to be better than we expected, we'll re-search
            # it at full depth

            # We first do a null-window search to see if there's a move that beats alpha
            # (we don't care about the actual value, so we search in the range [alpha, alpha + 1]
            # to increase the number of cutoffs)
            score = -self.search(depth - 1 - reduction, ply + 1, -alpha - 1, -alpha, isPV=false)
            # If the null window reduced search beats alpha, we redo the search with the same alpha
            # beta bounds, but without the reduction to get a better feel for the actual score of the position.
            # If the score turns out to beat alpha (but not beta) again, we'll re-search this with a full
            # window later
            if score > alpha:
                score = -self.search(depth - 1, ply + 1, -alpha - 1, -alpha, isPV=false)
        else:
            # Move wasn't reduced, just do a null window search
            score = -self.search(depth - 1, ply + 1, -alpha - 1, -alpha, isPV=false)
        if i > 0 and score > alpha and score < beta:
            # The position beat alpha (and not beta, which would mean it was too good for us and
            # our opponent wouldn't let us play it) in the null window search, search it
            # again with the full depth and full window. Note to future self: alpha and beta
            # are integers, so in a non-pv node it's never possible that this condition is triggered
            # since there's no value between alpha and beta (which is alpha + 1)
            score = -self.search(depth - 1, ply + 1, -beta, -alpha, isPV)
        inc(i)
        inc(playedMoves)
        self.board.unmakeMove()
        # When a search is cancelled or times out, we need
        # to make sure the entire call stack unwinds back
        # to the root move. This is why the check is duplicated
        if depth > 1 and self.shouldStop():
            return
        bestScore = max(score, bestScore)
        if score >= beta:
            # This move was too good for us, opponent will not search it
            if not (move.isCapture() or move.isEnPassant()):
                # Countermove heuristic: we assume that most moves have a natural
                # response irrespective of the actual position and store them in a
                # table indexed by the from/to squares of the previous move
                self.counters[self.previousMove.startSquare][self.previousMove.targetSquare] = move
            
            if move.isQuiet():
                # If the best move we found is a tactical move, we don't want to punish quiets
                # because they still might be good (just not as good wrt the best move)
                if not bestMove.isTactical():
                    # Give a bonus to the quiet move that failed high so that we find it faster later
                    self.storeHistoryScore(sideToMove, move, depth, true)
                    # Punish quiet moves coming before this one such that they are placed later in the
                    # list in subsequent searches and we manage to cut off faster
                    for quiet in failedQuiets:
                        self.storeHistoryScore(sideToMove, quiet, depth, false)
                # Killer move heuristic: store quiets that caused a beta cutoff according to the distance from
                # root that they occurred at, as they might be good refutations for future moves from the opponent.
                # Elo gains: 33.5 +/- 19.3
                self.storeKillerMove(ply, move)
            break
        if score > alpha:
            alpha = score
            bestMove = move
            if ply == 0:
                self.bestRootScore = score
            if isPV:
                # This loop is why pvMoves has one extra move.
                # We can just do ply + 1 and i + 1 without ever
                # fearing about buffer overflows
                for i, pv in self.pvMoves[ply + 1]:
                    if pv == nullMove():
                        self.pvMoves[ply][i + 1] = nullMove()
                        break
                    self.pvMoves[ply][i + 1] = pv
                self.pvMoves[ply][0] = move
        elif move.isQuiet():
            failedQuiets.add(move)
    if i == 0:
        # No moves were yielded by the move picker: no legal moves
        # available!
        if self.board.inCheck():
            # Checkmate! We do this subtraction
            # to give priority to shorter mates
            # (or to stave off mate as long as
            # possible if we're being mated)
            return Score(ply) - mateScore()
        # Stalemate
        return Score(0)
    # Store the best move in the transposition table so we can find it later
    let nodeType = if bestScore >= beta: LowerBound elif bestScore <= originalAlpha: UpperBound else: Exact
    var ttScore = bestScore
    # We do this because we want to make sure that when we get a TT cutoff and it's
    # a mate score, we pick the shortest possible mate line if we're mating and the
    # longest possible one if we're being mated. We revert this when probing the TT
    if abs(ttScore) >= mateScore() - MAX_DEPTH:
        ttScore += Score(ttScore.int.sgn()) * Score(ply)
    self.transpositionTable[].store(depth.uint8, ttScore, self.board.positions[^1].zobristKey, bestMove, nodeType, staticEval.int16)

    return bestScore


proc findBestLine(self: SearchManager, timeRemaining, increment: int64, maxDepth: int, maxNodes: uint64, searchMoves: seq[Move],
                   timePerMove=false, ponder=false, silent=false): array[256, Move] =
    ## Internal, single-threaded search for the principal variation
    
    # Apparently negative remaining time is a thing. Welp
    self.maxSearchTime = if not timePerMove: max(1, (timeRemaining div 10) + ((increment div 3) * 2)) else: timeRemaining
    let softLimit = if not timePerMove: self.maxSearchTime div 3 else: self.maxSearchTime
    self.pondering.store(ponder)
    self.maxNodes = maxNodes
    self.searchMoves = searchMoves
    self.searchStart = getMonoTime()
    self.hardLimit = self.searchStart + initDuration(milliseconds=self.maxSearchTime)
    self.softLimit = self.searchStart + initDuration(milliseconds=softLimit)
    self.nodeCount = 0
    self.selectiveDepth = 0
    self.highestDepth = 0
    for i in 0..MAX_DEPTH:
        result[i] = nullMove()
    var maxDepth = maxDepth
    if maxDepth == -1:
        maxDepth = 60
    # Iterative deepening loop
    self.stop.store(false)
    self.searching.store(true)
    var score = Score(0)
    for depth in 1..min(MAX_DEPTH, maxDepth):
        if depth < self.parameters.aspWindowDepthThreshold:
            score = self.search(depth, 0, lowestEval(), highestEval(), true)
        else:
            # Aspiration windows: start subsequent searches with tighter
            # alpha-beta bounds and widen them as needed (i.e. when the score
            # goes beyond the window) to increase the number of cutoffs
            var delta = Score(self.parameters.aspWindowInitialSize)
            var alpha = max(lowestEval(), score - delta)
            var beta = min(highestEval(), score + delta)
            var searchDepth {.used.} = depth
            while true:
                score = self.search(depth, 0, alpha, beta, true)
                # Score is outside window bounds, widen the one that
                # we got past to get a better result
                if score <= alpha:
                    alpha = max(lowestEval(), score - delta)
                elif score >= beta:
                    beta = min(highestEval(), score + delta)
                else:
                    # Value was within the alpha-beta bounds, we're done
                    break
                # Try again with larger window
                delta += delta
                if delta >= Score(self.parameters.aspWindowMaxSize):
                    # Window got too wide, give up and search with the full range
                    # of alpha-beta values
                    delta = highestEval()
        if self.pvMoves[0][0] != nullMove():
            result = self.pvMoves[0]
        if self.shouldStop():
            if not silent:
                # Ensure the final PV is logged even if
                # it has been cleared by the search
                self.pvMoves[0] = result
                self.log(depth - 1)
            break
        if not silent:
            self.log(depth)
        self.highestDepth = depth
        # Soft time management: don't start a new search iteration
        # if the soft limit has expired, as it is unlikely to complete
        # anyway
        if getMonoTime() >= self.softLimit and not self.isPondering():
            break
    self.searching.store(false)
    self.stop.store(false)
    self.pondering.store(false)


proc workerFunc(args: tuple[self: SearchManager, timeRemaining, increment: int64, maxDepth: int, maxNodes: uint64, searchMoves: seq[Move],
                  timePerMove, ponder, silent: bool]) {.thread.} =
    ## Worker that calls findBestLine in a new thread
    # Gotta lie to nim's thread analyzer lest it shout at us that we're not
    # GC safe!
    {.cast(gcsafe).}:
        discard args.self.findBestLine(args.timeRemaining, args.increment, args.maxDepth, args.maxNodes, args.searchMoves, args.timePerMove, args.ponder)

# Creating thread objects can be expensive, so there's no need to make new ones for every call
# to our parallel search. Also, nim leaks thread vars: this keeps the resource leaks
# to a minimum
var workers: seq[ref Thread[tuple[self: SearchManager, timeRemaining, increment: int64, maxDepth: int, maxNodes: uint64, searchMoves: seq[Move],
                  timePerMove, ponder, silent: bool]]] = @[]


proc search*(self: SearchManager, timeRemaining, increment: int64, maxDepth: int, maxNodes: uint64, searchMoves: seq[Move],
             timePerMove=false, ponder=false, silent=false, numWorkers=1): seq[Move] =
    ## Finds the principal variation in the current position
    ## and returns it, limiting search time according the
    ## the remaining time and increment values provided (in
    ## milliseconds) and only up to maxDepth ply (if maxDepth 
    ## is -1, a reasonable limit is picked). If maxNodes is supplied
    ## and is nonzero, search will stop once it has analyzed maxNodes
    ## nodes. If searchMoves is provided and is not empty, search will
    ## be restricted to the moves in the list. Note that regardless of
    ## any time limitations or explicit cancellations, the search will
    ## not stop until it has cleared at least depth one. Search depth
    ## is always constrained to at most MAX_DEPTH ply from the root. If
    ## timePerMove is true, the increment is assumed to be zero and the
    ## remaining time is considered the time limit for the entire search
    ## (note that soft time management is disabled in that case). If ponder
    ## is true, the search is performed in pondering mode (i.e. no explicit
    ## time limit) and can be switched to a regular search by calling the
    ## stopPondering() procedure. If numWorkers is > 1, the search is performed
    ## in parallel using numWorkers threads. If silent equals true, no logs are
    ## printed to the console during search
    while workers.len() + 1 < numWorkers:
        # We create n - 1 workers because we'll also be searching
        # ourselves
        workers.add(new Thread[tuple[self: SearchManager, timeRemaining, increment: int64, maxDepth: int, maxNodes: uint64, searchMoves: seq[Move],
                  timePerMove, ponder, silent: bool]])
    for i in 0..<numWorkers - 1:
        # The only shared state is the TT, everything else is thread-local
        var
            history = create(HistoryTable)
            killers = create(KillersTable)
            counters = create(CountersTable)
        # Copy in the data
        for color in PieceColor.White..PieceColor.Black:
            for i in Square(0)..Square(63):
                for j in Square(0)..Square(63):
                    history[color][i][j] = self.history[color][i][j]
        for i in 0..<MAX_DEPTH:
            for j in 0..<NUM_KILLERS:
                killers[i][j] = self.killers[i][j]
        for fromSq in Square(0)..Square(63):
            for toSq in Square(0)..Square(63):
                counters[fromSq][toSq] = self.counters[fromSq][toSq]
        # Create a new search manager to send off to a worker thread
        self.children.add(newSearchManager(self.board.positions, self.transpositionTable, history, killers, counters, self.parameters, false))
        # Off you go, you little search minion!
        createThread(workers[i][], workerFunc, (self.children[i], timeRemaining, increment, maxDepth, maxNodes div numWorkers.uint64, searchMoves, timePerMove, ponder, silent))
        # Pin thread to one CPU core to remove task switching overheads
        # introduced by the scheduler
        when not defined(windows):
            # The C-level Windows implementation of this using SetThreadAffinity is
            # incorrect, so don't use it
            pinToCpu(workers[i][], i)
    # We divide maxNodes by the number of workers so that even when searching in parallel, no more than maxNodes nodes
    # are searched
    var pv = self.findBestLine(timeRemaining, increment, maxDepth, maxNodes div numWorkers.uint64, searchMoves, timePerMove, ponder, silent)
    # Wait for all search threads to finish. This isn't technically
    # necessary, but it's good practice and will catch bugs in our
    # "atomic stop" system
    for i in 0..<numWorkers - 1:
        joinThread(workers[i][])
    for move in pv:
        if move == nullMove():
            break
        result.add(move)
    # Ensure local searchers get destroyed
    for child in self.children:
        child.`destroy=`()
    self.children.setLen(0)
