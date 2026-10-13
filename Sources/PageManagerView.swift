import SwiftUI

struct PageManagerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: PageManagerState
    @FocusState private var searchFocused: Bool
    var body: some View {
        let visible = state.visibleTiles(model: model)
        let pages = state.pages(model: model)
        let counts = state.counts(model: model)
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.3x3.square").font(.system(size: 27, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("页面管理").font(.title2.weight(.semibold))
                    Text(model.layout.layoutLocked ? "布局已锁定，仍可勾选应用并批量启动、退出。" : "与启动台位置一致 · 点击勾选，拖动调整位置。").foregroundStyle(.secondary)
                }
                Spacer()
                Button { state.toggleLock(model: model) } label: {
                    Label(model.layout.layoutLocked ? "已锁定" : "锁定布局", systemImage: model.layout.layoutLocked ? "lock.fill" : "lock.open")
                }.help(model.layout.layoutLocked ? "解除布局锁定" : "防止误拖动和修改布局")
                Picker("管理范围", selection: Binding(get: { state.scopeID }, set: { state.changeScope($0, model: model) })) {
                    Text("所有应用").tag("")
                    ForEach(model.layout.tiles.filter(\.isFolder)) { folder in Text(folder.name).tag(folder.id) }
                }.frame(width: 225).accessibilityLabel("管理范围")
            }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("来源页面").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10)
                    ScrollView {
                        VStack(spacing: 5) {
                            sourceButton("全部页面", page: -1, count: state.tiles(model: model).count)
                            ForEach(pages, id: \.self) { page in sourceButton(model.layout.pageTitle(page, folderID: state.folderID), page: page, count: counts[page] ?? 0) }
                        }
                    }
                    Button { state.addPage(model: model) } label: { Label("新建空白页", systemImage: "plus") }
                        .frame(maxWidth: .infinity).disabled(model.layout.layoutLocked).accessibilityLabel("新建空白页")
                    Button { state.presentGrouping(model: model) } label: { Label("整理到文件夹…", systemImage: "folder.badge.plus") }
                        .frame(maxWidth: .infinity).disabled(!state.canGroup(model: model))
                    if state.folderID != nil { Text("建组或合并请切换到‘所有应用’范围。").font(.caption).foregroundStyle(.secondary) }
                    Text("放入图标后保存。每页最多 \(model.capacity) 项。")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                }.padding(12).frame(width: 188).launcherGlass(radius: 20)
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("搜索名称或拼音", text: $state.query).textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("搜索页面图标").help("搜索名称或拼音 ⌘F")
                        if !state.query.isEmpty {
                            Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除页面搜索")
                        }
                    }.padding(12).launcherGlass(radius: 14)
                    HStack {
                        Text("当前显示 \(visible.count) 项 · 共选 \(state.selectedIDs.count) 项").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("只看已选", isOn: $state.showSelectedOnly).toggleStyle(.button).controlSize(.small)
                            .help("集中核对所有页面的勾选项").accessibilityLabel("只看已选图标")
                        Button("全选当前列表") { state.selectVisible(model: model) }.disabled(visible.isEmpty)
                            .keyboardShortcut("a", modifiers: [.command, .shift])
                        Button("清空选择") { state.selectedIDs = []; state.feedback = "" }.disabled(state.selectedIDs.isEmpty)
                    }
                    GeometryReader { area in
                      ScrollView {
                        if state.previewPages(model: model).isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: state.showSelectedOnly ? "checkmark.circle" : (state.query.isEmpty ? "square.grid.3x3" : "magnifyingglass")).font(.system(size: 30, weight: .light)).accessibilityHidden(true)
                                Text(state.showSelectedOnly ? (state.query.isEmpty ? "还没有选择图标" : "没有匹配的已选图标") : (state.query.isEmpty ? "这一页还没有图标" : "没有匹配的图标"))
                                Text(state.showSelectedOnly ? "关闭‘只看已选’继续勾选，或清除搜索条件。" : (state.query.isEmpty ? "在其他页勾选图标，再将目标页设为这一页。" : "换一个名称，或查看全部页面。"))
                                    .font(.callout).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).padding(.top, 70)
                        } else {
                            LazyVStack(spacing: 24) {
                                ForEach(state.previewPages(model: model), id: \.self) { page in
                                    PagePreview(model: model, state: state, page: page, width: max(200, area.size.width - 16))
                                }
                            }.padding(.trailing, 16).padding(.bottom, 8)
                        }
                      }
                      .id("\(state.scopeID)|\(state.sourcePage)|\(state.query)|\(state.showSelectedOnly)")
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 10) {
                let paths = state.selectedAppPaths(model: model)
                Text("应用操作").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Button("启动所选 \(paths.count) 个") { model.performAppBatch?(.launch, paths) }.disabled(paths.isEmpty)
                Button("退出所选 \(paths.count) 个") { model.performAppBatch?(.quit, paths) }.disabled(paths.isEmpty)
                Button("创建桌面工作组…") { model.showAppGroups?(paths) }.disabled(paths.isEmpty)
                Spacer()
                Button("桌面工作组…") { model.showAppGroups?(nil) }
            }.padding(.horizontal, 4)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        Picker("目标页", selection: Binding(get: { state.destinationPage }, set: { state.destinationPage = $0; state.feedback = "" })) {
                            ForEach(pages, id: \.self) { page in Text("\(model.layout.pageTitle(page, folderID: state.folderID)) · \(counts[page] ?? 0) / \(model.capacity) 项").tag(page) }
                        }.frame(width: 275).accessibilityLabel("批量移动目标页")
                        Button { state.promptPageName(state.destinationPage, model: model) } label: { Image(systemName: "pencil") }
                            .disabled(model.layout.layoutLocked).help("命名目标页").accessibilityLabel("命名目标页")
                        Text("可放 \(state.availableCount(model: model)) 项").font(.callout).foregroundStyle(.secondary)
                    }
                    if !state.feedback.isEmpty {
                        Text(state.feedback).font(.callout).foregroundStyle(state.feedbackIsError ? Color.red : Color.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if state.incomingCount(model: model) > state.availableCount(model: model) {
                        Text("需要放入 \(state.incomingCount(model: model)) 项，空位不足。请减少选择或新建空白页。")
                            .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    } else {
                        let outside = state.selectedOutsideList(model: model)
                        Text(state.selectedIDs.isEmpty ? "选择可跨多个来源页保留；目标页已有图标保留位置。" : (outside > 0 ? "有 \(outside) 项在当前列表之外；可用‘只看已选’核对，将一起移动。" : "将移动 \(state.incomingCount(model: model)) 项，其余所选图标已在目标页。"))
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        if let plan = state.undoPlan { Button(plan.title) { state.undo(model: model) }.disabled(model.layout.layoutLocked) }
                        Button("移动 \(state.incomingCount(model: model)) 项") { state.move(model: model) }
                            .buttonStyle(.borderedProminent).disabled(!state.canMove(model: model))
                            .accessibilityLabel("批量移动所选图标")
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                    Button("在启动台查看") {
                        model.showManagedPage?(state.folderID, state.sourcePage < 0 ? state.destinationPage : state.sourcePage)
                    }.buttonStyle(.link)
                }
            }
            .padding(14).launcherGlass(radius: 20)
        }
        .padding(20).frame(minWidth: 920, minHeight: 620)
        .overlay {
            GeometryReader { area in
                if let tile = state.previewDragTile, let point = state.previewDragPoint {
                    Group {
                        if tile.isFolder { Image(systemName: "folder.fill").resizable().scaledToFit().foregroundStyle(.blue) }
                        else if let path = tile.apps.first { Image(nsImage: model.icon(path)).resizable().scaledToFit() }
                    }.frame(width: state.previewDragIconSize, height: state.previewDragIconSize)
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 5)
                        .position(x: point.x, y: area.size.height - point.y)
                }
            }.allowsHitTesting(false)
        }
        .onDisappear { state.cancelPreviewDrag() }
        .sheet(isPresented: $state.groupingPresented) { BatchGroupingView(model: model, state: state) }
        .onAppear { searchFocused = true }
        .onChange(of: state.focusSearchGeneration) { _ in searchFocused = true }
        .onChange(of: state.showSelectedOnly) { selectedOnly in
            if selectedOnly { state.query = ""; state.feedback = "" }
        }
        .onChange(of: model.layout) { _ in state.reconcile(model: model) }
    }
    func sourceButton(_ title: String, page: Int, count: Int) -> some View {
        Button { state.sourcePage = page; state.showSelectedOnly = false; state.feedback = "" } label: {
            HStack {
                Image(systemName: page < 0 ? "square.stack.3d.up" : "rectangle.on.rectangle").frame(width: 19)
                Text(title).lineLimit(2).help(title)
                Spacer()
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).padding(.vertical, 12).contentShape(Rectangle())
                .background(!state.showSelectedOnly && state.sourcePage == page ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel("显示\(title)，\(count) 项")
        .contextMenu {
            if page >= 0 { Button("命名这一页…") { state.promptPageName(page, model: model) }.disabled(model.layout.layoutLocked) }
        }
    }
}
