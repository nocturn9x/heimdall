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
import std/[math, times, options, atomics, strutils, monotimes, strformat, heapqueue]

import heimdall/[eval, board, movegen, transpositions]
import heimdall/util/[see, logs, limits, shared, tunables, hashtable]

export shared

# Miscellaneous parameters that are not meant to be tweaked (neither manually nor automatically)
const
    PAWN_CORRHIST_SIZE* = 16384
    NONPAWN_CORRHIST_SIZE* = 16384
    MAJOR_CORRHIST_SIZE* = 16384
    MINOR_CORRHIST_SIZE* = 16384

    # How many killer moves we keep track of
    NUM_KILLERS* = 1

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


type
    LMRTable* = array[MAX_DEPTH + 1, array[MAX_MOVES + 1, int]]


    PawnCorrHist*         = array[White..Black, StaticHashTable[PAWN_CORRHIST_SIZE]]
    NonPawnCorrHist*      = array[White..Black, array[White..Black, StaticHashTable[NONPAWN_CORRHIST_SIZE]]]
    MajorCorrHist*        = array[White..Black, StaticHashTable[MAJOR_CORRHIST_SIZE]]
    MinorCorrHist*        = array[White..Black, StaticHashTable[MINOR_CORRHIST_SIZE]]
    ContCorrHist*         = array[White..Black, array[Pawn..King, array[Square.smallest()..Square.biggest(), array[White..Black, array[Pawn..King, array[Square.smallest()..Square.biggest(), int16]]]]]]
    ThreatHistory*        = array[White..Black, array[Square.smallest()..Square.biggest(), array[Square.smallest()..Square.biggest(), array[bool, array[bool, int16]]]]]
    CaptureHistory*       = array[White..Black, array[Square.smallest()..Square.biggest(), array[Square.smallest()..Square.biggest(), array[Pawn..Queen, array[bool, array[bool, int16]]]]]]
    CounterMoves*         = array[Square.smallest()..Square.biggest(), array[Square.smallest()..Square.biggest(), Move]]
    KillerMoves*          = array[MAX_DEPTH, array[NUM_KILLERS, Move]]
    ContinuationHistory*  = array[White..Black, array[Pawn..King, array[Square.smallest()..Square.biggest(), array[White..Black, array[Pawn..King, array[Square.smallest()..Square.biggest(), int16]]]]]]

    HistoryTables* = ref object
        quietHistory        {.align(64).} : ThreatHistory
        captureHistory      {.align(64).} : CaptureHistory
        killerMoves         {.align(64).} : KillerMoves
        counterMoves        {.align(64).} : CounterMoves
        continuationHistory {.align(64).} : ContinuationHistory
        pawnCorrHist        {.align(64).} : PawnCorrHist
        nonpawnCorrHist     {.align(64).} : NonPawnCorrHist
        majorCorrHist       {.align(64).} : MajorCorrHist
        minorCorrHist       {.align(64).} : MinorCorrHist
        contCorrHist        {.align(64).} : ContCorrHist
        initialized                       : bool

    SearchStackEntry = object
        staticEval: Score
        move      : Move
        piece     : Piece
        inCheck   : bool
        reduction : int

    SearchStack = array[MAX_DEPTH + 1, SearchStackEntry]

    MoveType = enum
        HashMove,
        GoodNoisy,
        KillerMove,
        CounterMove,
        QuietMove,
        BadNoisy

    ScoredMove = tuple[move: Move, data: int32]

    ChessVariation* = array[MAX_DEPTH + 1, Move]

    SearchManager* = object
        state*                       : SearchState
        statistics*                  : SearchStatistics
        parameters*                  : SearchParameters
        logger*     {.align(64).}    : SearchLogger
        stack       {.align(64).}    : SearchStack
        limiter*    {.align(64).}    : SearchLimiter
        histories*                   : HistoryTables
        board                        : Chessboard
        evalState                    : EvalState
        ttable                       : ptr TranspositionTable
        workerPool                   : WorkerPool
        workerCount                  : int
        searchMoves                  : seq[Move]
        clockStarted                 : bool
        expired                      : bool
        minNmpPly                    : int
        lmrTable       {.align(64).} : LMRTable
        pvMoves        {.align(64).} : array[MAX_DEPTH + 1, ChessVariation]
        previousScores {.align(64).} : array[MAX_MOVES, Score]
        previousLines  {.align(64).} : array[MAX_MOVES, ChessVariation]
        contempt                     : Score

    # Search thread pool implementation

    WorkerCommandType = enum
        Shutdown, Reset, Setup, Go, Ping

    WorkerCommand = object
        case kind: WorkerCommandType
            of Go:
                searchMoves: seq[Move]
                variations: int
            else:
                discard

    WorkerResponse = enum
        Ok, SetupMissing, SetupAlready, NotSetUp, Pong

    SearchWorker* = ref object
        workerId  : int
        thread    : Thread[SearchWorker]
        manager   : SearchManager
        channels  : tuple[command: Channel[WorkerCommand], response: Channel[WorkerResponse]]
        isSetUp   : Atomic[bool]
        ttable    : ptr TranspositionTable

    WorkerPool* = object
        workers: seq[SearchWorker]

proc search*(self: var SearchManager, searchMoves: seq[Move] = @[], silent=false, ponder=false, minimal=false, variations=1): seq[ChessVariation] {.gcsafe.}
proc newSearchManager*(positions: seq[Position], ttable: ptr TranspositionTable, parameters=getDefaultParameters(), mainWorker=true,
                       chess960=false, evalState=newEvalState(), state=newSearchState(), statistics=newSearchStatistics(),
                       normalizeScore: bool = true): SearchManager {.gcsafe.}
proc setBoardState*(self: SearchManager, state: seq[Position]) {.gcsafe.}
proc computeLMRTable*(self: var SearchManager) {.gcsafe.}

func score(self: ScoredMove): int32    {.inline.} = self.data and 0xffffff
func stage(self: ScoredMove): MoveType {.inline.} = MoveType(self.data shr 24)


func clear*(histories: HistoryTables) = 
    histories.quietHistory        = default(ThreatHistory)
    histories.captureHistory      = default(CaptureHistory)
    histories.continuationHistory = default(ContinuationHistory)
    histories.counterMoves        = default(CounterMoves)
    histories.killerMoves         = default(KillerMoves)
    histories.contCorrHist        = default(ContCorrHist)
    for color in White..Black:
        histories.pawnCorrHist[color].clear()
        histories.nonpawnCorrHist[color][White].clear()
        histories.nonpawnCorrHist[color][Black].clear()
        histories.majorCorrHist[color].clear()
        histories.minorCorrHist[color].clear()


func createWorkerPool: WorkerPool = discard

proc reply(self: SearchWorker, response: WorkerResponse) {.inline.} =
    self.channels.response.send(response)

proc receive(self: SearchWorker): WorkerCommand {.inline.} =
    return self.channels.command.recv()

proc workerLoop(self: SearchWorker) {.thread.} =
    while true:
        let msg = self.receive()
        case msg.kind:
            of Ping:
                self.reply(Pong)
            of Shutdown:
                if self.isSetUp.load(moRelaxed):
                    self.isSetUp.store(false, moRelaxed)
                self.reply(Ok)
                break
            of Reset:
                if not self.isSetUp.load(moRelaxed):
                    self.reply(NotSetUp)
                    continue

                self.manager.histories.clear()
                self.reply(Ok)
            of Go:
                # Start a search
                if not self.isSetUp.load(moRelaxed):
                    self.reply(SetupMissing)
                    continue
                self.reply(Ok)
                discard self.manager.search(msg.searchMoves, true, false, false, msg.variations)
            of Setup:
                if self.isSetUp.load(moRelaxed):
                    self.reply(SetupAlready)
                    continue

                self.isSetUp.store(true, moRelaxed)
                self.manager = newSearchManager(@[startpos()], self.ttable, mainWorker=false, evalState=newEvalState(verbose=false))
                self.reply(Ok)


proc cmd(self: SearchWorker, cmd: WorkerCommand, expected: WorkerResponse = Ok) {.inline.} =
    self.channels.command.send(cmd)
    let response = self.channels.response.recv()
    doAssert response == expected, &"sent {cmd} to worker #{self.workerId} and expected {expected}, got {response} instead"

template simpleCmd(k: WorkerCommandType): WorkerCommand = WorkerCommand(kind: k)

proc ping(self: SearchWorker)  {.inline.} = self.cmd(simpleCmd(Ping), Pong)
proc setup(self: SearchWorker) {.inline.} = self.cmd(simpleCmd(Setup))
proc reset(self: SearchWorker) {.inline.} = self.cmd(simpleCmd(Reset))

proc go(self: SearchWorker, searchMoves: seq[Move], variations: int) {.inline.} =
    self.cmd(WorkerCommand(kind: Go, searchMoves: searchMoves, variations: variations))

