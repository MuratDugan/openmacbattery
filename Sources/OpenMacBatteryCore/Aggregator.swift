import Foundation

/// Saatlik roll-up'ı `samples` → `hourly_aggregates` tablosuna idempotent şekilde yazar.
public final class Aggregator {
    private let db: Database
    public init(db: Database) { self.db = db }

    /// `since`'den (epoch sec) önceki saatler için aggregate üret.
    /// Default: 7 gün öncesinden şimdiye kadar tüm tamamlanmış saatler.
    /// Idempotent — INSERT OR REPLACE.
    public func rollUp(sinceEpochSec: Int64? = nil) throws {
        let since = sinceEpochSec ?? (Int64(Date().timeIntervalSince1970) - 7 * 86400)
        // Şu anki saatten önceki saatleri işle (devam eden saati bekle)
        let now = Int64(Date().timeIntervalSince1970)
        let currentHour = (now / 3600) * 3600

        let sql = """
        INSERT OR REPLACE INTO hourly_aggregates
            (hour_epoch, bundle_id, display_name,
             total_energy_raw, total_cpu_ns, total_wakeups,
             sample_count, avg_battery_percent, on_battery_seconds)
        SELECT
            (timestamp / 3600) * 3600 AS hour_epoch,
            COALESCE(bundle_id, exec_path, 'unknown') AS bkey,
            MAX(COALESCE(display_name, bundle_id, 'unknown')) AS dname,
            COALESCE(SUM(energy_billed_raw), 0),
            COALESCE(SUM(cpu_user_ns + cpu_system_ns), 0),
            COALESCE(SUM(pkg_idle_wakeups + interrupt_wakeups), 0),
            COUNT(*),
            AVG(battery_percent),
            SUM(CASE WHEN is_on_battery = 1 THEN 60 ELSE 0 END)
        FROM samples
        WHERE timestamp >= ? AND timestamp < ?
        GROUP BY hour_epoch, bkey;
        """
        let stmt = try db.prepare(sql)
        defer { stmt.finalize() }
        try stmt.bind(1, since)
        try stmt.bind(2, currentHour)
        _ = stmt.step()
    }
}
