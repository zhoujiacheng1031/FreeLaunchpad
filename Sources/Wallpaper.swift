import AppKit
import CoreGraphics

/// Read wallpaper files and configuration only; never capture desktop pixels.
enum WallpaperResolver {
    static func candidates(primary: URL?, displayUUID: String?, store: Data?) -> [URL] {
        var urls = primary.map { [$0] } ?? []
        guard let store, let root = (try? PropertyListSerialization.propertyList(from: store, format: nil)) as? [String: Any] else { return urls }
        var settings: [[String: Any]] = []
        if let displayUUID, let displays = root["Displays"] as? [String: Any], let display = displays[displayUUID] as? [String: Any] { settings.append(display) }
        if let all = root["AllSpacesAndDisplays"] as? [String: Any] { settings.append(all) }
        if let defaults = root["SystemDefault"] as? [String: Any] { settings.append(defaults) }
        func collect(_ value: Any) {
            if let text = value as? String, let url = URL(string: text), url.isFileURL {
                if !urls.contains(url) { urls.append(url) }
            } else if let data = value as? Data,
                      let decoded = try? PropertyListSerialization.propertyList(from: data, format: nil) { collect(decoded) }
            else if let dictionary = value as? [String: Any] { for key in dictionary.keys.sorted() { collect(dictionary[key]!) } }
            else if let array = value as? [Any] { for entry in array { collect(entry) } }
        }
        for setting in settings {
            guard let desktop = setting["Desktop"] as? [String: Any],
                  let content = desktop["Content"] as? [String: Any],
                  let choices = content["Choices"] as? [[String: Any]] else { continue }
            for choice in choices { if let configuration = choice["Configuration"] { collect(configuration) } }
        }
        return urls
    }
    @MainActor static func load(for screen: NSScreen?) -> (url: URL?, image: NSImage?) {
        let primary = screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        var uuid: String?
        if let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let displayUUID = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            uuid = CFUUIDCreateString(nil, displayUUID) as String
        }
        let storeURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        // Prefer the public API; the configuration is a fallback for a missing or stale URL.
        if let primary, let image = NSImage(contentsOf: primary) { return (primary, image) }
        let urls = candidates(primary: primary, displayUUID: uuid, store: try? Data(contentsOf: storeURL))
        for url in urls {
            if let image = NSImage(contentsOf: url) { return (url, image) }
        }
        return (primary, nil)
    }
}
