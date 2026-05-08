import ArgumentParser
import Foundation
import OpenMacBatteryCore

struct DaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Manage background sampler daemon",
        subcommands: [Run.self, Install.self, Uninstall.self, Status.self]
    )

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run sampler in foreground (used by LaunchAgent)"
        )
        @Option(name: .long, help: "Sample interval in seconds")
        var interval: Double = 60.0

        func run() throws {
            let db = try openDatabase()
            var cfg = SamplerConfig.default
            cfg.interval = interval
            let sampler = Sampler(db: db, config: cfg)
            let watcher = SleepWatcher()

            FileHandle.standardError.write(Data("openmacbattery daemon: starting (interval=\(interval)s)\n".utf8))

            watcher.start { event in
                let ts = Int64(Date().timeIntervalSince1970)
                switch event {
                case .willSleep:
                    if let s = try? db.prepare("INSERT OR REPLACE INTO sleep_periods(sleep_start, sleep_end) VALUES(?, NULL);") {
                        try? s.bind(1, ts); _ = s.step(); s.finalize()
                    }
                case .didWake:
                    if let s = try? db.prepare("UPDATE sleep_periods SET sleep_end = ? WHERE sleep_end IS NULL;") {
                        try? s.bind(1, ts); _ = s.step(); s.finalize()
                    }
                }
            }
            sampler.startTimer()

            // Saatlik aggregate roll-up + günlük prune
            let aggregator = Aggregator(db: db)
            let maintQueue = DispatchQueue(label: "openmacbattery.maint", qos: .utility)
            let maint = DispatchSource.makeTimerSource(queue: maintQueue)
            maint.schedule(deadline: .now() + 3600, repeating: 3600, leeway: .seconds(60))
            maint.setEventHandler {
                do {
                    try aggregator.rollUp()
                } catch {
                    FileHandle.standardError.write(Data("aggregator: \(error)\n".utf8))
                }
                // Günde bir kez prune (saat 03:00 civarı)
                let h = Calendar.current.component(.hour, from: Date())
                if h == 3 {
                    let now = Int64(Date().timeIntervalSince1970)
                    let rawCutoff = now - 7 * 86400
                    let hourlyCutoff = now - 180 * 86400
                    if let s = try? db.prepare("DELETE FROM samples WHERE timestamp < ?;") {
                        try? s.bind(1, rawCutoff); _ = s.step(); s.finalize()
                    }
                    if let s = try? db.prepare("DELETE FROM hourly_aggregates WHERE hour_epoch < ?;") {
                        try? s.bind(1, hourlyCutoff); _ = s.step(); s.finalize()
                    }
                    _ = try? db.exec("PRAGMA incremental_vacuum;")
                }
            }
            maint.resume()

            // Run loop'u canlı tut (SleepWatcher source'u dinliyor)
            RunLoop.current.run()
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Install user LaunchAgent (no sudo required)"
        )
        @Option(name: .long, help: "Path to openmacbattery binary")
        var binary: String = "/opt/homebrew/bin/openmacbattery"

        func run() throws {
            do {
                try DaemonInstaller.install(binaryPath: binary)
                print("LaunchAgent installed and started.")
                print("Plist:  \(DaemonInstaller.plistPath)")
                print("Logs:   \(DaemonInstaller.logPath)")
            } catch {
                print("Install failed: \(error)")
                throw ExitCode(1)
            }
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "uninstall",
            abstract: "Remove user LaunchAgent"
        )
        func run() throws {
            DaemonInstaller.uninstall()
            print("Uninstalled.")
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show daemon + DB status"
        )
        func run() throws {
            let db = try openDatabase()
            let reporter = Reporter(db: db)
            let s = try reporter.stats()
            let dbMB = Double(s.dbBytes) / 1_048_576.0
            print("DB: \(db.path)")
            print("Size: \(String(format: "%.2f", dbMB)) MB")
            print("Samples: \(s.sampleCount)")
            if let oldest = s.oldest, let newest = s.newest {
                let fmt = ISO8601DateFormatter()
                fmt.formatOptions = [.withInternetDateTime]
                print("Range: \(fmt.string(from: Date(timeIntervalSince1970: TimeInterval(oldest))))")
                print("    →  \(fmt.string(from: Date(timeIntervalSince1970: TimeInterval(newest))))")
            }
            if let f = s.calibrationFactor {
                print("Energy unit factor (J/raw): \(f)")
            } else {
                print("Energy unit factor: NOT calibrated (showing raw scores)")
            }

            // launchctl print
            let uid = getuid()
            let label = "com.openmacbattery"
            print("\nlaunchctl print gui/\(uid)/\(label):")
            _ = runShell(["/bin/launchctl", "print", "gui/\(uid)/\(label)"], passThrough: true)
        }
    }
}

@discardableResult
func runShell(_ args: [String], passThrough: Bool = false) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    if !passThrough {
        p.standardOutput = Pipe()
        p.standardError = Pipe()
    }
    do {
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    } catch {
        return -1
    }
}