proc shutdown(self: SearchWorker) {.inline.} =
    self.cmd(simpleCmd(Shutdown))
    joinThread(self.thread)
    self.channels.command.close()
    self.channels.response.close()


proc create(self: var WorkerPool): SearchWorker {.inline, discardable.} =
    ## Starts up a new thread and readies it to begin
    ## searching when necessary
    result = SearchWorker(workerId: self.workers.len())
    self.workers.add(result)
    result.channels.command.open(0)
    result.channels.response.open(0)
    createThread(result.thread, workerLoop, result)
    # Ensure worker is alive
    result.ping()


proc reset(self: WorkerPool) {.inline.} =
    ## Resets the state of all worker threads, but
    ## keeps them alive to be reused
    for worker in self.workers:
        worker.reset()


proc shutdown(self: var WorkerPool) {.inline.} =
    ## Cleanly shuts down all the threads in the
    ## pool
    for worker in self.workers:
        worker.shutdown()
    self.workers.setLen(0)


proc computeLMRTable*(self: var SearchManager) {.gcsafe.} =
    ## Computes the LMR reduction table based on the current
    ## tunable parameters
    for i in 1..self.lmrTable.high():
        for j in 1..self.lmrTable[0].high():
            self.lmrTable[i][j] = round(self.parameters.lmrBase + ln(i.float) * ln(j.float) * self.parameters.lmrMultiplier).int


proc newSearchManager*(positions: seq[Position], ttable: ptr TranspositionTable, parameters=getDefaultParameters(), mainWorker=true,
                       chess960=false, evalState=newEvalState(), state=newSearchState(), statistics=newSearchStatistics(),
                       normalizeScore: bool = true): SearchManager {.gcsafe.} =
    result = SearchManager(ttable: ttable, parameters: parameters, state: state, statistics: statistics, evalState: evalState)
    new(result.board)
    new(result.histories)
    result.histories.clear()
    result.state.normalizeScore.store(normalizeScore, moRelaxed)
    result.state.chess960.store(chess960, moRelaxed)
    result.state.isMainThread.store(mainWorker, moRelaxed)
    result.limiter    = newSearchLimiter(result.state, result.statistics)
    result.logger     = createSearchLogger(result.state, result.statistics, result.board, ttable)
    result.workerPool = createWorkerPool()
    result.computeLMRTable()
    result.setBoardState(positions)


proc setupWorkers(self: var SearchManager) {.inline.} =
    ## Setups each search worker by copying in the necessary
    ## data from the main searcher
    for i in 0..<self.workerCount:
        var worker = self.workerPool.workers[i]
        # This is the only stuff that we pass from the outside
        worker.ttable = self.ttable
        worker.setup()
        self.state.childrenStats.add(worker.manager.statistics)


proc createWorkers(self: var SearchManager, workerCount: int) {.inline.} =
    for i in 0..<workerCount:
        self.workerPool.create()
    self.setupWorkers()


proc shutdownWorkers*(self: var SearchManager) {.inline.} =
    self.workerPool.shutdown()
    self.state.childrenStats.setLen(0)


proc resetWorkers*(self: var SearchManager) {.inline.} =
    self.workerPool.reset()


proc restartWorkers*(self: var SearchManager) {.inline.} =
    self.shutdownWorkers()
    self.createWorkers(self.workerCount)


proc startSearch(self: WorkerPool, searchMoves: seq[Move], variations: int) {.inline.} =
    for worker in self.workers:
        worker.go(searchMoves, variations)


proc setWorkerCount*(self: var SearchManager, workerCount: int) {.inline.} =
    ## Sets the number of additional worker threads to search
    ## alongside the main thread
    doAssert workerCount >= 0
    if workerCount != self.workerCount:
        self.workerCount = workerCount
        self.shutdownWorkers()
        self.createWorkers(self.workerCount)


proc setBoardState*(self: SearchManager, state: seq[Position]) {.gcsafe.} =
    self.board.positions.setLen(0)
    for position in state:
        self.board.positions.add(position.clone())
    self.evalState.init(self.board)
    for worker in self.workerPool.workers:
        worker.manager.setBoardState(state)


proc setParameter*(self: var SearchManager, name: string, value: int) {.gcsafe.} =
    self.parameters.setParameter(name, value)
    if name in ["LMRBase", "LMRMultiplier"]:
        self.computeLMRTable()
    for worker in self.workerPool.workers:
        worker.manager.parameters.setParameter(name, value)
        if name in ["LMRBase", "LMRMultiplier"]:
            worker.manager.computeLMRTable()


func getCurrentPosition*(self: SearchManager): lent Position {.inline.} =
    return self.board.position


proc setNetwork*(self: var SearchManager, path: string) =
    self.evalState = newEvalState(path)
    self.evalState.init(self.board)
    # newEvalState and init() are expensive, no
    # need to run them for every thread!
    for worker in self.workerPool.workers:
        worker.manager.evalState = self.evalState.deepCopy()


func stopped(self: SearchManager):         bool          {.inline.} = self.state.stop.load(moRelaxed)
func cancelled*(self: SearchManager):      bool          {.inline.} = self.state.cancelled.load(moRelaxed)
func isPondering*(self: SearchManager):    bool          {.inline.} = self.state.pondering.load(moRelaxed)
func isSearching*(self: SearchManager):    bool          {.inline.} = self.state.searching.load(moRelaxed)
func getWorkerCount*(self: SearchManager): int           {.inline.} = self.workerCount
proc setUCIMode*(self: SearchManager, value: bool)       {.inline.} = self.state.uciMode.store(value, moRelaxed)
func setContempt*(self: var SearchManager, value: Score) {.inline.} = self.contempt = value


func stop(self: SearchManager) {.inline.} =
    self.state.stop.store(true, moRelaxed)
    # Stop all worker threads
    for child in self.workerPool.workers:
        child.manager.stop()


func cancel*(self: SearchManager) {.inline.} =
    self.state.cancelled.store(true, moRelaxed)
    self.stop()


func isKillerMove(self: SearchManager, move: Move, ply: int): bool {.inline.} =
    if ply notin 0..self.histories.killerMoves[0].high():
        return false
    for killer in self.histories.killerMoves[ply]:
        if killer == move:
            return true

func isCounterMove(self: SearchManager, move: Move, ply: int): bool {.inline.} =
    if ply < 1:
        return false
    let prevMove = self.stack[ply - 1].move
    return move == self.histories.counterMoves[prevMove.startSquare][prevMove.targetSquare]


func historyScore(self: SearchManager, sideToMove: PieceColor, move: Move): int16 {.inline.} =
    assert move.isCapture() or move.isQuiet()
    let startAttacked = self.board.position.threats.contains(move.startSquare)
    let targetAttacked = self.board.position.threats.contains(move.targetSquare)
    if move.isQuiet():
        result = self.histories.quietHistory[sideToMove][move.startSquare][move.targetSquare][startAttacked][targetAttacked]
    else:
        let victim = self.board.on(move.targetSquare).kind
        result = self.histories.captureHistory[sideToMove][move.startSquare][move.targetSquare][victim][startAttacked][targetAttacked]


func conthistScore(self: SearchManager, sideToMove: PieceColor, piece: Piece, target: Square, ply, dst: int): int16 {.inline.} =
    ## Returns the score stored in the continuation history dst
    ## plies ago (does not check for out of bounds access)
    let prevPiece = self.stack[ply - dst].piece
    result += self.histories.continuationHistory[sideToMove][piece.kind][target][prevPiece.color][prevPiece.kind][self.stack[ply - dst].move.targetSquare]


func conthistScore(self: SearchManager, sideToMove: PieceColor, piece: Piece, target: Square, ply: int): Score {.inline.} =
    ## Returns the cumulative continuation history score for
    ## as many plies as possible given the current one
    for dst in [0, 1, 3]:
        if ply > dst:
            result += self.conthistScore(sideToMove, piece, target, ply, dst + 1)


