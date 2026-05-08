import Foundation
import CSQLite

public enum DatabaseError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String)
    case step(String)
    case bind(String)

    public var description: String {
        switch self {
        case .open(let m): return "DB open failed: \(m)"
        case .prepare(let m): return "DB prepare failed: \(m)"
        case .step(let m): return "DB step failed: \(m)"
        case .bind(let m): return "DB bind failed: \(m)"
        }
    }
}

public final class Database {
    private var handle: OpaquePointer?
    public let path: String

    public static func defaultPath() -> String {
        let home = NSHomeDirectory()
        let newDir = "\(home)/Library/Application Support/OpenMacBattery"
        let oldDir = "\(home)/Library/Application Support/BatteryTracker"
        let fm = FileManager.default

        // Migration: BatTracker → OpenMacBattery rename'inden sonraki ilk açılış.
        // Eski klasörde data.db varsa ve yeni klasör boşsa, sessizce kopyala.
        if !fm.fileExists(atPath: newDir + "/data.db"),
           fm.fileExists(atPath: oldDir + "/data.db") {
            try? fm.createDirectory(atPath: newDir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            for name in ["data.db", "data.db-wal", "data.db-shm"] {
                let src = "\(oldDir)/\(name)"
                let dst = "\(newDir)/\(name)"
                if fm.fileExists(atPath: src), !fm.fileExists(atPath: dst) {
                    try? fm.copyItem(atPath: src, toPath: dst)
                }
            }
            FileHandle.standardError.write(Data(
                "Migrated existing data from \(oldDir) to \(newDir)\n".utf8))
        }

        try? fm.createDirectory(
            atPath: newDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: newDir)
        return "\(newDir)/data.db"
    }

    public init(path: String) throws {
        self.path = path
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(h)
            throw DatabaseError.open(msg)
        }
        self.handle = h
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("PRAGMA busy_timeout=5000;")
        try exec("PRAGMA auto_vacuum=INCREMENTAL;")
        try migrate()
        // 600 izinlerini DB dosyası ve WAL/SHM yan dosyaları için zorla.
        // (sqlite3_open_v2 default umask'le 644 oluşturur — başka apps okuyamasın diye sıkıyoruz.)
        for suffix in ["", "-wal", "-shm"] {
            let p = path + suffix
            if FileManager.default.fileExists(atPath: p) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p)
            }
        }
    }

    deinit {
        if let h = handle {
            sqlite3_close_v2(h)
        }
    }

    @discardableResult
    public func exec(_ sql: String) throws -> Int32 {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DatabaseError.step("\(sql): \(msg)")
        }
        return rc
    }

    public func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(handle))
            throw DatabaseError.prepare("\(sql): \(msg)")
        }
        return Statement(stmt: stmt)
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE;")
        do {
            let v = try body()
            try exec("COMMIT;")
            return v
        } catch {
            _ = try? exec("ROLLBACK;")
            throw error
        }
    }

    public func meta(key: String) -> String? {
        guard let stmt = try? prepare("SELECT value FROM meta WHERE key = ?;") else { return nil }
        defer { stmt.finalize() }
        try? stmt.bind(1, key)
        return stmt.step() ? stmt.string(0) : nil
    }

    public func setMeta(key: String, value: String) throws {
        let s = try prepare("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;")
        defer { s.finalize() }
        try s.bind(1, key)
        try s.bind(2, value)
        _ = s.step()
    }

    private func migrate() throws {
        let v = Int(meta(key: "schema_version") ?? "0") ?? 0
        if v < 1 {
            try exec(Schema.v1)
            try setMeta(key: "schema_version", value: "1")
        }
    }
}

// MARK: - Statement wrapper

public final class Statement {
    private var stmt: OpaquePointer?

    init(stmt: OpaquePointer) { self.stmt = stmt }

    public func finalize() {
        if let s = stmt { sqlite3_finalize(s); stmt = nil }
    }

