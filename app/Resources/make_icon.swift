// Generates Resources/AppIcon.icon/Assets/mic.png: the 1.4.0 app icon, a pixel-art microphone on a night sky, drawn on a
// 32×32 grid with the website's palette (yinloo.com, assets/common.js) and its black outline. One full-bleed layer;
// icon.json turns glass and shadows off so the pixels stay crisp. build.sh compiles the .icon with actool.
// Usage: swift make_icon.swift Resources/AppIcon.icon/Assets
import AppKit

func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
}
let palette: [Character: NSColor] = [
    "k": hex(0x0d0818), "w": hex(0xfff3b0), "W": hex(0xe8d48a), "y": hex(0xffd23f), "Y": hex(0xd9a514),
    "h": hex(0xff4d6d), "H": hex(0xc2304f), "v": hex(0xb7a6ff),
    "1": hex(0x2a1f4a), "2": hex(0x241a3b), "3": hex(0x1a1030), "4": hex(0x120a24),   // night sky, top to bottom
]

let N = 32
var g = [[Character]](repeating: [Character](repeating: ".", count: N), count: N)
func put(_ x: Int, _ y: Int, _ c: Character) { if (0..<N).contains(x) && (0..<N).contains(y) { g[y][x] = c } }
func center(_ i: Int) -> CGFloat { CGFloat(i) + 0.5 }

// Head: a 10×16 rounded rectangle (columns 11–20, rows 2–17), straight sides, shaded on the right.
for y in 2...17 { for x in 11...20 {
    let cx = center(x), cy = center(y)
    let tx = min(max(cx, 15), 17), ty = min(max(cy, 6), 14)
    if hypot(cx - tx, cy - ty) <= 4.3 { put(x, y, x == 20 || (x == 19 && (y < 4 || y > 15)) ? "W" : "w") }
}}
// Sound bars in the head: a 2-wide one in the middle, a 1-wide one either side.
for (xs, h) in [([13], 5), ([15, 16], 11), ([18], 3)] as [([Int], Int)] {
    for y in (10 - h / 2)...(10 + h / 2) { for x in xs { put(x, y, x == 16 ? "H" : "h") } }
}
// Holder: the lower half of a ring around the head (centre 16,12), its arms reaching up to row 9.
for y in 9...23 { for x in 3...28 {
    let cx = center(x), cy = center(y)
    let d = cy >= 12 ? hypot(cx - 16, cy - 12) : abs(cx - 16)
    if d >= 9.1 && d <= 10.9 && g[y][x] == "." { put(x, y, cy > 20 ? "Y" : "y") }
}}
// Stem and base.
for y in 23...26 { put(15, y, "y"); put(16, y, "Y") }
for x in 11...20 { put(x, 27, "y"); put(x, 28, "Y") }
// One-cell black outline around everything, like the sprites on the website.
let shapes = g
for y in 0..<N { for x in 0..<N where shapes[y][x] == "." {
    if [(1, 0), (-1, 0), (0, 1), (0, -1)].contains(where: { (dx, dy) in
        let nx = x + dx, ny = y + dy
        return (0..<N).contains(nx) && (0..<N).contains(ny) && shapes[ny][nx] != "."
    }) { g[y][x] = "k" }
}}
// Sky in four bands, and a few stars.
for y in 0..<N { for x in 0..<N where g[y][x] == "." { g[y][x] = ["1", "2", "3", "4"][y / 8] } }
for (x, y, c) in [(5, 5, "y"), (26, 4, "w"), (27, 25, "y"), (4, 22, "w"), (29, 14, "v"), (2, 12, "v")] as [(Int, Int, Character)] where g[y][x] != "k" {
    g[y][x] = c
}
for (dx, dy) in [(0, -1), (-1, 0), (1, 0), (0, 1)] where g[5 + dy][5 + dx] != "k" { g[5 + dy][5 + dx] = "Y" }

let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cell = CGFloat(px) / CGFloat(N)
for (y, row) in g.enumerated() { for (x, ch) in row.enumerated() {
    palette[ch]!.setFill()
    NSRect(x: CGFloat(x) * cell, y: CGFloat(N - 1 - y) * cell, width: cell, height: cell).fill()
}}
NSGraphicsContext.restoreGraphicsState()
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("mic.png"))
