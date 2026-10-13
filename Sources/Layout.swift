import Foundation

struct AppRecord: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    let bundleID: String
    var aliases: [String] = []
    var searchText: String {
        let names = ([name] + aliases).joined(separator: " ")
        let pinyin = names.applyingTransform(.toLatin, reverse: false) ?? names
        return "\(names) \(bundleID) \(pinyin) \(pinyin.replacingOccurrences(of: " ", with: ""))"
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}

struct Tile: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var apps: [String]
    var isFolder: Bool
    static func app(_ path: String) -> Tile { Tile(id: path, name: "", apps: [path], isFolder: false) }
    static func folder(_ paths: [String], name: String = "新建文件夹") -> Tile {
        Tile(id: "folder-" + UUID().uuidString, name: name, apps: paths, isFolder: true)
    }
}

struct Layout: Codable, Equatable {
    var version = 5
    var appGroups: [AppGroup] = []
    var tiles: [Tile] = []
    var hidden: [String] = []
    var positions: [String: Int] = [:]
    var folderPositions: [String: [String: Int]] = [:]
    var columns = 7
    var rows = 5
    var iconSize: Double = 88
    var horizontalSpacing: Double = 1
    var verticalSpacing: Double = 1
    var appearanceRevision = 2
    var extraPaths: [String] = []
    var backgroundPath: String? = nil
    var backgroundBlur: Double = 18
    var hotCorner = "none"
    var hideDock = false
    var backgroundOpacity: Double = 0.82
    var backgroundMode = "wallpaper"
    var pageNames: [String: String] = [:]
    var folderPageNames: [String: [String: String]] = [:]
    var layoutLocked = false

