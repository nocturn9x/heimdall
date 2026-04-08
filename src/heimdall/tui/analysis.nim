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

## Search integration for the TUI: background search thread + live polling

import std/[atomics, options, monotimes, times]

import heimdall/[board, moves, pieces, search, position, eval]
import heimdall/util/[limits, wdl]
import heimdall/tui/state


proc searchWorkerLoop*(statePtr: ptr AppState) {.thread.} =
    ## Background search thread. Listens for commands on the channel
    ## and executes searches.
    let state = statePtr[]

    while true:
        let cmd = state.channels.command.recv()

        case cmd.kind
        of Shutdown:
            state.channels.response.send(Exiting)
            break

        of StopSearch:
            state.searcher.cancel()
            if state.watchInitialized:
                state.watchSearcher.cancel()
            if not state.searcher.isSearching() and
               (not state.watchInitialized or not state.watchSearcher.isSearching()):
                state.channels.response.send(SearchComplete)

        of StartAnalysis:
            # Configure for infinite analysis (always uses primary engine)
            state.searcher.limiter.clear()
            state.searcher.state.mateDepth.store(none(int), moRelaxed)
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

        of StartEngineMove:
            state.searcher.limiter.clear()
            state.searcher.state.mateDepth.store(none(int), moRelaxed)
            for limit in cmd.engineLimits:
                state.searcher.limiter.addLimit(limit)
            state.searcher.setBoard(cmd.enginePositions)
            state.searcher.setUCIMode(true)
            discard state.searcher.search(silent=true, ponder=cmd.ponder, variations=1)

            state.channels.response.send(SearchComplete)


proc watchWorkerLoop*(statePtr: ptr AppState) {.thread.} =
    ## Background search thread for the second engine in watch mode.
    let state = statePtr[]

    while true:
        let cmd = state.watchChannels.command.recv()

        case cmd.kind
        of Shutdown:
            state.watchChannels.response.send(Exiting)
            break

        of StopSearch:
            state.watchSearcher.cancel()
            if not state.watchSearcher.isSearching():
                state.watchChannels.response.send(SearchComplete)

        of StartAnalysis:
            # Not used for watch engine, but handle gracefully
            state.watchChannels.response.send(SearchComplete)

        of StartEngineMove:
            state.watchSearcher.limiter.clear()
            state.watchSearcher.state.mateDepth.store(none(int), moRelaxed)
            for limit in cmd.engineLimits:
                state.watchSearcher.limiter.addLimit(limit)
            state.watchSearcher.setBoard(cmd.enginePositions)
            state.watchSearcher.setUCIMode(true)
            discard state.watchSearcher.search(silent=true, ponder=cmd.ponder, variations=1)

            state.watchChannels.response.send(SearchComplete)


proc startSearchWorker*(state: AppState) =
    ## Spawns the primary background search thread
    var statePtr = create(AppState)
    statePtr[] = state
    createThread(state.searchWorkerThread, searchWorkerLoop, statePtr)


proc startWatchWorker*(state: AppState) =
    ## Spawns the second background search thread for watch mode
    state.watchChannels.command.open()
    state.watchChannels.response.open()
    var statePtr = create(AppState)
    statePtr[] = state
    createThread(state.watchWorkerThread, watchWorkerLoop, statePtr)


proc stopSearch*(state: AppState) =
    ## Cancels any running search
    if state.searcher.isSearching():
        state.searcher.cancel()


proc startAnalysis*(state: AppState) =
    ## Starts continuous analysis on the current position
    if state.analysisRunning:
        # Stop current analysis first
        stopSearch(state)
        # Wait for the worker to acknowledge
        discard state.channels.response.recv()

    state.analysisRunning = true
    # Clone positions since Position can't be copied
    var positions: seq[Position]
    for pos in state.board.positions:
        positions.add(pos.clone())
    let cmd = SearchCommand(
        kind: StartAnalysis,
        analysisPositions: positions,
        analysisVariations: state.multiPV
    )
    state.channels.command.send(cmd)


proc stopAnalysis*(state: AppState) =
    ## Stops continuous analysis
    if not state.analysisRunning:
        return

    stopSearch(state)
    # Wait for the search to complete
    discard state.channels.response.recv()
    state.analysisRunning = false


