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


const
    EngineLimitExamples = "same, depth 20, nodes 200000, softnodes 100000, 5m+3s"
    WatchLimitExamples = "5m+3s, depth 20, nodes 200000, softnodes 100000, none"
    WatchBlackLimitExamples = "same, 5m+3s, depth 20, nodes 200000, softnodes 100000"


proc newTimeOrUnlimitedLimit(timeMs, incrementMs: int64): PlayLimitConfig =
    if timeMs == 0:
        result.kind = PlayUnlimited
    else:
        result.kind = PlayTime
        result.timeMs = timeMs
        result.incrementMs = incrementMs


proc newDepthPlayLimit(depth: int): PlayLimitConfig =
    result.kind = PlayDepth
    result.depth = depth


proc newNodePlayLimit(nodes: uint64): PlayLimitConfig =
    result.kind = PlayNodes
    result.softNodes = nodes


proc newSoftNodePlayLimit(softNodes: uint64, hardNodes: Option[uint64]): PlayLimitConfig =
    result.kind = PlaySoftNodes
    result.softNodes = softNodes
    result.hardNodes = hardNodes


proc limitClock(limit: PlayLimitConfig): ChessClock =
    case limit.kind
    of PlayTime:
        return newClock(limit.timeMs, limit.incrementMs)
    of PlayUnlimited, PlayDepth, PlayNodes, PlaySoftNodes:
        return newClock(int64.high div 2, 0)


proc isTimeManaged(limit: PlayLimitConfig): bool =
    limit.kind == PlayTime


proc formatConfiguredLimit(limit: PlayLimitConfig): string =
    case limit.kind
    of PlayTime:
        let mins = limit.timeMs div 60_000
        let secs = (limit.timeMs mod 60_000) div 1000
        let incSecs = limit.incrementMs div 1000
        if incSecs > 0:
            return &"{mins}m+{incSecs}s"
        return &"{mins}m{secs}s"
    of PlayUnlimited:
        return "unlimited"
    of PlayDepth:
        return "depth " & $limit.depth
    of PlayNodes:
        return "nodes " & $limit.softNodes
    of PlaySoftNodes:
        if limit.hardNodes.isSome():
            return "softnodes " & $limit.softNodes & " (hard " & $limit.hardNodes.get() & ")"
        return "softnodes " & $limit.softNodes


proc buildSearchLimits(limit: PlayLimitConfig, clock: ChessClock): seq[SearchLimit] =
    case limit.kind
    of PlayTime:
        result.add(newTimeLimit(clock.remainingMs, clock.incrementMs, 250))
    of PlayUnlimited:
        discard
    of PlayDepth:
        result.add(newDepthLimit(limit.depth))
    of PlayNodes:
        result.add(newNodeLimit(limit.softNodes))
    of PlaySoftNodes:
        result.add(newNodeLimit(limit.softNodes, limit.hardNodes.get(uint64.high)))


proc setWatchWhiteLimit(state: AppState, limit: PlayLimitConfig) =
    state.playerLimit = limit
    state.playerClock = limitClock(limit)
    state.engineDepth = if limit.kind == PlayDepth: some(limit.depth) else: none(int)


proc setWatchBlackLimit(state: AppState, limit: PlayLimitConfig) =
    state.engineLimit = limit
    state.engineClock = limitClock(limit)
    state.watchDepth = if limit.kind == PlayDepth: some(limit.depth) else: none(int)


proc setHumanPlayerLimit(state: AppState, limit: PlayLimitConfig) =
    state.playerLimit = limit
    state.playerClock = limitClock(limit)


proc setHumanEngineLimit(state: AppState, limit: PlayLimitConfig) =
    state.engineLimit = limit
    state.engineClock = limitClock(limit)
    state.engineDepth = if limit.kind == PlayDepth: some(limit.depth) else: none(int)
    state.watchDepth = none(int)


