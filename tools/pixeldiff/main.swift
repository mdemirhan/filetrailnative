// Per-region perceptual difference of two window captures; no TypeScript source.
//
// Usage: pixeldiff <a.png> <b.png> --out <dir> [--mask masks.json] [--regions regions.json]
//                  [--points WxH] [--threshold ΔE] [--no-default-masks]
//
// Both images are scaled (CoreImage) to the same size, `--points` at 2× (by default the size of
// <a> at 2×), flattened on white, and compared pixel by pixel as CIE76 ΔE in Lab. Masked rects
// (points, top-left origin) don't count. Writes <out>/heat.png and <out>/pixeldiff.json, whose
// `score` per region is the fraction of its pixels that differ by more than the threshold.
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Rect: Codable {
    var name: String?
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct RegionScore: Codable {
    var name: String
    var rect: Rect
    var score: Double
    var meanDeltaE: Double
    var maxDeltaE: Double
    var pixels: Int
}

struct Output: Codable {
    var a: String
    var b: String
    var points: Rect
    var threshold: Double
    var masks: [Rect]
    var overall: RegionScore
    var regions: [RegionScore]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pixeldiff: \(message)\n".utf8))
    exit(2)
}

var positional: [String] = []
var options: [String: String] = [:]
var flags: Set<String> = []
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    if argument == "--no-default-masks" {
        flags.insert(argument)
    } else if argument.hasPrefix("--") {
        guard let value = arguments.next() else { fail("\(argument) needs a value") }
        options[argument] = value
    } else {
        positional.append(argument)
    }
}
guard positional.count == 2, let outDir = options["--out"] else {
    fail("usage: pixeldiff <a.png> <b.png> --out <dir> [--mask f] [--regions f] [--points WxH] [--threshold n]")
}
let threshold = Double(options["--threshold"] ?? "5") ?? 5

func loadImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("could not read \(path)") }
    return image
}

func loadRects(_ path: String?) -> [Rect] {
    guard let path else { return [] }
    guard let data = FileManager.default.contents(atPath: path),
        let rects = try? JSONDecoder().decode([Rect].self, from: data)
    else { fail("could not read rects from \(path)") }
    return rects
}

let imageA = loadImage(positional[0])
let imageB = loadImage(positional[1])
var pointSize = CGSize(width: Double(imageA.width) / 2, height: Double(imageA.height) / 2)
if let text = options["--points"] {
    let parts = text.split(separator: "x").compactMap { Double($0) }
    guard parts.count == 2 else { fail("--points takes WxH") }
    pointSize = CGSize(width: parts[0], height: parts[1])
}
let width = Int(pointSize.width * 2)
let height = Int(pointSize.height * 2)

let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
let context = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])

/// RGBA8 pixels, top row first, scaled to width × height and flattened on white.
func pixels(of image: CGImage) -> [UInt8] {
    var scaled = CIImage(cgImage: image)
    if image.width != width || image.height != height {
        let sx = Double(width) / Double(image.width)
        let sy = Double(height) / Double(image.height)
        let scale = CIFilter(name: "CILanczosScaleTransform")
        scale?.setValue(scaled, forKey: kCIInputImageKey)
        scale?.setValue(sy, forKey: kCIInputScaleKey)
        scale?.setValue(sx / sy, forKey: kCIInputAspectRatioKey)
        scaled = (scale?.outputImage ?? scaled).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }
    let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    let flat = scaled.composited(over: white)
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    buffer.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        // Rendered to a bitmap, row 0 is the image's top.
        context.render(
            flat, toBitmap: base, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8, colorSpace: srgb)
    }
    return buffer
}

