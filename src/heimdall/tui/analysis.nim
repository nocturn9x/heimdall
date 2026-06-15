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

## Search integration for the TUI: background search thread + live polling

import std/[atomics, options, monotimes, times, strformat]

import heimdall/[board, moves, pieces, search, position, eval, movegen]
import heimdall/util/limits
import heimdall/tui/state


proc buildAnalysisLimits(state: AppState): seq[SearchLimit] =
    if state.analysis.depthLimit.isSome():
        result.add(newDepthLimit(state.analysis.depthLimit.get()))
    if state.analysis.mateLimit.isSome():
        result.add(newMateLimit(state.analysis.mateLimit.get()))


proc buildReplayPositions(state: AppState): seq[Position] =
    if state.mode != ModeReplay or state.replay.startPosition.isNone():
        return @[]

    var board = newChessboard(@[state.replay.startPosition.get().clone()])
    result.add(board.position.clone())
    for move in state.replay.moves:
        discard board.makeMove(move)
        result.add(board.position.clone())


proc searchWorkerLoop*(statePtr: ptr AppState) {.thread.} =
    ## Background search thread. Listens for commands on the channel
    ## and executes searches.
    let state = statePtr[]

    while true:
        let cmd = state.channels.command.recv()

        case cmd.kind:
            of Shutdown:
                state.channels.response.send(Exiting)
                break

            of StopSearch:
                state.searcher.cancel()
                if not state.searcher.isSearching():
                    state.channels.response.send(SearchComplete)

            of StartAnalysis:
                # Configure for infinite analysis (always uses primary engine)
                state.searcher.limiter.clear()
                state.searcher.state.mateDepth.store(cmd.analysisMateDepth, moRelaxed)
                for limit in cmd.analysisLimits:
                    state.searcher.limiter.addLimit(limit)
                state.searcher.setBoard(cmd.analysisPositions)
                state.searcher.setUCIMode(true)

                let pvLines = state.searcher.search(silent=true, variations=cmd.analysisVariations)

                var lines: seq[AnalysisLine]
                let depth = state.searcher.statistics.highestDepth.load(moRelaxed)
                for i, variation in pvLines:
                    var moves: seq[Move]
                    for move in variation.moves:
                        if move == nullMove(): break
                        moves.add(move)
                    if moves.len > 0:
                        lines.add(AnalysisLine(pv: moves, score: variation.score, depth: depth))
                state.pvChannel.send(lines)

                state.channels.response.send(SearchComplete)

            of StartGameAnalysis:
                state.searcher.limiter.clear()
                state.searcher.state.mateDepth.store(cmd.gameMateDepth, moRelaxed)
                state.searcher.setUCIMode(true)

                var currentPrefix: seq[Position]
                var previousIndex = -1

                for ply in cmd.gameOrder:
                    if ply < 0 or ply >= cmd.gamePositions.len:
                        continue

                    if previousIndex < 0:
                        currentPrefix = @[]
                        for idx in 0..ply:
                            currentPrefix.add(cmd.gamePositions[idx].clone())
                    elif ply > previousIndex:
                        for idx in previousIndex + 1..ply:
                            currentPrefix.add(cmd.gamePositions[idx].clone())
                    elif ply < previousIndex:
                        currentPrefix.setLen(ply + 1)

                    previousIndex = ply
                    state.searcher.limiter.clear()
                    state.searcher.state.mateDepth.store(cmd.gameMateDepth, moRelaxed)
                    for limit in cmd.gameLimits:
                        state.searcher.limiter.addLimit(limit)
                    state.searcher.setBoard(currentPrefix)

                    let variations = state.searcher.search(silent=true, variations=1)
                    if state.searcher.cancelled():
                        break

                    let stm = currentPrefix[^1].sideToMove
                    let material = currentPrefix[^1].material()

                    var rawStmScore = state.searcher.statistics.bestRootScore.load(moRelaxed)
                    var bestMove = state.searcher.statistics.bestMove.load(moRelaxed)
                    if variations.len > 0:
                        rawStmScore = variations[0].score
                        if variations[0].moves[0] != nullMove():
                            bestMove = variations[0].moves[0]

                    let rawWhiteScore = if stm == Black: -rawStmScore else: rawStmScore
                    let displayScore = state.displayScore(rawWhiteScore, material)
                    let totalNodes = state.searcher.limiter.totalNodes()
                    let elapsedMs = (getMonoTime() - state.searcher.state.searchStart.load(moRelaxed)).inMilliseconds()
                    let nps =
                        if elapsedMs > 0:
                            (totalNodes * 1000) div elapsedMs.uint64
                        else:
                            0'u64

                    state.gameAnalysisChannel.send(GameAnalysisProgress(
                        ply: ply,
                        positionKey: currentPrefix[^1].zobristKey.uint64,
                        score: displayScore,
                        rawScore: rawWhiteScore,
                        material: material,
                        sideToMove: stm,
                        depth: state.searcher.statistics.highestDepth.load(moRelaxed),
                        nps: nps,
                        nodes: totalNodes,
                        bestMove: bestMove
                    ))

                state.channels.response.send(SearchComplete)

            of StartEngineMove:
                state.searcher.limiter.clear()
                state.searcher.state.mateDepth.store(none(int), moRelaxed)
                for limit in cmd.engineLimits:
                    state.searcher.limiter.addLimit(limit)
                state.searcher.setBoard(cmd.enginePositions)
                state.searcher.setUCIMode(true)
                discard state.searcher.search(silent=true, ponder=cmd.ponder, variations=1)

                state.channels.response.send(SearchComplete)

