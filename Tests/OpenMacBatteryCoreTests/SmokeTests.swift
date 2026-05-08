import XCTest
@testable import OpenMacBatteryCore

final class SmokeTests: XCTestCase {
    func testListAllPids() {
        let pids = ProcessInfoReader.listAllPids()
        XCTAssertGreaterThan(pids.count, 10, "should find some processes")
        XCTAssertTrue(pids.contains(getpid()), "self pid should be in list")
    }

    func testSelfRusage() {
        guard let r = ProcessInfoReader.rusage(pid: getpid()) else {
            XCTFail("self rusage must succeed"); return
        }
        XCTAssertGreaterThan(r.userTimeNs + r.systemTimeNs, 0)
        XCTAssertTrue(r.rusageVersion == 4 || r.rusageVersion == 6)
    }

    func testDatabaseRoundtrip() throws {
        let tmp = NSTemporaryDirectory() + "battracker_test_\(getpid()).db"
        try? FileManager.default.removeItem(atPath: tmp)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let db = try Database(path: tmp)
        try db.setMeta(key: "energy_unit_factor", value: "1.42e-9")
        XCTAssertEqual(db.meta(key: "energy_unit_factor"), "1.42e-9")

        let sampler = Sampler(db: db)
        try sampler.sampleOnce()  // baseline
        // küçük bir CPU yükü
        var x = 0; for i in 0..<200_000 { x &+= i }
        _ = x
        Thread.sleep(forTimeInterval: 0.5)
        try sampler.sampleOnce()  // delta

        let r = try Reporter(db: db).stats()
        XCTAssertGreaterThan(r.sampleCount, 0)
    }

    func testPowerSourceReadsWithoutCrashing() {
        _ = PowerSourceReader.current()
    }

    func testEnergyFormatter() {
        XCTAssertTrue(EnergyFormatter.format(rawEnergy: 1000, factor: nil).contains("score"))
        XCTAssertTrue(EnergyFormatter.format(rawEnergy: 1_000_000_000, factor: 1.0).contains("kJ") ||
                      EnergyFormatter.format(rawEnergy: 1_000_000_000, factor: 1.0).contains("J"))
    }
}