/// sRGB (0…255) to CIE Lab (D65).
func lab(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (Double, Double, Double) {
    func linear(_ value: UInt8) -> Double {
        let c = Double(value) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    let (lr, lg, lb) = (linear(r), linear(g), linear(b))
    let x = (lr * 0.4124 + lg * 0.3576 + lb * 0.1805) / 0.95047
    let y = lr * 0.2126 + lg * 0.7152 + lb * 0.0722
    let z = (lr * 0.0193 + lg * 0.1192 + lb * 0.9505) / 1.08883
    func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
    let (fx, fy, fz) = (f(x), f(y), f(z))
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
}

let a = pixels(of: imageA)
let b = pixels(of: imageB)

var masks: [Rect] = []
if !flags.contains("--no-default-masks") {
    // The traffic lights (drawn by macOS over the original's page, by AppKit in the native window)
    // and the overlay scroller at the window's right edge.
    masks.append(Rect(name: "traffic lights", x: 0, y: 0, width: 90, height: 52))
    masks.append(Rect(name: "scroller", x: pointSize.width - 16, y: 0, width: 16, height: pointSize.height))
}
masks += loadRects(options["--mask"])

var masked = [Bool](repeating: false, count: width * height)
for mask in masks {
    let x0 = max(0, Int(mask.x * 2))
    let y0 = max(0, Int(mask.y * 2))
    let x1 = min(width, Int(((mask.x + mask.width) * 2).rounded(.up)))
    let y1 = min(height, Int(((mask.y + mask.height) * 2).rounded(.up)))
    guard x0 < x1, y0 < y1 else { continue }
    for y in y0..<y1 { for x in x0..<x1 { masked[y * width + x] = true } }
}

var delta = [Double](repeating: 0, count: width * height)
for index in 0..<(width * height) where !masked[index] {
    let o = index * 4
    if a[o] == b[o], a[o + 1] == b[o + 1], a[o + 2] == b[o + 2] { continue }
    let (l1, a1, b1) = lab(a[o], a[o + 1], a[o + 2])
    let (l2, a2, b2) = lab(b[o], b[o + 1], b[o + 2])
    delta[index] = ((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2)).squareRoot()
}

@MainActor func score(_ region: Rect) -> RegionScore {
    let x0 = max(0, Int(region.x * 2))
    let y0 = max(0, Int(region.y * 2))
    let x1 = min(width, Int(((region.x + region.width) * 2).rounded(.up)))
    let y1 = min(height, Int(((region.y + region.height) * 2).rounded(.up)))
    var count = 0
    var over = 0
    var sum = 0.0
    var worst = 0.0
    if x0 < x1, y0 < y1 {
        for y in y0..<y1 {
            for x in x0..<x1 where !masked[y * width + x] {
                let value = delta[y * width + x]
                count += 1
                sum += value
                worst = max(worst, value)
                if value > threshold { over += 1 }
            }
        }
    }
    func round(_ value: Double) -> Double { (value * 10000).rounded() / 10000 }
    return RegionScore(
        name: region.name ?? "region", rect: region, score: count == 0 ? 0 : round(Double(over) / Double(count)),
        meanDeltaE: count == 0 ? 0 : round(sum / Double(count)), maxDeltaE: round(worst), pixels: count)
}

let whole = Rect(name: "window", x: 0, y: 0, width: pointSize.width, height: pointSize.height)
let regions = loadRects(options["--regions"]).map(score)

// Heat map: <a> faded to gray, differences in red to yellow, masks in blue.
var heat = [UInt8](repeating: 255, count: width * height * 4)
for index in 0..<(width * height) {
    let o = index * 4
    let gray = (0.3 * Double(a[o]) + 0.59 * Double(a[o + 1]) + 0.11 * Double(a[o + 2])) * 0.35 + 255 * 0.65
    var (r, g, bl) = (gray, gray, gray)
    if masked[index] {
        (r, g, bl) = (gray * 0.8, gray * 0.85, 255)
    } else if delta[index] > threshold {
        let t = min(1, delta[index] / 40)
        (r, g, bl) = (255, 210 * (1 - t) + 20, 20)
    } else if delta[index] > 0 {
        (r, g, bl) = (gray, gray * 0.92, gray * 0.85)
    }
    heat[o] = UInt8(r)
    heat[o + 1] = UInt8(g)
    heat[o + 2] = UInt8(bl)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let heatURL = URL(fileURLWithPath: outDir).appendingPathComponent("heat.png")
heat.withUnsafeMutableBytes { raw in
    guard let bitmap = CGContext(
        data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
        let image = bitmap.makeImage(),
        let destination = CGImageDestinationCreateWithURL(heatURL as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("could not write \(heatURL.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    if !CGImageDestinationFinalize(destination) { fail("could not write \(heatURL.path)") }
}

let output = Output(
    a: positional[0], b: positional[1], points: whole, threshold: threshold, masks: masks, overall: score(whole),
    regions: regions)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
do {
    try encoder.encode(output).write(to: URL(fileURLWithPath: outDir).appendingPathComponent("pixeldiff.json"))
} catch {
    fail("could not write pixeldiff.json: \(error)")
}
print(String(format: "pixels: %.4f (mean ΔE %.2f)", output.overall.score, output.overall.meanDeltaE))
