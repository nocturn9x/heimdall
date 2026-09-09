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

# Package

# TODO: Can we do some nimscript stuff to generate this automagically?
version       = "1.5.0"
author        = "nocturn9x"
description   = "A UCI chess engine written in nim"
license       = "Apache-2.0"
srcDir        = "src"
binDir        = "bin"
installExt    = @["nim"]
bin           = @["heimdall"]


# Dependencies

requires "nim >= 2.2.2"
requires "jsony == 1.1.5"
requires "nint128 == 0.3.3"
requires "struct == 0.2.3"
requires "https://github.com/demotomohiro/pathX == 0.1"
requires "struct == 0.2.3"
requires "nimsimd == 1.2.13"

requires "noise >= 0.1.10"
requires "illwill >= 0.4.1"
