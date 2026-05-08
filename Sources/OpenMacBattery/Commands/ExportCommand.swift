import ArgumentParser
import Foundation
import OpenMacBatteryCore

struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export raw samples to CSV or JSON"
    )

    enum Format: String, ExpressibleByArgument { case csv, json }

    @Option(name: .long) var format: Format = .csv
    @Option(name: .long) var since: String = "7d"
    @Option(name: .long, help: "Filter by bundle id or display name substring") var app: String?

    func run() throws {
        let db = try openDatabase()
        let secs = try DurationParser.parse(since)
        let from = Int64(Date().timeIntervalSince1970) - secs

        var sql = """
        SELECT timestamp, pid, bundle_id, display_name,
               cpu_user_ns, cpu_system_ns,
               energy_billed_raw, energy_serviced_raw,
               pkg_idle_wakeups, interrupt_wakeups,
               disk_read_bytes, disk_write_bytes,
               is_on_battery, battery_percent, rusage_version
        FROM samples WHERE timestamp >= ?
        """
        if app != nil {
            sql += " AND (bundle_id = ? OR display_name LIKE ?)"
        }
        sql += " ORDER BY timestamp ASC;"

        let stmt = try db.prepare(sql)
        defer { stmt.finalize() }
        try stmt.bind(1, from)
        if let a = app {
            try stmt.bind(2, a)
            try stmt.bind(3, "%\(a)%")
        }

        switch format {
        case .csv:
            print("timestamp,pid,bundle_id,display_name,cpu_user_ns,cpu_system_ns,energy_billed_raw,energy_serviced_raw,pkg_idle_wakeups,interrupt_wakeups,disk_read_bytes,disk_write_bytes,is_on_battery,battery_percent,rusage_version")
            while stmt.step() {
                let cols: [String] = [
                    String(stmt.int64(0)),
                    String(stmt.int64(1)),
                    csvEsc(stmt.string(2)),
                    csvEsc(stmt.string(3)),
                    String(stmt.int64(4)),
                    String(stmt.int64(5)),
                    stmt.isNull(6) ? "" : String(stmt.int64(6)),
                    stmt.isNull(7) ? "" : String(stmt.int64(7)),
                    String(stmt.int64(8)),
                    String(stmt.int64(9)),
                    String(stmt.int64(10)),
                    String(stmt.int64(11)),
                    String(stmt.int64(12)),
                    stmt.isNull(13) ? "" : String(stmt.int64(13)),
                    String(stmt.int64(14)),
                ]
                print(cols.joined(separator: ","))
            }
        case .json:
            print("[")
            var first = true
            while stmt.step() {
                if !first { print(",") }
                first = false
                let energy = stmt.isNull(6) ? "null" : "\(stmt.int64(6))"
                let serviced = stmt.isNull(7) ? "null" : "\(stmt.int64(7))"
                let bp = stmt.isNull(13) ? "null" : "\(stmt.int64(13))"
                let row = """
                {"timestamp":\(stmt.int64(0)),"pid":\(stmt.int64(1)),"bundle_id":\(jsonStr(stmt.string(2))),"display_name":\(jsonStr(stmt.string(3))),"cpu_user_ns":\(stmt.int64(4)),"cpu_system_ns":\(stmt.int64(5)),"energy_billed_raw":\(energy),"energy_serviced_raw":\(serviced),"pkg_idle_wakeups":\(stmt.int64(8)),"interrupt_wakeups":\(stmt.int64(9)),"disk_read_bytes":\(stmt.int64(10)),"disk_write_bytes":\(stmt.int64(11)),"is_on_battery":\(stmt.int64(12)),"battery_percent":\(bp),"rusage_version":\(stmt.int64(14))}
                """
                print(row, terminator: "")
            }
            print("\n]")
        }
    }

    private func csvEsc(_ s: String?) -> String {
        guard let s else { return "" }
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
    private func jsonStr(_ s: String?) -> String {
        guard let s else { return "null" }
        let esc = s.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"")
                   .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(esc)\""
    }
}
