import SwiftUI

@MainActor final class AppGroupsState: ObservableObject {
    @Published var selectedID: String?
    @Published var editing = false
    @Published var draftID: String?
    @Published var name = ""
    @Published var paths = Set<String>()
    @Published var query = ""
    @Published var error = ""
    @Published var feedback = ""
    func edit(_ group: AppGroup? = nil, paths: [String] = []) {
        draftID = group?.id; name = group?.name ?? "新工作组"
        self.paths = Set(group?.apps ?? paths); query = ""; error = ""; editing = true
    }
    func save(model: AppModel) {
        let existing = model.layout.appGroups.first { $0.id == draftID }?.apps ?? []
        let ordered = existing.filter { paths.contains($0) } + model.catalog.map(\.path).filter { paths.contains($0) && !existing.contains($0) }
        let missing = paths.subtracting(ordered).sorted()
        var group = AppGroup.make(name: name, apps: ordered + missing)
        if let draftID { group.id = draftID }
        guard AppGroup.validCollection([group]) else { error = "名称需为 1–40 个字符且不含换行；请选择 1–1000 个应用。"; return }
        guard model.storeAppGroup(group) else { error = model.error ?? "保存失败"; return }
        selectedID = group.id; editing = false; feedback = "工作组已保存。"
    }
}

struct AppGroupsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: AppGroupsState
    @ObservedObject var batch: AppBatchRunner
    @ObservedObject var workspace: DesktopWorkspaceRunner
    var body: some View {
        let selected = model.layout.appGroups.first { $0.id == state.selectedID }
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "rectangle.3.group").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("桌面工作组").font(.title2.weight(.semibold))
                    Text("把常用应用一起打开，在新的 macOS 桌面中使用。").foregroundStyle(.secondary)
                }
                Spacer()
                Button { state.edit() } label: { Label("新建工作组", systemImage: "plus") }.disabled(batch.busy || workspace.busy || model.layout.appGroups.count >= 100)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("我的工作组").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8)
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(model.layout.appGroups) { group in
                                Button { state.selectedID = group.id; state.feedback = "" } label: {
                                    HStack {
                                        Image(systemName: "rectangle.3.group")
                                        VStack(alignment: .leading, spacing: 4) { Text(group.name).lineLimit(2); Text("\(group.apps.count) 个应用").font(.caption).foregroundStyle(.secondary) }
                                        Spacer(minLength: 0)
                                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(group.id == state.selectedID ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain).accessibilityLabel("工作组：\(group.name)，\(group.apps.count) 个应用")
                            }
                        }
                    }
                    Text("保存成员名单，启动台中的图标位置保持原样。").font(.caption).foregroundStyle(.secondary).padding(8)
                }.padding(12).frame(width: 205).frame(maxHeight: .infinity).launcherGlass(radius: 20)
                if let group = selected {
                    detail(group).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "rectangle.3.group").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                        Text("准备一个桌面工作组").font(.title3.weight(.medium))
                        Text("例如‘写作’、‘开发’或‘会议’。\n先选好应用，再创建新桌面并集中窗口。")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("选择应用…") { state.edit() }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.padding(20).frame(minWidth: 840, minHeight: 620)
            .sheet(isPresented: $state.editing) { AppGroupEditor(model: model, state: state) }
            .onChange(of: model.layout.appGroups) { groups in
                if !groups.contains(where: { $0.id == state.selectedID }) { state.selectedID = groups.first?.id }
            }
    }
    func detail(_ group: AppGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name).font(.title2.weight(.semibold))
                    Text("\(group.apps.count) 个应用 · \(group.apps.filter { batch.isRunning($0) }.count) 个正在运行").foregroundStyle(.secondary)
                }
                Spacer()
                Button("编辑…") { state.edit(group) }.disabled(batch.busy || workspace.busy)
                Menu {
                    Button("删除工作组") {
                        if model.deleteAppGroup(group.id) { state.feedback = "工作组已删除，应用和桌面保持原样。" }
                        else { state.feedback = model.error ?? "删除失败" }
                    }.disabled(batch.busy || workspace.busy)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 26).accessibilityLabel("工作组更多操作")
            }
            VStack(alignment: .leading, spacing: 10) {
                Button { model.startDesktopWorkspace?(group.apps) } label: {
                    Label(workspace.busy ? "正在处理桌面…" : "新建桌面并归入应用", systemImage: "rectangle.badge.plus")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(batch.busy || workspace.busy)
                Text("试用功能：创建新桌面，启动未运行的应用，把已有普通窗口一起移入。需要辅助功能权限；桌面接口可能随系统更新变化。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("在当前桌面启动") { model.performAppBatch?(.launch, group.apps) }
                    Button("退出工作组应用") { model.performAppBatch?(.quit, group.apps) }
                    Spacer()
                    Button("辅助功能设置…") { model.openWorkspacePermissions?() }.buttonStyle(.link)
                }.disabled(batch.busy || workspace.busy)
            }.padding(14).launcherGlass(radius: 18)
            if !workspace.feedback.isEmpty { Text(workspace.feedback).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if !state.feedback.isEmpty { Text(state.feedback).font(.callout).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.batchTargets(group.apps), id: \.path) { target in
                        HStack(spacing: 12) {
                            Image(nsImage: model.icon(target.path)).resizable().scaledToFit().frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(target.name).lineLimit(1)
                                Text(memberStatus(target)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Image(systemName: batch.isRunning(target.path) ? "circle.fill" : "circle").font(.system(size: 8))
                                .foregroundStyle(batch.isRunning(target.path) ? Color.green : Color.secondary).accessibilityHidden(true)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).launcherGlass(radius: 14)
                    }
                }
            }
            Text("退出使用正常退出；若有未保存内容，请处理应用的保存提示。退出工作组不会删除桌面。").font(.caption).foregroundStyle(.secondary)
        }
    }
    func memberStatus(_ target: AppBatchTarget) -> String {
        if let result = workspace.results[target.path] { return result }
        if !target.available { return "应用不可用，成员名单保留" }
        return batch.isRunning(target.path) ? "正在运行" : "未运行"
    }
}

