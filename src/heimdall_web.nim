# Copyright 2026 Mattia Giambirtone & All Contributors
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

## Browser entry point. JavaScript only enqueues commands; all UCI command
## handling (including blocking waits) stays on a dedicated Nim pthread.
import std/[atomics, strutils]
import heimdall/uci/session

when not defined(emscripten):
    {.fatal: "Build this entry point through make dev TARGET=wasm".}

proc keepAlive() {.importc: "emscripten_exit_with_live_runtime", header: "emscripten/emscripten.h", noreturn.}

var
    commands: Channel[string]
    uciThread: Thread[void]
    lifecycle: Atomic[int]

proc nextCommand(): string {.gcsafe.} = commands.recv()

proc runSession() {.thread.} =
    try:
        startUCISession(nextCommand)
    except CatchableError, Defect:
        let error = getCurrentException()
        stderr.writeLine("info string Browser engine error: " & error.msg)
    finally:
        lifecycle.store(3, moRelease)

proc heimdallReady(): cint {.exportc: "heimdall_ready", cdecl.} =
    ## Returns 1 while accepting commands, 2 while closing, or 3 after exit.
    lifecycle.load(moAcquire).cint

proc heimdallCommand(command: cstring): cint {.exportc: "heimdall_command", cdecl.} =
    ## Enqueues one UCI line without blocking the JavaScript event loop.
    ## Returns 0 on success, 1 when closed, 2 for invalid input, or 3 if full.
    if lifecycle.load(moAcquire) != 1:
        return 1
    if command == nil:
        return 2
    let line = $command
    if line.len > 65536 or '\n' in line or '\r' in line:
        return 2
    if not commands.trySend(line):
        return 3
    if line.strip() == "quit":
        # The UCI thread may finish before this call returns. Do not overwrite
        # its stopped state with closing if it processed quit immediately.
        var accepting = 1
        discard lifecycle.compareExchange(accepting, 2)
    return 0

commands.open(256)
lifecycle.store(1, moRelease)
createThread(uciThread, runSession)
# Returning from NimMainModule would destroy module globals (including the
# move-generation tables) while the UCI and search pthreads still use them.
# Unwind to JavaScript with the runtime and Nim globals intact instead.
keepAlive()
