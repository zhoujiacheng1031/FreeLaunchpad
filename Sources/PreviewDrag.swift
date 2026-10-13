import AppKit
import SwiftUI

struct PreviewDragSurface: NSViewRepresentable {
    let model: AppModel
    let state: PageManagerState
    let page: Int
    var geometry: LauncherGridGeometry?
    var scale: CGFloat = 1
    var source: Tile?
    var iconSize: CGFloat = 48
    func makeNSView(context: Context) -> PreviewDragView {
        let view = PreviewDragView()
        updateNSView(view, context: context); state.previewDragViews.add(view)
        return view
    }
    func updateNSView(_ view: PreviewDragView, context: Context) {
        view.model = model; view.state = state; view.page = page; view.geometry = geometry
        view.scale = scale; view.source = source; view.iconSize = iconSize
    }
}

/// Uses the same window-coordinate tracking as the launcher, with selection instead of launching.
@MainActor final class PreviewDragView: NSView {
    weak var model: AppModel?
    weak var state: PageManagerState?
    var page = 0
    var geometry: LauncherGridGeometry?
    var scale: CGFloat = 1
    var source: Tile?
    var iconSize: CGFloat = 48
    private var startPoint: CGPoint?
    private var exceededThreshold = false
    private var monitor: Any?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { source == nil ? nil : super.hitTest(point) }
    override func mouseDown(with event: NSEvent) { startPoint = event.locationInWindow; exceededThreshold = false }
    override func mouseUp(with event: NSEvent) {
        if !exceededThreshold, let source, let state { state.toggle(source.id, selected: !state.selectedIDs.contains(source.id)) }
        startPoint = nil; exceededThreshold = false
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let source, source.isFolder else { return }
        let menu = NSMenu()
        let item = NSMenuItem(title: "管理文件夹内页面", action: #selector(openFolder), keyEquivalent: "")
        item.target = self; menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func openFolder() { if let source, let state, let model { state.changeScope(source.id, model: model) } }
    override func mouseDragged(with event: NSEvent) {
        guard let startPoint, hypot(event.locationInWindow.x - startPoint.x, event.locationInWindow.y - startPoint.y) > 4 else { return }
        exceededThreshold = true
        guard monitor == nil, let model, let state, let source, let window,
              let token = state.beginPreviewDrag(source.id, model: model) else { return }
        state.previewDragTile = source; state.previewDragIconSize = iconSize
        // Retain the source view until release, even when a redraw replaces its SwiftUI cell.
        state.cancelPreviewPointer = { [self] in stop() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self, weak window] event in
            guard let self, let window, let model = self.model, let state = self.state else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { state.cancelPreviewDrag(); return nil }
                return event
            }
            if event.type == .leftMouseUp {
                if let destination = self.destination(event.locationInWindow, window: window) {
                    state.dropPreview(token, on: destination.page, cell: destination.cell, model: model)
                }
                state.cancelPreviewDrag(); return nil
            }
            self.update(event.locationInWindow, window: window)
            return nil
        }
        update(event.locationInWindow, window: window)
    }
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        startPoint = nil; exceededThreshold = false
    }
    private func destination(_ point: CGPoint, window: NSWindow) -> (page: Int, cell: Int)? {
        guard let state else { return nil }
        for view in state.previewDragViews.allObjects.compactMap({ $0 as? PreviewDragView }) {
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor, let grid = view.geometry else { continue }
            let local = view.convert(point, from: nil)
            guard view.bounds.contains(local), let cell = grid.cell(at: CGPoint(x: local.x / view.scale, y: local.y / view.scale)) else { continue }
            return (view.page, cell)
        }
        return nil
    }
    private func update(_ point: CGPoint, window: NSWindow) {
        guard let state else { return }
        state.previewDragPoint = point
        let destination = destination(point, window: window)
        state.previewHoverPage = destination?.page; state.previewHoverCell = destination?.cell
    }
}