proc applyLimitToTarget(state: AppState, target: PendingLimitTarget, limit: PlayLimitConfig) =
    case target:
        of EngineLimitTarget:
            state.setHumanEngineLimit(limit)
        of WatchWhiteLimitTarget:
            state.setWatchWhiteLimit(limit)
        of WatchBlackLimitTarget:
            state.setWatchBlackLimit(limit)
        of WatchSharedLimitTarget:
            state.setWatchWhiteLimit(limit)
            state.setWatchBlackLimit(limit)
        of NoPendingLimit:
            discard


proc advanceAfterLimitSelection(state: AppState, target: PendingLimitTarget) =
    case target:
        of EngineLimitTarget:
            state.setupStep = ChooseTakeback
            state.setStatus("Allow takeback? [y]es / [N]o", persistent=true)
        of WatchWhiteLimitTarget:
            state.setupStep = ChooseWatchBlackTime
            state.setStatus(
                "Black engine time control (e.g. 5m+3s, depth 20, nodes 200000, softnodes 100000, same):",
                persistent=true
            )
        of WatchBlackLimitTarget, WatchSharedLimitTarget:
            state.allowTakeback = false
            state.setupStep = ChooseWatchThreads
            if state.watchSeparateConfig:
                state.setStatus(&"White engine threads (current: {state.engineThreads}, Enter to keep):", persistent=true)
            else:
                state.setStatus(&"Threads (shared, current: {state.engineThreads}, Enter to keep):", persistent=true)
        of NoPendingLimit:
            discard


