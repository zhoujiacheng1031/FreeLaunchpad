import AppKit
import ApplicationServices
import Combine
import ObjectiveC.runtime

struct WorkspaceWindow: Equatable {
    let id: UInt32
    let pid: pid_t
    let path: String
}
@MainActor protocol DesktopWorkspaceDriver {
    func checkAvailability() throws
    func createDesktop() async throws -> UInt64
    func windows(at path: String) -> [WorkspaceWindow]
    func move(_ window: WorkspaceWindow, to desktop: UInt64) async throws
}
enum WorkspaceError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { switch self { case .unavailable(let message): return message } }
}

/// Traversal is shared by live AX elements and recorded topology regression fixtures.
enum MissionControlTree {
    static let hostBundleIDs = ["com.apple.WindowManager", "com.apple.dock"]
    static func isReady<Node>(_ display: Node?, identifier: (Node) -> String?, children: (Node) -> [Node]) -> Bool {
        guard let display else { return false }
        var found = Set<String>()
        func walk(_ node: Node, depth: Int) {
            if let id = identifier(node), id == "mc.spaces.add" || id == "mc.spaces.list" { found.insert(id) }
            guard depth < 8 else { return }
            for child in children(node) { walk(child, depth: depth + 1) }
        }
        walk(display, depth: 0)
        return found.contains("mc.spaces.add") && found.contains("mc.spaces.list")
    }
    static func display<Node>(in roots: [Node], screenID: UInt32,
                              identifier: (Node) -> String?, displayID: (Node) -> UInt32?,
                              children: (Node) -> [Node]) -> Node? {
        func walk(_ node: Node, depth: Int) -> Node? {
            if identifier(node) == "mc.display", displayID(node) == screenID { return node }
            guard depth < 8 else { return nil }
            for child in children(node) {
                if let match = walk(child, depth: depth + 1) { return match }
            }
            return nil
        }
        for root in roots { if let match = walk(root, depth: 0) { return match } }
        return nil
    }
}

/// Dynamically resolve the asynchronous WindowManager bridge without linking private classes.
private enum BridgedWindowMove {
    typealias Allocate = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
    typealias Initialize = @convention(c) (UnsafeMutableRawPointer, Selector, NSArray, UInt64) -> Unmanaged<AnyObject>?
    typealias Perform = @convention(c) (AnyObject, Selector) -> Void
    static var methods: (AnyClass, Method, Method, Method)? {
        guard let type = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation"),
              let alloc = class_getClassMethod(type, NSSelectorFromString("alloc")),
              let initialize = class_getInstanceMethod(type, NSSelectorFromString("initWithWindows:spaceID:")),
              let perform = class_getInstanceMethod(type, NSSelectorFromString("performWithWMBridgeDelegate")) else { return nil }
        return (type, alloc, initialize, perform)
    }
    static func start(window: UInt32, desktop: UInt64) throws -> AnyObject {
        guard let (type, alloc, initialize, perform) = methods,
              let raw = unsafeBitCast(method_getImplementation(alloc), to: Allocate.self)(type, NSSelectorFromString("alloc")),
              let owned = unsafeBitCast(method_getImplementation(initialize), to: Initialize.self)(raw, NSSelectorFromString("initWithWindows:spaceID:"), [NSNumber(value: window)] as NSArray, desktop) else {
            throw WorkspaceError.unavailable("系统窗口移动接口不可用。")
        }
        // alloc/init transfer one retained reference; keep the operation alive through verification.
        let operation = owned.takeRetainedValue()
        unsafeBitCast(method_getImplementation(perform), to: Perform.self)(operation, NSSelectorFromString("performWithWMBridgeDelegate"))
        return operation
    }
}

enum WorkspaceMembership {
    static func confirm(target: UInt64, read: () -> [UInt64]?,
                        pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) }) async throws -> Bool {
        for attempt in 0..<31 {
            if read() == [target] { return true }
            if attempt < 30 { try await pause() }
        }
        return false
    }
}

