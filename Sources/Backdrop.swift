import AppKit
import SwiftUI

struct LauncherBackdrop: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var opacity: Double { reduceTransparency ? 1 : model.layout.backgroundOpacity }
    var body: some View {
        GeometryReader { proxy in
            if model.layout.backgroundMode == "desktop" && !reduceTransparency {
                Color.black.opacity(opacity)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.14, green: 0.25, blue: 0.40), Color(red: 0.22, green: 0.23, blue: 0.39), Color(red: 0.09, green: 0.15, blue: 0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let image = model.backgroundImage {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                            .blur(radius: model.layout.backgroundBlur)
                        Color.black.opacity(0.16)
                    }
                }.opacity(opacity)
            }
        }.ignoresSafeArea()
    }
}
