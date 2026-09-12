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
#
# Authored with assistance from AI agents.

## Focused TI update regressions: endpoints, slider rays, mirroring and history.
## Build through make dev MAIN=tests/test_threat_updates.nim IS_TEST=1
## with EVALFILE set to the absolute path of threans.bin.
include heimdall/eval
import heimdall/movegen

var
    owner = newEvalState(verbose=false)
    referenceOwner = newEvalState(verbose=false)
    comparisons = 0
let state = owner.raw
let reference = referenceOwner.raw

proc legalMove(game: Chessboard, uci: string): Move =
    var legal = newMoveList()
    game.generateMoves(legal)
    for move in legal:
        if move.toUCI() == uci:
            return move
    doAssert false, "missing legal move " & uci & " in " & game.toFEN()

proc push(game: Chessboard, uci: string, target: EvalState = state) =
    let move = game.legalMove(uci)
    target.update(move, game.sideToMove, game.on(move.startSquare).kind,
                  game.on(move.captureSquare()).kind,
                  game.position.kingSquare(game.sideToMove))
    game.doMove(move)

proc verify(game: Chessboard, context: string, target: EvalState = state) =
    let actual = game.evaluate(target)
    reference.init(game)
    doAssert actual == game.evaluate(reference), context & ": evaluation mismatch"
    for side in White..Black:
        doAssert target.accumulators[side][target.current].data == reference.accumulators[side][0].data,
            context & ": PSQ mismatch for " & $side & " in " & game.toFEN()
        doAssert target.threatAccumulators[side][target.current].data == reference.threatAccumulators[side][0].data,
            context & ": TI mismatch for " & $side & " in " & game.toFEN()
    inc(comparisons)

# Each fixture isolates a reason a threat can appear/disappear. Castling uses
# Heimdall's internal UCI spelling: king origin followed by rook origin.
let fixtures = [
    ("rook discovery", "r6k/8/8/8/8/8/B7/R3K3 w - - 0 1", "a2b3"),
    ("rook obstruction", "r6k/8/8/8/8/1B6/8/R3K3 w - - 0 1", "b3a2"),
    ("bishop discovery", "7k/8/8/r7/8/8/3N4/4B2K w - - 0 1", "d2c4"),
    ("bishop obstruction", "7k/8/8/r7/2N5/8/8/4B2K w - - 0 1", "c4d2"),
    ("occupied target changes identity", "7k/3b4/8/8/n7/8/8/R6K w - - 0 1", "a1a4"),
    ("friendly pawn defense", "7k/8/8/4P3/3P4/8/8/7K w - - 0 1", "d4d5"),
    ("empty diff", "4k3/8/8/8/8/8/8/4K3 w - - 0 1", "e1f1"),
    ("empty mirrored refresh", "4k3/8/8/8/8/8/8/4K3 w - - 0 1", "e1d1"),
    ("king discovery without mirror change", "7k/8/8/8/8/4P3/4K3/4R3 w - - 0 1", "e2f2"),
    ("white mirrored discovery", "7k/8/8/8/8/3P4/3K4/3R4 w - - 0 1", "d2e2"),
    ("white mirrored obstruction", "7k/8/8/8/8/3P4/4K3/3R4 w - - 0 1", "e2d2"),
    ("black mirrored discovery", "3r4/3k4/3p4/8/8/8/8/7K b - - 0 1", "d7e7"),
    ("mirrored king capture", "7k/8/8/8/8/3P4/3Kn3/3R4 w - - 0 1", "d2e2"),
    ("en passant discovery", "7k/8/8/R2pP2n/8/8/8/7K w - d6 0 1", "e5d6"),
    ("black en passant discovery", "7k/8/8/8/r2Pp2N/8/8/7K b - d3 0 1", "e4d3"),
    ("short castling", "r3k2r/ppp2ppp/8/8/8/8/PPP2PPP/R3K2R w KQkq - 0 1", "e1h1"),
    ("long castling", "r3k2r/ppp2ppp/8/8/8/8/PPP2PPP/R3K2R w KQkq - 0 1", "e1a1"),
    ("quiet queen promotion", "7k/P7/8/8/8/8/8/R6K w - - 0 1", "a7a8q"),
    ("quiet rook promotion", "7k/P7/8/8/8/8/8/R6K w - - 0 1", "a7a8r"),
    ("quiet bishop promotion", "7k/P7/8/8/8/8/8/R6K w - - 0 1", "a7a8b"),
    ("quiet knight promotion", "7k/P7/8/8/8/8/8/R6K w - - 0 1", "a7a8n"),
    ("capture queen promotion", "1r5k/P7/8/8/8/8/8/R6K w - - 0 1", "a7b8q"),
    ("capture rook promotion", "1r5k/P7/8/8/8/8/8/R6K w - - 0 1", "a7b8r"),
    ("capture bishop promotion", "1r5k/P7/8/8/8/8/8/R6K w - - 0 1", "a7b8b"),
    ("capture knight promotion", "1r5k/P7/8/8/8/8/8/R6K w - - 0 1", "a7b8n")
]
for fixture in fixtures:
    let game = newChessboardFromFEN(fixture[1])
    state.init(game)
    verify(game, fixture[0] & " root")
    let rootWhite = state.threatAccumulators[White][0].data
    let rootBlack = state.threatAccumulators[Black][0].data
    # Reuse the child twice, once undoing it while its update is still pending.
    push(game, fixture[2])
    state.undo()
    game.unmakeMove()
    verify(game, fixture[0] & " pending undo")
    for repeat in 0..<2:
        # Poison the reusable child so even empty diffs must overwrite it.
        for side in White..Black:
            for value in state.threatAccumulators[side][1].data.mitems:
                value = 1234
        push(game, fixture[2])
        verify(game, fixture[0] & " child")
        doAssert state.threatAccumulators[White][0].data == rootWhite
        doAssert state.threatAccumulators[Black][0].data == rootBlack
        state.undo()
        game.unmakeMove()
        verify(game, fixture[0] & " evaluated undo")

