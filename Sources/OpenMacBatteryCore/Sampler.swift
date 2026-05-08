import Foundation
import Darwin

public struct SampleBaseline {
    var userTimeNs: UInt64
    var systemTimeNs: UInt64
    var pkgIdleWakeups: UInt64
    var interruptWakeups: UInt64
    var diskRead: UInt64
    var diskWrite: UInt64
    var billedEnergy: UInt64
    var servicedEnergy: UInt64
}

public struct SamplerConfig {
    public var interval: TimeInterval
    public var slowSampleThreshold: TimeInterval  // tick > X ise yavaşla
    public var fastSampleThreshold: TimeInterval  // tick < X ise tekrar hızlan
    public var slowInterval: TimeInterval
    public var fastTicksToRecover: Int             // ardışık X hızlı tick → fast'a dön

    public static let `default` = SamplerConfig(
        interval: 60.0,
        slowSampleThreshold: 0.5,
        fastSampleThreshold: 0.25,
        slowInterval: 120.0,
        fastTicksToRecover: 3
    )
}

public final class Sampler {
    private let db: Database
    private let resolver = BundleResolver()
    private let config: SamplerConfig
    private var baselines: [ProcessKey: SampleBaseline] = [:]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "openmacbattery.sampler", qos: .utility)
    private var running = false
    private var currentInterval: TimeInterval
    private var consecutiveFastTicks: Int = 0

    public init(db: Database, config: SamplerConfig = .default) {
        self.db = db
        self.config = config
        self.currentInterval = config.interval
    }

    public func startTimer() {
        guard !running else { return }
        running = true
        // Düşük process önceliği
        setpriority(PRIO_PROCESS, 0, 10)

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: currentInterval, leeway: .seconds(5))
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        t.resume()
        self.timer = t
    }

    public func stopTimer() {
        timer?.cancel()
        timer = nil
        running = false
    }

    private func tick() {
        let elapsed = measure {
            do { try sampleOnce() }
            catch { FileHandle.standardError.write(Data("sample error: \(error)\n".utf8)) }
        }

        // Self-throttling — histerezisli geçişler
        // Yavaşlat: tek bir yavaş tick yeter
        if elapsed > config.slowSampleThreshold && currentInterval < config.slowInterval {
            currentInterval = config.slowInterval
            consecutiveFastTicks = 0
            FileHandle.standardError.write(Data("sampler: slow tick (\(String(format: "%.3f", elapsed))s) → throttling to \(Int(currentInterval))s\n".utf8))
            timer?.schedule(deadline: .now() + currentInterval, repeating: currentInterval, leeway: .seconds(5))
            return
        }

        // Hızlandır: ardışık birkaç hızlı tick lazım (gürültüye karşı)
        if currentInterval > config.interval {
            if elapsed < config.fastSampleThreshold {
                consecutiveFastTicks += 1
                if consecutiveFastTicks >= config.fastTicksToRecover {
                    currentInterval = config.interval
                    consecutiveFastTicks = 0
                    FileHandle.standardError.write(Data("sampler: ticks back to fast → \(Int(currentInterval))s interval\n".utf8))
                    timer?.schedule(deadline: .now() + currentInterval, repeating: currentInterval, leeway: .seconds(5))
                }
            } else {
                // Aralıkta — sayacı sıfırla
                consecutiveFastTicks = 0
            }
        }
    }

    /// Tek seferlik sample (CLI debug için)
    public func sampleOnce() throws {
        let now = Int64(Date().timeIntervalSince1970)
        let power = PowerSourceReader.current()
        let pids = ProcessInfoReader.listAllPids()
        var seenKeys = Set<ProcessKey>()
        var insertedRows = 0
        var permDenied = 0

        let insertSQL = """
        INSERT INTO samples
            (timestamp, pid, proc_start_sec, bundle_id, display_name, exec_path,
             cpu_user_ns, cpu_system_ns,
             energy_billed_raw, energy_serviced_raw,
             pkg_idle_wakeups, interrupt_wakeups,
             disk_read_bytes, disk_write_bytes,
             is_on_battery, battery_percent, rusage_version)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """
        let stmt = try db.prepare(insertSQL)
        defer { stmt.finalize() }

        try db.transaction {
            for pid in pids {
                guard let id = ProcessInfoReader.identity(pid: pid) else { continue }
                guard let ru = ProcessInfoReader.rusage(pid: pid) else {
                    let err = ProcessInfoReader.lastErrno
                    if err == EPERM { permDenied += 1 }
                    continue
                }
                let key = ProcessKey(pid: pid, startTvSec: id.startTvSec)
                seenKeys.insert(key)
                let meta = resolver.resolve(pid: pid, startTvSec: id.startTvSec)

                // Delta hesapla — baseline yoksa ilk sample 0 yazılır (sonraki tick'te delta gelir)
                let prev = baselines[key]
                // Cumulative sayaç azalırsa (counter reset / PID reuse race), delta=0 yaz.
                func d(_ cur: UInt64, _ prv: UInt64?) -> UInt64 {
                    guard let prv else { return 0 }
                    return cur >= prv ? cur - prv : 0
                }
                let delta = SampleBaseline(
                    userTimeNs: d(ru.userTimeNs, prev?.userTimeNs),
                    systemTimeNs: d(ru.systemTimeNs, prev?.systemTimeNs),
                    pkgIdleWakeups: d(ru.pkgIdleWakeups, prev?.pkgIdleWakeups),
                    interruptWakeups: d(ru.interruptWakeups, prev?.interruptWakeups),
                    diskRead: d(ru.diskReadBytes, prev?.diskRead),
                    diskWrite: d(ru.diskWriteBytes, prev?.diskWrite),
                    billedEnergy: d(ru.billedEnergy, prev?.billedEnergy),
                    servicedEnergy: d(ru.servicedEnergy, prev?.servicedEnergy)
                )

                baselines[key] = SampleBaseline(
                    userTimeNs: ru.userTimeNs,
                    systemTimeNs: ru.systemTimeNs,
                    pkgIdleWakeups: ru.pkgIdleWakeups,
                    interruptWakeups: ru.interruptWakeups,
                    diskRead: ru.diskReadBytes,
                    diskWrite: ru.diskWriteBytes,
                    billedEnergy: ru.billedEnergy,
                    servicedEnergy: ru.servicedEnergy
                )

                // İlk sample'ı (baseline yokken) atla — delta bilgisi anlamsız
                if prev == nil { continue }

                stmt.reset()
                try stmt.bind(1, now)
                try stmt.bind(2, Int64(pid))
                try stmt.bind(3, Int64(id.startTvSec))
                try stmt.bind(4, meta.bundleId)
                try stmt.bind(5, meta.displayName)
                try stmt.bind(6, meta.execPath)
                try stmt.bind(7, delta.userTimeNs)
                try stmt.bind(8, delta.systemTimeNs)
                if ru.rusageVersion >= 6 {
                    try stmt.bind(9, delta.billedEnergy)
                    try stmt.bind(10, delta.servicedEnergy)
                } else {
                    try stmt.bindNull(9)
                    try stmt.bindNull(10)
                }
                try stmt.bind(11, delta.pkgIdleWakeups)
                try stmt.bind(12, delta.interruptWakeups)
                try stmt.bind(13, delta.diskRead)
                try stmt.bind(14, delta.diskWrite)
                try stmt.bind(15, Int64(power.isOnBattery ? 1 : 0))
                if let p = power.batteryPercent { try stmt.bind(16, Int64(p)) } else { try stmt.bindNull(16) }
                try stmt.bind(17, Int64(ru.rusageVersion))
                _ = stmt.step()
                insertedRows += 1
            }
        }

        // Cache + baseline temizliği — kaybolan PID'ler için
        let seenSet = seenKeys
        baselines = baselines.filter { seenSet.contains($0.key) }
        resolver.evictAll(except: seenSet)

        FileHandle.standardError.write(Data("sample: pids=\(pids.count) inserted=\(insertedRows) eperm=\(permDenied) battery=\(power.isOnBattery ? "yes" : "no") interval=\(Int(currentInterval))s\n".utf8))
    }

    private func measure(_ body: () -> Void) -> TimeInterval {
        let t0 = Date()
        body()
        return Date().timeIntervalSince(t0)
    }
}
