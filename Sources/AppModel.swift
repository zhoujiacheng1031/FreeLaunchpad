import AppKit
import Combine
import UniformTypeIdentifiers
import ServiceManagement

@MainActor final class AppModel: ObservableObject {
    @Published var layout = Layout()
    @Published var catalog: [AppRecord] = []
    @Published var query = ""
    @Published var page = 0
    @Published var extraPage: Int?
    @Published var folderID: String?
    @Published var selectedPath: String?
    @Published var showGeneration = 0
    @Published var contentInsets = LauncherInsets()
    @Published var desktopImageURL: URL?
    @Published var backgroundImage: NSImage?
    @Published var backgroundStatus = ""
    private var backgroundScreen: NSScreen?
    private var loadedBackgroundURL: URL?
    private var loadedBackgroundMode: String?
    @Published var draggedID: String?
    @Published var dropSlot: Int?
    @Published var dropTargetID: String?
    @Published var dropWillGroup = false
    @Published var dragNavigationID: String?
    var activeDragSource: NSObject?
    var dragViews = NSHashTable<NSView>.weakObjects()
    var cancelPointerDrag: (() -> Void)?
    @Published var dragWindowPoint: CGPoint?
    @Published var dragImage: NSImage?
    @Published var dragImageSize: CGFloat = 88
    private var dragToken = UUID().uuidString
    private var dragOriginFolder: String?
    private var navigationWork: DispatchWorkItem?
    @Published var error: String?
    @Published var scanning = false
    @Published var backupStatus = ""
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginMessage = ""
    let stateURL: URL
    private var icons: [String: NSImage] = [:]
    var dismiss: (() -> Void)?
    var showSettings: (() -> Void)?
    var showPageManager: (() -> Void)?
    var showAppGroups: (([String]?) -> Void)?
    var performAppBatch: ((AppBatchAction, [String]) -> Void)?
    var startDesktopWorkspace: (([String]) -> Void)?
    var openWorkspacePermissions: (() -> Void)?
    var showManagedPage: ((String?, Int) -> Void)?
    var configurationChanged: (() -> Void)?
    var scanGeneration = 0