struct AppGroupEditor: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: AppGroupsState
    @FocusState private var nameFocused: Bool
    var members: [AppBatchTarget] {
        let all = model.catalog.map(\.path) + state.paths.filter { model.record($0) == nil }.sorted()
        let text = state.query.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return model.batchTargets(all).filter {
            text.isEmpty || (model.record($0.path)?.searchText ?? $0.name.lowercased()).contains(text)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(state.draftID == nil ? "新建桌面工作组" : "编辑桌面工作组").font(.title2.weight(.semibold))
            TextField("工作组名称", text: $state.name).textFieldStyle(.roundedBorder).focused($nameFocused).accessibilityLabel("工作组名称")
            TextField("搜索应用名称或拼音", text: $state.query).textFieldStyle(.roundedBorder).accessibilityLabel("搜索工作组成员")
            HStack {
                Text("已选 \(state.paths.count) 个应用").foregroundStyle(.secondary)
                Spacer()
                Button("全选搜索结果") { state.paths.formUnion(members.map(\.path)) }
                Button("清空选择") { state.paths = [] }
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(members, id: \.path) { target in
                        Toggle(isOn: Binding(get: { state.paths.contains(target.path) }, set: { checked in
                            if checked { state.paths.insert(target.path) } else { state.paths.remove(target.path) }
                        })) {
                            HStack(spacing: 10) {
                                Image(nsImage: model.icon(target.path)).resizable().scaledToFit().frame(width: 32, height: 32)
                                Text(target.name).lineLimit(1)
                                if !target.available { Text("不可用").font(.caption).foregroundStyle(.secondary) }
                            }
                        }.toggleStyle(.checkbox).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(height: 310)
            if !state.error.isEmpty { Text(state.error).font(.callout).foregroundStyle(.red) }
            Text("保存工作组只记录应用名单。点击‘新建桌面并归入应用’才会创建系统桌面。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { state.editing = false }.keyboardShortcut(.cancelAction)
                Button("保存工作组") { state.save(model: model) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(state.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.name.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 || state.paths.isEmpty || state.paths.count > 1000)
            }
        }.padding(24).frame(width: 560).onAppear { nameFocused = true }
    }
}

struct AppBatchResultsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var batch: AppBatchRunner
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(batch.action == .launch ? "批量启动" : "批量退出").font(.title2.weight(.semibold))
                Spacer()
                if batch.busy { ProgressView().controlSize(.small) }
                Text("\(batch.items.count) 个应用").foregroundStyle(.secondary)
            }
            Text(batch.action == .launch ? "已运行的应用保持运行；批量启动保留当前窗口焦点。" : "使用正常退出方式。仍在运行的应用可能需要保存内容或确认，请处理后重试。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(batch.items) { item in
                        HStack(spacing: 12) {
                            Image(nsImage: model.icon(item.id)).resizable().scaledToFit().frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.target.name)
                                Text(item.status.label).font(.callout).foregroundStyle(item.status.isIssue ? Color.orange : Color.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).launcherGlass(radius: 16)
                    }
                }
            }
            HStack {
                Spacer()
                Button("重新检查状态") { batch.refresh() }.disabled(batch.busy || batch.workspaceBusy)
                Button("重试未完成项") {
                    batch.start(batch.action, targets: model.batchTargets(batch.items.filter { $0.status.isIssue }.map { $0.target.path }))
                }.disabled(batch.busy || batch.workspaceBusy || !batch.items.contains(where: { $0.status.isIssue }))
            }
        }.padding(22).frame(minWidth: 580, minHeight: 400)
    }
}