proc updateHistories(self: SearchManager, sideToMove: PieceColor, move: Move, piece: Piece, depth, ply: int, good: bool) {.inline.} =
    ## Updates internal histories with the given move
    ## which failed (at the given depth and ply from root),
    ## either high or low depending on whether good is true
    ## or false
    assert move.isCapture() or move.isQuiet()
    let startAttacked = self.board.position.threats.contains(move.startSquare)
    let targetAttacked = self.board.position.threats.contains(move.targetSquare)
    if move.isQuiet():
        var bonus = (if good: self.parameters.moveBonuses.conthist.good else: -self.parameters.moveBonuses.conthist.bad) * depth
        
        if ply > 0 and not self.board.positions[^2].fromNull:
            let prevPiece = self.stack[ply - 1].piece

            self.histories.continuationHistory[sideToMove][piece.kind][move.targetSquare][prevPiece.color][prevPiece.kind][self.stack[ply - 1].move.targetSquare] += (bonus - abs(bonus) * self.conthistScore(sideToMove, piece, move.targetSquare, ply, 1) div HISTORY_SCORE_CAP).int16
        if ply > 1 and not self.board.positions[^3].fromNull:
          let prevPiece = self.stack[ply - 2].piece
          self.histories.continuationHistory[sideToMove][piece.kind][move.targetSquare][prevPiece.color][prevPiece.kind][self.stack[ply - 2].move.targetSquare] += (bonus - abs(bonus) * self.conthistScore(sideToMove, piece, move.targetSquare, ply, 2) div HISTORY_SCORE_CAP).int16
        if ply > 3 and not self.board.positions[^5].fromNull:
          let prevPiece = self.stack[ply - 4].piece
          self.histories.continuationHistory[sideToMove][piece.kind][move.targetSquare][prevPiece.color][prevPiece.kind][self.stack[ply - 4].move.targetSquare] += (bonus - abs(bonus) * self.conthistScore(sideToMove, piece, move.targetSquare, ply, 4) div HISTORY_SCORE_CAP).int16

        bonus = (if good: self.parameters.moveBonuses.quiet.good else: -self.parameters.moveBonuses.quiet.bad) * depth
        self.histories.quietHistory[sideToMove][move.startSquare][move.targetSquare][startAttacked][targetAttacked] += int16(bonus - abs(bonus) * self.historyScore(sideToMove, move) div HISTORY_SCORE_CAP)

    elif move.isCapture():
        let bonus = (if good: self.parameters.moveBonuses.capture.good else: -self.parameters.moveBonuses.capture.bad) * depth
        let victim = self.board.on(move.targetSquare).kind
        # We use this formula to evenly spread the improvement the more we increase it (or decrease it)
        # while keeping it constrained to a maximum (or minimum) value so it doesn't (over|under)flow.
        self.histories.captureHistory[sideToMove][move.startSquare][move.targetSquare][victim][startAttacked][targetAttacked] += int16(bonus - abs(bonus) * self.historyScore(sideToMove, move) div HISTORY_SCORE_CAP)


proc scoreMove(self: SearchManager, hashMove: Move, move: Move, ply: int): ScoredMove {.inline.} =
    ## Returns an estimated static score for the move, used
    ## during move ordering
    result.move = move
    if move == hashMove:
        result.data = TTMOVE_OFFSET or HashMove.int32 shl 24
        return

    if ply > 0:
        if self.isKillerMove(move, ply):
            result.data = KILLERS_OFFSET or KillerMove.int32 shl 24
            return

        if self.isCounterMove(move, ply):
            result.data = COUNTER_OFFSET or CounterMove.int32 shl 24
            return

    let sideToMove = self.board.sideToMove

    # Good/bad tacticals
    if move.isTactical():
        let winning = self.parameters.see(self.board.position, move, 0)
        if move.isCapture():
            result.data += self.historyScore(sideToMove, move)
            # Prioritize attacking our opponent's
            # most valuable pieces
            result.data += MVV_MULTIPLIER * self.parameters.staticPieceScore(self.board.on(move.targetSquare)).int32
        elif move.isEnPassant():
            result.data += MVV_MULTIPLIER * self.parameters.staticPieceScore(Pawn).int32
        if not winning:
            # Prioritize good exchanges (see > 0)
            result.data += BAD_CAPTURE_OFFSET
            result.data = result.data or BadNoisy.int32 shl 24
            return
        else:
            result.data += GOOD_CAPTURE_OFFSET
            result.data = result.data or GoodNoisy.int32 shl 24
            return

    if move.isQuiet():
        result.data = QUIET_OFFSET + self.historyScore(sideToMove, move).int32 + self.conthistScore(sideToMove, self.board.on(move.startSquare), move.targetSquare, ply)
        result.data = result.data or QuietMove.int32 shl 24


iterator pickMoves(self: SearchManager, hashMove: Move, ply: int, qsearch: bool = false): ScoredMove =
    ## Abstracts movegen away from search by picking moves using
    ## our move orderer
    var moves {.noinit.} = newMoveList()
    self.board.generateMoves(moves, capturesOnly=qsearch)
    var scoredMoves {.noinit.}: array[MAX_MOVES, ScoredMove]
    for i in 0..moves.high():
        scoredMoves[i] = self.scoreMove(hashMove, moves[i], ply)
    # Incremental selection sort: we lazily sort the move list
    # as we yield elements from it, which is on average faster than
    # sorting the entire move list due to the fact that, thanks to our
    # pruning, we don't actually explore all the moves
    for startIndex in 0..<moves.len():
        var
            bestMoveIndex = moves.len()
            bestScore = int.low()
        for i in startIndex..<moves.len():
            if scoredMoves[i].score() > bestScore:
                bestScore = scoredMoves[i].score()
                bestMoveIndex = i
        if bestMoveIndex == moves.len():
            break
        yield scoredMoves[bestMoveIndex]
        # To avoid having to keep track of the moves we've
        # already returned, we just move them to a side of
        # the list that we won't iterate anymore. This has
        # the added benefit of sorting the list of moves
        # incrementally
        let scoredMove = scoredMoves[startIndex]
        scoredMoves[startIndex] = scoredMoves[bestMoveIndex]
        scoredMoves[bestMoveIndex] = scoredMove



proc stopPondering*(self: var SearchManager) {.inline.} =
    doAssert self.state.isMainThread.load(moRelaxed)
    self.state.pondering.store(false, moRelaxed)
    # Time will only be accounted for starting from
    # this point, so pondering was effectively free
    self.limiter.enable(true)


proc shouldStop*(self: var SearchManager): bool {.inline.} =
    ## Returns whether searching should
    ## stop. Only checks hard limits
    if self.stopped() or self.expired:
        # Search has been stopped or
        # previous shouldStop() call
        # returned true
        return true
    self.expired = self.limiter.expiredHard()
    return self.expired


proc getReduction(self: SearchManager, move: Move, depth, ply, moveNumber: int, isPV: static bool, improving, wasPV, ttCapture, cutNode: bool): int {.inline.} =
    const
        LMR_MOVENUMBER = (pv: 4, nonpv: 2)
        LMR_MIN_DEPTH = 3

    let moveCount = when isPV: LMR_MOVENUMBER.pv else: LMR_MOVENUMBER.nonpv
    if moveNumber > moveCount and depth >= LMR_MIN_DEPTH:
        result = self.lmrTable[depth][moveNumber] * QUANTIZATION_FACTOR
        when isPV:
            # PV nodes are valuable, reduce them less
            dec(result, 2 * QUANTIZATION_FACTOR)

        if cutNode:
            # Expected cut nodes aren't worth searching as deep
            inc(result, 2 * QUANTIZATION_FACTOR)

        if self.stack[ply].inCheck:
            # Reducing less in check might help finding good escapes
            dec(result, QUANTIZATION_FACTOR)

        if ttCapture and move.isQuiet():
            # Hash move is a capture and current move is not: move
            # is unlikely to be better than it (due to our move
            # ordering), so we reduce more
            inc(result, QUANTIZATION_FACTOR)

        if move.isQuiet():
            # Quiets are ordered later in the list, so they are generally
            # less promising
            inc(result, QUANTIZATION_FACTOR)

        # History LMR
        if move.isQuiet() or move.isCapture():
            let stm = self.board.sideToMove
            let piece = self.board.on(move.startSquare)
            var score: int = self.historyScore(stm, move)
            if move.isQuiet():
                score += self.conthistScore(stm, piece, move.targetSquare, ply)
                score = score * QUANTIZATION_FACTOR div self.parameters.historyLmrDivisor.quiet
            else:
                score = score * QUANTIZATION_FACTOR div self.parameters.historyLmrDivisor.noisy
            dec(result, score)

        const
            PREVIOUS_LMR_MINIMUM = 5
            PREVIOUS_LMR_DIVISOR = 5
        if ply > 0 and moveNumber >= PREVIOUS_LMR_MINIMUM:
            # The previous ply was searched with a reduced depth,
            # so we expected it to fail high quickly. Since we've
            # searched a bunch of moves and not failed high yet,
            # we might've misjudged it and it's worth to reduce
            # the current ply less
            dec(result, self.stack[ply - 1].reduction * QUANTIZATION_FACTOR div PREVIOUS_LMR_DIVISOR)

        when not isPV:
            # If the current node previously was in the principal variation
            # and now isn't, reduce it less, as it may be good anyway
            if wasPV:
                dec(result, QUANTIZATION_FACTOR)

        if improving:
            dec(result, QUANTIZATION_FACTOR)

        if self.isKillerMove(move, ply) or self.isCounterMove(move, ply):
            # Probably worth searching these moves deeper
            dec(result, QUANTIZATION_FACTOR)

        result = result div (1 + (move.isCapture() or move.isEnPassant()).int)

        # From gemini: The expression (result + QUANTIZATION_FACTOR div 2) div QUANTIZATION_FACTOR is a
        # technique for performing integer division that rounds the result to the nearest whole number,
        # rather than truncating it. Adding half of the divisor before dividing achieves this rounding effect.
        result = (result + QUANTIZATION_FACTOR div 2) div QUANTIZATION_FACTOR
        result = result.clamp(-1, depth - 1)


