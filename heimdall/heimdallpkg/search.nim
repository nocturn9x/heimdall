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

import heimdallpkg/see
import heimdallpkg/eval
import heimdallpkg/board
import heimdallpkg/util/limits
import heimdallpkg/movegen
import heimdallpkg/util/tunables
import heimdallpkg/util/shared
import heimdallpkg/util/aligned
import heimdallpkg/transpositions


import std/math
import std/times
import std/options
import std/atomics
import std/strutils
import std/monotimes
import std/strformat
import std/terminal
import std/heapqueue

# Miscellaneous parameters that are not meant to be tuned
const

    NUM_KILLERS* = 2
    MAX_DEPTH* = 255
    # Constants used during move ordering

    MVV_MULTIPLIER = 10
    # These offsets are used in the move
    # ordering step to ensure moves from
    # different heuristics don't have
    # overlapping scores. Heuristics with
    # higher offsets will always be placed
    # first
    TTMOVE_OFFSET = 700_000
    GOOD_CAPTURE_OFFSET = 600_000
    KILLERS_OFFSET = 500_000
    COUNTER_OFFSET = 400_000
    QUIET_OFFSET = 200_000
    BAD_CAPTURE_OFFSET = 50_000

    # Max value for scores in our
    # history tables
    HISTORY_SCORE_CAP = 16384


func computeLMRTable: array[MAX_DEPTH, array[MAX_MOVES, int]] {.compileTime.} =
    ## Precomputes the table containing reduction offsets at compile
    ## time
    for i in 1..result.high():
        for j in 1..result[0].high():
            result[i][j] = round(0.8 + ln(i.float) * ln(j.float) * 0.4).int


const LMR_TABLE = computeLMRTable()


type
    ThreatHistoryTable* = array[White..Black, array[Square(0)..Square(63), array[Square(0)..Square(63), array[bool, array[bool, Score]]]]]
    CaptHistTable* = array[White..Black, array[Square(0)..Square(63), array[Square(0)..Square(63), array[Pawn..Queen, Score]]]]
    CountersTable* = array[Square(0)..Square(63), array[Square(0)..Square(63), Move]]
    KillersTable* = array[MAX_DEPTH, array[NUM_KILLERS, Move]]
    ContinuationHistory* = array[White..Black, array[PieceKind.Pawn..PieceKind.King,
                           array[Square(0)..Square(63), array[White..Black, array[PieceKind.Pawn..PieceKind.King,
                           array[Square(0)..Square(63), int16]]]]]]


    SearchManager* = ref object
        # Search state
        state*: SearchState
        # Search statistics
        statistics*: SearchStatistics
        # Constrains the search according to
        # configured limits
        limiter*: SearchLimiter
        # The set of parameters used by the
        # search
        parameters: SearchParameters
        # We keep track of all the worker
        # threads' respective search states
        # to collect statistics efficiently
        children: seq[SearchManager]
        # Chessboard where we play moves
        board: Chessboard
        # Only search these root moves
        searchMoves: seq[Move]
        # Transposition table
        transpositionTable: ptr TTable
        # Heuristic tables
        quietHistory: ptr ThreatHistoryTable
        captureHistory: ptr CaptHistTable
        killers: ptr KillersTable
        counters: ptr CountersTable
        continuationHistory: ptr ContinuationHistory


proc setBoardState*(self: SearchManager, state: seq[Position]) =
    ## Sets the board state for the search
    self.board.positions = state
    self.state.evalState.init(self.board)


proc setNetwork*(self: SearchManager, path: string) =
    ## Loads the network at the given path into the
    ## search manager
    self.state.evalState = newEvalState(path)
    self.state.evalState.init(self.board)


proc setUCIMode*(self: SearchManager, value: bool) =
    self.state.uciMode.store(value)


proc newSearchManager*(positions: seq[Position], transpositions: ptr TTable,
                       quietHistory: ptr ThreatHistoryTable, captureHistory: ptr CaptHistTable,
                       killers: ptr KillersTable, counters: ptr CountersTable,
                       continuationHistory: ptr ContinuationHistory,
                       parameters=getDefaultParameters(), mainWorker=true, chess960=false,
                       evalState=newEvalState(), limiter: SearchLimiter = nil, state=newSearchState(),
                       statistics=newSearchStatistics()): SearchManager =
    ## Initializes a new search manager
    new(result)
    result = SearchManager(transpositionTable: transpositions, quietHistory: quietHistory,
                           captureHistory: captureHistory, killers: killers, counters: counters,
                           continuationHistory: continuationHistory, parameters: parameters,
                           limiter: limiter, state: state, statistics: statistics)
    if result.limiter.isNil():
        result.limiter = newSearchLimiter(result.state, result.statistics)
    new(result.board)
    result.state.evalState = evalState
    result.state.chess960.store(chess960)
    result.state.isMainThread.store(mainWorker)
    result.setBoardState(positions)


proc `destroy=`*(self: SearchManager) =
    ## Ensures our manually allocated objects
    ## are deallocated correctly upon destruction
    if not self.state.isMainThread.load():
        # This state is thread-local and is fine to
        # destroy *unless* we're the main worker. This
        # is because the main worker copies these to other
        # threads when the search begins, and they are passed
        # in from somewhere else, meaning that the main worker
        # technically doesn't own them
        freeHeapAligned(self.killers)
        freeHeapAligned(self.quietHistory)
        freeHeapAligned(self.captureHistory)
        freeHeapAligned(self.continuationHistory)
        freeHeapAligned(self.counters)


func isSearching*(self: SearchManager): bool {.inline.} =
    ## Returns whether a search for the best
    ## move is in progress
    result = self.state.searching.load()


func stop*(self: SearchManager) {.inline.} =
    ## Stops the search if it is
    ## running
    self.state.stop.store(true)
    # Stop all worker threads
    for child in self.children:
        stop(child)


func isKillerMove(self: SearchManager, move: Move, ply: int): bool {.inline.} =
    ## Returns whether the given move is a killer move
    for killer in self.killers[ply]:
        if killer == move:
            return true


proc getHistoryScore(self: SearchManager, sideToMove: PieceColor, move: Move): Score {.inline.} =
    ## Returns the score for the given move and side to move
    ## in our history tables
    assert move.isCapture() or move.isQuiet()
    if move.isQuiet():
        let startAttacked = self.board.positions[^1].threats.contains(move.startSquare)
        let targetAttacked = self.board.positions[^1].threats.contains(move.targetSquare)

        result = self.quietHistory[sideToMove][move.startSquare][move.targetSquare][startAttacked][targetAttacked]
    else:
        let victim = self.board.getPiece(move.targetSquare).kind
        result = self.captureHistory[sideToMove][move.startSquare][move.targetSquare][victim]


