import Foundation

struct BatchPlacementPlan {
    let folderID: String?
    let capacity: Int
    let targetPage: Int
    let before: [String: Int]
    let after: [String: Int]
    let movedIDs: Set<String>
}

enum BatchPlacementError: LocalizedError {
    case invalidPage, invalidSelection, layoutLocked
    case insufficientSpace(page: Int, needed: Int, available: Int)
    var errorDescription: String? {
        switch self {
        case .layoutLocked: return "布局已锁定，请先解除锁定。"
        case .invalidPage: return "目标页面无效，请重新选择。"
        case .invalidSelection: return "所选图标已发生变化，请重新勾选。"
        case let .insufficientSpace(page, needed, available):
            return "第 \(page + 1) 页还有 \(available) 个空位，需要放入 \(needed) 项。请减少选择、先移出部分图标，或新建空白页。"
        }
    }
}

extension Layout {
    /// Plan the whole selection before changing anything. Existing destination icons stay put.
    func planBatchMove(_ ids: Set<String>, toPage page: Int, folderID: String? = nil) throws -> BatchPlacementPlan {
        guard !layoutLocked else { throw BatchPlacementError.layoutLocked }
        let capacity = columns * rows
        guard capacity > 0, page >= 0, page <= Self.maximumSlot / capacity else { throw BatchPlacementError.invalidPage }
        if let folderID, !tiles.contains(where: { $0.id == folderID && $0.isFolder }) { throw BatchPlacementError.invalidSelection }
        let before = resolvedPositions(folderID: folderID)
        guard !ids.isEmpty, ids.allSatisfy({ before[$0] != nil }) else { throw BatchPlacementError.invalidSelection }
        let incoming = ids.filter { before[$0]! / capacity != page }.sorted { before[$0]! < before[$1]! }
        let occupied = Set(before.values)
        let start = page * capacity
        let free = (start..<min(start + capacity, Self.maximumSlot + 1)).filter { !occupied.contains($0) }
        guard incoming.count <= free.count else {
            throw BatchPlacementError.insufficientSpace(page: page, needed: incoming.count, available: free.count)
        }
        var after = before
        for (id, slot) in zip(incoming, free) { after[id] = slot }
        return BatchPlacementPlan(folderID: folderID, capacity: capacity, targetPage: page, before: before, after: after, movedIDs: Set(incoming))
    }
    @discardableResult mutating func applyBatchMove(_ plan: BatchPlacementPlan) -> Bool {
        guard !layoutLocked, columns * rows == plan.capacity, resolvedPositions(folderID: plan.folderID) == plan.before else { return false }
        return setBatchPositions(plan.after, folderID: plan.folderID)
    }
    /// Undo only this move. Do not replace unrelated preferences or overwrite later icon moves.
    @discardableResult mutating func undoBatchMove(_ plan: BatchPlacementPlan) -> Bool {
        guard !layoutLocked, columns * rows == plan.capacity, !plan.movedIDs.isEmpty else { return false }
        var current = resolvedPositions(folderID: plan.folderID)
        guard plan.movedIDs.allSatisfy({ current[$0] == plan.after[$0] }) else { return false }
        let otherSlots = Set(current.filter { !plan.movedIDs.contains($0.key) }.values)
        guard plan.movedIDs.allSatisfy({ plan.before[$0].map { !otherSlots.contains($0) } ?? false }) else { return false }
        for id in plan.movedIDs { current[id] = plan.before[id] }
        return setBatchPositions(current, folderID: plan.folderID)
    }
    private mutating func setBatchPositions(_ slots: [String: Int], folderID: String?) -> Bool {
        if let folderID {
            guard let index = tiles.firstIndex(where: { $0.id == folderID && $0.isFolder }), validPositions(slots, ids: tiles[index].apps), slots.count == tiles[index].apps.count else { return false }
            folderPositions[folderID] = slots
            tiles[index].apps.sort { slots[$0]! < slots[$1]! }
        } else {
            guard validPositions(slots, ids: tiles.map(\.id)), slots.count == tiles.count else { return false }
            positions = slots
            tiles.sort { slots[$0.id]! < slots[$1.id]! }
        }
        normalizePositions()
        return true
    }
}
