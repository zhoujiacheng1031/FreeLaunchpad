import SwiftUI

struct BatchGroupingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: PageManagerState
    @FocusState private var nameFocused: Bool
    var body: some View {
        let plan = try? state.groupingPlan(model: model)
        VStack(alignment: .leading, spacing: 18) {
            Text("整理到文件夹").font(.title2.weight(.semibold))
            Text("已勾选 \(state.selectedIDs.count) 个图标。所选文件夹会合并内容，不会嵌套。").foregroundStyle(.secondary)
            Picker("整理方式", selection: $state.groupingTargetID) {
                Text("创建新文件夹").tag("")
                ForEach(model.layout.tiles.filter(\.isFolder)) { folder in Text("移入：\(folder.name)").tag(folder.id) }
            }.accessibilityLabel("整理到新文件夹或已有文件夹")
            if state.groupingTargetID.isEmpty {
                TextField("文件夹名称", text: $state.groupingName).textFieldStyle(.roundedBorder)
                    .focused($nameFocused).accessibilityLabel("新文件夹名称")
            }
            VStack(alignment: .leading, spacing: 8) {
                if let plan {
                    Text("将整理 \(plan.selectedCount) 个图标，共 \(plan.incomingAppCount) 个应用。")
                    Text(plan.createdNew ? "新文件夹放在所选图标最靠前的位置，其余原位置留空。" : "目标文件夹的位置、名称和现有内部空位保留；移入应用追加到内部末尾。")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(validationMessage).font(.callout).foregroundStyle(.red)
                }
                if !state.groupingError.isEmpty { Text(state.groupingError).font(.callout).foregroundStyle(.red) }
                Text("完成后可在页面管理中撤销最近一次整理。").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14).launcherGlass(radius: 16)
            HStack {
                Spacer()
                Button("取消") { state.groupingPresented = false }.keyboardShortcut(.cancelAction)
                Button(state.groupingTargetID.isEmpty ? "创建文件夹" : "移入文件夹") { state.group(model: model) }
                    .buttonStyle(.borderedProminent).disabled(plan == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 500)
        .onAppear { nameFocused = state.groupingTargetID.isEmpty }
        .onChange(of: state.groupingTargetID) { _ in state.groupingError = ""; nameFocused = state.groupingTargetID.isEmpty }
        .onChange(of: state.groupingName) { _ in state.groupingError = "" }
    }
    var validationMessage: String {
        do { _ = try state.groupingPlan(model: model); return "" }
        catch { return error.localizedDescription }
    }
}
