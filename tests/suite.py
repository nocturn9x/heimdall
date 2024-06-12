import sys
import timeit
from pathlib import Path
from argparse import Namespace, ArgumentParser
from compare_positions import main as test
from concurrent.futures import ThreadPoolExecutor, as_completed
from multiprocessing import cpu_count
from copy import deepcopy


def main(args: Namespace) -> int:
    # We try to be polite with resource usage
    successful = []
    failed = []
    positions = args.positions_file.read_text().splitlines()
    print(f"[S] Loaded {len(positions)} position{'' if len(positions) == 1 else 's'}")
    longest_fen = max(sorted([len(fen) for fen in positions]))
    if not args.parallel:
        print("[S] Starting test suite")
    else:
        print(f"[S] Starting test suite with {args.workers} workers")
    start = timeit.default_timer()
    if not args.parallel:
        for i, fen in enumerate(positions):
            fen = fen.strip(" ")
            fen += " " * (longest_fen - len(fen))
            sys.stdout.write(f"\r[S] Testing {fen} ({i + 1}/{len(positions)})\033[K")
            args.fen = fen
            args.silent = not args.no_silent
            if test(args) == 0:
                successful.append(fen)
            else:
                failed.append(fen)
    else:
        # There is no compute going on in the Python thread,
        # it's just I/O waiting for the processes to finish,
        # so using a thread as opposed to a process doesn't
        # make much different w.r.t. the GIL (and threads are
        # cheaper than processes on some platforms)
        futures = {}
        try:
            pool = ThreadPoolExecutor(args.workers)
            for fen in positions:
                args = deepcopy(args)
                args.fen = fen.strip(" ")
                args.silent = not args.no_silent
                futures[pool.submit(test, args)] = args.fen
            for i, future in enumerate(as_completed(futures)):
                sys.stdout.write(f"\r[S] Testing in progress ({i + 1}/{len(positions)})\033[K")
                if future.result() == 0:
                    successful.append(futures[future])
                else:
                    failed.append(futures[future])
        except KeyboardInterrupt:
            stop = timeit.default_timer()
            pool.shutdown(cancel_futures=True)
            print(f"\r[S] Interrupted\033[K")
            total = len(successful) + len(failed)
            print(f"[S] Ran {total} tests at depth {args.ply} in {stop - start:.2f} seconds ({len(successful)} successful, {len(failed)} failed)")
            if failed and args.show_failures:
                print("[S] The following FENs failed to pass the test:\n\t", end="")
                print("\n\t".join(failed))
        else:
            stop = timeit.default_timer()
            print(f"\r[S] Ran {len(positions)} tests at depth {args.ply} in {stop - start:.2f} seconds ({len(successful)} successful, {len(failed)} failed)\033[K")
            if failed and args.show_failures:
                print("[S] The following FENs failed to pass the test:\n\t", end="")
                print("\n\t".join(failed))


if __name__ == "__main__":
    parser = ArgumentParser(description="Run a set of tests using compare_positions.py")
    parser.add_argument("--ply", "-d", type=int, required=True, help="The depth to stop at, expressed in plys (half-moves)")
    parser.add_argument("-b", "--bulk", action="store_true", help="Enable bulk-counting for Heimdall (much faster)", default=False)
    parser.add_argument("--stockfish", type=Path, help="Path to the stockfish executable. Defaults to '' (detected automatically)", default=None)
    parser.add_argument("--heimdall", type=Path, help="Path to the heimdall executable. Defaults to '' (detected automatically)", default=None)
    parser.add_argument("--positions-file", "-f", type=Path, help="Location of the file containing FENs to test, one per line. Defaults to 'tests/all.txt'", 
                        default=Path("tests/all.txt"))
    parser.add_argument("--no-silent", action="store_true", help="Do not suppress output from compare_positions.py (defaults to False)", default=False)
    parser.add_argument("-p", "--parallel", action="store_true", help="Run multiple tests in parallel", default=False)
    parser.add_argument("--workers", "-w", type=int, required=False, help="How many workers to use in parallel mode (defaults to cpu_count() / 2)", default=cpu_count() // 2)
    parser.add_argument("-s", "--show-failures", action="store_true", help="Show which FENs failed to pass the test", default=False)
    try:
        sys.exit(main(parser.parse_args()))
    except KeyboardInterrupt:
        sys.exit(255)