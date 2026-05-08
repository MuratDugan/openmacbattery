import ArgumentParser
import Foundation
import OpenMacBatteryCore

struct StatsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Show DB stats"
    )
    func run() throws {
        let db = try openDatabase()
        let s = try Reporter(db: db).stats()
        print("DB:        \(db.path)")
        print("Size:      \(String(format: "%.2f MB", Double(s.dbBytes) / 1_048_576.0))")
        print("Samples:   \(s.sampleCount)")
        if let o = s.oldest, let n = s.newest {
            let f = ISO8601DateFormatter()
            print("Oldest:    \(f.string(from: Date(timeIntervalSince1970: TimeInterval(o))))")
            print("Newest:    \(f.string(from: Date(timeIntervalSince1970: TimeInterval(n))))")
            let span = Double(n - o) / 3600.0
            print("Span:      \(String(format: "%.1f hours", span))")
        }
        if let f = s.calibrationFactor {
            print("Calibration: factor = \(f) J/raw")
        } else {
            print("Calibration: NOT calibrated — `openmacbattery calibrate` ile faktör çıkar")
        }
    }
}

struct PruneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "Apply retention policy and incremental_vacuum"
    )

    @Option(name: .long, help: "Keep raw samples for this many days") var rawDays: Int = 7
    @Option(name: .long, help: "Keep hourly aggregates for this many days") var hourlyDays: Int = 180

    func run() throws {
        let db = try openDatabase()
        let now = Int64(Date().timeIntervalSince1970)
        let rawCutoff = now - Int64(rawDays) * 86400
        let hourlyCutoff = now - Int64(hourlyDays) * 86400

        let s1 = try db.prepare("DELETE FROM samples WHERE timestamp < ?;")
        try s1.bind(1, rawCutoff); _ = s1.step(); s1.finalize()
        let s2 = try db.prepare("DELETE FROM hourly_aggregates WHERE hour_epoch < ?;")
        try s2.bind(1, hourlyCutoff); _ = s2.step(); s2.finalize()
        try db.exec("PRAGMA incremental_vacuum;")
        print("Pruned. Raw cutoff: \(rawDays)d, hourly cutoff: \(hourlyDays)d.")
    }
}
