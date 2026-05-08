import Foundation

/// LaunchAgent kurulum/kaldırma logic'i. Hem CLI hem GUI bunu kullanıyor.
public enum DaemonInstaller {
    public static let label = "com.openmacbattery"

    public static var plistPath: String {
        "\(NSHomeDirectory())/Library/LaunchAgents/\(label).plist"
    }

    public static var logPath: String {
        "\(NSHomeDirectory())/Library/Logs/openmacbattery.log"
    }
    public static var errorLogPath: String {
        "\(NSHomeDirectory())/Library/Logs/openmacbattery.error.log"
    }

    public enum InstallError: Error, CustomStringConvertible {
        case binaryNotFound(String)
        case writeFailed(String)
        case bootstrapFailed(Int32, String)
        public var description: String {
            switch self {
            case .binaryNotFound(let p): return "Binary not found: \(p)"
            case .writeFailed(let m): return "Could not write plist: \(m)"
            case .bootstrapFailed(let c, let m): return "launchctl bootstrap exit \(c): \(m)"
            }
        }
    }

    /// LaunchAgent kuruludur ve şu an çalışıyor mu?
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// Mevcut plist'in işaret ettiği binary yolu (yoksa nil).
    public static func installedBinaryPath() -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String], let first = args.first else {
            return nil
        }
        return first
    }

    /// Eski "BatTracker" sürümü kuruluysa söküp sil — sessizce migration.
    public static func cleanupLegacy() {
        let legacyLabels = ["com.murat.battracker", "com.murat.battracker.gui"]
        let uid = getuid()
        for label in legacyLabels {
            let plist = "\(NSHomeDirectory())/Library/LaunchAgents/\(label).plist"
            if FileManager.default.fileExists(atPath: plist) {
                _ = launchctl(["bootout", "gui/\(uid)", plist])
                try? FileManager.default.removeItem(atPath: plist)
                FileHandle.standardError.write(Data(
                    "Removed legacy LaunchAgent: \(plist)\n".utf8))
            }
        }
    }

    /// Plist'i yaz, launchctl bootstrap ile yükle. binaryPath: 'openmacbattery' CLI binary'si.
    public static func install(binaryPath: String) throws {
        cleanupLegacy()
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw InstallError.binaryNotFound(binaryPath)
        }
        let plistDir = "\(NSHomeDirectory())/Library/LaunchAgents"
        let logDir = "\(NSHomeDirectory())/Library/Logs"
        try? FileManager.default.createDirectory(atPath: plistDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)

        // Plist'i dictionary olarak inşa edip PropertyListSerialization ile yaz.
        // String enterpolasyonu yok → path'lerde özel karakter olsa bile XML kırılmaz.
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binaryPath, "daemon", "run"],
            "RunAtLoad": true,
            "KeepAlive": [
                "SuccessfulExit": false,
                "Crashed": true
            ] as [String: Any],
            "ThrottleInterval": 30,
            "StandardOutPath": logPath,
            "StandardErrorPath": errorLogPath,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10
        ]
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: dict, format: .xml, options: 0
            )
            try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistPath)
        } catch {
            throw InstallError.writeFailed("\(error)")
        }

        // Log dosyalarını 600 izinleriyle önceden yarat — launchd append modunda yazsın,
        // başkası okuyamasın (bu DB ile birlikte davranışsal profili sızdıran iki yer).
        for path in [logPath, errorLogPath] {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            } else {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }

        // Önceki yükleme varsa söküp yeniden yükle (binary path değişmiş olabilir)
        let uid = getuid()
        let domain = "gui/\(uid)"
        _ = launchctl(["bootout", domain, plistPath])
        let (exit, err) = launchctl(["bootstrap", domain, plistPath])
        if exit != 0 {
            throw InstallError.bootstrapFailed(exit, err)
        }
    }

    public static func uninstall() {
        let uid = getuid()
        _ = launchctl(["bootout", "gui/\(uid)", plistPath])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    /// LaunchAgent çalışıyor mu? (kurulu + bir pid'i var mı)
    public static func isRunning() -> Bool {
        guard isInstalled else { return false }
        let uid = getuid()
        let (_, out) = launchctl(["print", "gui/\(uid)/\(label)"])
        return out.contains("state = running") || out.contains("pid = ")
    }

    @discardableResult
    public static func launchctl(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return (-1, "\(error)") }
        p.waitUntilExit()
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, stdout + stderr)
    }
}
