import AppKit

/// A monochrome status-item drawing based on the app's faceted moka-pot mark.
/// The template image lets macOS choose contrast for light and dark menu bars.
@MainActor
enum MokaPotStatusImage {
    static func make(filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            if filled { drawFilled() } else { drawOutline() }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func polygon(_ coordinates: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = coordinates.first else { return path }
        path.move(to: NSPoint(x: first.0, y: first.1))
        for point in coordinates.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }
        path.close()
        return path
    }

    private static func drawFilled() {
        // Short knob and shallow lid.
        polygon([(8.3, 16.1), (8.45, 17.1), (9.55, 17.1), (9.7, 16.1)]).fill()
        polygon([(5.2, 14.2), (9, 16.0), (12.8, 14.2)]).fill()

        // Three solid panels leave narrow transparent facet seams. The left panel includes the spout.
        polygon([(2.1, 13.8), (5.3, 13.8), (5.9, 9.5), (4.9, 9.5), (4.5, 11.2)]).fill()
        polygon([(5.6, 13.8), (9.0, 13.8), (9.0, 9.5), (6.2, 9.5)]).fill()
        polygon([(9.25, 13.8), (12.7, 13.8), (11.8, 9.5), (9.25, 9.5)]).fill()
        NSBezierPath(rect: NSRect(x: 5.2, y: 8.35, width: 6.8, height: 0.9)).fill()

        polygon([(5.1, 8.1), (6.2, 8.1), (5.3, 1.2), (4.0, 1.2)]).fill()
        polygon([(6.5, 8.1), (9.0, 8.1), (9.0, 1.2), (5.6, 1.2)]).fill()
        polygon([(9.25, 8.1), (11.8, 8.1), (13.1, 1.2), (9.25, 1.2)]).fill()

        let handle = NSBezierPath()
        handle.move(to: NSPoint(x: 12.85, y: 13.2))
        handle.curve(to: NSPoint(x: 15.8, y: 12.2), controlPoint1: NSPoint(x: 15.8, y: 14.5), controlPoint2: NSPoint(x: 16.4, y: 13.5))
        handle.line(to: NSPoint(x: 15.1, y: 10.3))
        handle.curve(to: NSPoint(x: 13.7, y: 9.9), controlPoint1: NSPoint(x: 14.7, y: 9.4), controlPoint2: NSPoint(x: 14.0, y: 9.4))
        handle.lineWidth = 1.35
        handle.lineCapStyle = .round
        handle.lineJoinStyle = .round
        handle.stroke()
    }

    private static func drawOutline() {
        let upper = polygon([(2.1, 13.8), (12.7, 13.8), (11.8, 9.5), (4.9, 9.5), (4.5, 11.2)])
        upper.lineWidth = 1.1
        upper.lineJoinStyle = .round
        upper.stroke()
        let lid = polygon([(5.2, 14.4), (9.0, 16.0), (12.8, 14.4)])
        lid.lineWidth = 1.1
        lid.stroke()
        let knob = polygon([(8.3, 16.1), (8.45, 17.1), (9.55, 17.1), (9.7, 16.1)])
        knob.lineWidth = 0.9
        knob.stroke()
        let waist = NSBezierPath(rect: NSRect(x: 5.2, y: 8.35, width: 6.8, height: 0.9))
        waist.lineWidth = 1.0
        waist.stroke()
        let lower = polygon([(5.1, 8.1), (11.8, 8.1), (13.1, 1.2), (4.0, 1.2)])
        lower.lineWidth = 1.1
        lower.lineJoinStyle = .round
        lower.stroke()

        let handle = NSBezierPath()
        handle.move(to: NSPoint(x: 12.85, y: 13.2))
        handle.curve(to: NSPoint(x: 15.8, y: 12.2), controlPoint1: NSPoint(x: 15.8, y: 14.5), controlPoint2: NSPoint(x: 16.4, y: 13.5))
        handle.line(to: NSPoint(x: 15.1, y: 10.3))
        handle.curve(to: NSPoint(x: 13.7, y: 9.9), controlPoint1: NSPoint(x: 14.7, y: 9.4), controlPoint2: NSPoint(x: 14.0, y: 9.4))
        handle.lineWidth = 1.2
        handle.lineCapStyle = .round
        handle.lineJoinStyle = .round
        handle.stroke()
    }
}
