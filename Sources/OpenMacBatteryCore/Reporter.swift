import Foundation

public struct TopRow {
    public let groupKey: String        // SQL grouping key (bundle_id veya exec_path)
    public let bundleId: String?       // gerçek bundle_id, nil olabilir
    public let displayName: String
    public let execPath: String?
    public let energyRaw: Int64
    public let cpuNs: Int64
    public let wakeups: Int64
}

public struct TimelinePoint {
    public let bucket: Int64       // unix epoch (saniye, bucket başlangıcı)
    public let bundleId: String?
    public let displayName: String
    public let energyRaw: Int64
    public let cpuNs: Int64
}

public struct DateRange {
    public let from: Int64
    public let to: Int64
    public init(from: Int64, to: Int64) { self.from = from; self.to = to }
    public static func since(_ seconds: Int64) -> DateRange {
        let now = Int64(Date().timeIntervalSince1970)
        return DateRange(from: now - seconds, to: now)
    }
}

public final class Reporter {
    private let db: Database
    public init(db: Database) { self.db = db }

    public func top(range: DateRange, limit: Int = 20, onlyBattery: Bool = false) throws -> [TopRow] {
        let batteryClause = onlyBattery ? "AND is_on_battery = 1" : ""
        let sql = """
        SELECT
            COALESCE(bundle_id, exec_path, 'unknown') AS gkey,
            MAX(bundle_id) AS bid,
            COALESCE(MAX(display_name), MAX(bundle_id), 'unknown') AS dname,
            MAX(exec_path) AS epath,
            COALESCE(SUM(energy_billed_raw), 0) AS energy,
            COALESCE(SUM(cpu_user_ns + cpu_system_ns), 0) AS cpu,
            COALESCE(SUM(pkg_idle_wakeups + interrupt_wakeups), 0) AS wk
        FROM samples
        WHERE timestamp BETWEEN ? AND ? \(batteryClause)
        GROUP BY gkey
        ORDER BY energy DESC, cpu DESC
        LIMIT ?;
        """
        let stmt = try db.prepare(sql)
        defer { stmt.finalize() }
        try stmt.bind(1, range.from)
        try stmt.bind(2, range.to)
        try stmt.bind(3, Int64(limit))

        var rows: [TopRow] = []
        while stmt.step() {
            rows.append(TopRow(
                groupKey: stmt.string(0) ?? "unknown",
                bundleId: stmt.string(1),
                displayName: stmt.string(2) ?? "unknown",
                execPath: stmt.string(3),
                energyRaw: stmt.int64(4),
                cpuNs: stmt.int64(5),
                wakeups: stmt.int64(6)
            ))
        }
        return rows
    }

    public func appDetail(query: String, range: DateRange) throws -> [TimelinePoint] {
        let sql = """
        SELECT
            (timestamp / 3600) * 3600 AS bucket,
            bundle_id,
            COALESCE(display_name, bundle_id, 'unknown'),
            COALESCE(SUM(energy_billed_raw), 0),
            COALESCE(SUM(cpu_user_ns + cpu_system_ns), 0)
        FROM samples
        WHERE timestamp BETWEEN ? AND ?
          AND (bundle_id = ? OR display_name = ? OR display_name LIKE ?)
        GROUP BY bucket, bundle_id
        ORDER BY bucket ASC;
        """
        let stmt = try db.prepare(sql)
        defer { stmt.finalize() }
        try stmt.bind(1, range.from)
        try stmt.bind(2, range.to)
        try stmt.bind(3, query)
        try stmt.bind(4, query)
        try stmt.bind(5, "%\(query)%")

        var out: [TimelinePoint] = []
        while stmt.step() {
            out.append(TimelinePoint(
                bucket: stmt.int64(0),
                bundleId: stmt.string(1),
                displayName: stmt.string(2) ?? "unknown",
                energyRaw: stmt.int64(3),
                cpuNs: stmt.int64(4)
            ))
        }
        return out
    }

