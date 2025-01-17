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


## A basic tool to manage marlinformat datasets and collect
## statistics on them
import std/sequtils
import std/strutils
import std/math
import std/strformat
import std/times
import std/options


import heimdall/datagen/marlinformat
import heimdall/eval
import heimdall/pieces


proc runDataTool*(dataFile: string, filterScores: tuple[min, max: Score], dryRun: bool = false, outputName = "filtered.bin", limit: Option[int]) =
    echo &"Heimdall data tool v1, loading info on {dataFile}"
    var file = open(dataFile, fmRead)
    defer: file.close()

    let 
        size = getFileSize(file)
        expectedPositions = size div RECORD_SIZE

    echo &"File is {size} bytes long, expected number of positions: {expectedPositions}"
    if trunc(size / RECORD_SIZE) != size / RECORD_SIZE:
        echo &"Error: file size ({size}) is not a multiple of the record size ({RECORD_SIZE})!"
        quit(-1)
    
    var outputFile: File
    if not dryRun:
        outputFile = open(outputName, fmAppend)

    echo "Counting positions..."
    let startTime = cpuTime()
    var
        totalPositions = 0
        current = 0
        highestEval = lowestEval()
        lowestEval = highestEval()
        filtered = (above: 0, below: 0)
        wdl = (w: 0, d: 0, l: 0)
    while current < size:
        var data: array[RECORD_SIZE, char]
        let read = file.readChars(toOpenArray(data, 0, data.high()))
        current += read

        if read == 0:
            break
        
        # Ensure record is valid
        let record = data.mapIt($it).join().fromMarlinformat()
        inc(totalPositions)
        if record.eval > highestEval:
            highestEval = record.eval
        if record.eval < lowestEval:
            lowestEval = record.eval
        case record.wdl:
            of White:
                inc(wdl.w)
            of Black:
                inc(wdl.l)
            of None:
                inc(wdl.d)
        if record.eval > filterScores.max:
            filtered.above += 1
        elif record.eval < filterScores.min:
            filtered.below += 1
        elif not dryRun:
            outputFile.write(record.toMarlinformat())

        if limit.isSome() and limit.get() == totalPositions:
            break
    
    if not dryRun:
        outputFile.close()
    let endTime = cpuTime() - startTime

    echo &"Read {totalPositions} out of the expected {expectedPositions} positions in {endTime:.2f} seconds (~{(totalPositions.float / endTime).int} pos/sec)"
    if filtered.below + filtered.above > 0:
        echo &"Filtered a total of {filtered.above + filtered.below} positions to {outputName} ({filtered.above} with score > {filterScores.max}, {filtered.below} with score < {filterScores.min})"
    echo &"Stats:\n    - Highest eval: {highestEval()}\n    - Lowest eval: {lowestEval}" &
         &"\n    - W/D/L (white-relative): {wdl.w}/{wdl.d}/{wdl.l} ({(wdl.w / totalPositions) * 100:.2f}%/{(wdl.d / totalPositions) * 100:.2f}%/{(wdl.l / totalPositions) * 100:.2f}%)"
    quit(0)