func getOnePlyContHistScore(self: SearchManager, sideToMove: PieceColor, piece: Piece, target: Square, ply: int): int16 {.inline.} =
    ## Returns the score stored in the continuation history 1
    ## ply ago, with the given piece and target square. The ply
    ## argument is intended as the current distance from root,
    ## NOT the previous ply
    if ply > 0:
        var prevPiece = self.state.movedPieces[ply - 1]
        result += self.continuationHistory[sideToMove][piece.kind][target][prevPiece.color][prevPiece.kind][self.state.moves[ply - 1].targetSquare]


func getTwoPlyContHistScore(self: SearchManager, sideToMove: PieceColor, piece: Piece, target: Square, ply: int): int16 {.inline.} =
    ## Returns the score stored in the continuation history 2
    ## plies ago, with the given piece and target square. The ply
    ## argument is intended as the current distance from root,
    ## NOT the previous ply
    if ply > 1:
        var prevPiece = self.state.movedPieces[ply - 2]
        result += self.continuationHistory[sideToMove][piece.kind][target][prevPiece.color][prevPiece.kind][self.state.moves[ply - 2].targetSquare]


proc updateHistories(self: SearchManager, sideToMove: PieceColor, move: Move, piece: Piece, depth, ply: int, good: bool) {.inline.} =
    ## Updates internal histories with the given move
    ## which failed, at the given depth and ply from root,
    ## either high or low depending on whether good
    ## is true or false
    assert move.isCapture() or move.isQuiet()
    var bonus: int
    if move.isQuiet():
        bonus = (if good: self.parameters.goodQuietBonus else: -self.parameters.badQuietMalus) * depth
        if ply > 0 and not self.board.positions[^2].fromNull:
            let prevPiece = self.state.movedPieces[ply - 1]
            self.continuationHistory[sideToMove][piece.kind][move.targetSquare][prevPiece.color][prevPiece.kind][self.state.moves[ply - 1].targetSquare] += (bonus - abs(bonus) * self.getOnePlyContHistScore(sideToMove, piece, move.targetSquare, ply) div HISTORY_SCORE_CAP).int16
        if ply > 1 and not self.board.positions[^3].fromNull:
          let prevPiece = self.state.movedPieces[ply - 2]
          self.continuationHistory[sideToMove][piece.kind][move.targetSquare][prevPiece.color][prevPiece.kind][self.state.moves[ply - 2].targetSquare] += (bonus - abs(bonus) * self.getTwoPlyContHistScore(sideToMove, piece, move.targetSquare, ply) div HISTORY_SCORE_CAP).int16

        let startAttacked = self.board.positions[^1].threats.contains(move.startSquare)
        let targetAttacked = self.board.positions[^1].threats.contains(move.targetSquare)
        self.quietHistory[sideToMove][move.startSquare][move.targetSquare][startAttacked][targetAttacked] += Score(bonus) - abs(bonus.int32) * self.getHistoryScore(sideToMove, move) div HISTORY_SCORE_CAP

    elif move.isCapture():
        bonus = (if good: self.parameters.goodCaptureBonus else: -self.parameters.badCaptureMalus) * depth
        let victim = self.board.getPiece(move.targetSquare).kind
        # We use this formula to evenly spread the improvement the more we increase it (or decrease it)
        # while keeping it constrained to a maximum (or minimum) value so it doesn't (over|under)flow.
        self.captureHistory[sideToMove][move.startSquare][move.targetSquare][victim] += Score(bonus) - abs(bonus.int32) * self.getHistoryScore(sideToMove, move) div HISTORY_SCORE_CAP



proc getEstimatedMoveScore(self: SearchManager, hashMove: Move, move: Move, ply: int): int {.inline.} =
    ## Returns an estimated static score for the move used
    ## during move ordering
    if move == hashMove:
        # The TT move always goes first
        return TTMOVE_OFFSET

    if ply > 0 and self.isKillerMove(move, ply):
        # Killer moves come second
        return KILLERS_OFFSET

    if ply > 0 and move == self.counters[self.state.moves[ply - 1].startSquare][self.state.moves[ply - 1].targetSquare]:
        # Counter moves come third
        return COUNTER_OFFSET

    let sideToMove = self.board.sideToMove

    # Good/bad tacticals
    if move.isTactical():
        let seeScore = self.board.positions[^1].see(move)
        # Prioritize good exchanges (see > 0)
        result += seeScore
        if move.isCapture():
            # Add capthist score
            result += self.getHistoryScore(sideToMove, move)
        if seeScore < 0:
            if move.isCapture():   # TODO: En passant!
                # Prioritize attacking our opponent's
                # most valuable pieces
                result += MVV_MULTIPLIER * self.board.getPiece(move.targetSquare).getStaticPieceScore()

            return BAD_CAPTURE_OFFSET + result
        else:
            return GOOD_CAPTURE_OFFSET + result

    if move.isQuiet():
        let piece = self.board.getPiece(move.startSquare)
        # Quiet history and conthist
        result = QUIET_OFFSET + self.getHistoryScore(sideToMove, move)
        if ply > 0:
            result += self.getOnePlyContHistScore(sideToMove, piece, move.targetSquare, ply)
        if ply > 1:
            result += self.getTwoPlyContHistScore(sideToMove, piece, move.targetSquare, ply)


iterator pickMoves(self: SearchManager, hashMove: Move, ply: int, qsearch: bool = false): Move =
    ## Abstracts movegen away from search by picking moves using
    ## our move orderer
    var moves {.noinit.} = newMoveList()
    self.board.generateMoves(moves, capturesOnly=qsearch)
    var scores {.noinit.}: array[MAX_MOVES, int]
    # Precalculate the move scores
    for i in 0..moves.high():
        scores[i] = self.getEstimatedMoveScore(hashMove, moves[i], ply)
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


func isPondering*(self: SearchManager): bool {.inline.} = self.state.pondering.load()
func cancelled(self: SearchManager): bool {.inline.} = self.state.stop.load()
proc elapsedTime(self: SearchManager): int64 {.inline.} = (getMonoTime() - self.state.searchStart.load()).inMilliseconds()


proc stopPondering*(self: SearchManager) {.inline.} =
    ## Stop pondering and switch to regular search.
    self.state.pondering.store(false)
    self.state.stoppedPondering.store(getMonoTime())
    # Propagate the stop of pondering search to children
    for child in self.children:
        child.stopPondering()


