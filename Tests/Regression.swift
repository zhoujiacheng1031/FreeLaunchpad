import Foundation
import AppKit

@MainActor final class FakeLifecycle: AppLifecycleDriver {
    var running: [String: [AppInstance]] = [:]
    var launches: [String] = []
    var quits: [pid_t] = []
    var failLaunch = Set<String>()
    var refuseQuit = Set<pid_t>()
    var quitImmediately = true
    func instances(at path: String) -> [AppInstance] { running[path] ?? [] }
    func launch(_ path: String) async throws {
        launches.append(path)
        if failLaunch.contains(path) { throw CocoaError(.fileReadNoSuchFile) }
        running[path] = [AppInstance(pid: 800001 + Int32(launches.count), path: path, bundleID: "test.app")]
    }
    func quit(_ instance: AppInstance) -> Bool {
        quits.append(instance.pid)
        guard !refuseQuit.contains(instance.pid) else { return false }
        if quitImmediately { running[instance.path]?.removeAll { $0.pid == instance.pid } }
        return true
    }
}
@MainActor final class FakeDesktop: DesktopWorkspaceDriver {
    var allowed = true
    var createFails = false
    var created = 0
    var entries: [String: [WorkspaceWindow]] = [:]
    var moved: [UInt32] = []
    var failWindows = Set<UInt32>()
    func checkAvailability() throws { if !allowed { throw WorkspaceError.unavailable("需要辅助功能权限") } }
    func createDesktop() async throws -> UInt64 {
        if createFails { throw WorkspaceError.unavailable("新建桌面失败") }
        created += 1; return 88
    }
    func windows(at path: String) -> [WorkspaceWindow] { entries[path] ?? [] }
    func move(_ window: WorkspaceWindow, to desktop: UInt64) throws {
        if failWindows.contains(window.id) { throw WorkspaceError.unavailable("不能移动全屏窗口") }
        moved.append(window.id)
    }
}

