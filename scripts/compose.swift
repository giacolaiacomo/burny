// Composes the README images from raw popover snapshots.
// Usage: swift scripts/compose.swift <snapshots dir> <out dir> <claude %> <codex %>
// Expects in <snapshots dir>: icon.png, popover-dark.png, popover-light.png, settings-dark.png, breakdown-dark.png
// Writes hero.png, screens.png and frames/*.png (10 fps) for the README animation.

import AppKit

let args = CommandLine.arguments
let src = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
let barValues = args.count > 4 ? [args[3], args[4]] : ["–", "–"]

func rgb(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

func load(_ name: String) -> NSImage {
    let img = NSImage(contentsOf: src.appendingPathComponent(name))!
    let rep = img.representations[0]
    img.size = NSSize(width: rep.pixelsWide / 2, height: rep.pixelsHigh / 2)   // snapshots are @2x
    return img
}

/// Draws into a bitmap (@2x unless `scale` says otherwise) with a top-left origin, like a screen.
func canvas(_ w: CGFloat, _ h: CGFloat, _ name: String, scale: CGFloat = 2, _ draw: (NSRect) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: h)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)   // AppKit then draws images and text upright
    draw(NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

func drawImage(_ img: NSImage, in r: NSRect) {
    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

func text(_ s: String, at p: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white, width: CGFloat = 1000) {
    let para = NSMutableParagraphStyle()
    para.lineSpacing = size * 0.25
    let attr = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: para])
    let bounds = attr.boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin])
    attr.draw(with: NSRect(x: p.x, y: p.y, width: width, height: bounds.height), options: [.usesLineFragmentOrigin])
}

func textWidth(_ s: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).size().width
}

/// A popover-like panel: rounded corners, hairline border and a soft drop shadow.
func panel(_ img: NSImage, at origin: NSPoint, dark: Bool, alpha: CGFloat = 1) {
    let r = NSRect(origin: origin, size: img.size)
    let shape = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current?.cgContext.setAlpha(alpha)
    NSGraphicsContext.current?.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
    defer { NSGraphicsContext.current?.cgContext.endTransparencyLayer(); NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.22)
    sh.shadowBlurRadius = 40
    sh.shadowOffset = NSSize(width: 0, height: 18)
    sh.set()
    (dark ? rgb(0x1E1E1E) : rgb(0xECECEC)).setFill()   // window background colours
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    drawImage(img, in: r)
    NSGraphicsContext.restoreGraphicsState()
    (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.10)).setStroke()
    shape.lineWidth = 1
    shape.stroke()
}

func warmBackground(_ r: NSRect) {
    NSGradient(colors: [rgb(0x1B100E), rgb(0x2E1712), rgb(0x46200F)])!.draw(in: r, angle: -60)
    NSGradient(colors: [rgb(0xFF6A1F, 0.42), rgb(0xFF6A1F, 0)])!
        .draw(fromCenter: NSPoint(x: r.width * 0.72, y: r.height * 0.55), radius: 0,
              toCenter: NSPoint(x: r.width * 0.72, y: r.height * 0.55), radius: r.width * 0.55, options: [])
    NSGradient(colors: [rgb(0xB0306A, 0.30), rgb(0xB0306A, 0)])!
        .draw(fromCenter: NSPoint(x: r.width * 0.05, y: r.height), radius: 0,
              toCenter: NSPoint(x: r.width * 0.05, y: r.height), radius: r.width * 0.45, options: [])
}

/// A small progress ring in a service colour. The README images deliberately use no third-party logos.
func ring(_ p: CGFloat, _ color: NSColor, in r: NSRect) {
    let c = NSPoint(x: r.midX, y: r.midY), radius = r.width / 2 - 2
    let track = NSBezierPath()
    track.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = 3
    NSColor.white.withAlphaComponent(0.25).setStroke()
    track.stroke()
    let arc = NSBezierPath()   // flipped canvas: clockwise from 12 o'clock
    arc.appendArc(withCenter: c, radius: radius, startAngle: -90, endAngle: -90 + 360 * p / 100, clockwise: false)
    arc.lineWidth = 3
    arc.lineCapStyle = .round
    color.setStroke()
    arc.stroke()
}