proc parsePositiveNodeCount(input: string): tuple[value: uint64, ok: bool] =
    let stripped = input.strip()
    if stripped.len == 0:
        return (0'u64, false)
    try:
        let value = parseBiggestUInt(stripped).uint64
        if value == 0:
            return (0'u64, false)
        return (value, true)
    except ValueError:
        return (0'u64, false)


proc startSoftNodesFollowup(state: AppState, target: PendingLimitTarget, softNodes: uint64) =
    state.pendingLimitTarget = target
    state.pendingSoftNodes = softNodes
    state.setupStep = ChooseSoftNodesHardBound
    state.setStatus("Set a hard node cap as well? [y]es / [N]o", persistent=true)


proc configureEngineLikeLimit(
    state: AppState,
    input: string,
    target: PendingLimitTarget,
    invalidExamples: string,
    allowSame = false,
    sameLimit = PlayLimitConfig()
) =
    let stripped = input.strip().toLowerAscii()

    if allowSame and stripped == "same":
        state.applyLimitToTarget(target, sameLimit)
        state.advanceAfterLimitSelection(target)
        return

    if stripped.startsWith("depth"):
        let parts = stripped.splitWhitespace()
        if parts.len < 2:
            state.setStatus("Usage: depth <number>", persistent=true)
            return
        try:
            let depth = parseInt(parts[1])
            if depth < 1:
                state.setStatus("Depth must be at least 1", persistent=true)
                return
            state.applyLimitToTarget(target, newDepthPlayLimit(depth))
            state.advanceAfterLimitSelection(target)
        except ValueError:
            state.setStatus("Invalid depth. Examples: depth 20", persistent=true)
        return

    if stripped.startsWith("nodes"):
        let parts = stripped.splitWhitespace()
        if parts.len < 2:
            state.setStatus("Usage: nodes <count>", persistent=true)
            return
        let (nodes, ok) = parsePositiveNodeCount(parts[1])
        if not ok:
            state.setStatus("Invalid node count. Example: nodes 200000", persistent=true)
            return
        state.applyLimitToTarget(target, newNodePlayLimit(nodes))
        state.advanceAfterLimitSelection(target)
        return

    if stripped.startsWith("softnodes"):
        let parts = stripped.splitWhitespace()
        if parts.len < 2:
            state.setStatus("Usage: softnodes <count>", persistent=true)
            return
        let (softNodes, ok) = parsePositiveNodeCount(parts[1])
        if not ok:
            state.setStatus("Invalid node count. Example: softnodes 100000", persistent=true)
            return
        state.startSoftNodesFollowup(target, softNodes)
        return

    let (timeMs, incMs, ok) = parseTimeControl(stripped)
    if not ok:
        state.setStatus("Invalid time control. Examples: " & invalidExamples, persistent=true)
        return
    state.applyLimitToTarget(target, newTimeOrUnlimitedLimit(timeMs, incMs))
    state.advanceAfterLimitSelection(target)


proc formatPgnElapsed(elapsedMs: int64): string =
    let totalMs = max(0'i64, elapsedMs)
    let totalSec = totalMs div 1000
    let millis = totalMs mod 1000
    let hours = totalSec div 3600
    let minutes = (totalSec mod 3600) div 60
    let seconds = totalSec mod 60
    return &"{hours}:{minutes:02d}:{seconds:02d}.{millis:03d}"


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
    state.clearUserArrows()
    state.pendingPremoves = @[]
    state.playerLimit = newTimeOrUnlimitedLimit(0, 0)
    state.engineLimit = newTimeOrUnlimitedLimit(0, 0)
    state.engineDepth = none(int)
    state.watchDepth = none(int)
    state.pendingLimitTarget = NoPendingLimit
    state.pendingSoftNodes = 0
    state.playPhase = Setup
    state.setupStep = ChooseVariant
    state.playSideSelection = SideRandom
    state.watchPonder = false
    state.isWatchPondering = false
    state.gameResult = none(string)
    state.setStatus("Choose variant: [S]tandard / [f]rc / [d]frc / [c]urrent", persistent=true)


proc setupVariant(state: AppState, input: string) =
    case input.toLowerAscii():
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
            state.setStatus(&"DFRC position W: {w} B: {b}")
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
    case input.toLowerAscii():
        of "w", "white":
            state.playSideSelection = SideWhite
            state.playerColor = White
        of "b", "black":
            state.playSideSelection = SideBlack
            state.playerColor = Black
        of "r", "random", "":
            # Default: random
            state.playSideSelection = SideRandom
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

    state.setHumanPlayerLimit(newTimeOrUnlimitedLimit(timeMs, incMs))

    state.setupStep = ChooseEngineTime
    state.setStatus(
        "Engine time control (e.g. 5m+3s, same, depth 20, nodes 200000, softnodes 100000):",
        persistent=true
    )


proc setupEngineTime(state: AppState, input: string) =
    if state.watchMode:
        state.configureEngineLikeLimit(input, WatchSharedLimitTarget, WatchLimitExamples)
    else:
        state.configureEngineLikeLimit(input, EngineLimitTarget, EngineLimitExamples, allowSame=true, sameLimit=state.playerLimit)


proc setupWatchSeparate(state: AppState, input: string) =
    case input.toLowerAscii():
        of "y", "yes":
            state.watchSeparateConfig = true
            state.setupStep = ChooseWatchWhiteTime
            state.setStatus(
                "White engine time control (e.g. 5m+3s, depth 20, nodes 200000, softnodes 100000, none):",
                persistent=true
            )
        of "n", "no", "":
            state.watchSeparateConfig = false
            state.setupStep = ChooseEngineTime
            state.setStatus(
                "Time control for both engines (e.g. 5m+3s, depth 20, nodes 200000, softnodes 100000, none):",
                persistent=true
            )
        else:
            state.setStatus("Configure engines separately? [y]es / [N]o", persistent=true)


proc setupWatchWhiteTime(state: AppState, input: string) =
    state.configureEngineLikeLimit(input, WatchWhiteLimitTarget, WatchLimitExamples)


proc setupWatchBlackTime(state: AppState, input: string) =
    state.configureEngineLikeLimit(
        input,
        WatchBlackLimitTarget,
        WatchBlackLimitExamples,
        allowSame=true,
        sameLimit=state.playerLimit
    )


# TODO: setupSoftNodesHardLimit and setupSoftNodesHardBound seem to do the same thing
proc setupSoftNodesHardBound(state: AppState, input: string) =
    case input.toLowerAscii():
        of "y", "yes":
            state.setupStep = ChooseSoftNodesHardLimit
            state.setStatus(&"Hard node cap (must be >= {state.pendingSoftNodes}):", persistent=true)
        of "n", "no", "":
            let target = state.pendingLimitTarget
            state.applyLimitToTarget(target, newSoftNodePlayLimit(state.pendingSoftNodes, none(uint64)))
            state.pendingLimitTarget = NoPendingLimit
            state.pendingSoftNodes = 0
            state.advanceAfterLimitSelection(target)
        else:
            state.setStatus("Set a hard node cap as well? [y]es / [N]o", persistent=true)


proc setupSoftNodesHardLimit(state: AppState, input: string) =
    let (hardNodes, ok) = parsePositiveNodeCount(input)
    if not ok:
        state.setStatus("Invalid node count. Example: 250000", persistent=true)
        return
    if hardNodes < state.pendingSoftNodes:
        state.setStatus(&"Hard node cap must be at least {state.pendingSoftNodes}", persistent=true)
        return
    let target = state.pendingLimitTarget
    state.applyLimitToTarget(target, newSoftNodePlayLimit(state.pendingSoftNodes, some(hardNodes)))
    state.pendingLimitTarget = NoPendingLimit
    state.pendingSoftNodes = 0
    state.advanceAfterLimitSelection(target)


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

# TODO: Option
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
    case input.toLowerAscii():
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
    case input.toLowerAscii():
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
    case input.toLowerAscii():
        of "y", "yes":
            state.watchPonder = true
        of "n", "no", "":
            state.watchPonder = false
        else:
            state.setStatus("Black engine pondering? [y]es / [N]o", persistent=true)
            return
    beginGame(state)


proc setupTakeback(state: AppState, input: string) =
    case input.toLowerAscii():
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
    case input.toLowerAscii():
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
    state.gameStartFEN = state.board.position.toFEN(state.chess960)
    state.startFEN = state.gameStartFEN
    if not state.watchMode:
        state.lastPlayRematch = PlayRematchConfig(
            available: true,
            startFEN: state.gameStartFEN,
            chess960: state.chess960,
            variant: state.variant,
            sideSelection: state.playSideSelection,
            playerLimit: state.playerLimit,
            engineLimit: state.engineLimit,
            allowTakeback: state.allowTakeback,
            allowPonder: state.allowPonder
        )
    if state.watchMode:
        if state.playerLimit == state.engineLimit:
            state.gameTimeControl = "Engine vs Engine: " & formatConfiguredLimit(state.playerLimit)
        else:
            state.gameTimeControl =
                "Engine vs Engine: White " & formatConfiguredLimit(state.playerLimit) &
                " vs Black " & formatConfiguredLimit(state.engineLimit)
    elif state.playerLimit == state.engineLimit:
        state.gameTimeControl = formatConfiguredLimit(state.playerLimit)
    else:
        state.gameTimeControl = formatConfiguredLimit(state.playerLimit) & " vs " & formatConfiguredLimit(state.engineLimit)

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


proc startRematch*(state: AppState) =
    ## Starts a fresh game using the last :play configuration.
    if not state.lastPlayRematch.available:
        state.setError("No previous :play game to rematch")
        return
    if state.mode == ModeReplay:
        state.setError("Exit replay mode first (:exit)")
        return
    if state.mode == ModePlay and state.watchMode:
        state.setError("Rematch is only available for :play games")
        return
    if state.mode == ModePlay and state.playPhase in [PlayerTurn, EngineTurn]:
        state.setError("Cannot start a rematch during an active game")
        return

    let rematch = state.lastPlayRematch

    if state.analysisRunning:
        stopAnalysis(state)

    state.mode = ModePlay
    state.watchMode = false
    state.watchSeparateConfig = false
    state.boardSetupMode = false
    state.boardSetupSpawnPiece = none(Piece)
    state.clearUserArrows()
    state.selectedSquare = none(Square)
    state.dragSourceSquare = none(Square)
    state.dragCursor = none(tuple[x, y: int])
    state.pendingPremoves = @[]
    state.legalDestinations = @[]
    state.clearMoveRecords()
    state.undoneHistory = @[]
    state.lastMove = none(tuple[fromSq, toSq: Square])
    state.pendingLimitTarget = NoPendingLimit
    state.pendingSoftNodes = 0
    state.playPhase = Setup
    state.setupStep = ChooseVariant
    state.gameResult = none(string)
    state.isPondering = false
    state.watchPonder = false
    state.isWatchPondering = false
    state.allowTakeback = rematch.allowTakeback
    state.allowPonder = rematch.allowPonder
    state.variant = rematch.variant
    state.chess960 = rematch.chess960
    state.playSideSelection = rematch.sideSelection
    state.searcher.state.chess960.store(state.chess960, moRelaxed)
    state.board = newChessboardFromFEN(rematch.startFEN)
    state.startFEN = rematch.startFEN
    state.playerLimit = rematch.playerLimit
    state.playerClock = limitClock(state.playerLimit)
    state.engineLimit = rematch.engineLimit
    state.engineClock = limitClock(state.engineLimit)
    state.engineDepth = if rematch.engineLimit.kind == PlayDepth: some(rematch.engineLimit.depth) else: none(int)
    state.watchDepth = none(int)

    case rematch.sideSelection:
        of SideWhite:
            state.playerColor = White
        of SideBlack:
            state.playerColor = Black
        of SideRandom:
            state.playerColor = if rand(1) == 0: White else: Black

    state.flipped = state.playerColor == Black
    beginGame(state)


proc handlePlaySetup*(state: AppState, input: string) =
    ## Processes user input during play mode setup
    case state.setupStep:
        of ChooseVariant:
            setupVariant(state, input)
        of ChooseSide:
            setupSide(state, input)
        of ChoosePlayerTime:
            setupPlayerTime(state, input)
        of ChooseEngineTime:
            setupEngineTime(state, input)
        of ChooseSoftNodesHardBound:
            setupSoftNodesHardBound(state, input)
        of ChooseSoftNodesHardLimit:
            setupSoftNodesHardLimit(state, input)
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
    if state.playerLimit.isTimeManaged() and state.playerClock.expired:
        let winner = if state.playerColor == White: "0-1" else: "1-0"
        state.gameResult = some(&"{winner} (time)")
        state.playPhase = GameOver
        state.playerClock.stop()
        state.engineClock.stop()
        state.setStatus(&"Time forfeit! {winner}")
        return true

    if state.engineLimit.isTimeManaged() and state.engineClock.expired:
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
    let limitConfig =
        if state.watchMode:
            if useSecond: state.engineLimit else: state.playerLimit
        else:
            state.engineLimit

    var engineLimits: seq[SearchLimit]
    if useSecond:
        startTrackedClock(state.engineClock, state.engineClockMoveStartMs)
        engineLimits = buildSearchLimits(limitConfig, state.engineClock)
    elif state.watchMode:
        startTrackedClock(state.playerClock, state.playerClockMoveStartMs)
        engineLimits = buildSearchLimits(limitConfig, state.playerClock)
    else:
        startTrackedClock(state.engineClock, state.engineClockMoveStartMs)
        engineLimits = buildSearchLimits(limitConfig, state.engineClock)

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
                        engineLimits: buildSearchLimits(state.engineLimit, state.engineClock)
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
                        engineLimits: buildSearchLimits(state.playerLimit, state.playerClock)
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
                        engineLimits: buildSearchLimits(state.engineLimit, state.engineClock)
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
    if state.playerLimit.isTimeManaged():
        state.playerClock.tick()
    if state.engineLimit.isTimeManaged():
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