    deinit { finalize() }

    @discardableResult
    public func step() -> Bool {
        guard let s = stmt else { return false }
        return sqlite3_step(s) == SQLITE_ROW
    }

    public func reset() {
        if let s = stmt { sqlite3_reset(s); sqlite3_clear_bindings(s) }
    }

    public func bind(_ idx: Int32, _ v: Int64) throws {
        let rc = sqlite3_bind_int64(stmt, idx, v)
        if rc != SQLITE_OK { throw DatabaseError.bind("int64 \(idx)") }
    }
    public func bind(_ idx: Int32, _ v: Int) throws { try bind(idx, Int64(v)) }
    public func bind(_ idx: Int32, _ v: Int32) throws { try bind(idx, Int64(v)) }
    public func bind(_ idx: Int32, _ v: UInt64) throws { try bind(idx, Int64(bitPattern: v)) }
    public func bind(_ idx: Int32, _ v: Double) throws {
        let rc = sqlite3_bind_double(stmt, idx, v)
        if rc != SQLITE_OK { throw DatabaseError.bind("double \(idx)") }
    }
    public func bind(_ idx: Int32, _ v: String?) throws {
        let rc: Int32
        if let v {
            rc = v.withCString { bt_bind_text(stmt, idx, $0) }
        } else {
            rc = sqlite3_bind_null(stmt, idx)
        }
        if rc != SQLITE_OK { throw DatabaseError.bind("text \(idx)") }
    }
    public func bindNull(_ idx: Int32) throws {
        let rc = sqlite3_bind_null(stmt, idx)
        if rc != SQLITE_OK { throw DatabaseError.bind("null \(idx)") }
    }

    public func int64(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }
    public func int(_ col: Int32) -> Int { Int(sqlite3_column_int64(stmt, col)) }
    public func double(_ col: Int32) -> Double { sqlite3_column_double(stmt, col) }
    public func string(_ col: Int32) -> String? {
        guard let cstr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: cstr)
    }
    public func isNull(_ col: Int32) -> Bool { sqlite3_column_type(stmt, col) == SQLITE_NULL }
}

// MARK: - Schema

enum Schema {
    static let v1 = """
    CREATE TABLE IF NOT EXISTS samples (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp INTEGER NOT NULL,
        pid INTEGER NOT NULL,
        proc_start_sec INTEGER NOT NULL,
        bundle_id TEXT,
        display_name TEXT,
        exec_path TEXT,
        cpu_user_ns INTEGER NOT NULL,
        cpu_system_ns INTEGER NOT NULL,
        energy_billed_raw INTEGER,
        energy_serviced_raw INTEGER,
        pkg_idle_wakeups INTEGER,
        interrupt_wakeups INTEGER,
        disk_read_bytes INTEGER,
        disk_write_bytes INTEGER,
        is_on_battery INTEGER NOT NULL,
        battery_percent INTEGER,
        rusage_version INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_samples_time ON samples(timestamp);
    CREATE INDEX IF NOT EXISTS idx_samples_bundle ON samples(bundle_id, timestamp);

    CREATE TABLE IF NOT EXISTS hourly_aggregates (
        hour_epoch INTEGER NOT NULL,
        bundle_id TEXT NOT NULL,
        display_name TEXT,
        total_energy_raw INTEGER,
        total_cpu_ns INTEGER,
        total_wakeups INTEGER,
        sample_count INTEGER,
        avg_battery_percent REAL,
        on_battery_seconds INTEGER,
        PRIMARY KEY (hour_epoch, bundle_id)
    );

    CREATE TABLE IF NOT EXISTS sleep_periods (
        sleep_start INTEGER PRIMARY KEY,
        sleep_end INTEGER
    );

    CREATE TABLE IF NOT EXISTS battery_events (
        timestamp INTEGER PRIMARY KEY,
        event_type TEXT NOT NULL,
        battery_percent INTEGER
    );

    CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT
    );
    """
}