func symbol(_ name: String, _ size: CGFloat) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .medium).applying(.init(paletteColors: [.white])))
}

let icon = load("icon.png")
let dark = load("popover-dark.png"), light = load("popover-light.png"), settings = load("settings-dark.png")
let breakdown = load("breakdown-dark.png")

// MARK: hero.png — Burny on the left, a menu bar with the open popover on the right

/// The menu bar strip with Burny's item; returns the item's rect.
@discardableResult
func menuBar(_ r: NSRect) -> NSRect {
    let barH: CGFloat = 28
    NSColor.black.withAlphaComponent(0.30).setFill()
    NSRect(x: 0, y: 0, width: r.width, height: barH).fill()
    var x = r.width - 16
    let clock = "Sun 27 Sep  20:41"
    x -= textWidth(clock, size: 13.5, weight: .medium)
    text(clock, at: NSPoint(x: x, y: 5.5), size: 13.5, weight: .medium)
    for s in ["switch.2", "magnifyingglass", "battery.75percent", "wifi"] {
        guard let img = symbol(s, 14) else { continue }
        x -= img.size.width + 18
        drawImage(img, in: NSRect(x: x, y: (barH - img.size.height) / 2, width: img.size.width, height: img.size.height))
    }
    // Burny's item: two app icons with their percentages
    let items: [(NSColor, String)] = [(rgb(0xD97857), barValues[0]), (rgb(0x0FA37F), barValues[1])]
    let itemW = items.reduce(CGFloat(0)) { $0 + 18 + 5 + textWidth($1.1, size: 13.5, weight: .semibold) } + 12 + 16
    x -= itemW + 14
    let itemRect = NSRect(x: x, y: 3, width: itemW, height: barH - 6)
    NSColor.white.withAlphaComponent(0.20).setFill()
    NSBezierPath(roundedRect: itemRect, xRadius: 5, yRadius: 5).fill()
    var ix = itemRect.minX + 8
    for (color, pct) in items {
        ring(CGFloat(Double(pct.dropLast()) ?? 0), color, in: NSRect(x: ix, y: 5, width: 18, height: 18))
        ix += 18 + 5
        text(pct, at: NSPoint(x: ix, y: 5.5), size: 13.5, weight: .semibold)
        ix += textWidth(pct, size: 13.5, weight: .semibold) + 12
    }
    return itemRect
}

canvas(1280, 640, "hero.png") { r in
    warmBackground(r)
    let barH: CGFloat = 28
    let itemRect = menuBar(r)

    // Popover hanging from the item
    let px = min(itemRect.midX - dark.size.width / 2, r.width - dark.size.width - 24)
    panel(dark, at: NSPoint(x: px, y: barH + 10), dark: true)

    // Brand block
    let left: CGFloat = 96, top: CGFloat = 120
    drawImage(icon, in: NSRect(x: left - 22, y: top - 22, width: 184, height: 184))
    text("Burny", at: NSPoint(x: left, y: top + 170), size: 76, weight: .heavy)
    text("See how fast you're burning through\nyour Claude Code and Codex plans.", at: NSPoint(x: left, y: top + 268),
         size: 24, weight: .medium, color: NSColor.white.withAlphaComponent(0.78), width: 520)
    var cx = left
    for chip in ["0 tokens", "Local only", "~13 MB RAM", "Native Swift"] {
        let w = textWidth(chip, size: 15, weight: .semibold) + 26
        let c = NSRect(x: cx, y: top + 372, width: w, height: 32)
        rgb(0xFF7A2E, 0.18).setFill()
        NSBezierPath(roundedRect: c, xRadius: 16, yRadius: 16).fill()
        rgb(0xFF9A55, 0.55).setStroke()
        NSBezierPath(roundedRect: c.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16).stroke()
        text(chip, at: NSPoint(x: cx + 13, y: top + 378), size: 15, weight: .semibold, color: rgb(0xFFD2B0))
        cx += w + 10
    }
}

