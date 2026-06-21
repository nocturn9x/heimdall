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

## Implementation of the UCI search worker thread

import heimdall/[board, search, movegen, pieces as pcs]
import heimdall/util/[limits, logs]

import std/[os, random, atomics, options, terminal, strformat]

import heimdall/uci/shared

randomize()


proc createSearchWorker*(session: UCISession): UCISearchWorker =
    new(result)
    result.channels.receive.open(0)
    result.channels.send.open(0)
    result.session = session

proc getResponse*(worker: UCISearchWorker): WorkerResponse {.inline.} =
    return worker.channels.send.recv()

proc getAction*(worker: UCISearchWorker): WorkerCommand {.inline.} =
    return worker.channels.receive.recv()

proc waitFor*(worker: UCISearchWorker, response: WorkerResponse) {.inline.} =
    doAssert worker.getResponse() == response

func simpleCmd*(kind: WorkerAction): WorkerCommand = WorkerCommand(kind: kind)

proc sendAction*(worker: UCISearchWorker, command: WorkerCommand) {.inline.} =
    worker.channels.receive.send(command)

proc sendResponse*(worker: UCISearchWorker, response: WorkerResponse) {.inline.} =
    worker.channels.send.send(response)


proc searchWorkerLoop*(self: UCISearchWorker) {.thread.} =
    ## Finds the best move in the current position and
    ## prints it

    while true:
        let action = self.getAction()
        if self.session.debug:
            echo &"info string worker received action: {action.kind}"
        case action.kind:
            of Exit:
                if self.session.debug:
                    echo &"info string worker shutting down"
                self.sendResponse(Exiting)
                break
            of Search:
                if self.session.debug:
                    echo &"info string worker beginning search on UCI command {action.command}"
                var
                    timeRemaining = (if self.session.board.position.sideToMove == White: action.command.wtime else: action.command.btime)
                    increment = (if self.session.board.position.sideToMove == White: action.command.winc else: action.command.binc)
                    timePerMove = action.command.moveTime.isSome()

                if not self.session.enableWeirdTCs and not (timePerMove or timeRemaining.isNone()) and (increment.isNone() or increment.get() == 0):
                    if self.session.isMixedMode:
                        stderr.styledWrite(self.session.useColor, fgRed, "Error: ", fgYellow, NO_INCREMENT_TC_DETECTED, "\n")
                    else:
                        stderr.writeLine(&"info string {NO_INCREMENT_TC_DETECTED}")
                        # Resign
                        echo "bestmove 0000"
                    continue
                # Code duplication is ugly, but the condition would get ginormous if I were to do it in one if statement
                if not self.session.enableWeirdTCs and (action.command.movesToGo.isSome() and action.command.movesToGo.get() != 0):
                    # We don't even implement the movesToGo TC (it's old af), so this warning is especially
                    # meaningful
                    if self.session.isMixedMode:
                        stderr.styledWrite(self.session.useColor, fgRed, "Error: ", fgYellow, CYCLIC_TC_DETECTED, "\n")
                    else:
                        stderr.writeLine(&"info string {CYCLIC_TC_DETECTED}")
                        echo "bestmove 0000"
                    continue
                # Setup search limits

                # Remove limits from previous search
                self.session.searcher.limiter.clear()
                self.session.searcher.state.mateDepth.store(none(int), moRelaxed)

                # Add limits from new UCI command. Multiple limits are supported!
                if action.command.depth.isSome():
                    self.session.searcher.limiter.addLimit(newDepthLimit(action.command.depth.get()))
                if action.command.nodes.isSome():
                    if not self.session.datagenMode:
                        # When not in datagen mode, the values of UseSoftNodes and HardNodeLimit are ignored:
                        # the limit in the go command is always a hard limit
                        self.session.searcher.limiter.addLimit(newNodeLimit(action.command.nodes.get()))
                    else:
                        # If in datagen mode, but not using soft nodes, the node limit is the smallest between
                        # the globally configured limit (if nonzero) and the one provided in the go command
                        if not self.session.useSoftNodes:
                            let limit = block:
                                if self.session.hardNodeLimit > 0:
                                    min(self.session.hardNodeLimit.uint64, action.command.nodes.get())
                                else:
                                    action.command.nodes.get()
                            self.session.searcher.limiter.addLimit(newNodeLimit(limit))
                        else:
                            # Otherwise, use the limit in the go command as the soft limit (with some extra bits
                            # for soft limit randomization) and the globally configured limit (if nonzero) as the
                            # hard limit. If the hard limit is smaller than the soft limit, then it will be overridden
                            # by the soft limit
                            let softLimit = block:
                                let
                                    minimum = action.command.nodes.get()
                                    maximum = max(action.command.nodes.get(), self.session.softNodeRandomLimit.uint64)
                                if maximum != minimum:
                                    rand(minimum..maximum)
                                else:
                                    minimum
                            let hardLimit = max(self.session.hardNodeLimit.uint64, softLimit)
                            self.session.searcher.limiter.addLimit(newNodeLimit(softLimit, hardLimit))

                if timeRemaining.isSome():
                    if increment.isSome():
                        self.session.searcher.limiter.addLimit(newTimeLimit(timeRemaining.get(), increment.get(), self.session.overhead))
                    else:
                        self.session.searcher.limiter.addLimit(newTimeLimit(timeRemaining.get(), 0, self.session.overhead))

                if timePerMove:
                    self.session.searcher.limiter.addLimit(newTimeLimit(action.command.moveTime.get(), self.session.overhead))

                if action.command.mate.isSome():
                    let depth = action.command.mate.get()
                    self.session.searcher.state.mateDepth.store(some(depth), moRelaxed)
                    self.session.searcher.limiter.addLimit(newMateLimit(depth))

                if self.session.isMixedMode:
                    var hasLimits = false

                    stdout.styledWrite(self.session.useColor, fgGreen, "Searching")

                    if action.command.depth.isSome():
                        stdout.styledWrite(self.session.useColor, fgGreen, " to depth ", styleBright, fgYellow, $action.command.depth.get(), resetStyle)
                        hasLimits = true

                    if action.command.nodes.isSome():
                        let nodeLimit = block:
                            if not self.session.datagenMode:
                                action.command.nodes.get()
                            else:
                                if not self.session.useSoftNodes:
                                    if self.session.hardNodeLimit > 0:
                                        min(self.session.hardNodeLimit.uint64, action.command.nodes.get())
                                    else:
                                        action.command.nodes.get()
                                else:
                                    let minimum = action.command.nodes.get()
                                    let maximum = max(action.command.nodes.get(), self.session.softNodeRandomLimit.uint64)
                                    if maximum != minimum:
                                        maximum  # Show max possible
                                    else:
                                        minimum
                        if hasLimits:
                            stdout.styledWrite(self.session.useColor, fgGreen, ", up to ", styleBright, fgYellow, $nodeLimit, resetStyle, fgGreen, " nodes", resetStyle)
                        else:
                            stdout.styledWrite(self.session.useColor, fgGreen, " up to ", styleBright, fgYellow, $nodeLimit, resetStyle, fgGreen, " nodes", resetStyle)
                        hasLimits = true

                    if timeRemaining.isSome():
                        let timeMs = timeRemaining.get()
                        let timeDur = msToDuration(timeMs)
                        if increment.isSome() and increment.get() > 0:
                            let incDur = msToDuration(increment.get())
                            if hasLimits:
                                stdout.styledWrite(self.session.useColor, fgGreen, ", ", styleBright, fgYellow, $timeDur, resetStyle, fgGreen, " + ", styleBright, fgYellow, $incDur, resetStyle, fgGreen, " per move", resetStyle)
                            else:
                                stdout.styledWrite(self.session.useColor, fgGreen, " with ", styleBright, fgYellow, $timeDur, resetStyle, fgGreen, " + ", styleBright, fgYellow, $incDur, resetStyle, fgGreen, " per move", resetStyle)
                        else:
                            if hasLimits:
                                stdout.styledWrite(self.session.useColor, fgGreen, ", ", styleBright, fgYellow, $timeDur, resetStyle, fgGreen, " remaining", resetStyle)
                            else:
                                stdout.styledWrite(self.session.useColor, fgGreen, " with ", styleBright, fgYellow, $timeDur, resetStyle, fgGreen, " remaining", resetStyle)
                        hasLimits = true

                    if timePerMove:
                        let moveDur = msToDuration(action.command.moveTime.get())
                        if hasLimits:
                            stdout.styledWrite(self.session.useColor, fgGreen, ", for at most ", styleBright, fgYellow, $moveDur)
                        else:
                            stdout.styledWrite(self.session.useColor, fgGreen, " for ", styleBright, fgYellow, $moveDur, resetStyle)
                        hasLimits = true

                    if action.command.mate.isSome():
                        if hasLimits:
                            stdout.styledWrite(self.session.useColor, fgGreen, ", mate in ", styleBright, fgYellow, $action.command.mate.get(), resetStyle)
                        else:
                            stdout.styledWrite(self.session.useColor, fgGreen, " for mate in ", styleBright, fgYellow, $action.command.mate.get(), resetStyle)
                        hasLimits = true

                    if action.command.infinite:
                        if hasLimits:
                            stdout.styledWrite(self.session.useColor, fgGreen, " (infinite)", resetStyle)
                        else:
                            stdout.styledWrite(self.session.useColor, fgGreen, " indefinitely", resetStyle)

                    stdout.styledWrite(self.session.useColor, "\n")
                    stdout.flushFile()

                if action.command.ponder and not self.session.canPonder:
                    # Since some GUIs might misbehave, we require that Ponder be set to
                    # true to start a search when go ponder is detected. This should make
                    # it obvious that there's a problem!
                    if self.session.isMixedMode:
                        stderr.styledWrite(self.session.useColor, fgRed, "Error: ", fgYellow, PONDER_OPT_REQUIRED)
                    else:
                        stderr.writeLine(&"info string {PONDER_OPT_REQUIRED}", "\n")
                        echo "bestmove 0000"
                    continue

                self.session.searcher.setBoard(self.session.board.positions)
                var line = self.session.searcher.search(action.command.searchmoves, false, self.session.canPonder and action.command.ponder,
                                                        self.session.minimal, self.session.variations)[0]
                let chess960 = self.session.searcher.state.chess960.load(moRelaxed)
                for move in line.moves.mitems():
                    if move == nullMove():
                        break
                    if move.isCastling() and not chess960:
                        # Hide the fact we're using FRC internally
                        if move.isLongCastling():
                            move.targetSquare = makeSquare(rank(move.targetSquare), file(move.targetSquare) + pcs.File(2))
                        else:
                            move.targetSquare = makeSquare(rank(move.targetSquare), file(move.targetSquare) - pcs.File(1))
                # No limit has expired but the search has completed:
                # If this is a `go infinite` command, UCI tells us we must
                # not print a best move until we're told to stop explicitly,
                # so we spin until that happens
                if action.command.infinite:
                    while not self.session.searcher.shouldStop():
                        # Sleep for 10ms
                        sleep(10)
                if line.moves[0] == nullMove():
                    # No best move. Well shit. Usually this only happens at insanely low TCs
                    # so we just pick a random legal move
                    var moves = newMoveList()
                    var board = newChessboard(@[self.session.searcher.getCurrentPosition().clone()])
                    board.generateMoves(moves)
                    line.moves[0] = moves[rand(0..moves.high())]
                if not self.session.isMixedMode:
                    if line.moves[1] != nullMove():
                        echo &"bestmove {line.moves[0].toUCI()} ponder {line.moves[1].toUCI()}"
                    else:
                        echo &"bestmove {line.moves[0].toUCI()}"
                else:
                    if line.moves[1] != nullMove():
                        styledWrite(stdout, self.session.useColor, fgGreen, "Best move: ", styleBright, fgWhite, line.moves[0].toUCI(), "\n",
                                    resetStyle, fgCyan, "Best response: ", styleBright, fgWhite, line.moves[1].toUCI(), "\n")
                    else:
                        styledWrite(stdout, self.session.useColor, fgGreen, "Best move: ", styleBright, fgWhite, line.moves[0].toUCI(), "\n")
                if self.session.debug:
                    echo "info string worker has finished searching"
                if self.session.isMixedMode and not self.session.searcher.cancelled():
                    # Search exited because an internal limit was hit: make sure the command
                    # prompt is reprinted
                    stdout.styledWrite(self.session.useColor, fgYellow, "cmd> ")
                    stdout.flushFile()
                self.session.isInfiniteSearch = false
                self.sendResponse(SearchComplete)
