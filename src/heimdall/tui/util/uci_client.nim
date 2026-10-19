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

## Minimal UCI client used by the TUI watch mode for external engines.

import std/[os, osproc, streams, strutils, strformat, options]

import heimdall/[board, moves, movegen, position, eval, pieces]
import heimdall/util/move_parse
import heimdall/tui/util/notation


type
    UCIEngineLimit* = object
        hasTime*: bool
        whiteTimeMs*: int64
        blackTimeMs*: int64
        whiteIncrementMs*: int64
        blackIncrementMs*: int64
        depth*: Option[int]
        nodes*: Option[uint64]

    UCIOptionSetting* = object
        name*: string
        value*: string

    UCIClient* = ref object
        process: Process
        input: Stream
        output: Stream
        commandLine*: string
        name*: string
        supportsPonder*: bool
        supportsChess960*: bool
        supportsThreads*: bool
        supportsHash*: bool
        lastNodes*: uint64

    UCIEngineInfo* = object
        positionKey*: uint64
        sideToMove*: PieceColor
        depth*: int
        multipv*: int
        hasScore*: bool
        score*: Score
        pv*: seq[Move]
        nodes*: uint64
        nps*: uint64

    UCIEngineMoveResult* = object
        bestMove*: Move
        ponderMove*: Move
        nodes*: uint64
        error*: string


proc sendLine(client: UCIClient, line: string) =
    if client == nil or client.input == nil:
        raise newException(IOError, "UCI engine is not running")
    client.input.writeLine(line)
    client.input.flush()


proc readLine(client: UCIClient): string =
    if client == nil or client.output == nil:
        raise newException(IOError, "UCI engine is not running")
    if not client.output.readLine(result):
        raise newException(IOError, "UCI engine closed its output")


proc parseOption(client: UCIClient, line: string) =
    let lower = line.toLowerAscii()
    if lower.startsWith("option name ponder "):
        client.supportsPonder = true
    elif lower.startsWith("option name uci_chess960 "):
        client.supportsChess960 = true
    elif lower.startsWith("option name threads "):
        client.supportsThreads = true
    elif lower.startsWith("option name hash "):
        client.supportsHash = true


proc parseMateScore(moves: int): Score =
    let plies = max(1, abs(moves) * 2 - 1)
    if moves >= 0:
        mateIn(plies)
    else:
        matedIn(plies)


proc parsePV(parts: seq[string], startIdx: int, position: Position, chess960: bool): seq[Move] =
    var preview = newChessboard(@[position.clone()])
    for i in startIdx..<parts.len:
        let parsed = move_parse.parseUCIMove(preview.position, parts[i], chess960=chess960, requireSourcePiece=true)
        if parsed.error.hasError():
            break
        let move = preview.makeMove(parsed.move)
        if move == nullMove():
            break
        result.add(move)


proc parseInfo(client: UCIClient, line: string, positions: seq[Position], chess960: bool): UCIEngineInfo =
    let parts = line.splitWhitespace()
    result.multipv = 1
    if positions.len > 0:
        result.positionKey = positions[positions.high].zobristKey.uint64
        result.sideToMove = positions[positions.high].sideToMove
    var i = 1
    while i < parts.len:
        case parts[i]:
            of "depth":
                if i + 1 < parts.len:
                    try:
                        result.depth = parseInt(parts[i + 1])
                    except ValueError:
                        discard
                    inc i
            of "multipv":
                if i + 1 < parts.len:
                    try:
                        result.multipv = max(1, parseInt(parts[i + 1]))
                    except ValueError:
                        discard
                    inc i
            of "score":
                if i + 2 < parts.len:
                    try:
                        case parts[i + 1]:
                            of "cp":
                                result.score = Score(parseInt(parts[i + 2]))
                                result.hasScore = true
                            of "mate":
                                result.score = parseMateScore(parseInt(parts[i + 2]))
                                result.hasScore = true
                            else:
                                discard
                    except ValueError:
                        discard
                    inc i, 2
            of "nodes":
                if i + 1 < parts.len:
                    try:
                        result.nodes = parseBiggestUInt(parts[i + 1]).uint64
                        client.lastNodes = result.nodes
                    except ValueError:
                        discard
                    inc i
            of "nps":
                if i + 1 < parts.len:
                    try:
                        result.nps = parseBiggestUInt(parts[i + 1]).uint64
                    except ValueError:
                        discard
                    inc i
            of "pv":
                if positions.len > 0:
                    result.pv = parsePV(parts, i + 1, positions[positions.high], chess960)
                return
            else:
                discard
        inc i


proc waitForToken(client: UCIClient, token: string) =
    while true:
        let line = client.readLine().strip()
        if line.len == 0:
            continue
        if line.startsWith("id name "):
            client.name = line["id name ".len..^1].strip()
        elif line.startsWith("option "):
            client.parseOption(line)
        elif line == token:
            return