func clampEval(eval: Score): Score {.inline.} =
    ## Clamps the eval such that it is never a mate/mated
    ## score
    result = eval.clamp(lowestEval(), highestEval())


proc rawEval(self: SearchManager): Score =
    ## Runs the raw evaluation on the current
    ## position and applies static corrections
    ## to the result
    result = self.board.evaluate(self.evalState)
    # Material scaling. Yoinked from Stormphrax (see https://github.com/Ciekce/Stormphrax/compare/c4f4a8a6..6cc28cde)
    let
        knights = self.board.pieces(Knight)
        bishops = self.board.pieces(Bishop)
        pawns = self.board.pieces(Pawn)
        rooks = self.board.pieces(Rook)
        queens = self.board.pieces(Queen)

    let material = Score(self.parameters.materialPieceScore(Knight) * knights.count() +
                    self.parameters.materialPieceScore(Bishop) * bishops.count() +
                    self.parameters.materialPieceScore(Pawn) * pawns.count() +
                    self.parameters.materialPieceScore(Rook) * rooks.count() +
                    self.parameters.materialPieceScore(Queen) * queens.count())

    # This scales the eval linearly between base / divisor and (base + max material) / divisor
    result = result * (material + Score(self.parameters.materialScalingOffset)) div Score(self.parameters.materialScalingDivisor)
    # The contempt option is white relative, but static eval is stm relative
    let contemptValue = if self.board.sideToMove == Black: -self.contempt else: self.contempt
    # Ensure we don't return false mates
    result = (result + contemptValue).clampEval()


proc staticEval(self: SearchManager, rawEval: Score, ply: int): Score =
    ## Applies history-based corrections to the given
    ## raw evaluation
    result = rawEval
    let sideToMove = self.board.sideToMove

    result += Score(self.histories.pawnCorrHist[sideToMove].get(self.board.pawnKey).data div self.parameters.corrHistScale.eval.pawn)
    result += Score(self.histories.nonpawnCorrHist[sideToMove][White].get(self.board.nonpawnKey(White)).data div self.parameters.corrHistScale.eval.nonpawn)
    result += Score(self.histories.nonpawnCorrHist[sideToMove][Black].get(self.board.nonpawnKey(Black)).data div self.parameters.corrHistScale.eval.nonpawn)
    result += Score(self.histories.majorCorrHist[sideToMove].get(self.board.majorKey).data div self.parameters.corrHistScale.eval.major)
    result += Score(self.histories.minorCorrHist[sideToMove].get(self.board.minorKey).data div self.parameters.corrHistScale.eval.minor)

    if ply > 1:
        let
            prev2 = self.stack[ply - 2]
            prev = self.stack[ply - 1]
        
        var scale = self.parameters.corrHistScale.eval.continuation.one

        result += Score(self.histories.contCorrHist[prev2.piece.color][prev2.piece.kind][prev2.move.targetSquare][prev.piece.color][prev.piece.kind][prev.move.targetSquare] div scale)

        if ply > 3:
            let prev3 = self.stack[ply - 4]
            scale = self.parameters.corrHistScale.eval.continuation.two

            result += Score(self.histories.contCorrHist[prev3.piece.color][prev3.piece.kind][prev3.move.targetSquare][prev.piece.color][prev.piece.kind][prev.move.targetSquare] div scale)

    result = result.clampEval()


proc updateCorrectionHistories(self: SearchManager, sideToMove: PieceColor, depth, ply: int, bestScore, rawEval, staticEval, beta: Score) =
    let sideToMove = self.board.sideToMove
    let weight = min(depth + 1, 16)

    let
        # For readability
        board = self.board
        params = self.parameters
        hist = self.histories
    for (key, table, minValue, maxValue, scale) in [(board.pawnKey, addr hist.pawnCorrHist, params.corrHistMinValue.pawn,
                                                     params.corrHistMaxValue.pawn, params.corrHistScale.weight.pawn),
                                                    (board.majorKey, addr hist.majorCorrHist, params.corrHistMinValue.major,
                                                     params.corrHistMaxValue.major, params.corrHistScale.weight.major),
                                                    (board.minorKey, addr hist.minorCorrHist, params.corrHistMinValue.minor,
                                                     params.corrHistMaxValue.minor, params.corrHistScale.weight.minor)
                                                   ]:
        var newValue = table[sideToMove].get(key).data.int
        newValue *= max(scale - weight, 1)
        newValue += (bestScore - rawEval) * scale * weight
        newValue = clamp(newValue div scale, minValue, maxValue)
        table[sideToMove].store(key, newValue.int16)
    # Nonpawn history is indexed differently
    for color in White..Black:
        let key      = self.board.nonpawnKey(color)
        var
            minValue = params.corrHistMinValue.nonpawn
            maxValue = params.corrHistMaxValue.nonpawn
            scale    = params.corrHistScale.weight.nonpawn
            newValue = hist.nonpawnCorrHist[sideToMove][color].get(key).data.int
        
        newValue *= max(scale - weight, 1)
        newValue += (bestScore - rawEval) * scale * weight
        newValue = clamp(newValue div scale, minValue, maxValue)
        hist.nonpawnCorrHist[sideToMove][color].store(key, newValue.int16)

    # Continuation correction history is special as well
    if ply > 1:
        let
            prev2 = self.stack[ply - 2]
            prev = self.stack[ply - 1]

        var
            minValue = params.corrHistMinValue.continuation.one
            maxValue = params.corrHistMaxValue.continuation.one
            scale    = params.corrHistScale.weight.continuation.one
            newValue = hist.contCorrHist[prev2.piece.color][prev2.piece.kind][prev2.move.targetSquare][prev.piece.color][prev.piece.kind][prev.move.targetSquare].int

        newValue *= max(scale - weight, 1)
        newValue += (bestScore - rawEval) * scale * weight
        newValue = clamp(newValue div scale, minValue, maxValue)
        hist.contCorrHist[prev2.piece.color][prev2.piece.kind][prev2.move.targetSquare][prev.piece.color][prev.piece.kind][prev.move.targetSquare] = newValue.int16

        if ply > 3:
            let prev3 = self.stack[ply - 4]
            scale = self.parameters.corrHistScale.weight.continuation.two
            newValue = hist.contCorrHist[prev3.piece.color][prev3.piece.kind][prev3.move.targetSquare][prev.piece.color][prev.piece.kind][prev.move.targetSquare].int
            minValue = params.corrHistMinValue.continuation.two
            maxValue = params.corrHistMaxValue.continuation.two

            newValue *= max(scale - weight, 1)
            newValue += (bestScore - rawEval) * scale * weight
            newValue = clamp(newValue div scale, minValue, maxValue)
            hist.contCorrHist[prev3.piece.color][prev3.piece.kind][prev3.move.targetSquare][prev.piece.color][prev.piece.kind][prev.move.targetSquare] = newValue.int16


