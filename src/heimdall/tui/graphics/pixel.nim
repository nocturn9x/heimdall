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

## Pixel buffer and pre-rendered chess piece/board assets
##
## Piece images: Sashite Chess Assets (CC0 1.0 Universal)
## https://sashite.dev/assets/chess/

import std/math

import heimdall/pieces


type
    Color* = object
        r*, g*, b*, a*: uint8

    PixelBuffer* = object
        width*, height*: int
        data*: seq[uint8]  # RGBA interleaved


const
    CELL_PX* = 120  # pixels per board square
    BOARD_PX* = CELL_PX * 8  # 960

    # Highlight overlay colors (applied to square backgrounds)
    SELECTED_TINT*   = Color(r: 80, g: 200, b: 80, a: 130)
    HIGHLIGHTED_SQUARE_TINT* = Color(r: 70, g: 230, b: 255, a: 150)
    LAST_MOVE_TINT*  = Color(r: 200, g: 210, b: 80, a: 100)
    PREMOVE_TINT*    = Color(r: 80, g: 170, b: 240, a: 110)
    LEGAL_DEST_TINT* = Color(r: 50, g: 50, b: 50, a: 120)
    CHECK_TINT*      = Color(r: 240, g: 60, b: 60, a: 140)
    USER_ARROW_GREEN_TINT* = Color(r: 116, g: 255, b: 146, a: 168)
    USER_ARROW_RED_TINT* = Color(r: 255, g: 118, b: 118, a: 168)
    USER_ARROW_BLUE_TINT* = Color(r: 116, g: 188, b: 255, a: 168)
    USER_ARROW_YELLOW_TINT* = Color(r: 255, g: 214, b: 84, a: 168)
    THREAT_ARROW_TINT* = Color(r: 188, g: 48, b: 48, a: 188)
    ENGINE_ARROW_TINT* = Color(r: 110, g: 255, b: 140, a: 132)
    ENGINE_ARROW_SECONDARY_TINTS* = [
        Color(r: 156, g: 255, b: 178, a: 92),
        Color(r: 188, g: 255, b: 204, a: 72),
        Color(r: 214, g: 255, b: 224, a: 58)
    ]
    PREMOVE_TINTS* = [
        Color(r: 80, g: 170, b: 240, a: 110),
        Color(r: 80, g: 200, b: 80, a: 110),
        Color(r: 235, g: 90, b: 90, a: 110),
        Color(r: 245, g: 165, b: 70, a: 110),
        Color(r: 180, g: 110, b: 235, a: 110),
        Color(r: 80, g: 200, b: 185, a: 110)
    ]

    # Embedded raw RGBA data (loaded at compile time)
    BOARD_WHITE_DATA = staticRead("../../resources/pieces/rgba/board_white.rgba")
    BOARD_BLACK_DATA = staticRead("../../resources/pieces/rgba/board_black.rgba")

    W_KING_DATA   = staticRead("../../resources/pieces/rgba/w_king.rgba")
    W_QUEEN_DATA  = staticRead("../../resources/pieces/rgba/w_queen.rgba")
    W_ROOK_DATA   = staticRead("../../resources/pieces/rgba/w_rook.rgba")
    W_BISHOP_DATA = staticRead("../../resources/pieces/rgba/w_bishop.rgba")
    W_KNIGHT_DATA = staticRead("../../resources/pieces/rgba/w_knight.rgba")
    W_PAWN_DATA   = staticRead("../../resources/pieces/rgba/w_pawn.rgba")

    B_KING_DATA   = staticRead("../../resources/pieces/rgba/b_king.rgba")
    B_QUEEN_DATA  = staticRead("../../resources/pieces/rgba/b_queen.rgba")
    B_ROOK_DATA   = staticRead("../../resources/pieces/rgba/b_rook.rgba")
    B_BISHOP_DATA = staticRead("../../resources/pieces/rgba/b_bishop.rgba")
    B_KNIGHT_DATA = staticRead("../../resources/pieces/rgba/b_knight.rgba")
    B_PAWN_DATA   = staticRead("../../resources/pieces/rgba/b_pawn.rgba")


proc newPixelBuffer*(w, h: int): PixelBuffer =
    result.width = w
    result.height = h
    result.data = newSeq[uint8](w * h * 4)


proc fromRawRGBA*(data: string, w, h: int): PixelBuffer =
    ## Creates a pixel buffer from raw RGBA string data
    result.width = w
    result.height = h
    result.data = newSeq[uint8](data.len)
    copyMem(addr result.data[0], unsafeAddr data[0], data.len)


proc setPixel*(buf: var PixelBuffer, x, y: int, c: Color) {.inline.} =
    if x >= 0 and x < buf.width and y >= 0 and y < buf.height:
        let i = (y * buf.width + x) * 4
        buf.data[i]     = c.r
        buf.data[i + 1] = c.g
        buf.data[i + 2] = c.b
        buf.data[i + 3] = c.a