    init(stateDirectory: URL? = nil, scanOnStart: Bool = true) {
        let args = ProcessInfo.processInfo.arguments
        let directory: URL
        if let stateDirectory { directory = stateDirectory }
        else if let index = args.firstIndex(of: "--state-dir"), args.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: args[index + 1])
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FreeLaunchpad")
        }
        stateURL = directory.appendingPathComponent("layout.json")
        if FileManager.default.fileExists(atPath: stateURL.path) {
            do { layout = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: stateURL)).validated() }
            catch { self.error = "读取布局失败：\(error.localizedDescription)。原文件保留，保存前请先检查。" }
        }
        if scanOnStart { refresh() }
    }
    var folder: Tile? { layout.tiles.first { $0.id == folderID && $0.isFolder } }
    var filtered: [AppRecord] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let hidden = Set(layout.hidden)
        return catalog.filter { !hidden.contains($0.path) && $0.searchText.contains(text) }
    }
    var displayedTiles: [Tile] {
        if !query.isEmpty { return filtered.map { .app($0.path) } }
        if let folder { return folder.apps.map(Tile.app) }
        return layout.tiles
    }
    var capacity: Int { layout.columns * layout.rows }
    var tilePositions: [String: Int] {
        if !query.isEmpty { return Dictionary(uniqueKeysWithValues: displayedTiles.enumerated().map { ($0.element.id, $0.offset) }) }
        return layout.resolvedPositions(folderID: folderID)
    }
    var pageCount: Int { max(1, (tilePositions.values.max() ?? 0) / capacity + 1, query.isEmpty ? max((extraPage ?? -1) + 1, layout.namedPageCount(folderID: folderID)) : 1) }
    var navigationPages: [Int] {
        if pageCount <= 11 { return Array(0..<pageCount) }
        return Array(Set([0, pageCount - 1] + Array(max(0, page - 3)...min(pageCount - 1, page + 3)))).sorted()
    }
    func navigate(_ offset: Int) {
        let slots = tilePositions
        guard !slots.isEmpty else { return }
        guard let selectedPath, let current = slots[selectedPath] else {
            let first = slots.filter { $0.value / capacity == page }.min { $0.value < $1.value } ?? slots.min { $0.value < $1.value }
            self.selectedPath = first?.key
            if let first { page = first.value / capacity }
            return
        }
        let next: (key: String, value: Int)?
        if abs(offset) == layout.columns {
            let row = current / layout.columns, col = current % layout.columns
            next = slots.filter { offset > 0 ? $0.value / layout.columns > row : $0.value / layout.columns < row }
                .min { left, right in
                    let lrow = abs(left.value / layout.columns - row), rrow = abs(right.value / layout.columns - row)
                    if lrow != rrow { return lrow < rrow }
                    let lcol = abs(left.value % layout.columns - col), rcol = abs(right.value % layout.columns - col)
                    return lcol == rcol ? left.value < right.value : lcol < rcol
                }
        } else {
            next = slots.filter { offset > 0 ? $0.value > current : $0.value < current }.min { abs($0.value - current) < abs($1.value - current) }
        }
        if let next { self.selectedPath = next.key; page = next.value / capacity }
    }
    func addPage() {
        guard canArrange, pageCount < 1000 else { return }
        let next = pageCount; extraPage = next; page = next; selectedPath = nil
    }
    var pageTiles: [Tile] {
        let slots = tilePositions
        return displayedTiles.filter { (slots[$0.id] ?? 0) / capacity == page }
    }
    func slot(of id: String) -> Int? { tilePositions[id] }
    func tile(at slot: Int) -> Tile? {
        let slots = tilePositions
        return displayedTiles.first { slots[$0.id] == slot }
    }
    func record(_ path: String) -> AppRecord? { catalog.first { $0.path == path } }
    func name(_ tile: Tile) -> String { tile.isFolder ? tile.name : record(tile.apps.first ?? "")?.name ?? "应用" }
    func icon(_ path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 128, height: 128)
        icons[path] = icon
        return icon
    }
    func refresh() {
        scanning = true
        scanGeneration += 1
        let generation = scanGeneration
        let extra = layout.extraPaths
        let own = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = CatalogScanner.scan(extraPaths: extra, excluding: own)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                self.catalog = apps
                self.icons.removeAll()
                self.layout.reconcile(apps)
                self.scanning = false
                self.page = min(self.page, self.pageCount - 1)
                // Do not overwrite an unreadable original state during automatic discovery.
                if self.error == nil { self.save() }
            }
        }
    }
    @discardableResult func save() -> Bool {
        do {
            layout.normalizePositions()
            if folderID != nil && folder == nil { folderID = nil; extraPage = nil; page = 0; finishDrag() }
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encode(layout.validated())
            try data.write(to: stateURL, options: .atomic)
            updateBackground()
            configurationChanged?()
            return true
        } catch { self.error = "保存失败：\(error.localizedDescription)"; return false }
    }
    static func encode(_ layout: Layout) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(layout)
    }
    func updateBackground(screen: NSScreen? = nil, force: Bool = false) {
        if let screen { backgroundScreen = screen }
        let activeScreen = backgroundScreen ?? NSScreen.main
        let customURL = layout.backgroundPath.map { URL(fileURLWithPath: $0) }
        if !force && loadedBackgroundMode == layout.backgroundMode && backgroundImage != nil && (layout.backgroundMode != "image" || loadedBackgroundURL == customURL) { return }
        loadedBackgroundMode = layout.backgroundMode
        if layout.backgroundMode == "image" {
            loadedBackgroundURL = customURL; backgroundImage = customURL.flatMap { NSImage(contentsOf: $0) }
        } else {
            let wallpaper = WallpaperResolver.load(for: activeScreen)
            desktopImageURL = wallpaper.url
            loadedBackgroundURL = wallpaper.url; backgroundImage = wallpaper.image
        }
        backgroundStatus = layout.backgroundMode == "image"
            ? (backgroundImage == nil ? "请选择一张背景图片。" : "使用自定义图片")
            : (backgroundImage == nil ? "系统未提供可读取的壁纸；可选择图片或使用当前桌面。" : "已读取当前显示器的桌面壁纸")
    }
    func launch(_ path: String) {
        guard catalog.contains(where: { $0.path == path }) else { return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config) { [weak self] _, failure in
            DispatchQueue.main.async {
                if let failure { self?.error = "无法打开应用：\(failure.localizedDescription)" }
                else { self?.dismiss?() }
            }
        }
    }
    func activate(_ tile: Tile) {
        if tile.isFolder { folderID = tile.id; extraPage = nil; page = 0; selectedPath = nil }
        else if let path = tile.apps.first { launch(path) }
    }
    func hide(_ path: String) {
        guard !layout.layoutLocked else { return }
        layout.hide(path)
        if folderID != nil && folder == nil { folderID = nil; extraPage = nil; page = 0 }
        page = min(page, pageCount - 1); save()
    }
    func unhide(_ path: String) { guard !layout.layoutLocked else { return }; layout.unhide(path); layout.reconcile(catalog); save() }
    func move(_ source: String, to target: String) {
        guard canArrange, folderID == nil else { return }
        layout.move(source, before: target); save()
    }
    var canArrange: Bool { query.isEmpty && !layout.layoutLocked }
    @discardableResult func setLayoutLocked(_ locked: Bool) -> Bool {
        let original = layout
        if locked { finishDrag() }
        layout.layoutLocked = locked
        guard save() else { layout = original; return false }
        return true
    }
    @discardableResult func renamePage(_ name: String, page: Int, folderID: String?) -> Bool {
        let original = layout
        guard layout.setPageName(name, page: page, folderID: folderID) else {
            error = layout.layoutLocked ? "布局已锁定，请先解除锁定。" : "页面名称最多 40 个字符，不能包含换行或控制字符。"
            return false
        }
        guard save() else { layout = original; return false }
        return true
    }
    func beginDrag(_ id: String) -> String {
        finishDrag()
        guard canArrange else { return UUID().uuidString }
        draggedID = id; dragOriginFolder = folderID; dragToken = UUID().uuidString
        return dragToken
    }
    func finishDrag() {
        navigationWork?.cancel(); navigationWork = nil
        let cancel = cancelPointerDrag; cancelPointerDrag = nil
        cancel?(); activeDragSource = nil; dragWindowPoint = nil; dragImage = nil
        draggedID = nil; dropSlot = nil; dropTargetID = nil; dropWillGroup = false; dragNavigationID = nil
    }
    func acceptsDrag(_ token: String) -> Bool { draggedID != nil && dragToken == token && canArrange && folderID == dragOriginFolder }
    func hoverSlot(_ slot: Int, group: Bool) {
        guard canArrange, draggedID != nil else { return }
        if let navigation = dragNavigationID { leaveNavigation(navigation) }
        dropSlot = slot
        let target = tile(at: slot)
        dropTargetID = target?.id == draggedID ? nil : target?.id
        dropWillGroup = group && folderID == nil && dropTargetID != nil
    }
    func dropSlot(token: String, slot: Int, group: Bool) {
        guard acceptsDrag(token), let source = draggedID else { return }
        if group, folderID == nil, let target = tile(at: slot), target.id != source {
            layout.groupTile(source, with: target.id)
        } else { layout.place(source, at: slot, folderID: folderID) }
        page = min(slot / capacity, pageCount - 1)
        finishDrag(); save()
    }
    func dropTile(token: String, target: String, group: Bool) {
        guard let slot = slot(of: target) else { return }
        dropSlot(token: token, slot: slot, group: group)
    }
    func dropPage(token: String, target: Int) {
        guard target >= 0 && target < pageCount else { return }
        dropSlot(token: token, slot: layout.firstFreeSlot(on: target, capacity: capacity, folderID: folderID), group: false)
    }
    func hoverNavigation(_ id: String, target: Int, repeatDelta: Int? = nil) {
        guard draggedID != nil, canArrange, dragNavigationID != id else { return }
        navigationWork?.cancel(); dragNavigationID = id; dropTargetID = nil; dropSlot = nil
        scheduleNavigation(id, target: target, repeatDelta: repeatDelta)
    }
    private func scheduleNavigation(_ id: String, target: Int, repeatDelta: Int?) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.draggedID != nil, self.dragNavigationID == id else { return }
            self.page = min(max(0, target), self.pageCount - 1)
            if let delta = repeatDelta, self.page + delta >= 0, self.page + delta < self.pageCount {
                self.scheduleNavigation(id, target: self.page + delta, repeatDelta: delta)
            }
        }
        navigationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
    }
    func leaveNavigation(_ id: String) {
        if dragNavigationID == id { navigationWork?.cancel(); navigationWork = nil; dragNavigationID = nil }
    }
    func movePage(_ delta: Int) {
        page = min(max(0, page + delta), pageCount - 1)
        selectedPath = nil
    }
    func escape() {
        if !query.isEmpty { query = ""; page = 0 }
        else if folderID != nil { folderID = nil; extraPage = nil; page = 0 }
        else { dismiss?() }
    }
    func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "FreeLaunchpad-layout.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Self.encode(layout).write(to: url, options: .atomic); backupStatus = "备份已保存" }
        catch { self.error = "备份失败：\(error.localizedDescription)" }
    }
    func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8_000_000 else { throw LayoutError.invalidBackup }
            let incoming = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: url)).validated()
            // Preserve the previous layout before accepting a restore.
            let previous = stateURL.deletingLastPathComponent().appendingPathComponent("before-restore.json")
            try Self.encode(layout).write(to: previous, options: .atomic)
            layout = incoming
            page = 0; folderID = nil; query = ""
            save(); refresh()
            backupStatus = "已恢复；原布局保存在 before-restore.json"
        } catch { self.error = "恢复失败：\(error.localizedDescription)" }
    }
    func chooseBackground() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard NSImage(contentsOf: url) != nil else { error = "无法读取此图片。"; return }
        do {
            let directory = stateURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Data(contentsOf: url)
            let stored = directory.appendingPathComponent("background.\(url.pathExtension)")
            try data.write(to: stored, options: .atomic)
            layout.backgroundPath = stored.path; layout.backgroundMode = "image"; save()
        } catch { self.error = "背景保存失败：\(error.localizedDescription)" }
    }
    func addPath() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url, !layout.extraPaths.contains(url.path) else { return }
        layout.extraPaths.append(url.path); save(); refresh()
    }
    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
            loginMessage = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许。" : "已更新"
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginMessage = error.localizedDescription
        }
    }
}
