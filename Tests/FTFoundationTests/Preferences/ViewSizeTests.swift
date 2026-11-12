import Testing

@testable import FTFoundation

struct ViewSizeTests {
    static func size(_ mode: ExplorerViewMode, _ value: Int, density: Density = .standard) -> ViewSize? {
        let sizes = DensitySizes(standard: value, finder: value)
        return ViewSize.of(mode, density: density, iconSizes: sizes, compactListWidths: sizes)
    }

    // Icons go in steps of 8, from 32 to 128, and back to 64.
    @Test func stepsTheIconSizeBy8() throws {
        let icons = try #require(Self.size(.icons, 64))
        #expect(icons.bigger == 72 && icons.smaller == 56 && icons.stepped(.reset) == 64)
        #expect(icons.steps == ViewSize.Steps(bigger: true, smaller: true, reset: false))
        let largest = try #require(Self.size(.icons, 128))
        #expect(largest.bigger == 128 && largest.smaller == 120)
        #expect(largest.steps == ViewSize.Steps(bigger: false, smaller: true, reset: true))
        let smallest = try #require(Self.size(.icons, 32))
        #expect(smallest.smaller == 32 && smallest.bigger == 40)
        #expect(smallest.steps == ViewSize.Steps(bigger: true, smaller: false, reset: true))
    }

    // Columns go to the next whole 40 points, from 160 to 600; the default is not on a step, so the first step from it
    // is shorter.
    @Test func stepsTheColumnWidthToWhole40s() throws {
        let columns = try #require(Self.size(.list, 292))
        #expect(columns.bigger == 320 && columns.smaller == 280)
        #expect(columns.steps == ViewSize.Steps(bigger: true, smaller: true, reset: false))
        let onAStep = try #require(Self.size(.list, 320))
        #expect(onAStep.bigger == 360 && onAStep.smaller == 280 && onAStep.stepped(.reset) == 292)
        let nearTheTop = try #require(Self.size(.list, 590))
        #expect(nearTheTop.bigger == 600)
        let nearTheBottom = try #require(Self.size(.list, 170))
        #expect(nearTheBottom.smaller == 160)
        let finder = try #require(Self.size(.list, 400, density: .finder))
        #expect(finder.defaultValue == 252 && finder.stepped(.reset) == 252)
    }

    // The List has no size; its commands are dimmed.
    @Test func theListHasNoSize() {
        #expect(Self.size(.details, 64) == nil)
        for command in [AppCommand.increaseSize, .decreaseSize, .resetSize] {
            let list = CommandAvailabilityContext(viewSizeSteps: .unavailable)
            #expect(!CommandAvailability.canRun(command, list))
            // Unknown: on, as the other commands are.
            #expect(CommandAvailability.canRun(command, CommandAvailabilityContext()))
        }
        let atTheTop = CommandAvailabilityContext(
            viewSizeSteps: ViewSize.Steps(bigger: false, smaller: true, reset: true))
        #expect(!CommandAvailability.canRun(.increaseSize, atTheTop))
        #expect(CommandAvailability.canRun(.decreaseSize, atTheTop))
        #expect(CommandAvailability.canRun(.resetSize, atTheTop))
    }

    @Test func eachSizeCommandMakesItsChange() {
        #expect(ViewSize.Change(.increaseSize) == .bigger)
        #expect(ViewSize.Change(.decreaseSize) == .smaller)
        #expect(ViewSize.Change(.resetSize) == .reset)
        #expect(ViewSize.Change(.viewAsIcons) == nil)
    }
}
