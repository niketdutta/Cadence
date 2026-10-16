// Draws the Cadence app icon -> AppIcon.icns.  Run: swift make-icon.swift
import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()
func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }

// macOS icon grid: 824pt squircle centered in the 1024 canvas
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// soft drop shadow under the tile
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: col(0, 0, 0, 0.35))
ctx.addPath(squircle); ctx.setFillColor(col(0.1, 0.05, 0.2)); ctx.fillPath()
ctx.restoreGState()

// background: deep indigo -> magenta -> warm orange glow at the bottom
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [col(0.07, 0.05, 0.25), col(0.36, 0.10, 0.52), col(0.93, 0.30, 0.45)] as CFArray, locations: [0, 0.6, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
let glow = CGGradient(colorsSpace: cs, colors: [col(1, 0.62, 0.35, 0.55), col(1, 0.62, 0.35, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 120), startRadius: 0, endCenter: CGPoint(x: 512, y: 120), endRadius: 520, options: [])

// five rounded "cadence" bars: a rising and falling beat
let heights: [CGFloat] = [190, 330, 470, 300, 160]
let w: CGFloat = 78, gap: CGFloat = 40
let total = CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap
var x = (S - total) / 2
for h in heights {
    let r = CGRect(x: x, y: 512 - h / 2, width: w, height: h)
    let p = CGPath(roundedRect: r, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: col(0.1, 0, 0.2, 0.45))
    ctx.addPath(p); ctx.setFillColor(col(1, 1, 1, 0.92)); ctx.fillPath()
    ctx.restoreGState()
    // glassy top-to-bottom sheen
    ctx.saveGState()
    ctx.addPath(p); ctx.clip()
    let sheen = CGGradient(colorsSpace: cs, colors: [col(1, 1, 1, 1), col(1, 0.85, 0.95, 0.75)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: x, y: r.maxY), end: CGPoint(x: x, y: r.minY), options: [])
    ctx.restoreGState()
    x += w + gap
}

// top glass highlight on the tile
let hi = CGGradient(colorsSpace: cs, colors: [col(1, 1, 1, 0.22), col(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(hi, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
ctx.restoreGState()

// thin inner rim
ctx.addPath(squircle); ctx.setStrokeColor(col(1, 1, 1, 0.18)); ctx.setLineWidth(3); ctx.strokePath()
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon-1024.png"))

// iconset -> icns
let set = "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: set)
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        p.arguments = ["-z", "\(px)", "\(px)", "icon-1024.png", "--out", "\(set)/\(name)"]
        p.standardOutput = FileHandle.nullDevice; try! p.run(); p.waitUntilExit()
    }
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set, "-o", "AppIcon.icns"]; try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(atPath: set)