// MARK: screens.png — light, dark and settings side by side

let tallestShot = [light, breakdown, settings].map(\.size.height).max()!
canvas(1280, 48 + tallestShot + 90, "screens.png") { r in
    NSGradient(colors: [rgb(0xFFF6EF), rgb(0xFFE4D1)])!.draw(in: r, angle: -90)
    NSGradient(colors: [rgb(0xFF8A3D, 0.22), rgb(0xFF8A3D, 0)])!
        .draw(fromCenter: NSPoint(x: r.midX, y: r.height), radius: 0, toCenter: NSPoint(x: r.midX, y: r.height), radius: r.width * 0.6, options: [])
    let shots: [(NSImage, Bool, String)] = [(light, false, "Light"), (breakdown, true, "Where it went"), (settings, true, "Settings")]
    let gap: CGFloat = 44
    let total = shots.reduce(CGFloat(0)) { $0 + $1.0.size.width } + gap * CGFloat(shots.count - 1)
    var x = (r.width - total) / 2
    let tallest = shots.map(\.0.size.height).max()!
    for (img, isDark, caption) in shots {
        let y = 48 + (tallest - img.size.height) / 2
        panel(img, at: NSPoint(x: x, y: y), dark: isDark)
        let w = textWidth(caption, size: 16, weight: .semibold)
        text(caption, at: NSPoint(x: x + (img.size.width - w) / 2, y: 48 + tallest + 26), size: 16, weight: .semibold, color: rgb(0x7A4A33))
        x += img.size.width + gap
    }
}
// MARK: frames/ — a short loop: open Burny, look at the limits, open "Where it went", go back

let frameDir = out.appendingPathComponent("frames")
try? FileManager.default.createDirectory(at: frameDir, withIntermediateDirectories: true)
let W: CGFloat = 1000, Hgt: CGFloat = 860
let popX = W - dark.size.width - 24, popY: CGFloat = 38
// Header buttons inside the popover (points from its top-left): the pie chart and the back chevron.
let pieButton = NSPoint(x: popX + 279, y: popY + 23), backButton = NSPoint(x: popX + 21, y: popY + 27)
var frameNo = 0
var itemCenter = NSPoint.zero   // Burny's menu bar item, set by the first frame

enum Shown { case none, limits, breakdown }
struct Beat { var cursor: NSPoint; var click: CGFloat = 0; var from: Shown; var to: Shown; var mix: CGFloat }

let captions: [Shown: (String, String)] = [
    .none: ("Your AI plan limits,\nin the menu bar.", "Claude Code and Codex, side by side."),
    .limits: ("Every limit,\nat a glance.", "Session, week and per-model buckets. A forecast that only speaks up when it's likely."),
    .breakdown: ("Where did my\nlimits go?", "Split by project and model, from the logs Claude Code and Codex already keep."),
]

