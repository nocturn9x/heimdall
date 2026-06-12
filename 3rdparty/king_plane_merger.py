#!/usr/bin/env python3

"""Merge opponent king planes into friendly king planes for an NNUE file."""

## Original logic by @sp00ph, made pretty with AI

import argparse
from pathlib import Path
from typing import Sequence

import numpy as np


def isMirrored(sq):
    return sq % 8 >= 4


DEFAULT_HL_SIZE = 1536
PIECE_PLANES = 12
MERGED_PIECE_PLANES = 11
SQUARES = 64
DEFAULT_LAYOUT_PATH = Path(__file__).with_name("king_plane_buckets.txt")


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than 0")
    return parsed


def read_bucket_layout(path: Path) -> list[int]:
    values: list[int] = []
    for line in path.read_text().splitlines():
        line = line.split("#", maxsplit=1)[0]
        values.extend(int(value) for value in line.replace(",", " ").split())

    if len(values) != SQUARES:
        raise ValueError(f"{path} must contain {SQUARES} bucket entries, got {len(values)}")
    if min(values) < 0:
        raise ValueError(f"{path} must not contain negative bucket indices")

    return values


def merge_king_planes(
    input_path: Path,
    output_path: Path,
    layout: Sequence[int],
    hidden_layer_size: int,
) -> None:
    buckets = max(layout) + 1
    ft_size = buckets * PIECE_PLANES * SQUARES * hidden_layer_size
    merged_ft_size = buckets * MERGED_PIECE_PLANES * SQUARES * hidden_layer_size

    net = np.frombuffer(input_path.read_bytes(), dtype=np.int16)
    ft = net[:ft_size].reshape([buckets, PIECE_PLANES, SQUARES, hidden_layer_size])
    mergedFt = ft[:, :MERGED_PIECE_PLANES, :, :].copy()

    friendlyKing = 5
    opponentKing = 11

    for bucket in range(buckets):
        for sq in range(SQUARES):
            if bucket == layout[sq] and not isMirrored(sq):
                continue
            mergedFt[bucket, friendlyKing, sq, :] = ft[bucket, opponentKing, sq, :]

    mergedNet = np.concatenate((mergedFt.reshape(merged_ft_size), net[ft_size:]))
    output_path.write_bytes(mergedNet.tobytes())


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="Input NNUE file to merge")
    parser.add_argument(
        "--layout",
        type=Path,
        default=DEFAULT_LAYOUT_PATH,
        help=f"Bucket layout text file (default: {DEFAULT_LAYOUT_PATH})",
    )
    parser.add_argument(
        "--hl-size",
        type=positive_int,
        default=DEFAULT_HL_SIZE,
        help=f"Hidden layer size (default: {DEFAULT_HL_SIZE})",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=Path("merged.nnue"),
        help="Output NNUE file (default: merged.nnue)",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        layout = read_bucket_layout(args.layout)
    except (OSError, ValueError) as e:
        parser.error(str(e))

    try:
        merge_king_planes(args.input, args.output, layout, args.hl_size)
    except OSError as e:
        parser.error(str(e))
    except ValueError as e:
        parser.error(f"failed to merge {args.input}: {e}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
