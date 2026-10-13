import AppKit

@MainActor final class LauncherMenuItem: NSMenuItem {
    let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("Menu items are created in code") }
    @objc private func runAction() { handler() }
}

@MainActor enum LauncherTileMenu {
    static func menu(model: AppModel, tile: Tile) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, to parent: NSMenu? = nil, editing: Bool = false, handler: @escaping () -> Void) {
            let item = LauncherMenuItem(title) { if !editing || !model.layout.layoutLocked { handler() } }
            item.isEnabled = !editing || !model.layout.layoutLocked
            (parent ?? menu).addItem(item)
        }
        menu.autoenablesItems = false
        if tile.isFolder {
            add("打开文件夹") { model.activate(tile) }
            add("重命名…", editing: true) {
                let alert = NSAlert(); alert.messageText = "文件夹名称"
                let field = NSTextField(string: tile.name); field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
                alert.accessoryView = field; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
                alert.window.initialFirstResponder = field
                if alert.runModal() == .alertFirstButtonReturn, !model.layout.layoutLocked, let index = model.layout.tiles.firstIndex(where: { $0.id == tile.id }) {
                    let name = String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                    if !name.isEmpty { model.layout.tiles[index].name = name; model.save() }
                }
            }
            add("解散文件夹", editing: true) { model.layout.ungroup(tile.id); model.save() }
        } else if let path = tile.apps.first {
            add("打开") { model.launch(path) }
            add("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            menu.addItem(.separator())
            if model.folderID != nil {
                add("移出文件夹", editing: true) {
                    model.layout.extract(path)
                    if model.folder == nil { model.folderID = nil; model.page = 0 }
                    model.save()
                }
            }
            let groups = NSMenu(title: "移入文件夹")
            groups.autoenablesItems = false
            for folder in model.layout.tiles.filter({ $0.isFolder && !$0.apps.contains(path) }) {
                add(folder.name, to: groups, editing: true) { model.layout.group(path, with: folder.id); model.save() }
            }
            let newGroup = NSMenu(title: "与应用创建文件夹")
            newGroup.autoenablesItems = false
            for other in model.layout.tiles.filter({ !$0.isFolder && !$0.apps.contains(path) }) {
                add(model.name(other), to: newGroup, editing: true) { model.layout.group(path, with: other.id); model.save() }
            }
            let createItem = NSMenuItem(title: newGroup.title, action: nil, keyEquivalent: ""); createItem.submenu = newGroup; groups.addItem(createItem)
            let groupItem = NSMenuItem(title: groups.title, action: nil, keyEquivalent: ""); groupItem.submenu = groups; groupItem.isEnabled = !model.layout.layoutLocked; menu.addItem(groupItem)
            add("隐藏应用", editing: true) { model.hide(path) }
        }
        if model.canArrange {
            menu.addItem(.separator())
            let pages = NSMenu(title: "移到页面")
            for page in 0..<model.pageCount {
                add(model.layout.pageTitle(page, folderID: model.folderID), to: pages, editing: true) {
                    model.layout.place(tile.id, at: model.layout.firstFreeSlot(on: page, capacity: model.capacity, folderID: model.folderID), folderID: model.folderID)
                    model.page = min(page, model.pageCount - 1); model.save()
                }
            }
            let pagesItem = NSMenuItem(title: pages.title, action: nil, keyEquivalent: ""); pagesItem.submenu = pages; menu.addItem(pagesItem)
            if model.folderID == nil {
                add("移到首页", editing: true) {
                    model.layout.place(tile.id, at: 0); model.page = 0; model.save()
                }
                add("移到末尾", editing: true) {
                    let last = (model.layout.resolvedPositions().values.max() ?? -1) + 1
                    model.layout.place(tile.id, at: last); model.page = last / model.capacity; model.save()
                }
            }
        }
        return menu
    }
}
