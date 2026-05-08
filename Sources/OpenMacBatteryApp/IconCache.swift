import AppKit

@MainActor
final class IconCache: ObservableObject {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]
    private let genericApp: NSImage = NSWorkspace.shared.icon(for: .application)

    func icon(forAppPath path: String?) -> NSImage {
        guard let path else { return genericApp }
        if let hit = cache[path] { return hit }
        let img: NSImage
        if FileManager.default.fileExists(atPath: path) {
            img = NSWorkspace.shared.icon(forFile: path)
        } else {
            img = genericApp
        }
        // Sidebar boyutuna küçült (perf)
        img.size = NSSize(width: 32, height: 32)
        cache[path] = img
        return img
    }
}