func nodes*(self: SearchManager): uint64 {.inline.} =
    ## Returns the total number of nodes that
    ## have been analyzed by all threads
    result = self.statistics.nodeCount.load()
    for child in self.children:
        result += child.statistics.nodeCount.load()


proc logPretty(self: SearchManager, depth, variation: int, line: array[256, Move], bestRootScore: Score) =
    # Thanks to @tsoj for the patch!
    if not self.state.isMainThread.load():
        # We restrict logging to the main worker to reduce
        # noise and simplify things
        return
    # Using an atomic for such frequently updated counters kills
    # performance and cripples nps scaling, so instead we let each
    # thread have its own local counters and then aggregate the results
    # here
    var
        nodeCount = self.statistics.nodeCount.load()
        selDepth = self.statistics.selectiveDepth.load()
    for child in self.children:
        nodeCount += child.statistics.nodeCount.load()
        selDepth = max(selDepth, child.statistics.selectiveDepth.load())
    let
        elapsedMsec = self.elapsedTime()
        nps = 1000 * (nodeCount div max(elapsedMsec, 1).uint64)
    let chess960 = self.state.chess960.load()

    let kiloNps = nps div 1_000
    let multipv = variation

    stdout.styledWrite styleBright, fmt"{depth:>3}/{selDepth:<3} "
    stdout.styledWrite styleDim, fmt"{elapsedMsec:>6} ms "
    stdout.styledWrite styleDim, styleBright, fmt"{nodeCount:>10}"
    stdout.styledWrite styleDim, " nodes "
    stdout.styledWrite styleDim, styleBright, fmt"{kiloNps:>7}"
    stdout.styledWrite styleDim, " knps "
    stdout.styledWrite styleDim, fmt"  TT: {self.transpositionTable[].getFillEstimate() div 10:>3}%"


    stdout.styledWrite styleDim, "   multipv "
    stdout.styledWrite styleDim, styleBright, fmt"{multipv} "

    let
        color =
            if bestRootScore.abs <= 10:
                fgDefault
            elif bestRootScore > 0:
                fgGreen
            else:
                fgRed
        style: set[Style] =
            if bestRootScore.abs >= 100:
                {styleBright}
            elif bestRootScore.abs <= 20:
                {styleDim}
            else:
                {}

    if abs(bestRootScore) >= mateScore() - MAX_DEPTH:
      let
        extra = if bestRootScore > 0: ":D" else: ":("
        mateScore = if bestRootScore > 0: (mateScore() - bestRootScore + 1) div 2 else: (mateScore() + bestRootScore) div 2
      stdout.styledWrite styleBright,
          color, fmt"  #{mateScore} ", resetStyle, color, styleDim, extra, " "
    else:
        let scoreString = (if bestRootScore > 0: "+" else: "") & fmt"{bestRootScore.float / 100.0:.2f}"
        stdout.styledWrite style, color, fmt"{scoreString:>7} "


    const moveColors = [fgBlue, fgCyan, fgGreen, fgYellow, fgRed, fgMagenta, fgRed, fgYellow, fgGreen, fgCyan]

    for i, move in line:

        if move == nullMove():
            break

        var move = move
        if move.isCastling() and not chess960:
            # Hide the fact we're using FRC internally
            if move.targetSquare < move.startSquare:
                move.targetSquare = makeSquare(rankFromSquare(move.targetSquare), fileFromSquare(move.targetSquare) + 2)
            else:
                move.targetSquare = makeSquare(rankFromSquare(move.targetSquare), fileFromSquare(move.targetSquare) - 1)

        if i == 0:
            stdout.styledWrite " ", moveColors[i mod moveColors.len], styleBright, styleItalic, move.toAlgebraic()
        else:
            stdout.styledWrite " ", moveColors[i mod moveColors.len], move.toAlgebraic()

    echo ""


proc logUCI(self: SearchManager, depth: int, variation: int, line: array[256, Move], bestRootScore: Score) =
    if not self.state.isMainThread.load():
        # We restrict logging to the main worker to reduce
        # noise and simplify things
        return
    # Using a shared atomic for such frequently updated counters kills
    # performance and cripples nps scaling, so instead we let each thread
    # have its own local counters and then aggregate the results here
    var
        nodeCount = self.statistics.nodeCount.load()
        selDepth = self.statistics.selectiveDepth.load()
    for child in self.children:
        nodeCount += child.statistics.nodeCount.load()
        selDepth = max(selDepth, child.statistics.selectiveDepth.load())
    let
        elapsedMsec = self.elapsedTime()
        nps = 1000 * (nodeCount div max(elapsedMsec, 1).uint64)
    var logMsg = &"info depth {depth} seldepth {selDepth} multipv {variation}"
    if abs(bestRootScore) >= mateScore() - MAX_DEPTH:
        if bestRootScore > 0:
            logMsg &= &" score mate {((mateScore() - bestRootScore + 1) div 2)}"
        else:
            logMsg &= &" score mate {(-(mateScore() + bestRootScore) div 2)}"
    else:
        logMsg &= &" score cp {bestRootScore}"
    logMsg &= &" hashfull {self.transpositionTable[].getFillEstimate()} time {elapsedMsec} nodes {nodeCount} nps {nps}"
    let chess960 = self.state.chess960.load()
    if line[0] != nullMove():
        logMsg &= " pv "
        for move in line:
            if move == nullMove():
                break
            if move.isCastling() and not chess960:
                # Hide the fact we're using FRC internally
                var move = move
                if move.targetSquare < move.startSquare:
                    move.targetSquare = makeSquare(rankFromSquare(move.targetSquare), fileFromSquare(move.targetSquare) + 2)
                else:
                    move.targetSquare = makeSquare(rankFromSquare(move.targetSquare), fileFromSquare(move.targetSquare) - 1)
                logMsg &= &"{move.toAlgebraic()} "
            else:
                logMsg &= &"{move.toAlgebraic()} "
    if logMsg.endsWith(" "):
        # Remove extra space at the end of the pv
        logMsg = logMsg[0..^2]
    echo logMsg


proc log(self: SearchManager, depth, variation: int, line: array[256, Move], bestRootScore: Score) =
    if self.state.uciMode.load():
        self.logUCI(depth, variation, line, bestRootScore)
    else:
        self.logPretty(depth, variation, line, bestRootScore)


proc shouldStop*(self: SearchManager, inTree=true): bool {.inline.} =
    ## Returns whether searching should
    ## stop
    if self.cancelled():
        # Search has been cancelled!
        return true
    # Only the main thread does time management
    if not self.state.isMainThread.load():
        return
    if self.state.expired.load():
        # Search limit has expired before
        return true
    result = self.limiter.expired(inTree)
    self.state.expired.store(result)

