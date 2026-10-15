import AppKit
import SwiftUI
import Carbon
import ApplicationServices

final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel!
    var launcher: LauncherWindow!
    var settings: NSWindow?
    var pageManager: NSWindow?
    var appGroups: NSWindow?
    var batchResults: NSWindow?
    let appGroupsState = AppGroupsState()
    let appBatch = AppBatchRunner()
    let desktopWorkspace = DesktopWorkspaceRunner()
    let pageManagerState = PageManagerState()
    var statusItem: NSStatusItem!
    var hotKey: EventHotKeyRef?
    var hotKeyHandler: EventHandlerRef?
    var keyMonitor: Any?
    var scrollMonitor: Any?
    var cornerTimer: Timer?
    var refreshTimer: Timer?
    var cornerEnteredAt: Date?
    var cornerLatched = false
    var lastScroll = Date.distantPast
    var dockSession = DockPresentationSession()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model = AppModel()
        model.dismiss = { [weak self] in self?.hide() }
        model.showSettings = { [weak self] in self?.openSettings() }
        model.showPageManager = { [weak self] in self?.openPageManager() }
        model.showAppGroups = { [weak self] paths in self?.openAppGroups(paths: paths) }
        model.performAppBatch = { [weak self] action, paths in
            guard let self, !self.desktopWorkspace.busy else { return }
            self.appBatch.start(action, targets: self.model.batchTargets(paths)); self.openBatchResults()
        }
        model.startDesktopWorkspace = { [weak self] paths in
            guard let self, !self.appBatch.busy, !self.desktopWorkspace.busy else { return }
            self.hide(); self.appGroups?.orderOut(nil); self.pageManager?.orderOut(nil); self.batchResults?.orderOut(nil)
            self.desktopWorkspace.start(targets: self.model.batchTargets(paths), batch: self.appBatch) { [weak self] in self?.openAppGroups(paths: nil) }
        }
        model.openWorkspacePermissions = {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        model.showManagedPage = { [weak self] folder, page in self?.showManagedPage(folder: folder, page: page) }
        model.configurationChanged = { [weak self] in self?.updatePresentation() }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        launcher = LauncherWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        launcher.isReleasedWhenClosed = false
        launcher.title = "FreeLaunchpad"
        launcher.level = .floating
        launcher.backgroundColor = .clear
        launcher.isOpaque = false
        launcher.hasShadow = false
        launcher.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        launcher.contentView = NSHostingView(rootView: LauncherView(model: model))
        launcher.delegate = self
        setupMenu()
        setupHotKey()
        setupInput()
        cornerTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.checkCorner(); self?.updateContentInsets() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.model.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if !ProcessInfo.processInfo.arguments.contains("--background") { show() }
    }
    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "FreeLaunchpad")
        let menu = NSMenu()
        let items: [(String, Selector, String)] = [
            ("打开 FreeLaunchpad", #selector(toggle), ""),
            ("页面管理…", #selector(openPageManager), "l"),
            ("桌面工作组…", #selector(openAppGroupsMenu), "g"),
            ("批量操作结果…", #selector(openBatchResults), ""),
            ("锁定 / 解锁布局", #selector(toggleLayoutLock), ""),
            ("设置…", #selector(openSettings), ","),
            ("重新扫描应用", #selector(rescan), ""),
            ("退出 FreeLaunchpad", #selector(quit), "q")
        ]
        for (title, action, key) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
        }
        statusItem.menu = menu
        let main = NSMenu()
        let application = NSMenuItem(); application.submenu = menu.copy() as? NSMenu; main.addItem(application)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
    }
    func setupHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { delegate.toggle() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        let identifier = EventHotKeyID(signature: OSType(0x46504C50), id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), identifier, GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { model.error = "快捷键注册失败（\(result)），可能被其他应用占用。仍可从菜单栏打开。" }
    }
    func setupInput() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, NSApp.modalWindow == nil else { return event }
            if NSApp.keyWindow === self.pageManager {
                guard self.pageManager?.attachedSheet == nil else { return event }
                if let editor = self.pageManager?.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                if event.modifierFlags.contains(.command), event.characters?.lowercased() == "f" {
                    self.pageManagerState.focusSearchGeneration += 1; return nil
                }
                if Int(event.keyCode) == kVK_Escape {
                    if self.pageManagerState.previewDragTile != nil { self.pageManagerState.cancelPreviewDrag() }
                    else if !self.pageManagerState.query.isEmpty { self.pageManagerState.query = "" }
                    else if self.pageManagerState.showSelectedOnly { self.pageManagerState.showSelectedOnly = false }
                    else { self.pageManager?.performClose(nil) }
                    return nil
                }
                return event
            }
            guard NSApp.keyWindow === self.launcher else { return event }
            if let editor = self.launcher.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            if event.modifierFlags.contains(.command) {
                if event.characters == "," { self.openSettings(); return nil }
                if event.characters?.lowercased() == "l" { self.openPageManager(); return nil }
                if event.characters?.lowercased() == "g" { self.openAppGroups(paths: nil); return nil }
                return event
            }
            switch Int(event.keyCode) {
            case kVK_Escape: self.model.escape(); return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if let tile = self.model.displayedTiles.first(where: { $0.id == self.model.selectedPath }) ?? self.model.pageTiles.first { self.model.activate(tile) }
                return nil
            case kVK_PageDown: self.model.movePage(1); return nil
            case kVK_PageUp: self.model.movePage(-1); return nil
            case kVK_LeftArrow: self.navigate(-1); return nil
            case kVK_RightArrow: self.navigate(1); return nil
            case kVK_UpArrow: self.navigate(-self.model.layout.columns); return nil
            case kVK_DownArrow: self.navigate(self.model.layout.columns); return nil
            default: return event
            }
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, NSApp.keyWindow === self.launcher, NSApp.modalWindow == nil else { return event }
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            if abs(delta) > 2, event.momentumPhase.isEmpty, Date().timeIntervalSince(self.lastScroll) > 0.45 {
                self.model.movePage(delta < 0 ? 1 : -1); self.lastScroll = Date()
            }
            return nil
        }
    }
    func navigate(_ offset: Int) { model.navigate(offset) }
    func show() {
        pageManagerState.cancelPreviewDrag()
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        launcher.setFrame(screen.frame, display: true)
        model.updateBackground(screen: screen, force: true)
        model.finishDrag()
        model.query = ""; model.folderID = nil; model.extraPage = nil; model.selectedPath = nil
        model.showGeneration += 1
        model.page = min(model.page, model.pageCount - 1)
        settings?.orderOut(nil); pageManager?.orderOut(nil); appGroups?.orderOut(nil); batchResults?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        launcher.makeKeyAndOrderFront(nil)
        updatePresentation()
    }
    func hide() {
        pageManagerState.cancelPreviewDrag()
        model.finishDrag()
        launcher.orderOut(nil)
        restorePresentation()
    }
    func updatePresentation() {
        guard launcher?.isVisible == true, NSApp.isActive else { return }
        let requested = dockSession.options(current: NSApp.presentationOptions, hideDock: model.layout.hideDock)
        if NSApp.presentationOptions != requested { NSApp.presentationOptions = requested }
        updateContentInsets()
    }
    func restorePresentation() {
        if let original = dockSession.restore() { NSApp.presentationOptions = original }
    }
    func updateContentInsets() {
        guard launcher?.isVisible == true, let screen = launcher.screen else { return }
        let insets = LauncherInsets.resolve(frame: screen.frame, visibleFrame: screen.visibleFrame, hideDock: model.layout.hideDock)
        if model.contentInsets != insets { model.contentInsets = insets }
    }
    @objc func screenParametersChanged() {
        guard launcher?.isVisible == true, let screen = launcher.screen ?? NSScreen.main else { return }
        launcher.setFrame(screen.frame, display: true)
        model.updateBackground(screen: screen, force: true)
        updatePresentation()
    }
    func applicationDidResignActive(_ notification: Notification) {
        hide()
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        updatePresentation()
    }
    @objc func toggle() { if launcher.isVisible { hide() } else { show() } }
    @objc func rescan() { model.refresh() }
    @objc func toggleLayoutLock() { model.setLayoutLocked(!model.layout.layoutLocked) }
    @objc func woke() { model.refresh() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func openSettings() {
        hide(); pageManager?.orderOut(nil); appGroups?.orderOut(nil); batchResults?.orderOut(nil)
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 644, height: 624), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "FreeLaunchpad 设置"
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.isReleasedWhenClosed = false; window.center(); settings = window
        }
        NSApp.activate(ignoringOtherApps: true); settings?.makeKeyAndOrderFront(nil)
    }
    @objc func openPageManager() {
        if pageManager?.isVisible == true {
            pageManagerState.reconcile(model: model)
            NSApp.activate(ignoringOtherApps: true); pageManager?.makeKeyAndOrderFront(nil)
            return
        }
        pageManagerState.configure(model: model)
        hide(); settings?.orderOut(nil); appGroups?.orderOut(nil); batchResults?.orderOut(nil)
        if pageManager == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "FreeLaunchpad 页面管理"
            window.contentView = NSHostingView(rootView: PageManagerView(model: model, state: pageManagerState))
            window.delegate = self
            window.minSize = NSSize(width: 920, height: 650)
            window.isReleasedWhenClosed = false; window.center(); pageManager = window
        }
        NSApp.activate(ignoringOtherApps: true); pageManager?.makeKeyAndOrderFront(nil)
    }
    @objc func openAppGroupsMenu() { openAppGroups(paths: nil) }
    func openAppGroups(paths: [String]?) {
        hide(); settings?.orderOut(nil); pageManager?.orderOut(nil); batchResults?.orderOut(nil)
        if appGroups == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "FreeLaunchpad 桌面工作组"
            window.contentView = NSHostingView(rootView: AppGroupsView(model: model, state: appGroupsState, batch: appBatch, workspace: desktopWorkspace))
            window.collectionBehavior = [.moveToActiveSpace]
            window.minSize = NSSize(width: 840, height: 650)
            window.isReleasedWhenClosed = false; window.center(); appGroups = window
        }
        if let paths { appGroupsState.edit(paths: paths) }
        else if appGroupsState.selectedID == nil { appGroupsState.selectedID = model.layout.appGroups.first?.id }
        NSApp.activate(ignoringOtherApps: true); appGroups?.makeKeyAndOrderFront(nil)
    }
    @objc func openBatchResults() {
        hide()
        if batchResults == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 530), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "FreeLaunchpad 批量应用操作"
            window.contentView = NSHostingView(rootView: AppBatchResultsView(model: model, batch: appBatch))
            window.collectionBehavior = [.moveToActiveSpace]
            window.minSize = NSSize(width: 600, height: 440)
            window.isReleasedWhenClosed = false; window.center(); batchResults = window
        }
        NSApp.activate(ignoringOtherApps: true); batchResults?.makeKeyAndOrderFront(nil)
    }
    func showManagedPage(folder: String?, page: Int) {
        pageManager?.orderOut(nil)
        show()
        model.folderID = folder.flatMap { id in model.layout.tiles.contains(where: { $0.id == id && $0.isFolder }) ? id : nil }
        model.extraPage = max(0, page)
        model.page = min(max(0, page), model.pageCount - 1)
    }
    func windowDidResignKey(_ notification: Notification) {
        guard NSApp.modalWindow == nil else { return }
        if notification.object as? NSWindow === pageManager { pageManagerState.cancelPreviewDrag() }
        if notification.object as? NSWindow === launcher { hide() }
    }
    func checkCorner() {
        guard model.layout.hotCorner != "none", !launcher.isVisible, NSApp.modalWindow == nil else { return }
        let point = NSEvent.mouseLocation
        let hit = NSScreen.screens.contains { screen in
            let frame = screen.frame
            let left = point.x >= frame.minX && point.x <= frame.minX + 3
            let right = point.x <= frame.maxX && point.x >= frame.maxX - 3
            let top = point.y <= frame.maxY && point.y >= frame.maxY - 3
            let bottom = point.y >= frame.minY && point.y <= frame.minY + 3
            switch model.layout.hotCorner {
            case "topLeft": return left && top
            case "topRight": return right && top
            case "bottomLeft": return left && bottom
            case "bottomRight": return right && bottom
            default: return false
            }
        }
        if !hit { cornerEnteredAt = nil; cornerLatched = false; return }
        if cornerEnteredAt == nil { cornerEnteredAt = Date() }
        if !cornerLatched, Date().timeIntervalSince(cornerEnteredAt!) > 0.35 { cornerLatched = true; show() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return false }
    func applicationWillTerminate(_ notification: Notification) {
        restorePresentation()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        cornerTimer?.invalidate(); refreshTimer?.invalidate()
    }
}

@main enum FreeLaunchpad {
    @MainActor static func main() throws {
        if CommandLine.arguments.contains("--diagnostics") {
            let apps = CatalogScanner.scan(extraPaths: [], excluding: Bundle.main.bundleURL.path)
            let report: [String: Any] = ["applicationCount": apps.count, "applications": apps.map { ["name": $0.name, "bundleID": $0.bundleID, "path": $0.path] }, "architecture": "native", "version": "1.8.3"]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data)
        } else {
            let application = NSApplication.shared
            let delegate = AppDelegate()
            application.delegate = delegate
            application.run()
        }
    }
}
