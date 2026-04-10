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

## Play/watch setup prompts and configuration parsing.

import std/[options, random, atomics, strutils, strformat, parseutils]

import illwill
import heimdall/[board, pieces, search, transpositions]
import heimdall/util/scharnagl
import heimdall/tui/[state, analysis]
import heimdall/tui/play/[common, runtime]
import heimdall/tui/util/clock


proc setSetupPrompt(state: AppState, kind: PlaySetupKind, prompt: string) =
    state.play.setup = PlaySetupState(kind: kind)
    state.setStatus(prompt, persistent=true)


proc startLimitSelection(
    state: AppState,
    target: SetupLimitTarget,
    prompt: string,
    invalidExamples: string,
    allowSame = false,
    sameLimit = PlayLimitConfig()
) =
    state.play.setup = PlaySetupState(
        kind: SetupChooseLimit,
        limitConfig: (
            target: target,
            allowSame: allowSame,
            sameLimit: sameLimit,
            invalidExamples: invalidExamples
        )
    )
    state.setStatus(prompt, persistent=true)


proc advanceAfterLimitSelection(state: AppState, target: SetupLimitTarget) =
    case target:
        of EngineLimitTarget:
            state.setSetupPrompt(SetupChooseTakeback, "Allow takeback? [y]es / [N]o")
        of WatchWhiteLimitTarget:
            state.startLimitSelection(
                WatchBlackLimitTarget,
                "Black engine limits (combine with commas, e.g. 5m+3s, depth 20):",
                WatchBlackLimitExamples,
                allowSame=true,
                sameLimit=state.play.playerLimit
            )
        of WatchBlackLimitTarget, WatchSharedLimitTarget:
            state.play.allowTakeback = false
            if state.play.watchSeparateConfig:
                state.setSetupPrompt(
                    SetupChooseWatchThreads,
                    &"White engine threads (current: {state.engineThreads}, Enter to keep):"
                )
            else:
                state.setSetupPrompt(
                    SetupChooseWatchThreads,
                    &"Threads (shared, current: {state.engineThreads}, Enter to keep):"
                )


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


proc mergeLimit(existing, extra: PlayLimitConfig): tuple[limit: PlayLimitConfig, error: string] =
    result.limit = existing

    if extra.timeControl.isSome():
        if result.limit.timeControl.isSome():
            return (result.limit, "Time control specified more than once")
        result.limit.timeControl = extra.timeControl

    if extra.depth.isSome():
        if result.limit.depth.isSome():
            return (result.limit, "Depth specified more than once")
        result.limit.depth = extra.depth

    if extra.nodeLimit.isSome():
        if result.limit.nodeLimit.isNone():
            result.limit.nodeLimit = extra.nodeLimit
        else:
            let extraNodeLimit = extra.nodeLimit.get()
            var mergedNodeLimit = result.limit.nodeLimit.get()

            if extraNodeLimit.softNodes.isSome():
                if mergedNodeLimit.softNodes.isSome():
                    return (result.limit, "Soft node limit specified more than once")
                mergedNodeLimit.softNodes = extraNodeLimit.softNodes

            if extraNodeLimit.hardNodes.isSome():
                if mergedNodeLimit.hardNodes.isSome():
                    return (result.limit, "Hard node limit specified more than once")
                mergedNodeLimit.hardNodes = extraNodeLimit.hardNodes

            result.limit.nodeLimit = some(mergedNodeLimit)


