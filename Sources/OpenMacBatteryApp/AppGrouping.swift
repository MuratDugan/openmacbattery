import Foundation
import AppKit
import SwiftUI
import OpenMacBatteryCore

/// Helper / XPC process'leri parent .app'e katlayan ve sistem servislerini sınıflandıran model.
struct GroupedApp: Identifiable, Hashable {
    let id: String                    // grup anahtarı (parent bundle id veya parent app path)
    let displayName: String
    let bundleId: String?
    let parentAppPath: String?        // /Applications/Foo.app — icon için
    let memberKeys: [String]          // SQL'e geçecek group keys (helper'lar dahil)
    let energyRaw: Int64
    let cpuNs: Int64
    let wakeups: Int64
    let isSystem: Bool                // sistem servisi mi
    let level: EnergyLevel            // toplam içindeki paya göre
    let sharePercent: Double          // % of user-app total energy (0..100), grouping zamanında dondurulmuş

    static func == (lhs: GroupedApp, rhs: GroupedApp) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum EnergyLevel: String {
    case high = "High"
    case medium = "Medium"
    case low = "Low"
    case minimal = "Minimal"

    var color: NSColor {
        switch self {
        case .high: return .systemRed
        case .medium: return .systemOrange
        case .low: return .systemBlue
        case .minimal: return .secondaryLabelColor
        }
    }

    static func classify(fraction: Double) -> EnergyLevel {
        if fraction >= 0.15 { return .high }
        if fraction >= 0.05 { return .medium }
        if fraction >= 0.01 { return .low }
        return .minimal
    }
}

enum AppGrouping {
    /// `TopRow`'ları parent .app'e göre gruplandır, sistem/kullanıcı ayır, seviye hesapla.
    static func group(_ rows: [TopRow]) -> [GroupedApp] {
        // 1. Her satır için parent bilgisi çıkar
        struct Pre {
            let parentAppPath: String?
            let parentBundleId: String?
            let displayName: String
            let groupKey: String
            let row: TopRow
        }

        let pres: [Pre] = rows.map { row in
            let pAppPath = parentAppPath(execPath: row.execPath)
            let pBundle = pAppPath.flatMap { readBundleId(at: $0) }
            // Display: parent .app varsa onun adı, yoksa orijinal
            let dn: String = {
                if let p = pAppPath {
                    return ((p as NSString).lastPathComponent as NSString).deletingPathExtension
                }
                return row.displayName
            }()
            return Pre(
                parentAppPath: pAppPath,
                parentBundleId: pBundle ?? row.bundleId,
                displayName: dn,
                groupKey: row.groupKey,
                row: row
            )
        }

        // 2. Aynı parent bundle id (veya parent app path) altındaki helper'ları topla
        var buckets: [String: (
            parentAppPath: String?,
            parentBundleId: String?,
            displayName: String,
            members: [TopRow],
            memberKeys: [String]
        )] = [:]

        for p in pres {
            let bucketKey = p.parentBundleId ?? p.parentAppPath ?? p.row.groupKey
            if var existing = buckets[bucketKey] {
                existing.members.append(p.row)
                existing.memberKeys.append(p.groupKey)
                // Daha "anlamlı" display name'i tut (parent .app adı varsa)
                if existing.parentAppPath == nil, p.parentAppPath != nil {
                    existing.parentAppPath = p.parentAppPath
                    existing.displayName = p.displayName
                }
                buckets[bucketKey] = existing
            } else {
                buckets[bucketKey] = (
                    parentAppPath: p.parentAppPath,
                    parentBundleId: p.parentBundleId,
                    displayName: p.displayName,
                    members: [p.row],
                    memberKeys: [p.groupKey]
                )
            }
        }

        // 3. Toplam enerji (sistem+kullanıcı) — seviye hesabı için sadece kullanıcı toplamı kullanılacak
        let userTotal = buckets.values.reduce(Int64(0)) { acc, b in
            let isSys = isSystemBucket(parentAppPath: b.parentAppPath, parentBundleId: b.parentBundleId, members: b.members)
            let energy = b.members.reduce(Int64(0)) { $0 + max($1.energyRaw, 0) }
            return isSys ? acc : acc + energy
        }

        // 4. GroupedApp listesi
        let groups: [GroupedApp] = buckets.map { (key, b) in
            let totalEnergy = b.members.reduce(Int64(0)) { $0 + max($1.energyRaw, 0) }
            let totalCpu = b.members.reduce(Int64(0)) { $0 + $1.cpuNs }
            let totalWk = b.members.reduce(Int64(0)) { $0 + $1.wakeups }
            let isSys = isSystemBucket(parentAppPath: b.parentAppPath, parentBundleId: b.parentBundleId, members: b.members)
            let frac = userTotal > 0 ? Double(totalEnergy) / Double(userTotal) : 0
            return GroupedApp(
                id: key,
                displayName: b.displayName,
                bundleId: b.parentBundleId,
                parentAppPath: b.parentAppPath,
                memberKeys: b.memberKeys,
                energyRaw: totalEnergy,
                cpuNs: totalCpu,
                wakeups: totalWk,
                isSystem: isSys,
                level: EnergyLevel.classify(fraction: frac),
                sharePercent: frac * 100.0
            )
        }
        return groups.sorted { $0.energyRaw > $1.energyRaw }
    }

