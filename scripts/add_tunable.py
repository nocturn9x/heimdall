#!/usr/bin/env python3
"""
Add a tunable parameter to src/heimdall/util/tunables.nim.

Edits:
  1. SearchParametersObj field (creating or extending tuples as needed)
  2. addTunableParameter call in initTunableParameters
  3. setParameterBody case branch
  4. getParameter case branch

Path syntax:
  foo                -> top-level scalar (foo*: int)
  foo.bar            -> nested in tuple[bar: int]; bar is grouped with siblings
                        of identical type when possible
  foo.bar.baz        -> deeper nesting
  foo.bar[Pawn]      -> array index (the array field must already exist; the
                        struct is left untouched)

Usage:
  scripts/add_tunable.py NAME PATH MIN MAX DEFAULT [--quantized] [--float]

Examples:
  scripts/add_tunable.py NewMargin newMargin 1 200 100
  scripts/add_tunable.py NewMarginQuiet newMargin.quiet 1 200 100
  scripts/add_tunable.py NewMarginNoisy newMargin.noisy 1 200 100
  scripts/add_tunable.py NewLMRBase newLmrBase 200 800 400 --float
  scripts/add_tunable.py NewDivisor newDivisor 1024 8192 4096 --quantized
  scripts/add_tunable.py SEEOrdKingWeight seeWeights.ordering[King] 0 0 0
"""

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TUNABLES_PATH = REPO_ROOT / "src" / "heimdall" / "util" / "tunables.nim"

INDENT4 = "    "
INDENT8 = "        "
INDENT12 = "            "

IDENT_RE = re.compile(r"^[a-zA-Z_]\w*$")
FIELD_RE = re.compile(r"^ {8}(\w+)\*:\s*(.+)$")


# -- tuple parsing/serialization --------------------------------------------

def split_top_commas(body: str) -> list[str]:
    parts, current, depth = [], "", 0
    for c in body:
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
        if c == "," and depth == 0:
            parts.append(current.strip())
            current = ""
        else:
            current += c
    if current.strip():
        parts.append(current.strip())
    return parts


def find_top_colon(s: str) -> int:
    depth = 0
    for i, c in enumerate(s):
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
        elif c == ":" and depth == 0:
            return i
    return -1


def parse_tuple_groups(body: str) -> list[tuple[list[str], str]]:
    groups: list[tuple[list[str], str]] = []
    pending: list[str] = []
    for part in split_top_commas(body):
        ci = find_top_colon(part)
        if ci == -1:
            pending.append(part.strip())
            continue
        names = pending + [n.strip() for n in part[:ci].split(",")]
        groups.append((names, part[ci + 1:].strip()))
        pending = []
    if pending:
        raise ValueError(f"trailing names without type: {pending}")
    return groups


def serialize_tuple(groups: list[tuple[list[str], str]]) -> str:
    return "tuple[" + ", ".join(", ".join(ns) + ": " + t for ns, t in groups) + "]"


def merge_adjacent(groups: list[tuple[list[str], str]]) -> list[tuple[list[str], str]]:
    out: list[tuple[list[str], str]] = []
    for ns, t in groups:
        if out and out[-1][1] == t:
            out[-1] = (out[-1][0] + ns, t)
        else:
            out.append((list(ns), t))
    return out


def make_nested_tuple(path: list[str], leaf_type: str) -> str:
    if not path:
        return leaf_type
    return f"tuple[{path[0]}: {make_nested_tuple(path[1:], leaf_type)}]"


def extend_tuple_type(tuple_str: str, path: list[str], leaf_type: str) -> str:
    if not (tuple_str.startswith("tuple[") and tuple_str.endswith("]")):
        raise ValueError(f"cannot descend into non-tuple type: {tuple_str!r}")
    groups = parse_tuple_groups(tuple_str[len("tuple["):-1])
    head, rest = path[0], path[1:]

    found_gi = next((gi for gi, (ns, _) in enumerate(groups) if head in ns), -1)

    if found_gi == -1:
        new_type = leaf_type if not rest else make_nested_tuple(rest, leaf_type)
        merged = False
        for ns, t in groups:
            if t == new_type:
                ns.append(head)
                merged = True
                break
        if not merged:
            groups.append(([head], new_type))
        return serialize_tuple(merge_adjacent(groups))

    names, group_type = groups[found_gi]
    if not rest:
        raise ValueError(f"field path already exists with type {group_type!r}")

    new_inner = extend_tuple_type(group_type, rest, leaf_type)
    if len(names) > 1:
        names.remove(head)
        groups.insert(found_gi + 1, ([head], new_inner))
    else:
        groups[found_gi] = (names, new_inner)
    return serialize_tuple(merge_adjacent(groups))


# -- path parsing -----------------------------------------------------------

def parse_path(path_str: str) -> tuple[list[str], str | None]:
    index: str | None = None
    if "[" in path_str:
        prefix, rest = path_str.split("[", 1)
        if not rest.endswith("]"):
            raise ValueError(f"unmatched bracket in path: {path_str!r}")
        index = rest[:-1].strip()
        path_str = prefix
        if not index:
            raise ValueError("empty array index")
    components = path_str.split(".")
    if not components or any(not c for c in components):
        raise ValueError(f"invalid path: {path_str!r}")
    for c in components:
        if not IDENT_RE.match(c):
            raise ValueError(f"invalid field name in path: {c!r}")
    return components, index


