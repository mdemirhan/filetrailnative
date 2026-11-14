import FTFoundation
import Testing

@Suite struct ImageConversionTests {
    private let portrait = PixelSize(width: 4783, height: 7174)
    private let small = PixelSize(width: 1000, height: 500)

    @Test func actualSizeKeepsEverySize() {
        #expect(ImageConversion.targetSize(portrait, .actual) == portrait)
    }

    @Test func fitWithinShrinksTheLongestSideToTheSize() {
        #expect(ImageConversion.targetSize(portrait, .fitWithin(2048)) == PixelSize(width: 1365, height: 2048))
        #expect(ImageConversion.targetSize(small, .fitWithin(640)) == PixelSize(width: 640, height: 320))
    }

    @Test func fitWithinNeverEnlarges() {
        #expect(ImageConversion.targetSize(small, .fitWithin(3840)) == small)
        #expect(ImageConversion.targetSize(small, .fitWithin(1000)) == small)
    }

    @Test func scaleTakesAPercentageAndStopsAt100() {
        #expect(ImageConversion.targetSize(small, .scale(50)) == PixelSize(width: 500, height: 250))
        #expect(ImageConversion.targetSize(small, .scale(150)) == small)
        #expect(
            ImageConversion.targetSize(PixelSize(width: 3, height: 1), .scale(25)) == PixelSize(width: 1, height: 1))
    }

    // Every picture from 1 to 200 pixels each way, in every kind of size: never past the box nor larger than the
    // picture, at least a pixel each way; a picture made smaller meets its box exactly on one side, and its other side
    // is the nearest whole pixel to its shape. 60 by 80 within 50 is 38 by 50, not 38 by 51.
    @Test func everySizeStaysInsideItsBoxAndKeepsTheShapeToTheNearestPixel() {
        #expect(
            ImageConversion.targetSize(PixelSize(width: 60, height: 80), .fitWithin(50))
                == PixelSize(width: 38, height: 50))
        /// Whether `side` is `numerator / denominator` to the nearest pixel (within half of one), or the least of one.
        func nearest(_ side: Int, _ numerator: Int, _ denominator: Int) -> Bool {
            abs(2 * side * denominator - 2 * numerator) <= denominator || (side == 1 && numerator < denominator)
        }
        var boxes: [(size: ImageSize, width: Int, height: Int)] = [1, 2, 3, 7, 13, 50, 99, 100, 150, 199, 200].map {
            (.fitWithin($0), $0, $0)
        }
        for (width, height) in [(50, 13), (13, 50), (1, 200), (200, 1), (99, 100)] {
            boxes.append((.custom(width: width, height: height, unit: .pixels, proportional: true), width, height))
        }
        let percents = [1, 33, 50, 67, 99, 100]
        let exact = [(1, 1), (50, 100), (200, 200)]
        var wrong: [String] = []
        for width in 1...200 {
            for height in 1...200 {
                let original = PixelSize(width: width, height: height)
                for box in boxes {
                    guard let target = ImageConversion.targetSize(original, box.size) else {
                        wrong.append("\(width)×\(height) \(box.size): none")
                        continue
                    }
                    let fits = width <= box.width && height <= box.height
                    let inside =
                        target.width >= 1 && target.height >= 1 && target.width <= min(box.width, width)
                        && target.height <= min(box.height, height)
                    // Made smaller: the side that meets the box is the box's, the other the nearest to the shape.
                    let shaped =
                        (target.width == box.width && nearest(target.height, height * box.width, width))
                        || (target.height == box.height && nearest(target.width, width * box.height, height))
                    if fits ? target != original : !(inside && shaped) {
                        wrong.append("\(width)×\(height) \(box.size): \(target)")
                    }
                }
                for percent in percents {
                    let target = ImageConversion.targetSize(original, .scale(percent))
                    if let target, target.width <= width, target.height <= height,
                        nearest(target.width, width * percent, 100), nearest(target.height, height * percent, 100)
                    {
                        continue
                    }
                    wrong.append("\(width)×\(height) \(percent)%: \(String(describing: target))")
                }
                for (exactWidth, exactHeight) in exact {
                    let size = ImageSize.custom(
                        width: exactWidth, height: exactHeight, unit: .pixels, proportional: false)
                    let met = exactWidth <= width && exactHeight <= height
                    let target = ImageConversion.targetSize(original, size)
                    if target != (met ? PixelSize(width: exactWidth, height: exactHeight) : nil) {
                        wrong.append(
                            "\(width)×\(height) exactly \(exactWidth)×\(exactHeight): \(String(describing: target))")
                    }
                }
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count): \(wrong.prefix(20))")
    }

    @Test func aProportionalCustomSizeIsABoxEachPictureFitsInside() {
        let box = ImageSize.custom(width: 800, height: 800, unit: .pixels, proportional: true)
        #expect(ImageConversion.targetSize(small, box) == PixelSize(width: 800, height: 400))
        #expect(
            ImageConversion.targetSize(PixelSize(width: 500, height: 1000), box) == PixelSize(width: 400, height: 800))
        #expect(
            ImageConversion.targetSize(PixelSize(width: 600, height: 300), box) == PixelSize(width: 600, height: 300))
    }

    @Test func anExactSizeIsMetOnlyWithoutEnlarging() {
        #expect(
            ImageConversion.targetSize(small, .custom(width: 800, height: 450, unit: .pixels, proportional: false))
                == PixelSize(width: 800, height: 450))
        // Narrower but taller: the height would grow.
        #expect(
            ImageConversion.targetSize(small, .custom(width: 800, height: 600, unit: .pixels, proportional: false))
                == nil)
        #expect(
            ImageConversion.targetSize(small, .custom(width: 1200, height: 400, unit: .pixels, proportional: false))
                == nil)
        #expect(
            ImageConversion.targetSize(small, .custom(width: 1000, height: 500, unit: .pixels, proportional: false))
                == small)
    }

    @Test func customPercentagesStopAt100() {
        #expect(
            ImageConversion.targetSize(small, .custom(width: 40, height: 0, unit: .percent, proportional: true))
                == PixelSize(width: 400, height: 200))
        #expect(
            ImageConversion.targetSize(small, .custom(width: 50, height: 200, unit: .percent, proportional: false))
                == PixelSize(width: 500, height: 500))
    }

    @Test func theOutcomeCountsWhatIsMadeSmallerWhatAlreadyFitsAndWhatIsTooSmall() {
        let sizes = [portrait, small, PixelSize(width: 300, height: 200)]
        #expect(
            ImageConversion.outcome(sizes, .fitWithin(1280))
                == ImageConversion.SizeOutcome(smaller: 1, unchanged: 2, tooSmall: 0))
        #expect(
            ImageConversion.outcome(sizes, .custom(width: 640, height: 400, unit: .pixels, proportional: false))
                == ImageConversion.SizeOutcome(smaller: 2, unchanged: 0, tooSmall: 1))
    }

    @Test func shapesDifferPastAPixelOfRounding() {
        #expect(
            !ImageConversion.shapesDiffer([PixelSize(width: 4000, height: 3000), PixelSize(width: 1024, height: 768)]))
        #expect(
            !ImageConversion.shapesDiffer([PixelSize(width: 1366, height: 2048), PixelSize(width: 1365, height: 2048)]))
        #expect(
            ImageConversion.shapesDiffer([PixelSize(width: 4000, height: 3000), PixelSize(width: 3000, height: 4000)]))
        #expect(!ImageConversion.shapesDiffer([small]))
    }

    @Test func theNewNameKeepsTheStemWithTheFormatsExtension() {
        #expect(ImageConversion.newName(for: "Photo.HEIC", format: .jpeg) == "Photo.jpg")
        #expect(ImageConversion.newName(for: "archive.tar.png", format: .heic) == "archive.tar.heic")
        #expect(ImageConversion.newName(for: "Scan", format: .tiff) == "Scan.tiff")
        #expect(ImageConversion.newName(for: ".hidden", format: .png) == ".hidden.png")
    }

    @Test func onlyWhatImageIOReadsCanBeConverted() {
        for name in ["a.jpg", "b.JPEG", "c.heic", "d.png", "e.webp", "f.cr3", "g.dng", "h.gif", "i.tiff", "j.avif"] {
            #expect(ImageConversion.isConvertible(name: name), "\(name)")
        }
        for name in ["a.svg", "b.pdf", "c.txt", "noextension", "e.mov", ".jpg"] {
            #expect(!ImageConversion.isConvertible(name: name), "\(name)")
        }
    }
}