@main struct Regression {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError(message) }
    }
    static func rejected(_ layout: Layout) -> Bool { (try? layout.validated()) == nil }
    @MainActor static func main() async throws {
        // Topologies captured from Dock (legacy) and WindowManager (macOS 27).
        struct MCNode: Equatable {
            var id: String
            var display: UInt32? = nil
            var children: [MCNode] = []
        }
        let mainDisplay = MCNode(id: "mc.display", display: 2, children: [MCNode(id: "mc.spaces")])
        let otherDisplay = MCNode(id: "mc.display", display: 99)
        let emptyDock = MCNode(id: "Dock", children: [MCNode(id: "mc")])
        let legacyDock = MCNode(id: "Dock", children: [MCNode(id: "mc", children: [otherDisplay, mainDisplay])])
        let modernManager = MCNode(id: "WindowManager", children: [otherDisplay, mainDisplay])
        func mcDisplay(_ roots: [MCNode], screen: UInt32 = 2) -> MCNode? {
            MissionControlTree.display(in: roots, screenID: screen, identifier: { $0.id },
                                      displayID: { $0.display }, children: { $0.children })
        }
        check(MissionControlTree.hostBundleIDs.contains("com.apple.WindowManager") && MissionControlTree.hostBundleIDs.contains("com.apple.dock"), "Probe both observed Mission Control hosts")
        check(mcDisplay([emptyDock, modernManager]) == mainDisplay, "Empty Dock mc group must not shadow WindowManager display")
        check(mcDisplay([legacyDock]) == mainDisplay, "Legacy Dock hierarchy selects matching monitor")
        check(mcDisplay([emptyDock]) == nil, "Empty retained mc group is not visible Mission Control")
        check(mcDisplay([modernManager], screen: 33) == nil, "Never create on a different monitor")

        var membershipReads = 0
        let confirmedMove = try await WorkspaceMembership.confirm(target: 88, read: {
            membershipReads += 1
            return membershipReads < 3 ? [77] : [88]
        }, pause: {})
        check(confirmedMove && membershipReads == 3, "Async move waits for actual membership instead of accepting submission")
        let noMove = try await WorkspaceMembership.confirm(target: 88, read: { [77] }, pause: {})
        check(!noMove, "A silently ignored system move must time out as failure")
        let stickyMove = try await WorkspaceMembership.confirm(target: 88, read: { [77, 88] }, pause: {})
        check(!stickyMove, "Multi-space membership is not exclusive placement")

        let apps = ["A", "B", "C", "D"].map { AppRecord(path: "/Applications/\($0).app", name: $0, bundleID: "test.\($0)") }
        let a = apps[0].path, b = apps[1].path, c = apps[2].path, d = apps[3].path
        var layout = Layout()
        layout.tiles = [.folder([a, b], name: "工作"), .app(a), .app("/missing.app")]
        layout.reconcile(apps)
        check(layout.tiles.flatMap(\.apps) == [a, b, c, d], "Discovery must deduplicate folders and append newly installed apps")
        check(layout.tiles.count == 3, "Unavailable applications should leave no empty tiles")
        let reconciled = layout
        layout.reconcile(apps)
        check(layout == reconciled, "Discovery must be idempotent")
        layout.hide(b); layout.reconcile(apps)
        check(!layout.tiles.flatMap(\.apps).contains(b), "Hidden apps must stay hidden during refresh")
        layout.unhide(b); layout.unhide(b)
        check(layout.tiles.flatMap(\.apps).filter { $0 == b }.count == 1, "Unhide must not duplicate apps")
        layout.group(b, with: c)
        let group = layout.tiles.first { $0.apps.contains(c) }!
        check(group.isFolder && group.apps == [c, b], "Grouping apps must replace the target with a folder")
        layout.group(d, with: group.id)
        check(layout.tiles.first { $0.id == group.id }?.apps == [c, b, d], "Move into an existing folder")
        let beforeSelfGroup = layout
        layout.group(c, with: group.id)
        check(layout == beforeSelfGroup, "Dragging an app onto its own folder must not remove it")
        layout.extract(b)
        check(layout.tiles.last == .app(b) && layout.tiles.flatMap(\.apps).filter { $0 == b }.count == 1, "Extracting must retain exactly one app")
        layout.ungroup(group.id)
        check(!layout.tiles.contains { $0.id == group.id }, "Ungroup must remove the folder")
        check(Set(layout.tiles.flatMap(\.apps)) == Set(apps.map(\.path)), "Ungroup must preserve all apps")
        layout.move(b, before: c)
        check(layout.tiles.firstIndex { $0.id == b }! < layout.tiles.firstIndex { $0.id == c }!, "Reorder must move before the target")
        let beforeBadMove = layout
        layout.move("nonexistent", before: c)
        check(layout == beforeBadMove, "Unknown drag source must not change layout")
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(Layout.self, from: data).validated()
        check(decoded == layout, "Backup roundtrip")
        var legacyJSON = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacyJSON.removeValue(forKey: "hideDock")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        let legacy = try JSONDecoder().decode(Layout.self, from: legacyData).validated()
        check(!legacy.hideDock && legacy.tiles == layout.tiles, "Old backups must preserve layout and default to system Dock behavior")
        var dockHiddenLayout = layout; dockHiddenLayout.hideDock = true
        let dockBackup = try JSONDecoder().decode(Layout.self, from: JSONEncoder().encode(dockHiddenLayout)).validated()
        check(dockBackup.hideDock, "Dock preference must survive backup roundtrip")

        var oldAppearance = legacyJSON
        oldAppearance.removeValue(forKey: "appearanceRevision")
        oldAppearance.removeValue(forKey: "backgroundOpacity")
        oldAppearance.removeValue(forKey: "backgroundMode")
        oldAppearance["iconSize"] = 64
        let upgraded = try JSONDecoder().decode(Layout.self, from: JSONSerialization.data(withJSONObject: oldAppearance)).validated()
        check(upgraded.iconSize == 88 && upgraded.appearanceRevision == 2, "Old default icons must upgrade to the larger default once")
        check(upgraded.backgroundOpacity == 0.82 && upgraded.backgroundMode == "wallpaper", "Old layouts must get usable transparency and wallpaper defaults")
        oldAppearance["iconSize"] = 76
        let customized = try JSONDecoder().decode(Layout.self, from: JSONSerialization.data(withJSONObject: oldAppearance)).validated()
        check(customized.iconSize == 76, "Migration must preserve customized icon sizes")
        var transparent = upgraded; transparent.backgroundOpacity = 0; transparent.backgroundMode = "desktop"; transparent.iconSize = 128
        let transparencyBackup = try JSONDecoder().decode(Layout.self, from: JSONEncoder().encode(transparent)).validated()
        check(transparencyBackup == transparent, "Fully transparent desktop and large icons must survive backup roundtrip")
        transparent.backgroundOpacity = .nan
        check(rejected(transparent), "Nonfinite transparency must be rejected")
        transparent.backgroundOpacity = 1.1
        check(rejected(transparent), "Out-of-range transparency must be rejected")
        transparent.backgroundOpacity = 0.5; transparent.backgroundMode = "unknown"
        check(rejected(transparent), "Unknown background source must be rejected")

        // Exact release location, rather than only the destination page, is the regression oracle.
        var free = Layout(); free.tiles = (0..<36).map { Tile.app("/Applications/Free\($0).app") }
        let source = free.tiles[0].id, occupied = free.tiles[1].id
        let originalSlots = free.resolvedPositions()
        check(free.place(source, at: 41), "Cross-page free placement must accept the release cell")
        check(free.positions[source] == 41 && !free.positions.values.contains(0), "Page 2 cell 7 must stay at slot 41 and leave the original hole")
        check(originalSlots.filter { $0.key != source } == free.positions.filter { $0.key != source }, "Empty-cell moves must not shift unrelated icons")
        free.place(source, at: 1)
        check(free.positions[source] == 1 && free.positions[occupied] == 41, "Occupied cells must swap, including across pages")
        let freeBackup = try JSONDecoder().decode(Layout.self, from: JSONEncoder().encode(free)).validated()
        check(freeBackup == free, "Backup must retain sparse locations")
        let freeCatalog = free.tiles.map { AppRecord(path: $0.id, name: $0.id, bundleID: "") }
        free.reconcile(freeCatalog)
        check(free.positions[source] == 1 && free.positions[occupied] == 41 && !free.positions.values.contains(0), "Rescan must preserve intentional holes")
        free.reconcile(freeCatalog + [AppRecord(path: "/Applications/New.app", name: "New", bundleID: "")])
        check(free.positions["/Applications/New.app"] == 42, "New discovery must append without filling intentional holes")
        let beforeInvalidSlot = free
        free.place(source, at: -1); free.place("missing", at: 0)
        check(free == beforeInvalidSlot, "Invalid release cells must leave the layout unchanged")
        var malformed = free; malformed.positions[source] = -1
        check(rejected(malformed), "Backups with negative positions must be rejected")
        malformed = free; malformed.positions[source] = malformed.positions[occupied]
        check(rejected(malformed), "Backups with overlapping slots must be rejected")
        malformed = free; malformed.positions["unknown"] = 700
        check(rejected(malformed), "Backups with unknown tile positions must be rejected")
        var legacySlots = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Layout())) as! [String: Any]
        legacySlots["version"] = 1
        legacySlots["tiles"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([Tile.app(a), Tile.app(b)]))
        legacySlots.removeValue(forKey: "positions"); legacySlots.removeValue(forKey: "folderPositions")
        let slotMigration = try JSONDecoder().decode(Layout.self, from: JSONSerialization.data(withJSONObject: legacySlots)).validated()
        check(slotMigration.version == 5, "Legacy layouts must migrate to schema 5 while retaining sparse positions")
        check(slotMigration.resolvedPositions() == [a: 0, b: 1], "Old layouts must retain their original dense order")
        var groupingSlots = Layout(); groupingSlots.tiles = [.app(a), .app(b), .app(c)]
        groupingSlots.place(b, at: 48); groupingSlots.group(a, with: b)
        let positionedFolder = groupingSlots.tiles.first { $0.isFolder }!
        check(groupingSlots.positions[positionedFolder.id] == 48, "New folders must remain at the destination icon's slot")
        groupingSlots.place(a, at: 41, folderID: positionedFolder.id)
        check(groupingSlots.folderPositions[positionedFolder.id]?[a] == 41, "Folder contents must support sparse cross-page placement")
        groupingSlots.group(c, with: positionedFolder.id)
        check(groupingSlots.folderPositions[positionedFolder.id]?[a] == 41, "Adding to a folder must preserve existing sparse positions")
        groupingSlots.ungroup(positionedFolder.id)
        check(groupingSlots.positions[b] == 48 && Set(groupingSlots.tiles.flatMap(\.apps)) == Set([a,b,c]), "Ungroup must preserve the folder's root position and all apps")
        let wideGrid = LauncherGridGeometry(size: CGSize(width: LauncherGridGeometry.width(for: 2304), height: 1080), columns: 7, rows: 5)
        check(wideGrid.size.width / 2304 > 0.9, "Large-screen icon area must occupy over 90% of available width")
        check(wideGrid.iconSize(requested: 128) == 128 && wideGrid.cellWidth > 128 + 32, "Large screens must accommodate 128pt icons with room between them")
        check(wideGrid.cell(at: wideGrid.center(of: 6)) == 6 && wideGrid.cell(at: wideGrid.center(of: 34)) == 34, "Release coordinates must map to the rendered invisible grid")
        check(wideGrid.cell(at: CGPoint(x: -1, y: 10)) == nil && wideGrid.cell(at: CGPoint(x: wideGrid.size.width, y: 10)) == nil, "Outside release positions must be rejected")
        let smallGrid = LauncherGridGeometry(size: CGSize(width: LauncherGridGeometry.width(for: 1280), height: 580), columns: 10, rows: 7)
        check(smallGrid.iconSize(requested: 128) + 58 <= smallGrid.cellHeight, "Small-screen icons must fit their labels and row spacing")
        let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("free-launchpad-grid-regression-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        var spaced = free; spaced.horizontalSpacing = 0.25; spaced.verticalSpacing = 0.7
        let spacedBackup = try JSONDecoder().decode(Layout.self, from: JSONEncoder().encode(spaced)).validated()
        check(spacedBackup == spaced, "Spacing preferences must survive a backup roundtrip")
        var v3 = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spaced)) as! [String: Any]
        v3["version"] = 3; v3.removeValue(forKey: "horizontalSpacing"); v3.removeValue(forKey: "verticalSpacing")
        let upgradedV3 = try JSONDecoder().decode(Layout.self, from: JSONSerialization.data(withJSONObject: v3)).validated()
        check(upgradedV3.version == 5 && upgradedV3.horizontalSpacing == 1 && upgradedV3.verticalSpacing == 1 && upgradedV3.positions == spaced.positions, "Version 3 migration must retain exact cells and the previous full-area spacing")
        var badSpacing = spaced; badSpacing.horizontalSpacing = -.infinity
        check(rejected(badSpacing), "Nonfinite horizontal spacing must be rejected")
        badSpacing.horizontalSpacing = 0.2; badSpacing.verticalSpacing = 1.01
        check(rejected(badSpacing), "Out-of-range vertical spacing must be rejected")
        badSpacing.verticalSpacing = -0.1
        check(rejected(badSpacing), "Negative spacing must be rejected")
        let compactGrid = LauncherGridGeometry(size: wideGrid.size, columns: 7, rows: 5, requestedIconSize: 128, horizontalSpacing: 0, verticalSpacing: 0)
        let hiddenDockCanvas = LauncherCanvasMetrics.gridSize(screen: CGSize(width: 2304, height: 1296), insets: LauncherInsets(top: 36))
        let sideDockCanvas = LauncherCanvasMetrics.gridSize(screen: CGSize(width: 2304, height: 1296), insets: LauncherInsets(top: 36, leading: 74))
        let bottomDockCanvas = LauncherCanvasMetrics.gridSize(screen: CGSize(width: 2304, height: 1296), insets: LauncherInsets(top: 36, bottom: 66))
        check(sideDockCanvas.width < hiddenDockCanvas.width && sideDockCanvas.height == hiddenDockCanvas.height, "Side Dock previews must use the same reduced launcher width")
        check(bottomDockCanvas.height == hiddenDockCanvas.height - 66 && bottomDockCanvas.width == hiddenDockCanvas.width, "Bottom Dock previews must use the same reduced launcher height")
        check(compactGrid.cellWidth == 160 && compactGrid.cellHeight == 186 && compactGrid.iconSize(requested: 128) == 128, "Compact spacing must keep large icons and labels separate")
        check(compactGrid.center(of: 17) == CGPoint(x: wideGrid.size.width / 2, y: wideGrid.size.height / 2), "Compact layouts must remain centered in the whole launcher canvas")
        check(compactGrid.cell(at: .zero) == nil, "Empty outer margins must not map to an icon slot after reducing spacing")
        check((0..<35).allSatisfy { compactGrid.cell(at: compactGrid.center(of: $0)) == $0 }, "Every compressed visible cell must match its release coordinates")
        let horizontalOnly = LauncherGridGeometry(size: wideGrid.size, columns: 7, rows: 5, requestedIconSize: 128, horizontalSpacing: 0.4, verticalSpacing: 1)
        check(horizontalOnly.cellHeight == wideGrid.cellHeight && horizontalOnly.cellWidth > compactGrid.cellWidth && horizontalOnly.cellWidth < wideGrid.cellWidth, "Horizontal spacing must change independently of vertical spacing")
        let denseCompact = LauncherGridGeometry(size: smallGrid.size, columns: 10, rows: 7, requestedIconSize: 128, horizontalSpacing: 0, verticalSpacing: 0)
        check(denseCompact.iconSize(requested: 128) + 58 <= denseCompact.cellHeight && denseCompact.cell(at: denseCompact.center(of: 69)) == 69, "Small-screen compressed grids must fit labels and preserve last-cell drop accuracy")
        let previewModel = AppModel(stateDirectory: stateDir.appendingPathComponent("preview"), scanOnStart: false)
        previewModel.layout.columns = 4; previewModel.layout.rows = 3
        previewModel.layout.tiles = apps.map { .app($0.path) }; previewModel.catalog = apps
        previewModel.layout.place(a, at: 7); previewModel.layout.place(d, at: 25)
        let preview = PageManagerState(); preview.configure(model: previewModel); preview.sourcePage = -1
        check(preview.previewPages(model: previewModel) == [0, 1, 2] && preview.previewTiles(on: 1, model: previewModel).isEmpty, "All-page previews must include intervening empty pages")
        check(preview.previewTiles(on: 0, model: previewModel)[7]?.id == a && preview.previewTiles(on: 0, model: previewModel)[0] == nil, "Page previews must retain actual sparse cells instead of packing icons")
        preview.query = "A"
        check(preview.previewPages(model: previewModel) == [0] && preview.previewTiles(on: 0, model: previewModel).keys.sorted() == [7], "Search previews must retain an icon's original cell")
        preview.query = ""; preview.selectedIDs = [a, d]; preview.showSelectedOnly = true
        check(preview.previewPages(model: previewModel) == [0, 2] && preview.previewTiles(on: 2, model: previewModel)[1]?.id == d, "Selected-only previews must retain all selected pages and their original cells")
        preview.showSelectedOnly = false; preview.sourcePage = 1
        check(preview.previewPages(model: previewModel) == [1], "A selected empty page must still have a spatial preview")
        let previewBefore = previewModel.layout.resolvedPositions()
        let previewToken = preview.beginPreviewDrag(a, model: previewModel)!
        check(!preview.dropPreview("external-token", on: 1, cell: 5, model: previewModel) && previewModel.layout.resolvedPositions() == previewBefore, "Preview drops must reject external or stale drag tokens")
        check(preview.dropPreview(previewToken, on: 1, cell: 5, model: previewModel) && previewModel.layout.positions[a] == 17, "Preview drag must persist the exact cross-page empty cell")
        check(!preview.dropPreview(previewToken, on: 2, cell: 0, model: previewModel), "A completed preview drag token must not be reused")
        previewModel.layout.horizontalSpacing = 0.3; preview.undo(model: previewModel)
        check(previewModel.layout.resolvedPositions() == previewBefore && previewModel.layout.horizontalSpacing == 0.3, "Preview undo must restore the exact source hole while retaining spacing changes")
        let swapToken = preview.beginPreviewDrag(a, model: previewModel)!
        check(preview.dropPreview(swapToken, on: 0, cell: 1, model: previewModel) && previewModel.layout.positions[b] == 7 && previewModel.layout.positions[a] == 1, "Preview drops on occupied cells must swap both items")
        preview.undo(model: previewModel)
        check(previewModel.layout.resolvedPositions() == previewBefore, "Preview swap undo must restore both items")
        let resizeToken = preview.beginPreviewDrag(a, model: previewModel)!
        previewModel.layout.columns = 5
        check(!preview.dropPreview(resizeToken, on: 1, cell: 2, model: previewModel), "Changing grid dimensions must invalidate an in-flight preview drag")
        previewModel.layout.columns = 4
        let lockToken = preview.beginPreviewDrag(a, model: previewModel)!
        previewModel.layout.layoutLocked = true
        check(!preview.dropPreview(lockToken, on: 1, cell: 5, model: previewModel) && preview.beginPreviewDrag(a, model: previewModel) == nil, "Layout locking must block both starting and completing a preview drag")
        previewModel.layout.layoutLocked = false
        let scopeToken = preview.beginPreviewDrag(a, model: previewModel)!
        preview.changeScope("", model: previewModel)
        check(!preview.dropPreview(scopeToken, on: 1, cell: 5, model: previewModel), "Scope changes must invalidate even same-scope drag sessions")
        let model = AppModel(stateDirectory: stateDir, scanOnStart: false)
        model.layout.tiles = (0..<36).map { Tile.app("/Applications/Model\($0).app") }
        let dragged = model.layout.tiles[0].id
        let token = model.beginDrag(dragged)
        model.hoverNavigation("page-1", target: 1)
        try await Task.sleep(nanoseconds: 750_000_000)
        check(model.page == 1 && model.draggedID == dragged, "Page hover must turn the page without ending the active drag")
        let releaseCell = wideGrid.cell(at: wideGrid.center(of: 6))!
        model.hoverSlot(model.page * model.capacity + releaseCell, group: false)
        model.dropSlot(token: token, slot: model.page * model.capacity + releaseCell, group: false)
        let saved = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: model.stateURL)).validated()
        check(saved.positions[dragged] == 41 && model.page == 1 && model.draggedID == nil, "Cross-page release through the model must persist the exact cell and finish the drag")
        let canceledToken = model.beginDrag(dragged); model.finishDrag()
        model.dropSlot(token: canceledToken, slot: 0, group: false)
        check(model.layout.positions[dragged] == 41, "Canceled drag tokens must never change placement")
        model.addPage()
        let newPage = model.page
        let newToken = model.beginDrag(dragged)
        model.dropSlot(token: newToken, slot: newPage * model.capacity + 17, group: false)
        check(model.layout.positions[dragged] == newPage * model.capacity + 17, "New empty pages must accept and persist free placement")

        model.selectedPath = nil; model.page = newPage
        model.navigate(1)
        check(model.selectedPath == dragged && model.page == newPage, "Keyboard selection must begin at the current sparse page")
        model.navigate(-1)
        check(model.page == (model.slot(of: model.selectedPath!)! / model.capacity), "Keyboard page selection must follow stored positions rather than dense indices")
        model.layout.place(dragged, at: 699_999); model.page = model.pageCount - 1
        check(model.navigationPages.count <= 9, "Sparse backups must not generate thousands of page buttons")
        model.layout.reconcile(model.layout.tiles.map { AppRecord(path: $0.id, name: $0.id, bundleID: "") } + [AppRecord(path: "/Applications/Overflow.app", name: "Overflow", bundleID: "")])
        check(!rejected(model.layout), "Discovery must remain valid even at the maximum sparse slot")

        var bulk = Layout(); bulk.columns = 4; bulk.rows = 3
        let bulkApps = (0..<18).map { "/Applications/Fixture\($0).app" }
        bulk.tiles = bulkApps.map(Tile.app)
        let bulkBefore = bulk.resolvedPositions()
        let bulkPlan = try bulk.planBatchMove(Set([bulkApps[4], bulkApps[0], bulkApps[2], bulkApps[12]]), toPage: 1)
        check(bulk.positions.isEmpty && bulkPlan.movedIDs.count == 3, "Batch preview must not change layout or move icons already on the target page")
        check(bulkPlan.after[bulkApps[0]] == 18 && bulkPlan.after[bulkApps[2]] == 19 && bulkPlan.after[bulkApps[4]] == 20, "Batch allocation must follow original source order into target holes")
        check(bulkPlan.after.filter { !bulkPlan.movedIDs.contains($0.key) } == bulkBefore.filter { !bulkPlan.movedIDs.contains($0.key) }, "Batch moves must retain every unselected icon's position")
        check(bulk.applyBatchMove(bulkPlan) && !bulk.positions.values.contains(0), "Batch apply must leave source holes and commit the whole selection")
        check(Set(bulk.tiles.map(\.id)) == Set(bulkApps) && bulk.tiles.count == 18, "Bulk moving must never lose or duplicate icons")
        let bulkSaved = try JSONDecoder().decode(Layout.self, from: JSONEncoder().encode(bulk)).validated()
        check(bulkSaved == bulk, "Batch page choices must survive backup and reload")
        bulk.backgroundOpacity = 0.23; bulk.iconSize = 100
        check(bulk.undoBatchMove(bulkPlan) && bulk.positions == bulkBefore, "Undo must restore the exact sparse source positions")
        check(bulk.backgroundOpacity == 0.23 && bulk.iconSize == 100, "Undo must preserve unrelated preference changes")
        let fullPageBefore = bulk
        check((try? bulk.planBatchMove([bulkApps[13]], toPage: 0)) == nil && bulk == fullPageBefore, "Full target pages must reject the whole batch without changing anything")
        check((try? bulk.planBatchMove(["missing"], toPage: 1)) == nil && (try? bulk.planBatchMove([], toPage: 1)) == nil, "Empty or unknown selections must be rejected")
        check((try? bulk.planBatchMove([bulkApps[0]], toPage: -1)) == nil && (try? bulk.planBatchMove([bulkApps[0]], toPage: Int.max)) == nil, "Invalid target page numbers must be rejected safely")
        check((try? bulk.planBatchMove([bulkApps[0]], toPage: 1, folderID: "missing")) == nil, "Deleted folder scopes must be rejected")
        let stalePlan = try bulk.planBatchMove([bulkApps[0]], toPage: 1)
        bulk.place(bulkApps[5], at: 23)
        let afterInterveningMove = bulk
        check(!bulk.applyBatchMove(stalePlan) && bulk == afterInterveningMove, "Stale previews must not overwrite newer icon movements")
        let conflictPlan = try bulk.planBatchMove([bulkApps[0]], toPage: 1)
        bulk.applyBatchMove(conflictPlan); bulk.place(bulkApps[10], at: 0)
        let conflictBefore = bulk
        check(!bulk.undoBatchMove(conflictPlan) && bulk == conflictBefore, "Undo must not overwrite a different icon occupying the former source slot")
        var folderBulk = Layout(); folderBulk.columns = 4; folderBulk.rows = 3
        folderBulk.tiles = [.folder(bulkApps), .app("/Applications/Outside.app")]
        folderBulk.normalizePositions()
        let bulkFolderID = folderBulk.tiles[0].id
        let rootSlotsBefore = folderBulk.positions
        let folderBatch = try folderBulk.planBatchMove([bulkApps[0], bulkApps[1]], toPage: 1, folderID: bulkFolderID)
        check(folderBulk.applyBatchMove(folderBatch) && folderBulk.folderPositions[bulkFolderID]?[bulkApps[0]] == 18, "Folder contents must support atomic multi-selection page moves")
        check(folderBulk.positions == rootSlotsBefore && folderBulk.tiles[0].apps.count == 18, "Folder bulk moves must preserve its root position and membership")
        check(folderBulk.undoBatchMove(folderBatch) && folderBulk.folderPositions[bulkFolderID]?[bulkApps[0]] == 0, "Folder bulk moves must support exact undo")

        let bulkStateDir = stateDir.appendingPathComponent("bulk")
        let bulkModel = AppModel(stateDirectory: bulkStateDir, scanOnStart: false)
        bulkModel.layout.columns = 4; bulkModel.layout.rows = 3; bulkModel.layout.tiles = bulkApps.map(Tile.app)
        bulkModel.catalog = bulkApps.enumerated().map { AppRecord(path: $0.element, name: "Fixture\($0.offset)", bundleID: "") }
        let manager = PageManagerState(); manager.configure(model: bulkModel)
        manager.selectVisible(model: bulkModel); manager.destinationPage = 1
        check(manager.selectedIDs.count == 12 && !manager.canMove(model: bulkModel), "Select-all must follow the source page and detect insufficient target space")
        manager.addPage(model: bulkModel)
        check(manager.destinationPage == 2 && manager.canMove(model: bulkModel), "A new blank page must immediately accept the selected batch")
        manager.move(model: bulkModel)
        let batchOnDisk = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: bulkModel.stateURL)).validated()
        check(batchOnDisk.positions[bulkApps[0]] == 24 && batchOnDisk.positions[bulkApps[11]] == 35, "Manager apply must persist all selected placements in one save")
        check(manager.sourcePage == 2 && manager.selectedIDs.isEmpty && manager.undoPlan != nil, "After moving, the manager must show the destination and offer undo")
        bulkModel.layout.backgroundOpacity = 0.12
        manager.undo(model: bulkModel)
        check(bulkModel.layout.resolvedPositions() == bulkBefore && bulkModel.layout.backgroundOpacity == 0.12, "Manager undo must save original positions while retaining newer appearance settings")
        manager.sourcePage = 0; manager.query = "Fixture0"; manager.selectVisible(model: bulkModel)
        manager.sourcePage = 1; manager.query = "Fixture12"; manager.selectVisible(model: bulkModel)
        check(manager.selectedIDs == Set([bulkApps[0], bulkApps[12]]), "Selection must remain available across source pages and search filters")
        manager.query = "absent"
        check(manager.visibleTiles(model: bulkModel).isEmpty && manager.selectedIDs.count == 2, "Empty search results must not silently clear existing selection")
        check(manager.selectedOutsideList(model: bulkModel) == 2, "Hidden selections must be counted before committing a batch")
        manager.showSelectedOnly = true; manager.query = ""
        check(manager.visibleTiles(model: bulkModel).map(\.id) == [bulkApps[0], bulkApps[12]], "Selection review must include chosen icons from all source pages, in layout order")
        manager.query = "Fixture12"
        check(manager.visibleTiles(model: bulkModel).map(\.id) == [bulkApps[12]] && manager.selectedOutsideList(model: bulkModel) == 1, "Review search must filter the chosen list while reporting hidden selection")
        manager.toggle(bulkApps[12], selected: false)
        check(manager.visibleTiles(model: bulkModel).isEmpty && manager.selectedIDs == [bulkApps[0]], "Removing a reviewed choice must never reveal an unselected icon in its place")
        let reviewModel = AppModel(stateDirectory: stateDir.appendingPathComponent("review"), scanOnStart: false)
        reviewModel.layout = folderBulk
        manager.changeScope(bulkFolderID, model: reviewModel)
        check(!manager.showSelectedOnly && manager.selectedIDs.isEmpty && manager.query.isEmpty, "Changing folder scope must clear the previous scope's review filter and selection")
        manager.selectedIDs = [bulkApps[0], bulkApps[12]]; manager.sourcePage = 0; manager.showSelectedOnly = true
        check(manager.visibleTiles(model: reviewModel).map(\.id) == [bulkApps[0], bulkApps[12]], "Folder review must include selected internal applications across its pages")
        let limitModel = AppModel(stateDirectory: stateDir.appendingPathComponent("limit"), scanOnStart: false)
        limitModel.layout.columns = 4; limitModel.layout.rows = 3; limitModel.layout.tiles = Array(bulkApps.prefix(5)).map(Tile.app)
        limitModel.layout.place(bulkApps[0], at: Layout.maximumSlot)
        let limitManager = PageManagerState(); limitManager.configure(model: limitModel)
        limitManager.destinationPage = Layout.maximumSlot / limitModel.capacity
        limitManager.selectedIDs = Set(bulkApps[1...4])
        check(limitManager.availableCount(model: limitModel) == 3 && !limitManager.canMove(model: limitModel), "The final supported page must report only its real remaining slots, not a whole grid")
        manager.configure(model: bulkModel)
        check(!manager.showSelectedOnly && manager.selectedIDs.isEmpty, "A new manager session must start with an unfiltered selection list")
        let failedStateDir = stateDir.appendingPathComponent("blocked")
        try Data("block-directory".utf8).write(to: failedStateDir)
        let failedModel = AppModel(stateDirectory: failedStateDir, scanOnStart: false)
        failedModel.layout = bulkModel.layout
        let failedManager = PageManagerState(); failedManager.configure(model: failedModel)
        let failedPreviewToken = failedManager.beginPreviewDrag(bulkApps[0], model: failedModel)!
        let failedPreviewBefore = failedModel.layout
        check(!failedManager.dropPreview(failedPreviewToken, on: 2, cell: 3, model: failedModel) && failedModel.layout == failedPreviewBefore && failedManager.undoPlan == nil && failedManager.feedbackIsError, "Failed preview saves must restore all original cells and refuse an undo entry")
        failedManager.selectedIDs = [bulkApps[0]]; failedManager.destinationPage = 1
        let beforeFailedSave = failedModel.layout
        failedManager.move(model: failedModel)
        check(failedModel.layout == beforeFailedSave && failedManager.feedbackIsError && failedManager.undoPlan == nil, "Failed batch saves must roll back in-memory positions and report failure")
        let folderPreview = PageManagerState(); folderPreview.changeScope(bulkFolderID, model: reviewModel)
        let folderPreviewBefore = reviewModel.layout.resolvedPositions(folderID: bulkFolderID)
        let folderRootBefore = reviewModel.layout.positions
        let folderPreviewToken = folderPreview.beginPreviewDrag(bulkApps[0], model: reviewModel)!
        check(folderPreview.dropPreview(folderPreviewToken, on: 2, cell: 4, model: reviewModel) && reviewModel.layout.folderPositions[bulkFolderID]?[bulkApps[0]] == 28, "Folder preview drags must use internal absolute cells")
        check(reviewModel.layout.positions == folderRootBefore, "Internal preview drops must retain the folder's root position")
        folderPreview.undo(model: reviewModel)
        check(reviewModel.layout.resolvedPositions(folderID: bulkFolderID) == folderPreviewBefore, "Folder preview undo must restore internal sparse positions")
        let finalToken = limitManager.beginPreviewDrag(bulkApps[1], model: limitModel)!
        check(!limitManager.dropPreview(finalToken, on: Layout.maximumSlot / limitModel.capacity, cell: 11, model: limitModel), "Preview drops past the final supported slot must be rejected")

        var oldV2 = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bulkModel.layout)) as! [String: Any]
        oldV2["version"] = 2
        for key in ["pageNames", "folderPageNames", "layoutLocked"] { oldV2.removeValue(forKey: key) }
        let upgradedV2 = try JSONDecoder().decode(Layout.self, from: JSONSerialization.data(withJSONObject: oldV2)).validated()
        check(upgradedV2.version == 5 && upgradedV2.positions == bulkModel.layout.positions, "Schema 2 upgrades must preserve every sparse root position")
        check(upgradedV2.pageNames.isEmpty && upgradedV2.folderPageNames.isEmpty && !upgradedV2.layoutLocked, "Old backups must default to unnamed and unlocked")
        var named = folderBulk
        check(named.setPageName("  工作  ", page: 0) && named.pageTitle(0) == "第 1 页 · 工作", "Page naming must trim whitespace and retain the page number")
        check(named.setPageName("工具", page: 0, folderID: bulkFolderID) && named.pageName(0) == "工作", "Folder page names must be independent of root names")
        check(named.setPageName("备用", page: 5) && named.namedPageCount() == 6, "Named empty pages must remain discoverable after reload")
        named.layoutLocked = true
        let namedBackup = try JSONDecoder().decode(Layout.self, from: JSONEncoder().encode(named)).validated()
        check(namedBackup == named, "Page names, folder page names and locking must roundtrip together with the layout")
        let beforeLockedName = named
        check(!named.setPageName("更改", page: 0) && named == beforeLockedName, "Locking must block page naming without changing metadata")
        named.layoutLocked = false
        check(named.setPageName("  ", page: 5) && named.namedPageCount() == 1, "Clearing a named empty page must remove its persistent page marker")
        check(!named.setPageName(String(repeating: "名", count: 41), page: 0) && !named.setPageName("工作\n工具", page: 0), "Overlong or multiline names must be rejected")
        check(!named.setPageName("不存在", page: 0, folderID: "missing") && !named.setPageName("非法", page: -1), "Missing scopes and invalid page numbers must reject naming")
        var badNames = named; badNames.pageNames = ["01": "工作"]
        check(rejected(badNames), "Noncanonical page keys must be rejected in backups")
        badNames = named; badNames.folderPageNames["missing"] = ["0": "工作"]
        check(rejected(badNames), "Orphan folder page names must be rejected in backups")
        let namedModel = AppModel(stateDirectory: stateDir.appendingPathComponent("named"), scanOnStart: false)
        namedModel.layout = named; namedModel.layout.setPageName("备用", page: 5)
        let namedManager = PageManagerState(); namedManager.configure(model: namedModel)
        check(namedModel.pageCount == 6 && namedManager.pages(model: namedModel).contains(5), "Launcher and manager must both expose persistent named empty pages")
        namedModel.query = "absent"
        check(namedModel.pageCount == 1, "Search result paging must ignore named layout pages")
        namedModel.query = ""; namedModel.folderID = bulkFolderID
        check(namedModel.layout.pageTitle(0, folderID: namedModel.folderID) == "第 1 页 · 工具", "Folder navigation must use the folder's own page title")

        var groupBatch = Layout(); groupBatch.tiles = [.app(a), .app(b), .app(c), .app(d)]
        groupBatch.place(b, at: 40); groupBatch.place(c, at: 80)
        groupBatch.setPageName("工作", page: 1)
        let beforeGroup = groupBatch
        let groupPlan = try groupBatch.planBatchGroup([c, a, b], name: "办公")
        check(groupBatch == beforeGroup, "Grouping preview must be read-only")
        check(groupBatch.applyBatchGroup(groupPlan), "Grouping must atomically apply the full selection")
        let createdFolder = groupBatch.tiles.first { $0.id == groupPlan.folderID }!
        check(createdFolder.apps == [a, b, c] && createdFolder.name == "办公", "Batch folder content must follow original cross-page positions")
        check(groupBatch.positions[createdFolder.id] == 0 && groupBatch.positions[d] == beforeGroup.positions[d], "The new folder must use the earliest selected slot while retaining every unselected slot")
        check(!groupBatch.positions.values.contains(40) && !groupBatch.positions.values.contains(80), "Grouping must leave other source positions empty")
        check(Set(groupBatch.tiles.flatMap(\.apps)) == Set([a,b,c,d]), "Batch grouping must never lose or duplicate apps")
        let groupReload = try JSONDecoder().decode(Layout.self, from: JSONEncoder().encode(groupBatch)).validated()
        check(groupReload == groupBatch, "Grouped membership and sparse positions must survive reload")
        groupBatch.backgroundOpacity = 0.15; groupBatch.setPageName("沟通", page: 0)
        check(groupBatch.undoBatchGroup(groupPlan) && groupBatch.positions == beforeGroup.positions && groupBatch.tiles == beforeGroup.tiles, "Grouping undo must restore all original tiles and holes")
        check(groupBatch.backgroundOpacity == 0.15 && groupBatch.pageName(0) == "沟通", "Grouping undo must preserve newer appearance and root page names")
        check((try? groupBatch.planBatchGroup([a], name: "单个")) == nil && (try? groupBatch.planBatchGroup([a,b], name: "  ")) == nil, "Insufficient selection and empty folder names must reject grouping")
        check((try? groupBatch.planBatchGroup([a,"missing"], name: "无效")) == nil && (try? groupBatch.planBatchGroup([a,b], into: "missing")) == nil, "Stale selected icons and missing destination folders must reject grouping")
        let staleGroup = try groupBatch.planBatchGroup([a,b], name: "过期")
        groupBatch.place(d, at: 12)
        let afterGroupIntervention = groupBatch
        check(!groupBatch.applyBatchGroup(staleGroup) && groupBatch == afterGroupIntervention, "A stale grouping preview must not overwrite intervening layout changes")

        var merging = Layout()
        let firstFolder = Tile.folder([a,b], name: "来源"), secondFolder = Tile.folder([c], name: "目标")
        merging.tiles = [firstFolder, secondFolder, .app(d)]; merging.normalizePositions()
        merging.place(b, at: 41, folderID: firstFolder.id)
        merging.place(c, at: 65, folderID: secondFolder.id)
        merging.setPageName("来源内页", page: 1, folderID: firstFolder.id)
        merging.setPageName("目标内页", page: 1, folderID: secondFolder.id)
        let mergingBefore = merging
        let mergePlan = try merging.planBatchGroup([firstFolder.id, secondFolder.id, d], into: secondFolder.id)
        check(mergePlan.selectedCount == 2 && mergePlan.incomingAppCount == 3, "A selected destination folder must not count as incoming content")
        merging.applyBatchGroup(mergePlan)
        let merged = merging.tiles.first { $0.id == secondFolder.id }!
        check(merging.tiles.count == 1 && merged.apps == [c,a,b,d] && merged.name == "目标", "Selected folders must flatten into the existing target without nesting or renaming it")
        check(merging.positions[secondFolder.id] == mergingBefore.positions[secondFolder.id] && merging.folderPositions[secondFolder.id]?[c] == 65, "Existing target root and internal positions must remain unchanged")
        check(merging.folderPositions[secondFolder.id]?[a] == 66 && merging.folderPositions[secondFolder.id]?[d] == 68, "New folder members must append after existing sparse content")
        check(merging.folderPageNames[firstFolder.id] == nil && merging.pageName(1, folderID: secondFolder.id) == "目标内页", "Merge must remove vanished source metadata and retain target page names")
        check(merging.undoBatchGroup(mergePlan) && merging == mergingBefore, "Merge undo must restore source folders, their internal holes and names exactly")
        merging.applyBatchGroup(mergePlan); merging.place(c, at: 4, folderID: secondFolder.id)
        let mergeConflict = merging
        check(!merging.undoBatchGroup(mergePlan) && merging == mergeConflict, "Undo must reject newer internal folder changes instead of overwriting them")

        var locked = mergingBefore; locked.layoutLocked = true
        let lockedBefore = locked
        locked.group(d, with: secondFolder.id); locked.groupTile(firstFolder.id, with: secondFolder.id)
        locked.hide(a); locked.unhide("/Applications/Other.app"); locked.removeApp(c)
        locked.extract(b); locked.ungroup(firstFolder.id); locked.move(d, before: firstFolder.id)
        locked.move(d, toPage: 0, capacity: 35); locked.move(a, before: b, folderID: firstFolder.id)
        check(!locked.place(d, at: 40) && locked == lockedBefore, "Every layout mutation entry point must honor locking")
        check((try? locked.planBatchMove([d], toPage: 1)) == nil && (try? locked.planBatchGroup([d,firstFolder.id])) == nil, "Locked layouts must reject batch previews")
        check(!locked.applyBatchGroup(mergePlan) && !locked.undoBatchGroup(mergePlan), "Grouping apply and undo must recheck current lock state")
        var lockedBatch = beforeGroup; let beforeLockMove = try lockedBatch.planBatchMove([a], toPage: 1)
        lockedBatch.layoutLocked = true
        check(!lockedBatch.applyBatchMove(beforeLockMove) && !lockedBatch.undoBatchMove(beforeLockMove), "Move apply and undo must recheck current lock state")
        locked.reconcile([a,b,c,d,"/Applications/NewWhileLocked.app"].map { AppRecord(path: $0, name: $0, bundleID: "") })
        check(locked.layoutLocked && locked.positions[firstFolder.id] == lockedBefore.positions[firstFolder.id] && locked.tiles.flatMap(\.apps).contains("/Applications/NewWhileLocked.app"), "Locking must preserve existing layout while still discovering newly installed apps")

        let groupModel = AppModel(stateDirectory: stateDir.appendingPathComponent("group"), scanOnStart: false)
        groupModel.layout = beforeGroup
        let groupManager = PageManagerState(); groupManager.configure(model: groupModel)
        groupManager.selectedIDs = [a,b]; groupManager.presentGrouping(model: groupModel); groupManager.groupingName = "工作应用"
        groupManager.group(model: groupModel)
        let savedGroup = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: groupModel.stateURL)).validated()
        check(savedGroup.tiles.first(where: { $0.isFolder })?.name == "工作应用" && !groupManager.groupingPresented && groupManager.selectedIDs.isEmpty, "Manager must save grouping and return to a clean selection state")
        check(groupManager.undoPlan?.title == "撤销建组" && groupManager.feedback.contains("已创建"), "Manager must show a specific grouping result and undo action")
        groupManager.undo(model: groupModel)
        check(groupModel.layout == beforeGroup, "Manager grouping undo must persist exact original layout")
        groupManager.selectedIDs = [a,b]; groupManager.groupingName = "工作应用"; groupManager.group(model: groupModel)
        let existingID = groupModel.layout.tiles.first { $0.isFolder }!.id
        groupManager.selectedIDs = [d]; groupManager.presentGrouping(model: groupModel)
        check(groupManager.groupingTargetID == existingID && groupManager.canGroup(model: groupModel), "A single selected app must default to an available existing folder")
        groupManager.group(model: groupModel)
        check(groupManager.undoPlan?.title == "撤销移入" && groupModel.layout.tiles.first { $0.id == existingID }!.apps.contains(d), "Manager must support moving a selection into an existing folder")
        groupManager.undo(model: groupModel)
        let tokenBeforeLock = groupModel.beginDrag(c)
        check(groupModel.setLayoutLocked(true) && groupModel.draggedID == nil && !groupModel.acceptsDrag(tokenBeforeLock), "Locking during a drag must cancel its token and pending gesture")
        let lockedModelBefore = groupModel.layout
        _ = groupModel.beginDrag(c); groupModel.addPage(); groupModel.hide(c); groupModel.unhide("/Applications/Missing.app")
        groupManager.selectedIDs = [c,d]; groupManager.move(model: groupModel); groupManager.group(model: groupModel)
        check(groupModel.layout == lockedModelBefore && !groupModel.canArrange && groupModel.draggedID == nil && !groupManager.canGroup(model: groupModel), "Model and manager must block edits while locked, including attempted new gestures")
        let restoredLockedModel = AppModel(stateDirectory: stateDir.appendingPathComponent("group"), scanOnStart: false)
        check(restoredLockedModel.layout.layoutLocked, "Layout locking must persist across app restart")
        check(groupModel.setLayoutLocked(false) && groupModel.canArrange, "Unlocking must restore arrangement without changing positions")
        failedManager.selectedIDs = [bulkApps[0],bulkApps[1]]; failedManager.groupingName = "失败"
        failedManager.group(model: failedModel)
        check(failedModel.layout == beforeFailedSave && !failedManager.groupingError.isEmpty && failedManager.selectedIDs.count == 2, "Failed grouping saves must roll back layout and retain selection for retry")
        check(!failedModel.setLayoutLocked(true) && !failedModel.layout.layoutLocked, "Failed lock saves must roll back the lock flag")
        check(!failedModel.renamePage("失败", page: 0, folderID: nil) && failedModel.layout.pageNames.isEmpty, "Failed page-name saves must roll back metadata")

        let pageApps = (0..<71).map { "/Applications/Page\($0).app" }
        var paged = Layout(); paged.tiles = pageApps.map(Tile.app)
        paged.move(pageApps[0], toPage: 1, capacity: 35)
        check(paged.tiles[35].id == pageApps[0], "Forward page moves must land on the destination page after source removal")
        paged.move(pageApps[0], toPage: 2, capacity: 35)
        check(paged.tiles[70].id == pageApps[0], "Drops onto a sparse final page must retain its page boundary")
        paged.move(pageApps[0], toPage: 0, capacity: 35)
        check(paged.tiles[0].id == pageApps[0], "Backward page moves must land at the destination start")
        check(Set(paged.tiles.map(\.id)) == Set(pageApps) && paged.tiles.count == 71, "Cross-page moves must not lose or duplicate applications")
        let beforeInvalidPage = paged
        paged.move(pageApps[0], toPage: -1, capacity: 35)
        paged.move(pageApps[0], toPage: 3, capacity: 35)
        paged.move(pageApps[0], toPage: 0, capacity: 0)
        paged.move("missing", toPage: 1, capacity: 35)
        check(paged == beforeInvalidPage, "Invalid page drop targets must leave the layout untouched")
        var folderPages = Layout(); folderPages.tiles = [.folder(pageApps)]
        let folderID = folderPages.tiles[0].id
        folderPages.move(pageApps[0], toPage: 2, capacity: 35, folderID: folderID)
        check(folderPages.tiles[0].apps[70] == pageApps[0], "Cross-page rearrangement must also work inside a folder")
        folderPages.move(pageApps[0], before: pageApps[1], folderID: folderID)
        check(folderPages.tiles[0].apps[0] == pageApps[0], "Folder names and gaps must reorder without nesting")
        var merge = Layout(); merge.tiles = [.folder([a,b], name: "工作"), .folder([c,d])]
        let sourceGroup = merge.tiles[0].id, targetGroup = merge.tiles[1].id
        merge.groupTile(sourceGroup, with: targetGroup)
        check(merge.tiles.count == 1 && merge.tiles[0].apps == [c,d,a,b], "Dragging folders together must merge their apps without nesting")
        let beforeSelfMerge = merge; merge.groupTile(targetGroup, with: targetGroup)
        check(merge == beforeSelfMerge, "Self-drops must never delete folders")
        merge = Layout(); merge.tiles = [.app(a), .app(b), .app(c)]
        merge.groupTile(a, with: b)
        check(merge.tiles[0].isFolder && merge.tiles[0].apps == [b,a], "A direct icon drop must group without an Option modifier")
        merge.groupTile(c, with: merge.tiles[0].id)
        check(merge.tiles[0].apps == [b,a,c], "Direct drops onto an existing folder must add the application")
        let dropGeometry = TileDropGeometry(cellWidth: 168, cellHeight: 184, iconSize: 88)
        check(dropGeometry.groups(at: CGPoint(x: 84, y: 74)), "The center of a large icon must be a grouping target")
        check(!dropGeometry.groups(at: CGPoint(x: 84, y: 155)), "The app label must remain a reorder target")
        check(!dropGeometry.groups(at: CGPoint(x: 4, y: 74)), "The gap beside an icon must remain a reorder target")

        func desktopSetting(_ url: String) throws -> [String: Any] {
            let configuration = try PropertyListSerialization.data(fromPropertyList: ["url": ["relative": url]], format: .binary, options: 0)
            return ["Desktop": ["Content": ["Choices": [["Configuration": configuration]]]],
                    "Idle": ["Content": ["Choices": [["Configuration": try PropertyListSerialization.data(fromPropertyList: ["url": "file:///idle-only.png"], format: .binary, options: 0)]]]]]
        }
        let wallpaperStore = try PropertyListSerialization.data(fromPropertyList: [
            "Displays": ["SCREEN-2": try desktopSetting("file:///display%20wallpaper.heic")],
            "SystemDefault": try desktopSetting("file:///default.png")
        ], format: .binary, options: 0)
        let wallpaperURLs = WallpaperResolver.candidates(primary: nil, displayUUID: "SCREEN-2", store: wallpaperStore)
        check(wallpaperURLs.first?.path == "/display wallpaper.heic", "A nil system wallpaper URL must fall back to the matching display configuration")
        check(wallpaperURLs.map(\.path) == ["/display wallpaper.heic", "/default.png"], "Wallpaper fallback must decode URL escapes and ignore screen saver images")
        let primaryWallpaper = URL(fileURLWithPath: "/primary.png")
        check(WallpaperResolver.candidates(primary: primaryWallpaper, displayUUID: "SCREEN-2", store: wallpaperStore).first == primaryWallpaper, "The public wallpaper API must take priority over configuration fallback")
        check(WallpaperResolver.candidates(primary: nil, displayUUID: "UNKNOWN", store: wallpaperStore).first?.path == "/default.png", "Missing display records must use the system default wallpaper")
        check(WallpaperResolver.candidates(primary: nil, displayUUID: nil, store: Data("invalid".utf8)).isEmpty, "Unreadable wallpaper configuration must fail safely")

        var session = DockPresentationSession()
        let original: NSApplication.PresentationOptions = [.autoHideDock, .autoHideMenuBar]
        let hiddenOptions = session.options(current: original, hideDock: true)
        check(hiddenOptions.contains(.hideDock) && !hiddenOptions.contains(.autoHideDock), "Hide Dock must avoid conflicting presentation flags")
        check(hiddenOptions.contains(.autoHideMenuBar), "Dock handling must retain other presentation flags")
        check(session.options(current: hiddenOptions, hideDock: true) == hiddenOptions, "Repeated show must preserve the original presentation snapshot")
        check(session.options(current: hiddenOptions, hideDock: false) == original, "Turning off Dock hiding during a session must restore original options")
        check(session.restore() == original && session.restore() == nil, "Dismissal and termination restore exactly once")
        check(session.options(current: [], hideDock: false).isEmpty, "System Dock preferences must be respected without forcing visibility")
        _ = session.restore()
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let bottomDock = CGRect(x: 0, y: 80, width: 1440, height: 795)
        check(LauncherInsets.resolve(frame: screen, visibleFrame: bottomDock, hideDock: false) == LauncherInsets(top: 25, leading: 0, bottom: 80, trailing: 0), "Visible bottom Dock must reserve footer space")
        check(LauncherInsets.resolve(frame: screen, visibleFrame: bottomDock, hideDock: true) == LauncherInsets(top: 25, leading: 0, bottom: 0, trailing: 0), "Hidden Dock releases reserved space and retains menu bar space")
        check(LauncherInsets.resolve(frame: screen, visibleFrame: CGRect(x: 76, y: 0, width: 1364, height: 875), hideDock: false).leading == 76, "Left Dock must reserve leading space")
        check(LauncherInsets.resolve(frame: screen, visibleFrame: CGRect(x: 0, y: 0, width: 1364, height: 875), hideDock: false).trailing == 76, "Right Dock must reserve trailing space")
        let secondScreen = CGRect(x: -1440, y: 900, width: 1440, height: 900)
        check(LauncherInsets.resolve(frame: secondScreen, visibleFrame: CGRect(x: -1440, y: 980, width: 1440, height: 795), hideDock: false).bottom == 80, "Dock geometry must support offset secondary displays")
        var invalid = layout; invalid.version = 99
        check(rejected(invalid), "Unsupported backup versions must be rejected")
        invalid = layout; invalid.columns = 0
        check(rejected(invalid), "Zero-size grids must be rejected")
        invalid = layout; invalid.iconSize = .nan
        check(rejected(invalid), "Nonfinite sizes must be rejected")
        invalid = layout; invalid.tiles.append(layout.tiles[0])
        check(rejected(invalid), "Duplicate tile identifiers must be rejected")
        invalid = layout; invalid.extraPaths = ["relative/path"]
        check(rejected(invalid), "Relative application paths must be rejected")
        let chinese = AppRecord(path: "/test.app", name: "微信", bundleID: "com.tencent.xinWeChat")
        check(chinese.searchText.contains("weixin"), "Search must support full pinyin")
        check(chinese.searchText.contains("wechat"), "Search must support bundle identifiers")
        let localized = AppRecord(path: "/wechat.app", name: "WeChat", bundleID: "test", aliases: ["微信"])
        check(localized.searchText.contains("微信") && localized.searchText.contains("weixin"), "Search must use localized aliases even when the bundle name is English")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("FreeLaunchpad-scanner-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        func fixture(_ name: String, background: Bool = false) throws -> String {
            let root = temp.appendingPathComponent(name + ".app")
            let macos = root.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            let executable = macos.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let plist: [String: Any] = ["CFBundleExecutable": name, "CFBundleIdentifier": "test." + name, "CFBundleName": name, "CFBundlePackageType": "APPL", "LSBackgroundOnly": background]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: root.appendingPathComponent("Contents/Info.plist"))
            return root.path
        }
        let standalone = try fixture("VisibleFixture")
        let localizations = URL(fileURLWithPath: standalone).appendingPathComponent("Contents/Resources/zh-Hans.lproj")
        try FileManager.default.createDirectory(at: localizations, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleDisplayName": "测试应用"], format: .xml, options: 0).write(to: localizations.appendingPathComponent("InfoPlist.strings"))
        let own = try fixture("OwnFixture")
        let background = try fixture("BackgroundFixture", background: true)
        let helper = temp.appendingPathComponent("VisibleFixture.app/Contents/Helpers/NestedHelper.app")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        let scanned = CatalogScanner.scan(extraPaths: [temp.path, temp.path], excluding: own)
        check(scanned.filter { $0.path == standalone }.count == 1, "Custom roots must discover applications once")
        check(scanned.first { $0.path == standalone }?.searchText.contains("测试应用") == true, "Scanner must include InfoPlist.strings aliases")
        check(!scanned.contains { $0.path == own || $0.path == background || $0.path == helper.path }, "Scanner must exclude its own app, background executables and nested app packages")
        // Saved desktop workgroups never alter icon arrangement, including locked layouts.
        let comboDir = stateDir.appendingPathComponent("workgroups")
        let comboModel = AppModel(stateDirectory: comboDir, scanOnStart: false)
        comboModel.catalog = apps; comboModel.layout.tiles = apps.map { .app($0.path) }
        comboModel.layout.normalizePositions(); comboModel.layout.layoutLocked = true
        let originalTiles = comboModel.layout.tiles, comboOriginalSlots = comboModel.layout.positions
        let combo = AppGroup.make(name: "  开发  ", apps: [b,a,b])
        check(combo.name == "开发" && combo.apps == [b,a], "Workgroups trim names and preserve deduplicated member order")
        check(comboModel.storeAppGroup(combo), "Locked layouts still allow saving independent workgroups")
        check(comboModel.layout.tiles == originalTiles && comboModel.layout.positions == comboOriginalSlots, "Saving a workgroup must not move or group icons")
        let comboReload = AppModel(stateDirectory: comboDir, scanOnStart: false)
        check(comboReload.layout.appGroups == [combo] && comboReload.layout.layoutLocked, "Workgroups persist across restart with layout lock intact")
        var editedCombo = combo; editedCombo.name = "写作"; editedCombo.apps = [c,d]
        check(comboModel.storeAppGroup(editedCombo) && comboModel.layout.appGroups == [editedCombo], "Editing a workgroup replaces its own entry")
        let comboBackup = try JSONDecoder().decode(Layout.self, from: AppModel.encode(comboModel.layout)).validated()
        check(comboBackup.appGroups == [editedCombo], "Backups include named workgroups and their exact members")
        var disappearingCombo = comboBackup; disappearingCombo.reconcile([])
        check(disappearingCombo.appGroups == [editedCombo], "Catalog disappearance must preserve saved workgroup members")
        var legacyV4 = try JSONSerialization.jsonObject(with: AppModel.encode(comboBackup)) as! [String: Any]
        legacyV4["version"] = 4; legacyV4.removeValue(forKey: "appGroups")
        let decodedV4 = try JSONDecoder().decode(Layout.self, from: JSONSerialization.data(withJSONObject: legacyV4)).validated()
        check(decodedV4.version == 5 && decodedV4.appGroups.isEmpty && decodedV4.positions == comboOriginalSlots, "Version 4 migration preserves positions and starts with no workgroups")
        var invalidCombo = comboBackup; invalidCombo.appGroups[0].apps = [a,a]
        check(rejected(invalidCombo), "Backups reject repeated workgroup members")
        invalidCombo = comboBackup; invalidCombo.appGroups[0].name = " "
        check(rejected(invalidCombo), "Backups reject blank workgroup names")
        invalidCombo = comboBackup; invalidCombo.appGroups[0].apps = ["relative.app"]
        check(rejected(invalidCombo), "Backups reject nonabsolute workgroup paths")
        invalidCombo = comboBackup; invalidCombo.appGroups.append(editedCombo)
        check(rejected(invalidCombo), "Backups reject repeated workgroup identities")
        invalidCombo = comboBackup; invalidCombo.appGroups[0].apps = []
        check(rejected(invalidCombo), "Backups reject empty workgroups")
        invalidCombo = comboBackup; invalidCombo.appGroups[0].name = String(repeating: "界", count: 41)
        check(rejected(invalidCombo), "Backup validation and UI share workgroup name bounds")
        invalidCombo = comboBackup; invalidCombo.appGroups[0].name = "A\nB"
        check(rejected(invalidCombo), "Workgroup names reject embedded control characters")
        let comboBeforeFailure = failedModel.layout
        check(!failedModel.storeAppGroup(combo) && failedModel.layout == comboBeforeFailure, "Workgroup save failure rolls back all in-memory changes")
        failedModel.layout.appGroups = [combo]
        let deletionBeforeFailure = failedModel.layout
        check(!failedModel.deleteAppGroup(combo.id) && failedModel.layout == deletionBeforeFailure, "Workgroup deletion failure restores the saved entry")
        check(comboModel.deleteAppGroup(combo.id) && comboModel.layout.appGroups.isEmpty && comboModel.layout.positions == comboOriginalSlots, "Deleting a workgroup preserves icons and positions")
        let selectedFolder = Tile.folder([a,b], name: "顺序")
        comboModel.layout.tiles = [.app(c), selectedFolder, .app(d)]
        comboModel.layout.positions = [c:48,selectedFolder.id:2,d:80]
        comboModel.layout.folderPositions = [selectedFolder.id:[a:9,b:1]]
        let selection = PageManagerState(); selection.selectedIDs = [c,selectedFolder.id,"stale"]
        selection.sourcePage = 0; selection.query = "nothing"; selection.showSelectedOnly = true
        check(selection.selectedAppPaths(model: comboModel) == [b,a,c], "Batch selection includes filtered choices and expands folder contents in actual grid order")
        selection.scopeID = selectedFolder.id; selection.selectedIDs = [a]
        check(selection.selectedAppPaths(model: comboModel) == [a], "Folder management resolves only selected internal applications")
        let targets = comboModel.batchTargets([a,b,a,"/missing.app"])
        check(targets.count == 3 && targets.last?.available == false && targets.first?.name == "A", "Batch targets deduplicate and label unavailable apps")
        let lifecycle = FakeLifecycle()
        let batch = AppBatchRunner(driver: lifecycle)
        let ta = AppBatchTarget(path:a,name:"A",available:true), tb = AppBatchTarget(path:b,name:"B",available:true)
        let tc = AppBatchTarget(path:c,name:"C",available:true), tm = AppBatchTarget(path:"/missing.app",name:"Missing",available:false)
        lifecycle.failLaunch = [b]
        await batch.perform(.launch, targets:[ta,ta,tb,tc,tm])
        check(lifecycle.launches == [a,b,c] && batch.items.count == 4, "Launch deduplicates targets and continues after an individual failure")
        check(batch.items[0].status == .started && batch.items[2].status == .started && batch.items[3].status == .unavailable, "Launch result separates started and unavailable applications")
        check(batch.items[1].status.isIssue && !batch.busy, "Launch errors remain actionable after the batch finishes")
        await batch.perform(.launch, targets:[ta])
        check(batch.items[0].status == .alreadyRunning && lifecycle.launches.filter { $0 == a }.count == 1, "Launching an already running app must not duplicate its instance")
        await batch.perform(.quit, targets:[ta,tc,tm], quitWaitNanoseconds:0)
        check(batch.items.map(\.status) == [.exited,.exited,.notRunning], "Quit verifies termination independently and handles nonrunning apps")
        lifecycle.running[a] = [AppInstance(pid:900001,path:a,bundleID:"test.a"),AppInstance(pid:900002,path:a,bundleID:"test.a")]
        lifecycle.quitImmediately = false
        await batch.perform(.quit, targets:[ta], quitWaitNanoseconds:0)
        check(batch.items[0].status == .quitting && lifecycle.quits.suffix(2) == [900001,900002], "Accepted quit requests target all instances and must not prematurely report exit")
        lifecycle.running[a] = [AppInstance(pid:900002,path:a,bundleID:"test.a")]; batch.refresh()
        check(batch.items[0].status == .quitting, "One remaining process keeps the application in pending quit status")
        lifecycle.running[a] = []; batch.refresh()
        check(batch.items[0].status == .exited, "Termination notifications update a previously pending quit")
        lifecycle.running[b] = [AppInstance(pid:900003,path:b,bundleID:"test.b")]; lifecycle.refuseQuit = [900003]
        await batch.perform(.quit, targets:[tb], quitWaitNanoseconds:0)
        check(batch.items[0].status.isIssue && lifecycle.running[b]?.count == 1, "Refused quits do not force termination or claim success")
        lifecycle.running[b] = []; batch.refresh()
        check(batch.items[0].status == .exited, "A delayed exit following a refusal is still confirmed truthfully")
        let protectedIDs = ["com.apple.finder","com.apple.dock","local.free-launchpad.app"]
        for (index,id) in protectedIDs.enumerated() {
            lifecycle.running[a] = [AppInstance(pid:910000+Int32(index),path:a,bundleID:id)]
            let requests = lifecycle.quits.count
            await batch.perform(.quit, targets:[ta], quitWaitNanoseconds:0)
            check(batch.items[0].status == .protected && lifecycle.quits.count == requests, "Critical system and launcher instances must be retained")
        }
        check(AppBatchRunner.protected(AppInstance(pid:ProcessInfo.processInfo.processIdentifier,path:a,bundleID:"test")), "Own process protection also works without a bundle identifier")
        lifecycle.running = [:]; lifecycle.failLaunch = []
        batch.workspaceBusy = true; let launchesBeforeReserve = lifecycle.launches.count
        await batch.perform(.launch, targets:[ta])
        check(lifecycle.launches.count == launchesBeforeReserve, "A desktop operation reserves the batch engine against concurrent commands")
        batch.workspaceBusy = false
        let desktop = FakeDesktop()
        let workspaceRun = DesktopWorkspaceRunner(driver: desktop)
        desktop.allowed = false
        await workspaceRun.run(targets:[ta],batch:batch)
        check(desktop.created == 0 && lifecycle.launches.count == launchesBeforeReserve && workspaceRun.feedback.contains("权限"), "Missing accessibility permission must not create a desktop or launch apps")
        desktop.allowed = true; desktop.createFails = true
        await workspaceRun.run(targets:[ta],batch:batch)
        check(desktop.created == 0 && lifecycle.launches.count == launchesBeforeReserve, "Desktop creation failure must stop before launching or moving apps")
        desktop.createFails = false
        desktop.entries[a] = [WorkspaceWindow(id:1,pid:1,path:a),WorkspaceWindow(id:2,pid:1,path:a)]
        desktop.entries[b] = [WorkspaceWindow(id:3,pid:2,path:b)]
        desktop.failWindows = [2]
        await workspaceRun.run(targets:[ta,tb],batch:batch)
        check(desktop.created == 1 && desktop.moved == [1,3], "A workgroup creates one desktop and moves only selected app windows, continuing after a failed window")
        check(workspaceRun.results[a]?.contains("1 / 2") == true && workspaceRun.results[b]?.contains("已归入") == true, "Partial workspace placement is reported per app without claiming all windows moved")
        check(!workspaceRun.busy && !batch.workspaceBusy, "Workspace completion releases action controls")
        print("PASS: \(checks) regression checks")
    }
}
