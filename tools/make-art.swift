// Renders the project artwork into docs/: app icon, README hero banner and a
// mockup of the menu bar dropdown. Run with:  swift tools/make-art.swift
//
// Everything is drawn with AppKit so the repo needs no design-tool dependencies.

import AppKit

// MARK: - Canvas helpers

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha)
}

func canvas(_ width: CGFloat, _ height: CGFloat, scale: CGFloat, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    // Setting `size` in points while the bitmap is `scale` times larger in pixels is
    // what makes the context retina — it applies the scale itself, so the drawing
    // code below works in points.
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)  (\(rep.pixelsWide)x\(rep.pixelsHigh))")
}

func roundedRect(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func fillGradient(_ path: NSBezierPath, _ from: NSColor, _ to: NSColor, angle: CGFloat = 270) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(starting: from, ending: to)!.draw(in: path.bounds, angle: angle)
    NSGraphicsContext.restoreGraphicsState()
}

/// A soft radial glow built from stacked discs.
///
/// `NSGradient.draw(in:relativeCenterPosition:)` circumscribes the rect rather than
/// inscribing it, so its outer edge is still opaque and leaves a visible rectangular
/// seam. Stacking discs gives a clean linear falloff instead.
func softGlow(center: NSPoint, radius: CGFloat, color: NSColor, alpha: CGFloat) {
    let steps = 64
    let per = alpha / CGFloat(steps)
    for i in stride(from: steps, through: 1, by: -1) {
        let r = radius * CGFloat(i) / CGFloat(steps)
        color.withAlphaComponent(per).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r,
                                    width: r * 2, height: r * 2)).fill()
    }
}

func text(_ string: String, _ point: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular,
          color: NSColor = .white, tracking: CGFloat = 0) {
    var attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ]
    if tracking != 0 { attrs[.kern] = tracking }
    NSAttributedString(string: string, attributes: attrs).draw(at: point)
}

func textRight(_ string: String, rightX: CGFloat, y: CGFloat, size: CGFloat,
               weight: NSFont.Weight = .regular, color: NSColor = .white) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ]
    let s = NSAttributedString(string: string, attributes: attrs)
    s.draw(at: NSPoint(x: rightX - s.size().width, y: y))
}

func width(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
    NSAttributedString(string: string,
                       attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).size().width
}

// MARK: - Brand

let leafGreen = hex(0x4ADE80)
let leafTeal = hex(0x12B981)
let inkTop = hex(0x1B2029)
let inkBottom = hex(0x0A0C11)
let pageBG = hex(0x0B0D12)
let subtle = hex(0x8B93A1)

/// The mark: a leaf resting on a closed laptop. Drawn into a unit box of `size`.
func drawMark(in box: NSRect, laptop: Bool = true, monochrome: NSColor? = nil) {
    let s = box.width
    let cx = box.midX

    // Leaf: two mirrored curves meeting at the tips.
    let leaf = NSBezierPath()
    let tipBottom = NSPoint(x: cx - 0.20 * s, y: box.minY + (laptop ? 0.30 : 0.18) * s)
    let tipTop = NSPoint(x: cx + 0.26 * s, y: box.minY + (laptop ? 0.88 : 0.82) * s)
    leaf.move(to: tipBottom)
    leaf.curve(to: tipTop,
               controlPoint1: NSPoint(x: cx - 0.30 * s, y: box.minY + 0.70 * s),
               controlPoint2: NSPoint(x: cx - 0.02 * s, y: box.minY + 0.88 * s))
    leaf.curve(to: tipBottom,
               controlPoint1: NSPoint(x: cx + 0.28 * s, y: box.minY + 0.54 * s),
               controlPoint2: NSPoint(x: cx + 0.14 * s, y: box.minY + 0.32 * s))
    leaf.close()

    if let mono = monochrome {
        mono.setFill()
        leaf.fill()
    } else {
        fillGradient(leaf, leafGreen, leafTeal, angle: 250)
    }

    // Midrib — a thin stroke from the lower tip towards the upper one.
    let rib = NSBezierPath()
    rib.move(to: tipBottom)
    rib.curve(to: NSPoint(x: cx + 0.19 * s, y: box.minY + (laptop ? 0.80 : 0.74) * s),
              controlPoint1: NSPoint(x: cx - 0.10 * s, y: box.minY + 0.52 * s),
              controlPoint2: NSPoint(x: cx + 0.06 * s, y: box.minY + 0.66 * s))
    rib.lineWidth = 0.022 * s
    rib.lineCapStyle = .round
    (monochrome == nil ? hex(0x0A1F17, 0.55) : NSColor.clear).setStroke()
    if monochrome == nil { rib.stroke() }

    guard laptop else { return }

    // Closed laptop seen head-on: a wide slab with a thin seam.
    let slab = NSRect(x: cx - 0.36 * s, y: box.minY + 0.14 * s, width: 0.72 * s, height: 0.085 * s)
    let slabPath = roundedRect(slab, slab.height * 0.42)
    if let mono = monochrome {
        mono.setFill()
        slabPath.fill()
    } else {
        fillGradient(slabPath, hex(0xE8EBF0), hex(0x9AA3B2), angle: 270)
        hex(0x0A0C11, 0.55).setFill()
        roundedRect(NSRect(x: slab.minX + 0.03 * s, y: slab.midY - 0.005 * s,
                           width: slab.width - 0.06 * s, height: 0.01 * s), 0.005 * s).fill()
    }
}