proc startSearchWorker*(state: AppState) =
    ## Spawns the primary background search thread
    var statePtr = create(AppState)
    statePtr[] = state
    createThread(state.searchWorkerThread, searchWorkerLoop, statePtr)


proc stopSearch*(state: AppState) =
    ## Cancels any running search
    if state.searcher.isSearching():
        state.searcher.cancel()


proc drainPVChannel(state: AppState)


proc waitForPrimarySearchIdle(state: AppState) =
    ## Waits for the primary search worker to go idle without blocking forever
    ## if the search already completed and its SearchComplete message was
    ## consumed by the polling loop.
    while true:
        let (hasData, response) = state.channels.response.tryRecv()
        if hasData:
            case response:
                of SearchComplete, Exiting:
                    return
        elif not state.searcher.isSearching():
            return
        else:
            let response = state.channels.response.recv()
            case response:
                of SearchComplete, Exiting:
                    return


proc startAnalysis*(state: AppState) =
    ## Starts continuous analysis on the current position
    if state.analysis.running:
        # Stop current analysis first
        stopSearch(state)
        waitForPrimarySearchIdle(state)

    state.analysis.running = true
    discard state.restoreCachedAnalysis()
    # Clone positions since Position can't be copied
    var positions: seq[Position]
    for pos in state.board.positions:
        positions.add(pos.clone())
    let cmd = SearchCommand(
        kind: StartAnalysis,
        analysisPositions: positions,
        analysisVariations: state.analysis.multiPV,
        analysisLimits: buildAnalysisLimits(state),
        analysisMateDepth: state.analysis.mateLimit
    )
    state.channels.command.send(cmd)


proc stopAnalysis*(state: AppState) =
    ## Stops continuous analysis
    if not state.analysis.running:
        return

    stopSearch(state)
    waitForPrimarySearchIdle(state)
    state.analysis.running = false


proc drainGameAnalysisChannel(state: AppState) =
    while true:
        let (has, _) = state.gameAnalysisChannel.tryRecv()
        if not has:
            break


proc applyPendingGameAnalysisProgress(state: AppState) =
    while true:
        let (hasProgress, progress) = state.gameAnalysisChannel.tryRecv()
        if not hasProgress:
            break
        if progress.ply < 0 or progress.ply >= state.gameAnalysis.positions.len:
            continue
        let wasAnalyzed = state.gameAnalysis.positions[progress.ply].analyzed
        state.gameAnalysis.positions[progress.ply] = GameAnalysisPosition(
            analyzed: true,
            positionKey: progress.positionKey,
            score: progress.score,
            rawScore: progress.rawScore,
            material: progress.material,
            sideToMove: progress.sideToMove,
            depth: progress.depth,
            nps: progress.nps,
            nodes: progress.nodes,
            bestMove: progress.bestMove
        )
        if not wasAnalyzed:
            inc state.gameAnalysis.completedPositions