proc startUCIClient*(commandLine: string): tuple[client: UCIClient, error: string] =
    let argv = parseCmdLine(commandLine)
    if argv.len == 0:
        return (nil, "empty engine command")

    new(result.client)
    result.client.commandLine = commandLine
    result.client.name = argv[0]

    try:
        result.client.process = startProcess(
            argv[0],
            args = if argv.len > 1: argv[1..^1] else: @[],
            options = {poUsePath, poStdErrToStdOut}
        )
        result.client.input = result.client.process.inputStream()
        result.client.output = result.client.process.outputStream()
        result.client.sendLine("uci")
        result.client.waitForToken("uciok")
        result.client.sendLine("isready")
        result.client.waitForToken("readyok")
    except CatchableError as e:
        result.error = e.msg
        if result.client != nil and result.client.process != nil:
            try:
                result.client.process.terminate()
                discard result.client.process.waitForExit(250)
                result.client.process.close()
            except CatchableError:
                discard
        result.client = nil


proc close*(client: UCIClient) =
    if client == nil or client.process == nil:
        return
    try:
        if client.process.running():
            try:
                client.sendLine("quit")
            except CatchableError:
                discard
            if client.process.waitForExit(500) == -1:
                client.process.terminate()
                discard client.process.waitForExit(500)
    except CatchableError:
        discard
    try:
        client.process.close()
    except CatchableError:
        discard


proc setOption*(client: UCIClient, name, value: string) =
    client.sendLine(&"setoption name {name} value {value}")


proc newGame*(client: UCIClient) =
    client.sendLine("ucinewgame")
    client.sendLine("isready")
    client.waitForToken("readyok")


proc stop*(client: UCIClient) =
    if client != nil:
        client.sendLine("stop")


proc ponderHit*(client: UCIClient) =
    if client != nil:
        client.sendLine("ponderhit")


proc buildGoCommand(limit: UCIEngineLimit, ponder: bool, canPonder: bool): string =
    var parts = @["go"]
    if ponder and canPonder:
        parts.add("ponder")

    if limit.hasTime:
        parts.add("wtime")
        parts.add($max(0'i64, limit.whiteTimeMs))
        parts.add("btime")
        parts.add($max(0'i64, limit.blackTimeMs))
        parts.add("winc")
        parts.add($max(0'i64, limit.whiteIncrementMs))
        parts.add("binc")
        parts.add($max(0'i64, limit.blackIncrementMs))

    if limit.depth.isSome():
        parts.add("depth")
        parts.add($limit.depth.get())

    if limit.nodes.isSome():
        parts.add("nodes")
        parts.add($limit.nodes.get())

    if parts.len == 1 or (parts.len == 2 and parts[1] == "ponder"):
        parts.add("movetime")
        parts.add("1000")

    parts.join(" ")


proc buildPositionCommand(positions: seq[Position], startFEN: string, moves: seq[Move], chess960: bool): string =
    if startFEN.len > 0:
        result = "position fen " & startFEN
        if moves.len > 0:
            result &= " moves"
            for move in moves:
                result &= " " & move.toTUIUCI(chess960)
    else:
        result = "position fen " & positions[positions.high].toFEN(chess960)


proc parseBestMoveLine(
    line: string,
    positions: seq[Position],
    chess960: bool
): UCIEngineMoveResult =
    result.bestMove = nullMove()
    result.ponderMove = nullMove()

    let parts = line.splitWhitespace()
    if parts.len < 2 or parts[0] != "bestmove":
        result.error = "malformed bestmove line: " & line
        return
    if parts[1] == "0000":
        return

    let parsed = move_parse.parseUCIMove(positions[positions.high], parts[1], chess960=chess960)
    if parsed.error.hasError():
        result.error = formatUCIMoveParseError(parsed.error)
        return
    result.bestMove = parsed.move

    var ponderStr = ""
    for i in 2..<parts.len - 1:
        if parts[i] == "ponder":
            ponderStr = parts[i + 1]
            break
    if ponderStr.len == 0 or result.bestMove == nullMove():
        return

    var preview = newChessboard(@[positions[positions.high].clone()])
    if preview.makeMove(result.bestMove) == nullMove():
        return
    let ponderParsed = move_parse.parseUCIMove(preview.position, ponderStr, chess960=chess960)
    if not ponderParsed.error.hasError():
        result.ponderMove = ponderParsed.move


proc searchBestMove*(
    client: UCIClient,
    positions: seq[Position],
    limit: UCIEngineLimit,
    chess960: bool,
    startFEN = "",
    moves: seq[Move] = @[],
    infoChannel: ptr Channel[UCIEngineInfo] = nil,
    ponder = false
): UCIEngineMoveResult =
    result.bestMove = nullMove()
    result.ponderMove = nullMove()
    if client == nil:
        result.error = "UCI engine is not running"
        return
    if positions.len == 0:
        result.error = "no position available for UCI search"
        return

    try:
        client.lastNodes = 0
        if client.supportsChess960:
            client.setOption("UCI_Chess960", if chess960: "true" else: "false")

        client.sendLine(buildPositionCommand(positions, startFEN, moves, chess960))
        client.sendLine(buildGoCommand(limit, ponder, client.supportsPonder))

        while true:
            let line = client.readLine().strip()
            if line.len == 0:
                continue
            if line.startsWith("info "):
                let info = client.parseInfo(line, positions, chess960)
                if infoChannel != nil and (info.depth > 0 or info.nodes > 0 or info.nps > 0 or info.pv.len > 0):
                    infoChannel[].send(info)
            elif line.startsWith("bestmove "):
                result = parseBestMoveLine(line, positions, chess960)
                result.nodes = client.lastNodes
                return
    except CatchableError as e:
        result.error = e.msg
