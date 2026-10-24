import AppKit
import LidlessCore

/// Draws the "pulse" icon set. Geometry is ported from the 24x24 SVG symbols
/// (p0, p1, ptimer, plid, pwarn); drawing uses a flipped (y-down) context so
/// SVG coordinates map one-to-one. An available update adds a dot in the system accent colour;
/// the orange attention dot wins over it (StatusPresentation drops the update dot then).
///
/// Deliberately nonisolated: AppKit may invoke the NSImage drawing handler on any
/// thread, so everything the handler touches must be free of actor isolation.
enum IconRenderer {
    static let pointSize = NSSize(width: 18, height: 18)
    /// On air the glyph becomes a small lit ON AIR lamp, so a running session is visible
    /// at a glance in any menu bar.
    static let lampSize = NSSize(width: 24, height: 18)
    private static let warnColor = NSColor(srgbRed: 1, green: 0x9F / 255, blue: 0x0A / 255, alpha: 1)
    private static let onAir = NSColor(srgbRed: 0xE0 / 255, green: 0x34 / 255, blue: 0x2A / 255, alpha: 1)
    private static let onAirSpent = NSColor(srgbRed: 0x6E / 255, green: 0x1A / 255, blue: 0x15 / 255, alpha: 1)
    private static let lampDot = NSPoint(x: 21.5, y: 2.5)

    static func image(for p: StatusPresentation) -> NSImage {
        switch p.glyph {
        case .active, .timer, .lid:
            let image = NSImage(size: lampSize, flipped: true) { _ in
                drawLamp(p)
                return true
            }
            image.isTemplate = false
            return image
        case .off, .attention:
            let image = NSImage(size: pointSize, flipped: true) { rect in
                let t = NSAffineTransform()
                t.scale(by: rect.width / 24)
                t.concat()
                draw(p)
                return true
            }
            // A coloured dot makes the whole image non-template, as the lamp already is.
            image.isTemplate = p.glyph != .attention && !p.updateDot
            return image
        }
    }

    /// 24x18 pt, y-down. A red lamp with the white pulse; with a timer the lamp's lit part
    /// is the remaining fraction (the light burns down); in lid mode a horizon line sits below.
    private static func drawLamp(_ p: StatusPresentation) {
        let lid = p.glyph == .lid
        if p.updateDot {
            // The dot sits on the lamp's top-right corner; a clear ring keeps it apart from the red.
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: NSRect(origin: .zero, size: lampSize))
            clip.append(dot(at: lampDot, radius: 3.6))
            clip.windingRule = .evenOdd
            clip.addClip()
        }
        let lamp = NSRect(x: 1, y: lid ? 1.5 : 3, width: 22, height: lid ? 11 : 12)
        let shape = NSBezierPath(roundedRect: lamp, xRadius: 3, yRadius: 3)
        if p.glyph == .timer || (lid && p.progress != nil) {
            onAirSpent.setFill()
            shape.fill()
            let remaining = min(1, max(0, p.progress ?? 1))
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            onAir.setFill()
            NSRect(x: lamp.minX, y: lamp.minY, width: lamp.width * remaining, height: lamp.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            onAir.setFill()
            shape.fill()
        }
        let base = lamp.midY
        NSColor.white.setStroke()
        stroke(poly([(3.5, base), (7.5, base), (9.5, base - 3.6), (12.4, base + 3.6),
                     (14.7, base - 1.8), (16.1, base), (20.5, base)]), width: 1.6)
        if lid {
            NSColor.labelColor.setStroke()
            stroke(poly([(3, 16), (21, 16)]), width: 1.6)
        }
        if p.updateDot {
            NSGraphicsContext.restoreGraphicsState()
            NSColor.controlAccentColor.setFill()
            dot(at: lampDot, radius: 2.5).fill()
        }
    }

    private static func draw(_ p: StatusPresentation) {
        let ink = NSColor.labelColor
        switch p.glyph {
        case .off where p.updateDot:
            // The flat line steps aside for the dot, where the attention glyph has its orange one.
            ink.withAlphaComponent(0.9).setStroke()
            stroke(poly([(2.5, 12), (16.5, 12)]), width: 1.9)
            ink.setFill()
            dot(at: NSPoint(x: 9.5, y: 12), radius: 1.6).fill()
            NSColor.controlAccentColor.setFill()
            dot(at: NSPoint(x: 19.5, y: 6), radius: 3.6).fill()
        case .off:
            ink.withAlphaComponent(0.9).setStroke()
            stroke(poly([(2.5, 12), (21.5, 12)]), width: 1.9)
            ink.setFill()
            NSBezierPath(ovalIn: NSRect(x: 12 - 1.6, y: 12 - 1.6, width: 3.2, height: 3.2)).fill()
        case .active:
            ink.setStroke()
            stroke(poly([(2.5, 12.5), (6.5, 12.5), (8.7, 7), (12.3, 18), (14.9, 10.5), (16.5, 12.5), (21.5, 12.5)]), width: 2)
        case .timer:
            ink.withAlphaComponent(0.28).setStroke()
            stroke(NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 20, height: 20)), width: 1.7)
            ink.setStroke()
            let remaining = min(1, max(0, p.progress ?? 1))
            if remaining > 0 { stroke(ringArc(fraction: remaining), width: 1.7) }
            stroke(poly([(5.5, 12.5), (7.8, 12.5), (9.3, 9), (11.8, 16), (13.6, 11.2), (14.6, 12.5), (18.5, 12.5)]), width: 1.7)
        case .lid:
            ink.setStroke()
            stroke(poly([(2.5, 10), (6.5, 10), (8.5, 5.5), (11.7, 14.5), (14, 8.5), (15.5, 10), (21.5, 10)]), width: 1.9)
            stroke(poly([(3, 19.5), (21, 19.5)]), width: 2.4)
        case .attention:
            ink.setStroke()
            stroke(poly([(1.5, 13), (5, 13), (7, 8), (10.2, 18), (12.5, 11.5), (14, 13), (16.5, 13)]), width: 1.9)
            warnColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 19.5 - 3.6, y: 6 - 3.6, width: 7.2, height: 7.2)).fill()
        }
    }

    private static func dot(at center: NSPoint, radius r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    }

    private static func poly(_ pts: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
        for pt in pts.dropFirst() { path.line(to: NSPoint(x: pt.0, y: pt.1)) }
        return path
    }

    /// Clockwise from 12 o'clock around the r=10 ring, `fraction` of a full turn.
    private static func ringArc(fraction: Double) -> NSBezierPath {
        let path = NSBezierPath()
        let steps = max(2, Int(ceil(fraction * 72)))
        for i in 0...steps {
            let a = 2 * Double.pi * fraction * Double(i) / Double(steps)
            let pt = NSPoint(x: 12 + 10 * sin(a), y: 12 - 10 * cos(a))
            if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
        }
        return path
    }

    private static func stroke(_ path: NSBezierPath, width: CGFloat) {
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}
