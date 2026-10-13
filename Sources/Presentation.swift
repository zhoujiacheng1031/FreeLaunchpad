import AppKit

/// A presentation session belongs only to the visible launcher, never to Dock preferences.
struct DockPresentationSession {
    private(set) var original: NSApplication.PresentationOptions?
    mutating func options(current: NSApplication.PresentationOptions, hideDock: Bool) -> NSApplication.PresentationOptions {
        if original == nil { original = current }
        var requested = original!
        if hideDock {
            requested.remove(.autoHideDock)
            requested.insert(.hideDock)
        }
        return requested
    }
    mutating func restore() -> NSApplication.PresentationOptions? {
        defer { original = nil }
        return original
    }
}

struct LauncherInsets: Equatable {
    var top: CGFloat = 0
    var leading: CGFloat = 0
    var bottom: CGFloat = 0
    var trailing: CGFloat = 0
    static func resolve(frame: CGRect, visibleFrame: CGRect, hideDock: Bool) -> LauncherInsets {
        LauncherInsets(
            top: max(0, frame.maxY - visibleFrame.maxY),
            leading: hideDock ? 0 : max(0, visibleFrame.minX - frame.minX),
            bottom: hideDock ? 0 : max(0, visibleFrame.minY - frame.minY),
            trailing: hideDock ? 0 : max(0, frame.maxX - visibleFrame.maxX)
        )
    }
}

/// Fixed header/footer sizes let the manager preview the same usable canvas on any display.
enum LauncherCanvasMetrics {
    static let contextHeight: CGFloat = 28
    static let hintHeight: CGFloat = 14
    static func gridSize(screen: CGSize, insets: LauncherInsets) -> CGSize {
        let width = max(360, screen.width - insets.leading - insets.trailing)
        let height = max(320, screen.height - insets.top - insets.bottom)
        let searchTop: CGFloat = height < 700 ? 24 : 40
        let chromeHeight = searchTop + 50 + contextHeight + 12 + 24 + 12 + 40 + 15 + hintHeight + 20
        return CGSize(width: LauncherGridGeometry.width(for: width), height: max(1, height - chromeHeight))
    }
}

struct TileDropGeometry {
    var cellWidth: CGFloat
    var cellHeight: CGFloat
    var iconSize: CGFloat
    var groupRect: CGRect {
        let compact = iconSize < 40
        let top: CGFloat = compact ? 8 : 12
        let total = iconSize + (compact ? 20 + 6 + 8 : 34 + 9 + 12 + 3)
        return CGRect(x: (cellWidth - iconSize) / 2 - 8,
                      y: (cellHeight - total) / 2 + top - 8,
                      width: iconSize + 16, height: iconSize + 16)
    }
    func groups(at point: CGPoint) -> Bool { groupRect.contains(point) }
}