proc getReduction(self: SearchManager, move: Move, depth, ply, moveNumber: int, isPV: static bool, improving, cutNode: bool): int {.inline.} =
    ## Returns the amount a search depth should be reduced to
    let moveCount = when isPV: self.parameters.lmrMoveNumber.pv else: self.parameters.lmrMoveNumber.nonpv
    if moveNumber > moveCount and depth >= self.parameters.lmrMinDepth:
        result = LMR_TABLE[depth][moveNumber]
        when isPV:
            # Reduce PV nodes less
            # Gains: 37.8 +/- 20.7
            dec(result)

        if cutNode:
            inc(result, 2)

        if self.board.inCheck():
            # Reduce less when opponent is in check
            dec(result)

        # History LMR
        if move.isQuiet() or move.isCapture():
            let stm = self.board.sideToMove
            let piece = self.board.getPiece(move.startSquare)
            var score: int = self.getHistoryScore(stm, move)
            if move.isQuiet():
                score += self.getOnePlyContHistScore(stm, piece, move.targetSquare, ply) + self.getTwoPlyContHistScore(stm, piece, move.targetSquare, ply)
            dec(result, score div self.parameters.historyLmrDivisor)

        # Keep the reduction in the right range
        result = result.clamp(0, depth - 1)


proc staticEval(self: SearchManager): Score =
    ## Runs the static evaluation on the current
    ## position and applies corrections to the result
    result = self.board.evaluate(self.state.evalState)
    # Material scaling. Yoinked from Stormphrax (see https://github.com/Ciekce/Stormphrax/compare/c4f4a8a6..6cc28cde)
    let
        knights = self.board.getBitboard(Knight, White) or self.board.getBitboard(Knight, Black)
        bishops = self.board.getBitboard(Bishop, White) or self.board.getBitboard(Bishop, Black)
        pawns = self.board.getBitboard(Pawn, White) or self.board.getBitboard(Pawn, Black)
        rooks = self.board.getBitboard(Rook, White) or self.board.getBitboard(Rook, Black)
        queens = self.board.getBitboard(Queen, White) or self.board.getBitboard(Queen, Black)
    
    let material = Score(Knight.getStaticPieceScore() * knights.countSquares() +
                    Bishop.getStaticPieceScore() * bishops.countSquares() +
                    Pawn.getStaticPieceScore() * pawns.countSquares() +
                    Rook.getStaticPieceScore() * rooks.countSquares() +
                    Queen.getStaticPieceScore() * queens.countSquares())

    # This scales the eval linearly between base / divisor and (base + max material) / divisor
    result = result * (material + Score(self.parameters.materialScalingOffset)) div Score(self.parameters.materialScalingDivisor)


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
    self.statistics.selectiveDepth.store(max(self.statistics.selectiveDepth.load(), ply))
    if self.board.isDrawn(ply > 1):
        return Score(0)
    if self.shouldStop():
        return
    # We don't care about the depth of cutoffs in qsearch, anything will do
    # Gains: 23.2 +/- 15.4
    let
        query = self.transpositionTable[].get(self.board.zobristKey)
        ttHit = query.isSome()
        hashMove = if ttHit: query.get().bestMove else: nullMove()
    if ttHit:
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
    let staticEval = if not ttHit: self.staticEval() else: query.get().staticEval
    if staticEval >= beta:
        # Stand-pat evaluation
        return staticEval
    var
        bestScore = staticEval
        alpha = max(alpha, staticEval)
        bestMove = hashMove
    for move in self.pickMoves(hashMove, ply, qsearch=true):
        let seeScore = self.board.position.see(move)
        # Skip bad captures (gains 52.9 +/- 25.2)
        if seeScore < 0:
            continue
        # Qsearch futility pruning: similar to FP in regular search, but we skip moves
        # that gain no material instead of just moves that don't improve alpha
        if not self.board.inCheck() and staticEval + self.parameters.qsearchFpEvalMargin <= alpha and seeScore < 1:
            continue
        let kingSq = self.board.getBitboard(King, self.board.sideToMove).toSquare()
        self.state.moves[ply] = move
        self.state.movedPieces[ply] = self.board.getPiece(move.startSquare)
        self.state.evalState.update(move, self.board.sideToMove, self.state.movedPieces[ply].kind, self.board.getPiece(move.targetSquare).kind, kingSq)
        self.board.doMove(move)
        self.statistics.nodeCount.atomicInc()
        let score = -self.qsearch(ply + 1, -beta, -alpha)
        self.board.unmakeMove()
        self.state.evalState.undo()
        if self.state.expired.load():
            break
        bestScore = max(score, bestScore)
        if score >= beta:
            # This move was too good for us, opponent will not search it
            break
        if score > alpha:
            alpha = score
            bestMove = move
    if self.statistics.currentVariation.load() == 1 and not self.state.expired.load():
        # Store the best move in the transposition table so we can find it later

        # We don't store exact scores because we only look at captures, so they are
        # very much *not* exact!
        let nodeType = if bestScore >= beta: LowerBound else: UpperBound
        var storedScore = bestScore
        # Same mate score logic of regular search
        if abs(storedScore) >= mateScore() - MAX_DEPTH:
            storedScore += Score(storedScore.int.sgn()) * Score(ply)
        self.transpositionTable.store(0, storedScore, self.board.zobristKey, bestMove, nodeType, staticEval.int16)
    return bestScore


proc storeKillerMove(self: SearchManager, ply: int, move: Move) {.inline.} =
    ## Stores a killer move into our killers table at the given
    ## ply

    # Stolen from https://rustic-chess.org/search/ordering/killers.html

    # First killer move must not be the same as the one we're storing
    let first = self.killers[ply][0]
    if first == move:
        return
    var j = self.killers[ply].len() - 2
    while j >= 0:
        # Shift moves one spot down
        self.killers[ply][j + 1] = self.killers[ply][j];
        dec(j)
    self.killers[ply][0] = move


func clearPV(self: SearchManager, ply: int) {.inline.} =
    ## Clears the table used to store the
    ## principal variation at the given
    ## ply
    for i in 0..self.state.pvMoves[ply].high():
        self.state.pvMoves[ply][i] = nullMove()


func clearKillers(self: SearchManager, ply: int) {.inline.} =
    ## Clears the killer moves of the given
    ## ply
    for i in 0..self.killers[ply].high():
        self.killers[ply][i] = nullMove()