    public func timeline(range: DateRange, topN: Int, bucketSeconds: Int = 600) throws -> [TimelinePoint] {
        // İlk önce top N bundle'ı bul
        let top = try self.top(range: range, limit: topN)
        let keys = top.map { $0.groupKey }.filter { $0 != "unknown" }
        guard !keys.isEmpty else { return [] }

        let placeholders = keys.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT
            (timestamp / ?) * ? AS bucket,
            COALESCE(bundle_id, exec_path, 'unknown') AS gkey,
            COALESCE(display_name, bundle_id, 'unknown'),
            COALESCE(SUM(energy_billed_raw), 0),
            COALESCE(SUM(cpu_user_ns + cpu_system_ns), 0)
        FROM samples
        WHERE timestamp BETWEEN ? AND ?
          AND COALESCE(bundle_id, exec_path, 'unknown') IN (\(placeholders))
        GROUP BY bucket, gkey
        ORDER BY bucket ASC;
        """
        let stmt = try db.prepare(sql)
        defer { stmt.finalize() }
        try stmt.bind(1, Int64(bucketSeconds))
        try stmt.bind(2, Int64(bucketSeconds))
        try stmt.bind(3, range.from)
        try stmt.bind(4, range.to)
        for (i, k) in keys.enumerated() {
            try stmt.bind(Int32(5 + i), k)
        }

        var out: [TimelinePoint] = []
        while stmt.step() {
            out.append(TimelinePoint(
                bucket: stmt.int64(0),
                bundleId: stmt.string(1),
                displayName: stmt.string(2) ?? "unknown",
                energyRaw: stmt.int64(3),
                cpuNs: stmt.int64(4)
            ))
        }
        return out
    }

    /// Sidebar listesi: range içindeki tüm app'ler enerji DESC.
    public func allApps(range: DateRange, onlyBattery: Bool = false) throws -> [TopRow] {
        let batteryClause = onlyBattery ? "AND is_on_battery = 1" : ""
        let sql = """
        SELECT
            COALESCE(bundle_id, exec_path, 'unknown') AS gkey,
            MAX(bundle_id) AS bid,
            COALESCE(MAX(display_name), MAX(bundle_id), 'unknown') AS dname,
            MAX(exec_path) AS epath,
            COALESCE(SUM(energy_billed_raw), 0) AS energy,
            COALESCE(SUM(cpu_user_ns + cpu_system_ns), 0) AS cpu,
            COALESCE(SUM(pkg_idle_wakeups + interrupt_wakeups), 0) AS wk
        FROM samples
        WHERE timestamp BETWEEN ? AND ? \(batteryClause)
        GROUP BY gkey
        ORDER BY energy DESC, cpu DESC;
        """
        let stmt = try db.prepare(sql)
        defer { stmt.finalize() }
        try stmt.bind(1, range.from)
        try stmt.bind(2, range.to)
        var rows: [TopRow] = []
        while stmt.step() {
            rows.append(TopRow(
                groupKey: stmt.string(0) ?? "unknown",
                bundleId: stmt.string(1),
                displayName: stmt.string(2) ?? "unknown",
                execPath: stmt.string(3),
                energyRaw: stmt.int64(4),
                cpuNs: stmt.int64(5),
                wakeups: stmt.int64(6)
            ))
        }
        return rows
    }

    /// Birden fazla group key için birleşik zaman serisi (helper'lar parent'a katlanmış olduğunda).
    public func appTimelineMulti(groupKeys: [String], range: DateRange, bucketSeconds: Int = 600) throws -> [TimelinePoint] {
        guard !groupKeys.isEmpty else { return [] }
        let placeholders = groupKeys.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT
            (timestamp / ?) * ? AS bucket,
            COALESCE(SUM(energy_billed_raw), 0),
            COALESCE(SUM(cpu_user_ns + cpu_system_ns), 0)
        FROM samples
        WHERE timestamp BETWEEN ? AND ?
          AND COALESCE(bundle_id, exec_path, 'unknown') IN (\(placeholders))
        GROUP BY bucket
        ORDER BY bucket ASC;
        """
        let stmt = try db.prepare(sql)
        defer { stmt.finalize() }
        try stmt.bind(1, Int64(bucketSeconds))
        try stmt.bind(2, Int64(bucketSeconds))
        try stmt.bind(3, range.from)
        try stmt.bind(4, range.to)
        for (i, k) in groupKeys.enumerated() {
            try stmt.bind(Int32(5 + i), k)
        }
        var out: [TimelinePoint] = []
        while stmt.step() {
            out.append(TimelinePoint(
                bucket: stmt.int64(0),
                bundleId: nil,
                displayName: "",
                energyRaw: stmt.int64(1),
                cpuNs: stmt.int64(2)
            ))
        }
        return out
    }

