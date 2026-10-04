// Copyright 2026 Mattia Giambirtone & All Contributors
// SPDX-License-Identifier: Apache-2.0

// Emscripten uses this same worker entry point for its pthread workers.
if (self.name === "em-pthread") {
    importScripts(new URL("heimdall.js", self.location.href).href);
} else {
    const ready = (async () => {
        if (!self.crossOriginIsolated || typeof SharedArrayBuffer === "undefined") {
            throw new Error("Serve this page with COOP/COEP headers over HTTPS or localhost.");
        }
        const moduleUrl = new URL("heimdall.js", self.location.href).href;
        importScripts(moduleUrl);
        const engine = await createHeimdall({
            locateFile: path => new URL(path, moduleUrl).href,
            print: line => postMessage(line),
            printErr: line => postMessage(line),
            onAbort: reason => postMessage(`info string Browser engine error: ${reason}`),
        });
        if (engine._heimdall_ready() !== 1) throw new Error("Engine initialization failed.");
        return engine;
    })();

    ready.catch(error => postMessage(`info string Browser engine error: ${error.message}`));

    self.onmessage = async ({data}) => {
        try {
            if (typeof data !== "string" || data.includes("\0")) {
                throw new Error("Expected a UCI command string.");
            }
            const engine = await ready;
            for (const line of data.split(/\r?\n/).map(line => line.trim()).filter(Boolean)) {
                if (line.length > 65536) throw new Error("UCI command exceeds 64 KiB.");
                const result = engine.ccall("heimdall_command", "number", ["string"], [line]);
                if (result !== 0) throw new Error(`Command rejected (${result}): ${line}`);
                if (line === "quit") {
                    const stopped = setInterval(() => {
                        if (engine._heimdall_ready() === 3) {
                            clearInterval(stopped);
                            postMessage("info string Browser engine exited");
                        }
                    }, 10);
                }
            }
        } catch (error) {
            postMessage(`info string Browser engine error: ${error.message}`);
        }
    };
}
