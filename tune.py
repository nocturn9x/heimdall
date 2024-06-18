# Copyright 2024 Mattia Giambirtone & All Contributors
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

# I couldn't be arsed to write a tuner myself, so I'm using pytorch instead.
# Many many many thanks to @analog-hors on the Engine Programming Discord 
# server for providing a starting point to write this script! Also thanks
# to @affinelytyped, @jw1912, @__arandomnoob, @mathmagician, @ciekce and
# @.nanopixel for the priceless debugging help and explanations

import re
import json
import torch
import random
import numpy as np
# This comes from our Nim module with
# the same name
from eval import Features
from pathlib import Path
from timeit import default_timer as timer
from argparse import ArgumentParser
from enum import Enum


NIM_TEMPLATE = """# Copyright 2024 Mattia Giambirtone & All Contributors
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

## Tuned weights for heimdall's evaluation function

# NOTE: This file is computer-generated. Any and all modifications will be overwritten

import pieces


type
    Weight* = int16

const
    TEMPO_BONUS* = Weight(10)

    PAWN_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = {pawn_mg}

    PAWN_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = {pawn_eg}

    PASSED_PAWN_MIDDLEGAME_BONUSES: array[Square(0)..Square(63), Weight] = {passed_pawns_mg}

    PASSED_PAWN_ENDGAME_BONUSES: array[Square(0)..Square(63), Weight] = {passed_pawns_eg}

    ISOLATED_PAWN_MIDDLEGAME_BONUSES: array[Square(0)..Square(63), Weight] = {isolated_pawns_mg}

    ISOLATED_PAWN_ENDGAME_BONUSES: array[Square(0)..Square(63), Weight] = {isolated_pawns_eg}

    KNIGHT_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = {knight_mg}

    KNIGHT_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = {knight_eg}

    BISHOP_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = {bishop_mg}

    BISHOP_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = {bishop_eg}

    ROOK_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = {rook_mg}

    ROOK_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = {rook_eg}

    QUEEN_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = {queen_mg}

    QUEEN_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = {queen_eg}

    KING_MIDDLEGAME_SCORES: array[Square(0)..Square(63), Weight] = {king_mg}

    KING_ENDGAME_SCORES: array[Square(0)..Square(63), Weight] = {king_eg}

    # Piece weights
    MIDDLEGAME_WEIGHTS: array[PieceKind.Bishop..PieceKind.Rook, Weight] = {pieces_mg}
    ENDGAME_WEIGHTS: array[PieceKind.Bishop..PieceKind.Rook, Weight]    = {pieces_eg}

    # Flat bonuses (middlegame, endgame)
    ROOK_OPEN_FILE_BONUS*: tuple[mg, eg: Weight] = {rook_open_file}
    ROOK_SEMI_OPEN_FILE_BONUS*: tuple[mg, eg: Weight] = {rook_semi_open_file}
    DOUBLED_PAWNS_BONUS*: tuple[mg, eg: Weight] = {doubled_pawns}
    BISHOP_PAIR_BONUS*: tuple[mg, eg: Weight] = {bishop_pair}
    CONNECTED_ROOKS_BONUS*: tuple[mg, eg: Weight] = {connected_rooks}
    STRONG_PAWNS_BONUS*: tuple[mg, eg: Weight] = {strong_pawns}
    PAWN_THREATS_MINOR_BONUS*: tuple[mg, eg: Weight] = {pawn_minor_threats}
    PAWN_THREATS_MAJOR_BONUS*: tuple[mg, eg: Weight] = {pawn_major_threats}
    MINOR_THREATS_MAJOR_BONUS*: tuple[mg, eg: Weight] = {minor_major_threats}
    ROOK_THREATS_QUEEN_BONUS*: tuple[mg, eg: Weight] = {rook_queen_threats}
    
    # Tapered mobility bonuses
    BISHOP_MOBILITY_MIDDLEGAME_BONUS: array[14, Weight] = {bishop_mobility_mg}
    BISHOP_MOBILITY_ENDGAME_BONUS: array[14, Weight] = {bishop_mobility_eg}
    KNIGHT_MOBILITY_MIDDLEGAME_BONUS: array[9, Weight] = {knight_mobility_mg}
    KNIGHT_MOBILITY_ENDGAME_BONUS: array[9, Weight] = {knight_mobility_eg}
    ROOK_MOBILITY_MIDDLEGAME_BONUS: array[15, Weight] = {rook_mobility_mg}
    ROOK_MOBILITY_ENDGAME_BONUS: array[15, Weight] = {rook_mobility_eg}
    QUEEN_MOBILITY_MIDDLEGAME_BONUS: array[28, Weight] = {queen_mobility_mg}
    QUEEN_MOBILITY_ENDGAME_BONUS: array[28, Weight] = {queen_mobility_eg}
    KING_MOBILITY_MIDDLEGAME_BONUS: array[28, Weight] = {king_mobility_mg}
    KING_MOBILITY_ENDGAME_BONUS: array[28, Weight] = {king_mobility_eg}

    KING_ZONE_ATTACKS_MIDDLEGAME_BONUS*: array[9, Weight] = {king_zone_attacks_mg}
    KING_ZONE_ATTACKS_ENDGAME_BONUS*: array[9, Weight] = {king_zone_attacks_eg}

    MIDDLEGAME_PSQ_TABLES: array[PieceKind.Bishop..PieceKind.Rook, array[Square(0)..Square(63), Weight]] = [
        BISHOP_MIDDLEGAME_SCORES,
        KING_MIDDLEGAME_SCORES,
        KNIGHT_MIDDLEGAME_SCORES,
        PAWN_MIDDLEGAME_SCORES,
        QUEEN_MIDDLEGAME_SCORES,
        ROOK_MIDDLEGAME_SCORES
    ]

    ENDGAME_PSQ_TABLES: array[PieceKind.Bishop..PieceKind.Rook, array[Square(0)..Square(63), Weight]] = [
        BISHOP_ENDGAME_SCORES,
        KING_ENDGAME_SCORES,
        KNIGHT_ENDGAME_SCORES,
        PAWN_ENDGAME_SCORES,
        QUEEN_ENDGAME_SCORES,
        ROOK_ENDGAME_SCORES
    ]

var
    MIDDLEGAME_VALUE_TABLES*: array[PieceColor.White..PieceColor.Black, array[PieceKind.Bishop..PieceKind.Rook, array[Square(0)..Square(63), Weight]]]
    ENDGAME_VALUE_TABLES*: array[PieceColor.White..PieceColor.Black, array[PieceKind.Bishop..PieceKind.Rook, array[Square(0)..Square(63), Weight]]]
    PASSED_PAWN_MIDDLEGAME_TABLES*: array[PieceColor.White..PieceColor.Black, array[Square(0)..Square(63), Weight]]
    PASSED_PAWN_ENDGAME_TABLES*: array[PieceColor.White..PieceColor.Black, array[Square(0)..Square(63), Weight]]
    ISOLATED_PAWN_MIDDLEGAME_TABLES*: array[PieceColor.White..PieceColor.Black, array[Square(0)..Square(63), Weight]]
    ISOLATED_PAWN_ENDGAME_TABLES*: array[PieceColor.White..PieceColor.Black, array[Square(0)..Square(63), Weight]]


proc initializeTables =
    ## Initializes the piece-square tables with the correct values
    ## relative to the side that is moving (they are white-relative
    ## by default, so we need to flip the scores for black)
    for kind in PieceKind.Bishop..PieceKind.Rook:
        for sq in Square(0)..Square(63):
            let flipped = sq.flip()
            MIDDLEGAME_VALUE_TABLES[White][kind][sq] = MIDDLEGAME_WEIGHTS[kind] + MIDDLEGAME_PSQ_TABLES[kind][sq]
            ENDGAME_VALUE_TABLES[White][kind][sq] = ENDGAME_WEIGHTS[kind] + ENDGAME_PSQ_TABLES[kind][sq]
            MIDDLEGAME_VALUE_TABLES[Black][kind][sq] = MIDDLEGAME_WEIGHTS[kind] + MIDDLEGAME_PSQ_TABLES[kind][flipped]
            ENDGAME_VALUE_TABLES[Black][kind][sq] = ENDGAME_WEIGHTS[kind] + ENDGAME_PSQ_TABLES[kind][flipped]
            PASSED_PAWN_MIDDLEGAME_TABLES[White][sq] = PASSED_PAWN_MIDDLEGAME_BONUSES[sq]
            PASSED_PAWN_MIDDLEGAME_TABLES[Black][sq] = PASSED_PAWN_MIDDLEGAME_BONUSES[flipped]
            PASSED_PAWN_ENDGAME_TABLES[White][sq] = PASSED_PAWN_ENDGAME_BONUSES[sq]
            PASSED_PAWN_ENDGAME_TABLES[Black][sq] = PASSED_PAWN_ENDGAME_BONUSES[flipped]
            ISOLATED_PAWN_MIDDLEGAME_TABLES[White][sq] = ISOLATED_PAWN_MIDDLEGAME_BONUSES[sq]
            ISOLATED_PAWN_MIDDLEGAME_TABLES[Black][sq] = ISOLATED_PAWN_MIDDLEGAME_BONUSES[flipped]
            ISOLATED_PAWN_ENDGAME_TABLES[White][sq] = ISOLATED_PAWN_ENDGAME_BONUSES[sq]
            ISOLATED_PAWN_ENDGAME_TABLES[Black][sq] = ISOLATED_PAWN_ENDGAME_BONUSES[flipped]


proc getMobilityBonus*(kind: PieceKind, moves: int): tuple[mg, eg: Weight] =
    ## Returns the mobility bonus for the given piece type
    ## with the given number of (potentially pseudo-legal) moves
    case kind:
        of Bishop:
            return (BISHOP_MOBILITY_MIDDLEGAME_BONUS[moves], BISHOP_MOBILITY_ENDGAME_BONUS[moves])
        of Knight:
            return (KNIGHT_MOBILITY_MIDDLEGAME_BONUS[moves], KNIGHT_MOBILITY_ENDGAME_BONUS[moves])
        of Rook:
            return (ROOK_MOBILITY_MIDDLEGAME_BONUS[moves], ROOK_MOBILITY_ENDGAME_BONUS[moves])
        of Queen:
            return (QUEEN_MOBILITY_MIDDLEGAME_BONUS[moves], QUEEN_MOBILITY_ENDGAME_BONUS[moves])
        of King:
            return (KING_MOBILITY_MIDDLEGAME_BONUS[moves], KING_MOBILITY_ENDGAME_BONUS[moves])
        else:
            return (0, 0)


initializeTables()
"""


