import re
import sys
import subprocess
from shutil import which
from pathlib import Path
from argparse import ArgumentParser, Namespace



def main(args: Namespace) -> int:
    if args.silent:
        print = lambda *_: ...
    else:
        print = __builtins__.print
    print("Heimdall move validator v0.0.1 by nocturn9x")
    try:
        STOCKFISH = (args.stockfish or Path(which("stockfish"))).resolve(strict=True)
    except Exception as e:
        print(f"Could not locate stockfish executable -> {type(e).__name__}: {e}")
        return 2
    try:
        HEIMDALL = (args.heimdall or Path(which("heimdall"))).resolve(strict=True)
    except Exception as e:
        print(f"Could not locate heimdall executable -> {type(e).__name__}: {e}")
        return 2
    print(f"Starting Stockfish engine at {STOCKFISH.as_posix()!r}")
    stockfish_process = subprocess.Popen(STOCKFISH,
                                         stdout=subprocess.PIPE,
                                         stderr=subprocess.STDOUT,
                                         stdin=subprocess.PIPE,
                                         encoding="u8",
                                         text=True,
                                         bufsize=1
                                         )
    print(f"Starting Heimdall engine at {HEIMDALL.as_posix()!r}")
    heimdall_process = subprocess.Popen([HEIMDALL, "tui"],
                                       stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT,
                                       stdin=subprocess.PIPE,
                                       encoding="u8",
                                       text=True,
                                       bufsize=1
                                       )
    print(f"Setting position to {(args.fen if args.fen else 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1')!r}")
    stockfish_process.stdin.write(f"setoption name UCI_Chess960 value true\n")
    if args.fen:
        heimdall_process.stdin.write(f"position fen {args.fen}\n")
        stockfish_process.stdin.write(f"position fen {args.fen}\n")
    else:
        heimdall_process.stdin.write("position startpos\n")
        stockfish_process.stdin.write("position startpos\n")
    print(f"Engines started, beginning search to depth {args.ply}")
    heimdall_process.stdin.write(f"go perft {args.ply} {'bulk' if args.bulk else ''}\n")
    stockfish_process.stdin.write(f"go perft {args.ply}\n")
    stockfish_output, stockfish_error = stockfish_process.communicate()
    heimdall_output, heimdall_error = heimdall_process.communicate()
    if heimdall_process.returncode != 0:
        print(f"heimdall crashed, stderr output below:\n{heimdall_error}")
    if stockfish_process.returncode != 0:
        print(f"Stockfish crashed, stderr below:\n{stockfish_error}")
    if not all([stockfish_process.returncode == 0, heimdall_process.returncode == 0]):
        return 3
    positions = {
        "all": {},
        "stockfish": {},
        "heimdall": {}
    }
    pattern = re.compile(r"(?P<source>[a-h][1-8])(?P<target>[a-h][1-8])(?P<promotion>b|n|q|r)?:\s(?P<nodes>[0-9]+)", re.MULTILINE)
    for (source, target, promotion, nodes) in pattern.findall(stockfish_output):
        move = f"{source}{target}{promotion}"
        positions["all"][move] = [int(nodes)]
        positions["stockfish"][move] = int(nodes)
    for (source, target, promotion, nodes) in pattern.findall(heimdall_output):
        move = f"{source}{target}{promotion}"
        if move in positions["all"]:
            positions["all"][move].append(int(nodes))
        else:
            positions["all"][move] = [int(nodes)]
        positions["heimdall"][move] = int(nodes)
    
    missing = {
        # Are in heimdall but not in stockfish
        "heimdall": [],
        # Are in stockfish but not in heimdall
        "stockfish": []
    }
    # What mistakes did Heimdall do?
    mistakes = set()
    for move, nodes in positions["all"].items():
        if move not in positions["stockfish"]:
            missing["heimdall"].append(move)
            continue
        elif move not in positions["heimdall"]:
            missing["stockfish"].append(move)
            continue
        if nodes[0] != nodes[1]:
            mistakes.add(move)
    mistakes = sorted(list(mistakes))
    total_nodes = {"stockfish": sum(positions["stockfish"][move] for move in positions["stockfish"]),
                   "heimdall": sum(positions["heimdall"][move] for move in positions["heimdall"])}
    total_difference = total_nodes["stockfish"] - total_nodes["heimdall"]
    print(f"Stockfish searched {total_nodes['stockfish']} node{'' if total_nodes['stockfish'] == 1 else 's'}")
    print(f"Heimdall searched {total_nodes['heimdall']} node{'' if total_nodes['heimdall'] == 1 else 's'}")

    if total_difference > 0:
        print(f"Heimdall searched {total_difference} fewer node{'' if total_difference == 1 else 's'} than Stockfish")
    elif total_difference < 0:
        total_difference = abs(total_difference)
        print(f"Heimdall searched {total_difference} more node{'' if total_difference == 1 else 's'} than Stockfish")
    else:
        print("Node count is identical")
    pattern = re.compile(r"(?:\s\s-\sCaptures:\s(?P<captures>[0-9]+))\n"
                            r"(?:\s\s-\sChecks:\s(?P<checks>[0-9]+))\n"
                            r"(?:\s\s-\sE\.P:\s(?P<enPassant>[0-9]+))\n"
                            r"(?:\s\s-\sCheckmates:\s(?P<checkmates>[0-9]+))\n"
                            r"(?:\s\s-\sCastles:\s(?P<castles>[0-9]+))\n"
                            r"(?:\s\s-\sPromotions:\s(?P<promotions>[0-9]+))",
                            re.MULTILINE)
    extra: re.Match | None = None
    if not args.bulk:
        extra = pattern.search(heimdall_output)
    missed_total = len(missing['stockfish']) + len(missing['heimdall'])
    if missing["stockfish"] or missing["heimdall"] or mistakes:
        print(f"Found {missed_total} missed move{'' if missed_total == 1 else 's'} and {len(mistakes)} counting mistake{'' if len(mistakes) == 1 else 's'}, more info below: ")
        if args.bulk:
            print("Note: Heimdall was run in bulk-counting mode, so a detailed breakdown of each move type is not available. "
                  "To fix this, re-run the program without the --bulk option")
        if extra:
            print(f"   Breakdown by move type:")
            print(f"      - Captures: {extra.group('captures')}")
            print(f"      - Checks: {extra.group('checks')}")
            print(f"      - En Passant: {extra.group('enPassant')}")
            print(f"      - Checkmates: {extra.group('checkmates')}")
            print(f"      - Castles: {extra.group('castles')}")
            print(f"      - Promotions: {extra.group('promotions')}")

        elif not args.bulk:
            print("Unable to locate move breakdown in Heimdall output")
        if missing["stockfish"] or missing["heimdall"]:
            print("\n   Move count breakdown:")
            if missing["stockfish"]:
                print("      Legal moves missed: ")
                for move in missing["stockfish"]:
                    print(f"       - {move}: {positions['stockfish'][move]}")
            if missing["heimdall"]:
                print("\n      Illegal moves generated: ")
                for move in missing["heimdall"]:
                    print(f"       - {move}: {positions['heimdall'][move]}")
        if mistakes:
            print("\n   Counting mistakes made:")
            for move in mistakes:
                missed = positions["stockfish"][move] - positions["heimdall"][move]
                print(f"       - {move}: expected {positions['stockfish'][move]}, got {positions['heimdall'][move]} ({'-' if missed > 0 else '+'}{abs(missed)})")
        return 1
    else:
        print("No discrepancies detected")
        return 0

    


if __name__ == "__main__":
    parser = ArgumentParser(description="Automatically compare perft results between Heimdall and Stockfish")
    parser.add_argument("--fen", "-f", type=str, default="", help="The FEN string of the position to start from (empty string means the initial one). Defaults to ''")
    parser.add_argument("--ply", "-d", type=int, required=True, help="The depth to stop at, expressed in plys (half-moves)")
    parser.add_argument("--bulk", action="store_true", help="Enable bulk-counting for Heimdall (much faster)", default=False)
    parser.add_argument("--stockfish", type=Path, help="Path to the stockfish executable. Defaults to '' (detected automatically)", default=None)
    parser.add_argument("--heimdall", type=Path, help="Path to the heimdall executable. Defaults to '' (detected automatically)", default=None)
    parser.add_argument("--silent", action="store_true", help="Disable all output (a return code of 0 means the test was successful)", default=False)
    try:
        sys.exit(main(parser.parse_args()))
    except KeyboardInterrupt:
        sys.exit(255)