/// Experimental macOS integration, isolated from launch/quit and layout persistence.
/// Mission Control uses AX actions; window membership uses optional SkyLight symbols.
/// No injection, SIP changes, process restart, forced quit, or screen capture.
@MainActor final class SystemDesktopWorkspace: DesktopWorkspaceDriver {
    typealias Connection = @convention(c) () -> Int32
    typealias Displays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias WindowSpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias SpaceType = @convention(c) (Int32, UInt64) -> Int32
    typealias Compat = @convention(c) (Int32, UInt64, Int32) -> Int32
    typealias Move = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32, Int32) -> Int32
    typealias LegacyMove = @convention(c) (Int32, CFArray, UInt64) -> Void
    private let handle: UnsafeMutableRawPointer?
    private let connection: Connection?
    private let displays: Displays?
    private let windowSpaces: WindowSpaces?
    private let spaceType: SpaceType?
    private let compat: Compat?
    private let moveModern: Move?
    private let moveLegacy: LegacyMove?
    init() {
        let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        handle = library
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let library, let address = dlsym(library, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        connection = symbol("SLSMainConnectionID", Connection.self)
        displays = symbol("SLSCopyManagedDisplaySpaces", Displays.self)
        windowSpaces = symbol("SLSCopySpacesForWindows", WindowSpaces.self)
        spaceType = symbol("SLSSpaceGetType", SpaceType.self)
        compat = symbol("SLSSpaceSetCompatID", Compat.self)
        moveModern = symbol("SLSSetWindowListWorkspace", Move.self)
        moveLegacy = symbol("SLSMoveWindowsToManagedSpace", LegacyMove.self)
    }
    deinit { if let handle { dlclose(handle) } }
    private var modern: Bool {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return os.majorVersion > 14 || (os.majorVersion == 14 && os.minorVersion >= 5)
    }
    func checkAvailability() throws {
        guard AXIsProcessTrusted() else {
            throw WorkspaceError.unavailable("自动创建桌面和归入窗口需要辅助功能权限。请在系统设置 → 隐私与安全性 → 辅助功能中开启 FreeLaunchpad，再重试。")
        }
        guard connection != nil, displays != nil, windowSpaces != nil, spaceType != nil,
              (BridgedWindowMove.methods != nil || (modern ? (compat != nil && moveModern != nil) : moveLegacy != nil)) else {
            throw WorkspaceError.unavailable("当前系统未提供可用的桌面接口。可以先在调度中心手动创建桌面，再批量启动。")
        }
    }
    private func displaySpaces(_ screen: NSScreen) throws -> (ids: [UInt64], current: UInt64) {
        guard let connection, let displays, let raw = displays(connection())?.takeRetainedValue(),
              let entries = raw as? [[String: Any]],
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else {
            throw WorkspaceError.unavailable("无法读取当前显示器的桌面信息。")
        }
        let identifier = CFUUIDCreateString(nil, uuid) as String
        guard let entry = entries.first(where: { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(identifier) == .orderedSame })
                ?? (entries.count == 1 ? entries.first : nil),
              let spaces = entry["Spaces"] as? [[String: Any]],
              let current = (entry["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber else {
            throw WorkspaceError.unavailable("无法确定当前桌面，操作已停止。")
        }
        return (spaces.compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }, current.uint64Value)
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    private func find(_ element: AXUIElement, id: String, depth: Int = 0) -> AXUIElement? {
        if attribute(element, kAXIdentifierAttribute) as? String == id { return element }
        guard depth < 8 else { return nil }
        for child in children(element) { if let match = find(child, id: id, depth: depth + 1) { return match } }
        return nil
    }
    private func missionControlRoots() -> [AXUIElement] {
        MissionControlTree.hostBundleIDs.compactMap { bundleID in
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.5)
            return root
        }
    }
    private func missionControlDisplay(screen: NSScreen) -> AXUIElement? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        // Newer systems expose mc.display under WindowManager; older ones nest it in Dock's mc group.
        return MissionControlTree.display(in: missionControlRoots(), screenID: number.uint32Value,
            identifier: { self.attribute($0, kAXIdentifierAttribute) as? String },
            displayID: { (self.attribute($0, "AXDisplayID") as? NSNumber)?.uint32Value },
            children: children)
    }
    private func control(screen: NSScreen, id: String) -> AXUIElement? {
        guard let display = missionControlDisplay(screen: screen) else { return nil }
        return find(display, id: id)
    }
    func createDesktop() async throws -> UInt64 {
        try checkAvailability()
        guard let screen = NSScreen.main, !missionControlRoots().isEmpty else {
            throw WorkspaceError.unavailable("找不到调度中心。")
        }
        let before = try displaySpaces(screen)
        // The Dock can retain an empty Mission Control group after it closes.
        // A retained display alone is not enough: its desktop controls must be populated.
        if !MissionControlTree.isReady(missionControlDisplay(screen: screen), identifier: { self.attribute($0, kAXIdentifierAttribute) as? String }, children: children) {
            let config = NSWorkspace.OpenConfiguration()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"), configuration: config) { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
        var add: AXUIElement?
        for _ in 0..<30 {
            add = control(screen: screen, id: "mc.spaces.add")
            if add != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let add, AXUIElementPerformAction(add, kAXPressAction as CFString) == .success else {
            throw WorkspaceError.unavailable("调度中心的新建按钮不可用。请按 Esc 返回，或手动新建桌面。")
        }
        var newID: UInt64?
        for _ in 0..<30 {
            let now = try displaySpaces(screen)
            let added = now.ids.filter { !before.ids.contains($0) }
            if added.count == 1 { newID = added[0]; break }
            if added.count > 1 { throw WorkspaceError.unavailable("检测到多个新桌面，无法确定目标，操作已停止。") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let newID else { throw WorkspaceError.unavailable("未确认新桌面已创建；可能达到桌面数量上限。没有启动或搬移应用。") }
        for _ in 0..<30 {
            let now = try displaySpaces(screen)
            if let index = now.ids.firstIndex(of: newID), let list = control(screen: screen, id: "mc.spaces.list") {
                let buttons = children(list)
                if buttons.indices.contains(index), AXUIElementPerformAction(buttons[index], kAXPressAction as CFString) == .success { break }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        for _ in 0..<30 {
            if try displaySpaces(screen).current == newID { return newID }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw WorkspaceError.unavailable("桌面已经创建，但未确认切换成功。请手动切换后重试批量启动；空桌面可以在调度中心关闭。")
    }
    func windows(at path: String) -> [WorkspaceWindow] {
        let instances = SystemAppLifecycle().instances(at: path).filter { !AppBatchRunner.protected($0) }
        let pids = Set(instances.map(\.pid))
        // Space transitions can expose temporary layer-0 surfaces with no managed-space membership.
        let entries = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? NSNumber, pids.contains(pid.int32Value),
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = entry[kCGWindowNumber as String] as? NSNumber,
                  let connection, let windowSpaces,
                  let memberships = windowSpaces(connection(), 7, [id] as CFArray)?.takeRetainedValue() as? [NSNumber],
                  !memberships.isEmpty,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  (bounds["Width"] as? NSNumber)?.doubleValue ?? 0 >= 40,
                  (bounds["Height"] as? NSNumber)?.doubleValue ?? 0 >= 40 else { return nil }
            return WorkspaceWindow(id: id.uint32Value, pid: pid.int32Value, path: path)
        }
    }
    func move(_ window: WorkspaceWindow, to desktop: UInt64) async throws {
        try checkAvailability()
        guard SystemAppLifecycle().instances(at: window.path).contains(where: { $0.pid == window.pid }),
              let connection, let windowSpaces, let spaceType else { throw WorkspaceError.unavailable("应用窗口已经改变，请重试。") }
        let cid = connection()
        let ids = [NSNumber(value: window.id)] as CFArray
        guard let memberships = windowSpaces(cid, 7, ids)?.takeRetainedValue() as? [NSNumber], !memberships.isEmpty,
              spaceType(cid, desktop) == 0 else { throw WorkspaceError.unavailable("无法确认窗口或目标桌面。") }
        if memberships.map(\.uint64Value) == [desktop] { return }
        guard memberships.count == 1, spaceType(cid, memberships[0].uint64Value) == 0 else {
            throw WorkspaceError.unavailable("全屏窗口或显示在多个桌面的窗口需要手动调整。")
        }
        var operation: AnyObject?
        defer { withExtendedLifetime(operation) {} }
        if BridgedWindowMove.methods != nil {
            operation = try BridgedWindowMove.start(window: window.id, desktop: desktop)
        } else if modern, let compat, let moveModern {
            let tag: Int32 = 0x79616265
            guard compat(cid, desktop, tag) == 0 else { throw WorkspaceError.unavailable("系统拒绝归入窗口。") }
            defer { _ = compat(cid, desktop, 0) }
            var id = window.id
            guard moveModern(cid, &id, 1, tag) == 0 else { throw WorkspaceError.unavailable("系统拒绝移动窗口。") }
        } else { moveLegacy?(cid, ids, desktop) }
        let confirmed = try await WorkspaceMembership.confirm(target: desktop) {
            (windowSpaces(cid, 7, ids)?.takeRetainedValue() as? [NSNumber])?.map(\.uint64Value)
        }
        guard confirmed else {
            throw WorkspaceError.unavailable("窗口未确认移入；请在调度中心手动检查。")
        }
    }
}

@MainActor final class DesktopWorkspaceRunner: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var feedback = ""
    @Published private(set) var results: [String: String] = [:]
    private let driver: DesktopWorkspaceDriver
    init(driver: DesktopWorkspaceDriver? = nil) { self.driver = driver ?? SystemDesktopWorkspace() }
    func start(targets: [AppBatchTarget], batch: AppBatchRunner, completion: @escaping () -> Void = {}) {
        guard !busy, !batch.busy else { return }
        busy = true; batch.workspaceBusy = true; feedback = "正在准备新桌面…"; results = [:]
        let snapshot = targets
        Task { await run(targets: snapshot, batch: batch); completion() }
    }
    func run(targets: [AppBatchTarget], batch: AppBatchRunner) async {
        defer { busy = false; batch.workspaceBusy = false }
        do {
            try driver.checkAvailability()
            let desktop = try await driver.createDesktop()
            feedback = "已创建新桌面，正在启动和归入窗口…"
            await batch.perform(.launch, targets: targets, forWorkspace: true)
            for item in batch.items {
                guard item.status == .started || item.status == .alreadyRunning else { results[item.id] = item.status.label; continue }
                var windows = driver.windows(at: item.id)
                for _ in 0..<30 where windows.isEmpty {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    windows = driver.windows(at: item.id)
                }
                if windows.isEmpty { results[item.id] = "未找到普通窗口；应用可能无窗口或仍在打开"; continue }
                var moved = 0, issues: [String] = []
                for window in windows {
                    do { try await driver.move(window, to: desktop); moved += 1 }
                    catch { issues.append(error.localizedDescription) }
                }
                results[item.id] = issues.isEmpty ? "已归入新桌面 · \(moved) 个窗口" : "已归入 \(moved) / \(windows.count) 个窗口；\(issues.first!)"
            }
            feedback = "桌面工作组已处理，请检查各应用的窗口结果。全屏、固定桌面和后续新开的窗口可能需要手动调整。"
        } catch { feedback = error.localizedDescription }
    }
}
