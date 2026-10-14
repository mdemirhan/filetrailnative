// Port of the SVG path drawing the original's icons rely on (apps/desktop/src/renderer/components/ToolbarIcon.tsx):
// a parser for the path data its icons use
import AppKit

/// Reads SVG path data (`M L H V C S A Z`, absolute and relative) into an `NSBezierPath`, in the path's own
/// coordinates (y down, as in SVG).
enum SVGPath {
    static func path(_ data: String) -> NSBezierPath {
        var scanner = Scanner(Array(data.utf8))
        let path = NSBezierPath()
        var current = NSPoint.zero
        var start = NSPoint.zero
        var lastControl: NSPoint?
        var command: UInt8 = 0
        while let next = scanner.command(continuing: command) {
            command = next
            let relative = command >= 97
            func point(_ x: Double, _ y: Double) -> NSPoint {
                relative ? NSPoint(x: current.x + x, y: current.y + y) : NSPoint(x: x, y: y)
            }
            var control: NSPoint?
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y)
                start = current
                path.move(to: current)
                // Further pairs after a moveto are linetos.
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y)
                path.line(to: current)
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current = NSPoint(x: relative ? current.x + x : x, y: current.y)
                path.line(to: current)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current = NSPoint(x: current.x, y: relative ? current.y + y : y)
                path.line(to: current)
            case UInt8(ascii: "c"):
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x2 = scanner.number(),
                    let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number()
                else { return path }
                let first = point(x1, y1)
                let second = point(x2, y2)
                current = point(x, y)
                path.curve(to: current, controlPoint1: first, controlPoint2: second)
                control = second
            case UInt8(ascii: "s"):
                guard let x2 = scanner.number(), let y2 = scanner.number(), let x = scanner.number(),
                    let y = scanner.number()
                else { return path }
                let first =
                    lastControl.map { NSPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let second = point(x2, y2)
                current = point(x, y)
                path.curve(to: current, controlPoint1: first, controlPoint2: second)
                control = second
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                    let large = scanner.flag(), let sweep = scanner.flag(), let x = scanner.number(),
                    let y = scanner.number()
                else { return path }
                let end = point(x, y)
                arc(path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end
            case UInt8(ascii: "z"):
                path.close()
                current = start
            default:
                return path
            }
            lastControl = control
        }
        return path
    }

    /// An elliptical arc as cubic curves (SVG implementation notes, F.6.5).
    private static func arc(
        _ path: NSBezierPath, from p0: NSPoint, to p1: NSPoint, rx rx0: Double, ry ry0: Double, rotation: Double,
        large: Bool, sweep: Bool
    ) {
        var rx = abs(rx0)
        var ry = abs(ry0)
        guard rx > 0, ry > 0, p0 != p1 else {
            path.line(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2
        let dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = (max(0, numerator) / denominator).squareRoot()
        if large == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry
        let cy1 = -factor * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let sign: Double = ux * vy - uy * vx < 0 ? -1 : 1
            let dot = ux * vx + uy * vy
            let length = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
            return sign * acos(max(-1, min(1, dot / length)))
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        func onEllipse(_ t: Double) -> (point: NSPoint, dx: Double, dy: Double) {
            let x = rx * cos(t)
            let y = ry * sin(t)
            let tx = -rx * sin(t)
            let ty = ry * cos(t)
            return (
                NSPoint(x: cosPhi * x - sinPhi * y + cx, y: sinPhi * x + cosPhi * y + cy),
                cosPhi * tx - sinPhi * ty, sinPhi * tx + cosPhi * ty
            )
        }
        var t = theta1
        for _ in 0..<segments {
            let a = onEllipse(t)
            let b = onEllipse(t + step)
            path.curve(
                to: b.point, controlPoint1: NSPoint(x: a.point.x + k * a.dx, y: a.point.y + k * a.dy),
                controlPoint2: NSPoint(x: b.point.x - k * b.dx, y: b.point.y - k * b.dy))
            t += step
        }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSeparators() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x2C || bytes[index] == 0x0A {
                index += 1
            }
        }

        /// The next command letter, or `previous` again when numbers follow (an implicit repeat).
        mutating func command(continuing previous: UInt8) -> UInt8? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            if (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) {
                index += 1
                return byte
            }
            return previous == 0 ? nil : previous
        }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < bytes.count, bytes[index] == 0x30 || bytes[index] == 0x31 else { return nil }
            index += 1
            return bytes[index - 1] == 0x31
        }

        mutating func number() -> Double? {
            skipSeparators()
            let begin = index
            if index < bytes.count, bytes[index] == 0x2D || bytes[index] == 0x2B { index += 1 }
            var seenDot = false
            var seenDigit = false
            while index < bytes.count {
                let byte = bytes[index]
                if byte >= 0x30 && byte <= 0x39 {
                    seenDigit = true
                } else if byte == 0x2E && !seenDot {
                    seenDot = true
                } else {
                    break
                }
                index += 1
            }
            guard seenDigit, let text = String(bytes: bytes[begin..<index], encoding: .ascii) else {
                index = begin
                return nil
            }
            return Double(text)
        }
    }
}