class PieceKind(Enum):
    BISHOP = 0
    KING = 1
    KNIGHT = 2
    PAWN = 3
    QUEEN = 4
    ROOK = 5


def load_dataset(path: Path) -> tuple[np.array, list[str]]:
    """
    Loads a .book file at the given path and returns a tuple of
    the outcomes (as a numpy array) and the associated FEN of
    the position for each outcome
    """

    print(f"Loading positions from '{path}'")
    content = path.read_text()
    fens = []
    outcomes = []
    for match in re.finditer(r"((?:[rnbqkpRNBQKP1-8]+\/){7}[rnbqkpRNBQKP1-8]+\s[b|w]\s(?:[K|Q|k|q|]{1,4}|-)\s(?:-|[a-h][1-8])\s\d+\s\d+)\s\[(\d\.\d)\]", content):
        fens.append(match.group(1).strip())
        outcomes.append(float(match.group(2)))
    print(f"Loaded {len(fens)} positions")
    return np.array(outcomes, dtype=float), fens


def batch_loader(extractor: Features, num_batches, batch_size: int, dataset: tuple[np.ndarray, list[str]]):
    """
    Prepares the dataset for training by splitting it into batches and extracting
    features. This is a generator and the data is returned lazily at every iteration
    """

    outcomes, fens = dataset
    for _ in range(num_batches):
        targets = np.zeros((batch_size, 1), dtype=float)
        features = np.zeros((batch_size, extractor.featureCount()), dtype=float)
        for batch_idx in range(batch_size):
            chosen = random.randint(0, len(fens) - 1)
            targets[batch_idx] = outcomes[chosen]
            features[batch_idx] = extractor.extractFeatures(fens[chosen])
        yield torch.from_numpy(features), torch.from_numpy(targets)


