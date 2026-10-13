import AppKit
import SwiftUI

enum LauncherDropTarget {
    case tile(Tile, TileDropGeometry)
    case grid(LauncherGridGeometry)
    case page(Int, navigationID: String?, repeatDelta: Int?)
}

struct LauncherDragSurface: NSViewRepresentable {
    let model: AppModel
    let target: LauncherDropTarget
    var source: Tile? = nil
    func makeNSView(context: Context) -> LauncherDragView {
        let view = LauncherDragView()
        view.model = model; view.target = target; view.source = source
        model.dragViews.add(view)
        return view
    }
    func updateNSView(_ view: LauncherDragView, context: Context) {
        view.model = model; view.target = target; view.source = source
    }
}

/// In-app movement tracks window mouse events. The page canvas remains the destination
/// throughout the gesture, even after the original tile view leaves the visible page.
@MainActor final class LauncherDragView: NSView {
    weak var model: AppModel?
    var target: LauncherDropTarget?
    var source: Tile?
    private var mouseDownPoint: CGPoint?
    private var exceededClickThreshold = false
    private var pointerDrag: LauncherPointerDrag?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard source != nil || model?.draggedID != nil else { return nil }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) { mouseDownPoint = convert(event.locationInWindow, from: nil); exceededClickThreshold = false }
    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil; exceededClickThreshold = false }
        if pointerDrag == nil, !exceededClickThreshold, let source { model?.activate(source) }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let model, let source else { return }
        NSMenu.popUpContextMenu(LauncherTileMenu.menu(model: model, tile: source), with: event, for: self)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let position = convert(event.locationInWindow, from: nil)
        guard hypot(position.x - start.x, position.y - start.y) > 4 else { return }
        exceededClickThreshold = true
        guard pointerDrag == nil, let source, let model, model.canArrange, let window else { return }
        let token = model.beginDrag(source.id)
        model.activeDragSource = self
        let size: CGFloat
        if case let .tile(_, geometry) = target { size = geometry.iconSize } else { size = 88 }
        let image: NSImage
        if source.isFolder {
            image = NSImage(size: NSSize(width: size, height: size))
            image.lockFocus()
            NSColor(white: 0.3, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: size * 0.2, yRadius: size * 0.2).fill()
            for (index, path) in source.apps.prefix(9).enumerated() {
                let edge = (size - 24) / 3
                model.icon(path).draw(in: NSRect(x: 8 + CGFloat(index % 3) * (edge + 4), y: size - 8 - CGFloat(index / 3 + 1) * (edge + 4), width: edge, height: edge))
            }
            image.unlockFocus()
        } else { image = model.icon(source.apps[0]) }
        model.dragImage = image; model.dragImageSize = size
        let drag = LauncherPointerDrag(model: model, window: window, token: token)
        pointerDrag = drag
        model.cancelPointerDrag = { [weak self, weak drag] in
            drag?.stop(); self?.pointerDrag = nil; self?.mouseDownPoint = nil
        }
        drag.start(at: event.locationInWindow)
    }
    func containsWindowPoint(_ point: CGPoint, in window: NSWindow) -> Bool {
        self.window === window && !isHiddenOrHasHiddenAncestor && bounds.contains(convert(point, from: nil))
    }
    func destination(at point: CGPoint) -> (slot: Int, group: Bool)? {
        guard let model, case let .grid(geometry) = target else { return nil }
        let local = convert(point, from: nil)
        guard let cell = geometry.cell(at: local) else { return nil }
        let center = geometry.center(of: cell)
        let facePoint = CGPoint(x: local.x - center.x + geometry.cellWidth / 2, y: local.y - center.y + geometry.cellHeight / 2)
        let face = TileDropGeometry(cellWidth: geometry.cellWidth, cellHeight: geometry.cellHeight, iconSize: geometry.iconSize(requested: model.layout.iconSize))
        return (model.page * model.capacity + cell, face.groups(at: facePoint))
    }
}

@MainActor private final class LauncherPointerDrag {
    weak var model: AppModel?
    weak var window: NSWindow?
    let token: String
    private var monitor: Any?
    init(model: AppModel, window: NSWindow, token: String) { self.model = model; self.window = window; self.token = token }
    func start(at point: CGPoint) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self, let model = self.model else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { model.finishDrag(); return nil }
                return event
            }
            if event.type == .leftMouseUp { self.release(at: event.locationInWindow); return nil }
            self.update(at: event.locationInWindow)
            return nil
        }
        update(at: point)
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
    private func surfaces(at point: CGPoint) -> [LauncherDragView] {
        guard let model, let window else { return [] }
        return model.dragViews.allObjects.compactMap { $0 as? LauncherDragView }.filter { $0.containsWindowPoint(point, in: window) }
    }
    private func update(at point: CGPoint) {
        guard let model else { return }
        guard model.acceptsDrag(token) else { model.finishDrag(); return }
        model.dragWindowPoint = point
        let surfaces = surfaces(at: point)
        for view in surfaces {
            if case let .page(page, id, delta) = view.target, let id, page >= 0, page < model.pageCount {
                model.hoverNavigation(id, target: page, repeatDelta: delta); return
            }
        }
        if let view = surfaces.first(where: { if case .grid = $0.target { return true }; return false }), let destination = view.destination(at: point) {
            model.hoverSlot(destination.slot, group: destination.group)
        } else {
            if let id = model.dragNavigationID { model.leaveNavigation(id) }
            model.dropSlot = nil; model.dropTargetID = nil; model.dropWillGroup = false
        }
    }
    private func release(at point: CGPoint) {
        guard let model else { stop(); return }
        guard model.acceptsDrag(token) else { model.finishDrag(); return }
        let surfaces = surfaces(at: point)
        for view in surfaces {
            if case let .page(page, _, delta) = view.target, page >= 0, page < model.pageCount {
                model.dropPage(token: token, target: delta == nil ? page : model.page); return
            }
        }
        if let view = surfaces.first(where: { if case .grid = $0.target { return true }; return false }), let destination = view.destination(at: point) {
            model.dropSlot(token: token, slot: destination.slot, group: destination.group)
        } else { model.finishDrag() }
    }
}
