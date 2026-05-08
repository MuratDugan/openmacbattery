import ArgumentParser
import Foundation
import OpenMacBatteryCore

struct TopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "top",
        abstract: "Top energy consumers in a time window"
    )

    @Option(name: .long, help: "Duration like 24h, 7d, 30m")
    var since: String = "24h"

    @Option(name: .long, help: "Max rows")
    var limit: Int = 20

    @Flag(name: .long, help: "Only count samples taken while on battery")
    var onBattery: Bool = false

    func run() throws {
        let db = try openDatabase()
        let reporter = Reporter(db: db)
        let secs = try DurationParser.parse(since)
        let range = DateRange.since(secs)
        let rows = try reporter.top(range: range, limit: limit, onlyBattery: onBattery)
        let factor = db.meta(key: "energy_unit_factor").flatMap { Double($0) }

        let total = rows.reduce(Int64(0)) { $0 + $1.energyRaw }
        let calibTag = factor != nil ? "calibrated" : "uncalibrated (showing raw score)"
        print("Top energy consumers — last \(since)\(onBattery ? " (battery only)" : "")")
        print("Energy unit: \(calibTag)\n")

        let header = "\(Pad.l("RANK", 4))  \(Pad.l("APP", 30))  \(Pad.l("ENERGY", 16))  \(Pad.l("CPU", 10))  \(Pad.l("WAKEUPS", 10))  % OF IDENTIFIED"
        print(header)
        print(String(repeating: "-", count: header.count))
        for (i, r) in rows.enumerated() {
            let pct = total > 0 ? Double(r.energyRaw) / Double(total) * 100.0 : 0
            let row = r
            let line = "\(Pad.l(String(i + 1), 4))  \(Pad.l(row.displayName, 30))  \(Pad.l(EnergyFormatter.format(rawEnergy: row.energyRaw, factor: factor), 16))  \(Pad.l(EnergyFormatter.formatCpuNs(row.cpuNs), 10))  \(Pad.l(EnergyFormatter.formatCount(row.wakeups), 10))  \(Pad.r(String(format: "%.1f%%", pct), 6))"
            print(line)
        }
        if rows.isEmpty {
            print("(no samples in this window — daemon may not be running yet)")
        }
    }
}
