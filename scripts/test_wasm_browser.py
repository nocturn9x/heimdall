#!/usr/bin/env python3
# Copyright 2026 Mattia Giambirtone & All Contributors
# SPDX-License-Identifier: Apache-2.0

"""Exercise the shipped demo and its real Wasm pthreads in Chromium."""

import argparse
from functools import partial
from http.server import ThreadingHTTPServer
from pathlib import Path
from threading import Thread

from serve_wasm import IsolatedHandler


class QuietHandler(IsolatedHandler):
    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path("build/wasm"))
    parser.add_argument("--browser", help="Use an installed Chromium executable")
    args = parser.parse_args()
    if not (args.directory / "heimdall.wasm").is_file():
        parser.error("Build the engine first with make dev TARGET=wasm")
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        parser.error("Install Playwright to run this optional test: pip install playwright")

    handler = partial(QuietHandler, directory=str(args.directory.resolve()))
    with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with sync_playwright() as playwright:
                browser = playwright.chromium.launch(executable_path=args.browser, headless=True)
                page = browser.new_page()
                errors = []
                page.on("pageerror", lambda error: errors.append(str(error)))
                page.goto(f"http://127.0.0.1:{server.server_port}")
                page.wait_for_function('document.querySelector("#status").textContent.startsWith("Ready")', timeout=45000)
                assert page.evaluate("crossOriginIsolated"), "Missing isolation headers"
                max_threads = int(page.locator("#threads option").last.inner_text())

                # Invalid input must leave the UI usable without searching an old board.
                page.locator("#position").fill("not a fen")
                page.locator("#analyze").click()
                page.wait_for_function('document.querySelector("#status").textContent.includes("rejected that position")')
                assert page.locator("#analyze").is_enabled()
                page.locator("#position").fill("startpos")
                page.locator("#command").fill("go depth -1")
                page.locator("#command").press("Enter")
                page.wait_for_function('document.querySelector("#status").textContent.includes("unknown or invalid command")')
                assert page.locator("#analyze").is_enabled()

                for count in dict.fromkeys([1, min(2, max_threads), max_threads]):
                    page.locator("#threads").select_option(str(count))
                    page.locator("#analyze").click()
                    page.wait_for_function('document.querySelector("#output").textContent.split("> go infinite").at(-1).includes("info depth 3")', timeout=15000)
                    page.locator("#stop").click()
                    page.wait_for_function('document.querySelector("#status").textContent.startsWith("bestmove")', timeout=10000)
                    print(f"Browser search and stop passed with {count} search threads")
                page.locator("#command").fill("quit")
                page.locator("#command").press("Enter")
                page.wait_for_function('document.querySelector("#status").textContent === "info string Browser engine exited"')
                assert not errors, errors
                assert "Browser engine error:" not in page.locator("#output").inner_text()
                browser.close()
        finally:
            server.shutdown()
            thread.join()
    print("Browser smoke test passed")


if __name__ == "__main__":
    main()