// MARK: - App icon

func makeIcon(_ size: CGFloat) -> NSBitmapImageRep {
    canvas(size, size, scale: 1) {
        let inset = size * 0.085
        let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let squircle = roundedRect(body, body.width * 0.2237)

        fillGradient(squircle, inkTop, inkBottom, angle: 270)

        // A soft green glow behind the mark.
        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        softGlow(center: NSPoint(x: body.midX, y: body.midY + body.height * 0.10),
                 radius: body.width * 0.62, color: leafGreen, alpha: 0.26)
        NSGraphicsContext.restoreGraphicsState()

        // Hairline edge so the icon reads on light wallpapers too.
        hex(0xFFFFFF, 0.10).setStroke()
        squircle.lineWidth = size * 0.004
        squircle.stroke()

        let markBox = NSRect(x: body.minX + body.width * 0.17, y: body.minY + body.height * 0.14,
                             width: body.width * 0.66, height: body.height * 0.72)
        drawMark(in: markBox)
    }
}

// MARK: - Menu mockup

struct Row {
    enum Kind { case header, info, item, separator, warning }
    var kind: Kind
    var title: String = ""
    var trailing: String = ""
    /// Draws a ✓ in the leading gutter.
    var checked = false
    /// Green highlight bar — the master switch.
    var highlighted = false
    /// Neutral highlight — a submenu parent that is currently open.
    var open = false
    var chevron = false
}

let rowPadH: CGFloat = 14

func rowHeight(_ row: Row) -> CGFloat {
    switch row.kind {
    case .separator: return 11
    case .info, .warning: return 19
    case .header: return 26
    case .item: return 25
    }
}

func panelHeight(_ rows: [Row], topPad: CGFloat = 10, bottomPad: CGFloat = 10) -> CGFloat {
    rows.reduce(topPad + bottomPad) { $0 + rowHeight($1) }
}

/// Draws a macOS-style menu panel. `top` is the y of its upper edge.
func drawPanel(_ rows: [Row], x: CGFloat, top: CGFloat, width: CGFloat) {
    let height = panelHeight(rows)
    let panel = NSRect(x: x, y: top - height, width: width, height: height)
    let path = roundedRect(panel, 11)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    shadow.set()
    hex(0x1F232B).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    fillGradient(path, hex(0x2A2E37), hex(0x1E222A), angle: 270)
    hex(0xFFFFFF, 0.09).setStroke()
    path.lineWidth = 1
    path.stroke()

    var y = panel.maxY - 10
    for row in rows {
        let rh = rowHeight(row)
        y -= rh
        let baseline = y + (rh - 15) / 2 + 1
        let tx = panel.minX + rowPadH

        switch row.kind {
        case .separator:
            hex(0xFFFFFF, 0.10).setFill()
            NSRect(x: panel.minX + 10, y: y + rh / 2, width: width - 20, height: 1).fill()

        case .header:
            text(row.title, NSPoint(x: tx, y: baseline), size: 12.5, weight: .semibold,
                 color: hex(0xF2F4F8))

        case .info:
            text(row.title, NSPoint(x: tx, y: baseline + 1), size: 11, color: subtle)

        case .warning:
            text("⚠︎ " + row.title, NSPoint(x: tx, y: baseline + 1), size: 11, color: hex(0xF59E0B))

        case .item:
            if row.highlighted || row.open {
                (row.highlighted ? hex(0x2F6B4F, 0.55) : hex(0x3A4150, 0.75)).setFill()
                roundedRect(NSRect(x: panel.minX + 5, y: y + 1,
                                   width: width - 10, height: rh - 2), 6).fill()
            }
            if row.checked {
                text("✓", NSPoint(x: tx - 2, y: baseline), size: 12.5, weight: .bold,
                     color: row.highlighted ? leafGreen : hex(0xD7DCE5))
            }
            text(row.title, NSPoint(x: tx + 18, y: baseline), size: 12.5, color: hex(0xF2F4F8))
            if !row.trailing.isEmpty {
                textRight(row.trailing, rightX: panel.maxX - rowPadH, y: baseline, size: 12.5,
                          color: hex(0x9BA3B1))
            }
            if row.chevron {
                textRight("›", rightX: panel.maxX - rowPadH, y: baseline - 1, size: 14,
                          color: hex(0x9BA3B1))
            }
        }
    }
}

