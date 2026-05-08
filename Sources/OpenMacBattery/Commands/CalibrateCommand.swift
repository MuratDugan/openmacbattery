import ArgumentParser
import Foundation
import OpenMacBatteryCore

struct CalibrateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calibrate",
        abstract: "Calibrate energy unit factor against powermetrics (sudo required)"
    )

    @Option(name: .long, help: "Calibration duration in seconds")
    var duration: Int = 300

    @Option(name: .long, help: "powermetrics interval in milliseconds")
    var intervalMs: Int = 5000

    @Flag(name: .long, help: "Just show the current factor and exit")
    var show: Bool = false

    func run() throws {
        let db = try openDatabase()

        if show {
            if let f = db.meta(key: "energy_unit_factor") {
                print("Current factor: \(f) J / raw_unit")
                if let when = db.meta(key: "energy_unit_calibrated_at") {
                    print("Calibrated at:  \(when)")
                }
            } else {
                print("Not calibrated. Run: openmacbattery calibrate --duration 300")
            }
            return
        }

        print("Running powermetrics for \(duration)s — sudo password may be requested.")
        print("Tip: open a CPU workload during this window for a better fit.\n")

        let result: CalibrationResult
        do {
            result = try Calibrator.run(durationSec: duration, intervalMs: intervalMs)
        } catch {
            print("Calibration failed: \(error)")
            throw ExitCode(1)
        }

        try db.setMeta(key: "energy_unit_factor", value: String(result.factor))
        let when = ISO8601DateFormatter().string(from: Date())
        try db.setMeta(key: "energy_unit_calibrated_at", value: when)

        print("Calibration complete.")
        print("  Duration:        \(String(format: "%.1f", result.durationSec))s")
        print("  Plist samples:   \(result.plistSampleCount)")
        print("  Total energy:    \(String(format: "%.2f J", result.totalJoules))")
        print("  Total raw delta: \(result.totalRawDelta)")
        print("  Factor:          \(result.factor) J / raw_unit")
        print("  Stored at:       \(when)")
    }
}