    enum CodingKeys: String, CodingKey {
        case appGroups, positions, folderPositions, version, tiles, hidden, columns, rows, iconSize, horizontalSpacing, verticalSpacing, extraPaths, backgroundPath, backgroundBlur, hotCorner, hideDock, backgroundOpacity, backgroundMode, appearanceRevision, pageNames, folderPageNames, layoutLocked
    }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        if (1...4).contains(version) { version = 5 }
        appGroups = try values.decodeIfPresent([AppGroup].self, forKey: .appGroups) ?? []
        tiles = try values.decode([Tile].self, forKey: .tiles)
        hidden = try values.decode([String].self, forKey: .hidden)
        positions = try values.decodeIfPresent([String: Int].self, forKey: .positions) ?? [:]
        folderPositions = try values.decodeIfPresent([String: [String: Int]].self, forKey: .folderPositions) ?? [:]
        columns = try values.decode(Int.self, forKey: .columns)
        rows = try values.decode(Int.self, forKey: .rows)
        iconSize = try values.decode(Double.self, forKey: .iconSize)
        horizontalSpacing = try values.decodeIfPresent(Double.self, forKey: .horizontalSpacing) ?? 1
        verticalSpacing = try values.decodeIfPresent(Double.self, forKey: .verticalSpacing) ?? 1
        appearanceRevision = try values.decodeIfPresent(Int.self, forKey: .appearanceRevision) ?? 1
        if appearanceRevision < 2 {
            if iconSize == 64 { iconSize = 88 }
            appearanceRevision = 2
        }
        extraPaths = try values.decode([String].self, forKey: .extraPaths)
        backgroundPath = try values.decodeIfPresent(String.self, forKey: .backgroundPath)
        backgroundBlur = try values.decode(Double.self, forKey: .backgroundBlur)
        hotCorner = try values.decode(String.self, forKey: .hotCorner)
        hideDock = try values.decodeIfPresent(Bool.self, forKey: .hideDock) ?? false
        backgroundOpacity = try values.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.82
        backgroundMode = try values.decodeIfPresent(String.self, forKey: .backgroundMode) ?? (backgroundPath == nil ? "wallpaper" : "image")
        pageNames = try values.decodeIfPresent([String: String].self, forKey: .pageNames) ?? [:]
        folderPageNames = try values.decodeIfPresent([String: [String: String]].self, forKey: .folderPageNames) ?? [:]
        layoutLocked = try values.decodeIfPresent(Bool.self, forKey: .layoutLocked) ?? false
    }

    func validated() throws -> Layout {
        guard version == 5, AppGroup.validCollection(appGroups), (4...10).contains(columns), (3...7).contains(rows),
              (40...128).contains(iconSize), iconSize.isFinite,
              (0...1).contains(horizontalSpacing), horizontalSpacing.isFinite,
              (0...1).contains(verticalSpacing), verticalSpacing.isFinite,
              (0...1).contains(backgroundOpacity), backgroundOpacity.isFinite,
              ["desktop", "wallpaper", "image"].contains(backgroundMode),
              (0...40).contains(backgroundBlur), backgroundBlur.isFinite,
              ["none", "topLeft", "topRight", "bottomLeft", "bottomRight"].contains(hotCorner),
              tiles.count <= 10000, hidden.count <= 10000, extraPaths.count <= 100,
              tiles.allSatisfy({ !$0.id.isEmpty && $0.name.count <= 200 && $0.apps.count <= 10000 && ($0.isFolder || $0.apps.count == 1) }),
              Set(tiles.map(\.id)).count == tiles.count,
              (hidden + extraPaths + tiles.flatMap(\.apps)).allSatisfy({ $0.hasPrefix("/") && $0.utf8.count < 4096 }),
              backgroundPath == nil || backgroundPath!.hasPrefix("/")
        else { throw LayoutError.invalidBackup }
        guard validPositions(positions, ids: tiles.map(\.id)), folderPositions.count <= tiles.count,
              folderPositions.allSatisfy({ id, slots in
                  guard let folder = tiles.first(where: { $0.id == id && $0.isFolder }) else { return false }
                  return validPositions(slots, ids: folder.apps)
              }), validPageNames(pageNames), folderPageNames.count <= tiles.count,
              folderPageNames.allSatisfy({ id, names in
                  tiles.contains(where: { $0.id == id && $0.isFolder }) && validPageNames(names)
              }) else { throw LayoutError.invalidBackup }
        return self
    }

    mutating func reconcile(_ catalog: [AppRecord]) {
        normalizePositions()
        defer { normalizePositions() }
        let available = Set(catalog.map(\.path))
        let hiddenSet = Set(hidden)
        var seen = Set<String>()
        tiles = tiles.compactMap { tile in
            var updated = tile
            updated.apps = tile.apps.filter { available.contains($0) && !hiddenSet.contains($0) && seen.insert($0).inserted }
            guard !updated.apps.isEmpty else { return nil }
            return updated
        }
        for app in catalog where !hiddenSet.contains(app.path) && seen.insert(app.path).inserted {
            tiles.append(.app(app.path))
        }
        hidden = Array(hiddenSet).sorted()
    }

    mutating func hide(_ path: String) {
        guard !layoutLocked else { return }
        normalizePositions()
        defer { normalizePositions() }
        if !hidden.contains(path) { hidden.append(path) }
        removeApp(path)
    }
    mutating func unhide(_ path: String) {
        guard !layoutLocked else { return }
        normalizePositions()
        defer { normalizePositions() }
        hidden.removeAll { $0 == path }
        if !tiles.contains(where: { $0.apps.contains(path) }) { tiles.append(.app(path)) }
    }
    mutating func removeApp(_ path: String) {
        guard !layoutLocked else { return }
        normalizePositions()
        defer { normalizePositions() }
        tiles = tiles.compactMap { tile in
            var updated = tile
            updated.apps.removeAll { $0 == path }
            return updated.apps.isEmpty ? nil : updated
        }
    }
    mutating func group(_ path: String, with targetID: String) {
        guard !layoutLocked else { return }
        normalizePositions()
        defer { normalizePositions() }
        guard let target = tiles.first(where: { $0.id == targetID }), !target.apps.contains(path),
              tiles.contains(where: { $0.apps.contains(path) }) else { return }
        let targetSlot = positions[targetID]!
        removeApp(path)
        guard let index = tiles.firstIndex(where: { $0.id == targetID }) else { return }
        if target.isFolder { tiles[index].apps.append(path) }
        else { tiles[index] = .folder(target.apps + [path]); positions[tiles[index].id] = targetSlot }
    }
    mutating func groupTile(_ id: String, with targetID: String) {
        guard !layoutLocked else { return }
        normalizePositions()
        defer { normalizePositions() }
        guard id != targetID, let source = tiles.first(where: { $0.id == id }),
              let target = tiles.first(where: { $0.id == targetID }) else { return }
        if !source.isFolder { group(source.apps[0], with: targetID); return }
        let targetSlot = positions[targetID]!
        tiles.removeAll { $0.id == id }
        guard let index = tiles.firstIndex(where: { $0.id == targetID }) else { return }
        if target.isFolder { tiles[index].apps += source.apps.filter { !target.apps.contains($0) } }
        else { tiles[index] = .folder(target.apps + source.apps, name: source.name); positions[tiles[index].id] = targetSlot }
    }
    mutating func extract(_ path: String) {
        guard !layoutLocked else { return }
        normalizePositions()
        defer { normalizePositions() }
        removeApp(path)
        tiles.append(.app(path))
    }
    mutating func ungroup(_ id: String) {
        guard !layoutLocked else { return }
        normalizePositions()
        defer { normalizePositions() }
        guard let index = tiles.firstIndex(where: { $0.id == id && $0.isFolder }) else { return }
        let slot = positions[id]!
        let apps = tiles[index].apps
        tiles.replaceSubrange(index...index, with: apps.map(Tile.app))
        positions.removeValue(forKey: id)
        var next = slot
        for path in apps {
            if next > Self.maximumSlot { next = 0 }
            while positions.values.contains(next) { next += 1; if next > Self.maximumSlot { next = 0 } }
            positions[path] = next; next += 1
        }
        tiles.sort { positions[$0.id]! < positions[$1.id]! }
    }
    mutating func move(_ id: String, before target: String) {
        guard !layoutLocked else { return }
        guard id != target, let source = tiles.firstIndex(where: { $0.id == id }), tiles.contains(where: { $0.id == target }) else { return }
        normalizePositions()
        defer { assignOrderedPositions() }
        let tile = tiles.remove(at: source)
        let index = tiles.firstIndex(where: { $0.id == target })!
        tiles.insert(tile, at: index)
    }

    /// Page numbers describe the layout before the removal, so an earlier source
    /// never shifts the item back onto the preceding page at a page boundary.
    mutating func move(_ id: String, toPage page: Int, capacity: Int, folderID: String? = nil) {
        guard !layoutLocked else { return }
        guard page >= 0, capacity > 0 else { return }
        if let folderID, let folder = tiles.firstIndex(where: { $0.id == folderID && $0.isFolder }) {
            guard let source = tiles[folder].apps.firstIndex(of: id) else { return }
            let count = tiles[folder].apps.count
            guard page <= (max(1, count) - 1) / capacity else { return }
            normalizePositions()
            defer { assignOrderedPositions(folderID: folderID) }
            let app = tiles[folder].apps.remove(at: source)
            tiles[folder].apps.insert(app, at: min(page * capacity, tiles[folder].apps.count))
        } else if folderID == nil {
            guard let source = tiles.firstIndex(where: { $0.id == id }), page <= (max(1, tiles.count) - 1) / capacity else { return }
            normalizePositions()
            defer { assignOrderedPositions() }
            let tile = tiles.remove(at: source)
            tiles.insert(tile, at: min(page * capacity, tiles.count))
        }
    }
    mutating func move(_ id: String, before target: String, folderID: String) {
        guard !layoutLocked else { return }
        guard id != target, let folder = tiles.firstIndex(where: { $0.id == folderID && $0.isFolder }),
              let source = tiles[folder].apps.firstIndex(of: id), tiles[folder].apps.contains(target) else { return }
        normalizePositions()
        defer { assignOrderedPositions(folderID: folderID) }
        let app = tiles[folder].apps.remove(at: source)
        let index = tiles[folder].apps.firstIndex(of: target)!
        tiles[folder].apps.insert(app, at: index)
    }
}

