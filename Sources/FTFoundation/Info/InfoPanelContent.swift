import Foundation

/// What several selected items have that the panel sums up, from the window's listing: nothing more is read.
public struct InfoSelectionFacts: Equatable, Sendable {
    public var kindLabels: [String]
    public var created: [Date]
    public var modified: [Date]
    /// One per item; nil where it isn't known yet.
    public var modes: [Int?]

    public init(kindLabels: [String] = [], created: [Date] = [], modified: [Date] = [], modes: [Int?] = []) {
        self.kindLabels = kindLabels
        self.created = created
        self.modified = modified
        self.modes = modes
    }
}

extension InfoPanelModel {
    /// Everything the panel shows of one item.
    public struct ItemContent: Equatable, Sendable {
        public var sections: [InfoSection]
        public var subtitle: String

        /// Every row, section after section.
        public var rows: [InfoRow] { sections.flatMap(\.rows) }

        public func section(_ id: InfoSection.ID) -> InfoSection? { sections.first { $0.id == id } }
    }

    private static func row(_ label: String, _ text: String?, detail: String? = nil) -> InfoRow {
        InfoRow(label: label, value: .text(text ?? pending), muted: text == nil, detail: detail)
    }

    // MARK: One item

    /// The sections of one item, in an order that keeps what every item has in its place:
    /// - General: Kind; Opens with (a file) or Contains (a folder) in one place; Size; Tags; Where, the folder it is
    ///   in; Original for a link or an alias. A disk: Kind, Capacity, Used, Available, Tags.
    /// - Dates: Created, Modified, Last opened, Added.
    /// - Sharing & Permissions: Owner and Group (who, and what they may do), Everyone, Mode; Locked, Hidden and Extension
    ///   hidden when set.
    /// - Image, Movie, Sound, Document, Text, Application or Volume, by what the item is: each with the same rows for
    ///   every item that has it, a dash where it has none.
    /// - Downloaded, for a file that says where it came from; More (folded at first).
    /// Until the details are read their values are dashes, in their places.
    public static func itemContent(
        item: InfoItem, pending isPending: Bool, volume: InfoVolume?, isVolumeRoot: Bool, hasFolderSize: Bool,
        folderSize: FolderSizeEntry?, opensWith: OpensWithState, dates: DateText = .shared, homePath: String = "",
        startupDiskName: String = VolumePaths.defaultStartupDiskName, tags: InfoTagsState = .hidden,
        details detailsState: InfoDetailsState = .pending, signing: InfoSigningState = .none
    ) -> ItemContent {
        let details = detailsState.details
        let isFile = item.kind == .file || item.kind == .symlinkFile
        let folderEligible = item.kind.isFolderSizeEligible

        // General.
        var general: [InfoRow] = [InfoRow(label: "Kind", value: .text(item.kindLabel), muted: false)]
        if isVolumeRoot {
            let total = volume?.totalBytes
            let available = volume?.availableBytes
            let used = total.flatMap { total in available.map { max(0, total - $0) } }
            general.append(row("Capacity", total.map { SizeText.size($0) }))
            if let used, let total, total > 0 {
                general.append(
                    InfoRow(
                        label: "Used",
                        value: .usage(fraction: Double(used) / Double(total), text: SizeText.size(used)),
                        muted: false))
            } else {
                general.append(row("Used", nil))
            }
            let purgeable = details?.volume?.purgeableBytes.map { "\(SizeText.size($0)) of it purgeable" }
            general.append(row("Available", available.map { SizeText.size($0) }, detail: purgeable))
        } else {
            if isFile {
                switch opensWith {
                case .available: general.append(InfoRow(label: "Opens with", value: .opensWith, muted: false))
                case .pending, .hidden: general.append(row("Opens with", nil))
                }
            }
            // In the place a file's "Opens with" takes, so the rows under it stay where they are from item to item.
            if folderEligible { general.append(containsRow(folderSize)) }
            general.append(
                sizeRow(
                    item, pending: isPending, folderEligible: folderEligible, hasFolderSize: hasFolderSize,
                    folderSize: folderSize, details: details))
        }
        if let row = tags.row { general.append(row) }
        if !isVolumeRoot {
            if let parent = parentPath(item.path) {
                let label = PathBarModel.segments(parent, homePath: homePath, startupDiskName: startupDiskName)
                    .map(\.label).joined(separator: " › ")
                general.append(
                    InfoRow(
                        label: "Where", value: .place(label), muted: false,
                        copyText: item.path))
            } else {
                general.append(InfoRow(label: "Where", value: .text(pending), muted: true))
            }
        }
        // A symbolic link or an alias says where it leads, as Finder's Get Info does.
        switch item.original {
        case .found(let path):
            general.append(
                InfoRow(
                    label: "Original",
                    value: .originalLink(
                        label: PathBarModel.label(path, homePath: homePath, startupDiskName: startupDiskName),
                        path: path),
                    muted: false, copyText: path))
        case .missing:
            general.append(InfoRow(label: "Original", value: .text("Can\u{2019}t be found"), muted: true))
        case nil:
            break
        }
        var sections = [InfoSection(id: .general, rows: general)]

        // Dates.
        func date(_ value: Date?) -> String? { value.map { dates.dateTime($0) } }
        sections.append(
            InfoSection(
                id: .dates,
                rows: [
                    row("Created", date(item.createdAt)), row("Modified", date(item.modifiedAt)),
                    row("Last opened", date(item.lastOpenedAt)), row("Added", date(item.addedAt)),
                ]))

        sections.append(InfoSection(id: .permissions, rows: permissionRows(item, details: details)))

        // What the item is.
        if isVolumeRoot {
            sections.append(InfoSection(id: .volume, rows: volumeRows(details?.volume)))
        } else if item.kind == .bundle, item.fileExtension.lowercased() == "app" {
            sections.append(InfoSection(id: .application, rows: appRows(details?.app, signing: signing)))
        } else if isFile {
            switch InfoContentKind.of(extension: item.fileExtension) {
            case .image: sections.append(InfoSection(id: .image, rows: imageRows(details?.image)))
            case .movie: sections.append(InfoSection(id: .movie, rows: movieRows(details?.media)))
            case .sound: sections.append(InfoSection(id: .sound, rows: soundRows(details?.media)))
            case .pdf, .document: sections.append(InfoSection(id: .document, rows: documentRows(details?.document)))
            case .text: sections.append(InfoSection(id: .text, rows: textRows(details?.text)))
            case .other: break
            }
        }
        if let download = details?.download {
            sections.append(InfoSection(id: .downloaded, rows: downloadRows(download)))
        }
        sections.append(InfoSection(id: .more, rows: moreRows(item, details: details)))

        let summary: String?
        if isVolumeRoot {
            summary = volume?.availableBytes.map { "\(SizeText.size($0)) available" }
        } else if folderEligible {
            if case .ready(let size, _, _, _)? = folderSize { summary = SizeText.size(size) } else { summary = nil }
        } else if isPending, item.sizeBytes == nil {
            summary = nil
        } else {
            summary = SizeText.size(item.sizeBytes, status: item.sizeStatus)
        }
        return ItemContent(sections: sections, subtitle: summary.map { "\(item.kindLabel) · \($0)" } ?? item.kindLabel)
    }

