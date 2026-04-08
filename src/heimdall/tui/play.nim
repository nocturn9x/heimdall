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

## Play mode: play against the engine with clocks

import std/[options, random, atomics, strutils, strformat, parseutils]

import heimdall/[board, moves, pieces, movegen, position, search, transpositions, eval]
import heimdall/util/[limits, scharnagl]
import heimdall/tui/[state, clock, san, analysis]


proc beginGame(state: AppState)
proc startEngineTurn*(state: AppState)
proc onPlayerMove*(state: AppState, clearQueuedPremoves = true)

template startTrackedClock(clock, moveStartRemainingMs: untyped) =
    moveStartRemainingMs = clock.remainingMs
    clock.start()


proc formatPgnElapsed(elapsedMs: int64): string =
    let totalMs = max(0'i64, elapsedMs)
    let totalSec = totalMs div 1000
    let millis = totalMs mod 1000
    let hours = totalSec div 3600
    let minutes = (totalSec mod 3600) div 60
    let seconds = totalSec mod 60
    &"{hours}:{minutes:02d}:{seconds:02d}.{millis:03d}"


proc buildMoveComment(elapsedMs: int64, nodes: Option[uint64] = none(uint64)): string =
    result = &"[%emt {formatPgnElapsed(elapsedMs)}]"
    if nodes.isSome():
        result &= &" [%nodes {nodes.get()}]"


proc resolvePendingPremove(state: AppState): bool =
    if state.pendingPremoves.len == 0:
        return false

    let premove = state.pendingPremoves[0]
    state.pendingPremoves.delete(0)

    var moves = newMoveList()
    state.board.generateMoves(moves)

    var foundMove = nullMove()
    var isPromotion = false
    for move in moves:
        if move.startSquare() == premove.fromSq and move.targetSquare() == premove.toSq:
            if move.isPromotion():
                isPromotion = true
                if state.autoQueen and move.flag().promotionToPiece() == Queen:
                    foundMove = move
                    break
            else:
                foundMove = move
                break

    if foundMove == nullMove() and not isPromotion:
        state.clearPremoves()
        state.setStatus(&"Premove canceled: {premove.fromSq.toUCI()}{premove.toSq.toUCI()}")
        return false

    if isPromotion and not state.autoQueen:
        state.promotionPending = true
        state.promotionFrom = premove.fromSq
        state.promotionTo = premove.toSq
        state.setStatus("Premove ready: choose [Q]ueen / [R]ook / [B]ishop / [N]knight")
        return true

    if foundMove == nullMove():
        state.clearPremoves()
        state.setStatus(&"Premove canceled: {premove.fromSq.toUCI()}{premove.toSq.toUCI()}")
        return false

    let sanStr = state.board.toSAN(foundMove)
    state.lastMove = some((fromSq: foundMove.startSquare(), toSq: foundMove.targetSquare()))
    let applied = state.board.makeMove(foundMove)
    if applied == nullMove():
        state.clearPremoves()
        state.setStatus(&"Premove canceled: {premove.fromSq.toUCI()}{premove.toSq.toUCI()}")
        return false

    state.addMoveRecord(foundMove, sanStr)
    state.undoneHistory = @[]
    stdout.write("\a")
    stdout.flushFile()
    onPlayerMove(state, clearQueuedPremoves=false)
    return true

proc startPlayMode*(state: AppState) =
    ## Enters play mode setup. The actual setup is driven by
    ## user input processed in handlePlaySetup.
    if state.analysisRunning:
        stopAnalysis(state)
    state.mode = ModePlay
    state.boardSetupMode = false
    state.boardSetupSpawnPiece = none(Piece)
    state.pendingPremoves = @[]
    state.playPhase = Setup
    state.setupStep = ChooseVariant
    state.gameResult = none(string)
    state.setStatus("Choose variant: [S]tandard / [f]rc / [d]frc / [c]urrent", persistent=true)


proc setupVariant(state: AppState, input: string) =
    case input.toLowerAscii()
    of "s", "standard", "":
        # Default: standard
        state.variant = Standard
        state.chess960 = false
        state.searcher.state.chess960.store(false, moRelaxed)
        state.board = newDefaultChessboard()
    of "f", "frc":
        state.variant = FischerRandom
        state.chess960 = true
        state.searcher.state.chess960.store(true, moRelaxed)
        let n = rand(959)
        state.board = newChessboardFromFEN(scharnaglToFEN(n))
        state.setStatus(&"FRC position #{n}")
    of "d", "dfrc":
        state.variant = DoubleFischerRandom
        state.chess960 = true
        state.searcher.state.chess960.store(true, moRelaxed)
        let w = rand(959)
        let b = rand(959)
        state.board = newChessboardFromFEN(scharnaglToFEN(w, b))
        state.setStatus(&"DFRC position W:{w} B:{b}")
    of "c", "current":
        # Keep the current board position as-is
        discard
    else:
        state.setStatus("Choose variant: [S]tandard / [f]rc / [d]frc / [c]urrent", persistent=true)
        return

    state.clearMoveRecords()
    state.lastMove = none(tuple[fromSq, toSq: Square])

    if state.watchMode:
        state.playerColor = White  # White = playerClock, Black = engineClock
        state.setupStep = ChooseWatchSeparate
        state.setStatus("Configure engines separately? [y]es / [N]o", persistent=true)
    else:
        state.setupStep = ChooseSide
        state.setStatus("Play as: [w]hite / [b]lack / [R]andom", persistent=true)

proc setupSide(state: AppState, input: string) =
    case input.toLowerAscii()
    of "w", "white":
        state.playerColor = White
    of "b", "black":
        state.playerColor = Black
    of "r", "random", "":
        # Default: random
        state.playerColor = if rand(1) == 0: White else: Black
    else:
        state.setStatus("Play as: [w]hite / [b]lack / [R]andom", persistent=true)
        return

    # Flip board to match player's perspective
    state.flipped = state.playerColor == Black
    state.setupStep = ChoosePlayerTime
    state.setStatus("Your time control (e.g. 5m+3s, 10m, 1h+30s, none):", persistent=true)


proc setupPlayerTime(state: AppState, input: string) =
    let (timeMs, incMs, ok) = parseTimeControl(input)
    if not ok:
        state.setStatus("Invalid time control. Examples: 5m+3s, 10m, 90s, none", persistent=true)
        return

    if timeMs == 0:
        state.playerClock = newClock(int64.high div 2, 0)  # effectively infinite
    else:
        state.playerClock = newClock(timeMs, incMs)

    state.setupStep = ChooseEngineTime
    state.setStatus("Engine time control (e.g. 5m+3s, same, depth 20):", persistent=true)


proc setupEngineTime(state: AppState, input: string) =
    let stripped = input.strip().toLowerAscii()

    if stripped == "same" and not state.watchMode:
        state.engineClock = state.playerClock
    elif stripped == "same":
        state.setStatus("No player time to copy. Enter a time control:", persistent=true)
        return
    elif stripped.startsWith("depth"):
        let parts = stripped.splitWhitespace()
        if parts.len >= 2:
            try:
                state.engineDepth = some(parseInt(parts[1]))
                state.engineClock = newClock(int64.high div 2, 0)
            except ValueError:
                state.setStatus("Invalid depth. Examples: depth 20, same, 5m+3s", persistent=true)
                return
        else:
            state.setStatus("Usage: depth <number>")
            return
    else:
        let (timeMs, incMs, ok) = parseTimeControl(stripped)
        if not ok:
            state.setStatus("Invalid time control. Examples: same, depth 20, 5m+3s", persistent=true)
            return
        if timeMs == 0:
            state.engineClock = newClock(int64.high div 2, 0)
        else:
            state.engineClock = newClock(timeMs, incMs)

    # In watch mode, both sides use the same time control
    if state.watchMode:
        state.playerClock = state.engineClock
        state.allowTakeback = false
        state.setupStep = ChooseWatchThreads
        state.setStatus(&"Threads (shared, current: {state.engineThreads}, Enter to keep):", persistent=true)
    else:
        state.setupStep = ChooseTakeback
        state.setStatus("Allow takeback? [y]es / [N]o", persistent=true)


proc setupWatchSeparate(state: AppState, input: string) =
    case input.toLowerAscii()
    of "y", "yes":
        state.watchSeparateConfig = true
        state.setupStep = ChooseWatchWhiteTime
        state.setStatus("White engine time control (e.g. 5m+3s, depth 20, none):", persistent=true)
    of "n", "no", "":
        state.watchSeparateConfig = false
        state.setupStep = ChooseEngineTime
        state.setStatus("Time control for both engines (e.g. 5m+3s, depth 20, none):", persistent=true)
    else:
        state.setStatus("Configure engines separately? [y]es / [N]o", persistent=true)


proc setupWatchWhiteTime(state: AppState, input: string) =
    let stripped = input.strip().toLowerAscii()
    if stripped.startsWith("depth"):
        let parts = stripped.splitWhitespace()
        if parts.len >= 2:
            try:
                state.engineDepth = some(parseInt(parts[1]))
                state.playerClock = newClock(int64.high div 2, 0)
            except ValueError:
                state.setStatus("Invalid depth. Examples: depth 20, 5m+3s", persistent=true)
                return
        else:
            state.setStatus("Usage: depth <number>", persistent=true)
            return
    else:
        let (timeMs, incMs, ok) = parseTimeControl(stripped)
        if not ok:
            state.setStatus("Invalid time control. Examples: 5m+3s, depth 20, none", persistent=true)
            return
        if timeMs == 0:
            state.playerClock = newClock(int64.high div 2, 0)
        else:
            state.playerClock = newClock(timeMs, incMs)

    state.setupStep = ChooseWatchBlackTime
    state.setStatus("Black engine time control (e.g. 5m+3s, depth 20, same):", persistent=true)


proc setupWatchBlackTime(state: AppState, input: string) =
    let stripped = input.strip().toLowerAscii()
    if stripped == "same":
        state.engineClock = state.playerClock
    elif stripped.startsWith("depth"):
        let parts = stripped.splitWhitespace()
        if parts.len >= 2:
            try:
                # Note: depth limit applies to both sides since there's one engine
                state.engineDepth = some(parseInt(parts[1]))
                state.engineClock = newClock(int64.high div 2, 0)
            except ValueError:
                state.setStatus("Invalid depth. Examples: depth 20, same, 5m+3s", persistent=true)
                return
        else:
            state.setStatus("Usage: depth <number>", persistent=true)
            return
    else:
        let (timeMs, incMs, ok) = parseTimeControl(stripped)
        if not ok:
            state.setStatus("Invalid time control. Examples: same, depth 20, 5m+3s", persistent=true)
            return
        if timeMs == 0:
            state.engineClock = newClock(int64.high div 2, 0)
        else:
            state.engineClock = newClock(timeMs, incMs)

    state.allowTakeback = false
    state.setupStep = ChooseWatchThreads
    if state.watchSeparateConfig:
        state.setStatus(&"White engine threads (current: {state.engineThreads}, Enter to keep):", persistent=true)
    else:
        state.setStatus(&"Threads (shared, current: {state.engineThreads}, Enter to keep):", persistent=true)


proc setupWatchThreads(state: AppState, input: string) =
    let stripped = input.strip()
    if stripped.len > 0:
        try:
            let n = parseInt(stripped)
            if n < 1 or n > 1024:
                let prompt =
                    if state.watchSeparateConfig: "White engine threads must be 1-1024:"
                    else: "Threads must be 1-1024:"
                state.setStatus(prompt, persistent=true)
                return
            state.engineThreads = n
            state.searcher.setWorkerCount(n - 1)
        except ValueError:
            let prompt =
                if state.watchSeparateConfig: "Invalid number. Enter White engine thread count:"
                else: "Invalid number. Enter thread count:"
            state.setStatus(prompt, persistent=true)
            return

    state.setupStep = ChooseWatchHash
    if state.watchSeparateConfig:
        state.setStatus(&"White engine hash (current: {state.engineHash} MiB, Enter to keep):", persistent=true)
    else:
        state.setStatus(&"Hash size (shared, current: {state.engineHash} MiB, Enter to keep):", persistent=true)


proc parseHashInput(input: string): tuple[sizeMiB: int64, ok: bool] =
    let stripped = input.strip()
    if stripped.len == 0:
        return (0'i64, true)  # keep current
    try:
        let n = parseBiggestInt(stripped)
        if n < 1 or n > 33554432:
            return (0'i64, false)
        return (n, true)
    except ValueError:
        var sizeBytes: int64
        let consumed = parseSize(stripped, sizeBytes)
        if consumed == 0:
            return (0'i64, false)
        let sizeMiB = sizeBytes div (1024 * 1024)
        if sizeMiB < 1 or sizeMiB > 33554432:
            return (0'i64, false)
        return (sizeMiB, true)


proc setupWatchHash(state: AppState, input: string) =
    let (sizeMiB, ok) = parseHashInput(input)
    if not ok:
        let prompt =
            if state.watchSeparateConfig: "Invalid size for White engine hash. Examples: 64, 1 GB, 256 MiB:"
            else: "Invalid size. Examples: 64, 1 GB, 256 MiB:"
        state.setStatus(prompt, persistent=true)
        return
    if sizeMiB > 0:
        state.engineHash = sizeMiB.uint64
        state.ttable.resize(sizeMiB.uint64 * 1024 * 1024)

    if state.watchSeparateConfig:
        # Ask for Black's settings separately
        state.watchThreads = state.engineThreads  # default = same as White
        state.watchHash = state.engineHash
        state.setupStep = ChooseWatchBlackThreads
        state.setStatus(&"Black engine threads (Enter = same as White: {state.engineThreads}):", persistent=true)
    else:
        # Same config for both - Black copies White's settings
        state.watchThreads = state.engineThreads
        state.watchHash = state.engineHash
        state.setupStep = ChooseWatchPonder
        state.setStatus("Enable pondering for both engines? [y]es / [N]o", persistent=true)

proc setupWatchBlackThreads(state: AppState, input: string) =
    let stripped = input.strip()
    if stripped.len > 0:
        try:
            let n = parseInt(stripped)
            if n < 1 or n > 1024:
                state.setStatus("Threads must be 1-1024:", persistent=true)
                return
            state.watchThreads = n
        except ValueError:
            state.setStatus("Invalid number:", persistent=true)
            return

    state.setupStep = ChooseWatchBlackHash
    state.setStatus(&"Black engine hash (Enter = same as White: {state.engineHash} MiB):", persistent=true)

proc setupWatchBlackHash(state: AppState, input: string) =
    let (sizeMiB, ok) = parseHashInput(input)
    if not ok:
        state.setStatus("Invalid size. Examples: 64, 1 GB, 256 MiB:", persistent=true)
        return
    if sizeMiB > 0:
        state.watchHash = sizeMiB.uint64

    state.setupStep = ChooseWatchWhitePonder
    state.setStatus("White engine pondering? [y]es / [N]o", persistent=true)


proc setupWatchPonder(state: AppState, input: string) =
    ## Shared ponder setting for both engines
    case input.toLowerAscii()
    of "y", "yes":
        state.allowPonder = true
        state.watchPonder = true
    of "n", "no", "":
        state.allowPonder = false
        state.watchPonder = false
    else:
        state.setStatus("Enable pondering for both engines? [y]es / [N]o", persistent=true)
        return
    beginGame(state)


proc setupWatchWhitePonder(state: AppState, input: string) =
    case input.toLowerAscii()
    of "y", "yes":
        state.allowPonder = true
    of "n", "no", "":
        state.allowPonder = false
    else:
        state.setStatus("White engine pondering? [y]es / [N]o", persistent=true)
        return
    state.setupStep = ChooseWatchBlackPonder
    state.setStatus("Black engine pondering? [y]es / [N]o", persistent=true)


proc setupWatchBlackPonder(state: AppState, input: string) =
    case input.toLowerAscii()
    of "y", "yes":
        state.watchPonder = true
    of "n", "no", "":
        state.watchPonder = false
    else:
        state.setStatus("Black engine pondering? [y]es / [N]o", persistent=true)
        return
    beginGame(state)


proc setupTakeback(state: AppState, input: string) =
    case input.toLowerAscii()
    of "y", "yes":
        state.allowTakeback = true
    of "n", "no", "":
        state.allowTakeback = false
    else:
        state.setStatus("Allow takeback? [y]es / [N]o", persistent=true)
        return
    state.setupStep = ChoosePonder
    state.setStatus("Enable pondering? [y]es / [N]o", persistent=true)


proc setupPonder(state: AppState, input: string) =
    case input.toLowerAscii()
    of "y", "yes":
        state.allowPonder = true
    of "n", "no", "":
        state.allowPonder = false
    else:
        state.setStatus("Enable pondering? [y]es / [N]o", persistent=true)
        return
    beginGame(state)


proc beginGame(state: AppState) =
    ## Transitions from setup to active game
    # Clear primary engine state
    state.ttable.init()
    state.searcher.histories.clear()
    state.searcher.resetWorkers()
    state.pendingPremoves = @[]

    # Initialize second engine for watch mode (independent instance)
    if state.watchMode:
        if state.watchTtable != nil:
            dealloc(state.watchTtable)
        state.watchTtable = create(TranspositionTable)
        state.watchTtable[] = newTranspositionTable(state.watchHash * 1024 * 1024)
        state.watchSearcher = newSearchManager(state.board.positions, state.watchTtable, evalState=newEvalState(verbose=false))
        if state.watchThreads > 1:
            state.watchSearcher.setWorkerCount(state.watchThreads - 1)
        state.watchInitialized = true
        startWatchWorker(state)

    # Record game info for display
    state.gameStartFEN = state.board.toFEN()
    # Build time control description
    proc fmtClock(c: ChessClock): string =
        if c.remainingMs >= int64.high div 4:
            return "unlimited"
        let mins = c.remainingMs div 60_000
        let secs = (c.remainingMs mod 60_000) div 1000
        let incSecs = c.incrementMs div 1000
        if incSecs > 0:
            return &"{mins}m+{incSecs}s"
        else:
            return &"{mins}m{secs}s"
    if state.watchMode:
        state.gameTimeControl = "Engine vs Engine: " & fmtClock(state.engineClock)
    elif state.engineDepth.isSome():
        state.gameTimeControl = fmtClock(state.playerClock) & " vs depth " & $state.engineDepth.get()
    elif state.playerClock.remainingMs == state.engineClock.remainingMs and
         state.playerClock.incrementMs == state.engineClock.incrementMs:
        state.gameTimeControl = fmtClock(state.playerClock)
    else:
        state.gameTimeControl = fmtClock(state.playerClock) & " vs " & fmtClock(state.engineClock)

    if state.watchMode:
        # Engine vs Engine: always engine turn
        state.playPhase = EngineTurn
        startEngineTurn(state)
    else:
        state.playPhase = if state.board.sideToMove() == state.playerColor: PlayerTurn else: EngineTurn
        if state.playPhase == PlayerTurn:
            startTrackedClock(state.playerClock, state.playerClockMoveStartMs)
            state.setStatus("Your turn!")
        else:
            startTrackedClock(state.engineClock, state.engineClockMoveStartMs)
            startEngineTurn(state)


proc handlePlaySetup*(state: AppState, input: string) =
    ## Processes user input during play mode setup
    case state.setupStep
    of ChooseVariant:
        setupVariant(state, input)
    of ChooseSide:
        setupSide(state, input)
    of ChoosePlayerTime:
        setupPlayerTime(state, input)
    of ChooseEngineTime:
        setupEngineTime(state, input)
    of ChooseTakeback:
        setupTakeback(state, input)
    of ChoosePonder:
        setupPonder(state, input)
    of ChooseWatchSeparate:
        setupWatchSeparate(state, input)
    of ChooseWatchWhiteTime:
        setupWatchWhiteTime(state, input)
    of ChooseWatchBlackTime:
        setupWatchBlackTime(state, input)
    of ChooseWatchThreads:
        setupWatchThreads(state, input)
    of ChooseWatchHash:
        setupWatchHash(state, input)
    of ChooseWatchBlackThreads:
        setupWatchBlackThreads(state, input)
    of ChooseWatchBlackHash:
        setupWatchBlackHash(state, input)
    of ChooseWatchPonder:
        setupWatchPonder(state, input)
    of ChooseWatchWhitePonder:
        setupWatchWhitePonder(state, input)
    of ChooseWatchBlackPonder:
        setupWatchBlackPonder(state, input)


proc checkGameOver*(state: AppState): bool =
    ## Checks if the game is over and sets gameResult if so.
    ## Returns true if the game ended.
    if state.gameResult.isSome():
        return true

    # Check clocks
    if state.playerClock.expired:
        let winner = if state.playerColor == White: "0-1" else: "1-0"
        state.gameResult = some(&"{winner} (time)")
        state.playPhase = GameOver
        state.playerClock.stop()
        state.engineClock.stop()
        state.setStatus(&"Time forfeit! {winner}")
        return true

    if state.engineClock.expired:
        let winner = if state.playerColor == White: "1-0" else: "0-1"
        state.gameResult = some(&"{winner} (time)")
        state.playPhase = GameOver
        state.playerClock.stop()
        state.engineClock.stop()
        state.setStatus(&"Engine flagged! {winner}")
        return true

    # Check position-based endings
    var moves = newMoveList()
    state.board.generateMoves(moves)

    if moves.len == 0:
        if state.board.inCheck():
            let winner = if state.board.sideToMove() == White: "0-1" else: "1-0"
            state.gameResult = some(&"{winner} (checkmate)")
            state.playPhase = GameOver
            state.playerClock.stop()
            state.engineClock.stop()
            state.setStatus(&"Checkmate! {winner}")
        else:
            state.gameResult = some("1/2-1/2 (stalemate)")
            state.playPhase = GameOver
            state.playerClock.stop()
            state.engineClock.stop()
            state.setStatus("Stalemate! Draw")
        return true

    if state.board.isInsufficientMaterial():
        state.gameResult = some("1/2-1/2 (insufficient material)")
        state.playPhase = GameOver
        state.playerClock.stop()
        state.engineClock.stop()
        state.setStatus("Draw by insufficient material")
        return true

    if state.board.halfMoveClock() >= 100:
        state.gameResult = some("1/2-1/2 (50-move rule)")
        state.playPhase = GameOver
        state.playerClock.stop()
        state.engineClock.stop()
        state.setStatus("Draw by 50-move rule")
        return true

    if state.board.drawnByRepetition(0):
        state.gameResult = some("1/2-1/2 (repetition)")
        state.playPhase = GameOver
        state.playerClock.stop()
        state.engineClock.stop()
        state.setStatus("Draw by repetition")
        return true

    return false


proc startEngineTurn*(state: AppState) =
    ## Starts the engine's search for its move
    state.engineThinking = true

    var positions: seq[Position]
    for pos in state.board.positions:
        positions.add(pos.clone())

    # In watch mode, determine which engine plays this move
    let isBlackTurn = state.board.sideToMove() == Black
    let useSecond = state.watchMode and state.watchInitialized and isBlackTurn

    # Start the right clock and pick limits
    let depthLimit = if useSecond: state.watchDepth else: state.engineDepth

    var engineLimits: seq[SearchLimit]
    if useSecond:
        startTrackedClock(state.engineClock, state.engineClockMoveStartMs)
        if depthLimit.isSome():
            engineLimits.add(newDepthLimit(depthLimit.get()))
        elif state.engineClock.remainingMs < int64.high div 2:
            engineLimits.add(newTimeLimit(state.engineClock.remainingMs, state.engineClock.incrementMs, 250))
    elif state.watchMode:
        startTrackedClock(state.playerClock, state.playerClockMoveStartMs)
        if depthLimit.isSome():
            engineLimits.add(newDepthLimit(depthLimit.get()))
        elif state.playerClock.remainingMs < int64.high div 2:
            engineLimits.add(newTimeLimit(state.playerClock.remainingMs, state.playerClock.incrementMs, 250))
    else:
        startTrackedClock(state.engineClock, state.engineClockMoveStartMs)
        if depthLimit.isSome():
            engineLimits.add(newDepthLimit(depthLimit.get()))
        elif state.engineClock.remainingMs < int64.high div 2:
            engineLimits.add(newTimeLimit(state.engineClock.remainingMs, state.engineClock.incrementMs, 250))

    let cmd = SearchCommand(
        kind: StartEngineMove,
        enginePositions: positions,
        engineLimits: engineLimits
    )
    if useSecond:
        state.watchChannels.command.send(cmd)
    else:
        state.channels.command.send(cmd)


proc onEngineMoveComplete*(state: AppState) =
    ## Called when the engine's search finishes
    state.engineThinking = false

    # Determine which engine just moved (the side that was to move BEFORE the search)
    # Since the search just finished, sideToMove is still the side that searched
    let wasBlack = state.board.sideToMove() == Black
    let usedSecond = state.watchMode and state.watchInitialized and wasBlack
    let stats = if usedSecond: state.watchSearcher.statistics
                else: state.searcher.statistics
    let nodesSearched = stats.nodeCount.load(moRelaxed)

    # Press the correct clock
    var elapsedMs = 0'i64
    if usedSecond:
        elapsedMs = state.engineClock.finishMove(state.engineClockMoveStartMs)
    elif state.watchMode:
        elapsedMs = state.playerClock.finishMove(state.playerClockMoveStartMs)
    else:
        elapsedMs = state.engineClock.finishMove(state.engineClockMoveStartMs)

    # Get the best move from the correct engine's statistics
    let bestMove = stats.bestMove.load(moRelaxed)
    if bestMove == nullMove():
        state.setStatus("Engine couldn't find a move!")
        state.playPhase = GameOver
        return

    # Handle opponent's ponder in watch mode
    if state.watchMode:
        if usedSecond and state.isPondering:
            # Black just moved, White was pondering
            if bestMove == state.ponderMove:
                state.searcher.stopPondering()  # ponderhit!
            else:
                state.searcher.cancel()
                discard state.channels.response.recv()
            state.isPondering = false
        elif not usedSecond and state.isWatchPondering:
            # White just moved, Black was pondering
            if bestMove == state.watchPonderMove:
                state.watchSearcher.stopPondering()  # ponderhit!
            else:
                state.watchSearcher.cancel()
                discard state.watchChannels.response.recv()
            state.isWatchPondering = false

    # Record SAN before making the move
    let sanStr = state.board.toSAN(bestMove)
    state.lastMove = some((fromSq: bestMove.startSquare(), toSq: bestMove.targetSquare()))

    let applied = state.board.makeMove(bestMove)
    if applied == nullMove():
        state.setStatus("Engine made illegal move!")
        state.playPhase = GameOver
        return

    state.addMoveRecord(bestMove, sanStr, buildMoveComment(elapsedMs, some(nodesSearched)))

    # Audible feedback for engine move (disabled in watch mode)
    if not state.watchMode:
        stdout.write("\a")
        stdout.flushFile()

    if not checkGameOver(state):
        if state.watchMode:
            # Engine vs Engine: start the other engine's turn
            state.playPhase = EngineTurn

            # The engine that just moved can now ponder while the other thinks
            let justMovedBlack = usedSecond  # Black just moved, White is next
            if justMovedBlack and state.watchPonder:
                # Black just moved - start Black pondering on White's expected reply
                let pvSecond = state.watchSearcher.previousVariations[0].moves[1]
                if pvSecond != nullMove():
                    state.watchPonderMove = pvSecond
                    var ponderPositions: seq[Position]
                    for pos in state.board.positions:
                        ponderPositions.add(pos.clone())
                    var ponderBoard = newChessboard(ponderPositions)
                    discard ponderBoard.makeMove(pvSecond)
                    var finalPositions: seq[Position]
                    for pos in ponderBoard.positions:
                        finalPositions.add(pos.clone())
                    state.watchChannels.command.send(SearchCommand(
                        kind: StartEngineMove, ponder: true,
                        enginePositions: finalPositions,
                        engineLimits: @[newTimeLimit(state.engineClock.remainingMs, state.engineClock.incrementMs, 250)]
                    ))
                    state.isWatchPondering = true
            elif not justMovedBlack and state.allowPonder:
                # White just moved - start White pondering on Black's expected reply
                let pvSecond = state.searcher.previousVariations[0].moves[1]
                if pvSecond != nullMove():
                    state.ponderMove = pvSecond
                    var ponderPositions: seq[Position]
                    for pos in state.board.positions:
                        ponderPositions.add(pos.clone())
                    var ponderBoard = newChessboard(ponderPositions)
                    discard ponderBoard.makeMove(pvSecond)
                    var finalPositions: seq[Position]
                    for pos in ponderBoard.positions:
                        finalPositions.add(pos.clone())
                    state.channels.command.send(SearchCommand(
                        kind: StartEngineMove, ponder: true,
                        enginePositions: finalPositions,
                        engineLimits: @[newTimeLimit(state.playerClock.remainingMs, state.playerClock.incrementMs, 250)]
                    ))
                    state.isPondering = true

            startEngineTurn(state)
        else:
            state.playPhase = PlayerTurn
            startTrackedClock(state.playerClock, state.playerClockMoveStartMs)
            if resolvePendingPremove(state):
                return
            state.setStatus(&"Engine played {sanStr}. Your turn!")

            # Start pondering if enabled - search on the expected reply
            if state.allowPonder:
                # The ponder move is the second move in the PV
                let ponderMove = stats.variationMoves[0].load(moRelaxed)
                # Actually read from previousVariations for the full PV
                let pvSecond = state.searcher.previousVariations[0].moves[1]
                if pvSecond != nullMove():
                    state.ponderMove = pvSecond
                    # Temporarily make the ponder move on a cloned board
                    var ponderPositions: seq[Position]
                    for pos in state.board.positions:
                        ponderPositions.add(pos.clone())
                    # Make the ponder move on the cloned position stack
                    var ponderBoard = newChessboard(ponderPositions)
                    discard ponderBoard.makeMove(pvSecond)
                    var finalPositions: seq[Position]
                    for pos in ponderBoard.positions:
                        finalPositions.add(pos.clone())

                    let cmd = SearchCommand(
                        kind: StartEngineMove,
                        ponder: true,
                        enginePositions: finalPositions,
                        engineLimits: @[newTimeLimit(
                            state.engineClock.remainingMs,
                            state.engineClock.incrementMs, 250)]
                    )
                    state.channels.command.send(cmd)
                    state.isPondering = true


proc onPlayerMove*(state: AppState, clearQueuedPremoves = true) =
    ## Called after the player successfully makes a move
    if clearQueuedPremoves:
        state.pendingPremoves = @[]
    let elapsedMs = state.playerClock.finishMove(state.playerClockMoveStartMs)
    if state.moveComments.len > 0:
        state.moveComments[^1] = buildMoveComment(elapsedMs)

    if state.isPondering:
        # Check if the player's move matches the ponder move
        let playerMove = state.moveHistory[^1]
        if playerMove == state.ponderMove:
            # Ponderhit! Tell the engine to switch from ponder to real search
            state.searcher.stopPondering()
            state.isPondering = false
            state.engineThinking = true
            state.playPhase = EngineTurn
            startTrackedClock(state.engineClock, state.engineClockMoveStartMs)
            # The search continues with real time limits
            return
        else:
            # Ponder miss - cancel the ponder search
            state.searcher.cancel()
            discard state.channels.response.recv()
            state.isPondering = false

    if not checkGameOver(state):
        state.playPhase = EngineTurn
        startEngineTurn(state)


proc tickClocks*(state: AppState) =
    ## Updates running clocks. Called each frame.
    if state.mode != ModePlay or state.playPhase in [Setup, GameOver]:
        return
    state.playerClock.tick()
    state.engineClock.tick()
    discard checkGameOver(state)


proc exitPlayMode*(state: AppState) =
    ## Exits play mode back to analysis
    if state.isPondering or state.engineThinking:
        stopSearch(state)
        discard state.channels.response.recv()
        state.engineThinking = false
        state.isPondering = false
    if state.isWatchPondering:
        state.watchSearcher.cancel()
        discard state.watchChannels.response.recv()
        state.isWatchPondering = false
    state.playerClock.stop()
    state.engineClock.stop()
    state.pendingPremoves = @[]
    state.mode = ModeAnalysis
    state.playPhase = Setup
    state.gameResult = none(string)
    # Clean up second engine and its worker if initialized
    if state.watchInitialized:
        # Stop the second worker thread
        if state.watchSearcher.isSearching():
            state.watchSearcher.cancel()
        state.watchChannels.command.send(SearchCommand(kind: Shutdown))
        discard state.watchChannels.response.recv()
        joinThread(state.watchWorkerThread)
        state.watchChannels.command.close()
        state.watchChannels.response.close()
        state.watchSearcher.shutdownWorkers()
        if state.watchTtable != nil:
            dealloc(state.watchTtable)
            state.watchTtable = nil
        state.watchInitialized = false
    state.watchMode = false
    state.watchSeparateConfig = false
    state.setStatus("Exited play mode")
