import ArgumentParser
import Foundation
import OpenMacBatteryCore

struct AppCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Per-app timeline by hour"
    )

    @Argument(help: "Bundle ID or display name (substring match)")
    var query: String

    @Option(name: .long) var since: String = "7d"

    func run() throws {
        let db = try openDatabase()
        let reporter = Reporter(db: db)
        let range = DateRange.since(try DurationParser.parse(since))
        let points = try reporter.appDetail(query: query, range: range)
        let factor = db.meta(key: "energy_unit_factor").flatMap { Double($0) }

        if points.isEmpty {
            print("No data for \"\(query)\" in last \(since).")
            return
        }
        print("App: \(points.first?.displayName ?? query)  (last \(since))\n")
        print("\(Pad.l("HOUR (local)", 20))  \(Pad.l("ENERGY", 12))  \(Pad.l("CPU", 10))")
        print(String(repeating: "-", count: 50))
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:00"
        var total = Int64(0); var totalCpu = Int64(0)
        for p in points {
            let date = Date(timeIntervalSince1970: TimeInterval(p.bucket))
            print("\(Pad.l(fmt.string(from: date), 20))  \(Pad.l(EnergyFormatter.format(rawEnergy: p.energyRaw, factor: factor), 12))  \(Pad.l(EnergyFormatter.formatCpuNs(p.cpuNs), 10))")
            total += p.energyRaw
            totalCpu += p.cpuNs
        }
        print(String(repeating: "-", count: 50))
        print("\(Pad.l("TOTAL", 20))  \(Pad.l(EnergyFormatter.format(rawEnergy: total, factor: factor), 12))  \(Pad.l(EnergyFormatter.formatCpuNs(totalCpu), 10))")
    }
}