proc qsearch(self: var SearchManager, root: static bool, ply: int, alpha, beta: Score, isPV: static bool): Score =
    ## Negamax search with a/b pruning that is restricted to
    ## capture moves (commonly called quiescent search). The
    ## purpose of this extra search step is to mitigate the
    ## so called horizon effect that stems from the fact that,
    ## at some point, the engine will have to stop searching,
    ## possibly thinking a bad move is good because it couldn't
    ## see far enough ahead (this usually results in the engine
    ## blundering captures or sacking pieces for apparently no
    ## reason: the reason is that it did not look at the opponent's
    ## responses, because it stopped earlier. That's the horizon). To
    ## address this, we look at all possible captures in the current
    ## position and make sure that a position is evaluated as bad if
    ## only bad capture moves are possible, even if good non-capture
    ## moves exist
    if self.shouldStop() or self.board.isDrawn(ply):
        return Score(0)

    if ply >= MAX_DEPTH:
        return self.staticEval(self.rawEval(), ply)

    when isPV:
        self.statistics.selectiveDepth.store(max(self.statistics.selectiveDepth.load(moRelaxed), ply), moRelaxed)
    let
        query = self.ttable[].get(self.board.zobristKey)
        entry = query.get(TTEntry())
        ttHit = query.isSome()
        hashMove = entry.bestMove
    var wasPV = isPV
    if not wasPV:
        wasPV = entry.flag.wasPV()
    let ttScore = Score(entry.score).decompressScore(ply)
    # We don't care about the depth of cutoffs in qsearch, anything will do
    case entry.flag.bound():
        of NoBound:
            discard
        of Exact:
            return ttScore
        of LowerBound:
            if ttScore >= beta:
                return ttScore
        of UpperBound:
            if ttScore <= alpha:
                return ttScore
    let
        rawEval = if not ttHit: self.rawEval() else: query.get().rawEval
        staticEval = self.staticEval(rawEval, ply)
    self.stack[ply].staticEval = staticEval
    self.stack[ply].inCheck = self.board.inCheck()
    var bestScore = block:
        let flag = entry.flag.bound()
        if flag == Exact or (flag == UpperBound and ttScore < staticEval) or (flag == LowerBound and ttScore > staticEval):
            ttScore
        else:
            staticEval
    if bestScore >= beta:
        # Stand-pat evaluation
        if not bestScore.isMateScore() and not beta.isMateScore():
            bestScore = ((bestScore + beta) div 2).clampEval()
        if not ttHit:
            self.ttable.store(0, bestScore.compressScore(ply), self.board.zobristKey, nullMove(), LowerBound, rawEval.int16, wasPV)
        return bestScore
    var
        alpha = max(alpha, staticEval)
        bestMove = hashMove
    for scoredMove in self.pickMoves(hashMove, ply, qsearch=true):
        let move = scoredMove.move
        let winning = block:
            # We already ran these in scoreMove(), so
            # we don't need to do it again
            if scoredMove.stage() == GoodNoisy:
                true
            elif scoredMove.stage() == BadNoisy:
                false
            else:
                self.parameters.see(self.board.position, move, 0)
        # Skip known bad captures
        if not winning:
            continue
        let
            previous = if ply > 0: self.stack[ply - 1].move else: nullMove()
            recapture = previous != nullMove() and previous.targetSquare == move.targetSquare

        # Qsearch futility pruning: similar to FP in regular search, but we skip moves
        # that gain no material on top of not improving alpha (given a margin)
        if not recapture and not self.stack[ply].inCheck and staticEval + self.parameters.qsearchFpEvalMargin <= alpha and not self.parameters.see(self.board.position, move, 1):
            continue
        let kingSq = self.board.position.kingSquare(self.board.sideToMove)
        self.stack[ply].move = move
        self.stack[ply].piece = self.board.on(move.startSquare)
        self.stack[ply].reduction = 0
        self.evalState.update(move, self.board.sideToMove, self.stack[ply].piece.kind, self.board.on(move.targetSquare).kind, kingSq)
        self.board.doMove(move)
        discard self.statistics.nodeCount.fetchAdd(1, moRelaxed)
        prefetch(addr self.ttable.data[getIndex(self.ttable[], self.board.zobristKey)], cint(0), cint(3))
        let score = -self.qsearch(false, ply + 1, -beta, -alpha, isPV)
        self.board.unmakeMove()
        self.evalState.undo()
        if self.shouldStop():
            return Score(0)
        bestScore = max(score, bestScore)
        if score > alpha:
            alpha = score
            bestMove = move
            when root:
                self.statistics.bestRootScore.store(score, moRelaxed)
                self.statistics.bestMove.store(bestMove, moRelaxed)
        if score >= beta:
            # This move was too good for us, opponent will not search it
            break
    if self.shouldStop():
        return Score(0)
    if self.statistics.currentVariation.load(moRelaxed) == 1:
        # We don't store exact scores because we only look at captures, so our
        # scores are very much *not* exact!
        let nodeType = if bestScore >= beta: LowerBound else: UpperBound
        self.ttable.store(0, bestScore.compressScore(ply), self.board.zobristKey, bestMove, nodeType, rawEval.int16, wasPV)
    return bestScore


func storeKillerMove(self: SearchManager, ply: int, move: Move) {.inline.} =
    # Stolen from https://rustic-chess.org/search/ordering/killers.html

    let first = self.histories.killerMoves[ply][0]
    if first == move:
        return
    var j = self.histories.killerMoves[ply].len() - 2
    while j >= 0:
        # Shift moves one spot down
        self.histories.killerMoves[ply][j + 1] = self.histories.killerMoves[ply][j];
        dec(j)
    self.histories.killerMoves[ply][0] = move


func clearPV(self: var SearchManager, ply: int) {.inline.} =
    self.pvMoves[ply][0] = nullMove()


func clearKillers(self: SearchManager, ply: int) {.inline.} =
    for i in 0..self.histories.killerMoves[ply].high():
        self.histories.killerMoves[ply][i] = nullMove()


