# Package

version       = "0.4.0"
author        = "nocturn9x"
description   = "A UCI chess engine written in nim"
license       = "Apache-2.0"
srcDir        = "heimdall"
binDir        = "bin"
installExt    = @["nim"]
bin           = @["heimdall"]


# Dependencies

requires "nim >= 2.0.4"
requires "jsony >= 1.1.5"
requires "nint128 >= 0.3.3"
requires "struct >= 0.2.3"
requires "https://github.com/demotomohiro/pathX >= 0.1"

task test, "Runs the test suite":
  exec "python tests/suite.py -d 6 -b -p -s"
  exec "python tests/suite.py -d 6 -b -p -s -f tests/chess960.txt"
  exec "python tests/suite.py -d 7 -b -p -s -f tests/heavy.txt"
