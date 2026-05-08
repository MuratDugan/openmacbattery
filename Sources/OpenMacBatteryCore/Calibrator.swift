import Foundation

/// Powermetrics ile cross-check kalibrasyonu.
///
/// Yaklaşım:
/// 1. Tüm process'lerin baseline rusage snapshot'ı
/// 2. `sudo powermetrics --format plist -i <ms> -n <N>` çalıştır
/// 3. Her plist sample'da toplam paket gücünü oku (mW)
/// 4. Süre sonunda yeni rusage snapshot al, billed_energy delta'ları topla
/// 5. factor = total_joules / total_raw_delta  (J / raw_unit)
///
/// Bu yöntem absolute J/raw faktörünü ampirik bulur. Ne kadar yük varsa o kadar doğru.
public struct CalibrationResult {
    public let factor: Double           // J / raw_unit
    public let totalJoules: Double      // ölçülen toplam paket enerjisi
    public let totalRawDelta: UInt64    // tüm process'lerin billed_energy delta toplamı
    public let durationSec: Double
    public let plistSampleCount: Int
}

public enum CalibrationError: Error, CustomStringConvertible {
    case powermetricsLaunch(String)
    case powermetricsExit(Int32, String)
    case parse(String)
    case insufficientLoad(String)

    public var description: String {
        switch self {
        case .powermetricsLaunch(let m): return "powermetrics launch failed: \(m)"
        case .powermetricsExit(let c, let s): return "powermetrics exited \(c): \(s)"
        case .parse(let m): return "parse failed: \(m)"
        case .insufficientLoad(let m): return "calibration unreliable: \(m)"
        }
    }
}

public enum Calibrator {
    /// duration: toplam ölçüm saniyesi. intervalMs: powermetrics sample aralığı (ms).
    public static func run(durationSec: Int, intervalMs: Int = 5000) throws -> CalibrationResult {
        let n = max(1, (durationSec * 1000) / intervalMs)

        // 1. Baseline rusage snapshot
        let baseline = snapshotRusages()

        // 2. powermetrics çalıştır (sudo gerek)
        let pm = Process()
        pm.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        pm.arguments = [
            "/usr/bin/powermetrics",
            "--samplers", "cpu_power",
            "--format", "plist",
            "-i", String(intervalMs),
            "-n", String(n)
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        pm.standardOutput = stdout
        pm.standardError = stderr

        let t0 = Date()
        do { try pm.run() }
        catch { throw CalibrationError.powermetricsLaunch("\(error)") }
        pm.waitUntilExit()
        let elapsed = Date().timeIntervalSince(t0)

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        if pm.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8) ?? ""
            throw CalibrationError.powermetricsExit(pm.terminationStatus, msg)
        }

        // 3. Birden fazla plist document peş peşe; her biri NUL byte ile ayrılmış olabilir.
        let samples = try parsePlistStream(data: outData)
        guard !samples.isEmpty else {
            throw CalibrationError.parse("no plist samples in powermetrics output")
        }

        // 4. Her sample'da package power'ı oku (mW), süreyle çarpıp joule yap
        var totalJoules: Double = 0
        var sampleCount = 0
        for sample in samples {
            // Apple Silicon: "package_joules" mevcut olabilir, yoksa elapsed_ns + combined_power
            if let elapsedNs = sample["elapsed_ns"] as? UInt64 {
                let durSec = Double(elapsedNs) / 1_000_000_000.0
                if let pkgJ = sample["package_joules"] as? Double {
                    totalJoules += pkgJ
                    sampleCount += 1
                    continue
                }
                // Fallback: combined_power (mW) × duration
                if let mw = sample["combined_power"] as? Double {
                    totalJoules += (mw / 1000.0) * durSec
                    sampleCount += 1
                    continue
                }
                // processor.package_watts × elapsed
                if let proc = sample["processor"] as? [String: Any],
                   let watts = proc["package_watts"] as? Double {
                    totalJoules += watts * durSec
                    sampleCount += 1
                    continue
                }
            }
        }

        if totalJoules <= 0 {
            throw CalibrationError.parse("no usable power readings in plist (keys: \(samples.first?.keys.joined(separator: ",") ?? "—"))")
        }

        // 5. Final rusage snapshot, delta hesapla
        let final = snapshotRusages()
        var totalRawDelta: UInt64 = 0
        for (key, finalEnergy) in final {
            if let baseEnergy = baseline[key], finalEnergy >= baseEnergy {
                totalRawDelta &+= (finalEnergy - baseEnergy)
            }
        }

        guard totalRawDelta > 1000 else {
            throw CalibrationError.insufficientLoad("rusage delta sum too small (\(totalRawDelta)); run a CPU workload during calibration")
        }

        let factor = totalJoules / Double(totalRawDelta)
        return CalibrationResult(
            factor: factor,
            totalJoules: totalJoules,
            totalRawDelta: totalRawDelta,
            durationSec: elapsed,
            plistSampleCount: sampleCount
        )
    }

    // MARK: - Helpers

    /// Tüm okunabilir process'lerin (pid,start) → billed_energy ham değeri haritası.
    private static func snapshotRusages() -> [ProcessKey: UInt64] {
        var out: [ProcessKey: UInt64] = [:]
        for pid in ProcessInfoReader.listAllPids() {
            guard let id = ProcessInfoReader.identity(pid: pid) else { continue }
            guard let r = ProcessInfoReader.rusage(pid: pid) else { continue }
            out[ProcessKey(pid: pid, startTvSec: id.startTvSec)] = r.billedEnergy
        }
        return out
    }

    /// powermetrics --format plist çıktısını parse et — birden fazla plist arka arkaya gelir.
    private static func parsePlistStream(data: Data) throws -> [[String: Any]] {
        // powermetrics multi-plist çıktısı NUL byte (0x00) ile ayrılır.
        var results: [[String: Any]] = []
        var current = Data()
        for byte in data {
            if byte == 0x00 {
                if !current.isEmpty {
                    if let plist = try? PropertyListSerialization.propertyList(from: current, format: nil) as? [String: Any] {
                        results.append(plist)
                    }
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty {
            if let plist = try? PropertyListSerialization.propertyList(from: current, format: nil) as? [String: Any] {
                results.append(plist)
            }
        }
        return results
    }
}
