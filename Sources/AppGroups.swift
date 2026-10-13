import Foundation

/// Saved launch sets are independent of folders and keep unavailable members for later recovery.
struct AppGroup: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var apps: [String]
    static func make(name: String, apps: [String]) -> AppGroup {
        AppGroup(id: "app-group-" + UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines), apps: uniquePaths(apps))
    }
    static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
    static func validCollection(_ groups: [AppGroup]) -> Bool {
        groups.count <= 100 && Set(groups.map(\.id)).count == groups.count && groups.reduce(0, { $0 + $1.apps.count }) <= 20000 && groups.allSatisfy {
            !$0.id.isEmpty && $0.id.utf8.count <= 200 && (1...40).contains($0.name.count) &&
            $0.name == $0.name.trimmingCharacters(in: .whitespacesAndNewlines) &&
            !$0.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
            (1...1000).contains($0.apps.count) && Set($0.apps).count == $0.apps.count &&
            $0.apps.allSatisfy { $0.hasPrefix("/") && $0.utf8.count < 4096 }
        }
    }
}

extension AppModel {
    @discardableResult func storeAppGroup(_ group: AppGroup) -> Bool {
        let before = layout
        if let index = layout.appGroups.firstIndex(where: { $0.id == group.id }) { layout.appGroups[index] = group }
        else { layout.appGroups.append(group) }
        guard save() else { layout = before; return false }
        return true
    }
    @discardableResult func deleteAppGroup(_ id: String) -> Bool {
        let before = layout
        layout.appGroups.removeAll { $0.id == id }
        guard save() else { layout = before; return false }
        return true
    }
    func batchTargets(_ paths: [String]) -> [AppBatchTarget] {
        AppGroup.uniquePaths(paths).map {
            AppBatchTarget(path: $0, name: record($0)?.name ?? URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent,
                           available: record($0) != nil)
        }
    }
}

extension PageManagerState {
    /// Resolve all selections, including ones outside the current page or search, in spatial order.
    func selectedAppPaths(model: AppModel) -> [String] {
        let slots = positions(model: model)
        return AppGroup.uniquePaths(tiles(model: model).filter { selectedIDs.contains($0.id) }
            .sorted { (slots[$0.id] ?? 0) < (slots[$1.id] ?? 0) }.flatMap { tile in
                guard tile.isFolder else { return tile.apps }
                let internalSlots = model.layout.resolvedPositions(folderID: tile.id)
                return tile.apps.sorted { (internalSlots[$0] ?? 0) < (internalSlots[$1] ?? 0) }
            })
    }
}