func drawFrame(_ b: Beat) {
    canvas(W, Hgt, String(format: "frames/f%04d.png", frameNo), scale: 1) { r in
        warmBackground(r)
        let item = menuBar(r)
        itemCenter = NSPoint(x: item.midX, y: item.midY)
        func pop(_ s: Shown, _ a: CGFloat) {
            guard a > 0.01, s != .none else { return }
            panel(s == .limits ? dark : breakdown, at: NSPoint(x: popX, y: popY), dark: true, alpha: a)
        }
        pop(b.from, 1 - b.mix)
        pop(b.to, b.mix)
        // Caption on the left, crossfading with the popover
        for (s, a) in [(b.from, 1 - b.mix), (b.to, b.mix)] where a > 0.01 {
            let (title, sub) = captions[s]!
            let c = NSColor.white.withAlphaComponent(a)
            text(title, at: NSPoint(x: 64, y: 250), size: 50, weight: .heavy, color: c, width: 520)
            text(sub, at: NSPoint(x: 64, y: 400), size: 21, weight: .medium, color: NSColor.white.withAlphaComponent(0.75 * a), width: 480)
        }
        drawImage(icon, in: NSRect(x: 48, y: 108, width: 120, height: 120))
        var cx: CGFloat = 64
        for chip in ["0 tokens", "Local only", "~13 MB RAM"] {
            let w = textWidth(chip, size: 15, weight: .semibold) + 26
            let c = NSRect(x: cx, y: Hgt - 110, width: w, height: 32)
            rgb(0xFF7A2E, 0.18).setFill()
            NSBezierPath(roundedRect: c, xRadius: 16, yRadius: 16).fill()
            rgb(0xFF9A55, 0.55).setStroke()
            NSBezierPath(roundedRect: c.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16).stroke()
            text(chip, at: NSPoint(x: cx + 13, y: Hgt - 104), size: 15, weight: .semibold, color: rgb(0xFFD2B0))
            cx += w + 10
        }
        // Click ripple, then the cursor
        if b.click > 0 {
            let rad = 8 + 18 * b.click
            rgb(0xFFFFFF, 0.55 * (1 - b.click)).setFill()
            NSBezierPath(ovalIn: NSRect(x: b.cursor.x - rad, y: b.cursor.y - rad, width: rad * 2, height: rad * 2)).fill()
        }
        // The macOS arrow, drawn by hand (NSCursor's image doesn't render outside a running app); tip at the cursor point.
        let arrow = NSBezierPath()
        for (i, (dx, dy)) in [(0.0, 0.0), (0, 17), (4, 13.2), (6.8, 19.6), (9.6, 18.4), (6.9, 12.2), (12, 12.2)].enumerated() {
            let p = NSPoint(x: b.cursor.x + dx * 1.3, y: b.cursor.y + dy * 1.3)
            i == 0 ? arrow.move(to: p) : arrow.line(to: p)
        }
        arrow.close()
        arrow.lineJoinStyle = .round
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.4)
        sh.shadowBlurRadius = 3
        sh.shadowOffset = NSSize(width: 0, height: 1)
        sh.set()
        NSColor.black.setFill()
        arrow.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke()
        arrow.lineWidth = 1.6
        arrow.stroke()
    }
    frameNo += 1
}

func ease(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }
func move(_ a: NSPoint, _ b: NSPoint, _ n: Int, shown: Shown) -> NSPoint {
    for i in 1...n {
        let t = ease(CGFloat(i) / CGFloat(n))
        drawFrame(Beat(cursor: NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), from: shown, to: shown, mix: 0))
    }
    return b
}
func click(_ p: NSPoint, from: Shown, to: Shown, fade: Int, hold: Int) {
    for i in 1...fade {
        let t = CGFloat(i) / CGFloat(fade)
        drawFrame(Beat(cursor: p, click: min(1, t * 1.5), from: from, to: to, mix: ease(t)))
    }
    for _ in 0..<hold { drawFrame(Beat(cursor: p, from: to, to: to, mix: 0)) }
}

// 10 fps
var cur = NSPoint(x: 560, y: 520)
for _ in 0..<12 { drawFrame(Beat(cursor: cur, from: .none, to: .none, mix: 0)) }
cur = move(cur, itemCenter, 9, shown: .none)
click(cur, from: .none, to: .limits, fade: 5, hold: 32)
cur = move(cur, pieButton, 8, shown: .limits)
click(cur, from: .limits, to: .breakdown, fade: 6, hold: 45)
cur = move(cur, backButton, 9, shown: .breakdown)
click(cur, from: .breakdown, to: .limits, fade: 6, hold: 10)
cur = move(cur, NSPoint(x: 560, y: 520), 8, shown: .limits)
click(cur, from: .limits, to: .none, fade: 5, hold: 6)

print("✓ wrote hero.png, screens.png and \(frameNo) animation frames to \(out.path)")