    /// Pil yüzdesi zaman serisi (en yüksek battery_percent olan sample saatlik bucket'ta).
    public struct BatteryPoint { public let bucket: Int64; public let percent: Double; public let onBattery: Bool }
    public func batteryTimeline(range: DateRange, bucketSeconds: Int = 600) throws -> [BatteryPoint] {
        let sql = """
        SELECT
            (timestamp / ?) * ? AS bucket,
            AVG(battery_percent),
            MAX(is_on_battery)
        FROM samples
        WHERE timestamp BETWEEN ? AND ? AND battery_percent IS NOT NULL
        GROUP BY bucket
        ORDER BY bucket ASC;
        """
        let stmt = try db.prepare(sql)
        defer { stmt.finalize() }
        try stmt.bind(1, Int64(bucketSeconds))
        try stmt.bind(2, Int64(bucketSeconds))
        try stmt.bind(3, range.from)
        try stmt.bind(4, range.to)
        var out: [BatteryPoint] = []
        while stmt.step() {
            out.append(.init(bucket: stmt.int64(0), percent: stmt.double(1), onBattery: stmt.int64(2) == 1))
        }
        return out
    }

    /// Verilen app'in time-bucket'lı zaman serisi (ortalama 10dk bucket).
    public func appTimeline(bundleKey: String, range: DateRange, bucketSeconds: Int = 600) throws -> [TimelinePoint] {
        let sql = """
        SELECT
            (timestamp / ?) * ? AS bucket,
            ?,
            ?,
            COALESCE(SUM(energy_billed_raw), 0),
            COALESCE(SUM(cpu_user_ns + cpu_system_ns), 0)
        FROM samples
        WHERE timestamp BETWEEN ? AND ?
          AND COALESCE(bundle_id, exec_path, 'unknown') = ?
        GROUP BY bucket
        ORDER BY bucket ASC;
        """
        let stmt = try db.prepare(sql)
        defer { stmt.finalize() }
        try stmt.bind(1, Int64(bucketSeconds))
        try stmt.bind(2, Int64(bucketSeconds))
        try stmt.bind(3, bundleKey)
        try stmt.bind(4, bundleKey)
        try stmt.bind(5, range.from)
        try stmt.bind(6, range.to)
        try stmt.bind(7, bundleKey)
        var out: [TimelinePoint] = []
        while stmt.step() {
            out.append(TimelinePoint(
                bucket: stmt.int64(0),
                bundleId: stmt.string(1),
                displayName: stmt.string(2) ?? "unknown",
                energyRaw: stmt.int64(3),
                cpuNs: stmt.int64(4)
            ))
        }
        return out
    }

    /// Pildeyken battery_percent düşüş hızından gerçek ortalama watt çekişi.
    /// `fullWh` = pilin tam dolu Wh kapasitesi.
    /// Dönüş: (avgWatts, percentDropPerHour, samplesUsed) — yeterli düşüş yoksa nil.
    public func averageBatteryWatts(rangeSec: Int, fullWh: Double) throws -> (watts: Double, percentPerHour: Double, samples: Int)? {
        let now = Int64(Date().timeIntervalSince1970)
        let from = now - Int64(rangeSec)
        let sql = """
        SELECT
            MIN(timestamp), MAX(timestamp),
            (SELECT battery_percent FROM samples WHERE timestamp >= ? AND is_on_battery = 1 AND battery_percent IS NOT NULL ORDER BY timestamp ASC LIMIT 1),
            (SELECT battery_percent FROM samples WHERE timestamp <= ? AND is_on_battery = 1 AND battery_percent IS NOT NULL ORDER BY timestamp DESC LIMIT 1),
            COUNT(*)
        FROM samples
        WHERE timestamp BETWEEN ? AND ? AND is_on_battery = 1 AND battery_percent IS NOT NULL;
        """
        let stmt = try db.prepare(sql); defer { stmt.finalize() }
        try stmt.bind(1, from); try stmt.bind(2, now)
        try stmt.bind(3, from); try stmt.bind(4, now)
        guard stmt.step(), !stmt.isNull(0), !stmt.isNull(1), !stmt.isNull(2), !stmt.isNull(3) else { return nil }
        let tFirst = stmt.int64(0), tLast = stmt.int64(1)
        let pFirst = stmt.int(2), pLast = stmt.int(3)
        let count = Int(stmt.int64(4))
        let dt = Double(tLast - tFirst)
        guard dt >= 60 else { return nil }
        let drop = Double(pFirst - pLast)   // pozitif = deşarj
        guard drop > 0 else { return nil }   // şarjda veya rölantide
        let percentPerHour = drop * 3600.0 / dt
        let watts = (percentPerHour / 100.0) * fullWh
        return (watts, percentPerHour, count)
    }