proc parseEngineLimits(input: string, config: LimitSetupConfig): tuple[limit: PlayLimitConfig, error: string] =
    let stripped = input.strip().toLowerAscii()

    if config.allowSame and stripped == "same":
        return (config.sameLimit, "")

    var limit = newUnlimitedPlayLimit()
    let rawClauses = stripped.split(",")
    var clauses: seq[string]
    for clause in rawClauses:
        let normalized = clause.strip()
        if normalized.len > 0:
            clauses.add(normalized)

    if clauses.len == 0:
        return (limit, "Invalid engine limits. Examples: " & config.invalidExamples)

    for clause in clauses:
        var clauseLimit = newUnlimitedPlayLimit()

        if clause.startsWith("depth"):
            let parts = clause.splitWhitespace()
            if parts.len < 2:
                return (limit, "Usage: depth <number>")
            try:
                let depth = parseInt(parts[1])
                if depth < 1:
                    return (limit, "Depth must be at least 1")
                clauseLimit = newDepthPlayLimit(depth)
            except ValueError:
                return (limit, "Invalid depth. Examples: depth 20")

        elif clause.startsWith("nodes"):
            let parts = clause.splitWhitespace()
            if parts.len < 2:
                return (limit, "Usage: nodes <count>")
            let (nodes, ok) = parsePositiveNodeCount(parts[1])
            if not ok:
                return (limit, "Invalid node count. Example: nodes 200000")
            clauseLimit = newNodePlayLimit(nodes)

        elif clause.startsWith("softnodes"):
            let parts = clause.splitWhitespace()
            if parts.len < 2:
                return (limit, "Usage: softnodes <count>")
            let (softNodes, ok) = parsePositiveNodeCount(parts[1])
            if not ok:
                return (limit, "Invalid node count. Example: softnodes 100000")
            clauseLimit = newSoftNodePlayLimit(softNodes, none(uint64))

        else:
            let (timeMs, incMs, ok) = parseTimeControl(clause)
            if not ok:
                return (limit, "Invalid engine limits. Examples: " & config.invalidExamples)
            clauseLimit = newTimeOrUnlimitedLimit(timeMs, incMs)

        let merged = mergeLimit(limit, clauseLimit)
        if merged.error.len > 0:
            return (limit, merged.error)
        limit = merged.limit

    result.limit = limit


proc startSoftNodesFollowup(state: AppState, target: SetupLimitTarget, limit: PlayLimitConfig) =
    state.play.setup = PlaySetupState(
        kind: SetupChooseSoftNodesHardLimit,
        softNodeConfig: (target: target, limit: limit, stage: SoftNodeAskHardCap)
    )
    state.setStatus("Set a hard node cap as well? [y]es / [N]o", persistent=true)


proc configureEngineLikeLimit(state: AppState, input: string, config: LimitSetupConfig) =
    let parsed = parseEngineLimits(input, config)
    if parsed.error.len > 0:
        state.setStatus(parsed.error, persistent=true)
        return

    if parsed.limit.nodeLimit.isSome() and
       parsed.limit.nodeLimit.get().softNodes.isSome() and
       parsed.limit.nodeLimit.get().hardNodes.isNone():
        state.startSoftNodesFollowup(config.target, parsed.limit)
        return

    state.applyLimitToTarget(config.target, parsed.limit)
    state.advanceAfterLimitSelection(config.target)


proc setupVariant(state: AppState, input: string) =
    case input.toLowerAscii():
        of "s", "standard", "":
            state.play.variant = Standard
            state.chess960 = false
            state.searcher.state.chess960.store(false, moRelaxed)
            state.board = newDefaultChessboard()
        of "f", "frc":
            state.play.variant = FischerRandom
            state.chess960 = true
            state.searcher.state.chess960.store(true, moRelaxed)
            let n = rand(959)
            state.board = newChessboardFromFEN(scharnaglToFEN(n))
            state.setStatus(&"FRC position #{n}")
        of "d", "dfrc":
            state.play.variant = DoubleFischerRandom
            state.chess960 = true
            state.searcher.state.chess960.store(true, moRelaxed)
            let w = rand(959)
            let b = rand(959)
            state.board = newChessboardFromFEN(scharnaglToFEN(w, b))
            state.setStatus(&"DFRC position W: {w} B: {b}")
        of "c", "current":
            discard
        else:
            state.setStatus("Choose variant: [S]tandard / [f]rc / [d]frc / [c]urrent", persistent=true)
            return

    state.clearMoveRecords()
    state.lastMove = none(tuple[fromSq, toSq: Square])

    if state.play.watchMode:
        state.play.playerColor = White
        state.setSetupPrompt(SetupChooseWatchSeparate, "Configure engines separately? [y]es / [N]o")
    else:
        state.setSetupPrompt(SetupChooseSide, "Play as: [w]hite / [b]lack / [R]andom")