def format_psqt(data: list[int]) -> str:
    # Thanks ChatGPT
    return f"[\n        {',\n        '.join(', '.join(str(data[i+j]) for j in range(8)) for i in range(0, len(data), 8))}\n    ]"


def main(num_batches, batch_size: int, dataset_path: Path, epoch_size: int, dump: Path, scaling: int, use_gpu: bool):
    """
    Uses pytorch to tune Heimdall's evaluation using the provided
    dataset
    """

    features = Features()
    start = timer()
    data = load_dataset(dataset_path)
    print(f"Dataset loaded in {timer() - start:.2f} seconds")
    dataset_size = len(data[0])
    feature_count = features.featureCount()
    
    dataset = batch_loader(features, num_batches, batch_size, data)
    device = torch.device("cuda") if use_gpu else None
    model = torch.nn.Linear(feature_count, 1, bias=False, dtype=float)
    if use_gpu:
        model = model.to(device)
    torch.nn.init.constant_(model.weight, 0)
    optimizer = torch.optim.Adam(model.parameters(), lr=0.001)

    print(f"Starting tuning for {feature_count} features in {num_batches} batches of {batch_size} elements each. Dataset contains {dataset_size} entries")

    running_loss = 0.0
    epoch_start = timer()
    for i, (features, target) in enumerate(dataset):
        if use_gpu:
            features = features.to(device)
            target = target.to(device)
        optimizer.zero_grad()
        outputs = torch.sigmoid(model(features))
        diff = outputs - target
        loss = torch.mean(torch.abs(diff) ** 2.6)
        loss.backward()
        optimizer.step()

        running_loss += loss.item()
        if (i + 1) % epoch_size == 0:
            print(f"\rEpoch #{(i + 1) // epoch_size} completed in {timer() - epoch_start:.2f} seconds, running loss is {running_loss / epoch_size}\033[K", end="", flush=True)
            epoch_start = timer()
            running_loss = 0.0
    print()
    params = [((param.detach().cpu().numpy() * scaling).round().astype(int)).tolist() for param in model.parameters()][0][0]

    # Collect results into a nice JSON output
    result = {
        "psqts": {k.name.lower(): {"eg": [], "mg": []} for k in PieceKind},
        "pieceWeights": {"mg": [0 for _ in PieceKind], "eg": [0 for _ in PieceKind]},
        "tempo": 0,
        "rookOpenFile": {"mg": 0, "eg": 0},
        "rookSemiOpenFile": {"mg": 0, "eg": 0},
        "passedPawnBonuses": {"mg": [0 for _ in range(64)], "eg": [0 for _ in range(64)]},
        "isolatedPawnBonuses": {"mg": [0 for _ in range(64)], "eg": [0 for _ in range(64)]},
        "majorPieceSeventhRank": [{"mg": 0, "eg": 0}, {"mg": 0, "eg": 0}],
        "knightMobility": [{"mg": 0, "eg": 0} for _ in range(9)],
        "bishopMobility": [{"mg": 0, "eg": 0} for _ in range(14)],
        "rookMobility": [{"mg": 0, "eg": 0} for _ in range(15)],
        "queenMobility": [{"mg": 0, "eg": 0} for _ in range(28)],
        "kingMobility": [{"mg": 0, "eg": 0} for _ in range(28)],
        "kingZoneAttacks": [{"mg": 0, "eg": 0} for _ in range(9)],
        "doubledPawns": {"mg": 0, "eg": 0},
        "bishopPair": {"mg": 0, "eg": 0},
        "connectedRooks": {"mg": 0, "eg": 0},
        "strongPawns": {"mg": 0, "eg": 0},
        "pawnMinorThreats": {"mg": 0, "eg": 0},
        "pawnMajorThreats": {"mg": 0, "eg": 0},
        "minorMajorThreats": {"mg": 0, "eg": 0},
        "rookQueenThreats": {"mg": 0, "eg": 0}
    }
    for i, k in enumerate(PieceKind):
        i *= 64
        key = k.name.lower()
        result["psqts"][key]["mg"] = params[i:i + 64]
        i += 384
        result["psqts"][key]["eg"] = params[i:i + 64]
    i = 768
    result["pieceWeights"]["mg"] = params[i:i + 6]
    i += 6
    result["pieceWeights"]["eg"] = params[i:i + 6]
    i += 6
    result["rookOpenFile"]["mg"] = params[i]
    result["rookOpenFile"]["eg"] = params[i + 1]
    result["rookSemiOpenFile"]["mg"] = params[i + 2]
    result["rookSemiOpenFile"]["eg"] = params[i + 3]
    i += 4
    result["passedPawnBonuses"]["mg"] = params[i:i + 64]
    i += 64
    result["passedPawnBonuses"]["eg"] = params[i:i + 64]
    i += 64
    result["isolatedPawnBonuses"]["mg"] = params[i:i + 64]
    i += 64
    result["isolatedPawnBonuses"]["eg"] = params[i:i + 64]
    i += 64
    # Piece mobility

    # Bishops
    for j in range(14):
        idx = i + j * 2
        result["bishopMobility"][j]["mg"] = params[idx]
        result["bishopMobility"][j]["eg"] = params[idx + 1]
    
    i += 14 * 2
    
    # Knights
    for j in range(9):
        idx = i + j * 2
        result["knightMobility"][j]["mg"] = params[idx]
        result["knightMobility"][j]["eg"] = params[idx + 1]
    
    i += 9 * 2

    # Rooks
    for j in range(15):
        idx = i + j * 2
        result["rookMobility"][j]["mg"] = params[idx]
        result["rookMobility"][j]["eg"] = params[idx + 1]
    
    i += 15 * 2
    
    # Queens
    for j in range(28):
        idx = i + j * 2
        result["queenMobility"][j]["mg"] = params[idx]
        result["queenMobility"][j]["eg"] = params[idx + 1]
    
    i += 28 * 2

    # King
    for j in range(28):
        idx = i + j * 2
        result["kingMobility"][j]["mg"] = params[idx]
        result["kingMobility"][j]["eg"] = params[idx + 1]
    
    i += 28 * 2

    for j in range(9):
        idx = i + j * 2
        result["kingZoneAttacks"][j]["mg"] = params[idx]
        result["kingZoneAttacks"][j]["eg"] = params[idx + 1]
    
    i += 9 * 2

    result["doubledPawns"]["mg"] = params[i]
    result["doubledPawns"]["eg"] = params[i + 1]

    i += 2

    result["bishopPair"]["mg"] = params[i]
    result["bishopPair"]["eg"] = params[i + 1]

    i += 2

    result["connectedRooks"]["mg"] = params[i]
    result["connectedRooks"]["eg"] = params[i + 1]

    i += 2

    result["strongPawns"]["mg"] = params[i]
    result["strongPawns"]["eg"] = params[i + 1]

    i += 2

    result["pawnMinorThreats"]["mg"] = params[i]
    result["pawnMinorThreats"]["eg"] = params[i + 1]

    i += 2

    result["pawnMajorThreats"]["mg"] = params[i]
    result["pawnMajorThreats"]["eg"] = params[i + 1]

    i += 2

    result["minorMajorThreats"]["mg"] = params[i]
    result["minorMajorThreats"]["eg"] = params[i + 1]

    i += 2

    result["rookQueenThreats"]["mg"] = params[i]
    result["rookQueenThreats"]["eg"] = params[i + 1]

    i += 2

    result["tempo"] = params[i]
    raw_dump_path = dump / "raw.json"
    pretty_dump_path = dump / "pretty.json"
    template_path = dump / "weights.nim"
    print(f"Tuning completed in {timer() - start:.2f} seconds, dumping results to {dump}")
    pretty_dump_path.write_text(json.dumps(result))
    raw_dump_path.write_text(json.dumps(params))
    template = NIM_TEMPLATE.format(
        pawn_mg=format_psqt(result["psqts"]["pawn"]["mg"]),
        pawn_eg=format_psqt(result["psqts"]["pawn"]["eg"]),
        bishop_mg=format_psqt(result["psqts"]["bishop"]["mg"]),
        bishop_eg=format_psqt(result["psqts"]["bishop"]["eg"]),
        knight_mg=format_psqt(result["psqts"]["knight"]["mg"]),
        knight_eg=format_psqt(result["psqts"]["knight"]["eg"]),
        rook_mg=format_psqt(result["psqts"]["rook"]["mg"]),
        rook_eg=format_psqt(result["psqts"]["rook"]["eg"]),
        queen_mg=format_psqt(result["psqts"]["queen"]["mg"]),
        queen_eg=format_psqt(result["psqts"]["queen"]["eg"]),
        king_mg=format_psqt(result["psqts"]["king"]["mg"]),
        king_eg=format_psqt(result["psqts"]["king"]["eg"]),
        pieces_mg=str(result["pieceWeights"]["mg"]),
        pieces_eg=str(result["pieceWeights"]["eg"]),
        rook_open_file=str((result["rookOpenFile"]["mg"], result["rookOpenFile"]["eg"])),
        rook_semi_open_file=str((result["rookSemiOpenFile"]["mg"], result["rookSemiOpenFile"]["eg"])),
        passed_pawns_mg=format_psqt(result["passedPawnBonuses"]["mg"]),
        passed_pawns_eg=format_psqt(result["passedPawnBonuses"]["eg"]),
        isolated_pawns_mg=format_psqt(result["isolatedPawnBonuses"]["mg"]),
        isolated_pawns_eg=format_psqt(result["isolatedPawnBonuses"]["eg"]),
        knight_mobility_mg=str([d["mg"] for d in result["knightMobility"]]),
        knight_mobility_eg=str([d["eg"] for d in result["knightMobility"]]),
        bishop_mobility_mg=str([d["mg"] for d in result["bishopMobility"]]),
        bishop_mobility_eg=str([d["eg"] for d in result["bishopMobility"]]),
        rook_mobility_mg=str([d["mg"] for d in result["rookMobility"]]),
        rook_mobility_eg=str([d["eg"] for d in result["rookMobility"]]),
        queen_mobility_mg=str([d["mg"] for d in result["queenMobility"]]),
        queen_mobility_eg=str([d["eg"] for d in result["queenMobility"]]),
        king_mobility_mg=str([d["mg"] for d in result["kingMobility"]]),
        king_mobility_eg=str([d["eg"] for d in result["kingMobility"]]),
        king_zone_attacks_mg=str([d["mg"] for d in result["kingZoneAttacks"]]),
        king_zone_attacks_eg=str([d["eg"] for d in result["kingZoneAttacks"]]),
        doubled_pawns=str((result["doubledPawns"]["mg"], result["doubledPawns"]["eg"])),
        bishop_pair=str((result["bishopPair"]["mg"], result["bishopPair"]["eg"])),
        connected_rooks=str((result["connectedRooks"]["mg"], result["connectedRooks"]["eg"])),
        strong_pawns=str((result["strongPawns"]["mg"], result["strongPawns"]["eg"])),
        pawn_minor_threats=str((result["pawnMinorThreats"]["mg"], result["pawnMinorThreats"]["eg"])),
        pawn_major_threats=str((result["pawnMajorThreats"]["mg"], result["pawnMajorThreats"]["eg"])),
        minor_major_threats=str((result["minorMajorThreats"]["mg"], result["minorMajorThreats"]["eg"])),
        rook_queen_threats=str((result["rookQueenThreats"]["mg"], result["rookQueenThreats"]["eg"]))
        )
    template_path.write_text(template)