proc startGameAnalysis*(state: AppState) =
    if state.mode != ModeReplay:
        state.setError("Computer analysis is only available in replay mode")
        return
    if state.replay.moves.len == 0 or state.replay.startPosition.isNone():
        state.setError("Load a PGN first")
        return
    if state.gameAnalysis.running:
        state.setError("Computer analysis is already running. Use :stop first.")
        return

    if state.analysis.running:
        stopAnalysis(state)

    let gamePositions = buildReplayPositions(state)
    if gamePositions.len == 0:
        state.setError("Could not build replay positions")
        return

    state.clearAnalysisPrompt()
    state.dismissStatus()
    state.clearAnalysisDisplay()
    state.clearGameAnalysis()
    state.gameAnalysis.totalPositions = gamePositions.len
    state.gameAnalysis.running = true
    state.gameAnalysis.division = classifyGameAnalysisDivision(gamePositions)
    state.gameAnalysis.positions = newSeq[GameAnalysisPosition](gamePositions.len)
    for i in 0..gamePositions.high:
        state.gameAnalysis.positions[i] = GameAnalysisPosition(
            positionKey: gamePositions[i].zobristKey.uint64,
            material: gamePositions[i].material(),
            sideToMove: gamePositions[i].sideToMove
        )

    var order: seq[int]
    case state.gameAnalysis.direction:
        of GameAnalysisReverse:
            for ply in countdown(gamePositions.high, 0):
                order.add(ply)
        of GameAnalysisForward:
            for ply in 0..gamePositions.high:
                order.add(ply)

    drainPVChannel(state)
    drainGameAnalysisChannel(state)
    state.channels.command.send(SearchCommand(
        kind: StartGameAnalysis,
        gamePositions: gamePositions,
        gameOrder: order,
        gameLimits: state.gameAnalysis.limits,
        gameMateDepth: state.gameAnalysis.mateLimit
    ))


proc stopGameAnalysis*(state: AppState) =
    if not state.gameAnalysis.running:
        return

    stopSearch(state)
    waitForPrimarySearchIdle(state)
    applyPendingGameAnalysisProgress(state)
    state.gameAnalysis.running = false


proc toggleAnalysis*(state: AppState) =
    ## Toggles analysis on/off
    if state.analysis.running:
        stopAnalysis(state)
        state.setStatus("Analysis stopped")
    else:
        if state.gameAnalysis.running:
            state.setError("Stop the computer analysis first")
            return
        startAnalysis(state)
        state.setStatus("Analysis started")


proc drainPVChannel(state: AppState) =
    ## Drains any pending PV data from the channel
    while true:
        let (has, _) = state.pvChannel.tryRecv()
        if not has: break


proc restartAnalysis*(state: AppState) =
    ## Restarts analysis if it's running (e.g. after a position change)
    if state.analysis.running:
        stopSearch(state)
        waitForPrimarySearchIdle(state)
        drainPVChannel(state)
        discard state.restoreCachedAnalysis()
        var positions: seq[Position]
        for pos in state.board.positions:
            positions.add(pos.clone())
        let cmd = SearchCommand(
            kind: StartAnalysis,
            analysisPositions: positions,
            analysisVariations: state.analysis.multiPV,
            analysisLimits: buildAnalysisLimits(state),
            analysisMateDepth: state.analysis.mateLimit
        )
        state.channels.command.send(cmd)


