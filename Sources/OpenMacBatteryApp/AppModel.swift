import Foundation
import Combine
import SwiftUI
import OpenMacBatteryCore

enum TimeRange: String, CaseIterable, Identifiable {
    case h1 = "1h"
    case h6 = "6h"
    case h24 = "24h"
    case d7 = "7d"
    case d30 = "30d"

    var id: String { rawValue }
    var displayKey: String {
        switch self {
        case .h1: return "Last hour"
        case .h6: return "Last 6 hours"
        case .h24: return "Today"
        case .d7: return "This week"
        case .d30: return "This month"
        }
    }
    /// SwiftUI Text içinde otomatik localize edilir.
    var displayName: LocalizedStringKey {
        return LocalizedStringKey(displayKey)
    }
    var seconds: Int64 {
        switch self {
        case .h1: return 3600
        case .h6: return 6 * 3600
        case .h24: return 86400
        case .d7: return 7 * 86400
        case .d30: return 30 * 86400
        }
    }
    var bucketSeconds: Int {
        switch self {
        case .h1: return 60
        case .h6: return 5 * 60
        case .h24: return 10 * 60
        case .d7: return 60 * 60
        case .d30: return 4 * 60 * 60
        }
    }
}

struct TimelineSample: Identifiable {
    let id = UUID()
    let date: Date
    let energyRaw: Int64
    let cpuNs: Int64
}

struct BatterySample: Identifiable {
    let id = UUID()
    let date: Date
    let percent: Double
    let onBattery: Bool
}

struct DBStats {
    var sampleCount: Int64 = 0
    var sizeBytes: Int64 = 0
    var oldest: Date? = nil
    var newest: Date? = nil
    var calibrationFactor: Double? = nil
}

struct SleepInterval: Identifiable {
    let id = UUID()
    let start: Date
    let end: Date
}

struct HeroSummary {
    var firstPercent: Int?
    var lastPercent: Int?
    var onBatterySeconds: Int64
    var onAcSeconds: Int64
    var sleepSeconds: Int64
    var topThree: [GroupedApp]
    var totalUserEnergy: Int64

    var deltaPercent: Int? {
        guard let f = firstPercent, let l = lastPercent else { return nil }
        return l - f
    }
}

struct AppNarrative {
    let activeMinutes: Int        // ~ enerji tüketen sample sayısı * bucket dakika
    let peakHourLocal: Int?       // 0..23
    let peakDay: Date?
}

/// Önceki periyodun aynı uzunluğa göre karşılaştırması.
struct PeriodCompare {
    let currentTotalEnergy: Int64
    let previousTotalEnergy: Int64
    let hasPrevious: Bool
    /// Yüzde değişim: pozitif = arttı, negatif = azaldı. nil = baseline çok küçük.
    var deltaPercent: Double? {
        guard hasPrevious, previousTotalEnergy > 1000 else { return nil }
        let cur = Double(currentTotalEnergy)
        let prev = Double(previousTotalEnergy)
        return (cur - prev) / prev * 100.0
    }
}

/// Per-app anomali: bu periyodda enerji önceki periyodun X katından fazla mı.
struct AppAnomaly {
    let ratio: Double      // current / previous
    let label: String      // "×3 normalden çok"
}

@MainActor
final class AppModel: ObservableObject {
    @Published var range: TimeRange = .h24 { didSet { refreshNow() } }
    @Published var onBattery: Bool = false { didSet { refreshNow() } }
    @Published var showSystem: Bool = false { didSet { refreshNow() } }
    @Published var apps: [GroupedApp] = []
    @Published var totalUserEnergy: Int64 = 0
    @Published var selectedAppId: String? = nil { didSet { reloadDetail() } }
    @Published var detailTimeline: [TimelineSample] = []
    @Published var batteryTimeline: [BatterySample] = []
    @Published var sleepPeriods: [SleepInterval] = []
    @Published var sparklines: [String: [Double]] = [:]
    @Published var hero = HeroSummary(firstPercent: nil, lastPercent: nil, onBatterySeconds: 0, onAcSeconds: 0, sleepSeconds: 0, topThree: [], totalUserEnergy: 0)
    @Published var narrative: AppNarrative? = nil
    @Published var compare = PeriodCompare(currentTotalEnergy: 0, previousTotalEnergy: 0, hasPrevious: false)
    @Published var anomalies: [String: AppAnomaly] = [:]
    @Published var liveWatts: LivePowerReading? = nil
    @Published var liveAppWatts: [String: Double] = [:]   // app id → estimated W
    @Published var batterySnapshot: BatterySnapshot? = nil
    @Published var avgWatts1h: Double? = nil              // son 1 saatlik ortalama gerçek W
    @Published var stats = DBStats()
    @Published var lastRefresh: Date = Date()
    @Published var lastLiveRefresh: Date = Date()
    @Published var loading: Bool = false
    @Published var errorMessage: String? = nil