enum LayoutError: LocalizedError {
    case invalidBackup
    var errorDescription: String? { "布局文件不受支持或包含无效数据，当前布局未更改。" }
}

enum CatalogScanner {
    static func scan(extraPaths: [String], excluding ownPath: String) -> [AppRecord] {
        let fm = FileManager.default
        let roots = ["/Applications", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path, "/System/Applications"] + extraPaths
        var found: [String: AppRecord] = [:]
        func add(_ url: URL) {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path != ownPath, found[path] == nil, let bundle = Bundle(url: url),
                  let executable = bundle.executableURL, fm.isExecutableFile(atPath: executable.path),
                  (bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool) != true else { return }
            let bundleName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let displayName = fm.displayName(atPath: path)
            let name = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
            var aliases = Set([bundleName, url.deletingPathExtension().lastPathComponent])
            let preferredLocalization = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: Locale.preferredLanguages).first
            var localizedName: String?
            if let resources = bundle.resourceURL,
               let children = try? fm.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil) {
                for localization in children where localization.pathExtension == "lproj" {
                    let strings = localization.appendingPathComponent("InfoPlist.strings")
                    guard let data = try? Data(contentsOf: strings),
                          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                    for key in ["CFBundleName", "CFBundleDisplayName"] {
                        if let alias = plist[key] as? String { aliases.insert(alias) }
                    }
                    if localization.deletingPathExtension().lastPathComponent == preferredLocalization {
                        localizedName = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
                    }
                }
            }
            found[path] = AppRecord(path: path, name: localizedName ?? name, bundleID: bundle.bundleIdentifier ?? "", aliases: aliases.sorted())
        }
        for root in Set(roots) {
            let rootURL = URL(fileURLWithPath: root)
            if rootURL.pathExtension == "app" { add(rootURL); continue }
            guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if url.pathExtension == "app" { add(url); enumerator.skipDescendants() }
            }
        }
        add(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
