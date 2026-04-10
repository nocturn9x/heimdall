# Copyright 2026 Mattia Giambirtone & All Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

## Chess clock with increment support.

import std/[monotimes, times, strformat, strutils]

import heimdall/tui/state


proc newClock*(timeMs: int64, incrementMs: int64 = 0): ChessClock =
    result.remainingMs = timeMs
    result.incrementMs = incrementMs
    result.running = false
    result.expired = false


proc tick*(clock: var ChessClock) =
    ## Called each frame to update the running clock
    if not clock.running or clock.expired:
        return
    let now = getMonoTime()
    let elapsed = (now - clock.lastTick).inMilliseconds()
    clock.remainingMs -= elapsed
    clock.lastTick = now
    if clock.remainingMs <= 0:
        clock.remainingMs = 0
        clock.expired = true


proc start*(clock: var ChessClock) =
    clock.lastTick = getMonoTime()
    clock.running = true


proc stop*(clock: var ChessClock) =
    if clock.running:
        clock.tick()  # account for final elapsed time
        clock.running = false


proc press*(clock: var ChessClock) =
    ## Called when a move is made: stops the clock and adds increment
    clock.stop()
    clock.remainingMs += clock.incrementMs


proc finishMove*(clock: var ChessClock, moveStartRemainingMs: int64): int64 =
    ## Stops the clock, returns the time spent on the move, and applies increment.
    clock.stop()
    result = max(0'i64, moveStartRemainingMs - clock.remainingMs)
    clock.remainingMs += clock.incrementMs


proc formatTime*(clock: ChessClock): string =
    if clock.remainingMs <= 0:
        return "0:00.0"
    let totalMs = clock.remainingMs
    let totalSec = totalMs div 1000
    let minutes = totalSec div 60
    let seconds = totalSec mod 60
    let tenths = (totalMs mod 1000) div 100
    if totalSec < 10:
        return &"{seconds}.{tenths}"
    return &"{minutes}:{seconds:02d}"


proc parseDuration(s: string): int64 =
    ## Parses a duration string like "5m", "1h30m", "90s", "5m3s".
    ## Returns total milliseconds. Raises ValueError on bad input.
    var totalMs: int64 = 0
    var numBuf = ""
    let s = s.strip().toLowerAscii()

    for c in s:
        if c.isDigit() or c == '.':
            numBuf &= c
        elif c == 'h':
            if numBuf.len == 0: raise newException(ValueError, "missing number before 'h'")
            totalMs += (parseFloat(numBuf) * 3600_000).int64
            numBuf = ""
        elif c == 'm':
            if numBuf.len == 0: raise newException(ValueError, "missing number before 'm'")
            totalMs += (parseFloat(numBuf) * 60_000).int64
            numBuf = ""
        elif c == 's':
            if numBuf.len == 0: raise newException(ValueError, "missing number before 's'")
            totalMs += (parseFloat(numBuf) * 1000).int64
            numBuf = ""
        elif c notin {' ', '\t'}:
            raise newException(ValueError, &"unexpected character '{c}'")

    # If there's a leftover number with no unit, treat as seconds
    if numBuf.len > 0:
        totalMs += (parseFloat(numBuf) * 1000).int64

    if totalMs <= 0:
        raise newException(ValueError, "time must be positive")
    return totalMs


proc parseTimeControl*(s: string): tuple[timeMs: int64, incMs: int64, ok: bool] =
    ## Parses a time control string. Format: "<duration>+<increment>"
    ## Duration: "5m", "5m3s", "1h", "90s", "300" (bare number = seconds)
    ## Increment: "3s", "5", bare number = seconds
    ## Special: "none", "inf", "infinite"
    let s = s.strip()
    if s.toLowerAscii() in ["none", "inf", "infinite"]:
        return (0'i64, 0'i64, true)

    let parts = s.split("+")
    if parts.len notin 1..2:
        return (0'i64, 0'i64, false)

    try:
        let timeMs = parseDuration(parts[0])
        var incMs: int64 = 0
        if parts.len == 2:
            incMs = parseDuration(parts[1])
        return (timeMs, incMs, true)
    except ValueError:
        return (0'i64, 0'i64, false)
