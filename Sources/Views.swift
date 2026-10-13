import SwiftUI
import AppKit
import ServiceManagement

struct LauncherView: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let insets = model.contentInsets
            let width = max(360, geometry.size.width - insets.leading - insets.trailing)
            let height = max(320, geometry.size.height - insets.top - insets.bottom)
            ZStack {
                backdrop.contentShape(Rectangle()).onTapGesture { model.escape() }
                VStack(spacing: 0) {
                    searchBar.frame(width: min(630, width - 72))
                        .padding(.top, height < 700 ? 24 : 40)
                    HStack(spacing: 8) {
                        if let folder = model.folder, model.query.isEmpty {
                            Button { model.folderID = nil; model.extraPage = nil; model.page = 0 } label: {
                                Image(systemName: "chevron.left").fontWeight(.semibold)
                                    .frame(width: 28, height: 28)
                            }.buttonStyle(.plain).accessibilityLabel("返回所有应用")
                            Text(folder.name).fontWeight(.semibold)
                        } else { Text(model.query.isEmpty ? "所有应用" : "搜索结果") }
                        Text("\(model.displayedTiles.count)").monospacedDigit().opacity(0.6)
                        if model.scanning { ProgressView().controlSize(.small) }
                    }
                    .frame(height: LauncherCanvasMetrics.contextHeight)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(.black.opacity(0.18), in: Capsule())
                    .padding(.top, 12).padding(.bottom, 12)

                    GeometryReader { area in
                        let grid = LauncherGridGeometry(size: CGSize(width: LauncherGridGeometry.width(for: width), height: area.size.height), layout: model.layout)
                        let iconSize = grid.iconSize(requested: model.layout.iconSize)
                        ZStack(alignment: .topLeading) {
                            if model.pageTiles.isEmpty {
                                emptyPageContent.padding(24)
                                    .frame(width: min(390, grid.size.width - 40))
                                    .launcherGlass(radius: 24)
                                    .position(x: grid.size.width / 2, y: grid.size.height / 2)
                                    .allowsHitTesting(model.draggedID == nil)
                            }
                            if let slot = model.dropSlot, slot / model.capacity == model.page, !model.dropWillGroup {
                                let center = grid.center(of: slot % model.capacity)
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .fill(.white.opacity(0.07))
                                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
                                    .frame(width: min(grid.cellWidth - 12, iconSize + 60), height: min(grid.cellHeight - 12, iconSize + 66))
                                    .position(center)
                            }
                            ForEach(model.pageTiles) { tile in
                                let cell = (model.slot(of: tile.id) ?? 0) % model.capacity
                                tileView(tile, iconSize: iconSize, labelWidth: grid.cellWidth - 18, cellHeight: grid.cellHeight, cellWidth: grid.cellWidth)
                                    .position(grid.center(of: cell))
                            }
                        }
                        .frame(width: grid.size.width, height: grid.size.height)
                        // This destination stays alive during page changes, including on empty pages.
                        .overlay(LauncherDragSurface(model: model, target: .grid(grid)))
                        .frame(width: area.size.width, height: area.size.height)
                    }
                    .padding(.bottom, 12)
                    pageNavigation.padding(.bottom, 15)
                    HStack(spacing: 5) {
                        Text("⌃").fontWeight(.medium)
                        Text("⌥").fontWeight(.medium)
                        Text(model.draggedID == nil ? (model.layout.layoutLocked ? "空格打开 · Esc 返回 · 布局已锁定" : "空格打开 · Esc 返回") : "拖到空位自由摆放 · 图标中心建组 · 边缘翻页")
                    }.font(.system(size: 11)).frame(height: LauncherCanvasMetrics.hintHeight).foregroundStyle(.white.opacity(0.48)).padding(.bottom, 20)
                }
                .padding(EdgeInsets(top: insets.top, leading: insets.leading, bottom: insets.bottom, trailing: insets.trailing))
            }
            .overlay(alignment: .topLeading) {
                if let point = model.dragWindowPoint, let image = model.dragImage {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: model.dragImageSize, height: model.dragImageSize)
                        .scaleEffect(1.06).shadow(color: .black.opacity(0.28), radius: 14, y: 8)
                        .position(x: point.x, y: geometry.size.height - point.y)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .leading) { dragEdge(delta: -1) }
            .overlay(alignment: .trailing) { dragEdge(delta: 1) }
            .foregroundStyle(.white).preferredColorScheme(.dark)
            .animation(reduceMotion || model.draggedID != nil ? nil : .easeInOut(duration: 0.2), value: model.page)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.folderID)
            .onAppear { searchFocused = true }
            .onChange(of: model.showGeneration) { _ in
                searchFocused = false
                DispatchQueue.main.async { searchFocused = true }
            }
            .onChange(of: model.query) { _ in model.page = 0; model.extraPage = nil; model.selectedPath = nil }
            .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("好", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
    func dragEdge(delta: Int) -> some View {
        let target = model.page + delta
        let valid = target >= 0 && target < model.pageCount
        let id = "edge-\(delta)"
        return ZStack {
            Color.white.opacity(model.dragNavigationID == id ? 0.12 : 0.001)
            if model.draggedID != nil && valid {
                Image(systemName: delta < 0 ? "chevron.left" : "chevron.right")
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: 44).contentShape(Rectangle())
        .overlay(LauncherDragSurface(model: model, target: .page(target, navigationID: id, repeatDelta: delta)))
        .allowsHitTesting(model.draggedID != nil && valid)
    }
    var searchBar: some View {
        LauncherGlassGroup {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).opacity(0.7)
                    TextField("", text: $model.query, prompt: Text("搜索应用").foregroundColor(.white.opacity(0.65))).font(.system(size: 16))
                        .textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("搜索应用")
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").opacity(0.65) }
                            .buttonStyle(.plain).accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 20).frame(height: 50)
                .launcherGlass(radius: 25)
                Button { model.showPageManager?() } label: {
                    Image(systemName: "square.grid.3x3.square").font(.system(size: 19, weight: .medium))
                        .frame(width: 50, height: 50).launcherGlass(radius: 25, interactive: true)
                }.buttonStyle(.plain).help("页面管理 ⌘L").accessibilityLabel("页面管理")
                Button { model.showAppGroups?(nil) } label: {
                    Image(systemName: "rectangle.3.group").font(.system(size: 19, weight: .medium))
                        .frame(width: 50, height: 50).launcherGlass(radius: 25, interactive: true)
                }.buttonStyle(.plain).help("桌面工作组 ⌘G").accessibilityLabel("桌面工作组")
                Button { model.setLayoutLocked(!model.layout.layoutLocked) } label: {
                    Image(systemName: model.layout.layoutLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: 17, weight: .medium)).frame(width: 44, height: 50)
                        .launcherGlass(radius: 25, interactive: true)
                }.buttonStyle(.plain).help(model.layout.layoutLocked ? "解除布局锁定" : "锁定布局，防止误拖动")
                    .accessibilityLabel(model.layout.layoutLocked ? "解除布局锁定" : "锁定布局")
                Button { model.showSettings?() } label: {
                    Image(systemName: "gearshape").font(.system(size: 19, weight: .medium))
                        .frame(width: 50, height: 50).launcherGlass(radius: 25, interactive: true)
                }.buttonStyle(.plain).help("设置 ⌘,").accessibilityLabel("设置")
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 18, y: 7)
    }
    var pageNavigation: some View {
        HStack(spacing: 4) {
            Button { model.movePage(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 32)
            }.disabled(model.page == 0).accessibilityLabel("上一页")
            ForEach(model.navigationPages, id: \.self) { page in
                Button { model.page = page; model.selectedPath = nil } label: {
                    Capsule().fill(.white.opacity(page == model.page ? 0.95 : 0.32))
                        .frame(width: page == model.page ? 18 : 6, height: 6)
                        .frame(width: 24, height: 32)
                }.accessibilityLabel(model.query.isEmpty ? model.layout.pageTitle(page, folderID: model.folderID) : "第 \(page + 1) 页")
                .help(model.query.isEmpty ? model.layout.pageTitle(page, folderID: model.folderID) : "第 \(page + 1) 页")
                .overlay(LauncherDragSurface(model: model, target: .page(page, navigationID: "page-\(page)", repeatDelta: nil)))
            }
            if model.canArrange {
                Button { model.addPage() } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 32)
                }.accessibilityLabel("添加空白页面")
            }
            Button { model.movePage(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 32)
            }.disabled(model.page >= model.pageCount - 1).accessibilityLabel("下一页")
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 14).padding(.horizontal, 8)
            Text(currentPageLabel).lineLimit(1).truncationMode(.middle)
                .font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.9)).padding(.trailing, 8)
                .accessibilityLabel("当前\(currentPageLabel)")
        }
        .buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 4)
        .launcherGlass(radius: 22, interactive: true)
    }
    var currentPageLabel: String {
        let number = "第 \(model.page + 1) / \(model.pageCount) 页"
        guard model.query.isEmpty, let name = model.layout.pageName(model.page, folderID: model.folderID) else { return number }
        return "\(name) · \(number)"
    }
    var backdrop: some View { LauncherBackdrop(model: model) }
    var emptyPageContent: some View {
        VStack(spacing: 12) {
            let searching = !model.query.isEmpty
            let discovering = model.scanning && model.displayedTiles.isEmpty
            Image(systemName: searching ? "magnifyingglass" : "square.grid.3x3")
                .font(.system(size: 32, weight: .light)).opacity(0.8).accessibilityHidden(true)
            Text(discovering ? "正在发现应用…" : (searching ? "没有匹配的应用" : "这一页还没有图标"))
                .font(.title3.weight(.semibold))
            Text(searching ? "试试应用名称、拼音或英文名。" : (model.layout.layoutLocked ? "布局已锁定，可在页面管理中解除锁定后安排图标。" : "从其他页面拖入图标，或在页面管理中批量安排。"))
                .font(.callout).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
            if !discovering {
                Button(searching ? "清除搜索" : "打开页面管理") {
                    if searching { model.query = "" } else { model.showPageManager?() }
                }.buttonStyle(.bordered)
            }
        }
    }
    func tileView(_ tile: Tile, iconSize: Double, labelWidth: Double, cellHeight: Double, cellWidth: Double) -> some View {
        Button { model.activate(tile) } label: { LauncherTileFace(model: model, tile: tile, iconSize: iconSize, labelWidth: labelWidth) }
        .buttonStyle(LauncherTileStyle()).accessibilityLabel(model.name(tile))
        .frame(width: cellWidth, height: cellHeight)
        .contentShape(Rectangle())
        .overlay(LauncherDragSurface(model: model, target: .tile(tile, TileDropGeometry(cellWidth: cellWidth, cellHeight: cellHeight, iconSize: iconSize)), source: tile))
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        TabView {
            Form {
                Section("网格") {
                    Toggle("锁定布局", isOn: Binding(get: { model.layout.layoutLocked }, set: { model.setLayoutLocked($0) }))
                    Text("锁定后仍可打开应用和搜索；拖动、建组、隐藏、页面命名和网格行列数暂不可修改。新安装的应用仍会自动加入。")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper("列数：\(model.layout.columns)", value: $model.layout.columns, in: 4...10)
                        .disabled(model.layout.layoutLocked)
                    Stepper("行数：\(model.layout.rows)", value: $model.layout.rows, in: 3...7)
                        .disabled(model.layout.layoutLocked)
                    HStack { Text("图标 \(Int(model.layout.iconSize)) pt"); Slider(value: $model.layout.iconSize, in: 40...128).accessibilityLabel("图标大小") }
                    HStack { Text("横向间距 \(Int((model.layout.horizontalSpacing * 100).rounded()))%"); Slider(value: $model.layout.horizontalSpacing, in: 0...1).accessibilityLabel("横向图标间距") }
                    HStack { Text("纵向间距 \(Int((model.layout.verticalSpacing * 100).rounded()))%"); Slider(value: $model.layout.verticalSpacing, in: 0...1).accessibilityLabel("纵向图标间距") }
                    HStack {
                        Text("0% 紧凑 · 100% 铺满可用区域；图标与名称始终保留间隙。").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("重置间距") { model.layout.horizontalSpacing = 1; model.layout.verticalSpacing = 1 }
                    }
                    Text("每页最多 \(model.capacity) 项；调整行列数会改变分页，图标大小不改变排列位置。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("页面管理…（批量安排图标）") { model.showPageManager?() }
                    Text("空位摆放 · 名称处交换 · 图标中心建组。停在页面圆点或屏幕边缘翻页。").font(.caption).foregroundStyle(.secondary)
                }
                Section("背景") {
                    Picker("背景来源", selection: $model.layout.backgroundMode) {
                        Text("当前桌面").tag("desktop")
                        Text("桌面壁纸").tag("wallpaper")
                        Text("自定义图片").tag("image")
                    }
                    if model.layout.backgroundMode == "image" { Button("选择图片…") { model.chooseBackground() } }
                    if model.layout.backgroundMode == "wallpaper" { Button("重新读取壁纸") { model.updateBackground(force: true) } }
                    HStack {
                        Text("不透明度 \(Int((model.layout.backgroundOpacity * 100).rounded()))%")
                        Slider(value: $model.layout.backgroundOpacity, in: 0...1).accessibilityLabel("背景不透明度")
                    }
                    Text("降低不透明度可看见后方桌面和窗口，图标与文字保持清晰。")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.layout.backgroundMode == "desktop" {
                        Text("当前桌面直接透出后方窗口。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack { Text("壁纸模糊"); Slider(value: $model.layout.backgroundBlur, in: 0...40) }
                        Text(model.backgroundStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Dock") {
                    Toggle("启动台打开时隐藏 Dock", isOn: $model.layout.hideDock)
                    Text(model.layout.hideDock ? "打开启动台时隐藏；退出启动台、打开应用或设置时恢复原状态。" : "沿用系统 Dock 显示设置；网格和分页自动避开底部或侧边 Dock。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("打开方式") {
                    Text("全局快捷键：Control + Option + 空格")
                    Picker("触发角", selection: $model.layout.hotCorner) {
                        Text("关闭").tag("none"); Text("左上角").tag("topLeft"); Text("右上角").tag("topRight")
                        Text("左下角").tag("bottomLeft"); Text("右下角").tag("bottomRight")
                    }
                    Toggle("登录时启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }))
                    if !model.loginMessage.isEmpty { Text(model.loginMessage).font(.caption) }
                }
            }.formStyle(.grouped).tabItem { Label("外观与启动", systemImage: "slider.horizontal.3") }
            Form {
                Section("应用来源") {
                    Text("自动扫描 /Applications、~/Applications 和系统应用。")
                    ForEach(model.layout.extraPaths, id: \.self) { path in
                        HStack {
                            Text(path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("移除") { model.layout.extraPaths.removeAll { $0 == path }; model.save(); model.refresh() }
                        }
                    }
                    HStack {
                        Button("添加目录…") { model.addPath() }
                        Button(model.scanning ? "扫描中…" : "重新扫描") { model.refresh() }.disabled(model.scanning)
                    }
                }
                Section("已隐藏应用 · \(model.layout.hidden.count)") {
                    if model.layout.hidden.isEmpty { Text("没有隐藏的应用").foregroundStyle(.secondary) }
                    ForEach(model.layout.hidden, id: \.self) { path in
                        HStack {
                            Text(model.record(path)?.name ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
                            Spacer(); Button("恢复显示") { model.unhide(path) }.disabled(model.layout.layoutLocked)
                        }
                    }
                }
            }.formStyle(.grouped).tabItem { Label("应用", systemImage: "square.grid.2x2") }
            Form {
                Section("布局备份") {
                    Text("备份包含图标位置、空位、文件夹、页面名称、锁定状态、桌面工作组、隐藏列表和外观设置。恢复前会自动保留当前布局；恢复备份会替换锁定状态。")
                    HStack { Button("导出备份…") { model.exportBackup() }; Button("恢复备份…") { model.importBackup() } }
                    if !model.backupStatus.isEmpty { Text(model.backupStatus).font(.caption).foregroundStyle(.secondary) }
                    Button("打开数据目录") { NSWorkspace.shared.open(model.stateURL.deletingLastPathComponent()) }
                }
                Section("FreeLaunchpad 1.8.1") {
                    Text("免费、开源、离线运行。独立实现的 macOS 应用启动器。")
                    Text("双指滚动翻页；四指全局捏合与旧 Launchpad 数据迁移暂未实现。").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("备份与关于", systemImage: "externaldrive") }
        }
        .padding(12).frame(width: 620, height: 600)
        .onChange(of: model.layout) { _ in model.page = min(model.page, model.pageCount - 1); model.save() }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("好", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