BATCH_SIZE = 16384
NUM_BATCHES = 5500
EPOCH_SIZE = 100
SCALING_FACTOR = 400


if __name__ == "__main__":
    parser = ArgumentParser(description="Tune Heimdall's evaluation")
    parser.add_argument("--dataset", "-d", type=Path, help="Location of the *.book file containing positions (as FENs) and the game outcome relative to white enclosed"
                        " in square brackets (0.0 means black wins, 1.0 means white wins, 0.5 means draw). One position is expected per line", required=True)
    parser.add_argument("--batches", "-b", type=int, help=f"How many batches to run (defaults to {NUM_BATCHES})", default=NUM_BATCHES)
    parser.add_argument("--epoch-size", "-e", type=int, help=f"After how many batches the tool prints progress information (defaults to {EPOCH_SIZE})", default=EPOCH_SIZE)
    parser.add_argument("--batch-size", "-s", type=int, help=f"The number of training samples in each batch (defaults to {BATCH_SIZE})", default=BATCH_SIZE)
    parser.add_argument("--results", "-r", type=Path, default=Path.cwd(), help="Location where the files containing the tuned weights will be dumped (defaults to the current directory)")
    parser.add_argument("-f", "--scaling", type=int, help=f"Scaling factor of the final weights (defailts to {SCALING_FACTOR})", default=SCALING_FACTOR)
    parser.add_argument("-g", "--use-gpu", action="store_true", help=f"Perform computations on a CUDA or ROCm compatible accelerator (i.e. GPU), if available", default=False)
    args = parser.parse_args()
    main(args.batches, args.batch_size, args.dataset, args.epoch_size, args.results, args.scaling, args.use_gpu)
