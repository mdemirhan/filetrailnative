import FTFoundation

/// What the View menu's size commands do to a PDF or Quick Look's preview the viewer shows: Make Bigger is Zoom In,
/// Make Smaller Zoom Out and Default Size Actual Size, with their keys, and Zoom to Fit fits a whole page.
enum ViewerZoom: CaseIterable, Hashable, Sendable {
    case zoomIn, zoomOut, actualSize, fit

    init?(_ command: AppCommand) {
        switch command {
        case .increaseSize: self = .zoomIn
        case .decreaseSize: self = .zoomOut
        case .resetSize: self = .actualSize
        case .zoomToFit: self = .fit
        default: return nil
        }
    }

    var command: ShortcutCommandID {
        switch self {
        case .zoomIn: .increaseSize
        case .zoomOut: .decreaseSize
        case .actualSize: .resetSize
        case .fit: .zoomToFit
        }
    }

    var title: String {
        switch self {
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .actualSize: "Actual Size"
        case .fit: "Zoom to Fit"
        }
    }
}