proc setupSide(state: AppState, input: string) =
    case input.toLowerAscii():
        of "w", "white":
            state.play.sideSelection = SideWhite
            state.play.playerColor = White
        of "b", "black":
            state.play.sideSelection = SideBlack
            state.play.playerColor = Black
        of "r", "random", "":
            state.play.sideSelection = SideRandom
            state.play.playerColor = if rand(1) == 0: White else: Black
        else:
            state.setStatus("Play as: [w]hite / [b]lack / [R]andom", persistent=true)
            return

    state.flipped = state.play.playerColor == Black
    state.setSetupPrompt(SetupChoosePlayerTime, "Your time control (e.g. 5m+3s, 10m, 1h+30s, none):")


proc setupPlayerTime(state: AppState, input: string) =
    let (timeMs, incMs, ok) = parseTimeControl(input)
    if not ok:
        state.setStatus("Invalid time control. Examples: 5m+3s, 10m, 90s, none", persistent=true)
        return

    state.play.playerLimit = newTimeOrUnlimitedLimit(timeMs, incMs)
    state.play.playerClock = limitClock(state.play.playerLimit)
    state.startLimitSelection(
        EngineLimitTarget,
        "Engine limits (combine with commas, e.g. 5m+3s, depth 20):",
        EngineLimitExamples,
        allowSame=true,
        sameLimit=state.play.playerLimit
    )


proc setupWatchSeparate(state: AppState, input: string) =
    case input.toLowerAscii():
        of "y", "yes":
            state.play.watchSeparateConfig = true
            state.startLimitSelection(
                WatchWhiteLimitTarget,
                "White engine limits (combine with commas, e.g. 5m+3s, depth 20):",
                WatchLimitExamples
            )
        of "n", "no", "":
            state.play.watchSeparateConfig = false
            state.startLimitSelection(
                WatchSharedLimitTarget,
                "Limits for both engines (combine with commas, e.g. 5m+3s, depth 20):",
                WatchLimitExamples
            )
        else:
            state.setStatus("Configure engines separately? [y]es / [N]o", persistent=true)


proc setupSoftNodesHardLimit(state: AppState, input: string) =
    let config = state.play.setup.softNodeConfig
    let nodeLimit = config.limit.nodeLimit.get()
    case config.stage:
        of SoftNodeAskHardCap:
            let softNodes = nodeLimit.softNodes.get()
            case input.toLowerAscii():
                of "y", "yes":
                    state.play.setup = PlaySetupState(
                        kind: SetupChooseSoftNodesHardLimit,
                        softNodeConfig: (target: config.target, limit: config.limit, stage: SoftNodeEnterHardCap)
                    )
                    state.setStatus(&"Hard node cap (must be >= {softNodes}):", persistent=true)
                of "n", "no", "":
                    state.applyLimitToTarget(config.target, config.limit)
                    state.advanceAfterLimitSelection(config.target)
                else:
                    state.setStatus("Set a hard node cap as well? [y]es / [N]o", persistent=true)
        of SoftNodeEnterHardCap:
            let softNodes = nodeLimit.softNodes.get()
            let (hardNodes, ok) = parsePositiveNodeCount(input)
            if not ok:
                state.setStatus("Invalid node count. Example: 250000", persistent=true)
                return
            if hardNodes < softNodes:
                state.setStatus(&"Hard node cap must be at least {softNodes}", persistent=true)
                return
            var limit = config.limit
            limit.nodeLimit = some(NodeLimitConfig(softNodes: some(softNodes), hardNodes: some(hardNodes)))
            state.applyLimitToTarget(config.target, limit)
            state.advanceAfterLimitSelection(config.target)


proc setupWatchThreads(state: AppState, input: string) =
    let stripped = input.strip()
    if stripped.len > 0:
        try:
            let n = parseInt(stripped)
            if n < 1 or n > 1024:
                let prompt =
                    if state.play.watchSeparateConfig: "White engine threads must be 1-1024:"
                    else: "Threads must be 1-1024:"
                state.setStatus(prompt, persistent=true)
                return
            state.engineThreads = n
            state.searcher.setWorkerCount(n - 1)
        except ValueError:
            let prompt =
                if state.play.watchSeparateConfig: "Invalid number. Enter White engine thread count:"
                else: "Invalid number. Enter thread count:"
            state.setStatus(prompt, persistent=true)
            return

    if state.play.watchSeparateConfig:
        state.setSetupPrompt(
            SetupChooseWatchHash,
            &"White engine hash (current: {state.engineHash} MiB, Enter to keep):"
        )
    else:
        state.setSetupPrompt(
            SetupChooseWatchHash,
            &"Hash size (shared, current: {state.engineHash} MiB, Enter to keep):"
        )


