# Copyright 2024 Mattia Giambirtone & All Contributors
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

import heimdallpkg/tui
import heimdallpkg/movegen
import heimdallpkg/bitboards
import heimdallpkg/moves
import heimdallpkg/pieces
import heimdallpkg/magics
import heimdallpkg/rays
import heimdallpkg/position
import heimdallpkg/board


export tui, movegen, bitboards, moves, pieces, magics, rays, position, board


when isMainModule:
    setControlCHook(proc () {.noconv.} = quit(0))
    basicTests()
    quit(commandLoop())
