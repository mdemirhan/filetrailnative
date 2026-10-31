// The demo project's photos for the README: a landscape for each .jpg in the folder given, and a contact sheet for its
// PDF. Each file keeps its date. Run by scripts/readme-screenshots.sh on its copy of the project.
import AppKit

let palettes: [[(Double, Double, Double)]] = [
    [(0.53, 0.72, 0.86), (0.72, 0.84, 0.88), (0.47, 0.60, 0.66), (0.28, 0.45, 0.50), (0.10, 0.42, 0.50)],
    [(0.32, 0.20, 0.45), (0.93, 0.45, 0.42), (0.55, 0.30, 0.48), (0.35, 0.20, 0.38), (0.16, 0.12, 0.22)],
    [(0.95, 0.85, 0.72), (0.98, 0.90, 0.78), (0.78, 0.68, 0.62), (0.60, 0.52, 0.50), (0.22, 0.20, 0.26)],
    [(0.20, 0.62, 0.78), (0.45, 0.80, 0.82), (0.33, 0.66, 0.58), (0.20, 0.55, 0.50), (0.05, 0.52, 0.68)],
    [(0.05, 0.07, 0.22), (0.12, 0.14, 0.34), (0.10, 0.11, 0.30), (0.07, 0.08, 0.22), (0.02, 0.03, 0.10)],
    [(0.40, 0.14, 0.26), (0.96, 0.52, 0.28), (0.70, 0.30, 0.22), (0.45, 0.20, 0.18), (0.20, 0.09, 0.08)],
    [(0.62, 0.68, 0.72), (0.80, 0.83, 0.84), (0.55, 0.60, 0.63), (0.40, 0.46, 0.50), (0.30, 0.42, 0.46)],
]
func color(_ c: (Double, Double, Double)) -> NSColor { NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1) }

func landscape(seed: Int) -> Data? {
    let width = 1200, height = 800
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let palette = palettes[seed % palettes.count]
    NSGradient(starting: color(palette[1]), ending: color(palette[0]))?
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)
    let sunX = 250 + Double(seed * 137 % 700), sunY = 470 + Double(seed * 53 % 180)
    NSColor.white.withAlphaComponent(0.85).setFill()
    NSBezierPath(ovalIn: NSRect(x: sunX - 26, y: sunY - 26, width: 52, height: 52)).fill()
    for layer in 0..<3 {
        let base = 430 - Double(layer) * 90
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        for x in stride(from: 0, through: width, by: 8) {
            let t = Double(x) / 170
            let s = Double(seed * 7 + layer * 13)
            let ridge = abs(sin(t * 0.8 + s)) * 120 + sin(t * 2.3 + s * 1.7) * 40 + sin(t * 5.1 + s) * 14
            path.line(to: NSPoint(x: Double(x), y: base + ridge * (1 - Double(layer) * 0.22)))
        }
        path.line(to: NSPoint(x: width, y: 0))
        path.close()
        color(palette[layer + 2 > 3 ? 3 : layer + 2]).setFill()
        path.fill()
    }
    color(palette[4]).setFill()
    NSRect(x: 0, y: 0, width: width, height: 130).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
}

func contactSheet() -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let consumer = CGDataConsumer(data: data), let pdf = CGContext(consumer: consumer, mediaBox: &box, nil)
    else { return Data() }
    pdf.beginPDFPage(nil)
    pdf.setFillColor(NSColor(white: 0.14, alpha: 1).cgColor)
    pdf.fill(CGRect(x: 0, y: 500, width: 612, height: 292))
    pdf.setFillColor(NSColor.white.cgColor)
    pdf.fill(CGRect(x: 50, y: 700, width: 300, height: 34))
    pdf.setFillColor(NSColor(white: 0.7, alpha: 1).cgColor)
    pdf.fill(CGRect(x: 50, y: 670, width: 180, height: 12))
    pdf.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
    for row in 0..<9 { pdf.fill(CGRect(x: 50, y: 430 - row * 42, width: 512, height: 14)) }
    pdf.endPDFPage()
    pdf.closePDF()
    return data as Data
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
func replace(_ name: String, with data: Data?) throws {
    guard let data else { return }
    let file = folder.appendingPathComponent(name)
    let date = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]
    try data.write(to: file)
    try FileManager.default.setAttributes([.modificationDate: date as Any], ofItemAtPath: file.path)
}
for (index, name) in files.enumerated() where name.hasSuffix(".jpg") {
    try replace(name, with: landscape(seed: index + 1))
}
for name in files where name.hasSuffix(".pdf") { try replace(name, with: contactSheet()) }