# -- file edits -------------------------------------------------------------

def find_struct_range(lines: list[str]) -> tuple[int, int]:
    start = next(
        (i for i, l in enumerate(lines)
         if re.match(r"^\s+SearchParametersObj\*\s*=\s*object", l)),
        None,
    )
    if start is None:
        raise RuntimeError("couldn't find SearchParametersObj definition")
    i = start + 1
    last_field = i
    while i < len(lines):
        stripped = lines[i].rstrip()
        bare = stripped.lstrip()
        if bare == "" or bare.startswith("#"):
            i += 1
            continue
        if FIELD_RE.match(stripped):
            last_field = i
            i += 1
            continue
        break
    return start, last_field


def modify_struct(lines: list[str], path: list[str],
                  leaf_type: str, has_index: bool) -> list[str]:
    if has_index:
        return lines

    _, last_field = find_struct_range(lines)
    head = path[0]

    head_match: tuple[int, re.Match[str]] | None = None
    for i in range(last_field + 1):
        m = FIELD_RE.match(lines[i].rstrip())
        if m and m.group(1) == head:
            head_match = (i, m)
            break

    if head_match is None:
        rest = path[1:]
        new_type = leaf_type if not rest else make_nested_tuple(rest, leaf_type)
        new_line = f"{INDENT8}{head}*: {new_type}\n"
        return lines[:last_field + 1] + [new_line] + lines[last_field + 1:]

    i, m = head_match
    current_type = m.group(2)
    rest = path[1:]
    if not rest:
        raise ValueError(
            f"field {head!r} already exists with type {current_type!r}"
        )
    new_type = extend_tuple_type(current_type, rest, leaf_type)
    return lines[:i] + [f"{INDENT8}{head}*: {new_type}\n"] + lines[i + 1:]


def insert_add_tunable(lines: list[str], name: str, min_v: int, max_v: int,
                       default: int, quantized: bool) -> list[str]:
    last_idx = max(
        (i for i, l in enumerate(lines)
         if "addTunableParameter(" in l and not l.lstrip().startswith("#")),
        default=-1,
    )
    if last_idx == -1:
        raise RuntimeError("no addTunableParameter calls found")
    extra = ", true" if quantized else ""
    new_line = f'{INDENT4}addTunableParameter("{name}", {min_v}, {max_v}, {default}{extra})\n'
    return lines[:last_idx + 1] + [new_line] + lines[last_idx + 1:]


def field_access(path: list[str], index: str | None) -> str:
    expr = ".".join(path)
    if index is not None:
        expr += f"[{index}]"
    return expr


def insert_case_branches(lines: list[str], name: str, path: list[str],
                         index: str | None, is_float: bool) -> list[str]:
    expr = field_access(path, index)
    setter_rhs = "value / 1000" if is_float else "value"
    getter_rhs = f"int(self.{expr} * 1000)" if is_float else f"self.{expr}"

    setter_branch = (
        f'{INDENT8}of "{name}":\n'
        f"{INDENT12}self.{expr} = {setter_rhs}\n"
    )
    getter_branch = (
        f'{INDENT8}of "{name}":\n'
        f"{INDENT12}{getter_rhs}\n"
    )

    positions = [
        i for i, l in enumerate(lines)
        if l.rstrip() == f"{INDENT8}else:"
        and i + 1 < len(lines)
        and "invalid tunable parameter" in lines[i + 1]
    ]
    if len(positions) != 2:
        raise RuntimeError(
            f"expected 2 invalid-tunable else clauses, found {len(positions)}"
        )
    setter_pos, getter_pos = positions  # file order: setter first, getter second

    result = lines[:]
    result = result[:getter_pos] + [getter_branch] + result[getter_pos:]
    result = result[:setter_pos] + [setter_branch] + result[setter_pos:]
    return result


# -- main -------------------------------------------------------------------

def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("name", help="SPSA parameter name (e.g. NewMarginQuiet)")
    p.add_argument("path", help="Field path (e.g. newMargin.quiet)")
    p.add_argument("min", type=int)
    p.add_argument("max", type=int)
    p.add_argument("default", type=int)
    p.add_argument("--quantized", action="store_true",
                   help="Mark the parameter as quantized")
    p.add_argument("--float", dest="is_float", action="store_true",
                   help="Leaf type is float, scaled by 1000")
    args = p.parse_args()

    if args.min > args.max:
        p.error("min must be <= max")
    if not (args.min <= args.default <= args.max):
        p.error("default must be within [min, max]")

    try:
        path, index = parse_path(args.path)
    except ValueError as e:
        p.error(str(e))

    leaf_type = "float" if args.is_float else "int"

    original = TUNABLES_PATH.read_text()
    if f'"{args.name}"' in original:
        print(f"error: parameter name {args.name!r} already appears in the file",
              file=sys.stderr)
        return 1

    lines = original.splitlines(keepends=True)
    try:
        lines = modify_struct(lines, path, leaf_type, has_index=(index is not None))
        lines = insert_add_tunable(
            lines, args.name, args.min, args.max, args.default, args.quantized
        )
        lines = insert_case_branches(lines, args.name, path, index, args.is_float)
    except (ValueError, RuntimeError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    TUNABLES_PATH.write_text("".join(lines))
    rel = TUNABLES_PATH.relative_to(REPO_ROOT)
    print(f"added tunable {args.name!r} to {rel} (run `git diff -- {rel}` to review)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