proc toggleAnalysis*(state: AppState) =
    ## Toggles analysis on/off
    if state.analysisRunning:
        stopAnalysis(state)
        state.setStatus("Analysis stopped")
    else:
        startAnalysis(state)
        state.setStatus("Analysis started")


proc drainPVChannel(state: AppState) =
    ## Drains any pending PV data from the channel
    while true:
        let (has, _) = state.pvChannel.tryRecv()
        if not has: break


proc restartAnalysis*(state: AppState) =
    ## Restarts analysis if it's running (e.g. after a position change)
    if state.analysisRunning:
        stopSearch(state)
        discard state.channels.response.recv()
        drainPVChannel(state)
        state.analysisLines = @[]
        var positions: seq[Position]
        for pos in state.board.positions:
            positions.add(pos.clone())
        let cmd = SearchCommand(
            kind: StartAnalysis,
            analysisPositions: positions,
            analysisVariations: state.multiPV
        )
        state.channels.command.send(cmd)


proc pollSearchResults*(state: AppState) =
    ## Non-blocking poll of search statistics for live display updates.
    ## Called every frame from the main event loop.
    if not state.analysisRunning and not state.engineThinking:
        return

    # Read atomic statistics, aggregating node counts from all threads
    let stats = state.searcher.statistics
    let totalNodes = state.searcher.limiter.totalNodes()
    state.analysisNodes = totalNodes
    state.analysisDepth = stats.highestDepth.load(moRelaxed)

    # Compute NPS from total nodes across all threads
    let startTime = state.searcher.state.searchStart.load(moRelaxed)
    let elapsedMs = (getMonoTime() - startTime).inMilliseconds()
    if elapsedMs > 0:
        state.analysisNPS = (totalNodes * 1000) div elapsedMs.uint64

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
        ## Converts a raw STM-relative score to a normalized white-relative display score
        let normalized = normalizeScore(rawStmScore, mat)
        if stm == Black: -normalized else: normalized

    if varCount > 0:
        # Ensure we have enough slots
        while state.analysisLines.len < state.multiPV:
            state.analysisLines.add(AnalysisLine())

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
                state.analysisLines[i] = AnalysisLine(
                    pv: pvMoves,
                    score: toDisplayScore(vScore, sideToMove, material),
                    rawScore: vScore,
                    depth: state.analysisDepth
                )

        # Sort by raw STM score descending (best for side to move first)
        for i in 0..<scored.len:
            for j in i+1..<scored.len:
                if scored[j].rawScore > scored[i].rawScore:
                    swap(scored[i], scored[j])

        # Reorder analysisLines to match sorted order
        var sorted: seq[AnalysisLine]
        for sv in scored:
            sorted.add(state.analysisLines[sv.idx])
        # Keep any remaining old lines that weren't updated this iteration
        for i in sorted.len..<min(state.analysisLines.len, state.multiPV):
            sorted.add(state.analysisLines[i])
        state.analysisLines = sorted

    elif bestMove != nullMove():
        let displayScore = toDisplayScore(bestScore, sideToMove, material)
        if state.analysisLines.len == 0:
            state.analysisLines = @[AnalysisLine(pv: @[bestMove], score: displayScore, rawScore: bestScore, depth: state.analysisDepth)]
        else:
            state.analysisLines[0] = AnalysisLine(pv: @[bestMove], score: displayScore, rawScore: bestScore, depth: state.analysisDepth)

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
        state.analysisLines = sortedPV

    # Check for search completion (non-blocking) on primary channel
    let (hasData, response) = state.channels.response.tryRecv()
    if hasData:
        case response
        of SearchComplete:
            if state.engineThinking:
                state.engineThinking = false
        of Exiting:
            discard

    # Also check watch channel for second engine completion
    if state.watchInitialized:
        let (hasWatch, watchResp) = state.watchChannels.response.tryRecv()
        if hasWatch:
            case watchResp
            of SearchComplete:
                if state.engineThinking:
                    state.engineThinking = false
            of Exiting:
                discard


proc shutdownSearchWorker*(state: AppState) =
    ## Cleanly shuts down the search worker thread
    if state.analysisRunning:
        stopAnalysis(state)

    state.channels.command.send(SearchCommand(kind: Shutdown))
    # Wait for the worker to exit
    discard state.channels.response.recv()
    joinThread(state.searchWorkerThread)
