import ArgumentParser
import Foundation
import OpenMacBatteryCore

struct SampleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sample",
        abstract: "Take a single sample (debug)"
    )

    @Flag(name: .long) var once: Bool = false
    @Flag(name: .long) var verbose: Bool = false

    func run() throws {
        let db = try openDatabase()
        let sampler = Sampler(db: db)
        // İki kere çağırmak gerek: ilk çağrı baseline kurar, ikincisi delta yazar
        try sampler.sampleOnce()
        if once {
            print("Baseline established. Run again to record deltas, or use the daemon.")
            return
        }
        // Default: 5 sn bekle ve ikinci sample al
        Thread.sleep(forTimeInterval: 5.0)
        try sampler.sampleOnce()
        print("OK — two samples recorded (5s apart).")
    }
}
