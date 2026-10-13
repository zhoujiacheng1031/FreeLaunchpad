import AppKit
import Combine

@MainActor final class PageManagerState: ObservableObject {
    @Published var scopeID = ""
    @Published var sourcePage = -1
    @Published var destinationPage = 0
    @Published var query = ""
    @Published var showSelectedOnly = false
    @Published var focusSearchGeneration = 0
    @Published var selectedIDs = Set<String>()
    @Published var extraPage: Int?
    @Published var feedback = ""
    @Published var feedbackIsError = false
    @Published private(set) var undoPlan: PageManagerUndo?
    @Published var groupingPresented = false
    @Published var groupingTargetID = ""
    @Published var groupingName = "新建文件夹"
    @Published var groupingError = ""
    private var dragToken: String?
    private var dragScope: String?
    private var dragTileID: String?
    private var dragColumns = 0
    private var dragRows = 0
    private var dragSlot: Int?
    var previewDragViews = NSHashTable<NSView>.weakObjects()
    var cancelPreviewPointer: (() -> Void)?
    @Published var previewDragTile: Tile?
    @Published var previewDragPoint: CGPoint?
    @Published var previewDragIconSize: CGFloat = 48
    @Published var previewHoverPage: Int?
    @Published var previewHoverCell: Int?
    var folderID: String? { scopeID.isEmpty ? nil : scopeID }
    func configure(model: AppModel) {
        cancelPreviewDrag()
        scopeID = model.folderID ?? ""
        sourcePage = model.query.isEmpty ? model.page : -1
        destinationPage = max(0, model.page)
        extraPage = model.extraPage
        query = ""; showSelectedOnly = false; selectedIDs = []; feedback = ""; undoPlan = nil; groupingPresented = false
        reconcile(model: model)
    }
    func changeScope(_ id: String, model: AppModel) {
        cancelPreviewDrag()
        scopeID = id; sourcePage = -1; destinationPage = 0; extraPage = nil
        query = ""; showSelectedOnly = false; selectedIDs = []; feedback = ""; undoPlan = nil; groupingPresented = false
        reconcile(model: model)
    }
    func tiles(model: AppModel) -> [Tile] {
        if let folderID { return model.layout.tiles.first { $0.id == folderID && $0.isFolder }?.apps.map(Tile.app) ?? [] }
        return model.layout.tiles
    }
    func positions(model: AppModel) -> [String: Int] { model.layout.resolvedPositions(folderID: folderID) }
    func pageCount(model: AppModel) -> Int {
        max(1, (positions(model: model).values.max() ?? 0) / model.capacity + 1, (extraPage ?? -1) + 1, model.layout.namedPageCount(folderID: folderID))
    }
    func pages(model: AppModel) -> [Int] {
        let count = pageCount(model: model)
        if count <= 1000 { return Array(0..<count) }
        let names = folderID.map { model.layout.folderPageNames[$0] ?? [:] } ?? model.layout.pageNames
        let namedPages = names.keys.compactMap(Int.init).filter { $0 <= Layout.maximumSlot / model.capacity }
        return Array(Set(positions(model: model).values.map { $0 / model.capacity } + namedPages + [0, destinationPage] + (sourcePage >= 0 ? [sourcePage] : []) + (extraPage.map { [$0] } ?? []))).sorted()
    }
    func counts(model: AppModel) -> [Int: Int] {
        positions(model: model).values.reduce(into: [:]) { $0[$1 / model.capacity, default: 0] += 1 }
    }
    func visibleTiles(model: AppModel) -> [Tile] {
        let slots = positions(model: model)
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return tiles(model: model).filter { tile in
            if showSelectedOnly {
                guard selectedIDs.contains(tile.id) else { return false }
            } else {
                guard sourcePage < 0 || (slots[tile.id] ?? 0) / model.capacity == sourcePage else { return false }
            }
            if text.isEmpty { return true }
            let names = ([model.name(tile)] + tile.apps.map { model.record($0)?.searchText ?? $0 }).joined(separator: " ")
            return names.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(text)
        }.sorted { (slots[$0.id] ?? 0) < (slots[$1.id] ?? 0) }
    }
    /// Filtering never packs icons into new cells. Each preview is an actual page of the layout.
    func previewPages(model: AppModel) -> [Int] {
        if !showSelectedOnly && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sourcePage >= 0 ? [sourcePage] : pages(model: model)
        }
        let slots = positions(model: model)
        return Array(Set(visibleTiles(model: model).compactMap { slots[$0.id].map { $0 / model.capacity } })).sorted()
    }
    func previewTiles(on page: Int, model: AppModel) -> [Int: Tile] {
        let slots = positions(model: model)
        return Dictionary(uniqueKeysWithValues: visibleTiles(model: model).compactMap { tile in
            guard let slot = slots[tile.id], slot / model.capacity == page else { return nil }
            return (slot % model.capacity, tile)
        })
    }
    func beginPreviewDrag(_ id: String, model: AppModel) -> String? {
        guard !model.layout.layoutLocked, positions(model: model)[id] != nil else { return nil }
        let token = UUID().uuidString
        dragToken = token; dragScope = scopeID; dragTileID = id
        dragColumns = model.layout.columns; dragRows = model.layout.rows; dragSlot = positions(model: model)[id]
        return token
    }
    func cancelPreviewDrag() {
        cancelPreviewPointer?(); cancelPreviewPointer = nil
        dragToken = nil; dragTileID = nil; dragScope = nil
        previewDragTile = nil; previewDragPoint = nil; previewHoverPage = nil; previewHoverCell = nil
    }
    @discardableResult func dropPreview(_ token: String, on page: Int, cell: Int, model: AppModel) -> Bool {
        guard token == dragToken, scopeID == dragScope, let id = dragTileID,
              model.layout.columns == dragColumns, model.layout.rows == dragRows,
              positions(model: model)[id] == dragSlot else { return false }
        dragToken = nil; dragTileID = nil; dragScope = nil
        guard !model.layout.layoutLocked else { return false }
        guard page >= 0, page <= Layout.maximumSlot / model.capacity, (0..<model.capacity).contains(cell) else { return false }
        let slot = page * model.capacity + cell
        guard slot <= Layout.maximumSlot else { return false }
        let original = model.layout
        let before = positions(model: model)
        guard before[id] != slot, model.layout.place(id, at: slot, folderID: folderID) else { return false }
        guard model.save() else {
            model.layout = original; feedback = model.error ?? "保存失败，布局未更改。"; feedbackIsError = true; return false
        }
        let after = positions(model: model)
        let moved = Set(before.keys.filter { before[$0] != after[$0] })
        undoPlan = .move(BatchPlacementPlan(folderID: folderID, capacity: model.capacity, targetPage: page, before: before, after: after, movedIDs: moved))
        feedback = "已调整\(model.layout.pageTitle(page, folderID: folderID))的位置。"; feedbackIsError = false
        return true
    }
    func selectVisible(model: AppModel) {
        selectedIDs.formUnion(visibleTiles(model: model).map(\.id)); feedback = ""; feedbackIsError = false
    }
    func selectedOutsideList(model: AppModel) -> Int {
        selectedIDs.subtracting(Set(visibleTiles(model: model).map(\.id))).count
    }
    func toggle(_ id: String, selected: Bool) {
        if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
        feedback = ""
    }
    func incomingCount(model: AppModel) -> Int {
        let slots = positions(model: model)
        return selectedIDs.filter { slots[$0].map { $0 / model.capacity != destinationPage } ?? false }.count
    }
    func availableCount(model: AppModel) -> Int {
        let start = destinationPage * model.capacity
        let capacity = max(0, min(model.capacity, Layout.maximumSlot - start + 1))
        return max(0, capacity - (counts(model: model)[destinationPage] ?? 0))
    }
    func canMove(model: AppModel) -> Bool {
        let incoming = incomingCount(model: model)
        return !model.layout.layoutLocked && incoming > 0 && incoming <= availableCount(model: model)
    }
    func addPage(model: AppModel) {
        guard !model.layout.layoutLocked else { return }
        let page = pageCount(model: model)
        guard page <= Layout.maximumSlot / model.capacity else { return }
        extraPage = page; destinationPage = page; feedback = ""
    }
    func reconcile(model: AppModel) {
        if model.layout.layoutLocked { cancelPreviewDrag() }
        if !scopeID.isEmpty, !model.layout.tiles.contains(where: { $0.id == scopeID && $0.isFolder }) {
            changeScope("", model: model); return
        }
        selectedIDs.formIntersection(Set(tiles(model: model).map(\.id)))
        let count = pageCount(model: model)
        if sourcePage >= count { sourcePage = -1 }
        destinationPage = min(max(0, destinationPage), count - 1)
    }
    func move(model: AppModel) {
        do {
            let plan = try model.layout.planBatchMove(selectedIDs, toPage: destinationPage, folderID: folderID)
            guard !plan.movedIDs.isEmpty else { feedback = "所选图标已经在目标页。"; feedbackIsError = false; return }
            let original = model.layout
            guard model.layout.applyBatchMove(plan) else { throw BatchPlacementError.invalidSelection }
            guard model.save() else {
                model.layout = original; feedback = model.error ?? "保存失败，布局未更改。"; feedbackIsError = true; return
            }
            undoPlan = .move(plan)
            sourcePage = destinationPage; selectedIDs = []; query = ""; showSelectedOnly = false
            model.page = destinationPage; model.selectedPath = nil
            feedback = "已将 \(plan.movedIDs.count) 项移到\(model.layout.pageTitle(destinationPage, folderID: folderID))。"; feedbackIsError = false
        } catch { feedback = error.localizedDescription; feedbackIsError = true }
    }
    func undo(model: AppModel) {
        guard let plan = undoPlan else { return }
        guard !model.layout.layoutLocked else { feedback = "布局已锁定，请先解除锁定。"; feedbackIsError = true; return }
        let original = model.layout
        guard plan.apply(to: &model.layout) else {
            feedback = "布局已发生变化，无法撤销这次整理。请重新安排图标。"; feedbackIsError = true; undoPlan = nil; return
        }
        guard model.save() else { model.layout = original; feedback = model.error ?? "撤销未能保存。"; feedbackIsError = true; return }
        undoPlan = nil; selectedIDs = []; sourcePage = -1; query = ""; showSelectedOnly = false
        feedback = "已撤销本次整理。"; feedbackIsError = false
    }
    func canGroup(model: AppModel) -> Bool {
        guard folderID == nil, !model.layout.layoutLocked, !selectedIDs.isEmpty else { return false }
        return selectedIDs.count >= 2 || model.layout.tiles.contains { $0.isFolder && !selectedIDs.contains($0.id) }
    }
    func presentGrouping(model: AppModel) {
        guard canGroup(model: model) else { return }
        groupingTargetID = selectedIDs.count >= 2 ? "" : (model.layout.tiles.first { $0.isFolder && !selectedIDs.contains($0.id) }?.id ?? "")
        groupingName = "新建文件夹"; groupingError = ""; groupingPresented = true
    }
    func groupingPlan(model: AppModel) throws -> BatchGroupingPlan {
        guard folderID == nil else { throw BatchPlacementError.invalidSelection }
        return try model.layout.planBatchGroup(selectedIDs, into: groupingTargetID.isEmpty ? nil : groupingTargetID, name: groupingName)
    }
    func group(model: AppModel) {
        do {
            let plan = try groupingPlan(model: model)
            let original = model.layout
            guard model.layout.applyBatchGroup(plan) else { throw BatchPlacementError.invalidSelection }
            guard model.save() else { model.layout = original; groupingError = model.error ?? "保存失败，布局未更改。"; return }
            undoPlan = .group(plan); groupingPresented = false
            selectedIDs = []; query = ""; showSelectedOnly = false
            sourcePage = (model.layout.positions[plan.folderID] ?? 0) / model.capacity
            destinationPage = sourcePage; model.page = sourcePage; model.selectedPath = nil
            let name = model.layout.tiles.first { $0.id == plan.folderID }?.name ?? "文件夹"
            feedback = plan.createdNew ? "已创建‘\(name)’，包含 \(plan.incomingAppCount) 个应用。" : "已将 \(plan.incomingAppCount) 个应用移入‘\(name)’。"
            feedbackIsError = false
        } catch { groupingError = error.localizedDescription }
    }
    func promptPageName(_ page: Int, model: AppModel) {
        guard !model.layout.layoutLocked else { return }
        let alert = NSAlert(); alert.messageText = "命名第 \(page + 1) 页"
        alert.informativeText = "最多 40 个字符。留空可恢复默认页码；命名的空白页会保留。"
        let field = NSTextField(string: model.layout.pageName(page, folderID: folderID) ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.placeholderString = "例如：工作、沟通、系统"
        alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if model.renamePage(field.stringValue, page: page, folderID: folderID) {
            feedback = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "已恢复默认页码。" : "已命名：\(model.layout.pageTitle(page, folderID: folderID))。"
            feedbackIsError = false
        } else { feedback = model.error ?? "页面名称未能保存。"; feedbackIsError = true }
    }
    func toggleLock(model: AppModel) {
        if model.setLayoutLocked(!model.layout.layoutLocked) {
            feedback = model.layout.layoutLocked ? "布局已锁定，可继续浏览和搜索。" : "布局已解锁，可以继续整理。"
            feedbackIsError = false
        } else { feedback = model.error ?? "锁定状态未能保存。"; feedbackIsError = true }
    }
}