    /// Size has a second line for every item, a dash until it is known, so the rows under it stay where they are from
    /// a file to a folder and while a folder is measured: a file's size on disk, a folder's exact bytes.
    private static func sizeRow(
        _ item: InfoItem, pending isPending: Bool, folderEligible: Bool, hasFolderSize: Bool,
        folderSize: FolderSizeEntry?, details: InfoDetails?
    ) -> InfoRow {
        if folderEligible, hasFolderSize, let folderSize {
            var muted = false
            var detail = pending
            switch folderSize {
            case .idle, .error: muted = true
            case .ready(let size, _, _, _): detail = InfoText.bytes(size)
            default: break
            }
            return InfoRow(label: "Size", value: .folderSize, muted: muted, detail: detail)
        }
        if folderEligible { return InfoRow(label: "Size", value: .text("--"), muted: true, detail: pending) }
        if isPending, item.sizeBytes == nil { return row("Size", nil, detail: pending) }
        guard item.sizeStatus == .ready, let bytes = item.sizeBytes else {
            return InfoRow(
                label: "Size", value: .text(SizeText.size(item.sizeBytes, status: item.sizeStatus)), muted: false,
                detail: pending)
        }
        let disk = details?.sizeOnDisk.map { "\(SizeText.size($0)) on disk" } ?? pending
        return InfoRow(label: "Size", value: .text(InfoText.sizeWithBytes(bytes)), muted: false, detail: disk)
    }