proc pollSearchResults*(state: AppState) =
    ## Non-blocking poll of search statistics for live display updates.
    ## Called every frame from the main event loop.
    applyPendingGameAnalysisProgress(state)

    if not state.analysis.running and not state.play.engineThinking and not state.gameAnalysis.running:
        return

    if state.analysis.running or state.play.engineThinking:
        # Read atomic statistics, aggregating node counts from all threads
        let stats = state.searcher.statistics
        let totalNodes = state.searcher.limiter.totalNodes()
        state.analysis.nodes = totalNodes
        state.analysis.depth = stats.highestDepth.load(moRelaxed)

        # Compute NPS from total nodes across all threads
        let startTime = state.searcher.state.searchStart.load(moRelaxed)
        let elapsedMs = (getMonoTime() - startTime).inMilliseconds()
        if elapsedMs > 0:
            state.analysis.nps = (totalNodes * 1000) div elapsedMs.uint64

        # Read best score
        let bestScore = stats.bestRootScore.load(moRelaxed)
        let bestMove = stats.bestMove.load(moRelaxed)

        # Read live per-variation data from atomics.
        # Scores from the search are STM-relative (positive = good for side to move).
        # We store them as white-relative for display, but sort by STM-relative (best for current player first).
        let varCount = stats.variationCount.load(moRelaxed)
        let sideToMove = state.board.sideToMove()
        let material = state.board.material()

        proc toDisplayScore(rawStmScore: Score, stm: PieceColor, mat: int): Score =
            ## Converts a raw STM-relative score to the configured white-relative display score.
            let rawWhiteScore = if stm == Black: -rawStmScore else: rawStmScore
            state.displayScore(rawWhiteScore, mat)

        if varCount > 0:
            # Ensure we have enough slots
            while state.analysis.lines.len < state.analysis.multiPV:
                state.analysis.lines.add(AnalysisLine())

            # Collect raw scores for sorting
            type ScoredVar = tuple[idx: int, rawScore: Score]
            var scored: seq[ScoredVar]

            for i in 0..<varCount:
                let vScore = stats.variationScores[i].load(moRelaxed)
                let vMove = stats.variationMoves[i].load(moRelaxed)
                if vMove != nullMove():
                    scored.add((idx: i, rawScore: vScore))
                    # Read the full PV from previousVariations (safe on x86:
                    # if the atomic variationCount write is visible, preceding
                    # non-atomic writes to previousVariations are too)
                    var pvMoves: seq[Move]
                    for m in state.searcher.previousVariations[i].moves:
                        if m == nullMove(): break
                        pvMoves.add(m)
                    if pvMoves.len == 0:
                        pvMoves = @[vMove]
                    state.analysis.lines[i] = AnalysisLine(
                        pv: pvMoves,
                        score: toDisplayScore(vScore, sideToMove, material),
                        rawScore: vScore,
                        depth: state.analysis.depth
                    )
                    state.analysis.linesPositionKey = state.board.zobristKey().uint64

            # Sort by raw STM score descending (best for side to move first)
            for i in 0..<scored.len:
                for j in i+1..<scored.len:
                    if scored[j].rawScore > scored[i].rawScore:
                        swap(scored[i], scored[j])

            # Reorder analysisLines to match sorted order
            var sorted: seq[AnalysisLine]
            for sv in scored:
                sorted.add(state.analysis.lines[sv.idx])
            # Keep any remaining old lines that weren't updated this iteration
            for i in sorted.len..<min(state.analysis.lines.len, state.analysis.multiPV):
                sorted.add(state.analysis.lines[i])
            state.analysis.lines = sorted
            state.storeCurrentAnalysisSnapshot()

        elif bestMove != nullMove():
            let displayScore = toDisplayScore(bestScore, sideToMove, material)
            if state.analysis.lines.len == 0:
                state.analysis.lines = @[AnalysisLine(pv: @[bestMove], score: displayScore, rawScore: bestScore, depth: state.analysis.depth)]
            else:
                state.analysis.lines[0] = AnalysisLine(pv: @[bestMove], score: displayScore, rawScore: bestScore, depth: state.analysis.depth)
            state.analysis.linesPositionKey = state.board.zobristKey().uint64
            state.storeCurrentAnalysisSnapshot()

        # Check for full MultiPV results from the worker (richer PV data after search completes)
        let (hasPV, pvLines) = state.pvChannel.tryRecv()
        if hasPV and pvLines.len > 0:
            # pvLines scores are raw STM-relative from the search; sort and normalize
            type ScoredPV = tuple[idx: int, rawScore: Score]
            var scoredPV: seq[ScoredPV]
            for i, line in pvLines:
                scoredPV.add((idx: i, rawScore: line.score))
            for i in 0..<scoredPV.len:
                for j in i+1..<scoredPV.len:
                    if scoredPV[j].rawScore > scoredPV[i].rawScore:
                        swap(scoredPV[i], scoredPV[j])
            var sortedPV: seq[AnalysisLine]
            for sv in scoredPV:
                var line = pvLines[sv.idx]
                line.rawScore = sv.rawScore
                line.score = toDisplayScore(sv.rawScore, sideToMove, material)
                sortedPV.add(line)
            state.analysis.lines = sortedPV
            state.analysis.linesPositionKey = state.board.zobristKey().uint64
            state.storeCurrentAnalysisSnapshot()

        state.storeCurrentAnalysisSnapshot()

    # Check for search completion (non-blocking) on primary channel
    let (hasData, response) = state.channels.response.tryRecv()
    if hasData:
        case response:
            of SearchComplete:
                if state.play.engineThinking:
                    state.play.engineThinking = false
                if state.gameAnalysis.running:
                    state.gameAnalysis.running = false
                    if state.gameAnalysis.completedPositions >= state.gameAnalysis.totalPositions:
                        state.setStatus(&"Computer analysis complete ({state.gameAnalysis.completedPositions}/{state.gameAnalysis.totalPositions} positions)")
                    else:
                        state.setStatus(&"Computer analysis stopped ({state.gameAnalysis.completedPositions}/{state.gameAnalysis.totalPositions} positions analyzed)")
            of Exiting:
                discard

proc shutdownSearchWorker*(state: AppState) =
    ## Cleanly shuts down the search worker thread
    if state.analysis.running:
        stopAnalysis(state)
    if state.gameAnalysis.running:
        stopGameAnalysis(state)

    state.channels.command.send(SearchCommand(kind: Shutdown))
    # Wait for the worker to exit
    discard state.channels.response.recv()
    joinThread(state.searchWorkerThread)
