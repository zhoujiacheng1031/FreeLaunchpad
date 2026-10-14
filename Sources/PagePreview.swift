import SwiftUI
import AppKit

struct PagePreview: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: PageManagerState
    let page: Int
    let width: CGFloat
    var canvasSize: CGSize {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let insets = LauncherInsets.resolve(frame: screen.frame, visibleFrame: screen.visibleFrame, hideDock: model.layout.hideDock)
        return LauncherCanvasMetrics.gridSize(screen: screen.frame.size, insets: insets)
    }
    var body: some View {
        let grid = LauncherGridGeometry(size: canvasSize, layout: model.layout)
        let scale = max(0.001, width / grid.size.width)
        let cells = state.previewTiles(on: page, model: model)
        let occupied = Set(state.positions(model: model).values.filter { $0 / model.capacity == page }.map { $0 % model.capacity })
        VStack(spacing: 10) {
            HStack {
                Text(model.layout.pageTitle(page, folderID: state.folderID)).font(.headline)
                Text("\(occupied.count) / \(model.capacity) 项").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { state.promptPageName(page, model: model) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).disabled(model.layout.layoutLocked).help("命名这一页").accessibilityLabel("命名第 \(page + 1) 页")
                Button("查看") { model.showManagedPage?(state.folderID, page) }.buttonStyle(.link)
                    .accessibilityLabel("在启动台查看第 \(page + 1) 页")
            }
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.12, green: 0.19, blue: 0.29), Color(red: 0.13, green: 0.15, blue: 0.24)], startPoint: .topLeading, endPoint: .bottomTrailing)
                LauncherBackdrop(model: model)
                if state.previewHoverPage == page, let cell = state.previewHoverCell {
                    let center = grid.center(of: cell)
                    RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2))
                        .frame(width: grid.cellWidth * scale - 4, height: grid.cellHeight * scale - 4)
                        .position(x: center.x * scale, y: center.y * scale)
                }
                ForEach(0..<model.capacity, id: \.self) { cell in
                    let center = grid.center(of: cell)
                    let cellWidth = grid.cellWidth * scale
                    let cellHeight = grid.cellHeight * scale
                    Group {
                        if let tile = cells[cell] {
                            tileButton(tile, cellWidth: cellWidth, cellHeight: cellHeight,
                                        iconSize: min(grid.iconSize(requested: model.layout.iconSize) * scale, max(14, cellHeight - 28), max(14, cellWidth - 18)))
                        } else {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.white.opacity(occupied.contains(cell) ? 0.035 : 0.14), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                                .frame(width: max(8, cellWidth - 8), height: max(8, cellHeight - 8))
                                .accessibilityHidden(true)
                        }
                    }.position(x: center.x * scale, y: center.y * scale)
                }
            }
            .frame(width: width, height: grid.size.height * scale)
            .contentShape(Rectangle())
            .overlay(PreviewDragSurface(model: model, state: state, page: page, geometry: grid, scale: scale))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.12)))
        }
    }
    func tileButton(_ tile: Tile, cellWidth: CGFloat, cellHeight: CGFloat, iconSize: CGFloat) -> some View {
        let selected = state.selectedIDs.contains(tile.id)
        return Button { state.toggle(tile.id, selected: !selected) } label: {
            LauncherTileFace(model: model, tile: tile, iconSize: iconSize, labelWidth: max(20, cellWidth - 10), isPreview: true)
                .frame(width: cellWidth, height: cellHeight)
                .contentShape(Rectangle())
                .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(selected ? Color.accentColor : .white.opacity(0.7))
                        .background(.black.opacity(0.35), in: Circle()).padding(5).accessibilityHidden(true)
                }
                .foregroundStyle(.white).environment(\.colorScheme, .dark)
        }.buttonStyle(.plain)
        .opacity(state.previewDragTile?.id == tile.id ? 0.35 : 1)
        .overlay(PreviewDragSurface(model: model, state: state, page: page, source: tile, iconSize: iconSize))
        .accessibilityLabel("\(selected ? "取消选择" : "选择")\(model.name(tile))，第 \(page + 1) 页")
        .help(model.layout.layoutLocked ? "\(model.name(tile)) · 点击勾选，解除锁定后可移动" : "\(model.name(tile)) · 点击勾选，拖到空位移动，拖到图标交换")
        .contextMenu {
            if tile.isFolder { Button("管理文件夹内页面") { state.changeScope(tile.id, model: model) } }
        }
    }
}