    // MARK: Sharing & Permissions

    private static func permissionRows(_ item: InfoItem, details: InfoDetails?) -> [InfoRow] {
        let owner = details?.owner
        guard let mode = item.permissionMode, let parts = PermissionText.split(mode) else {
            return ["Owner", "Group", "Everyone", "Mode"].map { row($0, nil) }
        }
        func access(_ label: String, _ name: String?, isYou: Bool, shift: Int) -> InfoRow {
            InfoRow(
                label: label,
                value: .access(
                    name: name, isYou: isYou, words: InfoText.privilege(mode, shift: shift),
                    letters: InfoText.privilegeLetters(mode, shift: shift)),
                muted: false)
        }
        var rows = [
            access("Owner", owner?.user, isYou: owner?.isYou ?? false, shift: 6),
            access("Group", owner?.group, isYou: false, shift: 3),
            row("Everyone", InfoText.privilege(mode, shift: 0)),
            InfoRow(
                label: "Mode", value: .text("\(parts.octal) · \(parts.symbolic)"), muted: false,
                copyText: parts.octal),
        ]
        if let flags = details?.flags {
            if flags.locked { rows.append(row("Locked", "Yes")) }
            if flags.hidden || item.isHidden { rows.append(row("Hidden", "Yes")) }
            if flags.extensionHidden { rows.append(row("Extension", "Hidden")) }
        }
        return rows
    }

    // MARK: What the item is

    private static func imageRows(_ image: InfoDetails.Image?) -> [InfoRow] {
        let size: String? = image?.width.flatMap { width in image?.height.map { InfoText.dimensions(width, $0) } }
        let megapixels: String? = image?.width.flatMap { width in
            image?.height.map { "\(JSString.toFixed(Double(width * $0) / 1_000_000, 1)) megapixels" }
        }
        let color = image.flatMap { $0.colorProfile ?? $0.colorModel }
        var depth: [String] = []
        if let bits = image?.bitsPerChannel { depth.append("\(bits) bits per channel") }
        if let alpha = image?.hasAlpha { depth.append(alpha ? "alpha" : "no alpha") }
        var exposure: [String] = []
        if let seconds = image?.exposureSeconds { exposure.append(InfoText.exposure(seconds)) }
        if let f = image?.fNumber { exposure.append("f/\(JSString.toFixed(f, 1))") }
        if let iso = image?.iso { exposure.append("ISO \(iso)") }
        if let flash = image?.flash { exposure.append(flash ? "flash" : "no flash") }
        var lens = image?.lens
        if let focal = image?.focalLength35mm, focal > 0 {
            lens = [lens, "\(Int(focal.rounded())) mm"].compactMap { $0 }.joined(separator: " · ")
        }
        let location: String? = image?.latitude.flatMap { lat in
            image?.longitude.map { InfoText.location(latitude: lat, longitude: $0) }
        }
        return [
            row("Dimensions", size, detail: megapixels ?? pending),
            row("Resolution", image?.dpi.map { "\(Int($0.rounded())) dpi" }),
            row("Color", color, detail: depth.isEmpty ? pending : depth.joined(separator: ", ")),
            row("Camera", image?.camera, detail: lens ?? pending),
            row("Exposure", exposure.isEmpty ? nil : exposure.joined(separator: " · ")),
            row("Taken", image?.taken.map { DateText.shared.dateTime($0) }),
            row("Location", location),
        ]
    }

    private static func movieRows(_ media: InfoDetails.Media?) -> [InfoRow] {
        let size: String? = media?.width.flatMap { width in media?.height.map { InfoText.dimensions(width, $0) } }
        return [
            row("Duration", media?.seconds.map(InfoText.duration)),
            row("Dimensions", size),
            row("Codecs", media.flatMap { $0.codecs.isEmpty ? nil : $0.codecs.joined(separator: ", ") }),
            row("Bit rate", media?.bitRate.map(InfoText.bitRate)),
            row("Audio", media.flatMap { InfoText.audio(sampleRate: $0.sampleRate, channels: $0.channels) }),
        ]
    }

