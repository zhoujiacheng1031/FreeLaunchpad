import SwiftUI
import AppKit

struct LauncherGlass: ViewModifier {
    var radius: CGFloat
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            content.background(colorScheme == .dark ? Color(white: 0.16) : Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.14)))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
        }
    }
}

extension View {
    func launcherGlass(radius: CGFloat = 28, interactive: Bool = false) -> some View {
        modifier(LauncherGlass(radius: radius, interactive: interactive))
            .contentShape(.interaction, RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct LauncherGlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content() }
        } else { content() }
    }
}

struct LauncherTileStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

final class TileHoverState: ObservableObject {
    @Published var isHovering = false
}

struct LauncherTileFace: View {
    @ObservedObject var model: AppModel
    let tile: Tile
    let iconSize: CGFloat
    let labelWidth: CGFloat
    var isPreview = false
    @StateObject private var hover = TileHoverState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var highlighted: Bool { hover.isHovering || (!isPreview && (model.selectedPath == tile.id || model.dropTargetID == tile.id)) }
    var body: some View {
        VStack(spacing: isPreview ? 4 : (iconSize < 40 ? 6 : 9)) {
            if tile.isFolder {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: max(1, iconSize * 0.031)), count: 3), spacing: max(1, iconSize * 0.031)) {
                    ForEach(Array(tile.apps.prefix(9)), id: \.self) { path in
                        Image(nsImage: model.icon(path)).resizable().scaledToFit()
                    }
                }
                .padding(min(9, iconSize * 0.07)).frame(width: iconSize, height: iconSize)
                .launcherGlass(radius: iconSize * 0.24)
            } else if let path = tile.apps.first {
                Image(nsImage: model.icon(path)).resizable().scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 5)
            }
            Text(model.name(tile)).font(.system(size: isPreview ? 11 : 13, weight: .medium))
                .lineLimit(isPreview || iconSize < 40 ? 1 : 2).multilineTextAlignment(.center)
                .frame(width: labelWidth, height: isPreview ? 18 : (iconSize < 40 ? 20 : 34), alignment: .top)
                .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
        }
        .frame(width: labelWidth).padding(.top, isPreview ? 4 : (iconSize < 40 ? 8 : 12)).padding(.bottom, isPreview || iconSize < 40 ? 0 : 3)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.12)))
            }
        }
        .scaleEffect(hover.isHovering && !reduceMotion ? 1.035 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: highlighted)
        .onHover { hover.isHovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .overlay {
            if !isPreview && model.dropTargetID == tile.id {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(model.dropWillGroup ? Color.cyan : .white, lineWidth: 2)
                    .overlay(alignment: .top) {
                        Text(model.dropWillGroup ? (tile.isFolder ? "加入文件夹" : "创建文件夹") : "移到此处")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.7), in: Capsule()).offset(y: -12)
                    }
            }
        }
        .opacity(!isPreview && model.draggedID == tile.id ? 0.35 : 1)
    }
}