    /// Verilen aralıktaki tüm group key'ler için toplam ham enerji.
    public func energyByGroupKey(range: DateRange, onlyBattery: Bool = false) throws -> [String: Int64] {
        let batteryClause = onlyBattery ? "AND is_on_battery = 1" : ""
        let sql = """
        SELECT
            COALESCE(bundle_id, exec_path, 'unknown') AS gkey,
            COALESCE(SUM(energy_billed_raw), 0)
        FROM samples
        WHERE timestamp BETWEEN ? AND ? \(batteryClause)
        GROUP BY gkey;
        """
        let stmt = try db.prepare(sql); defer { stmt.finalize() }
        try stmt.bind(1, range.from); try stmt.bind(2, range.to)
        var out: [String: Int64] = [:]
        while stmt.step() {
            out[stmt.string(0) ?? "unknown"] = stmt.int64(1)
        }
        return out
    }

    /// Pencerenin başındaki ve sonundaki pil yüzdeleri + pildeyken/AC süresi.
    public struct BatterySummary {
        public let firstPercent: Int?
        public let lastPercent: Int?
        public let onBatterySeconds: Int64
        public let onAcSeconds: Int64
        public let sleepSeconds: Int64
        /// Pildeyken net düşüş (-50 → 30 = -20). AC'deyken doluyorsa pozitif.
        public var deltaPercent: Int? {
            guard let f = firstPercent, let l = lastPercent else { return nil }
            return l - f
        }
    }

    public func batterySummary(range: DateRange) throws -> BatterySummary {
        // İlk ve son sample'ın pil yüzdesi (NULL olmayan)
        let firstSql = "SELECT battery_percent FROM samples WHERE timestamp >= ? AND timestamp <= ? AND battery_percent IS NOT NULL ORDER BY timestamp ASC LIMIT 1;"
        let lastSql  = "SELECT battery_percent FROM samples WHERE timestamp >= ? AND timestamp <= ? AND battery_percent IS NOT NULL ORDER BY timestamp DESC LIMIT 1;"
        var first: Int? = nil
        var last: Int? = nil
        let s1 = try db.prepare(firstSql); defer { s1.finalize() }
        try s1.bind(1, range.from); try s1.bind(2, range.to)
        if s1.step(), !s1.isNull(0) { first = s1.int(0) }
        let s2 = try db.prepare(lastSql); defer { s2.finalize() }
        try s2.bind(1, range.from); try s2.bind(2, range.to)
        if s2.step(), !s2.isNull(0) { last = s2.int(0) }

        // Pildeyken / AC süresi (her sample 60sn varsay; aslında interval değişmiş olabilir)
        let durSql = """
        SELECT
            COALESCE(SUM(CASE WHEN is_on_battery = 1 THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN is_on_battery = 0 THEN 1 ELSE 0 END), 0)
        FROM (SELECT DISTINCT timestamp, MAX(is_on_battery) AS is_on_battery
              FROM samples WHERE timestamp BETWEEN ? AND ?
              GROUP BY timestamp);
        """
        var onBattSec: Int64 = 0; var onAcSec: Int64 = 0
        let s3 = try db.prepare(durSql); defer { s3.finalize() }
        try s3.bind(1, range.from); try s3.bind(2, range.to)
        if s3.step() {
            onBattSec = s3.int64(0) * 60
            onAcSec = s3.int64(1) * 60
        }

        // Sleep süresi
        let sleepSql = """
        SELECT COALESCE(SUM(
            MIN(COALESCE(sleep_end, ?), ?) - MAX(sleep_start, ?)
        ), 0)
        FROM sleep_periods
        WHERE COALESCE(sleep_end, ?) >= ? AND sleep_start <= ?;
        """
        var sleepSec: Int64 = 0
        let s4 = try db.prepare(sleepSql); defer { s4.finalize() }
        let now = Int64(Date().timeIntervalSince1970)
        try s4.bind(1, now); try s4.bind(2, range.to); try s4.bind(3, range.from)
        try s4.bind(4, now); try s4.bind(5, range.from); try s4.bind(6, range.to)
        if s4.step() { sleepSec = max(0, s4.int64(0)) }

        return BatterySummary(
            firstPercent: first, lastPercent: last,
            onBatterySeconds: onBattSec, onAcSeconds: onAcSec,
            sleepSeconds: sleepSec
        )
    }