    private static func soundRows(_ media: InfoDetails.Media?) -> [InfoRow] {
        [
            row("Duration", media?.seconds.map(InfoText.duration)),
            row("Title", media?.title), row("Artist", media?.artist), row("Album", media?.album),
            row("Codecs", media.flatMap { $0.codecs.isEmpty ? nil : $0.codecs.joined(separator: ", ") }),
            row("Audio", media.flatMap { InfoText.audio(sampleRate: $0.sampleRate, channels: $0.channels) }),
        ]
    }

    private static func documentRows(_ document: InfoDetails.Document?) -> [InfoRow] {
        let page: String? = document?.pageWidth.flatMap { width in
            document?.pageHeight.map { InfoText.pageSize(width: width, height: $0) }
        }
        var version: String?
        if let value = document?.version { version = "PDF \(value)" }
        if let locked = document?.locked {
            version = [version, locked ? "locked" : "not locked"].compactMap { $0 }.joined(separator: " · ")
        }
        return [
            row("Pages", document?.pages.map { FormatLocale.count($0) }), row("Page size", page),
            row("Title", document?.title),
            row("Authors", document.flatMap { $0.authors.isEmpty ? nil : $0.authors.joined(separator: ", ") }),
            row("Made with", document?.madeWith), row("Version", version),
        ]
    }

    private static func textRows(_ text: InfoDetails.Text?) -> [InfoRow] {
        [
            row("Lines", text.map { FormatLocale.count($0.lines) }), row("Encoding", text?.encoding),
            row("Line endings", text?.lineEnding),
        ]
    }

    private static func appRows(_ app: InfoDetails.App?, signing: InfoSigningState) -> [InfoRow] {
        var signedBy: String?
        var notarized: String?
        if case .read(let value) = signing, let value {
            signedBy = value.signedBy
            notarized = value.notarized.map { $0 ? "Yes" : "No" } ?? "Not needed"
        } else if case .read = signing {
            signedBy = "Unknown"
            notarized = "Unknown"
        }
        let version: String? = app?.version.map { version in app?.build.map { "\(version) (\($0))" } ?? version }
        return [
            row("Version", version), row("Identifier", app?.identifier), row("Runs on", app?.runsOn),
            row("Requires", app?.minimumSystem.map { "macOS \($0) or later" }), row("Signed by", signedBy),
            row("Notarized", notarized), row("Copyright", app?.copyright),
        ]
    }

    private static func volumeRows(_ volume: InfoDetails.Volume?) -> [InfoRow] {
        func yesNo(_ value: Bool?) -> String? { value.map { $0 ? "Yes" : "No" } }
        return [
            row("Format", volume?.format), row("Mounted at", volume?.mountPoint), row("Device", volume?.device),
            row("Connection", volume?.connection), row("Ejectable", yesNo(volume?.ejectable)),
            row("Ownership", volume?.ignoresOwnership.map { $0 ? "Ignored" : "Respected" }),
        ]
    }

    private static func downloadRows(_ download: InfoDetails.Download) -> [InfoRow] {
        var rows: [InfoRow] = []
        if let from = download.from {
            let host = URL(string: from)?.host()
            rows.append(
                InfoRow(
                    label: "From", value: .text(host ?? from), muted: false, detail: host == nil ? nil : from,
                    copyText: from))
        }
        if let page = download.page { rows.append(InfoRow(label: "Page", value: .text(page), muted: false)) }
        let by = [download.agent, download.date.map { DateText.shared.dateTime($0) }].compactMap { $0 }
        if !by.isEmpty { rows.append(row("By", by.joined(separator: ", "))) }
        return rows
    }

