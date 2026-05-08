import Foundation
import CProcInfo

public struct ProcRusage {
    public let userTimeNs: UInt64
    public let systemTimeNs: UInt64
    public let pkgIdleWakeups: UInt64
    public let interruptWakeups: UInt64
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    public let billedEnergy: UInt64
    public let servicedEnergy: UInt64
    public let runnableTimeNs: UInt64
    public let rusageVersion: Int  // 4 veya 6, 0 = fail
}

public struct ProcIdentity {
    public let pid: pid_t
    public let startTvSec: UInt64
    public let startTvUsec: UInt64
    public let ppid: pid_t
    public let uid: UInt32
}

public enum ProcessInfoReader {
    /// Tüm PID listesini al.
    public static func listAllPids() -> [pid_t] {
        // Önce kapasite öğren
        let count = bt_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Buffer biraz fazla tut, process'ler doğabilir
        let cap = Int(count) + 64
        var buffer = [pid_t](repeating: 0, count: cap)
        let written = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            bt_listallpids(ptr.baseAddress, Int32(cap))
        }
        guard written > 0 else { return [] }
        // proc_listallpids dönüş değeri yazılan toplam byte değil, yazılan PID sayısı (Apple docs).
        // Buffer'ı written'a göre kırp.
        let n = Int(written) / MemoryLayout<pid_t>.size
        let actual = min(n > 0 ? n : Int(written), cap)
        return Array(buffer.prefix(actual)).filter { $0 > 0 }
    }

    public static func rusage(pid: pid_t) -> ProcRusage? {
        let r = bt_proc_rusage(pid)
        guard r.ok == 1 else { return nil }
        return ProcRusage(
            userTimeNs: r.user_time_ns,
            systemTimeNs: r.system_time_ns,
            pkgIdleWakeups: r.pkg_idle_wakeups,
            interruptWakeups: r.interrupt_wakeups,
            diskReadBytes: r.diskio_bytesread,
            diskWriteBytes: r.diskio_byteswritten,
            billedEnergy: r.billed_energy,
            servicedEnergy: r.serviced_energy,
            runnableTimeNs: r.runnable_time_ns,
            rusageVersion: Int(r.version)
        )
    }

    public static func identity(pid: pid_t) -> ProcIdentity? {
        let info = bt_proc_bsdinfo(pid)
        guard info.ok == 1 else { return nil }
        return ProcIdentity(
            pid: pid,
            startTvSec: info.start_tvsec,
            startTvUsec: info.start_tvusec,
            ppid: pid_t(info.ppid),
            uid: info.uid
        )
    }

    public static func execPath(pid: pid_t) -> String? {
        let cap = 4096
        var buf = [CChar](repeating: 0, count: cap)
        let written = buf.withUnsafeMutableBufferPointer { ptr -> Int32 in
            bt_proc_path(pid, ptr.baseAddress, Int32(cap))
        }
        guard written > 0 else { return nil }
        return String(cString: buf)
    }

    public static var lastErrno: Int32 { bt_errno() }
}
