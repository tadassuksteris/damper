import AppKit

/// The menu bar version of the app icon, drawn for small sizes.
@MainActor
enum MenuBarMark {
    private enum Detail { case levels, paused, muted }

    static let active = make(.levels)
    static let paused = make(.paused)
    static let muted = make(.muted)

    /// AppKit may call the drawing handler on any thread, so it must not be main-actor isolated.
    nonisolated private static func make(_ detail: Detail) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            let speaker = NSBezierPath()
            speaker.move(to: NSPoint(x: 2, y: 6.5))
            speaker.line(to: NSPoint(x: 4.5, y: 6.5))
            speaker.line(to: NSPoint(x: 8.5, y: 3.1))
            speaker.curve(to: NSPoint(x: 9.5, y: 3.6), controlPoint1: NSPoint(x: 9, y: 2.7), controlPoint2: NSPoint(x: 9.5, y: 2.9))
            speaker.line(to: NSPoint(x: 9.5, y: 14.4))
            speaker.curve(to: NSPoint(x: 8.5, y: 14.9), controlPoint1: NSPoint(x: 9.5, y: 15.1), controlPoint2: NSPoint(x: 9, y: 15.3))
            speaker.line(to: NSPoint(x: 4.5, y: 11.5))
            speaker.line(to: NSPoint(x: 2, y: 11.5))
            speaker.close(); speaker.fill()
            switch detail {
            case .paused:
                for x in [12.5, 18.0] {
                    NSBezierPath(roundedRect: NSRect(x: x, y: 4.5, width: 2.5, height: 9), xRadius: 0.8, yRadius: 0.8).fill()
                }
            case .muted:
                NSColor.black.setStroke()
                let cross = NSBezierPath()
                cross.lineWidth = 2
                cross.lineCapStyle = .round
                cross.move(to: NSPoint(x: 13, y: 5.5)); cross.line(to: NSPoint(x: 19.5, y: 12.5))
                cross.move(to: NSPoint(x: 19.5, y: 5.5)); cross.line(to: NSPoint(x: 13, y: 12.5))
                cross.stroke()
            case .levels:
                for (x, y) in [(13.5, 6.5), (19.0, 11.5)] {
                    // Leave clear space around the thumb so it remains distinct at menu-bar size.
                    NSBezierPath(roundedRect: NSRect(x: x - 0.75, y: 3, width: 1.5, height: y - 5.5), xRadius: 0.75, yRadius: 0.75).fill()
                    NSBezierPath(roundedRect: NSRect(x: x - 0.75, y: y + 2.5, width: 1.5, height: 12.5 - y), xRadius: 0.75, yRadius: 0.75).fill()
                    NSBezierPath(roundedRect: NSRect(x: x - 2, y: y - 1.5, width: 4, height: 3), xRadius: 1, yRadius: 1).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Damper"
        return image
    }
}