    private static func moreRows(_ item: InfoItem, details: InfoDetails?) -> [InfoRow] {
        let more = details?.more
        var volume: String?
        if let name = more?.volumeName {
            volume = [name, more?.volumeFormat].compactMap { $0 }.joined(separator: " · ")
        }
        var fileID: String?
        if let id = more?.fileID {
            let links = more?.linkCount ?? 1
            fileID = "\(id) · \(links) \(links == 1 ? "link" : "links")"
        }
        let cloud: String? = more.map {
            switch $0.cloud {
            case .none: "Not in a cloud"
            case .downloaded: "Downloaded"
            case .cloudOnly: "In the cloud only"
            }
        }
        var rows = [
            row("Type", more?.contentType),
            row("Cloud", cloud), row("Volume", volume), row("File ID", fileID),
            row("Attributes", more.map { $0.attributes.isEmpty ? "None" : $0.attributes.joined(separator: "\n") }),
        ]
        if let comment = details?.comment { rows.append(row("Comments", comment)) }
        // The lists of More, at the panel's end, take their lines: nothing under them moves.
        for index in rows.indices where ["Attributes", "Comments"].contains(rows[index].label) {
            rows[index].wraps = true
        }
        return rows
    }

    // MARK: Several items

    /// The sections of several items: General (Kinds on one line, Contains when folders are among them, Size, Tags,
    /// Where), Dates (Created and Modified, from the first to the last) and Sharing & Permissions (the modes, with how
    /// many have each).
    public static func selectionContent(
        _ selection: InfoSelection, facts: InfoSelectionFacts, hasFolderSize: Bool, folderSize: FolderSizeEntry?,
        dates: DateText = .shared, homePath: String = "",
        startupDiskName: String = VolumePaths.defaultStartupDiskName, tags: InfoTagsState = .hidden
    ) -> [InfoSection] {
        var general: [InfoRow] = []
        if !facts.kindLabels.isEmpty {
            let kinds = InfoText.kinds(facts.kindLabels)
            general.append(InfoRow(label: "Kinds", value: .fitting(full: kinds.full, short: kinds.short), muted: false))
        }
        if hasFolderSize, folderSize != nil { general.append(containsRow(folderSize)) }
        if hasFolderSize, let folderSize {
            var idle = false
            if case .idle = folderSize { idle = true }
            general.append(InfoRow(label: "Size", value: .folderSize, muted: idle))
        } else {
            let size = selection.totalBytes
            general.append(
                InfoRow(
                    label: "Size", value: .text(size.map { InfoText.sizeWithBytes($0) } ?? "--"), muted: size == nil))
        }
        if let row = tags.row { general.append(row) }
        if let parent = selection.parentPath {
            let label = PathBarModel.segments(parent, homePath: homePath, startupDiskName: startupDiskName)
                .map(\.label).joined(separator: " › ")
            general.append(
                InfoRow(label: "Where", value: .place(label), muted: false, copyText: parent))
        } else {
            general.append(InfoRow(label: "Where", value: .text("Several folders"), muted: true))
        }
        func range(_ values: [Date]) -> String? {
            guard let first = values.min(), let last = values.max() else { return nil }
            return dates.dayRange(first, last)
        }
        // The modes on one line, the most first, or how many there are where they don't fit ("3 modes").
        var modes = row("Mode", nil)
        if !facts.modes.isEmpty, !facts.modes.contains(where: { $0 == nil }) {
            // Counted as numbers, and each mode there is written out once: a folder's items share a few.
            var numbers: [Int] = []
            var numberCounts: [Int: Int] = [:]
            for case let mode? in facts.modes {
                if numberCounts[mode] == nil { numbers.append(mode) }
                numberCounts[mode, default: 0] += 1
            }
            var order: [String] = []
            var counts: [String: Int] = [:]
            for mode in numbers {
                let octal = PermissionText.mode(mode)
                if counts[octal] == nil { order.append(octal) }
                counts[octal, default: 0] += numberCounts[mode] ?? 0
            }
            if order.count == 1 {
                modes = row("Mode", order[0])
            } else {
                let sorted = order.enumerated().sorted { a, b in
                    let (ca, cb) = (counts[a.element] ?? 0, counts[b.element] ?? 0)
                    return ca != cb ? ca > cb : a.offset < b.offset
                }.map(\.element)
                let full = sorted.map { "\($0) on \(FormatLocale.count(counts[$0] ?? 0))" }.joined(separator: " · ")
                modes = InfoRow(
                    label: "Mode", value: .fitting(full: full, short: "\(FormatLocale.count(order.count)) modes"),
                    muted: false)
            }
        }
        return [
            InfoSection(id: .general, rows: general),
            InfoSection(
                id: .dates, rows: [row("Created", range(facts.created)), row("Modified", range(facts.modified))]),
            InfoSection(id: .permissions, rows: [modes]),
        ]
    }

