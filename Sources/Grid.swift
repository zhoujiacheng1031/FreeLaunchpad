import Foundation

extension Layout {
    /// Absolute slots preserve intentional gaps and page boundaries, independently of tile order.
    static let maximumSlot = 699_999
    func validPositions(_ slots: [String: Int], ids: [String]) -> Bool {
        let allowed = Set(ids)
        return slots.count <= ids.count && Set(slots.values).count == slots.count
            && slots.allSatisfy { allowed.contains($0.key) && (0...Self.maximumSlot).contains($0.value) }
    }
    func resolvedPositions(folderID: String? = nil) -> [String: Int] {
        let ids: [String]
        let saved: [String: Int]
        if let folderID {
            ids = tiles.first { $0.id == folderID && $0.isFolder }?.apps ?? []
            saved = folderPositions[folderID] ?? [:]
        } else { ids = tiles.map(\.id); saved = positions }
        let allowed = Set(ids)
        var slots = saved.filter { allowed.contains($0.key) }
        var next = (slots.values.max() ?? -1) + 1
        var occupied = Set(slots.values)
        for id in ids where slots[id] == nil {
            if next > Self.maximumSlot { next = 0; while occupied.contains(next) { next += 1 } }
            slots[id] = next; occupied.insert(next); next += 1
        }
        return slots
    }
    mutating func normalizePositions() {
        positions = resolvedPositions()
        var folders: [String: [String: Int]] = [:]
        for tile in tiles where tile.isFolder { folders[tile.id] = resolvedPositions(folderID: tile.id) }
        folderPositions = folders
        folderPageNames = folderPageNames.filter { folders[$0.key] != nil }
    }
    mutating func assignOrderedPositions(folderID: String? = nil) {
        let occupied = resolvedPositions(folderID: folderID).values.sorted()
        if let folderID, let folder = tiles.first(where: { $0.id == folderID }) {
            folderPositions[folderID] = Dictionary(uniqueKeysWithValues: zip(folder.apps, occupied))
        } else { positions = Dictionary(uniqueKeysWithValues: zip(tiles.map(\.id), occupied)) }
    }
    /// Dropping on an empty slot leaves the source slot empty; occupied slots swap.
    @discardableResult mutating func place(_ id: String, at slot: Int, folderID: String? = nil) -> Bool {
        guard !layoutLocked, (0...Self.maximumSlot).contains(slot) else { return false }
        var slots = resolvedPositions(folderID: folderID)
        guard let previous = slots[id] else { return false }
        if let other = slots.first(where: { $0.value == slot && $0.key != id })?.key { slots[other] = previous }
        slots[id] = slot
        if let folderID {
            guard let folder = tiles.firstIndex(where: { $0.id == folderID && $0.isFolder }) else { return false }
            folderPositions[folderID] = slots
            tiles[folder].apps.sort { slots[$0]! < slots[$1]! }
        } else {
            positions = slots
            tiles.sort { slots[$0.id]! < slots[$1.id]! }
        }
        normalizePositions()
        return true
    }
    func firstFreeSlot(on page: Int, capacity: Int, folderID: String? = nil) -> Int {
        let occupied = Set(resolvedPositions(folderID: folderID).values)
        let start = max(0, page) * max(1, capacity)
        return (start..<(start + max(1, capacity))).first { !occupied.contains($0) } ?? start
    }
}

struct LauncherGridGeometry {
    var size: CGSize
    var columns: Int
    var rows: Int
    var requestedIconSize: CGFloat = 88
    var horizontalSpacing: Double = 1
    var verticalSpacing: Double = 1
    private var fittedIconSize: CGFloat {
        min(requestedIconSize, max(24, size.width / CGFloat(columns) - 32), max(24, size.height / CGFloat(rows) - 58))
    }
    var cellWidth: CGFloat {
        let maximum = size.width / CGFloat(columns)
        let minimum = min(maximum, fittedIconSize + 32)
        return minimum + (maximum - minimum) * CGFloat(horizontalSpacing)
    }
    var cellHeight: CGFloat {
        let maximum = size.height / CGFloat(rows)
        let minimum = min(maximum, fittedIconSize + 58)
        return minimum + (maximum - minimum) * CGFloat(verticalSpacing)
    }
    var origin: CGPoint {
        CGPoint(x: (size.width - cellWidth * CGFloat(columns)) / 2, y: (size.height - cellHeight * CGFloat(rows)) / 2)
    }
    init(size: CGSize, columns: Int, rows: Int, requestedIconSize: CGFloat = 88, horizontalSpacing: Double = 1, verticalSpacing: Double = 1) {
        self.size = size; self.columns = columns; self.rows = rows
        self.requestedIconSize = requestedIconSize; self.horizontalSpacing = horizontalSpacing; self.verticalSpacing = verticalSpacing
    }
    init(size: CGSize, layout: Layout) {
        self.init(size: size, columns: layout.columns, rows: layout.rows, requestedIconSize: layout.iconSize,
                  horizontalSpacing: layout.horizontalSpacing, verticalSpacing: layout.verticalSpacing)
    }
    static func width(for available: CGFloat) -> CGFloat {
        available - 2 * min(80, max(24, available * 0.035))
    }
    func iconSize(requested: CGFloat) -> CGFloat {
        min(requested, max(24, cellWidth - 32), max(24, cellHeight - 58))
    }
    func cell(at point: CGPoint) -> Int? {
        guard size.width > 0, size.height > 0, columns > 0, rows > 0,
              point.x >= origin.x, point.y >= origin.y,
              point.x < origin.x + cellWidth * CGFloat(columns), point.y < origin.y + cellHeight * CGFloat(rows) else { return nil }
        return min(rows - 1, Int((point.y - origin.y) / cellHeight)) * columns + min(columns - 1, Int((point.x - origin.x) / cellWidth))
    }
    func center(of cell: Int) -> CGPoint {
        CGPoint(x: origin.x + (CGFloat(cell % columns) + 0.5) * cellWidth, y: origin.y + (CGFloat(cell / columns) + 0.5) * cellHeight)
    }
}