    public struct SleepInterval { public let start: Int64; public let end: Int64 }
    public func sleepPeriods(range: DateRange) throws -> [SleepInterval] {
        let sql = """
        SELECT sleep_start, COALESCE(sleep_end, ?)
        FROM sleep_periods
        WHERE COALESCE(sleep_end, ?) >= ? AND sleep_start <= ?
        ORDER BY sleep_start ASC;
        """
        let now = Int64(Date().timeIntervalSince1970)
        let stmt = try db.prepare(sql); defer { stmt.finalize() }
        try stmt.bind(1, now); try stmt.bind(2, now)
        try stmt.bind(3, range.from); try stmt.bind(4, range.to)
        var out: [SleepInterval] = []
        while stmt.step() {
            let s = max(stmt.int64(0), range.from)
            let e = min(stmt.int64(1), range.to)
            if e > s { out.append(SleepInterval(start: s, end: e)) }
        }
        return out
    }

    /// Sidebar sparkline'ları için: tüm grup anahtarları için zaman serileri.
    /// Dönüş: groupKey → [(bucket, energyRaw)] — bucket aralıkları kronolojik.
    public func sparklineBuckets(range: DateRange, bucketSeconds: Int = 600, onlyBattery: Bool = false) throws -> [String: [(Int64, Int64)]] {
        let batteryClause = onlyBattery ? "AND is_on_battery = 1" : ""
        let sql = """
        SELECT
            COALESCE(bundle_id, exec_path, 'unknown') AS gkey,
            (timestamp / ?) * ? AS bucket,
            COALESCE(SUM(energy_billed_raw), 0)
        FROM samples
        WHERE timestamp BETWEEN ? AND ? \(batteryClause)
        GROUP BY gkey, bucket
        ORDER BY gkey, bucket;
        """
        let stmt = try db.prepare(sql); defer { stmt.finalize() }
        try stmt.bind(1, Int64(bucketSeconds))
        try stmt.bind(2, Int64(bucketSeconds))
        try stmt.bind(3, range.from); try stmt.bind(4, range.to)
        var out: [String: [(Int64, Int64)]] = [:]
        while stmt.step() {
            let key = stmt.string(0) ?? "unknown"
            out[key, default: []].append((stmt.int64(1), stmt.int64(2)))
        }
        return out
    }

    public func stats() throws -> (sampleCount: Int64, dbBytes: Int64, oldest: Int64?, newest: Int64?, calibrationFactor: Double?) {
        let cnt: Int64 = {
            guard let s = try? db.prepare("SELECT COUNT(*) FROM samples;") else { return 0 }
            defer { s.finalize() }
            return s.step() ? s.int64(0) : 0
        }()
        let oldest: Int64? = {
            guard let s = try? db.prepare("SELECT MIN(timestamp) FROM samples;") else { return nil }
            defer { s.finalize() }
            return s.step() && !s.isNull(0) ? s.int64(0) : nil
        }()
        let newest: Int64? = {
            guard let s = try? db.prepare("SELECT MAX(timestamp) FROM samples;") else { return nil }
            defer { s.finalize() }
            return s.step() && !s.isNull(0) ? s.int64(0) : nil
        }()
        let bytes: Int64 = {
            (try? FileManager.default.attributesOfItem(atPath: db.path)[.size] as? Int64) ?? 0
        }()
        let factor = db.meta(key: "energy_unit_factor").flatMap { Double($0) }
        return (cnt, bytes, oldest, newest, factor)
    }
}

public enum Pad {
    /// Sola yasla, n karaktere kadar boşlukla doldur veya kırp.
    public static func l(_ s: String, _ n: Int) -> String {
        if s.count >= n { return String(s.prefix(n)) }
        return s + String(repeating: " ", count: n - s.count)
    }
    /// Sağa yasla.
    public static func r(_ s: String, _ n: Int) -> String {
        if s.count >= n { return String(s.prefix(n)) }
        return String(repeating: " ", count: n - s.count) + s
    }
}

public enum EnergyFormatter {
    public static func format(rawEnergy: Int64, factor: Double?) -> String {
        guard let f = factor, f > 0 else {
            return "score \(rawEnergy)"
        }
        let joules = Double(rawEnergy) * f
        if joules >= 1000 { return String(format: "~%.2f kJ", joules / 1000.0) }
        if joules >= 1 { return String(format: "~%.0f J", joules) }
        return String(format: "~%.2f mJ", joules * 1000.0)
    }

    public static func formatCpuNs(_ ns: Int64) -> String {
        let s = Double(ns) / 1_000_000_000.0
        if s >= 3600 { return String(format: "%.1fh", s / 3600.0) }
        if s >= 60 { return String(format: "%.1fm", s / 60.0) }
        return String(format: "%.1fs", s)
    }

    public static func formatCount(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000.0) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000.0) }
        return "\(n)"
    }
}
