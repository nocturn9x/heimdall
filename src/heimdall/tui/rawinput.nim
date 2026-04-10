# Copyright 2025 Mattia Giambirtone & All Contributors
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

## Raw terminal input reader with SGR mouse support.
## Bypasses illwill's getKey() for input to properly handle
## mouse escape sequences that illwill can't parse.

import std/[strutils, os]
from std/posix import STDIN_FILENO, STDOUT_FILENO, read
from std/termios import Termios, tcGetAttr, tcSetAttr, TCSANOW, ISIG, Cflag,
    IOctl_WinSize, TIOCGWINSZ, ioctl
import illwill


type
    TerminalKind* = enum
        tkKitty
        tkGhostty
        tkWezTerm
        tkKonsole
        tkUnknown

    InputEventKind* = enum
        ievNone
        ievKey
        ievMouse

    MouseAction* = enum
        maPress
        maRelease
        maMove

    MouseButton* = enum
        mbLeft
        mbMiddle
        mbRight
        mbNone

    MouseEvent* = object
        x*, y*: int
        button*: MouseButton
        action*: MouseAction
        shift*: bool
        alt*: bool
        ctrl*: bool

    InputEvent* = object
        case kind*: InputEventKind:
            of ievNone:
                discard
            of ievKey:
                key*: Key
            of ievMouse:
                mouse*: MouseEvent


const
    SGR_MOUSE_ENABLE_BASE = "\x1b[?1002h\x1b[?1006h"
    SGR_MOUSE_DISABLE_BASE = "\x1b[?1002l\x1b[?1006l"
    PIXEL_MOUSE_ENABLE = "\x1b[?1016h"
    PIXEL_MOUSE_DISABLE = "\x1b[?1016l"


var
    lastMouseButton {.threadvar.}: MouseButton


proc detectTerminalKind*: TerminalKind =
    let term = getEnv("TERM", "").toLowerAscii()
    let termProgram = getEnv("TERM_PROGRAM", "").toLowerAscii()

    if existsEnv("KITTY_WINDOW_ID") or term.contains("kitty"):
        return tkKitty
    if existsEnv("WEZTERM_PANE") or termProgram == "wezterm" or term == "wezterm":
        return tkWezTerm
    if term.contains("ghostty") or termProgram == "ghostty":
        return tkGhostty
    if existsEnv("KONSOLE_VERSION") or termProgram == "konsole":
        return tkKonsole
    return tkUnknown


proc terminalKindName*(kind: TerminalKind): string =
    case kind:
        of tkKitty:
            "Kitty"
        of tkGhostty:
            "Ghostty"
        of tkWezTerm:
            "WezTerm"
        of tkKonsole:
            "Konsole"
        of tkUnknown:
            let termProgram = getEnv("TERM_PROGRAM", "")
            let term = getEnv("TERM", "")
            if termProgram.len > 0 and term.len > 0:
                termProgram & " (" & term & ")"
            elif termProgram.len > 0:
                termProgram
            elif term.len > 0:
                term
            else:
                "unknown terminal"


proc supportsPixelMouse(kind: TerminalKind): bool =
    ## We enable 1016 for terminals we explicitly target. Konsole is kept on
    ## cell-based mouse coordinates because its kitty image support does not
    ## imply pixel mouse support.
    return kind in {tkKitty, tkGhostty, tkWezTerm}


proc terminalCompatibilityWarning*: string =
    let kind = detectTerminalKind()
    if kind == tkUnknown:
        return "Warning: terminal '" & terminalKindName(kind) &
            "' is untested; supported terminals are Kitty, WezTerm, Ghostty, and Konsole. The TUI may render or handle mouse input incorrectly."
    ""


proc mouseEnableSequence: string =
    let kind = detectTerminalKind()
    result = SGR_MOUSE_ENABLE_BASE
    if supportsPixelMouse(kind):
        result &= PIXEL_MOUSE_ENABLE


proc mouseDisableSequence: string =
    let kind = detectTerminalKind()
    result = SGR_MOUSE_DISABLE_BASE
    if supportsPixelMouse(kind):
        result &= PIXEL_MOUSE_DISABLE


proc getCellPixelSize: tuple[w, h: int] =
    ## Queries the terminal's pixel size per character cell.
    var ws: IOctl_WinSize
    if ioctl(STDOUT_FILENO.cint, TIOCGWINSZ, addr ws) == 0 and ws.ws_col > 0 and ws.ws_row > 0 and
       ws.ws_xpixel > 0 and ws.ws_ypixel > 0:
        result.w = max(1, ws.ws_xpixel.int div ws.ws_col.int)
        result.h = max(1, ws.ws_ypixel.int div ws.ws_row.int)
    else:
        result.w = 9
        result.h = 18


