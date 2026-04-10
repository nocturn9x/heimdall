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

## Kitty graphics protocol for transmitting images to the terminal.

import std/[base64, strformat]

import heimdall/tui/graphics/pixel


# zlib FFI for image compression
{.passl: "-lz".}
proc compressBound(sourceLen: culong): culong {.importc, header: "<zlib.h>".}
proc compress2(dest: pointer, destLen: ptr culong, source: pointer, sourceLen: culong, level: cint): cint {.importc, header: "<zlib.h>".}

proc zlibCompress(data: openArray[uint8]): seq[uint8] =
    let srcLen = data.len.culong
    var destLen = compressBound(srcLen)
    result = newSeq[uint8](destLen)
    let rc = compress2(addr result[0], addr destLen, unsafeAddr data[0], srcLen, 6)
    if rc == 0:
        result.setLen(destLen)
    else:
        result = @[]  # compression failed, caller falls back to uncompressed


const
    ESC = "\x1b"
    APC = ESC & "_G"
    ST  = ESC & "\\"
    CHUNK_SIZE = 4096


proc deleteImage*(id: int) =
    ## Deletes a previously transmitted image by ID
    stdout.write(&"{APC}a=d,d=I,i={id},q=2;{ST}")
    stdout.flushFile()


proc deletePlacement*(imageId, placementId: int) =
    ## Deletes a specific image placement, keeping the image data.
    stdout.write(&"{APC}a=d,d=i,i={imageId},p={placementId},q=2;{ST}")
    stdout.flushFile()


proc transmitPixels(buf: PixelBuffer, id: int, display: bool, row = 1, col = 1) =
    ## Uploads RGBA image data, optionally displaying it immediately.
    if display:
        stdout.write(ESC & "7")
        stdout.write(&"{ESC}[{row};{col}H")

    # Try zlib compression (o=z tells kitty data is zlib-compressed)
    let compressed = zlibCompress(buf.data)
    let useCompression = compressed.len > 0
    let payload = if useCompression: compressed else: buf.data
    let encoded = base64.encode(payload)
    let compFlag = if useCompression: ",o=z" else: ""
    let action = if display: "a=T," else: ""

    # Send in chunks
    var pos = 0
    var first = true

    while pos < encoded.len:
        let remaining = encoded.len - pos
        let chunkLen = min(CHUNK_SIZE, remaining)
        let chunk = encoded[pos..<pos + chunkLen]
        let more = if pos + chunkLen < encoded.len: 1 else: 0

        if first:
            stdout.write(&"{APC}{action}f=32{compFlag},s={buf.width},v={buf.height},i={id},q=2,m={more};{chunk}{ST}")
            first = false
        else:
            stdout.write(&"{APC}m={more};{chunk}{ST}")

        pos += chunkLen

    if display:
        stdout.write(ESC & "8")
    stdout.flushFile()


proc transmitImage*(buf: PixelBuffer, row, col: int, id: int = 1) =
    ## Transmits and displays an RGBA image at the given terminal position.
    transmitPixels(buf, id, display=true, row=row, col=col)


proc uploadImage*(buf: PixelBuffer, id: int) =
    ## Uploads RGBA image data without creating a placement.
    transmitPixels(buf, id, display=false)


proc placeImage*(imageId, placementId, row, col: int, x = 0, y = 0, z = 0) =
    ## Creates or updates an image placement at the given terminal position.
    stdout.write(ESC & "7")
    stdout.write(&"{ESC}[{row};{col}H")
    stdout.write(&"{APC}a=p,i={imageId},p={placementId},X={x},Y={y},z={z},C=1,q=2;{ST}")
    stdout.write(ESC & "8")
    stdout.flushFile()