func makeMenu() -> NSBitmapImageRep {
    let main: [Row] = [
        Row(kind: .header, title: "Agent mode · ~5h 10m of work left"),
        Row(kind: .info, title: "Timer: 2:14:03 left"),
        Row(kind: .separator),
        Row(kind: .item, title: "Agent mode", trailing: "⌘K", checked: true, highlighted: true),
        Row(kind: .item, title: "Extend by 30 minutes"),
        Row(kind: .separator),
        Row(kind: .item, title: "Power saving", open: true, chevron: true),
        Row(kind: .item, title: "Keep awake", chevron: true),
        Row(kind: .item, title: "Energy hogs", chevron: true),
        Row(kind: .separator),
        Row(kind: .info, title: "battery · 53% · ~5h 20m"),
        Row(kind: .info, title: "Claude Code: 2 processes"),
        Row(kind: .info, title: "Restricted: 9 frozen (20 processes)"),
        Row(kind: .separator),
        Row(kind: .item, title: "Session report"),
        Row(kind: .item, title: "Settings", chevron: true),
        Row(kind: .item, title: "About"),
        Row(kind: .item, title: "Quit", trailing: "⌘Q"),
    ]

    let submenu: [Row] = [
        Row(kind: .info, title: "Power draw: 4.2 W (−3.1 W)"),
        Row(kind: .info, title: "Before power saving: 7.3 W"),
        Row(kind: .separator),
        Row(kind: .item, title: "Power saving on", checked: true),
        Row(kind: .item, title: "Aggressive mode (freeze apps)"),
        Row(kind: .info, title: "taskpolicy: efficiency cores, ~2x slower"),
        Row(kind: .separator),
        Row(kind: .item, title: "Manage apps", chevron: true),
        Row(kind: .separator),
        Row(kind: .item, title: "Arm when the lid closes", checked: true),
        Row(kind: .item, title: "Turn the display off on start"),
        Row(kind: .item, title: "Turn the display off now"),
        Row(kind: .separator),
        Row(kind: .item, title: "Low Power Mode (admin password)"),
        Row(kind: .item, title: "Pause Spotlight (admin password)"),
    ]

    let mainWidth: CGFloat = 380
    let subWidth: CGFloat = 268
    let barHeight: CGFloat = 30
    let gap: CGFloat = 8
    let rightMargin: CGFloat = 16

    // How far down the main panel the opened submenu starts.
    var subOffset: CGFloat = 10
    for row in main {
        if row.open { break }
        subOffset += rowHeight(row)
    }

    let w = rightMargin + mainWidth + subWidth - 4 + 40
    // The canvas has to clear whichever panel reaches lower.
    let deepest = max(panelHeight(main), subOffset - 6 + panelHeight(submenu))
    let h = barHeight + gap + deepest + 28

    return canvas(w, h, scale: 2) {
        pageBG.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()

        // --- Fake menu bar along the top
        let bar = NSRect(x: 0, y: h - barHeight, width: w, height: barHeight)
        fillGradient(NSBezierPath(rect: bar), hex(0x23262D), hex(0x1A1D23), angle: 270)
        hex(0xFFFFFF, 0.07).setFill()
        NSRect(x: 0, y: h - barHeight, width: w, height: 1).fill()

        drawMark(in: NSRect(x: w - 190, y: h - barHeight + 6, width: 17, height: 18),
                 laptop: false, monochrome: hex(0xE6E9EF))
        text("2:14 · ~5:10", NSPoint(x: w - 168, y: h - barHeight + 8), size: 12,
             color: hex(0xE6E9EF))
        textRight("Thu 14:22", rightX: w - 16, y: h - barHeight + 8, size: 12, color: hex(0xC3C9D4))

        // --- The dropdown, with the Power saving submenu opened to its left
        // (macOS flips submenus leftwards near the right edge of the screen).
        let mainX = w - rightMargin - mainWidth
        let mainTop = h - barHeight - gap
        drawPanel(main, x: mainX, top: mainTop, width: mainWidth)

        drawPanel(submenu, x: mainX - subWidth + 4, top: mainTop - subOffset + 6, width: subWidth)
    }
}

