// Copyright 2026 Mattia Giambirtone & All Contributors
// SPDX-License-Identifier: Apache-2.0

// UCI and threading regressions against the actual Wasm engine under Node.
// Optionally compare deterministic searches with a native build of the same net.
const assert = require("node:assert/strict");
const path = require("node:path");
const {spawnSync} = require("node:child_process");

const modulePath = path.resolve(process.argv[2] || "build/wasm/heimdall.js");
const nativePath = process.argv[3];
const lines = [];
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const deadline = setTimeout(() => { console.error(lines.slice(-40).join("\n")); process.exit(1); }, 90000);

async function waitFor(predicate, start = 0, timeout = 15000) {
    const end = Date.now() + timeout;
    while (Date.now() < end) {
        const line = lines.slice(start).find(predicate);
        if (line !== undefined) return line;
        const error = lines.find(line => /Browser engine error:|AssertionDefect|Aborted\(/.test(line));
        if (error) throw new Error(error);
        await sleep(5);
    }
    throw new Error("Timed out waiting for engine output:\n" + lines.slice(-30).join("\n"));
}

function signature(output) {
    const info = output.filter(line => line.startsWith("info depth ")).at(-1);
    assert.ok(info, "missing final search report");
    return {
        depth: info.match(/\bdepth (\d+)/)[1],
        nodes: info.match(/\bnodes (\d+)/)[1],
        score: info.match(/\bscore (cp|mate) (-?\d+)/).slice(1),
        pv: info.split(" pv ")[1],
        bestmove: output.find(line => line.startsWith("bestmove ")),
    };
}

async function main() {
    const engine = await require(modulePath)({print: line => lines.push(line), printErr: line => lines.push(line)});
    assert.equal(engine._heimdall_ready(), 1);
    function send(line) {
        assert.equal(engine.ccall("heimdall_command", "number", ["string"], [line]), 0, line);
    }
    async function barrier() {
        const start = lines.length;
        send("isready");
        await waitFor(line => line === "readyok", start);
    }

    send("uci");
    await waitFor(line => line === "uciok");
    const maxThreads = Number(lines.find(line => line.startsWith("option name Threads ")).match(/max (\d+)/)[1]);
    await barrier();
    send("position startpos");
    send("go perft 4 bulk");
    await waitFor(line => /^Nodes searched .*: 197281$/.test(line));
    await barrier();

    const positions = [
        "startpos",
        "fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "startpos moves e2e4 c7c5 g1f3 d7d6 d2d4 c5d4 f3d4",
    ];
    for (const position of positions) {
        send("ucinewgame");
        await barrier();
        const start = lines.length;
        send("position " + position);
        send("go depth 7");
        await waitFor(line => line.startsWith("bestmove "), start);
        send("wait");
        await barrier();
        const actual = signature(lines.slice(start));
        if (nativePath) {
            const result = spawnSync(nativePath, [], {
                input: `uci\nucinewgame\nposition ${position}\ngo depth 7\nwait\nisready\nquit\n`,
                encoding: "utf8", timeout: 20000,
                env: {...process.env, NO_COLOR: "1", NO_LOGO: "1"},
            });
            assert.equal(result.status, 0, result.error || result.stderr);
            assert.deepEqual(actual, signature(result.stdout.split(/\r?\n/)), position);
        }
        console.log(`Search agrees: ${position} (${actual.nodes} nodes, ${actual.bestmove})`);
    }

    // Persistent search threads plus TT initialization must fit the fixed pool.
    for (const threads of [...new Set([1, Math.min(2, maxThreads), maxThreads])]) {
        send(`setoption name Threads value ${threads}`);
        send("setoption name Hash value 16");
        send("setoption name TTClear");
        send("ucinewgame");
        await barrier();
        for (let cycle = 0; cycle < 3; cycle++) {
            const start = lines.length;
            send("position startpos");
            send("go infinite");
            if (cycle !== 0) await waitFor(line => /^info depth [2-9]\b/.test(line), start);
            send("stop");
            await waitFor(line => /^bestmove [a-h][1-8][a-h][1-8]/.test(line), start);
            await barrier();
        }
        const start = lines.length;
        send("position startpos");
        send("go movetime 350");
        await waitFor(line => line.startsWith("bestmove "), start);
        send("wait");
        await barrier();
        console.log(`Stop, reuse, TT clear and timed search pass with ${threads} search threads`);
    }

    let start = lines.length;
    send(`setoption name Threads value ${maxThreads + 1}`);
    await waitFor(line => line.includes("Threads must be between"), start);
    start = lines.length;
    send("setoption name Hash value 257");
    await waitFor(line => line.includes("Hash must be between"), start);
    await barrier();
    // Exercise shared-memory growth and replacement of a live allocation.
    send("setoption name Hash value 256");
    send("setoption name TTClear");
    await barrier();
    send("setoption name Hash value 16");
    await barrier();
    send("quit");
    for (let i = 0; engine._heimdall_ready() !== 3 && i < 1000; i++) await sleep(5);
    assert.equal(engine._heimdall_ready(), 3, "clean shutdown");
    assert.equal(engine.ccall("heimdall_command", "number", ["string"], ["uci"]), 1);
    console.log("Wasm regressions passed");
    clearTimeout(deadline);
    process.exit(0);
}

main().catch(error => { console.error(error); console.error(lines.slice(-40).join("\n")); process.exit(1); });