proc getPixel*(buf: PixelBuffer, x, y: int): Color {.inline.} =
    if x >= 0 and x < buf.width and y >= 0 and y < buf.height:
        let i = (y * buf.width + x) * 4
        result = Color(r: buf.data[i], g: buf.data[i+1], b: buf.data[i+2], a: buf.data[i+3])


proc blendPixel*(buf: var PixelBuffer, x, y: int, c: Color) {.inline.} =
    if x < 0 or x >= buf.width or y < 0 or y >= buf.height:
        return

    let i = (y * buf.width + x) * 4
    let sa = c.a.uint16
    if sa == 0:
        return

    let da = buf.data[i + 3].uint16
    let outA = sa + da * (255 - sa) div 255
    if outA == 0:
        return

    buf.data[i] = uint8((c.r.uint16 * sa + buf.data[i].uint16 * da * (255 - sa) div 255) div outA)
    buf.data[i + 1] = uint8((c.g.uint16 * sa + buf.data[i + 1].uint16 * da * (255 - sa) div 255) div outA)
    buf.data[i + 2] = uint8((c.b.uint16 * sa + buf.data[i + 2].uint16 * da * (255 - sa) div 255) div outA)
    buf.data[i + 3] = uint8(outA)


proc premoveTint*(index: int): Color {.inline.} =
    PREMOVE_TINTS[index mod PREMOVE_TINTS.len]


proc blendOver*(dst: var PixelBuffer, src: PixelBuffer, ox, oy: int) =
    ## Alpha-composites src onto dst at offset (ox, oy)
    for sy in 0..<src.height:
        let dy = oy + sy
        if dy < 0 or dy >= dst.height: continue
        for sx in 0..<src.width:
            let dx = ox + sx
            if dx < 0 or dx >= dst.width: continue

            let si = (sy * src.width + sx) * 4
            let sa = src.data[si + 3].uint16
            if sa == 0: continue

            let di = (dy * dst.width + dx) * 4
            if sa == 255:
                dst.data[di]     = src.data[si]
                dst.data[di + 1] = src.data[si + 1]
                dst.data[di + 2] = src.data[si + 2]
                dst.data[di + 3] = 255
            else:
                let da = dst.data[di + 3].uint16
                let outA = sa + da * (255 - sa) div 255
                if outA == 0: continue
                dst.data[di]     = uint8((src.data[si].uint16 * sa + dst.data[di].uint16 * da * (255 - sa) div 255) div outA)
                dst.data[di + 1] = uint8((src.data[si+1].uint16 * sa + dst.data[di+1].uint16 * da * (255 - sa) div 255) div outA)
                dst.data[di + 2] = uint8((src.data[si+2].uint16 * sa + dst.data[di+2].uint16 * da * (255 - sa) div 255) div outA)
                dst.data[di + 3] = uint8(outA)


proc blendOverScaled*(dst: var PixelBuffer, src: PixelBuffer, ox, oy, dw, dh: int) =
    ## Alpha-composites src onto dst at offset (ox, oy), scaled to dw×dh
    if src.width == 0 or src.height == 0: return
    for dy in 0..<dh:
        let ty = oy + dy
        if ty < 0 or ty >= dst.height: continue
        let sy = (dy * src.height) div dh
        for dx in 0..<dw:
            let tx = ox + dx
            if tx < 0 or tx >= dst.width: continue
            let sx = (dx * src.width) div dw

            let si = (sy * src.width + sx) * 4
            let sa = src.data[si + 3].uint16
            if sa == 0: continue

            let di = (ty * dst.width + tx) * 4
            if sa == 255:
                dst.data[di]     = src.data[si]
                dst.data[di + 1] = src.data[si + 1]
                dst.data[di + 2] = src.data[si + 2]
                dst.data[di + 3] = 255
            else:
                let da = dst.data[di + 3].uint16
                let outA = sa + da * (255 - sa) div 255
                if outA == 0: continue
                dst.data[di]     = uint8((src.data[si].uint16 * sa + dst.data[di].uint16 * da * (255 - sa) div 255) div outA)
                dst.data[di + 1] = uint8((src.data[si+1].uint16 * sa + dst.data[di+1].uint16 * da * (255 - sa) div 255) div outA)
                dst.data[di + 2] = uint8((src.data[si+2].uint16 * sa + dst.data[di+2].uint16 * da * (255 - sa) div 255) div outA)
                dst.data[di + 3] = uint8(outA)


proc tintRect*(buf: var PixelBuffer, x1, y1, x2, y2: int, tint: Color) =
    ## Applies a semi-transparent color tint over a rectangular region
    for y in max(0, y1)..min(buf.height - 1, y2):
        for x in max(0, x1)..min(buf.width - 1, x2):
            let i = (y * buf.width + x) * 4
            let sa = tint.a.uint16
            let da = 255'u16 - sa
            buf.data[i]     = uint8((buf.data[i].uint16 * da + tint.r.uint16 * sa) div 255)
            buf.data[i + 1] = uint8((buf.data[i+1].uint16 * da + tint.g.uint16 * sa) div 255)
            buf.data[i + 2] = uint8((buf.data[i+2].uint16 * da + tint.b.uint16 * sa) div 255)


