import Foundation

/// Restore folder structure and its metadata together; preserve appearance and root page names.
struct LayoutContentSnapshot: Equatable {
    var tiles: [Tile]
    var positions: [String: Int]
    var folderPositions: [String: [String: Int]]
    var folderPageNames: [String: [String: String]]
    init(_ layout: Layout) {
        tiles = layout.tiles; positions = layout.positions
        folderPositions = layout.folderPositions; folderPageNames = layout.folderPageNames
    }
    func restore(into layout: inout Layout) {
        layout.tiles = tiles; layout.positions = positions
        layout.folderPositions = folderPositions; layout.folderPageNames = folderPageNames
    }
}

struct BatchGroupingPlan {
    let before: LayoutContentSnapshot
    let after: LayoutContentSnapshot
    let folderID: String
    let createdNew: Bool
    let selectedCount: Int
    let incomingAppCount: Int
}

enum BatchGroupingError: LocalizedError {
    case selectMore, invalidName, tooManyApps
    var errorDescription: String? {
        switch self {
        case .selectMore: return "新建文件夹至少需要勾选两个图标。移入已有文件夹时，请勾选该文件夹之外的图标。"
        case .invalidName: return "文件夹名称需要 1–40 个字符，不能包含换行或控制字符。"
        case .tooManyApps: return "文件夹内应用超过支持范围，请减少选择。"
        }
    }
}

extension Layout {
    func planBatchGroup(_ ids: Set<String>, into targetID: String? = nil, name: String = "新建文件夹") throws -> BatchGroupingPlan {
        guard !layoutLocked else { throw BatchPlacementError.layoutLocked }
        guard !ids.isEmpty, ids.allSatisfy({ id in tiles.contains(where: { $0.id == id }) }) else { throw BatchPlacementError.invalidSelection }
        if let targetID, !tiles.contains(where: { $0.id == targetID && $0.isFolder }) { throw BatchPlacementError.invalidSelection }
        let incomingIDs = ids.subtracting(targetID.map { [$0] } ?? [])
        guard incomingIDs.count >= (targetID == nil ? 2 : 1) else { throw BatchGroupingError.selectMore }
        let slots = resolvedPositions()
        let selected = tiles.filter { incomingIDs.contains($0.id) }.sorted { slots[$0.id]! < slots[$1.id]! }
        let paths = selected.flatMap { tile -> [String] in
            guard tile.isFolder else { return tile.apps }
            let internalSlots = resolvedPositions(folderID: tile.id)
            return tile.apps.sorted { internalSlots[$0]! < internalSlots[$1]! }
        }
        let existing = targetID.flatMap { id in tiles.first(where: { $0.id == id }) }
        let combined = (existing?.apps ?? []) + paths
        guard Set(combined).count == combined.count else { throw BatchPlacementError.invalidSelection }
        guard combined.count <= 10000 else { throw BatchGroupingError.tooManyApps }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if targetID == nil {
            guard !cleaned.isEmpty, cleaned.count <= 40,
                  !cleaned.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw BatchGroupingError.invalidName }
        }
        let destination = existing ?? Tile.folder(combined, name: cleaned)
        var after = self
        after.normalizePositions()
        after.tiles.removeAll { incomingIDs.contains($0.id) }
        after.positions = slots.filter { !incomingIDs.contains($0.key) }
        if let index = after.tiles.firstIndex(where: { $0.id == destination.id }) {
            after.tiles[index].apps = combined
        } else {
            after.tiles.append(destination)
            after.positions[destination.id] = selected.map { slots[$0.id]! }.min()!
        }
        after.normalizePositions()
        after.tiles.sort { after.positions[$0.id]! < after.positions[$1.id]! }
        _ = try after.validated()
        return BatchGroupingPlan(before: LayoutContentSnapshot(self), after: LayoutContentSnapshot(after), folderID: destination.id,
                                 createdNew: targetID == nil, selectedCount: incomingIDs.count, incomingAppCount: paths.count)
    }
    @discardableResult mutating func applyBatchGroup(_ plan: BatchGroupingPlan) -> Bool {
        guard !layoutLocked, LayoutContentSnapshot(self) == plan.before else { return false }
        plan.after.restore(into: &self)
        return true
    }
    @discardableResult mutating func undoBatchGroup(_ plan: BatchGroupingPlan) -> Bool {
        guard !layoutLocked, LayoutContentSnapshot(self) == plan.after else { return false }
        plan.before.restore(into: &self)
        return true
    }
}

enum PageManagerUndo {
    case move(BatchPlacementPlan)
    case group(BatchGroupingPlan)
    var title: String {
        switch self {
        case .move: return "撤销移动"
        case .group(let plan): return plan.createdNew ? "撤销建组" : "撤销移入"
        }
    }
    func apply(to layout: inout Layout) -> Bool {
        switch self {
        case .move(let plan): return layout.undoBatchMove(plan)
        case .group(let plan): return layout.undoBatchGroup(plan)
        }
    }
}