proc parseHashInput(input: string): tuple[sizeMiB: Option[int64], ok: bool] =
    let stripped = input.strip()
    if stripped.len == 0:
        return (none(int64), true)
    try:
        let n = parseBiggestInt(stripped)
        if n < 1 or n > 33554432:
            return (none(int64), false)
        return (some(n), true)
    except ValueError:
        var sizeBytes: int64
        let consumed = parseSize(stripped, sizeBytes)
        if consumed == 0:
            return (none(int64), false)
        let sizeMiB = sizeBytes div (1024 * 1024)
        if sizeMiB < 1 or sizeMiB > 33554432:
            return (none(int64), false)
        return (some(sizeMiB), true)


proc setupWatchHash(state: AppState, input: string) =
    let (sizeMiB, ok) = parseHashInput(input)
    if not ok:
        let prompt =
            if state.play.watchSeparateConfig: "Invalid size for White engine hash. Examples: 64, 1 GB, 256 MiB:"
            else: "Invalid size. Examples: 64, 1 GB, 256 MiB:"
        state.setStatus(prompt, persistent=true)
        return
    if sizeMiB.isSome():
        if state.ttable.resize(sizeMiB.get().uint64 * 1024 * 1024):
            state.engineHash = sizeMiB.get().uint64
        else:
            state.setStatus("Failed to resize White engine hash table", persistent=true)
            return

    if state.play.watchSeparateConfig:
        state.play.watch.threads = state.engineThreads
        state.play.watch.hash = state.engineHash
        state.setSetupPrompt(
            SetupChooseWatchBlackThreads,
            &"Black engine threads (Enter = same as White: {state.engineThreads}):"
        )
    else:
        state.play.watch.threads = state.engineThreads
        state.play.watch.hash = state.engineHash
        state.setSetupPrompt(SetupChooseWatchPonder, "Enable pondering for both engines? [y]es / [N]o")


proc setupWatchBlackThreads(state: AppState, input: string) =
    let stripped = input.strip()
    if stripped.len > 0:
        try:
            let n = parseInt(stripped)
            if n < 1 or n > 1024:
                state.setStatus("Threads must be 1-1024:", persistent=true)
                return
            state.play.watch.threads = n
        except ValueError:
            state.setStatus("Invalid number:", persistent=true)
            return

    state.setSetupPrompt(
        SetupChooseWatchBlackHash,
        &"Black engine hash (Enter = same as White: {state.engineHash} MiB):"
    )


proc setupWatchBlackHash(state: AppState, input: string) =
    let (sizeMiB, ok) = parseHashInput(input)
    if not ok:
        state.setStatus("Invalid size. Examples: 64, 1 GB, 256 MiB:", persistent=true)
        return
    if sizeMiB.isSome():
        state.play.watch.hash = sizeMiB.get().uint64

    state.setSetupPrompt(SetupChooseWatchWhitePonder, "White engine pondering? [y]es / [N]o")


proc setupWatchPonder(state: AppState, input: string) =
    case input.toLowerAscii():
        of "y", "yes":
            state.play.allowPonder = true
            state.play.watch.allowPonder = true
        of "n", "no", "":
            state.play.allowPonder = false
            state.play.watch.allowPonder = false
        else:
            state.setStatus("Enable pondering for both engines? [y]es / [N]o", persistent=true)
            return
    beginGame(state)


proc setupWatchWhitePonder(state: AppState, input: string) =
    case input.toLowerAscii():
        of "y", "yes":
            state.play.allowPonder = true
        of "n", "no", "":
            state.play.allowPonder = false
        else:
            state.setStatus("White engine pondering? [y]es / [N]o", persistent=true)
            return
    state.setSetupPrompt(SetupChooseWatchBlackPonder, "Black engine pondering? [y]es / [N]o")


proc setupWatchBlackPonder(state: AppState, input: string) =
    case input.toLowerAscii():
        of "y", "yes":
            state.play.watch.allowPonder = true
        of "n", "no", "":
            state.play.watch.allowPonder = false
        else:
            state.setStatus("Black engine pondering? [y]es / [N]o", persistent=true)
            return
    beginGame(state)