proc normalizeCellMouseCoords(cellX, cellY: int): tuple[x, y: int] =
    ## Converts 0-based terminal cell coordinates to approximate pixel coords
    ## by using the center point of the cell.
    let cell = getCellPixelSize()
    result.x = cellX * cell.w + cell.w div 2
    result.y = cellY * cell.h + cell.h div 2


proc decodeMouseEvent(btnBits, rawX, rawY: int, pressed, pixelCoords: bool): InputEvent =
    let isMove = (btnBits and 32) != 0
    let shift = (btnBits and 4) != 0
    let alt = (btnBits and 8) != 0
    let ctrl = (btnBits and 16) != 0
    var button = case (btnBits and 3):
        of 0:
            mbLeft
        of 1:
            mbMiddle
        of 2:
            mbRight
        else:
            mbNone

    let action = if isMove: maMove
                 elif pressed: maPress
                 else: maRelease

    if action == maRelease and button == mbNone:
        button = lastMouseButton
    elif action == maMove and button == mbNone:
        button = lastMouseButton

    if action == maPress and button != mbNone:
        lastMouseButton = button
    elif action == maRelease:
        lastMouseButton = mbNone

    let coords = if pixelCoords: (x: rawX, y: rawY)
                 else: normalizeCellMouseCoords(rawX, rawY)

    InputEvent(kind: ievMouse, mouse: MouseEvent(
        x: coords.x, y: coords.y, button: button, action: action,
        shift: shift, alt: alt, ctrl: ctrl
    ))


proc disableISIG* =
    ## Disables ISIG so Ctrl+C/Ctrl+Z are delivered as bytes
    ## instead of generating signals. Call after illwillInit.
    var ttyState: Termios
    discard tcGetAttr(STDIN_FILENO.cint, addr ttyState)
    ttyState.c_lflag = ttyState.c_lflag and not ISIG
    discard tcSetAttr(STDIN_FILENO.cint, TCSANOW, addr ttyState)


proc enableMouseTracking* =
    stdout.write(mouseEnableSequence())
    stdout.flushFile()


proc disableMouseTracking* =
    stdout.write(mouseDisableSequence())
    stdout.flushFile()


proc readByte: int =
    ## Reads one byte from stdin non-blocking.
    ## Returns -1 if nothing available (VMIN=0 set by illwill).
    var c: char
    let n = read(STDIN_FILENO, addr c, 1)
    if n <= 0: return -1
    return c.int


const
    ESC_SEQUENCE_POLL_MS = 25


proc readByteWait(timeoutMs = ESC_SEQUENCE_POLL_MS): int =
    ## Reads one byte from stdin, spinning briefly for escape sequence continuations.
    ## Escape sequence bytes can arrive a few milliseconds apart, especially for
    ## longer mouse packets, so wait a little instead of timing out immediately.
    var c: char
    for attempt in 0..<max(1, timeoutMs):
        let n = read(STDIN_FILENO, addr c, 1)
        if n > 0: return c.int
        sleep(1)
    return -1


proc discardCSISequence =
    ## Consumes the rest of an unknown CSI sequence up to its final byte.
    while true:
        let b = readByteWait()
        if b < 0:
            return
        let c = chr(b)
        if c in {'@'..'~'}:
            return


proc flushMouseNumber(parts: var seq[int], numBuf: var string): bool =
    if numBuf.len == 0 or numBuf == "-":
        return false
    try:
        parts.add(parseInt(numBuf))
        numBuf = ""
        return true
    except ValueError:
        return false


proc tryParseSGRMouse: InputEvent =
    ## Parses an SGR mouse sequence after \e[< has been consumed.
    ## Format: btn;x;yM (press) or btn;x;ym (release).
    ## With pixel mouse mode enabled in our targeted terminals, x/y are
    ## terminal pixel coordinates; otherwise they are terminal cells.
    var numBuf = ""
    var parts: seq[int]

    while true:
        let b = readByteWait()
        if b < 0:
            discardCSISequence()
            return InputEvent(kind: ievNone)
        let c = chr(b)
        if c.isDigit():
            numBuf &= c
        elif c == '-' and numBuf.len == 0:
            numBuf = "-"
        elif c == ';':
            if not flushMouseNumber(parts, numBuf):
                discardCSISequence()
                return InputEvent(kind: ievNone)
        elif c in {'M', 'm'}:
            if not flushMouseNumber(parts, numBuf):
                discardCSISequence()
                return InputEvent(kind: ievNone)
            if parts.len >= 3:
                let btnBits = parts[0]
                let x = parts[1] - 1  # 1-based to 0-based
                let y = parts[2] - 1
                let pressed = c == 'M'
                return decodeMouseEvent(btnBits, x, y, pressed, pixelCoords=supportsPixelMouse(detectTerminalKind()))
            return InputEvent(kind: ievNone)
        else:
            # Unknown char in sequence, discard the rest of the packet so it
            # cannot leak into normal text input.
            discardCSISequence()
            return InputEvent(kind: ievNone)