# A mirrored refresh must read its own queued position, not the last position
# in the queue. Subsequent pawn movement makes those feature sets different.
for eager in [false, true]:
    let game = newChessboardFromFEN("4k3/8/8/8/8/8/P7/R3K3 w - - 0 1")
    state.init(game)
    for uci in ["e1d1", "e8f8", "a2a4"]:
        push(game, uci)
        if eager:
            verify(game, "eager mirrored sequence")
    verify(game, "mirrored sequence leaf")
    for ply in 0..<3:
        state.undo()
        game.unmakeMove()
        verify(game, "mirrored sequence ancestor")

# UCI 'position ... moves ...' supplies board history before EvalState.init.
# The first child therefore has board index 3 but accumulator index 1.
block historyBeforeRoot:
    let game = newDefaultChessboard()
    for uci in ["e2e4", "e7e5"]:
        game.doMove(game.legalMove(uci))
    state.init(game)
    doAssert state.current == 0 and game.positions.len == 3
    verify(game, "root after historical moves")
    push(game, "g1f3")
    let copiedGame = newChessboard(game.positions)
    var copiedOwner = state.clone(copiedGame)
    verify(copiedGame, "pending clone after historical moves", copiedOwner.raw)
    verify(game, "child after historical moves")
    doAssert state.current == 1
    for uci in ["b8c6", "f1b5"]:
        push(game, uci)
    verify(game, "delayed children after historical moves")
    for ply in 0..<3:
        state.undo()
        game.unmakeMove()
        verify(game, "historical root ancestor")
    copiedOwner.raw.undo()
    copiedGame.unmakeMove()
    verify(copiedGame, "cloned historical root", copiedOwner.raw)

# Null moves add board history without consuming an accumulator frame. Cover
# real descendants beneath one, including an already pending parent update.
for pendingParent in [false, true]:
    let game = newDefaultChessboard()
    state.init(game)
    if pendingParent:
        push(game, "g1f3")
    doAssert game.canNullMove()
    game.makeNullMove()
    push(game, if pendingParent: "e2e4" else: "e7e5")
    verify(game, "real move below null")
    state.undo()
    game.unmakeMove()
    verify(game, "null position after child undo")
    game.unmakeMove()
    verify(game, "null undo")
    if pendingParent:
        state.undo()
        game.unmakeMove()
        verify(game, "pending parent undo")

# The selective updater must neither read nor write the other perspective's
# child. Evaluation uses this when it rebuilds a mirrored king perspective.
for selected in [White, Black, None]:
    let game = newDefaultChessboard()
    state.init(game)
    game.doMove(game.legalMove("e2e4"))
    state.current = 1
    for side in White..Black:
        for value in state.threatAccumulators[side][1].data.mitems:
            value = -1234
    state.updateThreats(1, selected)
    reference.init(game)
    for side in White..Black:
        if selected == None or side == selected:
            doAssert state.threatAccumulators[side][1].data == reference.threatAccumulators[side][0].data
        else:
            for value in state.threatAccumulators[side][1].data:
                doAssert value == -1234
    inc(comparisons)

echo "Threat updates: ", fixtures.len, " move fixtures; ", comparisons, " state comparisons passed"

printSimdInfo()