proc search(self: var SearchManager, depth, ply: int, alpha, beta: Score, isPV, root: static bool, cutNode: bool, excluded=nullMove()): Score {.discardable, gcsafe.} =
    ## Negamax search with various optimizations and features
    assert alpha < beta
    assert isPV or alpha + 1 == beta

    when isPV:
        self.clearPV(ply)

    if self.shouldStop() or self.board.isDrawn(ply):
        return Score(0)
    
    if ply >= MAX_DEPTH:
        # Prevents the engine from thinking a position that
        # was extended to max ply is drawn when it isn't. This
        # is very very rare, so no need to cache anything
        return self.staticEval(self.rawEval(), ply)
    
    when isPV:
        self.statistics.selectiveDepth.store(max(self.statistics.selectiveDepth.load(moRelaxed), ply), moRelaxed)

    var alpha = alpha
    var beta = beta
    # Mate distance pruning: if we have a proven mate score,
    # reject lines that do not improve upon it
    when not root:
        alpha = max(alpha, matedIn(ply))
        beta = min(beta, mateIn(ply + 1))

        if alpha >= beta:
            return alpha

    # Clearing the next ply's killers makes it so
    # that the killer table is local wrt. to its
    # subtree rather than tree-global. This makes the
    # next killer moves more relevant to our children
    # nodes, because they will only come from their
    # siblings. Idea stolen from Simbelmyne, thanks
    # @sroelants!
    if ply < self.histories.killerMoves.high():
        self.clearKillers(ply + 1)

    let originalAlpha = alpha
    let sideToMove = self.board.sideToMove
    self.stack[ply].inCheck = self.board.inCheck()
    self.stack[ply].reduction = 0
    var depth = min(depth, MAX_DEPTH)
    if self.stack[ply].inCheck:
        # Check extension. We perform it now instead
        # of in the move loop because this avoids us
        # dropping into quiescent search when we are
        # in check
        depth = clamp(depth + 1, 1, MAX_DEPTH)

    if depth <= 0:
        return self.qsearch(root, ply, alpha, beta, isPV)
    let
        isSingularSearch = excluded != nullMove()
        query = self.ttable.get(self.board.zobristKey)
        ttHit = query.isSome()
        entry = query.get(TTEntry())
        ttDepth = entry.depth.int
        hashMove = entry.bestMove
        ttCapture = hashMove.isCapture()
        rawEval = if not ttHit: self.rawEval() else: query.get().rawEval
        staticEval = self.staticEval(rawEval, ply)
        expectFailHigh {.used.} = entry.flag.bound() != UpperBound
        ttScore = Score(entry.score).decompressScore(ply)
        ttAdjustedEval {.used.} = block:
            if ttHit and not isSingularSearch and not self.stack[ply].inCheck:
                case entry.flag.bound():
                    of NoBound:
                        staticEval
                    of Exact:
                        ttScore
                    of LowerBound:
                        if ttScore >= staticEval:
                            ttScore
                        else:
                            staticEval
                    of UpperBound:
                        if ttScore <= staticEval:
                            ttScore
                        else:
                            staticEval
            else:
                staticEval
    var wasPV = isPV
    if not wasPV and ttHit:
        wasPV = entry.flag.wasPV()
    self.stack[ply].staticEval = staticEval
    # If the static eval from this position is greater than that from 2 plies
    # ago (our previous turn), then we are improving our position
    var improving = false
    if ply > 2 and not self.stack[ply].inCheck and not self.stack[ply - 2].inCheck:
        improving = staticEval > self.stack[ply - 2].staticEval
    if not ttHit and not isSingularSearch and not self.stack[ply].inCheck:
        # Cache static eval immediately
        self.ttable.store(depth.uint8, 0, self.board.zobristKey, nullMove(), NoBound, staticEval.int16, wasPV)
    var ttPrune = false
    if ttHit and not isSingularSearch:
        # We can not trust a TT entry score for cutting off
        # this node if it comes from a shallower search than
        # the one we're currently doing, because it will not
        # have looked at all the possibilities
        if ttDepth >= depth:
            case entry.flag.bound():
                of NoBound:
                    discard
                of Exact:
                    ttPrune = true
                of LowerBound:
                    ttPrune = ttScore >= beta
                of UpperBound:
                    ttPrune = ttScore <= alpha
    if ttPrune:
        when not isPV:
            return ttScore
        else:
            # PV nodes are rare and contain a lot of valuable information,
            # so we avoid cutting them off
            depth = clamp(depth - 1, 1, MAX_DEPTH)

    when not root:
        const
            IIR_MIN_DEPTH = 3
            IIR_DEPTH_DIFFERENCE = 4

        if depth >= IIR_MIN_DEPTH and (not ttHit or ttDepth + IIR_DEPTH_DIFFERENCE < depth):
            # Internal iterative reductions: if there is no entry in the TT for
            # this node (or the one we have comes from a much lower depth than the
            # current one), it's not worth it to search it at full depth, so we
            # reduce it and hope that the next search iteration yields better
            # results
            depth = clamp(depth - 1, 1, MAX_DEPTH)
    when not isPV:
        if self.stack[ply - 1].reduction > 0 and not self.stack[ply - 1].inCheck and not self.stack[ply - 1].move.isTactical() and
           (-self.stack[ply - 1].staticEval > self.stack[ply].staticEval) and self.stack[ply].staticEval < alpha:
            # If we are the child of an LMR search, and static eval suggests we might fail low (and so fail high from
            # the parent node's perspective) and we have improved the evaluation from the previous ply, we extend the
            # search depth. The heuristic is limited to non-tactical moves (to avoid eval instability) and from positions
            # that were not previously in check (as static eval is close to useless in those positions)
            depth = clamp(depth + 1, 1, MAX_DEPTH)
        if not wasPV:
            const RFP_DEPTH_LIMIT = 8

            if not self.stack[ply].inCheck and depth <= RFP_DEPTH_LIMIT:
                # Reverse futility pruning: if the static eval suggests a fail high is likely,
                # cut off the node

                let margin = (self.parameters.rfpMargins.base * depth) - self.parameters.rfpMargins.improving * improving.int

                if ttAdjustedEval - margin >= beta:
                    # Instead of returning the static eval, we do something known as "fail mid"
                    # (I prefer "ultra fail retard"), which is supposed to be a better guesstimate
                    # of the positional advantage (and a better-er guesstimate than plain fail medium)
                    return (beta + (ttAdjustedEval - beta) div 3).clampEval()

            const NMP_DEPTH_THRESHOLD = 1

            if depth > NMP_DEPTH_THRESHOLD and staticEval >= beta and ply >= self.minNmpPly and
               (not ttHit or expectFailHigh or ttScore >= beta) and self.board.canNullMove():
                # Null move pruning: it is reasonable to assume that
                # it is always better to make a move than not to do
                # so (with some exceptions noted below). To take advantage
                # of this assumption, we bend the rules a little and perform
                # a so-called "null move", basically passing our turn doing
                # nothing, and then perform a shallower search for our opponent.
                # If the shallow search fails high (i.e. produces a beta cutoff),
                # then it is useless for us to search this position any further,
                # and we can just return the score outright. Since we only care about
                # whether the opponent can beat beta and not the actual value, we
                # can do a null window search and save some time, too
                let
                    friendlyPawns = self.board.pieces(Pawn, sideToMove)
                    friendlyKing = self.board.pieces(King, sideToMove)
                    friendlyPieces = self.board.pieces(sideToMove)
                if not (friendlyPieces and not (friendlyKing or friendlyPawns)).isEmpty():
                    # NMP is disabled in endgame positions where only kings
                    # and (friendly) pawns are left because those are the ones
                    # where it is most likely that the null move assumption will
                    # not hold true due to zugzwang. This assumption doesn't always
                    # hold true however, and at higher depths we will do a verification
                    # search by disabling NMP for a few plies to check whether we can
                    # actually prune the node or not, regardless of what's on the board
                    self.board.makeNullMove()
                    const
                        NMP_BASE_REDUCTION = 4
                        NMP_DEPTH_REDUCTION = 3
                        NMP_EVAL_DEPTH_MAX_REDUCTION = 3
                    var reduction = NMP_BASE_REDUCTION + depth div NMP_DEPTH_REDUCTION
                    reduction += min((staticEval - beta) div self.parameters.nmpEvalDivisor, NMP_EVAL_DEPTH_MAX_REDUCTION)
                    let score = -self.search(depth - reduction, ply + 1, -beta - 1, -beta, isPV=false, root=false, cutNode=not cutNode)
                    self.board.unmakeMove()
                    if self.shouldStop():
                        return Score(0)
                    if score >= beta:
                        const NMP_VERIFICATION_THRESHOLD = 14

                        # Note: yoinked from Stormphrax
                        if depth <= NMP_VERIFICATION_THRESHOLD or self.minNmpPly > 0:
                            return (if not score.isMateScore(): score else: beta)

                        # Verification search: we run a search for our side on the position
                        # before null-moving, taking care of disabling NMP for the next few
                        # plies. We only prune if this search fails high as well

                        const
                            NMP_MIN_DISABLED_PLY_MULT = 3
                            NMP_MIN_DISABLED_PLY_DIVISOR = 4
                        self.minNmpPly = ply + (depth - reduction) * NMP_MIN_DISABLED_PLY_MULT div NMP_MIN_DISABLED_PLY_DIVISOR
                        let verifiedScore = self.search(depth - reduction, ply, beta - 1, beta, isPV=false, root=false, cutNode=true)
                        # Re-enable NMP
                        self.minNmpPly = 0
                        # Verification search failed high: we're safe to prune
                        if verifiedScore >= beta:
                            return (if not verifiedScore.isMateScore(): verifiedScore else: beta)
    var
        bestMove = nullMove()
        bestScore = -SCORE_INF
        # playedMoves counts how many moves we called makeMove() on, while
        # seenMoves counts how many moves were yielded by the move picker
        playedMoves = 0
        seenMoves = 0
        # Quiet moves that failed low
        failedQuiets = newMoveList()
        # The pieces that moved for each failed
        # quiet move in the above list
        failedQuietPieces {.noinit.}: array[MAX_MOVES, Piece]
        failedCaptures = newMoveList()
    for (move, _) in self.pickMoves(hashMove, ply):
        when root:
            if self.searchMoves.len() > 0 and move notin self.searchMoves:
                continue
        if move == excluded:
            # No counters are incremented when we encounter excluded
            # moves because we act as if they don't exist
            continue
        let
            nodesBefore {.used.} = self.statistics.nodeCount.load(moRelaxed)
            # Ensures we don't prune moves that stave off checkmate
            isNotMated {.used.} = not bestScore.isLossScore()
            # We make move loop pruning decisions based on a depth that is
            # closer to the one the move is likely to actually be searched at
            lmrDepth {.used.} = depth - self.lmrTable[depth][seenMoves]
        when not isPV:
            const FP_DEPTH_LIMIT = 7
            
            let margin = self.parameters.fpEvalOffset + self.parameters.fpEvalMargin * (depth + improving.int)

            if isNotMated and move.isQuiet() and lmrDepth <= FP_DEPTH_LIMIT and staticEval + margin <= alpha:
                # Futility pruning: If a (quiet) move cannot meaningfully improve alpha, prune it from the
                # tree
                inc(seenMoves)
                continue
        when not root:
            if isNotMated:
                const
                    LMP_DEPTH_OFFSET = 4
                    LMP_DEPTH_MULTIPLIER = 1

                if move.isQuiet() and playedMoves >= (LMP_DEPTH_OFFSET + LMP_DEPTH_MULTIPLIER * depth * depth) div (2 - improving.int):
                    # Late move pruning: prune moves when we've played enough of them (assumes the move
                    # orderer did a good job)
                    inc(seenMoves)
                    continue

                const SEE_PRUNING_MAX_DEPTH = 5

                if lmrDepth <= SEE_PRUNING_MAX_DEPTH and (move.isQuiet() or move.isCapture() or move.isEnPassant()):
                    # SEE pruning: prune moves with a bad enough SEE score
                    let margin = -depth * (if move.isQuiet(): self.parameters.seePruningMargin.quiet else: self.parameters.seePruningMargin.capture)
                    if not self.parameters.see(self.board.position, move, margin):
                        inc(seenMoves)
                        continue
        var singular = 0
        when not root:
            const
                SE_MIN_DEPTH = 4
                SE_DEPTH_OFFSET = 4

            if not isSingularSearch and depth > SE_MIN_DEPTH and expectFailHigh and move == hashMove and ttDepth + SE_DEPTH_OFFSET >= depth:
                # Singular extensions. If there is a TT move and we expect the node to fail high, we do a null
                # window shallower search (using a new beta derived from the TT score) that excludes the TT move
                # to verify whether it is the only good move: if the search fails low, then said move is "singular",
                # and it is searched with an increased depth

                const
                    SE_DEPTH_MULTIPLIER = 1
                    SE_REDUCTION_OFFSET = 1
                    SE_REDUCTION_DIVISOR = 2
                let
                    newBeta = Score(ttScore - SE_DEPTH_MULTIPLIER * depth)
                    newAlpha = Score(newBeta - 1)
                    newDepth = (depth - SE_REDUCTION_OFFSET) div SE_REDUCTION_DIVISOR
                    # This is basically a big comparison, asking "is there any move better than the TT move?"
                    singularScore = self.search(newDepth, ply, newAlpha, newBeta, isPV=false, root=false, cutNode=cutNode, excluded=hashMove)
                if singularScore < newBeta:
                    # Search failed low, hash move is singular: explore it deeper
                    inc(singular)
                    when not isPV:
                        # We restrict greater extensions to non-pv nodes. The consensus
                        # on this seems to be that it avoids search explosions (it can
                        # apparently be done in pv nodes with much tighter margins)

                        # Multiple extensions. Hash move is increasingly singular: explore it
                        # even deeper
                        for margin in [self.parameters.doubleExtMargin, self.parameters.tripleExtMargin]:
                            if singularScore <= newAlpha - margin:
                                inc(singular)
                elif newBeta >= beta:
                    # Singular beta suggests a fail high and the move is not singular:
                    # cut off the node
                    return newBeta
                # Negative extensions: hash move is not singular, but various conditions
                # suggest a cutoff is likely, so we reduce the search depth
                elif ttScore >= beta:
                    singular = -2
                elif cutNode:
                    singular = -2
        self.stack[ply].move = move
        self.stack[ply].piece = self.board.on(move.startSquare)
        let kingSq = self.board.position.kingSquare(self.board.sideToMove)
        self.evalState.update(move, self.board.sideToMove, self.stack[ply].piece.kind, self.board.on(move.targetSquare).kind, kingSq)
        let reduction = self.getReduction(move, depth, ply, seenMoves, isPV, improving, wasPV, ttCapture, cutNode)
        self.stack[ply].reduction = reduction
        self.board.doMove(move)
        discard self.statistics.nodeCount.fetchAdd(1, moRelaxed)
        var score: Score
        # Prefetch next TT entry: 0 means read, 3 means the value has high temporal locality
        # and should be kept in all possible cache levels if possible
        prefetch(addr self.ttable.data[getIndex(self.ttable[], self.board.zobristKey)], cint(0), cint(3))
        # Implementation of Principal Variation Search (PVS)
        if seenMoves == 0:
            # Due to our move ordering scheme, the first move is assumed to be the best, so
            # search it always at full depth with the full search window
            score = -self.search(depth - 1 + singular, ply + 1, -beta, -alpha, isPV, false, when isPV: false else: not cutNode)
        elif reduction > 0:
            # Late Move Reductions: assume our move orderer did a good job,
            # so it is not worth it to look at all moves at the same depth equally.
            # If this move turns out to be better than we expected, we'll re-search
            # it at full depth

            # We first do a null-window reduced search to see if there's a move that beats alpha
            # (we don't care about the actual value, so we search in the range [alpha, alpha + 1]
            # to increase the number of cutoffs)
            score = -self.search(depth - 1 - reduction, ply + 1, -alpha - 1, -alpha, isPV=false, root=false, cutNode=true)
            # If the null window reduced search beats alpha, we redo the search with the same alpha
            # beta bounds without the reduction, to get a better feel for the actual score of the position.
            # If the score turns out to beat alpha (but not beta) again, we'll re-search this with a full
            # window later
            if score > alpha:
                score = -self.search(depth - 1, ply + 1, -alpha - 1, -alpha, isPV=false, root=false, cutNode=not cutNode)
        else:
            # Move wasn't reduced, just do a null window search
            score = -self.search(depth - 1, ply + 1, -alpha - 1, -alpha, isPV=false, root=false, cutNode=not cutNode)
        if seenMoves > 0 and score > alpha and score < beta:
            # The position beat alpha (and not beta, which would mean it was too good for us and
            # our opponent wouldn't let us play it) in the null window search: search it again
            # with the full depth and full window. Note to future self: alpha and beta are integers,
            # so in a non-pv node it's never possible that this condition is triggered since there's
            # no value between alpha and beta (which is alpha + 1)
            score = -self.search(depth - 1, ply + 1, -beta, -alpha, isPV, root=false, cutNode=false)
        if self.shouldStop():
            self.evalState.undo()
            self.board.unmakeMove()
            return Score(0)
        inc(playedMoves)
        inc(seenMoves)
        when root:
            let nodesAfter = self.statistics.nodeCount.load(moRelaxed)
            self.statistics.spentNodes[move.startSquare][move.targetSquare].atomicInc(nodesAfter - nodesBefore)
        self.board.unmakeMove()
        self.evalState.undo()
        bestScore = max(score, bestScore)
        if score <= alpha and score < beta:
            if move.isQuiet():
                failedQuiets.add(move)
                failedQuietPieces[failedQuiets.high()] = self.stack[ply].piece
            elif move.isCapture():
                failedCaptures.add(move)
        if score > alpha:
            # We found a new best move
            alpha = score
            bestMove = move
            when root:
                self.statistics.bestRootScore.store(score, moRelaxed)
                self.statistics.bestMove.store(bestMove, moRelaxed)
            if score < beta:
                when isPV:
                    # This loop is why pvMoves has one extra move.
                    # We can just do ply + 1 and i + 1 without ever
                    # fearing about buffer overflows
                    for i, pvMove in self.pvMoves[ply + 1]:
                        self.pvMoves[ply][i + 1] = pvMove
                        if pvMove == nullMove():
                            break
                    self.pvMoves[ply][0] = move
        if score >= beta:
            # This move was too good for us, opponent will not search it
            when not root:
                if not (move.isCapture() or move.isEnPassant()):
                    # Countermove heuristic: we assume that most moves have a natural
                    # response irrespective of the actual position and store them in a
                    # table indexed by the from/to squares of the previous move
                    let prevMove = self.stack[ply - 1].move
                    self.histories.counterMoves[prevMove.startSquare][prevMove.targetSquare] = move

            let histDepth = depth + (bestScore - beta > self.parameters.historyDepthEvalThreshold).int
            # If the best move we found is a tactical move, we don't want to punish quiets,
            # because they still might be good (just not as good wrt the best move).
            # Very important to note that move == bestMove here!
            if move.isQuiet():
                # Give a bonus to the quiet move that failed high so that we find it faster later
                self.updateHistories(sideToMove, move, self.stack[ply].piece, histDepth, ply, true)
                # Punish quiet moves coming before this one such that they are placed later in the
                # list in subsequent searches and we manage to cut off faster
                for i, quiet in failedQuiets:
                    self.updateHistories(sideToMove, quiet, failedQuietPieces[i], histDepth, ply, false)
                # Killer move heuristic: store quiets that caused a beta cutoff according to the distance from
                # root that they occurred at, as they might be good refutations for future moves from the opponent
                self.storeKillerMove(ply, move)

            # It doesn't make a whole lot of sense to give a bonus to a capture
            # if the best move is a quiet move, does it? (This is also why we
            # don't give a bonus to quiets if the best move is a tactical move)
            if move.isCapture():
                self.updateHistories(sideToMove, move, nullPiece(), histDepth, ply, true)

            # We always apply the malus to captures regardless of what the best
            # move is because if a quiet manages to beat all previously seen captures
            # we still want to punish them, otherwise we'd think they're better than
            # they actually are
            for capture in failedCaptures:
                self.updateHistories(sideToMove, capture, nullPiece(), histDepth, ply, false)
            break
    if seenMoves == 0:
        # Terminal node: checkmate or stalemate
        if isSingularSearch:
            return alpha
        elif self.stack[ply].inCheck:
            return matedIn(ply)
        # Stalemate
        return Score(0)
    let nodeType = if bestScore >= beta: LowerBound elif bestScore <= originalAlpha: UpperBound else: Exact

    if not self.board.inCheck() and (bestMove == nullMove() or bestMove.isQuiet()) and (
        nodeType == Exact or (nodeType == LowerBound and bestScore > staticEval) or
        (nodeType == UpperBound and bestScore <= staticEval)
    ):
        self.updateCorrectionHistories(sideToMove, depth, ply, bestScore, rawEval, staticEval, beta)


    # If the whole node failed low, we preserve the previous hash move
    if bestMove == nullMove():
        bestMove = hashMove
    # Don't store in the TT during a singular search. We also don't overwrite
    # the entry in the TT for the root node to avoid poisoning the original
    # score
    if not isSingularSearch and (not root or self.statistics.currentVariation.load(moRelaxed) == 1) and not self.expired and not self.stopped():
        self.ttable.store(depth.uint8, bestScore.compressScore(ply), self.board.zobristKey, bestMove, nodeType, staticEval.int16, wasPV)

    return bestScore


