import Foundation

extension Layout {
    static let maximumNamedPage = maximumSlot / 12
    static func cleanPageName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func validPageNames(_ names: [String: String]) -> Bool {
        names.count <= 1000 && names.allSatisfy { key, name in
            guard let page = Int(key), String(page) == key, (0...Self.maximumNamedPage).contains(page) else { return false }
            return !name.isEmpty && name.count <= 40 && name == Self.cleanPageName(name)
                && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
    }
    func pageName(_ page: Int, folderID: String? = nil) -> String? {
        if let folderID { return folderPageNames[folderID]?[String(page)] }
        return pageNames[String(page)]
    }
    func pageTitle(_ page: Int, folderID: String? = nil) -> String {
        let number = "第 \(page + 1) 页"
        return pageName(page, folderID: folderID).map { "\(number) · \($0)" } ?? number
    }
    func namedPageCount(folderID: String? = nil) -> Int {
        let names = folderID.map { folderPageNames[$0] ?? [:] } ?? pageNames
        let supported = Self.maximumSlot / (columns * rows)
        return (names.keys.compactMap(Int.init).filter { $0 <= supported }.max() ?? -1) + 1
    }
    @discardableResult mutating func setPageName(_ name: String, page: Int, folderID: String? = nil) -> Bool {
        guard !layoutLocked, (0...(Self.maximumSlot / (columns * rows))).contains(page) else { return false }
        if let folderID, !tiles.contains(where: { $0.id == folderID && $0.isFolder }) { return false }
        let cleaned = Self.cleanPageName(name)
        guard cleaned.isEmpty || validPageNames([String(page): cleaned]) else { return false }
        var names = folderID.map { folderPageNames[$0] ?? [:] } ?? pageNames
        if cleaned.isEmpty { names.removeValue(forKey: String(page)) } else { names[String(page)] = cleaned }
        guard validPageNames(names) else { return false }
        if let folderID {
            if names.isEmpty { folderPageNames.removeValue(forKey: folderID) } else { folderPageNames[folderID] = names }
        } else { pageNames = names }
        return true
    }
}