proc search(self: SearchManager, depth, ply: int, alpha, beta: Score, isPV: static bool, cutNode: bool, excluded=nullMove()): Score {.discardable.} =
    ## Negamax search with various optimizations and features
    assert alpha < beta
    assert isPV or alpha + 1 == beta

    if (ply > 0 and self.shouldStop()) or depth > MAX_DEPTH:
        # We do not let ourselves get cancelled until we have
        # cleared at least depth 1
        return

    # Clear the PV table for this ply
    self.clearPV(ply)

    # Clearing the next ply's killers makes it so
    # that the killer table is local wrt to its
    # subtree rather than global. This makes the
    # next killer moves more relevant to our children
    # nodes, because they will only come from their
    # siblings. Idea stolen from Simbelmyne, thanks
    # @sroelants!
    if ply < self.killers[].high():
        self.clearKillers(ply + 1)

    let originalAlpha = alpha
    self.statistics.selectiveDepth.store(max(self.statistics.selectiveDepth.load(), ply))
    if self.board.isDrawn(ply > 1):
        return Score(0)
    var depth = depth
    let sideToMove = self.board.sideToMove
    if self.board.inCheck():
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
    let
        isSingularSearch = excluded != nullMove()
        query = self.transpositionTable.get(self.board.zobristKey)
        ttHit = query.isSome()
        ttDepth = if ttHit: query.get().depth.int else: 0
        hashMove = if not ttHit: nullMove() else: query.get().bestMove
        ttScore = if ttHit: query.get().score else: 0
        staticEval = if not ttHit: self.staticEval() else: query.get().staticEval
        expectFailHigh = ttHit and query.get().flag in [LowerBound, Exact]
        root = ply == 0
    self.state.evals[ply] = staticEval
    # If the static eval from this position is greater than that from 2 plies
    # ago (our previous turn), then we are improving our position
    var improving = false
    if ply > 2 and not self.board.inCheck():
        # Uhh somehow the static bool for isPV fucks with the compile
        # time evaluator, so we can't use self.state.evals[ply - 2]
        # directly because its type isn't resolved and remains T, so
        # we help the compiler a lil by telling it that the type of the
        # static eval is indeed Score
        let previousEval: Score = self.state.evals[ply - 2]
        improving = staticEval > previousEval
    # Only cut off in non-pv nodes
    # to avoid random blunders
    when not isPV:
        if ttHit and not isSingularSearch:
            let entry = query.get()
            # We can not trust a TT entry score for cutting off
            # this node if it comes from a shallower search than
            # the one we're currently doing, because it will not
            # have looked at all the possibilities
            if ttDepth >= depth:
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
    if not root and depth >= self.parameters.iirMinDepth and (not ttHit or ttDepth + self.parameters.iirDepthDifference < depth):
        # Internal iterative reductions: if there is no entry in the TT for
        # this node or the one we have comes from a much lower depth than the
        # current one, it's not worth it to search it at full depth, so we
        # reduce it and hope that the next search iteration yields better
        # results
        depth -= 1
    when not isPV:
        if not self.board.inCheck() and depth <= self.parameters.rfpDepthLimit and staticEval - self.parameters.rfpEvalThreshold * depth >= beta:
            # Reverse futility pruning: if the side to move has a significant advantage
            # in the current position and is not in check, return the position's static
            # evaluation to encourage the engine to deal with any potential threats from
            # the opponent. Since this optimization technique is not sound, we limit the
            # depth at which it can trigger for safety purposes (it is also the reason
            # why the "advantage" threshold scales with depth: the deeper we go, the more
            # careful we want to be with our estimate for how much of an advantage we may
            # or may not have)

            # Instead of returning the static eval, we do something known as "fail medium"
            # (or affectionately "fail retard"), which is supposed to be a better guesstimate
            # of the positional advantage
            return (staticEval + beta) div 2
        if depth > self.parameters.nmpDepthThreshold and self.board.canNullMove() and staticEval >= beta:
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
                friendlyPawns = self.board.getBitboard(Pawn, sideToMove)
                friendlyKing = self.board.getBitboard(King, sideToMove)
                friendlyPieces = self.board.getOccupancyFor(sideToMove)
            if (friendlyPieces and not (friendlyKing or friendlyPawns)) != 0:
                # NMP is disabled in endgame positions where only kings
                # and (friendly) pawns are left because those are the ones
                # where it is most likely that the null move assumption will
                # not hold true due to zugzwang (fancy engines do zugzwang
                # verification, but I literally cba to do that)
                # TODO: Look into verification search
                self.statistics.nodeCount.atomicInc()
                self.board.makeNullMove()
                # We perform a shallower search because otherwise there would be no point in
                # doing NMP at all!
                let reduction = self.parameters.nmpBaseReduction + depth div self.parameters.nmpDepthReduction
                let score = -self.search(depth - reduction, ply + 1, -beta - 1, -beta, isPV=false, cutNode=not cutNode)
                self.board.unmakeMove()
                if score >= beta:
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
        failedQuiets {.noinit.} = newMoveList()
        # The pieces that moved for each failed
        # quiet move in the above list
        failedQuietPieces {.noinit.}: array[MAX_MOVES, Piece]
        # Captures that failed low
        failedCaptures {.noinit.} = newMoveList()
    for move in self.pickMoves(hashMove, ply):
        if root and self.searchMoves.len() > 0 and move notin self.searchMoves:
            continue
        if move == excluded:
            # No counters are incremented when we encounter excluded
            # moves because we act as if they don't exist
            continue

        let nodesBefore = self.statistics.nodeCount.load()
        # Ensures we don't prune moves that stave off checkmate
        let isNotMated = bestScore > -mateScore() + MAX_DEPTH
        when not isPV:
            if move.isQuiet() and depth <= self.parameters.fpDepthLimit and
             (staticEval + self.parameters.fpEvalOffset) + self.parameters.fpEvalMargin * (depth + improving.int) <= alpha and isNotMated:
                # Futility pruning: If a (quiet) move cannot meaningfully improve alpha, prune it from the
                # tree. Much like RFP, this is an unsound optimization (and a riskier one at that,
                # apparently), so our depth limit and evaluation margins are very conservative
                # compared to RFP. Also, we need to make sure the best score is not a mate score, or
                # we'd risk pruning moves that evade checkmate
                inc(i)
                continue
        if not root and move.isQuiet() and isNotMated and playedMoves >= (self.parameters.lmpDepthOffset + self.parameters.lmpDepthMultiplier * depth * depth) div (2 - improving.int):
            # Late move pruning: prune moves when we've played enough of them. Since the optimization
            # is unsound, we want to make sure we don't accidentally miss a move that staves off
            # checkmate
            inc(i)
            continue
        if not root and isNotMated and depth <= self.parameters.seePruningMaxDepth and (move.isQuiet() or move.isCapture() or move.isEnPassant()):
            # SEE pruning: prune moves with a bad SEE score
            let seeScore = self.board.positions[^1].see(move)
            let margin = -depth * (if move.isQuiet(): self.parameters.seePruningQuietMargin else: self.parameters.seePruningCaptureMargin)
            if seeScore < margin:
                inc(i)
                continue
        var singular = 0
        if not root and not isSingularSearch and depth > self.parameters.seMinDepth and expectFailHigh and move == hashMove and ttDepth + self.parameters.seDepthOffset >= depth:
            # Singular extensions. If there is a TT move and we expect the node to fail high, we do a null
            # window search with reduced depth (using a new beta derived from the TT score) and excluding
            # the TT move to verify whether it is the only good move: if the search fails low, then said
            # move is "singular" and it is searched with an increased depth. Note that singular extensions
            # are disabled when we are already in a singular search

            # Derive new beta from TT score
            let newBeta = Score(ttScore - self.parameters.seDepthMultiplier * depth)
            let newAlpha = Score(newBeta - 1)
            let newDepth = (depth - self.parameters.seReductionOffset) div self.parameters.seReductionDivisor
            # This is basically a big comparison, asking "is there any move better than the TT move?"
            let singularScore = self.search(newDepth, ply, newAlpha, newBeta, isPV=false, cutNode=cutNode, excluded=hashMove)
            if singularScore < newBeta:
                # Search failed low, hash move is singular: explore it deeper
                inc(singular)
                when not isPV:
                    # We restrict greater extensions to non-pv nodes. The consensus
                    # on this seems to be that it avoids search explosions (it can
                    # apparently be done in pv nodes with much tighter margins)

                    # Double extensions. Hash move is very singular (no close candiates)
                    # so we explore it deeper
                    if singularScore <= newAlpha - self.parameters.doubleExtMargin:
                        inc(singular)
            elif ttScore >= beta:
                ## Negative extensions: hash move is not singular, but TT score
                ## suggests a cutoff is likely so we reduce the search depth
                singular = -1
                # TODO: Triple extensions, multi-cut pruning

        self.state.moves[ply] = move
        self.state.movedPieces[ply] = self.board.getPiece(move.startSquare)
        let kingSq = self.board.getBitboard(King, self.board.sideToMove).toSquare()
        self.state.evalState.update(move, self.board.sideToMove, self.state.movedPieces[ply].kind, self.board.getPiece(move.targetSquare).kind, kingSq)
        let reduction = self.getReduction(move, depth, ply, i, isPV, improving, cutNode)
        self.board.doMove(move)
        self.statistics.nodeCount.atomicInc()
        # Find the best move for us (worst move
        # for our opponent, hence the negative sign)
        var score: Score
        # Prefetch next TT entry: 0 means read, 3 means the value has high temporal locality
        # and should be kept in all possible cache levels if possible
        prefetch(addr self.transpositionTable.data[getIndex(self.transpositionTable[], self.board.zobristKey)], cint(0), cint(3))
        # Implementation of Principal Variation Search (PVS)
        if i == 0:
            # Due to our move ordering scheme, the first move is always the "best", so
            # search it always at full depth with the full search window
            score = -self.search(depth - 1 + singular, ply + 1, -beta, -alpha, isPV, when isPV: false else: not cutNode)
        elif reduction > 0:
            # Late Move Reductions: assume our move orderer did a good job,
            # so it is not worth it to look at all moves at the same depth equally.
            # If this move turns out to be better than we expected, we'll re-search
            # it at full depth

            # We first do a null-window search to see if there's a move that beats alpha
            # (we don't care about the actual value, so we search in the range [alpha, alpha + 1]
            # to increase the number of cutoffs)
            score = -self.search(depth - 1 - reduction, ply + 1, -alpha - 1, -alpha, isPV=false, cutNode=true)
            # If the null window reduced search beats alpha, we redo the search with the same alpha
            # beta bounds, but without the reduction to get a better feel for the actual score of the position.
            # If the score turns out to beat alpha (but not beta) again, we'll re-search this with a full
            # window later
            if score > alpha:
                score = -self.search(depth - 1, ply + 1, -alpha - 1, -alpha, isPV=false, cutNode=not cutNode)
        else:
            # Move wasn't reduced, just do a null window search
            score = -self.search(depth - 1, ply + 1, -alpha - 1, -alpha, isPV=false, cutNode=not cutNode)
        if i > 0 and score > alpha and score < beta:
            # The position beat alpha (and not beta, which would mean it was too good for us and
            # our opponent wouldn't let us play it) in the null window search, search it
            # again with the full depth and full window. Note to future self: alpha and beta
            # are integers, so in a non-pv node it's never possible that this condition is triggered
            # since there's no value between alpha and beta (which is alpha + 1)
            score = -self.search(depth - 1, ply + 1, -beta, -alpha, isPV, cutNode=false)
        inc(i)
        inc(playedMoves)
        if root:
            # Record how many nodes were spent on each root move
            let nodesAfter = self.statistics.nodeCount.load()
            self.statistics.spentNodes[move.startSquare][move.targetSquare].atomicInc(nodesAfter - nodesBefore)
        self.board.unmakeMove()
        self.state.evalState.undo()
        # When a search is cancelled or times out, we need
        # to make sure the entire call stack unwinds back
        # to the root move. This is why the check is duplicated.
        # We only check whether the limit has expired previously
        # because if it hasn't, we'll catch it at the next recursive
        # call anyway
        if ply > 1 and self.state.expired.load():
            return
        bestScore = max(score, bestScore)
        if score >= beta:
            # This move was too good for us, opponent will not search it
            if not root and not (move.isCapture() or move.isEnPassant()):
                # Countermove heuristic: we assume that most moves have a natural
                # response irrespective of the actual position and store them in a
                # table indexed by the from/to squares of the previous move
                let prevMove = self.state.moves[ply - 1]
                self.counters[prevMove.startSquare][prevMove.targetSquare] = move

            if move.isQuiet():
                # If the best move we found is a tactical move, we don't want to punish quiets
                # because they still might be good (just not as good wrt the best move)
                if not bestMove.isTactical():
                    # Give a bonus to the quiet move that failed high so that we find it faster later
                    self.updateHistories(sideToMove, move, self.state.movedPieces[ply], depth, ply, true)
                    # Punish quiet moves coming before this one such that they are placed later in the
                    # list in subsequent searches and we manage to cut off faster
                    for i, quiet in failedQuiets:
                        self.updateHistories(sideToMove, quiet, failedQuietPieces[i], depth, ply, false)
                # Killer move heuristic: store quiets that caused a beta cutoff according to the distance from
                # root that they occurred at, as they might be good refutations for future moves from the opponent.
                # Elo gains: 33.5 +/- 19.3
                self.storeKillerMove(ply, move)

            if move.isCapture():
                # It doesn't make a whole lot of sense to give a bonus to a capture
                # if the best move is a quiet move, does it? (This is also why we
                # don't give a bonus to quiets if the best move is a tactical move)
                if bestMove.isCapture():
                    self.updateHistories(sideToMove, move, nullPiece(), depth, ply, true)

                # We always apply the malus to captures regardless of what the best
                # move is because if a quiet manages to beat all previously seen captures
                # we still want to punish them, otherwise we'd think they're better than
                # they actually are!
                for capture in failedCaptures:
                    self.updateHistories(sideToMove, capture, nullPiece(), depth, ply, false)
            break
        if score > alpha:
            alpha = score
            bestMove = move
            if root:
                self.statistics.bestRootScore.store(score)
                self.statistics.bestMove.store(bestMove)
            when isPV:
                # This loop is why pvMoves has one extra move.
                # We can just do ply + 1 and i + 1 without ever
                # fearing about buffer overflows
                for i, pv in self.state.pvMoves[ply + 1]:
                    if pv == nullMove():
                        self.state.pvMoves[ply][i + 1] = nullMove()
                        break
                    self.state.pvMoves[ply][i + 1] = pv
                self.state.pvMoves[ply][0] = move
        else:
            if move.isQuiet():
                failedQuiets.add(move)
                failedQuietPieces[failedQuiets.high()] = self.state.movedPieces[ply]
            elif move.isCapture():
                failedCaptures.add(move)
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
        return if not isSingularSearch: Score(0) else: alpha
    # Don't store in the TT during a singular search. We also don't overwrite
    # the entry in the TT for the root node to avoid poisoning the original
    # score
    if not isSingularSearch and (not root or self.statistics.currentVariation.load() == 1) and not self.state.expired.load() and not self.cancelled():
        # Store the best move in the transposition table so we can find it later
        let nodeType = if bestScore >= beta: LowerBound elif bestScore <= originalAlpha: UpperBound else: Exact
        var storedScore = bestScore
        # We do this because we want to make sure that when we get a TT cutoff and it's
        # a mate score, we pick the shortest possible mate line if we're mating and the
        # longest possible one if we're being mated. We revert this when probing the TT
        if abs(storedScore) >= mateScore() - MAX_DEPTH:
            storedScore += Score(storedScore.int.sgn()) * Score(ply)
        self.transpositionTable.store(depth.uint8, storedScore, self.board.zobristKey, bestMove, nodeType, staticEval.int16)

    return bestScore


