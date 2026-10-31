// Port of sanitizeBatchRenameSettings and sanitizeBatchRenamePresets (apps/desktop/src/shared/batchRename.ts)
import Foundation

extension BatchRename {
    /// `text`: a string cut to 255 UTF-16 units (a cut inside a surrogate pair leaves a replacement character here,
    /// where JavaScript keeps half of the pair).
    private static func text(_ value: JSONNode?, _ fallback: String) -> String {
        guard let string = value?.string else { return fallback }
        let units = string.utf16
        return units.count > maxTextSettingLength ? JSString.string(Array(units.prefix(maxTextSettingLength))) : string
    }

    private static func wholeNumber(_ value: JSONNode?, _ fallback: Int, least: Int) -> Int {
        guard let number = value?.number, number.isFinite else { return fallback }
        return Int(min(Double(maxNumberSetting), max(Double(least), jsRound(number))))
    }

    private static func pick<Choice: RawRepresentable>(_ value: JSONNode?, _ fallback: Choice) -> Choice
    where Choice.RawValue == String, Choice: CaseIterable {
        value?.string.flatMap { Choice(rawValue: $0) } ?? fallback
    }

    private static func flag(_ value: JSONNode?, _ fallback: Bool) -> Bool {
        value?.bool ?? fallback
    }

    private static func digits(_ value: JSONNode?, _ fallback: BatchRenameDigits) -> BatchRenameDigits {
        if value?.string == "auto" { return .auto }
        if let number = value?.number, let count = Int(exactly: number), (2...5).contains(count) {
            return .fixed(count)
        }
        return fallback
    }

    /// Saved settings are read leniently: a value that is missing or not one of the choices takes its default, so a
    /// damaged or older file never stops the sheet from opening.
    public static func sanitizeSettings(_ value: JSONNode?) -> BatchRenameSettings {
        let record = value?.object ?? [:]
        let d = BatchRenameSettings.defaults
        return BatchRenameSettings(
            mode: pick(record["mode"], d.mode),
            find: text(record["find"], d.find),
            replaceWith: text(record["replaceWith"], d.replaceWith),
            matchCase: flag(record["matchCase"], d.matchCase),
            useRegex: flag(record["useRegex"], d.useRegex),
            addText: text(record["addText"], d.addText),
            addWhere: pick(record["addWhere"], d.addWhere),
            nameFormat: pick(record["nameFormat"], d.nameFormat),
            formatWhere: pick(record["formatWhere"], d.formatWhere),
            customName: text(record["customName"], d.customName),
            keepNames: flag(record["keepNames"], d.keepNames),
            startAt: wholeNumber(record["startAt"], d.startAt, least: 0),
            step: wholeNumber(record["step"], d.step, least: 1),
            digits: digits(record["digits"], d.digits),
            separator: pick(record["separator"], d.separator),
            dateSource: pick(record["dateSource"], d.dateSource),
            dateFormat: pick(record["dateFormat"], d.dateFormat),
            dateSeparator: pick(record["dateSeparator"], d.dateSeparator),
            customDatePattern: text(record["customDatePattern"], d.customDatePattern),
            caseStyle: pick(record["caseStyle"], d.caseStyle),
            applyTo: pick(record["applyTo"], d.applyTo),
            onConflict: pick(record["onConflict"], d.onConflict))
    }

    /// Presets with an empty or repeated name are dropped; the first of a name is kept.
    public static func sanitizePresets(_ value: JSONNode?) -> [BatchRenamePreset] {
        guard let entries = value?.array else { return [] }
        var presets: [BatchRenamePreset] = []
        var seen = Set<NameKeys.Exact>()
        for entry in entries {
            guard let record = entry.object else { continue }
            let trimmed = JSString.trimmed(record["name"]?.string ?? "")
            let units = Array(trimmed.utf16.prefix(80))
            let name = JSString.string(units)
            if name.isEmpty || !seen.insert(NameKeys.Exact(JSString.lowercased(name))).inserted {
                continue
            }
            presets.append(BatchRenamePreset(name: name, settings: sanitizeSettings(record["settings"])))
            if presets.count == maxPresets { break }
        }
        return presets
    }

    /// The settings as the saved state holds them.
    static func node(of settings: BatchRenameSettings) -> JSONNode {
        (try? JSONNode.of(settings)) ?? BatchRenameSanitizers.defaultSettings
    }
}
