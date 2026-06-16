#!/usr/bin/env python3
import argparse
import os
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path


ILLEGAL_INSTRUCTION_EXIT_CODES = {
    -signal.SIGILL,
    128 + signal.SIGILL,
    0xC000001D,
    -1073741795,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify built binaries match the bench recorded in a commit message"
    )
    parser.add_argument("--commit", default="HEAD", help="commit to read the expected bench from")
    parser.add_argument("--depth", default=13, type=int, help="bench depth to run")
    parser.add_argument("binaries", nargs="+", help="binaries to verify")
    args = parser.parse_args()
    if args.depth < 0:
        parser.error("--depth must be non-negative")
    return args


def expected_bench(commit: str) -> str:
    result = subprocess.run(
        ["git", "log", "-1", "--format=%B", commit],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    message = result.stdout
    match = re.search(r"\(bench\s+([0-9]+)\)", message)
    if match is None:
        match = re.search(r"bench:\s*([0-9]+)", message)
    if match is None:
        raise RuntimeError(f"could not find '(bench N)' or 'bench: N' in commit '{commit}'")
    return match.group(1)


def proc_cpuinfo_flags() -> set[str]:
    cpuinfo = Path("/proc/cpuinfo")
    if not cpuinfo.is_file():
        return set()

    flags: set[str] = set()
    for line in cpuinfo.read_text(errors="ignore").splitlines():
        key, sep, value = line.partition(":")
        if sep == "" or key.strip().lower() not in {"flags", "features"}:
            continue
        flags.update(flag.lower() for flag in value.split())
    return flags


def cpu_probe_compiler() -> str | None:
    candidates = [os.environ.get("CC"), "cc", "clang", "gcc", "cl"]
    for candidate in candidates:
        if candidate and shutil.which(candidate):
            return candidate
    return None


def cpuid_probe_source() -> str:
    return textwrap.dedent(
        r"""
        #include <stdio.h>

        #if defined(__i386__) || defined(__x86_64__) || defined(_M_IX86) || defined(_M_X64)
        #if defined(_MSC_VER)
        #include <intrin.h>
        static void cpuidex(unsigned leaf, unsigned subleaf, unsigned regs[4]) {
            int out[4];
            __cpuidex(out, (int)leaf, (int)subleaf);
            regs[0] = (unsigned)out[0];
            regs[1] = (unsigned)out[1];
            regs[2] = (unsigned)out[2];
            regs[3] = (unsigned)out[3];
        }
        static unsigned long long xgetbv0(void) {
            return _xgetbv(0);
        }
        #else
        #include <cpuid.h>
        static void cpuidex(unsigned leaf, unsigned subleaf, unsigned regs[4]) {
            __cpuid_count(leaf, subleaf, regs[0], regs[1], regs[2], regs[3]);
        }
        static unsigned long long xgetbv0(void) {
            unsigned eax, edx;
            __asm__ volatile("xgetbv" : "=a"(eax), "=d"(edx) : "c"(0));
            return ((unsigned long long)edx << 32) | eax;
        }
        #endif
        #endif

        int main(void) {
        #if defined(__i386__) || defined(__x86_64__) || defined(_M_IX86) || defined(_M_X64)
            unsigned regs[4] = {0, 0, 0, 0};
            cpuidex(1, 0, regs);
            unsigned leaf1_ecx = regs[2];
            int osxsave = (regs[2] & (1u << 27)) != 0;
            if (!osxsave) {
                return 0;
            }

            unsigned long long xcr0 = xgetbv0();
            int avx_state = (xcr0 & 0x6u) == 0x6u;
            int avx512_state = (xcr0 & 0xe6u) == 0xe6u;
            cpuidex(7, 0, regs);

            if (avx_state && (regs[1] & (1u << 5))) {
                puts("avx2");
            }
            if (avx_state && (leaf1_ecx & (1u << 12))) {
                puts("fma");
            }
            if (regs[1] & (1u << 3)) {
                puts("bmi1");
            }
            if (regs[1] & (1u << 8)) {
                puts("bmi2");
            }
            if (avx512_state && (regs[1] & (1u << 16))) {
                puts("avx512f");
            }
            if (avx512_state && (regs[1] & (1u << 17))) {
                puts("avx512dq");
            }
            if (avx512_state && (regs[1] & (1u << 28))) {
                puts("avx512cd");
            }
            if (avx512_state && (regs[1] & (1u << 30))) {
                puts("avx512bw");
            }
            if (avx512_state && (regs[1] & (1u << 31))) {
                puts("avx512vl");
            }
            if (avx512_state && (regs[2] & (1u << 11))) {
                puts("avx512vnni");
            }
        #endif
            return 0;
        }
        """
    )


def cpuid_probe_flags() -> set[str]:
    compiler = cpu_probe_compiler()
    if compiler is None:
        return set()

    with tempfile.TemporaryDirectory() as tempdir:
        temp = Path(tempdir)
        source = temp / "cpu_probe.c"
        binary = temp / ("cpu_probe.exe" if sys.platform.startswith(("win", "msys", "cygwin")) else "cpu_probe")
        source.write_text(cpuid_probe_source())

        compile_cmd = [compiler, str(source), "-O2", "-o", str(binary)]
        if Path(compiler).name.lower() == "cl":
            compile_cmd = [compiler, "/nologo", "/O2", str(source), f"/Fe:{binary}"]

        try:
            subprocess.run(
                compile_cmd,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            result = subprocess.run(
                [str(binary)],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except (OSError, subprocess.CalledProcessError):
            return set()

    return set(result.stdout.split())


def host_cpu_flags() -> set[str]:
    flags = cpuid_probe_flags()
    if flags:
        return flags
    return proc_cpuinfo_flags()


def binary_cpu_requirements(binary: Path) -> set[str]:
    name = binary.name.lower()
    avx512_v4 = {"avx512f", "avx512bw", "avx512cd", "avx512dq", "avx512vl"}
    if "-vnni" in name:
        return avx512_v4 | {"avx512vnni"}
    if "-avx512" in name:
        return avx512_v4
    if "-haswell" in name or "-zen2" in name:
        return {"avx2", "fma", "bmi1", "bmi2"}
    return set()


def unsupported_reason(binary: Path, flags: set[str]) -> str | None:
    required = binary_cpu_requirements(binary)
    if not required or not flags:
        return None

    missing = sorted(required - flags)
    if missing:
        return "host CPU is missing " + ", ".join(missing)
    return None


def is_illegal_instruction(returncode: int) -> bool:
    return returncode in ILLEGAL_INSTRUCTION_EXIT_CODES


def actual_bench(binary: Path, depth: int) -> tuple[int, str | None, str]:
    result = subprocess.run(
        [str(binary), "bench", str(depth), "-s"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    bench = None
    for line in result.stdout.splitlines():
        match = re.match(r"^([0-9]+) nodes ", line)
        if match is not None:
            bench = match.group(1)
    return result.returncode, bench, result.stdout


def main() -> int:
    args = parse_args()
    try:
        expected = expected_bench(args.commit)
    except (RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    status = 0
    flags = host_cpu_flags()
    for binary_name in args.binaries:
        binary = Path(binary_name)
        if not binary.is_file():
            print(f"Error: binary '{binary}' does not exist", file=sys.stderr)
            status = 1
            continue

        reason = unsupported_reason(binary, flags)
        if reason is not None:
            print(f"Skipping {binary}: {reason}")
            continue

        print(f"Checking {binary} against bench {expected}")
        try:
            returncode, actual, output = actual_bench(binary, args.depth)
        except OSError as exc:
            print(f"Error: failed to run '{binary}': {exc}", file=sys.stderr)
            status = 1
            continue

        if returncode != 0:
            if is_illegal_instruction(returncode):
                print(f"Skipping {binary}: failed with illegal instruction exit code {returncode}")
                continue
            print(
                f"Error: '{binary} bench {args.depth} -s' failed with exit code {returncode}",
                file=sys.stderr,
            )
            print("\n".join(output.splitlines()[-20:]), file=sys.stderr)
            status = 1
        elif actual is None:
            print(f"Error: failed to extract bench from '{binary}' output", file=sys.stderr)
            print("\n".join(output.splitlines()[-20:]), file=sys.stderr)
            status = 1
        elif actual != expected:
            print(f"Error: '{binary}' bench was {actual}, expected {expected}", file=sys.stderr)
            status = 1
        else:
            print(f"{binary}: bench {actual}")

    return status


if __name__ == "__main__":
    raise SystemExit(main())
