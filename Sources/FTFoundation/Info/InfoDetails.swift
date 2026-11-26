import Foundation

/// What the Info panel shows of one item beyond its properties: read in the background after the item settles
/// (`InfoDetailsReader`), each part nil where the item has none or it can't be read.
public struct InfoDetails: Equatable, Sendable {
    /// What the item takes on its disk, in bytes.
    public var sizeOnDisk: Int64?
    public var owner: Owner?
    public var flags = Flags()
    public var more = More()
    public var download: Download?
    /// Finder's Comments.
    public var comment: String?
    public var image: Image?
    public var media: Media?
    public var document: Document?
    public var text: Text?
    public var app: App?
    public var volume: Volume?

    public init() {}

    public struct Owner: Equatable, Sendable {
        public var user: String
        public var group: String
        /// Whether the user is the one running the app.
        public var isYou: Bool
        /// What the one running the app may do, by `access`: "Read & Write", "Read only", "Write only", "No Access".
        public var youCan: String

        public init(user: String, group: String, isYou: Bool, youCan: String) {
            self.user = user
            self.group = group
            self.isYou = isYou
            self.youCan = youCan
        }
    }

    public struct Flags: Equatable, Sendable {
        public var locked = false
        /// Hidden by its flag (a name that starts with a dot is hidden by its name, which the name says).
        public var hidden = false
        public var extensionHidden = false

        public init(locked: Bool = false, hidden: Bool = false, extensionHidden: Bool = false) {
            self.locked = locked
            self.hidden = hidden
            self.extensionHidden = extensionHidden
        }
    }

    public enum Cloud: String, Equatable, Sendable {
        /// Not kept in a cloud.
        case none
        case downloaded
        /// Its data is in the cloud only (`SF_DATALESS`).
        case cloudOnly
    }

    /// The More section's facts.
    public struct More: Equatable, Sendable {
        public var contentType: String?
        public var volumeName: String?
        public var volumeFormat: String?
        public var fileID: UInt64?
        public var linkCount: Int?
        public var cloud: Cloud = .none
        /// The names of its extended attributes, A to Z.
        public var attributes: [String] = []

        public init(
            contentType: String? = nil, volumeName: String? = nil, volumeFormat: String? = nil, fileID: UInt64? = nil,
            linkCount: Int? = nil, cloud: Cloud = .none, attributes: [String] = []
        ) {
            self.contentType = contentType
            self.volumeName = volumeName
            self.volumeFormat = volumeFormat
            self.fileID = fileID
            self.linkCount = linkCount
            self.cloud = cloud
            self.attributes = attributes
        }
    }

    /// Where a downloaded file came from.
    public struct Download: Equatable, Sendable {
        /// The file's own address.
        public var from: String?
        /// The page that linked to it.
        public var page: String?
        /// The app that saved it ("Safari").
        public var agent: String?
        public var date: Date?

        public init(from: String? = nil, page: String? = nil, agent: String? = nil, date: Date? = nil) {
            self.from = from
            self.page = page
            self.agent = agent
            self.date = date
        }
    }

    public struct Image: Equatable, Sendable {
        public var width: Int?
        public var height: Int?
        public var dpi: Double?
        public var colorProfile: String?
        public var colorModel: String?
        public var bitsPerChannel: Int?
        public var hasAlpha: Bool?
        public var camera: String?
        public var lens: String?
        public var exposureSeconds: Double?
        public var fNumber: Double?
        public var iso: Int?
        public var flash: Bool?
        public var focalLength35mm: Double?
        public var taken: Date?
        public var latitude: Double?
        public var longitude: Double?

        public init() {}

        public var isEmpty: Bool { self == Image() }
    }

    public struct Media: Equatable, Sendable {
        public var seconds: Double?
        public var width: Int?
        public var height: Int?
        public var codecs: [String] = []
        public var bitRate: Double?
        public var sampleRate: Double?
        public var channels: Int?
        public var title: String?
        public var artist: String?
        public var album: String?

        public init() {}

        public var isEmpty: Bool { self == Media() }
        /// Whether it has a picture: a movie, rather than sound alone.
        public var isVideo: Bool { width != nil && height != nil }
    }

    public struct Document: Equatable, Sendable {
        public var pages: Int?
        /// The first page's size, in points.
        public var pageWidth: Double?
        public var pageHeight: Double?
        public var title: String?
        public var authors: [String] = []
        /// The app it was made with.
        public var madeWith: String?
        /// "1.7" for a PDF.
        public var version: String?
        public var locked: Bool?

        public init() {}

        public var isEmpty: Bool { self == Document() }
    }

    public struct Text: Equatable, Sendable {
        public var lines: Int
        public var encoding: String
        public var lineEnding: String

        public init(lines: Int, encoding: String, lineEnding: String) {
            self.lines = lines
            self.encoding = encoding
            self.lineEnding = lineEnding
        }
    }

    public struct App: Equatable, Sendable {
        public var version: String?
        public var build: String?
        public var identifier: String?
        /// "Apple Silicon and Intel", "Apple Silicon", "Intel".
        public var runsOn: String?
        public var minimumSystem: String?
        public var copyright: String?

        public init() {}

        public var isEmpty: Bool { self == App() }
    }

    /// Who signed an app and whether Apple notarized it: a code check, read after the rest.
    public struct Signing: Equatable, Sendable {
        /// "Developer ID · Lumen Labs", "Mac App Store", "Apple", "Ad hoc", "Not signed".
        public var signedBy: String
        /// Nil where it doesn't apply (Apple's own, the App Store's, not signed).
        public var notarized: Bool?

        public init(signedBy: String, notarized: Bool?) {
            self.signedBy = signedBy
            self.notarized = notarized
        }
    }

    public struct Volume: Equatable, Sendable {
        public var format: String?
        public var encrypted: Bool?
        public var mountPoint: String?
        public var device: String?
        /// "Internal", "External", "Network", "Disk image".
        public var connection: String?
        public var ejectable: Bool?
        /// Whether the disk ignores who owns its items.
        public var ignoresOwnership: Bool?
        /// Space macOS can free when asked (caches, local copies of what is in iCloud).
        public var purgeableBytes: Int64?

        public init() {}
    }
}

/// What the Info panel has of its item's details: being read, read, or not asked (more than one item, closed).
public enum InfoDetailsState: Equatable, Sendable {
    case pending
    case read(InfoDetails)

    public var details: InfoDetails? {
        if case .read(let details) = self { return details }
        return nil
    }
}

/// What the Info panel has of an app's signing.
public enum InfoSigningState: Equatable, Sendable {
    /// Not an app.
    case none
    case pending
    case read(InfoDetails.Signing?)
}
