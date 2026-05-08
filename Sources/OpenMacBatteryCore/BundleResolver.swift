import Foundation
import AppKit

public struct ProcessKey: Hashable {
    public let pid: pid_t
    public let startTvSec: UInt64
}

public struct ProcessMetadata {
    public let bundleId: String?
    public let displayName: String?
    public let execPath: String?
}

public final class BundleResolver {
    private var cache: [ProcessKey: ProcessMetadata] = [:]

    public init() {}

    public func resolve(pid: pid_t, startTvSec: UInt64) -> ProcessMetadata {
        let key = ProcessKey(pid: pid, startTvSec: startTvSec)
        if let hit = cache[key] { return hit }

        var bundleId: String? = nil
        var displayName: String? = nil

        if let app = NSRunningApplication(processIdentifier: pid) {
            bundleId = app.bundleIdentifier
            displayName = app.localizedName
        }

        let path = ProcessInfoReader.execPath(pid: pid)

        // Helper / XPC pattern'ini parent app'e map et
        if bundleId == nil, let p = path {
            if let parent = parentBundleId(fromPath: p) {
                bundleId = parent
            }
            if displayName == nil {
                displayName = (p as NSString).lastPathComponent
            }
        }
        if displayName == nil, let p = path {
            displayName = (p as NSString).lastPathComponent
        }

        let meta = ProcessMetadata(bundleId: bundleId, displayName: displayName, execPath: path)
        cache[key] = meta
        return meta
    }

    public func invalidate(pid: pid_t, startTvSec: UInt64) {
        cache.removeValue(forKey: ProcessKey(pid: pid, startTvSec: startTvSec))
    }

    public func evictAll(except keys: Set<ProcessKey>) {
        for k in cache.keys where !keys.contains(k) {
            cache.removeValue(forKey: k)
        }
    }

    /// /Applications/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper
    /// gibi yollardan parent .app'in Info.plist'ini okuyup CFBundleIdentifier'ı çek.
    private func parentBundleId(fromPath path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // En dıştaki .app'i bul (helper/XPC değil, parent)
        var indices: [Int] = []
        for (i, p) in parts.enumerated() where p.hasSuffix(".app") {
            indices.append(i)
        }
        guard let outermost = indices.first else { return nil }
        let upTo = parts.prefix(outermost + 1).joined(separator: "/")
        let plistPath = upTo + "/Contents/Info.plist"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }
}