proc setupTakeback(state: AppState, input: string) =
    case input.toLowerAscii():
        of "y", "yes":
            state.play.allowTakeback = true
        of "n", "no", "":
            state.play.allowTakeback = false
        else:
            state.setStatus("Allow takeback? [y]es / [N]o", persistent=true)
            return
    state.setSetupPrompt(SetupChoosePonder, "Enable pondering? [y]es / [N]o")


proc setupPonder(state: AppState, input: string) =
    case input.toLowerAscii():
        of "y", "yes":
            state.play.allowPonder = true
        of "n", "no", "":
            state.play.allowPonder = false
        else:
            state.setStatus("Enable pondering? [y]es / [N]o", persistent=true)
            return
    beginGame(state)


proc startPlayMode*(state: AppState) =
    if state.analysis.running:
        stopAnalysis(state)
    state.preparePlaySetup()
    state.play.playerLimit = newUnlimitedPlayLimit()
    state.play.engineLimit = newUnlimitedPlayLimit()
    state.play.sideSelection = SideRandom
    state.play.watch.allowPonder = false
    state.play.watch.isPondering = false
    state.setStatus("Choose variant: [S]tandard / [f]rc / [d]frc / [c]urrent", persistent=true)


proc handlePlaySetup*(state: AppState, input: string) =
    case state.play.setup.kind:
        of SetupChooseVariant:
            setupVariant(state, input)
        of SetupChooseSide:
            setupSide(state, input)
        of SetupChoosePlayerTime:
            setupPlayerTime(state, input)
        of SetupChooseLimit:
            configureEngineLikeLimit(state, input, state.play.setup.limitConfig)
        of SetupChooseSoftNodesHardLimit:
            setupSoftNodesHardLimit(state, input)
        of SetupChooseTakeback:
            setupTakeback(state, input)
        of SetupChoosePonder:
            setupPonder(state, input)
        of SetupChooseWatchSeparate:
            setupWatchSeparate(state, input)
        of SetupChooseWatchThreads:
            setupWatchThreads(state, input)
        of SetupChooseWatchHash:
            setupWatchHash(state, input)
        of SetupChooseWatchBlackThreads:
            setupWatchBlackThreads(state, input)
        of SetupChooseWatchBlackHash:
            setupWatchBlackHash(state, input)
        of SetupChooseWatchPonder:
            setupWatchPonder(state, input)
        of SetupChooseWatchWhitePonder:
            setupWatchWhitePonder(state, input)
        of SetupChooseWatchBlackPonder:
            setupWatchBlackPonder(state, input)


proc setupShortcutInput*(state: AppState, key: Key): Option[string] =
    case state.play.setup.kind:
        of SetupChooseVariant:
            case key:
                of Key.S, Key.ShiftS, Key.Enter:
                    return some("s")
                of Key.F, Key.ShiftF:
                    return some("f")
                of Key.D, Key.ShiftD:
                    return some("d")
                of Key.C, Key.ShiftC:
                    return some("c")
                else:
                    discard
        of SetupChooseSide:
            case key:
                of Key.W, Key.ShiftW:
                    return some("w")
                of Key.B, Key.ShiftB:
                    return some("b")
                of Key.R, Key.ShiftR, Key.Enter:
                    return some("r")
                else:
                    discard
        of SetupChooseTakeback, SetupChoosePonder, SetupChooseWatchSeparate,
           SetupChooseWatchPonder, SetupChooseWatchWhitePonder, SetupChooseWatchBlackPonder:
            case key:
                of Key.Y, Key.ShiftY:
                    return some("y")
                of Key.N, Key.ShiftN, Key.Enter:
                    return some("n")
                else:
                    discard
        of SetupChooseSoftNodesHardLimit:
            case state.play.setup.softNodeConfig.stage:
                of SoftNodeAskHardCap:
                    case key:
                        of Key.Y, Key.ShiftY:
                            return some("y")
                        of Key.N, Key.ShiftN, Key.Enter:
                            return some("n")
                        else:
                            discard
                of SoftNodeEnterHardCap:
                    discard
        else:
            discard

    none(string)