// MARK: - Hero banner

func makeHero() -> NSBitmapImageRep {
    let w: CGFloat = 1200, h: CGFloat = 400
    return canvas(w, h, scale: 2) {
        fillGradient(NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: h)),
                     hex(0x141821), hex(0x07090D), angle: 290)

        // Aurora behind the artwork.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: h)).addClip()
        softGlow(center: NSPoint(x: w - 215, y: h / 2), radius: 330, color: leafTeal, alpha: 0.34)
        softGlow(center: NSPoint(x: 40, y: h - 40), radius: 420, color: hex(0x3B82F6), alpha: 0.16)
        NSGraphicsContext.restoreGraphicsState()

        let left: CGFloat = 72

        // Eyebrow
        text("MACOS MENU BAR", NSPoint(x: left, y: 303), size: 13, weight: .semibold,
             color: leafGreen, tracking: 2.6)

        // Title
        text("Claude Not Close", NSPoint(x: left - 3, y: 216), size: 58, weight: .bold,
             color: hex(0xF7F9FC), tracking: -1.2)

        // Tagline
        text("Close the lid. Claude Code keeps working.", NSPoint(x: left, y: 172),
             size: 20, weight: .medium, color: hex(0xB7BECC))
        text("Everything else gets throttled so the battery survives.",
             NSPoint(x: left, y: 142), size: 20, weight: .medium, color: hex(0x7D8695))

        // Chips
        var cx = left
        for (label, color) in [("Swift", hex(0xF05138)), ("macOS 13+", hex(0x60A5FA)),
                               ("No root required", leafGreen),
                               ("Free, non-commercial", hex(0xA78BFA))] {
            let tw = width(label, size: 13, weight: .medium)
            let chip = NSRect(x: cx, y: 54, width: tw + 34, height: 30)
            let path = roundedRect(chip, 15)
            hex(0xFFFFFF, 0.05).setFill()
            path.fill()
            hex(0xFFFFFF, 0.11).setStroke()
            path.lineWidth = 1
            path.stroke()
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: chip.minX + 12, y: chip.midY - 3, width: 6, height: 6)).fill()
            text(label, NSPoint(x: chip.minX + 24, y: chip.midY - 8), size: 13, weight: .medium,
                 color: hex(0xD6DBE4))
            cx = chip.maxX + 10
        }

        // The app icon itself, large on the right.
        let tile: CGFloat = 272
        let iconRep = makeIcon(tile * 2)
        iconRep.size = NSSize(width: tile, height: tile)
        let iconImage = NSImage(size: iconRep.size)
        iconImage.addRepresentation(iconRep)
        iconImage.draw(in: NSRect(x: w - 215 - tile / 2, y: h / 2 - tile / 2,
                                  width: tile, height: tile))
    }
}

// MARK: - Run

let fm = FileManager.default
try? fm.createDirectory(atPath: "docs", withIntermediateDirectories: true)

write(makeHero(), to: "docs/hero.png")
write(makeMenu(), to: "docs/menu.png")
write(makeIcon(1024), to: "docs/icon.png")

// Iconset -> .icns
let iconset = "build/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (px, name) in [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"),
                   (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"),
                   (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"),
                   (1024, "icon_512x512@2x")] {
    write(makeIcon(CGFloat(px)), to: "\(iconset)/\(name).png")
}
