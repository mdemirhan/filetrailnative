// Port of apps/desktop/src/renderer/lib/fileDragImages.ts and the drag limits of packages/contracts/src/limits.ts
import CoreGraphics
import Foundation

/// Where a dragged item shows in the window (`FileDragImage`): its icon and its name, so the drag sets off from
/// there, as Finder's does. Rects are in window points from the top left.
public struct FileDragImage: Equatable, Sendable {
    /// The item's place among the dragged paths.
    public var index: Int
    public var iconRect: CGRect
    public var nameRect: CGRect
    public var nameFontSize: Double
    /// Icon view centers its names under the icons; the lists put them after.
    public var nameCentered: Bool
    /// Whether the icon on screen is a picture Quick Look made, sent with the drag.
    public var thumbnail: Bool

    public init(
        index: Int, iconRect: CGRect, nameRect: CGRect, nameFontSize: Double, nameCentered: Bool, thumbnail: Bool
    ) {
        self.index = index
        self.iconRect = iconRect
        self.nameRect = nameRect
        self.nameFontSize = nameFontSize
        self.nameCentered = nameCentered
        self.thumbnail = thumbnail
    }
}

/// An item as a view draws it: its icon and name, and whether the icon shows inside every scrolling area holding it.
public struct FileDragPlacement: Equatable, Sendable {
    public var iconRect: CGRect
    public var nameRect: CGRect
    public var nameFontSize: Double
    public var nameCentered: Bool
    public var thumbnail: Bool
    public var inSight: Bool

    public init(
        iconRect: CGRect, nameRect: CGRect, nameFontSize: Double, nameCentered: Bool, thumbnail: Bool, inSight: Bool
    ) {
        self.iconRect = iconRect
        self.nameRect = nameRect
        self.nameFontSize = nameFontSize
        self.nameCentered = nameCentered
        self.thumbnail = thumbnail
        self.inSight = inSight
    }
}

public enum FileDragImages {
    /// `MAX_FILE_DRAG_IMAGES`: Finder draws no more than fit on screen.
    public static let maxImages = 200
    /// `MAX_PATHS_PER_REQUEST`: a drag of more files than one copy takes is refused as a whole.
    public static let maxPaths = 100_000

    /// `measureFileDragImages`: each dragged item where it shows, up to `maxImages`. Items out of sight, or not drawn
    /// at all, are left out and go along unseen. `placements` is what the view draws, looked up once.
    public static func measure(_ paths: [String], placements: [String: FileDragPlacement]) -> [FileDragImage] {
        var images: [FileDragImage] = []
        for (index, path) in paths.enumerated() {
            if images.count >= maxImages { break }
            guard let placement = placements[path], placement.inSight,
                !(placement.iconRect.width == 0 && placement.iconRect.height == 0)
            else { continue }
            images.append(
                FileDragImage(
                    index: index, iconRect: placement.iconRect, nameRect: placement.nameRect,
                    nameFontSize: placement.nameFontSize, nameCentered: placement.nameCentered,
                    thumbnail: placement.thumbnail))
        }
        return images
    }

    /// `isInSight`: whether a rect shows inside every scrolling area holding it (each given in the same space).
    public static func isInSight(_ rect: CGRect, within areas: [CGRect]) -> Bool {
        if rect.width == 0, rect.height == 0 { return false }
        for bounds in areas
        where rect.maxY <= bounds.minY || rect.minY >= bounds.maxY || rect.maxX <= bounds.minX
            || rect.minX >= bounds.maxX
        {
            return false
        }
        return true
    }
}
