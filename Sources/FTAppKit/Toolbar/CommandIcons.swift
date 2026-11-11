import AppKit
import FTFoundation

extension CommandIcon {
    /// The system symbol of the command: Finder's where Finder has the same command.
    var symbolName: String {
        switch self {
        case .back: "chevron.backward"
        case .forward: "chevron.forward"
        case .up: "chevron.up"
        case .goTo: "arrow.forward.folder"
        case .refresh: "arrow.clockwise"
        case .newTab, .openInNewTab: "plus.rectangle.on.rectangle"
        case .icons, .viewAs: "square.grid.2x2"
        case .details: "list.bullet"
        case .list: "rectangle.split.3x1"
        case .sortBy: "arrow.up.arrow.down"
        case .foldersFirst: "text.below.folder"
        case .hidden: "eye.slash"
        case .hiddenShown: "eye"
        case .viewOptions: "ellipsis.circle"
        case .search: "magnifyingglass"
        case .folderTree, .revealInTree: "sidebar.leading"
        case .infoPanel: "sidebar.trailing"
        case .infoRow: "rectangle.bottomthird.inset.filled"
        case .open, .openFile: "arrow.up.forward.app"
        case .openInNewWindow: "macwindow.badge.plus"
        case .openWith: "arrow.up.right.square"
        case .quickLook: "eye"
        case .showPackageContents: "shippingbox"
        case .edit: "square.and.pencil"
        case .showInfo: "info.circle"
        case .calculateSize: "chart.pie"
        case .revealInFolder: "arrow.up.folder"
        case .rootTreeHere: "list.bullet.indent"
        case .showInFinder: "finder"
        case .terminal: "apple.terminal"
        case .cut: "scissors"
        case .copy: "document.on.document"
        case .paste: "document.on.clipboard"
        case .copyPath: "link"
        case .move: "folder"
        case .rename: "pencil"
        case .duplicate: "plus.square.on.square"
        case .newFolder: "folder.badge.plus"
        case .favorite: "star"
        case .trash, .emptyTrash: "trash"
        case .deleteImmediately: "trash.slash"
        case .eject: "eject"
        case .theme: "circle.lefthalf.filled"
        case .settings: "gearshape"
        case .help: "questionmark.circle"
        }
    }

    /// The symbol as a template image at its own size, for the system's buttons and menus, which size and tint it.
    var image: NSImage { SymbolGlyph.image(symbolName) }
}

/// System symbols drawn by the app's own views.
enum SymbolGlyph {
    /// The symbol `name` as a template image; `pointSize` nil leaves its size to whatever shows it.
    static func image(_ name: String, pointSize: Double? = nil, weight: NSFont.Weight = .regular) -> NSImage {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return NSImage() }
        guard let pointSize else { return symbol }
        return symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
            ?? symbol
    }

    /// Draws the symbol `name` in `color`, as large as fits in `rect` and centered there (a flipped context).
    static func draw(_ name: String, in rect: NSRect, color: NSColor, weight: NSFont.Weight = .regular) {
        // A translucent palette color comes out with its alpha applied twice: the symbol is drawn in the opaque
        // color, at the color's alpha.
        let resolved = color.usingColorSpace(.sRGB) ?? color
        guard
            let image = image(name, pointSize: rect.height, weight: weight)
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [resolved.withAlphaComponent(1)]))
        else { return }
        let scale = min(1, rect.width / image.size.width, rect.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let fitted = NSRect(
            x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        image.draw(
            in: fitted, from: .zero, operation: .sourceOver, fraction: resolved.alphaComponent, respectFlipped: true,
            hints: nil)
    }
}

/// A system symbol of its own in a color, filling its bounds; it ignores the pointer.
final class SymbolIconView: NSView {
    var symbolName: String {
        didSet { needsDisplay = true }
    }
    var color: NSColor = .labelColor {
        didSet { needsDisplay = true }
    }

    init(_ symbolName: String) {
        self.symbolName = symbolName
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        SymbolGlyph.draw(symbolName, in: bounds, color: color)
    }
}
