# Package

# TODO: Can we do some nimscript stuff to generate this automagically?
version       = "1.3.2"
author        = "nocturn9x"
description   = "A UCI chess engine written in nim"
license       = "Apache-2.0"
srcDir        = "src"
binDir        = "bin"
installExt    = @["nim"]
bin           = @["heimdall"]


# Dependencies

requires "nim >= 2.2.0"
requires "jsony == 1.1.5"
requires "nint128 == 0.3.3"
requires "struct == 0.2.3"
requires "https://github.com/demotomohiro/pathX == 0.1"
requires "struct == 0.2.3"
requires "nimsimd == 1.2.13"

task test, "Runs the test suite":
  exec "heimdall testonly"
  exec "python tests/suite.py -d 6 -b -p -s -f tests/all.txt"
  exec "python tests/suite.py -d 7 -b -p -s -f tests/standard_heavy.txt"

