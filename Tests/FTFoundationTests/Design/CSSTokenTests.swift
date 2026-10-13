import Foundation
import Testing

@testable import FTFoundation

/// Every custom property of the reference stylesheet, in both themes, has a Swift counterpart
/// with an equal value. The names are mapped in this file only:
///  - theme colours, shadows and the pressed brightness are `ThemePalette` properties named by
///    camel-casing the token (`--bg-base` is `bgBase`);
///  - accent-derived tokens, fixed sizes and fonts are listed in `accentValues` and `designValues`;
///  - anything else must be in `notUsed`, with the reason the native UI does not need it.
@Suite struct CSSTokenTests {
    private typealias Theme = [String: [String: Any]]

    // MARK: The mapping table

    /// Tokens the native UI has no use for.
    private static let notUsed: [String: String] = {
        var table = [
            "--bg-active": "stale violet default; the accent's activeBg replaces it at run time",
            "--crumb-active-bg": "stale default; the accent's activeBg replaces it at run time",
        ]
        for layer in ["below", "raised", "sticky", "toolbar", "float", "notification", "menu", "modal", "drag", "tooltip"] {
            table["--z-\(layer)"] = "CSS stacking order; AppKit orders views and windows itself"
        }
        return table
    }()

    private static func px(_ value: Double) -> String { formatCSSNumber(value) + "px" }
    private static func ms(_ value: Double) -> String { formatCSSNumber(value) + "ms" }

    /// Theme-independent tokens, as the string the stylesheet resolves them to.
    private static var designValues: [String: String] {
        let type = DesignTokens.typeScale
        let radii = DesignTokens.radii
        let heights = DesignTokens.controlHeights
        let motion = DesignTokens.motion
        return [
            "--font-sans": DesignTokens.sansFontStack,
            "--font-mono": DesignTokens.monoFontStack,
            "--font-size-mini": px(type.mini),
            "--font-size-small": px(type.small),
            "--font-size-callout": px(type.callout),
            "--font-size-body": px(type.body),
            "--font-size-name": px(type.name),
            "--font-size-title3": px(type.title3),
            "--font-size-title2": px(type.title2),
            "--font-size-title1": px(type.title1),
            "--mono-font-size": px(type.mono),
            "--radius-xs": px(radii.xs),
            "--radius-control": px(radii.control),
            "--radius-menu": px(radii.menu),
            "--radius-dialog": px(radii.dialog),
            "--radius-capsule": px(radii.capsule),
            "--control-height-small": px(heights.small),
            "--control-height": px(heights.regular),
            "--control-height-large": px(heights.large),
            "--duration-fast": ms(motion.fast),
            "--duration-base": ms(motion.base),
            "--duration-slow": ms(motion.slow),
            "--duration-flash": ms(motion.flash),
            "--duration-flash-slow": ms(motion.flashSlow),
            "--duration-spin": ms(motion.spin),
            "--ease-standard": "cubic-bezier(\(formatCSSNumber(motion.easing.x1)), \(formatCSSNumber(motion.easing.y1)), "
                + "\(formatCSSNumber(motion.easing.x2)), \(formatCSSNumber(motion.easing.y2)))",
            "--disabled-opacity": formatCSSNumber(DesignTokens.disabledOpacity),
            "--pane-header-height": px(DesignTokens.paneHeaderHeight),
            "--breadcrumb-row-height": px(DesignTokens.breadcrumbRowHeight),
            "--settings-sidebar-width": px(DesignTokens.settingsSidebarWidth),
            "--settings-popup-min-width": px(DesignTokens.settingsPopupMinWidth),
        ]
    }

    /// Tokens that follow the accent. The stylesheet's own values are the default accent's, in
    /// the light theme's alphas, in both themes; the Rename marks differ by theme.
    private static func accentValues(_ appearance: ThemeAppearance) -> [String: String] {
        let accent = AccentPalette(hex: AccentPalette.defaultHex, appearance: .light)
        let themed = AccentPalette(hex: AccentPalette.defaultHex, appearance: appearance)
        let fieldEdge = ThemePalette.palette(for: appearance).fieldEdge
        return [
            "--ft-accent-solid": accent.solid.cssString,
            "--ft-accent-solid-dark": accent.solidDark.cssString,
            "--ft-accent-solid-button": accent.solidButton.cssString,
            "--ft-accent-on-solid": accent.onSolid.cssString,
            "--ft-accent-border": accent.border.cssString,
            "--ft-accent-soft-bg": accent.softBg.cssString,
            "--ft-accent-hero-icon-bg": accent.heroIconBg.cssString,
            "--ft-accent-path-crumb-hover": accent.pathCrumbHover.cssString,
            "--ft-accent-action-hover-bg": accent.actionHoverBg.cssString,
            "--ft-accent-search-pill-border": accent.searchPillBorder.cssString,
            "--ft-accent-location-ring": accent.locationRing.cssString,
            "--ft-accent-ring-soft": accent.ringSoft.cssString,
            "--get-info-hero-icon-bg": accent.heroIconBg.cssString,
            "--get-info-action-bg-hover": accent.actionHoverBg.cssString,
            "--get-info-action-icon-hover": accent.pathCrumbHover.cssString,
            "--get-info-action-text-hover": accent.pathCrumbHover.cssString,
            "--search-border-active": accent.solid.cssString,
            "--search-caret": accent.solid.cssString,
            "--search-icon-active": accent.solid.cssString,
            "--search-shadow-active": "0 0 0 1px \(accent.ringSoft.cssString)",
            "--focus-ring": accent.focusRing.cssString,
            "--field-focus": fieldEdge.cssString + ", " + accent.focusRing.cssString,
            "--batch-rename-mark-text": themed.batchRenameMarkText.cssString,
            "--batch-rename-mark-bg": themed.batchRenameMarkBg.cssString,
        ]
    }