    /// /Applications/Slack.app/Contents/MacOS/... → /Applications/Slack.app
    /// Helper'lar için en dıştaki .app'i (yani parent uygulamayı) döndür.
    static func parentAppPath(execPath: String?) -> String? {
        guard let path = execPath else { return nil }
        let comps = path.components(separatedBy: "/")
        for (i, c) in comps.enumerated() where c.hasSuffix(".app") {
            // En dıştaki .app — ilk bulunan parent
            return "/" + comps.prefix(i + 1).filter { !$0.isEmpty }.joined(separator: "/")
        }
        return nil
    }

    /// Parent .app'in Info.plist'inden CFBundleIdentifier oku
    static func readBundleId(at appPath: String) -> String? {
        let plistPath = appPath + "/Contents/Info.plist"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }

    /// Sistem servisi tespiti.
    /// Kural: parent bir .app değilse VE exec path /System/, /usr/, /sbin/ vb. altındaysa → sistem.
    /// Ya da bundle_id com.apple.* ile başlıyor ve /Applications altında değilse → sistem.
    static func isSystemBucket(parentAppPath: String?, parentBundleId: String?, members: [TopRow]) -> Bool {
        // Kullanıcı app'i: parent .app /Applications/ veya /System/Applications/ altında
        if let p = parentAppPath {
            if p.hasPrefix("/Applications/") || p.contains("/Applications/") && !p.hasPrefix("/System/Library/") {
                return false
            }
            if p.hasPrefix("/System/Applications/") {
                return false  // Mail, Music, Notes vb. — Apple ama kullanıcıya açık
            }
            if p.hasPrefix("/Users/") && p.contains("/Applications/") {
                return false  // ~/Applications altındaki user-installed
            }
        }

        // Daemon / system service patternları
        let systemPathPrefixes = [
            "/System/Library/",
            "/System/Volumes/Preboot/",
            "/System/Cryptexes/",
            "/usr/sbin/", "/usr/bin/", "/usr/libexec/",
            "/sbin/", "/bin/",
            "/Library/Apple/",
            "/Library/PrivilegedHelperTools/",
            "/Library/Developer/",
            "/private/var/"
        ]
        for m in members {
            guard let p = m.execPath else { continue }
            for pre in systemPathPrefixes where p.hasPrefix(pre) {
                return true
            }
        }
        // Bundle id com.apple.* ve dışarıda görünen bir .app değilse
        if let bid = parentBundleId, bid.hasPrefix("com.apple."), parentAppPath == nil {
            return true
        }
        // BatTracker'ı kullanıcı kalabalığından çıkar — kendisi gösterilmesin (varsayılan)
        if parentBundleId == "com.openmacbattery" || parentBundleId == "com.openmacbattery.gui" {
            return true
        }
        return false
    }
}