proc startClock*(self: SearchManager) =
    ## Starts the manager's internal clock
    self.state.searchStart.store(getMonoTime())
    self.state.stoppedPondering.store(self.state.searchStart.load())
    self.state.clockStarted = true


proc findBestLine(self: SearchManager, searchMoves: seq[Move], silent=false, ponder=false, variations=1): array[256, Move] =
    ## Internal, single-threaded search for the principal variation

    # Clean up the search state and statistics
    self.state.pondering.store(ponder)
    self.searchMoves = searchMoves
    self.statistics.nodeCount.store(0)
    self.statistics.highestDepth.store(0)
    self.statistics.selectiveDepth.store(0)
    self.statistics.bestRootScore.store(0)
    self.statistics.bestMove.store(nullMove())
    self.statistics.currentVariation.store(0)
    for i in Square(0)..Square(63):
        for j in Square(0)..Square(63):
            self.statistics.spentNodes[i][j].store(0)

    for i in 0..MAX_DEPTH:
        result[i] = nullMove()
    var score = Score(0)
    var previousScores: array[MAX_MOVES, Score]
    var bestMoves: seq[Move] = @[]
    var legalMoves {.noinit.} = newMoveList()
    var variations = min(MAX_MOVES, variations)
    
    # This is way more complicated than it seems to need because we want to print
    # variations from best to worst and that requires some bookkeeping.

    var heap = initHeapQueue[tuple[score: Score, line: int]]()
    var messages = newSeqOfCap[tuple[score: Score, line: int]](32)

    if variations > 1:
        self.board.generateMoves(legalMoves)
        if searchMoves.len() > 0:
            variations = min(variations, searchMoves.len())
    
    var lines = newSeqOfCap[array[256, Move]](variations)

    block search:
        # Iterative deepening loop
        self.state.stop.store(false)
        self.state.searching.store(true)
        self.state.expired.store(false)
        if not self.state.clockStarted:
            self.startClock()
        for depth in 1..MAX_DEPTH:
            if self.shouldStop():
                break
            self.limiter.scale(self.parameters)
            heap.clear()
            messages.setLen(0)
            lines.setLen(0)
            for i in 1..variations:
                self.statistics.selectiveDepth.store(0)
                self.statistics.currentVariation.store(i)
                if depth < self.parameters.aspWindowDepthThreshold:
                    score = self.search(depth, 0, lowestEval(), highestEval(), true, false)
                else:
                    # Aspiration windows: start subsequent searches with tighter
                    # alpha-beta bounds and widen them as needed (i.e. when the score
                    # goes beyond the window) to increase the number of cutoffs
                    var
                        delta = Score(self.parameters.aspWindowInitialSize)
                        alpha = max(lowestEval(), score - delta)
                        beta = min(highestEval(), score + delta)
                        reduction = 0
                    while true:
                        score = self.search(depth - reduction, 0, alpha, beta, true, false)
                        # Score is outside window bounds, widen the one that
                        # we got past to get a better result
                        if score <= alpha:
                            alpha = max(lowestEval(), score - delta)
                            # Grow the window downward as well when we fail
                            # low (cuts off faster)
                            beta = (alpha + beta) div 2
                            # Reset the reduction whenever we fail low to ensure
                            # we don't miss good stuff that seems bad at first
                            reduction = 0
                        elif score >= beta:
                            beta = min(highestEval(), score + delta)
                            # Whenever we fail high, reduce the search depth as we
                            # expect the score to be good for our opponent anyway
                            reduction += 1
                        else:
                            # Value was within the alpha-beta bounds, we're done
                            break
                        # Try again with larger window
                        delta += delta
                        if delta >= Score(self.parameters.aspWindowMaxSize):
                            # Window got too wide, give up and search with the full range
                            # of alpha-beta values
                            delta = highestEval()
                let variation = self.state.pvMoves[0]
                lines.add(variation)
                bestMoves.add(variation[0])
                let stopping = self.shouldStop(false)
                if variation[0] != nullMove() and i == 1 and not stopping:
                    result = variation
                if not silent:
                    if not stopping:
                        heap.push((score, lines.high()))
                    else:
                        # Can't use shouldStop because it caches the result from
                        # previous calls to expired()
                        let isIncompleteSearch = self.limiter.expired(true) or self.cancelled()
                        if not isIncompleteSearch:
                            previousScores[i - 1] = score
                        break search
                previousScores[i - 1] = score
                self.statistics.highestDepth.store(depth)
                if variations > 1:
                    self.searchMoves = searchMoves
                    for move in legalMoves:
                        if move in bestMoves:
                            # Don't search the current best move in the next search
                            continue
                        if searchMoves.len() > 0 and move notin searchMoves:
                            # If the user told us to only search a specific set
                            # of moves, don't override that
                            continue
                        self.searchMoves.add(move)
            bestMoves.setLen(0)
            # Print all lines ordered by score (extract them from the min heap
            # in reverse)
            while heap.len() > 0:
                messages.add(heap.pop())
            var i = 1
            for j in countdown(messages.high(), 0):
                let message = messages[j]
                self.log(depth, i, lines[message.line], message.score)
                inc(i)

    if not silent:
        # Log final info message
        self.log(self.statistics.highestDepth.load(), 1, result, previousScores[0])
    if self.state.isMainThread.load():
        # The main thread is the only one doing time management,
        # so we need to explicitly stop all other workers
        self.stop()
    # Reset atomics
    self.state.searching.store(false)
    self.state.pondering.store(false)
    self.state.clockStarted = false