    // MARK: Helpers

    private static func camelCase(_ token: String) -> String {
        var result = ""
        var upper = false
        for ch in token.dropFirst(2) {
            if ch == "-" {
                upper = true
            } else {
                result += upper ? ch.uppercased() : String(ch)
                upper = false
            }
        }
        return result
    }

    private static func themeTokens(_ name: String) throws -> Theme {
        let golden = try GoldenFile.json("css-tokens.json")
        return try #require(golden[name] as? Theme)
    }

    private static func resolved(_ token: [String: Any]) -> String? { token["value"] as? String }

    private static func paletteProperties(_ appearance: ThemeAppearance) -> [String: Any] {
        var properties: [String: Any] = [:]
        for child in Mirror(reflecting: ThemePalette.palette(for: appearance)).children {
            if let label = child.label { properties[label] = child.value }
        }
        return properties
    }

    // MARK: Tests

    @Test(arguments: ThemeAppearance.allCases)
    func everyTokenHasAnEqualSwiftCounterpart(appearance: ThemeAppearance) throws {
        let tokens = try Self.themeTokens(appearance.rawValue)
        #expect(tokens.count > 100)
        let properties = Self.paletteProperties(appearance)
        let design = Self.designValues
        let accent = Self.accentValues(appearance)

        var failures: [String] = []
        for (name, token) in tokens.sorted(by: { $0.key < $1.key }) {
            guard let expected = Self.resolved(token) else {
                failures.append("\(name): unresolved in the golden (\(token["raw"] ?? "")); resolve it or list it")
                continue
            }
            if Self.notUsed[name] != nil { continue }
            if let value = design[name] ?? accent[name] {
                if value != expected { failures.append("\(name): expected \(expected), Swift has \(value)") }
                continue
            }
            guard let property = properties[Self.camelCase(name)] else {
                failures.append("\(name): no Swift counterpart (value \(expected))")
                continue
            }
            switch property {
            case let color as RGBA:
                if RGBA(css: expected) != color {
                    failures.append("\(name): expected \(expected), Swift has \(color.cssString)")
                }
            case let shadows as [ShadowLayer]:
                if shadows.cssString != expected {
                    failures.append("\(name): expected \(expected), Swift has \(shadows.cssString)")
                }
            case let brightness as Double:
                if "brightness(\(formatCSSNumber(brightness)))" != expected {
                    failures.append("\(name): expected \(expected), Swift has brightness(\(brightness))")
                }
            default:
                failures.append("\(name): Swift property has unexpected type \(type(of: property))")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) failures: \(failures.prefix(10))")
    }

    @Test func mappingTablesHaveNoStaleEntries() throws {
        let light = try Self.themeTokens("light")
        let dark = try Self.themeTokens("dark")
        let names = Set(light.keys).union(dark.keys)
        #expect(Set(light.keys) == Set(dark.keys))
        for name in Self.notUsed.keys { #expect(names.contains(name), "unused entry \(name) is not in the golden") }
        for name in Self.designValues.keys { #expect(names.contains(name), "design entry \(name) is not in the golden") }
        for name in Self.accentValues(.light).keys { #expect(names.contains(name), "accent entry \(name) is not in the golden") }
        // Every palette property is a real token, so a rename in the golden cannot leave dead code.
        let camelNames = Set(names.map(Self.camelCase))
        for label in Self.paletteProperties(.light).keys {
            #expect(camelNames.contains(label), "ThemePalette.\(label) is not a token")
        }
    }

    @Test func reducedMotionZeroesTheThreeDurations() throws {
        let golden = try GoldenFile.json("css-tokens.json")
        let reduced = try #require(golden["reducedMotion"] as? [String: String])
        let motion = Motion.reduced
        #expect(reduced["--duration-fast"] == Self.ms(motion.fast))
        #expect(reduced["--duration-base"] == Self.ms(motion.base))
        #expect(reduced["--duration-slow"] == Self.ms(motion.slow))
        #expect(reduced.count == 3)
        #expect(motion.flash == DesignTokens.motion.flash && motion.spin == DesignTokens.motion.spin)
    }

    @Test func spacingScaleAndTypeScaleMatchTheInventory() {
        #expect(DesignTokens.spacing == [2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 28])
        #expect(DesignTokens.controlHeights.toolbar == 32)
    }

    @Test func inventoryColourTableSpotChecks() {
        let light = ThemePalette.light
        let dark = ThemePalette.dark
        #expect(light.bgBase.cssString == "#ffffff" && dark.bgBase.cssString == "#1e1e20")
        #expect(light.textSecondary.cssString == "rgba(0, 0, 0, 0.5)")
        #expect(dark.contextMenuShadow.cssString == "0 8px 40px rgba(0, 0, 0, 0.45), 0 2px 8px rgba(0, 0, 0, 0.25)")
        #expect(light.bgHover.cssString == "rgba(29, 29, 31, 0.05)")
    }
}
