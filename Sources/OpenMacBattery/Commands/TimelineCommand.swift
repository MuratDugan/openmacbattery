import ArgumentParser
import Foundation
import OpenMacBatteryCore

struct TimelineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "timeline",
        abstract: "Top-N apps energy timeline (10-min buckets)"
    )

    @Option(name: .long) var since: String = "24h"
    @Option(name: .long) var top: Int = 5
    @Option(name: .long, help: "Bucket size in seconds") var bucket: Int = 600

    func run() throws {
        let db = try openDatabase()
        let reporter = Reporter(db: db)
        let range = DateRange.since(try DurationParser.parse(since))
        let points = try reporter.timeline(range: range, topN: top, bucketSeconds: bucket)
        let factor = db.meta(key: "energy_unit_factor").flatMap { Double($0) }

        if points.isEmpty {
            print("No data.")
            return
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        print("\(Pad.l("BUCKET", 12))  \(Pad.l("APP", 25))  ENERGY")
        for p in points {
            let date = Date(timeIntervalSince1970: TimeInterval(p.bucket))
            print("\(Pad.l(fmt.string(from: date), 12))  \(Pad.l(p.displayName, 25))  \(EnergyFormatter.format(rawEnergy: p.energyRaw, factor: factor))")
        }
    }
}