proc tryParseLegacyMouse: InputEvent =
    ## Parses the legacy X10 mouse packet after \e[M.
    ## This is used as a fallback by terminals that ignore 1006/1016.
    let btnByte = readByteWait()
    let xByte = readByteWait()
    let yByte = readByteWait()
    if btnByte < 0 or xByte < 0 or yByte < 0:
        return InputEvent(kind: ievNone)

    let btnBits = btnByte - 32
    let x = xByte - 33  # encoded as 1-based coordinate + 32
    let y = yByte - 33
    if btnBits < 0 or x < 0 or y < 0:
        return InputEvent(kind: ievNone)

    let pressed = (btnBits and 3) != 3
    decodeMouseEvent(btnBits, x, y, pressed, pixelCoords=false)


proc tryParseCSI: InputEvent =
    ## Parses a CSI (\e[) sequence
    let b = readByteWait()
    if b < 0:
        return InputEvent(kind: ievKey, key: Key.Escape)

    let c = chr(b)
    case c:
        of '<':
            return tryParseSGRMouse()
        of 'M':
            return tryParseLegacyMouse()
        of 'A':
            return InputEvent(kind: ievKey, key: Key.Up)
        of 'B':
            return InputEvent(kind: ievKey, key: Key.Down)
        of 'C':
            return InputEvent(kind: ievKey, key: Key.Right)
        of 'D':
            return InputEvent(kind: ievKey, key: Key.Left)
        of 'H':
            return InputEvent(kind: ievKey, key: Key.Home)
        of 'F':
            return InputEvent(kind: ievKey, key: Key.End)
        of '1':
            let b2 = readByteWait()
            if b2 < 0: return InputEvent(kind: ievNone)
            if chr(b2) == '~':
                return InputEvent(kind: ievKey, key: Key.Home)
            # Consume rest of unknown sequence
            if chr(b2) in {'0'..'9'}:
                discard readByteWait()  # consume trailing ~
            return InputEvent(kind: ievNone)
        of '3':
            discard readByteWait()  # consume ~
            return InputEvent(kind: ievKey, key: Key.Delete)
        of '4':
            discard readByteWait()
            return InputEvent(kind: ievKey, key: Key.End)
        of '5':
            discard readByteWait()
            return InputEvent(kind: ievKey, key: Key.PageUp)
        of '6':
            discard readByteWait()
            return InputEvent(kind: ievKey, key: Key.PageDown)
        else:
            discardCSISequence()
            return InputEvent(kind: ievNone)


proc pollInput*: InputEvent =
    ## Non-blocking input poll. Returns keyboard or mouse events.
    let b = readByte()
    if b < 0:
        return InputEvent(kind: ievNone)

    case b:
        of 0x1b:  # ESC
            let b2 = readByteWait()
            if b2 < 0:
                return InputEvent(kind: ievKey, key: Key.Escape)
            case chr(b2):
                of '[':
                    return tryParseCSI()
                of 'O':
                    # SS3 sequences (some terminals use for arrow keys)
                    let b3 = readByteWait()
                    if b3 < 0: return InputEvent(kind: ievKey, key: Key.Escape)
                    case chr(b3):
                        of 'A':
                            return InputEvent(kind: ievKey, key: Key.Up)
                        of 'B':
                            return InputEvent(kind: ievKey, key: Key.Down)
                        of 'C':
                            return InputEvent(kind: ievKey, key: Key.Right)
                        of 'D':
                            return InputEvent(kind: ievKey, key: Key.Left)
                        of 'H':
                            return InputEvent(kind: ievKey, key: Key.Home)
                        of 'F':
                            return InputEvent(kind: ievKey, key: Key.End)
                        else:
                            return InputEvent(kind: ievNone)
                else:
                    return InputEvent(kind: ievKey, key: Key.Escape)
        of 0x0d, 0x0a:
            return InputEvent(kind: ievKey, key: Key.Enter)
        of 0x7f:
            return InputEvent(kind: ievKey, key: Key.Backspace)
        of 0x09:
            return InputEvent(kind: ievKey, key: Key.Tab)
        of 0x01..0x08, 0x0b, 0x0c, 0x0e..0x1a:
            # Ctrl+A through Ctrl+Z (excluding Tab=0x09, Enter=0x0d)
            {.push warning[HoleEnumConv]:off.}
            return InputEvent(kind: ievKey, key: Key(b))
            {.pop.}
        else:
            # Regular printable character or other
            if b >= 32 and b <= 126:
                {.push warning[HoleEnumConv]:off.}
                return InputEvent(kind: ievKey, key: Key(b))
                {.pop.}
            return InputEvent(kind: ievNone)