proc startClock*(self: var SearchManager) =
    ## Starts the manager's internal clock.
    ## If we're not the main thread, or the
    ## clock was already started, this is a
    ## no-op
    if not self.state.isMainThread.load(moRelaxed) or self.clockStarted:
        return
    self.state.searchStart.store(getMonoTime(), moRelaxed)
    self.limiter.resetHardLimit()
    self.clockStarted = true


proc aspirationSearch(self: var SearchManager, depth: int, score: Score): Score {.inline.} =
    var
        delta = Score(self.parameters.aspWindowInitialSize)
        alpha = max(-SCORE_INF, score - delta)
        beta = min(SCORE_INF, score + delta)
        reduction = 0
        score = score
    let mateDepth = self.state.mateDepth.load(moRelaxed).get(0)
    if mateDepth > 0:
        alpha = mateIn(mateDepth * 2 - 1)
        beta = mateIn(0)
    var fullWindow = false
    while true:
        score = self.search(depth - reduction, 0, alpha, beta, true, true, false)
        if delta == SCORE_INF:
            # FIXME: For some mysterious reason heimdall seems to
            # be losing on time when low on time with many threads (like 200+).
            # The likely culprit is this while loop failing to exit.
            # We check if the delta is equal to the maximum score because
            # if we searched with the full window we can exit. This should
            # already be handled by the else clause at the end of the loop,
            # but ¯\_(ツ)_/¯
            if fullWindow:
                break
            fullWindow = true
        if self.shouldStop():
            break
        # Score is outside window bounds, widen the one that
        # we got past to get a better result
        if score <= alpha:
            alpha = max(-SCORE_INF, score - delta)
            # Grow the window downward as well when we fail
            # low (cuts off faster)
            beta = (alpha + beta) div 2
            # Reset the reduction whenever we fail low to ensure
            # we don't miss good stuff that seems bad at first
            reduction = 0
        elif score >= beta:
            beta = min(SCORE_INF, score + delta)
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
            delta = SCORE_INF
    return score


