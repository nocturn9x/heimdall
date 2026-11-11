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

## MantaRay owns feature updates and forward inference. The bridge receives
## borrowed position views, never pointers retained past a call.
import heimdall/[board, moves, pieces, position, nnue]
import heimdall/util/memory/thp/alloc
import std/os
include heimdall/eval_scores

static:
    doAssert not SINGLE_LAYER, "MantaRay currently supports multilayer TI networks"
    doAssert NUM_INPUT_BUCKETS == 16 and NUM_OUTPUT_BUCKETS == 8
    doAssert FT_SIZE == 768 and MIRRORED and not MERGED_KINGS
    doAssert QA == 255 and L1_QUANT_BITS == 7 and QUANT_BITS == 6
    doAssert FT_SCALE_BITS == 7 and L1_BIAS_SHIFT == 0

const MRHeader = "heimdall/mantaray/bridge.h"
type
    MRBoard {.importc: "HDBoard", header: MRHeader, bycopy, completeStruct.} = object
        pieces: ptr uint64
        mailbox: ptr uint8
        stm: uint8
    MRMove {.importc: "HDMove", header: MRHeader, bycopy, completeStruct.} = object
        `from`, to, side, piece, captured, capture, promotion, castle: uint8

proc mrLoad(bytes: pointer, size: csize_t): cstring {.importc: "hd_mr_load", header: MRHeader.}
proc mrNew(source: pointer = nil): pointer {.importc: "hd_mr_new", header: MRHeader.}
proc mrDelete(s: pointer) {.importc: "hd_mr_delete", header: MRHeader.}
proc mrCopy(d, s: pointer) {.importc: "hd_mr_copy", header: MRHeader.}
proc mrReset(s: pointer, b: MRBoard) {.importc: "hd_mr_reset", header: MRHeader.}
proc mrPush(s: pointer, b: MRBoard, m: MRMove) {.importc: "hd_mr_push", header: MRHeader.}
proc mrPop(s: pointer) {.importc: "hd_mr_pop", header: MRHeader.}
proc mrEvaluate(s: pointer, b: MRBoard): int32 {.importc: "hd_mr_evaluate", header: MRHeader.}
proc mrFresh(s: pointer, b: MRBoard): int32 {.importc: "hd_mr_fresh", header: MRHeader.}

type
    StackOwner = object
        raw: pointer

proc `=destroy`(self: StackOwner) = mrDelete(self.raw)
proc `=copy`(dest: var StackOwner, source: StackOwner) {.error: "MantaRay stacks have unique owners".}

type
    EvalStateObj = object
        stack: StackOwner
        board: Chessboard
        pending: bool
        move: MRMove
        depth: int
    EvalState* = ptr EvalStateObj
    EvalStateOwner* = HugePtr[EvalStateObj]

template view(p: Position): MRBoard =
    MRBoard(pieces: cast[ptr uint64](unsafeAddr p.pieces[White][Pawn]),
            mailbox: cast[ptr uint8](unsafeAddr p.mailbox[Square(0)]),
            stm: uint8(p.sideToMove))

proc mrData(s: pointer): pointer {.importc: "hd_mr_data", header: MRHeader.}
proc mrSize(s: pointer): csize_t {.importc: "hd_mr_size", header: MRHeader.}
proc mrEqual(a, b: pointer): cint {.importc: "hd_mr_equal", header: MRHeader.}

proc dumpMantaRayNet*(state: EvalState, path: string) =
    ## Export this state's active network in canonical disk layout.
    var bytes = newString(int(mrSize(state.stack.raw)))
    copyMem(addr bytes[0], mrData(state.stack.raw), bytes.len)
    writeFile(path, bytes)

proc sameAccumulators*(a, b: EvalState): bool =
    ## Compare every materialized lane, for both perspectives and all slots.
    mrEqual(a.stack.raw, b.stack.raw) != 0

proc kingBucket*(side: PieceColor, square: Square): int {.inline.} =
    INPUT_BUCKETS[if side == White: square.flipRank() else: square]

proc newEvalState*(networkPath: string = "", verbose: static bool = true): EvalStateOwner =
    let bytes = if networkPath != "": readFile(networkPath)
                elif EMBED_NET: DEFAULT_NET_WEIGHTS
                else: readFile(getAppDir() / "network.bin")
    if bytes.len == 0:
        raise newException(IOError, "Empty MantaRay network")
    let error = mrLoad(unsafeAddr bytes[0], csize_t(bytes.len))
    if error != nil:
        raise newException(IOError, "MantaRay network: " & $error)
    when verbose:
        echo "info string using MantaRay v7 inference"
    result = allocHugePage[EvalStateObj](zero=true)
    result.raw.stack.raw = mrNew()
    doAssert result.raw.stack.raw != nil, "MantaRay stack allocation failed"

proc init*(self: EvalState, board: Chessboard) =
    self.board = board
    self.pending = false
    self.depth = 0
    mrReset(self.stack.raw, view(board.position))

proc copyFrom*(self: EvalState, source: EvalState, board: Chessboard) =
    ## Copy pending and materialized history so undo remains valid in clones.
    if self != source:
        mrCopy(self.stack.raw, source.stack.raw)
        self.pending = source.pending
        self.move = source.move
        self.depth = source.depth
    self.board = board

proc clone*(self: EvalState, board: Chessboard): EvalStateOwner =
    result = allocHugePage[EvalStateObj](zero=true)
    result.raw.stack.raw = mrNew(self.stack.raw)
    doAssert result.raw.stack.raw != nil, "MantaRay stack allocation failed"
    result.raw.copyFrom(self, board)

proc flush(self: EvalState) {.inline.} =
    if self.pending:
        mrPush(self.stack.raw, view(self.board.position), self.move)
        self.pending = false

proc update*(self: EvalState, move: Move, sideToMove: PieceColor,
             piece: PieceKind, captured=Empty, kingSq: Square) {.inline.} =
    # update() runs before doMove(). Delay just this push until its board exists.
    # Null moves need no stack entry: they change neither PSQ nor TI features.
    self.flush()
    doAssert self.depth < 255, "MantaRay accumulator stack exhausted"
    self.move = MRMove(`from`: uint8(move.startSquare), to: uint8(move.targetSquare),
        side: uint8(sideToMove), piece: uint8(piece),
        captured: uint8(if move.isCastling(): Empty else: captured),
        capture: uint8(move.captureSquare()),
        promotion: uint8(if move.isPromotion(): move.flag().promotionToPiece() else: Empty),
        castle: uint8(move.isCastling()))
    self.pending = true
    inc self.depth

proc undo*(self: EvalState) {.inline.} =
    doAssert self.depth > 0
    if self.pending: self.pending = false
    else: mrPop(self.stack.raw)
    dec self.depth

proc evaluateFresh*(position: Position, state: EvalState): Score =
    ## Independent rebuild through MantaRay, for verification.
    mrFresh(state.stack.raw, view(position))

proc evaluate*(position: Position, state: EvalState): Score {.inline.} =
    state.flush()
    result = mrEvaluate(state.stack.raw, view(position))
    when defined(mantarayVerify):
        doAssert result == evaluateFresh(position, state), "MantaRay incremental/fresh mismatch"

proc evaluate*(board: Chessboard, state: EvalState): Score {.inline.} =
    board.position.evaluate(state)
