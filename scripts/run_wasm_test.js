// Copyright 2026 Mattia Giambirtone & All Contributors
// SPDX-License-Identifier: Apache-2.0

// Run a standalone Nim test built through make dev TARGET=wasm WASM_MAIN=...
const path = require("node:path");
const filename = process.argv[2];
if (!filename) {
    console.error("Usage: node scripts/run_wasm_test.js /path/to/heimdall.js");
    process.exit(2);
}
const modulePath = path.resolve(filename);
require(modulePath)({locateFile: name => path.join(path.dirname(modulePath), name)})
    .catch(error => { console.error(error); process.exit(1); });
