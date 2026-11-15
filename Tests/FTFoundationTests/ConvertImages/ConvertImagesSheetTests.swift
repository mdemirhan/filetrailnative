import FTFoundation
import Testing

@Suite struct ConvertImagesSheetTests {
    private let photo = ImageInfo(size: PixelSize(width: 2400, height: 1600))

    private func sheet(
        _ infos: [ImageInfo?], _ edit: (inout ConvertImagesSettings) -> Void = { _ in }
    ) -> ConvertImagesSheet {
        var settings = ConvertImagesSettings.defaults
        edit(&settings)
        return ConvertImagesSheet(settings: settings, count: infos.count, infos: infos)
    }

    // Only the formats this Mac can write are offered; one chosen on another Mac gives way to the first of them.
    @Test func onlyTheFormatsTheMacWritesAreOffered() {
        #expect(sheet([photo]).formats == ImageFormat.allCases)
        let types = ImageFormat.allCases.map(\.typeIdentifier)
        #expect(ImageFormat.formats(amongTypes: types + ["com.example.other"]) == ImageFormat.allCases)
        let withoutAVIF = ImageFormat.formats(amongTypes: types.filter { $0 != "public.avif" })
        #expect(withoutAVIF == [.jpeg, .heic, .png, .tiff])
        #expect(ImageFormat.formats(amongTypes: []) == [])
        // Every Mac writes these.
        #expect(ImageFormat.writableHere.contains(.jpeg) && ImageFormat.writableHere.contains(.png))

        var settings = ConvertImagesSettings.defaults
        settings.format = .avif
        var offered = ConvertImagesSheet(settings: settings, count: 1, infos: [photo], formats: withoutAVIF)
        #expect(offered.formats == withoutAVIF)
        #expect(offered.settings.format == .jpeg)
        offered.choose(format: .avif)
        #expect(offered.settings.format == .jpeg)
        offered.choose(format: .heic)
        #expect(offered.settings.format == .heic)
        // A format it can write stays as chosen.
        settings.format = .tiff
        #expect(ConvertImagesSheet(settings: settings, count: 1, formats: withoutAVIF).settings.format == .tiff)
    }

    @Test func forOneImageTheSizesItAlreadyFitsAreGrayedWithItsSize() {
        let one = sheet([photo])
        #expect(!one.isEnabled(.fitWithin(3840)))
        #expect(!one.isEnabled(.fitWithin(2560)))
        #expect(one.isEnabled(.fitWithin(1920)))
        #expect(one.disabledNote(.fitWithin(2560)) == "This image is 2400 px")
        #expect(one.disabledNote(.fitWithin(1920)) == nil)
        // Several pictures have no one size: every choice is offered.
        #expect(sheet([photo, photo]).isEnabled(.fitWithin(3840)))
    }

    @Test func forOneImageTheSummarySaysTheSizeItBecomes() {
        var one = sheet([photo])
        #expect(one.summary == "2400 \u{00D7} 1600, kept at its size")
        one.choose(size: .fitWithin(1280))
        #expect(one.summary == "2400 \u{00D7} 1600 \u{2192} 1280 \u{00D7} 853")
        #expect(one.canConvert)
    }

    @Test func aCustomSizeLargerThanTheOneImageBecomesItsSizeWithANote() {
        var one = sheet([photo]) { $0.sizeMode = .custom }
        one.type(width: 3000)
        // Proportional: the height follows.
        #expect(one.settings.customHeight == 2000)
        let settled = one.settleCustom()
        #expect(settled)
        #expect(one.settings.customWidth == 2400)
        #expect(one.settings.customHeight == 1600)
        #expect(one.customNote == "At most 2400 \u{00D7} 1600, this image\u{2019}s size")
        one.type(width: 1200)
        #expect(one.customNote == nil)
        #expect(one.settings.customHeight == 800)
    }

    @Test func anExactCustomSizeForOneImageIsBroughtBackEachWay() {
        var one = sheet([photo]) {
            $0.sizeMode = .custom
            $0.proportional = false
        }
        one.type(width: 3000)
        one.type(height: 900)
        one.settleCustom()
        #expect(one.settings.customWidth == 2400)
        #expect(one.settings.customHeight == 900)
    }