type
    SearchArgs = tuple[self: SearchManager, searchMoves: seq[Move], silent, ponder: bool, variations: int]
    SearchThread = Thread[SearchArgs]


proc workerFunc(args: SearchArgs) {.thread.} =
    ## Worker that calls findBestLine in a new thread
    # Gotta lie to nim's thread analyzer lest it shout at us that we're not
    # GC safe!
    {.cast(gcsafe).}:
        discard args.self.findBestLine(args.searchMoves, args.silent, args.ponder, args.variations)

# Creating thread objects can be expensive, so there's no need to make new ones for every call
# to our parallel search. Also, nim leaks thread vars: this keeps the resource leaks
# to a minimum
var workers: seq[ref SearchThread] = @[]


proc search*(self: SearchManager, searchMoves: seq[Move] = @[], silent=false, ponder=false, numWorkers=1, variations=1): seq[Move] =
    ## Finds the principal variation in the current position
    ## and returns it, limiting search time according the
    ## the manager's limiter configuration. If ponder equals
    ## true, the search will ignore time limits until the
    ## stopPondering() procedure is called, after which it
    ## will continue as normal. Note that, irrespective of
    ## any limit or explicit cancellation, search will not
    ## stop until depth one has been cleared. If numWorkers
    ## is > 1, the search is performed in parallel using that
    ## many threads. If silent equals true, UCI logs are not
    ## printed to the console during search. If variations > 1,
    ## the specified number of alternative variations (up to
    ## MAX_MOVES) is searched (note that time and node limits
    ## are shared across all of them), but only the first one
    ## is returned. If searchMoves is nonempty, only the specified
    ## set of root moves is searched
    while workers.len() + 1 < numWorkers:
        # We create n - 1 workers because we'll also be searching
        # ourselves
        workers.add(new SearchThread)
    let chess960 = self.state.chess960.load()
    for i in 0..<numWorkers - 1:
        # The only shared state is the TT, everything else is thread-local
        var
            # Allocate on 64-byte boundaries to ensure threads won't have
            # overlapping stuff in their cache lines
            evalState = self.state.evalState.deepCopy()
            quietHistory = allocHeapAligned(ThreatHistoryTable, 64)
            continuationHistory = allocHeapAligned(ContinuationHistory, 64)
            captureHistory = allocHeapAligned(CaptHistTable, 64)
            killers = allocHeapAligned(KillersTable, 64)
            counters = allocHeapAligned(CountersTable, 64)
        # Copy in the data
        for color in White..Black:
            for i in Square(0)..Square(63):
                for j in Square(0)..Square(63):
                    quietHistory[color][i][j][true][false] = self.quietHistory[color][i][j][true][false]
                    quietHistory[color][i][j][false][true] = self.quietHistory[color][i][j][false][true]
                    quietHistory[color][i][j][true][true] = self.quietHistory[color][i][j][true][true]
                    quietHistory[color][i][j][false][false] = self.quietHistory[color][i][j][false][false]
                    for piece in Pawn..Queen:
                        captureHistory[color][i][j][piece] = self.captureHistory[color][i][j][piece]
        for i in 0..<MAX_DEPTH:
            for j in 0..<NUM_KILLERS:
                killers[i][j] = self.killers[i][j]
        for fromSq in Square(0)..Square(63):
            for toSq in Square(0)..Square(63):
                counters[fromSq][toSq] = self.counters[fromSq][toSq]
        for sideToMove in White..Black:
            for piece in PieceKind.all():
                for to in Square(0)..Square(63):
                    for prevColor in White..Black:
                        for prevPiece in PieceKind.all():
                            for prevTo in Square(0)..Square(63):
                                continuationHistory[sideToMove][piece][to][prevColor][prevPiece][prevTo] = self.continuationHistory[sideToMove][piece][to][prevColor][prevPiece][prevTo]
        # Create a new search manager to send off to a worker thread
        self.children.add(newSearchManager(self.board.positions, self.transpositionTable, quietHistory, captureHistory, killers, counters, continuationHistory, self.parameters, false, chess960, evalState))
        self.state.childrenStats.add(self.children[^1].statistics)
        # Off you go, you little search minion!
        createThread(workers[i][], workerFunc, (self.children[i], searchMoves, silent, ponder, variations))
        # Pin thread to one CPU core to remove task switching overheads
        # introduced by the scheduler
        when not defined(windows) and defined(pinSearchThreads):
            # The C-level Windows implementation of this using SetThreadAffinity is
            # borked, so don't use it. It also causes problem on systems with more than
            # one NUMA domain, so it's  hidden behind an optional compile time flag
            pinToCpu(workers[i][], i)
    var pv = self.findBestLine(searchMoves, silent, ponder, variations)
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
    self.state.childrenStats.setLen(0)
