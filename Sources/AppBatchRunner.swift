import AppKit
import Combine

struct AppBatchTarget: Equatable {
    let path: String
    let name: String
    let available: Bool
}
struct AppInstance: Equatable {
    let pid: pid_t
    let path: String
    let bundleID: String
}
@MainActor protocol AppLifecycleDriver {
    func instances(at path: String) -> [AppInstance]
    func launch(_ path: String) async throws
    func quit(_ instance: AppInstance) -> Bool
}
@MainActor final class SystemAppLifecycle: AppLifecycleDriver {
    static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
    func instances(at path: String) -> [AppInstance] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let url = app.bundleURL, Self.canonical(url.path) == Self.canonical(path) else { return nil }
            return AppInstance(pid: app.processIdentifier, path: Self.canonical(url.path), bundleID: app.bundleIdentifier ?? "")
        }
    }
    func launch(_ path: String) async throws {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.createsNewApplicationInstance = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config) { app, error in
                if let error { continuation.resume(throwing: error) }
                else if app != nil { continuation.resume() }
                else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
            }
        }
    }
    func quit(_ instance: AppInstance) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: instance.pid), !app.isTerminated,
              let path = app.bundleURL?.path, Self.canonical(path) == Self.canonical(instance.path),
              !AppBatchRunner.protected(instance) else { return false }
        return app.terminate()
    }
}

enum AppBatchAction { case launch, quit }
enum AppBatchStatus: Equatable {
    case queued, opening, started, alreadyRunning, quitting, exited, notRunning, unavailable, protected, failed(String)
    var label: String {
        switch self {
        case .queued: return "等待处理"
        case .opening: return "正在启动…"
        case .started: return "已启动"
        case .alreadyRunning: return "已经运行"
        case .quitting: return "仍在运行，请处理保存提示或稍后重试"
        case .exited: return "已退出"
        case .notRunning: return "未运行"
        case .unavailable: return "应用不可用，请重新扫描或编辑组合"
        case .protected: return "保留系统组件和 FreeLaunchpad"
        case .failed(let reason): return reason
        }
    }
    var isIssue: Bool {
        switch self { case .failed, .unavailable, .quitting, .protected: return true; default: return false }
    }
}
struct AppBatchItem: Identifiable, Equatable {
    var id: String { target.path }
    let target: AppBatchTarget
    var status: AppBatchStatus = .queued
    var requestedPIDs: [pid_t] = []
}

@MainActor final class AppBatchRunner: ObservableObject {
    @Published private(set) var items: [AppBatchItem] = []
    @Published private(set) var busy = false
    @Published var workspaceBusy = false
    @Published private(set) var action = AppBatchAction.launch
    @Published private(set) var runningRevision = 0
    @Published var presented = false
    private let driver: AppLifecycleDriver
    private var observations: [AnyCancellable] = []
    private var scheduled = false
    init(driver: AppLifecycleDriver? = nil) {
        self.driver = driver ?? SystemAppLifecycle()
        if driver == nil {
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                NSWorkspace.shared.notificationCenter.publisher(for: name).receive(on: RunLoop.main)
                    .sink { [weak self] _ in self?.refresh() }.store(in: &observations)
            }
        }
    }
    static func protected(_ instance: AppInstance) -> Bool {
        instance.pid == ProcessInfo.processInfo.processIdentifier ||
        ["com.apple.finder", "com.apple.dock", "com.apple.systemuiserver", "com.apple.loginwindow", "local.free-launchpad.app"].contains(instance.bundleID.lowercased()) ||
        SystemAppLifecycle.canonical(instance.path) == SystemAppLifecycle.canonical(Bundle.main.bundleURL.path)
    }
    func isRunning(_ path: String) -> Bool { !driver.instances(at: path).isEmpty }
    func refresh() {
        runningRevision += 1
        for i in items.indices where action == .quit && !items[i].requestedPIDs.isEmpty {
            guard items[i].status == .quitting || { if case .failed = items[i].status { return true }; return false }() else { continue }
            let current = Set(driver.instances(at: items[i].target.path).map(\.pid))
            if items[i].requestedPIDs.allSatisfy({ !current.contains($0) }) { items[i].status = .exited }
        }
    }
    func start(_ action: AppBatchAction, targets: [AppBatchTarget]) {
        guard !busy, !scheduled, !workspaceBusy else { presented = true; return }
        scheduled = true
        presented = true
        Task { scheduled = false; await perform(action, targets: targets) }
    }
    func perform(_ action: AppBatchAction, targets: [AppBatchTarget], quitWaitNanoseconds: UInt64 = 1_500_000_000, forWorkspace: Bool = false) async {
        guard !busy, !workspaceBusy || forWorkspace else { return }
        busy = true; self.action = action
        var seen = Set<String>()
        items = targets.filter { seen.insert(SystemAppLifecycle.canonical($0.path)).inserted }.map { AppBatchItem(target: $0) }
        defer { busy = false; refresh() }
        for i in items.indices {
            let target = items[i].target
            let running = driver.instances(at: target.path)
            switch action {
            case .launch:
                if !running.isEmpty { items[i].status = .alreadyRunning; continue }
                guard target.available else { items[i].status = .unavailable; continue }
                items[i].status = .opening
                do { try await driver.launch(target.path); items[i].status = .started }
                catch { items[i].status = .failed("启动失败：" + error.localizedDescription) }
            case .quit:
                guard !running.isEmpty else { items[i].status = .notRunning; continue }
                guard !running.contains(where: Self.protected) else { items[i].status = .protected; continue }
                var accepted = true
                for instance in running { if !driver.quit(instance) { accepted = false } }
                items[i].requestedPIDs = running.map(\.pid)
                items[i].status = accepted ? .quitting : .failed("应用未接受退出请求；可能有保存提示，请处理后重试")
            }
        }
        if action == .quit && items.contains(where: { $0.status == .quitting }) {
            // A successful terminate() only acknowledges the request. Confirm termination separately.
            let deadline = DispatchTime.now().uptimeNanoseconds + quitWaitNanoseconds
            repeat {
                refresh()
                if !items.contains(where: { $0.status == .quitting }) { break }
                if DispatchTime.now().uptimeNanoseconds >= deadline { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            } while !Task.isCancelled
        }
    }
}