    private var refreshTimer: Timer?
    private var liveTimer: Timer?

    init() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        // Canlı watt — 15 saniyede bir yenile (kendi tüketimi düşük tutmak için)
        liveTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLiveWatts() }
        }
        refreshLiveWatts()
    }

    /// IOPS okuması ucuz; per-app dağılım için ekstra DB query açmıyoruz —
    /// mevcut `apps` state'indeki oranları kullanıyoruz. Sıfır wakeup, sıfır I/O.
    func refreshLiveWatts() {
        let reading = PowerSourceReader.liveWatts()
        self.liveWatts = reading
        if let r = reading, r.watts > 0.1, totalUserEnergy > 0 {
            var dist: [String: Double] = [:]
            for app in apps where !app.isSystem {
                let frac = Double(max(app.energyRaw, 0)) / Double(totalUserEnergy)
                dist[app.id] = frac * r.watts
            }
            self.liveAppWatts = dist
        } else {
            self.liveAppWatts = [:]
        }
        // Pil snapshot'ı + son 1 saatlik gerçek ortalama tüketim
        let snap = PowerSourceReader.batterySnapshot()
        self.batterySnapshot = snap
        if let s = snap, s.fullWh > 0 {
            if let db = try? Database(path: Database.defaultPath()) {
                let reporter = Reporter(db: db)
                let avg = try? reporter.averageBatteryWatts(rangeSec: 3600, fullWh: s.fullWh)
                self.avgWatts1h = avg?.watts
            }
        }
        self.lastLiveRefresh = Date()
    }

    func refreshNow() {
        Task { await self.reload() }
    }

    func reload() async {
        loading = true
        defer { loading = false }
        do {
            let db = try Database(path: Database.defaultPath())
            let reporter = Reporter(db: db)
            let r = DateRange.since(range.seconds)

            let rawRows = try reporter.allApps(range: r, onlyBattery: onBattery)
            let grouped = AppGrouping.group(rawRows)
            let visible = showSystem ? grouped : grouped.filter { !$0.isSystem }

            let bat = try reporter.batteryTimeline(range: r, bucketSeconds: range.bucketSeconds)
                .map { BatterySample(date: Date(timeIntervalSince1970: TimeInterval($0.bucket)),
                                     percent: $0.percent, onBattery: $0.onBattery) }
            let sleep = try reporter.sleepPeriods(range: r).map {
                SleepInterval(start: Date(timeIntervalSince1970: TimeInterval($0.start)),
                              end: Date(timeIntervalSince1970: TimeInterval($0.end)))
            }
            let bs = try reporter.batterySummary(range: r)

            // Sparkline'lar (sidebar mini grafik)
            let sparkBuckets = 32
            let sparkBucketSec = max(60, Int(range.seconds) / sparkBuckets)
            let rawSpark = try reporter.sparklineBuckets(range: r, bucketSeconds: sparkBucketSec, onlyBattery: onBattery)
            var sparkOut: [String: [Double]] = [:]
            // Tüm bucket'ları aynı X eksenine hizala
            let firstBucket = (r.from / Int64(sparkBucketSec)) * Int64(sparkBucketSec)
            let lastBucket  = (r.to   / Int64(sparkBucketSec)) * Int64(sparkBucketSec)
            let bucketCount = Int((lastBucket - firstBucket) / Int64(sparkBucketSec)) + 1
            for app in visible {
                var series = [Double](repeating: 0, count: max(1, min(bucketCount, sparkBuckets * 2)))
                for key in app.memberKeys {
                    guard let pts = rawSpark[key] else { continue }
                    for (b, e) in pts {
                        let idx = Int((b - firstBucket) / Int64(sparkBucketSec))
                        if idx >= 0 && idx < series.count {
                            series[idx] += Double(max(0, e))
                        }
                    }
                }
                sparkOut[app.id] = series
            }

            // Önceki periyot karşılaştırması — aynı uzunlukta range, daha eski
            let prevRange = DateRange(from: r.from - range.seconds, to: r.from)
            let prevByKey = (try? reporter.energyByGroupKey(range: prevRange, onlyBattery: onBattery)) ?? [:]
            let oldestSec = (try? reporter.stats().oldest) ?? nil
            let hasPrevious: Bool = {
                guard let o = oldestSec else { return false }
                // Önceki range'in çoğunu kapsayacak kadar eski veri var mı
                return o <= prevRange.from + range.seconds / 2
            }()
            let prevTotal: Int64 = visible.reduce(Int64(0)) { acc, app in
                let s = app.memberKeys.reduce(Int64(0)) { $0 + max(prevByKey[$1] ?? 0, 0) }
                return acc + s
            }
            let curTotal = visible.reduce(Int64(0)) { $0 + max($1.energyRaw, 0) }
            self.compare = PeriodCompare(currentTotalEnergy: curTotal, previousTotalEnergy: prevTotal, hasPrevious: hasPrevious)

            // Per-app anomali — current/previous oranı ≥ 2 ve previous yeterince büyükse
            var anomalies: [String: AppAnomaly] = [:]
            if hasPrevious {
                for app in visible {
                    let prevEnergy = app.memberKeys.reduce(Int64(0)) { $0 + max(prevByKey[$1] ?? 0, 0) }
                    guard prevEnergy > 10000, app.energyRaw > prevEnergy * 2 else { continue }
                    let ratio = Double(app.energyRaw) / Double(prevEnergy)
                    anomalies[app.id] = AppAnomaly(
                        ratio: ratio,
                        label: ratio >= 10 ? "×10+ normalden" : String(format: "×%.0f normalden", ratio)
                    )
                }
            }
            self.anomalies = anomalies

            let st = try reporter.stats()

            self.apps = visible
            self.totalUserEnergy = visible.reduce(Int64(0)) { $0 + max($1.energyRaw, 0) }
            self.batteryTimeline = bat
            self.sleepPeriods = sleep
            self.sparklines = sparkOut
            self.hero = HeroSummary(
                firstPercent: bs.firstPercent,
                lastPercent: bs.lastPercent,
                onBatterySeconds: bs.onBatterySeconds,
                onAcSeconds: bs.onAcSeconds,
                sleepSeconds: bs.sleepSeconds,
                topThree: Array(visible.prefix(3)),
                totalUserEnergy: visible.reduce(Int64(0)) { $0 + max($1.energyRaw, 0) }
            )
            self.stats = DBStats(
                sampleCount: st.sampleCount,
                sizeBytes: st.dbBytes,
                oldest: st.oldest.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                newest: st.newest.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                calibrationFactor: st.calibrationFactor
            )
            self.lastRefresh = Date()
            self.errorMessage = nil

            if let sel = selectedAppId, !visible.contains(where: { $0.id == sel }) {
                selectedAppId = visible.first?.id
            } else if selectedAppId == nil {
                selectedAppId = visible.first?.id
            } else {
                reloadDetail()
            }
        } catch {
            self.errorMessage = "Veri okunamadı: \(error)"
        }
    }

    private func reloadDetail() {
        guard let id = selectedAppId,
              let app = apps.first(where: { $0.id == id }) else {
            self.detailTimeline = []
            return
        }
        Task { await self.loadDetail(app: app) }
    }

    private func loadDetail(app: GroupedApp) async {
        do {
            let db = try Database(path: Database.defaultPath())
            let reporter = Reporter(db: db)
            let r = DateRange.since(range.seconds)
            let pts = try reporter.appTimelineMulti(groupKeys: app.memberKeys, range: r, bucketSeconds: range.bucketSeconds)
                .map { TimelineSample(date: Date(timeIntervalSince1970: TimeInterval($0.bucket)),
                                      energyRaw: $0.energyRaw, cpuNs: $0.cpuNs) }
            self.detailTimeline = pts
            self.narrative = computeNarrative(samples: pts, bucketSec: range.bucketSeconds)
        } catch {
            self.errorMessage = "Detay okunamadı: \(error)"
        }
    }

    private func computeNarrative(samples: [TimelineSample], bucketSec: Int) -> AppNarrative? {
        guard !samples.isEmpty else { return nil }
        // Aktif bucket: enerji veya cpu>0 olanlar
        let activeBuckets = samples.filter { $0.energyRaw > 0 || $0.cpuNs > 0 }
        let activeMinutes = (activeBuckets.count * bucketSec) / 60

        // En yüksek enerjili bucket (peak)
        let peakSample = samples.max(by: { $0.energyRaw < $1.energyRaw })
        var peakHour: Int? = nil
        var peakDay: Date? = nil
        if let peakSample, peakSample.energyRaw > 0 {
            peakHour = Calendar.current.component(.hour, from: peakSample.date)
            peakDay = Calendar.current.startOfDay(for: peakSample.date)
        }
        return AppNarrative(activeMinutes: activeMinutes, peakHourLocal: peakHour, peakDay: peakDay)
    }

    /// Yüzde — atomik, app içine gömülü; race-free.
    func sharePercent(of app: GroupedApp) -> Double {
        return app.sharePercent
    }
}