    @Test func aPercentageStopsAt100() {
        var one = sheet([photo]) {
            $0.sizeMode = .custom
            $0.customUnit = .percent
            $0.customWidth = 50
            $0.customHeight = 50
        }
        one.type(width: 150)
        one.settleCustom()
        #expect(one.settings.customWidth == 100)
        #expect(one.customNote == "At most 100%")
    }

    @Test func severalImagesSayHowManyAreMadeSmallerAndHowManyAlreadyFit() {
        let small = ImageInfo(size: PixelSize(width: 800, height: 600))
        var several = sheet([photo, photo, small]) { $0.sizeMode = .fitWithin }
        several.choose(size: .fitWithin(1280))
        #expect(several.summary == "3 images: 2 made smaller, 1 already fit and keep their size")
        several.choose(size: .fitWithin(640))
        #expect(several.summary == "3 images, each made smaller")
        several.choose(size: .actual)
        #expect(several.summary == "3 images, each kept at its size")
        several.choose(size: .fitWithin(3840))
        #expect(several.summary == "3 images, all already fit and keep their size")
    }

    @Test func anExactSizeAnyImageIsSmallerThanGraysConvert() {
        let small = ImageInfo(size: PixelSize(width: 800, height: 600))
        let several = sheet([photo, small]) {
            $0.sizeMode = .custom
            $0.proportional = false
            $0.customWidth = 1000
            $0.customHeight = 700
        }
        #expect(!several.canConvert)
        #expect(
            several.warnings.first
                == "1 of the images is smaller than 1000 \u{00D7} 700, and images are never made larger")
    }

    @Test func anExactSizeWarnsWhenTheImagesDifferInShape() {
        let portrait = ImageInfo(size: PixelSize(width: 1600, height: 2400))
        let several = sheet([photo, portrait]) {
            $0.sizeMode = .custom
            $0.proportional = false
            $0.customWidth = 1000
            $0.customHeight = 1000
        }
        #expect(several.canConvert)
        #expect(
            several.warnings
                == ["The images aren\u{2019}t all the same shape, so one exact size stretches them differently"])
        // Kept proportional, each fits the box in its own shape: no warning.
        var proportional = several
        proportional.set(proportional: true)
        #expect(proportional.warnings.isEmpty)
    }

    @Test func untilTheSizesAreReadOnlyTheActualSizeCanConvert() {
        var reading = ConvertImagesSheet(settings: .defaults, count: 2)
        #expect(reading.isReading)
        #expect(reading.canConvert)
        reading.choose(size: .fitWithin(1280))
        #expect(!reading.canConvert)
        #expect(reading.summary == "Reading the images\u{2019} sizes\u{2026}")
        reading.read([photo, photo])
        #expect(reading.canConvert)
    }

    // A custom size kept from a batch of large photos is made to fit one small picture while it is converted, and
    // is still the one remembered afterwards; edited in the sheet, what was typed is remembered.
    @Test func aCustomSizeShrunkToFitOnePictureIsRememberedAsItWas() {
        let small = ImageInfo(size: PixelSize(width: 800, height: 600))
        var one = sheet([small]) {
            $0.sizeMode = .custom
            $0.customUnit = .pixels
            $0.proportional = true
            $0.customWidth = 1920
            $0.customHeight = 1080
        }
        #expect(one.settings.customWidth == 800 && one.settings.customHeight == 450)
        #expect(one.settingsToRemember.customWidth == 1920 && one.settingsToRemember.customHeight == 1080)
        #expect(one.options.size == one.settings.size)
        // Another mode chosen and Custom again: still as it was.
        one.choose(size: .actual)
        one.choose(size: .custom)
        #expect(one.settingsToRemember.customWidth == 1920)
        #expect(one.settingsToRemember.sizeMode == .custom)
        // Typed, the new size is the one to remember.
        one.type(width: 400)
        #expect(one.settingsToRemember == one.settings)
        #expect(one.settings.customWidth == 400 && one.settings.customHeight == 300)

        // A size that already fits is remembered as it is.
        let fits = sheet([photo]) {
            $0.sizeMode = .custom
            $0.customUnit = .pixels
            $0.customWidth = 1200
            $0.customHeight = 800
        }
        #expect(fits.settingsToRemember == fits.settings)
    }

    // With nothing that can be read as a picture there is nothing to convert.
    @Test func convertIsOffWhenNoneOfThemIsAPicture() {
        let none = sheet([nil, nil, nil])
        #expect(!none.canConvert)
        #expect(none.summary == "None of them can be opened as an image.")
        #expect(none.warnings.isEmpty)
        let one = sheet([nil])
        #expect(!one.canConvert)
        #expect(one.summary == "It can\u{2019}t be opened as an image.")
        // One that can be read is enough.
        let some = sheet([nil, photo])
        #expect(some.canConvert)
        #expect(some.warnings == ["1 of them can\u{2019}t be opened as an image"])
    }

    @Test func theNotesSayWhatTheFormatLosesOfThesePictures() {
        let clear = ImageInfo(size: PixelSize(width: 10, height: 10), hasAlpha: true)
        let bright = ImageInfo(size: PixelSize(width: 10, height: 10), hasGainMap: true)
        let moving = ImageInfo(size: PixelSize(width: 10, height: 10), frameCount: 12)
        var notes = sheet([clear, bright, moving])
        #expect(
            notes.notes == [
                "JPEG has no transparency: transparent parts become white.",
                "Of an animation, or a file of several pages, only the first is converted.",
            ])
        notes.choose(format: .png)
        #expect(
            notes.notes == [
                "PNG keeps no HDR: HDR photos are saved in standard range.",
                "Of an animation, or a file of several pages, only the first is converted.",
            ])
    }

    @Test func withoutMetadataTheLocationGoesToo() {
        var one = sheet([photo])
        #expect(!one.removesLocation)
        one.set(keepMetadata: false)
        #expect(one.removesLocation)
        #expect(one.options.removeLocation == false)
        #expect(one.options.keepMetadata == false)
        one.set(keepMetadata: true)
        one.set(removeLocation: true)
        #expect(one.options.removeLocation)
    }

    @Test func theSavedSettingsAreReadLeniently() {
        #expect(ConvertImagesSettings.sanitize(nil) == .defaults)
        let read = ConvertImagesSettings.sanitize(
            .object([
                "format": .string("avif"), "quality": .number(0.6), "sizeMode": .string("custom"),
                "fitWithin": .number(1234), "scale": .number(25), "customWidth": .number(800),
                "customHeight": .number(-5), "customUnit": .string("pixels"), "proportional": .bool(false),
                "keepMetadata": .string("yes"), "removeLocation": .bool(true),
            ]))
        #expect(read.format == .avif)
        #expect(read.quality == 0.6)
        #expect(read.sizeMode == .custom)
        // Only the sizes the pop-up offers.
        #expect(read.fitWithin == ConvertImagesSettings.defaults.fitWithin)
        #expect(read.scale == 25)
        #expect(read.customWidth == 800)
        #expect(read.customHeight == ConvertImagesSettings.defaults.customHeight)
        #expect(!read.proportional)
        #expect(read.keepMetadata)
        #expect(read.removeLocation)
    }

    @Test func theMenusCountWhatTheyWouldConvert() {
        #expect(ConvertImagesText.menuTitle(count: 1) == "Convert Image\u{2026}")
        #expect(ConvertImagesText.menuTitle(count: 3) == "Convert 3 Images\u{2026}")
        #expect(ConvertImagesText.menuTitle(count: 0) == "Convert Images\u{2026}")
    }

    @Test func onlyASelectionOfImagesCanBeConverted() {
        #expect(ImageConversion.canConvert([CommandEntry(path: "/a/b.jpg", kind: .file)]))
        #expect(ImageConversion.canConvert([CommandEntry(path: "/a/b.jpg", kind: .symlinkFile)]))
        #expect(
            !ImageConversion.canConvert([
                CommandEntry(path: "/a/b.jpg", kind: .file), CommandEntry(path: "/a/c.txt", kind: .file),
            ]))
        #expect(!ImageConversion.canConvert([CommandEntry(path: "/a/photos.png", kind: .directory)]))
        #expect(!ImageConversion.canConvert([]))
    }
}
