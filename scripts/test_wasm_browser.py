#!/usr/bin/env python3
# Copyright 2026 Mattia Giambirtone & All Contributors
# SPDX-License-Identifier: Apache-2.0

"""Exercise the chess website, UCI console, and real Wasm pthreads in Chromium."""

import argparse
from functools import partial
from http.server import ThreadingHTTPServer
from pathlib import Path
from threading import Thread

from serve_wasm import IsolatedHandler


class QuietHandler(IsolatedHandler):
    def log_message(self, *_):
        pass


def exercise_site(page, url):
    page.add_init_script("""
        window.engineCommands = [];
        window.engineLines = [];
        const NativeWorker = window.Worker;
        window.Worker = class extends NativeWorker {
            constructor(...args) {
                super(...args);
                this.addEventListener('message', event => window.engineLines.push(event.data));
            }
            postMessage(data, ...rest) {
                window.engineCommands.push(data);
                return super.postMessage(data, ...rest);
            }
        };
    """)
    page.goto(url)
    page.wait_for_selector("#connection.ready", timeout=45000)
    assert page.evaluate("crossOriginIsolated"), "Missing isolation headers"
    assert page.locator(".square").count() == 64
    assert "dark" in page.locator('[data-square="a1"]').get_attribute("class").split()
    assert "dark" not in page.locator('[data-square="h1"]').get_attribute("class").split()
    assert page.locator("#game-status").inner_text() == "White to move"
    page.locator("#think-time").select_option("300")

    def move(source, target):
        page.locator(f'[data-square="{source}"]').click()
        page.locator(f'[data-square="{target}"]').click()

    def move_count(count):
        page.wait_for_function("count => document.querySelectorAll('.move-entry').length === count", arg=count, timeout=15000)

    def load(text):
        if not page.locator("#position-panel").evaluate("element => element.open"):
            page.locator("#position-panel summary").click()
        page.locator("#position-input").fill(text)
        page.locator("#load-position").click()

    # Legal moves, a real engine reply, and retaining its evaluation for the player.
    move("e2", "e5")
    move_count(0)
    move("e2", "e4")
    move_count(2)
    assert page.locator("#game-status").inner_text() == "White to move"
    assert page.locator("#score").inner_text() != "—"
    page.locator("#undo").click()
    move_count(0)

    # Changing the board while a timed search runs must discard its old reply.
    page.locator("#think-time").select_option("3000")
    completed = page.evaluate("engineLines.filter(line => line.startsWith('bestmove ')).length")
    move("d2", "d4")
    page.wait_for_function("engineCommands.at(-1) === 'go movetime 3000'")
    page.locator("#new-game").click()
    page.wait_for_function("count => engineLines.filter(line => line.startsWith('bestmove ')).length > count", arg=completed)
    page.wait_for_timeout(300)
    move_count(0)
    assert page.locator('[data-square="d2"]').get_attribute("aria-label") == "d2, white pawn"

    # Playing Black starts with an engine move and flips the board.
    page.locator("#think-time").select_option("300")
    page.locator("#side-black").click()
    move_count(1)
    assert page.locator(".square").first.get_attribute("data-square") == "h1"
    move("e7", "e5")
    move_count(3)
    page.locator("#mode-analysis").click()

    # Stop/restart and option changes remain responsive during infinite search.
    max_threads = int(page.locator("#threads option").last.inner_text())
    for count in dict.fromkeys([1, min(2, max_threads), max_threads]):
        page.locator("#threads").select_option(str(count))
        page.wait_for_function("Number(document.querySelector('#depth').textContent) >= 5", timeout=15000)
        page.locator("#engine-toggle").click()
        assert page.locator("#engine-toggle").get_attribute("aria-label") == "Start analysis"
        page.locator("#engine-toggle").click()
        page.wait_for_function("document.querySelector('#search-dot').classList.contains('busy')")
    page.locator("#engine-toggle").click()

    # Invalid imports leave the current board intact and the engine available.
    before = page.locator("#moves").inner_text()
    for invalid in ["not a fen", "4k3/8/8/8/8/8/8/4K3 w KQ - 0 1", "8/8/8/8/8/8/4k3/4K3 w - - 0 1"]:
        load(invalid)
        assert page.locator("#position-error").inner_text()
        assert page.locator("#moves").inner_text() == before
    load("1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 *")
    move_count(6)
    page.context.grant_permissions(["clipboard-read", "clipboard-write"])
    page.locator("#copy-fen").click()
    copied = page.evaluate("navigator.clipboard.readText()")
    assert copied.startswith("r1bqkb1r/pppp1ppp/2n2n2/")
    page.wait_for_function("Number(document.querySelector('#depth').textContent) >= 5")
    page.locator("#history-prev").click()
    assert "5 / 6" in page.locator("#history-position").inner_text()
    # Branching from a reviewed position truncates the old continuation.
    move("d7", "d6")
    move_count(6)
    assert page.locator(".move-entry").last.inner_text() == "d6"
    page.locator('[data-square="d2"]').scroll_into_view_if_needed()
    source = page.locator('[data-square="d2"]').bounding_box()
    target = page.locator('[data-square="d3"]').bounding_box()
    page.mouse.move(source["x"] + source["width"] / 2, source["y"] + source["height"] / 2)
    page.mouse.down()
    page.mouse.move(target["x"] + target["width"] / 2, target["y"] + target["height"] / 2, steps=8)
    page.mouse.up()
    move_count(7)
    assert page.locator(".move-entry").last.inner_text() == "d3"

    # Standard castling is translated to king-to-rook for Heimdall's UCI parser.
    load("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
    move("e1", "g1")
    move_count(1)
    assert page.locator('[data-square="f1"]').get_attribute("aria-label") == "f1, white rook"
    page.wait_for_function("engineCommands.some(line => line.startsWith('position fen r3k2r/') && line.endsWith('moves e1h1'))")
    page.wait_for_function("Number(document.querySelector('#depth').textContent) >= 5")
    move("e8", "c8")
    page.wait_for_function("engineCommands.some(line => line.endsWith('moves e1h1 e8a8'))")
    page.wait_for_function("Number(document.querySelector('#depth').textContent) >= 5")

    load("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1")
    move("e5", "d6")
    assert page.locator('[data-square="d5"]').get_attribute("aria-label") == "d5, empty"
    load("8/P6k/8/8/8/8/8/4K3 w - - 0 1")
    move("a7", "a8")
    page.locator('[aria-label="Promote to knight"]').click()
    page.wait_for_function("document.querySelector('[data-square=\"a8\"]').getAttribute('aria-label') === 'a8, white knight'")
    assert page.locator('[data-square="a8"]').get_attribute("aria-label") == "a8, white knight"
    assert "insufficient material" in page.locator("#game-status").inner_text()
    assert page.locator("#engine-toggle").is_disabled()

    # Mate score must be converted from side-to-move to White's perspective.
    load("6k1/5ppp/8/8/8/8/5PPP/4R1K1 w - - 0 1")
    page.wait_for_function("document.querySelector('#score').textContent === 'M1'", timeout=15000)
    assert page.locator("#score-description").inner_text() == "White has mate in 1"
    move("e1", "e8")
    assert "White wins by checkmate" == page.locator("#game-status").inner_text()
    load("4r1k1/5ppp/8/8/8/8/5PPP/6K1 b - - 0 1")
    page.wait_for_function("document.querySelector('#score').textContent === '−M1'", timeout=15000)
    assert page.locator("#score-description").inner_text() == "Black has mate in 1"

    # Downloaded PGN preserves an imported starting FEN and the move history.
    with page.expect_download() as download:
        page.locator("#download-pgn").click()
    pgn = Path(download.value.path()).read_text()
    assert '[FEN "4r1k1/' in pgn
    assert '[Result "*"]' in pgn
    page.locator("#engine-toggle").click()
    for width in [320, 390, 768, 1440]:
        page.set_viewport_size({"width": width, "height": 900})
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth"), width
        assert page.locator("#board").bounding_box()["width"] > 200
    errors = page.evaluate("engineLines.filter(line => /Browser engine error:|info string error:/.test(line))")
    assert not errors, errors
    print("Chess website passed: play both sides, cancellation, analysis, history, imports, castling, en passant, promotion, mate, PGN, and responsive layout")


def exercise_controls(page, url):
    page.goto(url)
    page.wait_for_selector("#connection.ready", timeout=45000)
    assert page.locator("#hash").input_value() == "64"
    assert page.locator("#hash").get_attribute("min") == "1"
    assert page.locator("#hash").get_attribute("max") == "256"
    assert page.locator("#hash").get_attribute("step") == "1"
    max_threads = int(page.locator("#threads option").last.inner_text())
    assert max_threads == min(64, page.evaluate("navigator.hardwareConcurrency || 1"))
    assert "Make your next move" not in page.locator("body").inner_text()
    assert "A LITTLE CHESS" not in page.locator("body").inner_text()

    # Resize and clear while idle, then verify an actual search uses the options.
    for invalid in ["0", "257", "1.5", ""]:
        start = page.evaluate("engineCommands.length")
        page.locator("#hash").fill(invalid)
        page.locator("#hash").dispatch_event("change")
        assert page.locator("#hash").input_value() == "64"
        assert not page.evaluate("start => engineCommands.slice(start).some(line => line.startsWith('setoption name Hash'))", start)
    page.locator("#hash").fill("96")
    page.locator("#hash").press("Tab")
    page.wait_for_function("engineCommands.includes('setoption name Hash value 96')")
    page.locator("#clear-hash").click()
    page.wait_for_function("document.querySelector('#toast').textContent === 'Hash cleared'")
    assert page.evaluate("engineCommands.includes('setoption name TTClear')")
    page.locator("#mode-analysis").click()
    page.wait_for_function("Number(document.querySelector('#depth').textContent) >= 5")
    for size in [256, 1, 192, 65, 64]:
        start = page.evaluate("engineCommands.length")
        page.locator("#hash").fill(str(size))
        page.locator("#hash").press("Tab")
        page.wait_for_function("({start, size}) => engineCommands.slice(start).includes(`setoption name Hash value ${size}`) && engineCommands.slice(start).includes('go infinite')", arg={"start": start, "size": size})
    page.locator("#clear-hash").click()
    page.wait_for_function("!document.querySelector('#clear-hash').disabled")
    assert page.locator("#engine-toggle").get_attribute("aria-label") == "Stop engine"
    page.locator("#engine-toggle").click()
    page.locator("#hash").fill("33")
    page.locator("#hash").press("Tab")
    page.wait_for_function("engineCommands.includes('setoption name Hash value 33')")
    assert page.locator("#engine-toggle").get_attribute("aria-label") == "Start analysis"

    # Control the page's monotonic clock without spending minutes on flag tests.
    page.clock.install()
    page.locator("#mode-play").click()
    page.locator("#time-control").select_option("300+3")
    assert page.locator("#bottom-clock").inner_text() == "5:00"
    assert page.locator("#top-clock").inner_text() == "5:00"
    page.clock.fast_forward(1000)
    page.locator('[data-square="e2"]').click()
    page.locator('[data-square="e4"]').click()
    page.wait_for_function("engineCommands.some(line => /^go wtime \\d+ btime \\d+ winc 3000 binc 3000$/.test(line))")
    assert page.locator("#bottom-clock").inner_text() == "5:02"
    assert "running" in page.locator("#top-clock").get_attribute("class")
    page.locator("#engine-toggle").click()
    paused = [page.locator("#top-clock").inner_text(), page.locator("#bottom-clock").inner_text()]
    page.clock.fast_forward(10000)
    assert [page.locator("#top-clock").inner_text(), page.locator("#bottom-clock").inner_text()] == paused
    page.locator("#undo").click()
    assert page.locator("#top-clock").inner_text() == "5:00"
    assert page.locator("#bottom-clock").inner_text() == "5:00"
    page.locator("#flip").click()
    assert page.locator("#top-clock").get_attribute("data-side") == "w"
    page.locator("#flip").click()

    page.locator("#time-control").select_option("60+0")
    page.clock.fast_forward(61000)
    page.wait_for_function("document.querySelector('#game-status').textContent === 'Black wins on time'")
    assert page.locator("#game-status").inner_text() == "Black wins on time"
    page.locator('[data-square="e2"]').click()
    page.locator('[data-square="e4"]').click()
    assert page.locator(".move-entry").count() == 0
    page.locator("#position-panel summary").click()
    with page.expect_download() as download:
        page.locator("#download-pgn").click()
    pgn = Path(download.value.path()).read_text()
    assert '[TimeControl "60+0"]' in pgn
    assert '[Result "0-1"]' in pgn

    # Zero increment is accepted by the real engine and receives a clock budget.
    page.locator("#side-black").click()
    page.wait_for_function("engineCommands.some(line => /^go wtime \\d+ btime \\d+ winc 0 binc 0$/.test(line))")
    page.wait_for_function("Number(document.querySelector('#depth').textContent) >= 3")
    page.clock.fast_forward(61000)
    page.wait_for_function("document.querySelector('#game-status').textContent === 'Black wins on time'")
    assert page.locator("#game-status").inner_text() == "Black wins on time"
    page.locator("#side-white").click()
    page.locator("#time-control").select_option("custom")
    page.locator("#base-minutes").fill("0.5")
    page.locator("#increment-seconds").fill("1")
    page.locator("#apply-time").click()
    assert page.locator("#bottom-clock").inner_text() == "0:30"
    page.locator("#time-control").select_option("untimed")
    assert page.locator("#bottom-clock").is_hidden()
    assert page.locator("#think-time").is_visible()
    errors = page.evaluate("engineLines.filter(line => /Browser engine error:|info string error:|Unable to apply|unsupported/.test(line))")
    assert not errors, errors
    print(f"Controls passed: hash resizing/clearing, {max_threads} selectable threads, Fischer clocks, UCI budgets, pause, undo, flag fall, PGN time controls, and custom games")


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
                url = f"http://127.0.0.1:{server.server_port}"
                exercise_site(page, url)
                exercise_controls(page, url)
                # The time-control checks install a virtual clock; use a fresh
                # page so the console's pthread checks run with normal timers.
                page.close()
                page = browser.new_page()
                page.on("pageerror", lambda error: errors.append(str(error)))
                page.goto(f"{url}/console.html")
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
                    go_count = page.evaluate('document.querySelector("#output").textContent.split("> go infinite").length')
                    page.locator("#analyze").click()
                    page.wait_for_function('count => document.querySelector("#output").textContent.split("> go infinite").length > count', arg=go_count, timeout=15000)
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