proc fillCircle*(buf: var PixelBuffer, cx, cy, r: int, c: Color) =
    let r2 = r * r
    for y in max(0, cy - r)..min(buf.height - 1, cy + r):
        for x in max(0, cx - r)..min(buf.width - 1, cx + r):
            if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r2:
                buf.setPixel(x, y, c)


proc fillTriangle*(buf: var PixelBuffer,
                   ax, ay, bx, by, cx, cy: float,
                   c: Color) =
    let minX = max(0, int(floor(min(ax, min(bx, cx)))))
    let maxX = min(buf.width - 1, int(ceil(max(ax, max(bx, cx)))))
    let minY = max(0, int(floor(min(ay, min(by, cy)))))
    let maxY = min(buf.height - 1, int(ceil(max(ay, max(by, cy)))))

    proc edge(px, py, qx, qy, rx, ry: float): float {.inline.} =
        (rx - px) * (qy - py) - (ry - py) * (qx - px)

    let area = edge(ax, ay, bx, by, cx, cy)
    if abs(area) < 0.001:
        return

    for y in minY..maxY:
        let py = y.float + 0.5
        for x in minX..maxX:
            let px = x.float + 0.5
            let w0 = edge(ax, ay, bx, by, px, py)
            let w1 = edge(bx, by, cx, cy, px, py)
            let w2 = edge(cx, cy, ax, ay, px, py)
            if area > 0:
                if w0 >= 0 and w1 >= 0 and w2 >= 0:
                    buf.setPixel(x, y, c)
            else:
                if w0 <= 0 and w1 <= 0 and w2 <= 0:
                    buf.setPixel(x, y, c)


proc drawArrowOverlay*(buf: var PixelBuffer,
                       startX, startY, targetX, targetY: int,
                       c: Color,
                       shaftThickness, headLength, headWidth: int) =
    let dx = (targetX - startX).float
    let dy = (targetY - startY).float
    let lineLength = sqrt(dx * dx + dy * dy)
    if lineLength < 1.0:
        return

    let ux = dx / lineLength
    let uy = dy / lineLength
    let perpX = -uy
    let perpY = ux
    let headLen = min(headLength.float, lineLength * 0.45)
    let shaftEndX = targetX.float - ux * headLen * 0.7
    let shaftEndY = targetY.float - uy * headLen * 0.7
    let baseX = targetX.float - ux * headLen
    let baseY = targetY.float - uy * headLen
    let radius = max(1, shaftThickness div 2)
    let steps = max(1, int(ceil(max(abs(shaftEndX - startX.float), abs(shaftEndY - startY.float)))))
    var overlay = newPixelBuffer(buf.width, buf.height)

    for i in 0..steps:
        let t = i.float / steps.float
        let x = int(round(startX.float + (shaftEndX - startX.float) * t))
        let y = int(round(startY.float + (shaftEndY - startY.float) * t))
        overlay.fillCircle(x, y, radius, c)

    let wing = headWidth.float / 2.0
    let leftX = baseX + perpX * wing
    let leftY = baseY + perpY * wing
    let rightX = baseX - perpX * wing
    let rightY = baseY - perpY * wing
    overlay.fillTriangle(targetX.float, targetY.float, leftX, leftY, rightX, rightY, c)
    overlay.fillCircle(startX, startY, radius + 1, c)
    overlay.fillCircle(int(round(baseX)), int(round(baseY)), radius + 1, c)
    buf.blendOver(overlay, 0, 0)


# --- Asset access ---

proc getBoardImage*(flipped: bool): PixelBuffer =
    if flipped:
        fromRawRGBA(BOARD_BLACK_DATA, BOARD_PX, BOARD_PX)
    else:
        fromRawRGBA(BOARD_WHITE_DATA, BOARD_PX, BOARD_PX)


proc getPieceImage*(piece: Piece): PixelBuffer =
    let data = case piece.color:
        of White:
            case piece.kind:
                of King:   W_KING_DATA
                of Queen:  W_QUEEN_DATA
                of Rook:   W_ROOK_DATA
                of Bishop: W_BISHOP_DATA
                of Knight: W_KNIGHT_DATA
                of Pawn:   W_PAWN_DATA
                of Empty:  ""
        of Black:
            case piece.kind:
                of King:   B_KING_DATA
                of Queen:  B_QUEEN_DATA
                of Rook:   B_ROOK_DATA
                of Bishop: B_BISHOP_DATA
                of Knight: B_KNIGHT_DATA
                of Pawn:   B_PAWN_DATA
                of Empty:  ""
        of None: ""

    if data.len > 0:
        fromRawRGBA(data, CELL_PX, CELL_PX)
    else:
        newPixelBuffer(0, 0)