    // MARK: The Info Row

    /// The Info Row's facts for one item: its kind, the one fact that matters most for it, and when it changed; never a
    /// count or a size the status bar says already. Each is left out until known.
    public struct RowFacts: Equatable, Sendable {
        public var name: String
        public var kind: String?
        /// The fact of its kind: "4032 × 3024", "2:31 · 3840 × 2160", "12 pages", "Version 3.7.1", "45 files,
        /// 20 folders", "→ ~/src/projects", "212 GB available".
        public var fact: String?
        /// The folder size control stands in the fact's place: a folder not yet measured.
        public var showsFolderSize: Bool
        public var modified: String?
        public var modifiedTooltip: String?
        /// What is left on the disk: for the folder on screen.
        public var available: String?
    }

    public static func rowFacts(
        entry: InfoEntry, metadata: InfoMetadata?, item: InfoItem?, folderSize: FolderSizeEntry?,
        details: InfoDetails?, isShownFolder: Bool = false, availableBytes: Int64? = nil, now: Date,
        dates: DateText = .shared, homePath: String = ""
    ) -> RowFacts {
        let known: (kind: String, modified: Date?)? =
            metadata.map { ($0.kindLabel, $0.modifiedAt) }
            ?? (item?.path == entry.path ? item : nil).map { ($0.kindLabel, $0.modifiedAt) }
        var fact: String?
        var showsFolderSize = false
        if entry.kind.isFolderSizeEligible {
            if let contents = measuredContents(folderSize) {
                fact = contents
            } else if folderSize != nil {
                showsFolderSize = true
            }
        }
        if fact == nil, !showsFolderSize {
            fact = kindFact(details, item: item?.path == entry.path ? item : nil, homePath: homePath)
        }
        var modified: String?
        var tooltip: String?
        if let date = known?.modified {
            modified = "Modified \(dates.relative(date, now: now))"
            tooltip = dates.exactDateTime(date)
        }
        return RowFacts(
            name: entry.name,
            kind: isShownFolder && entry.kind == .directory
                ? nil
                : known?.kind ?? InfoPreview.fallbackKindLabel(kind: entry.kind, fileExtension: entry.fileExtension),
            fact: fact, showsFolderSize: showsFolderSize, modified: modified, modifiedTooltip: tooltip,
            available: isShownFolder ? availableBytes.map { "\(SizeText.size($0)) available" } : nil)
    }

    /// The one fact of an item's kind the Info Row shows.
    static func kindFact(_ details: InfoDetails?, item: InfoItem?, homePath: String) -> String? {
        if case .found(let path)? = item?.original {
            return "→ \(Places.abbreviate(path, homePath: homePath))"
        }
        if case .missing? = item?.original { return "Original can\u{2019}t be found" }
        guard let details else { return nil }
        if let image = details.image, let width = image.width, let height = image.height {
            return InfoText.dimensions(width, height)
        }
        if let media = details.media {
            var parts: [String] = []
            if let seconds = media.seconds { parts.append(InfoText.duration(seconds)) }
            if media.isVideo, let width = media.width, let height = media.height {
                parts.append(InfoText.dimensions(width, height))
            } else if let artist = media.artist {
                parts.append(artist)
            }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
        }
        if let pages = details.document?.pages {
            return "\(FormatLocale.count(pages)) \(pages == 1 ? "page" : "pages")"
        }
        if let lines = details.text?.lines { return "\(FormatLocale.count(lines)) \(lines == 1 ? "line" : "lines")" }
        if let version = details.app?.version { return "Version \(version)" }
        return nil
    }

    /// The Info Row of several items: their kinds, on one line or "3 kinds", and the days they were changed.
    public static func selectionRowFacts(_ facts: InfoSelectionFacts, dates: DateText = .shared)
        -> (kinds: (full: String, short: String), modified: String?)
    {
        var modified: String?
        if let first = facts.modified.min(), let last = facts.modified.max() {
            modified = "Modified \(dates.dayRange(first, last))"
        }
        return (InfoText.kinds(facts.kindLabels), modified)
    }
}