proc search*(self: var SearchManager, searchMoves: seq[Move] = @[], silent=false, ponder=false, minimal=false, variations=1): seq[ChessVariation] =
    ## Begins a search. The time this call takes is limited
    ## according the the manager's limiter configuration. If
    ## ponder equals true, the search will ignore all limits
    ## until the stopPondering() procedure is called, after
    ## which search will be limited as if they were imposed
    ## from the moment after the call. If silent equals true,
    ## search logs will not be printed. If variations > 1, the
    ## specified number of alternative variations (up to MAX_MOVES)
    ## is searched (note that time and node limits are shared across
    ## all of them), and they are all returned. The number of alternative
    ## variations is always clamped to the number of legal moves available
    ## on the board or (when provided), the specified number of root moves
    ## to search, whichever is smallest. If searchMoves is nonempty, only
    ## the specified set of root moves is considered (the moves in the list
    ## are assumed to be legal). If minimal is true and logs are not silenced,
    ## only the final log message is printed. If getWorkerCount() is > 0, the
    ## search is performed by the calling thread plus that many additional threads
    ## in parallel
    if ponder:
        self.limiter.disable()
    else:
        # Just in case it was disabled earlier
        self.limiter.enable()
    if silent:
        self.logger.disable()
    else:
        self.logger.enable()

    self.startClock()
    self.state.pondering.store(ponder, moRelaxed)
    self.searchMoves = searchMoves
    self.statistics.nodeCount.store(0, moRelaxed)
    self.statistics.highestDepth.store(0, moRelaxed)
    self.statistics.selectiveDepth.store(0, moRelaxed)
    self.statistics.bestRootScore.store(0, moRelaxed)
    self.statistics.bestMove.store(nullMove(), moRelaxed)
    self.statistics.currentVariation.store(0, moRelaxed)
    self.state.stop.store(false, moRelaxed)
    self.state.searching.store(true, moRelaxed)
    self.state.cancelled.store(false, moRelaxed)
    self.expired = false

    for i in Square.all():
        for j in Square.all():
            self.statistics.spentNodes[i][j].store(0, moRelaxed)

    var score = Score(0)
    var bestMoves: seq[Move] = @[]
    var legalMoves {.noinit.} = newMoveList()
    var variations = min(MAX_MOVES, variations)

    if variations > 1:
        self.board.generateMoves(legalMoves)
        if searchMoves.len() > 0:
            variations = min(variations, searchMoves.len())

    var lastInfoLine = false

    result = newSeq[ChessVariation](variations)
    for i in 0..<variations:
        for j in 0..MAX_DEPTH:
            self.previousLines[i][j] = nullMove()
    for i in 0..<MAX_MOVES:
        self.previousScores[i] = Score(0)

    self.workerPool.startSearch(searchMoves, variations)

    block iterativeDeepening:
        for depth in 1..MAX_DEPTH:
            if self.limiter.expiredSoft():
                break iterativeDeepening
            self.limiter.scale(self.parameters)

            for i in 1..variations:
                self.statistics.selectiveDepth.store(0, moRelaxed)
                self.statistics.currentVariation.store(i, moRelaxed)

                const ASPIRATION_WINDOW_DEPTH_THRESHOLD = 5

                if depth < ASPIRATION_WINDOW_DEPTH_THRESHOLD:
                    score = self.search(depth, 0, -SCORE_INF, SCORE_INF, true, true, false)
                else:
                    # Aspiration windows: start subsequent searches with tighter
                    # alpha-beta bounds and widen them as needed (i.e. when the score
                    # goes beyond the window) to increase the number of cutoffs
                    score = self.aspirationSearch(depth, score)
                if self.shouldStop() or self.pvMoves[0][0] == nullMove():
                    # Search has likely been interrupted mid-tree:
                    # cannot trust partial results
                    lastInfoLine = self.stopped() or self.limiter.hardLimitReached()
                    break iterativeDeepening
                bestMoves.add(self.pvMoves[0][0])
                self.previousLines[i - 1] = self.pvMoves[0]
                result[i - 1] = self.pvMoves[0]
                self.previousScores[i - 1] = score
                self.statistics.highestDepth.store(depth, moRelaxed)
                if not silent and not minimal:
                    self.logger.log(self.pvMoves[0], i)
                if variations > 1:
                    self.searchMoves = searchMoves
                    for move in legalMoves:
                        if searchMoves.len() > 0 and move notin searchMoves:
                            # If the user told us to only search a specific set
                            # of moves, don't override that
                            continue
                        if move in bestMoves:
                            # Don't search the current best move(s) in the next search
                            continue
                        self.searchMoves.add(move)
            bestMoves.setLen(0)

    var stats = self.statistics
    var finalScore = self.previousScores[0]
    if self.state.isMainThread.load(moRelaxed):
        # The main thread is the only one doing time management,
        # so we need to explicitly stop all other workers
        self.stop()

        var bestSearcher = addr self

        # Wait for all workers to stop searching and answer to our pings
        for i, worker in self.workerPool.workers:
            worker.ping()
            # Pick the best result across all of our threads. Logic yoinked from
            # Ethereal
            let
                bestDepth = bestSearcher.statistics.highestDepth.load(moRelaxed)
                bestScore = bestSearcher.statistics.bestRootScore.load(moRelaxed)
                currentDepth = worker.manager.statistics.highestDepth.load(moRelaxed)
                currentScore = worker.manager.statistics.bestRootScore.load(moRelaxed)

            # Thread has the same depth but better score than our best
            # so far or a shorter mate (or longer mated) line than what
            # we currently have
            if (bestDepth == currentDepth and currentScore > bestScore) or (currentScore.isMateScore() and currentScore > bestScore):
                bestSearcher = addr worker.manager

            # Thread has a higher search depth than our best one and does
            # not replace a (closer) mate score
            if currentDepth > bestDepth and (currentScore > bestScore or not bestScore.isMateScore()):
                bestSearcher = addr worker.manager

        if not bestSearcher.state.isMainThread.load(moRelaxed):
            # We picked a different line from the one of the main thread:
            # print the last info line such that it is obvious from the
            # outside
            lastInfoLine = true
            # TODO: Look into whether this fucks up the reporting.
            # Incomplete worker searches could cause issues. Only
            # visual things, but still
            stats = bestSearcher.statistics
            finalScore = bestSearcher.statistics.bestRootScore.load(moRelaxed)
            for i in 0..<result.len():
                result[i] = bestSearcher.previousLines[i]

    if not silent and (lastInfoLine or minimal):
        # Log final info message
        self.logger.log(result[0], 1, some(finalScore), some(stats))

    self.state.searching.store(false, moRelaxed)
    self.state.pondering.store(false, moRelaxed)
    self.clockStarted = false

