#!/usr/bin/env python3
# Copyright 2026 Mattia Giambirtone & All Contributors
# SPDX-License-Identifier: Apache-2.0

"""Serve the browser engine with the isolation headers required by pthreads."""

import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class IsolatedHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path("build/wasm"))
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    if not (args.directory / "heimdall.js").is_file():
        parser.error("Build the engine first with make dev TARGET=wasm")
    handler = partial(IsolatedHandler, directory=str(args.directory.resolve()))
    with ThreadingHTTPServer((args.host, args.port), handler) as server:
        print(f"Heimdall: http://{args.host}:{server.server_port}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
