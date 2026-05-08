import SwiftUI
import Charts
import AppKit
import OpenMacBatteryCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
        } detail: {
            DetailView()
        }
        .toolbar { MainToolbar(model: model) }
        .navigationTitle("OpenMacBattery")
    }
}

// MARK: - Toolbar

struct MainToolbar: ToolbarContent {
    @ObservedObject var model: AppModel
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("Range", selection: $model.range) {
                ForEach(TimeRange.allCases, id: \.self) { r in
                    Text(r.displayName).tag(r)
                }
            }
            .pickerStyle(.menu)
        }
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $model.onBattery) {
                Label(model.onBattery ? "On battery only" : "All measurements",
                      systemImage: model.onBattery ? "battery.75percent" : "powerplug")
                    .labelStyle(.titleAndIcon)
            }
            .toggleStyle(.button)
            .help(model.onBattery
                  ? "Showing measurements taken while on battery — click to include all"
                  : "Showing all measurements — click to filter to battery only")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Toggle("Show system services", isOn: $model.showSystem)
                Divider()
                Button("Settings…") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help("Display options and settings")
        }
        ToolbarItem(placement: .primaryAction) {
            BatteryDetailsToolbarButton(model: model)
        }
        ToolbarItem(placement: .primaryAction) {
            RefreshRingButton(model: model, cycleSec: 15)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(format: NSLocalizedString("%lld apps", comment: ""), model.apps.count))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(model.range.displayName).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()

            if model.apps.isEmpty {
                EmptySidebar()
            } else {
                List(selection: $model.selectedAppId) {
                    ForEach(model.apps) { app in
                        AppRowView(app: app,
                                   percent: model.sharePercent(of: app),
                                   sparkline: model.sparklines[app.id] ?? [],
                                   anomaly: model.anomalies[app.id])
                            .tag(app.id)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            StatsFooter()
        }
    }
}

struct EmptySidebar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "hourglass").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("Collecting data")
                .font(.headline)
            Text("OpenMacBattery is monitoring your apps in the background. First measurements will arrive within 1-2 minutes.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            if model.stats.sampleCount > 0 {
                Text(String(format: NSLocalizedString("%lld samples so far", comment: ""), model.stats.sampleCount))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct BatteryDetailsToolbarButton: View {
    @ObservedObject var model: AppModel
    @State private var showPopover: Bool = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                if let s = model.batterySnapshot {
                    Text("\(s.percent)%")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .help("Battery details (⌥⌘B)")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            BatteryDetailsView(compact: true)
                .environmentObject(model)
        }
    }

    private var iconName: String {
        guard let s = model.batterySnapshot else { return "battery.0" }
        if s.isCharging { return "battery.100.bolt" }
        if s.percent >= 75 { return "battery.100" }
        if s.percent >= 50 { return "battery.75" }
        if s.percent >= 25 { return "battery.50" }
        if s.percent >= 10 { return "battery.25" }
        return "battery.0"
    }
    private var iconColor: Color {
        guard let s = model.batterySnapshot else { return .secondary }
        if s.isCharging { return .blue }
        if s.percent <= 10 { return .red }
        if s.percent <= 25 { return .orange }
        return .primary
    }
}

struct AppRowView: View {
    let app: GroupedApp
    let percent: Double
    let sparkline: [Double]
    let anomaly: AppAnomaly?

    @State private var showForceQuitConfirm: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.shared.icon(forAppPath: app.parentAppPath))
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(app.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let an = anomaly {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 10))
                            .help(String(format: NSLocalizedString("%@ is consuming %@ battery", comment: ""), app.displayName, an.label))
                    }
                }
                HStack(spacing: 6) {
                    EnergyBadge(level: app.level)
                    Text(percent < 0.1 ? "<0.1%" : String(format: "%.1f%%", percent))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let an = anomaly {
                        Text(an.label)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    if app.isSystem {
                        Text("system")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).stroke(.secondary, lineWidth: 0.5))
                    }
                }
            }
            Spacer(minLength: 6)
            Sparkline(values: sparkline, color: Color(app.level.color))
                .frame(width: 56, height: 22)
        }
        .padding(.vertical, 3)
        .contextMenu {
            if AppActions.canQuit(app) {
                Button {
                    AppActions.quit(app: app, force: false)
                } label: {
                    Label(String(format: NSLocalizedString("Quit %@", comment: ""), app.displayName), systemImage: "xmark.circle")
                }
                Button(role: .destructive) {
                    showForceQuitConfirm = true
                } label: {
                    Label("Force Quit", systemImage: "bolt.slash")
                }
                Divider()
            } else {
                Text(app.isSystem ? "System services cannot be quit from here" : "No running instance found")
                    .foregroundStyle(.secondary)
                Divider()
            }
            Button {
                AppActions.openInActivityMonitor()
            } label: {
                Label("Open in Activity Monitor", systemImage: "speedometer")
            }
            if let path = app.parentAppPath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
        }
        .alert(String(format: NSLocalizedString("Force Quit %@?", comment: ""), app.displayName), isPresented: $showForceQuitConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Force Quit", role: .destructive) {
                AppActions.quit(app: app, force: true)
            }
        } message: {
            Text("Unsaved changes may be lost.")
        }
    }
}

enum AppActions {
    static func canQuit(_ app: GroupedApp) -> Bool {
        guard !app.isSystem, let bid = app.bundleId else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty
    }

    static func quit(app: GroupedApp, force: Bool) {
        guard let bid = app.bundleId else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        for r in running {
            if force { _ = r.forceTerminate() } else { _ = r.terminate() }
        }
    }

    static func openInActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.open(url)
    }
}

struct Sparkline: View {
    let values: [Double]
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 0, 1)
            let n = max(values.count, 1)
            let stepX = geo.size.width / CGFloat(max(n - 1, 1))
            Path { path in
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = geo.size.height - CGFloat(v / maxV) * geo.size.height
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            Path { path in
                guard !values.isEmpty else { return }
                path.move(to: CGPoint(x: 0, y: geo.size.height))
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * stepX
                    let y = geo.size.height - CGFloat(v / maxV) * geo.size.height
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                path.closeSubpath()
            }
            .fill(color.opacity(0.18))
        }
    }
}

struct EnergyBadge: View {
    let level: EnergyLevel
    var body: some View {
        Text(LocalizedStringKey(level.rawValue))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(level.color)))
    }
}

struct BarIndicator: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
                    .frame(width: geo.size.width * min(1.0, max(0, fraction)))
            }
        }
    }
}

struct StatsFooter: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if let n = model.stats.newest {
                    Text(String(format: NSLocalizedString("Last sample %@", comment: ""), relativeTime(n)))
                        .font(.caption2)
                        .foregroundStyle(timeSinceLast(n) < 180 ? .green : .orange)
                    Circle()
                        .fill(timeSinceLast(n) < 180 ? .green : .orange)
                        .frame(width: 6, height: 6)
                } else {
                    Text("No measurements yet")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(String(format: NSLocalizedString("refreshed %@", comment: ""), relativeTime(model.lastRefresh)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let err = model.errorMessage {
                Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func timeSinceLast(_ d: Date) -> TimeInterval { Date().timeIntervalSince(d) }
    private func relativeTime(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Detail

struct DetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.apps.isEmpty {
            EmptyDetailView()
        } else if let id = model.selectedAppId,
                  let app = model.apps.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LiveWattCard()
                    BatteryLifeCard()
                    HeroCard()
                    CompareCard()
                    OnBatteryTipCard(app: app)
                    AppHeader(app: app)
                    SummaryCards(app: app)
                    NarrativeCard(app: app)
                    EnergyTimelineCard()
                    BatteryTimelineCard()
                    TopBarCard()
                }
                .padding(20)
            }
        } else {
            EmptyDetailView()
        }
    }
}

struct LiveWattCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let r = model.liveWatts {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(color.opacity(0.25), lineWidth: 4)
                        .frame(width: 56, height: 56)
                    Circle()
                        .trim(from: 0, to: min(1.0, r.watts / 30.0))
                        .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 56, height: 56)
                    VStack(spacing: 0) {
                        Text(String(format: "%.1f", r.watts))
                            .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        Text("W").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.headline)
                    Text(subtext).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !top3.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(top3, id: \.0) { (id, name, w) in
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(name).font(.caption2).lineLimit(1).frame(maxWidth: 100, alignment: .trailing)
                                Text(String(format: "≈%.1f W", w))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(color)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        }
    }

    private var color: Color {
        guard let r = model.liveWatts else { return .accentColor }
        if r.isCharging { return .blue }
        if r.watts > 15 { return .red }
        if r.watts > 7 { return .orange }
        return .green
    }
    private var headline: String {
        guard let r = model.liveWatts else { return "" }
        let watts = String(format: "%.1f", r.watts)
        if r.isCharging {
            return String(format: NSLocalizedString("Charging now (~%@ W in)", comment: ""), watts)
        }
        return String(format: NSLocalizedString("Drawing now: %@ watts", comment: ""), watts)
    }
    private var subtext: String {
        guard let r = model.liveWatts else { return "" }
        return "\(r.amperage_mA) mA · \(String(format: "%.2f", Double(r.voltage_mV)/1000)) V"
    }
    private var top3: [(String, String, Double)] {
        let sorted = model.liveAppWatts
            .filter { $0.value >= 0.1 }
            .sorted(by: { $0.value > $1.value })
            .prefix(3)
        return sorted.compactMap { (id, w) in
            guard let app = model.apps.first(where: { $0.id == id }) else { return nil }
            return (id, app.displayName, w)
        }
    }
}

struct BatteryLifeCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let snap = model.batterySnapshot {
            HStack(spacing: 16) {
                BatteryGlyph(percent: snap.percent, isCharging: snap.isCharging || snap.externalConnected)
                    .frame(width: 56, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(headline(snap: snap))
                        .font(.system(size: 14, weight: .semibold))
                    if let sub = subtext(snap: snap) {
                        Text(sub).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Capacity").font(.caption2).foregroundStyle(.secondary)
                        Text("\(snap.currentCapacity_mAh) / \(snap.maxCapacity_mAh) mAh")
                            .font(.system(.caption2, design: .monospaced))
                    }
                    if snap.healthPercent < 100 {
                        HStack(spacing: 4) {
                            Text("Health").font(.caption2).foregroundStyle(.secondary)
                            Text("\(snap.healthPercent)% · \(snap.cycleCount) cycles")
                                .font(.system(.caption2, design: .monospaced))
                        }
                    } else {
                        HStack(spacing: 4) {
                            Text("Cycles").font(.caption2).foregroundStyle(.secondary)
                            Text("\(snap.cycleCount)").font(.system(.caption2, design: .monospaced))
                        }
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        }
    }

    private func headline(snap: BatterySnapshot) -> String {
        if snap.isCharging {
            if let m = snap.macOsTimeRemainingMin, m > 0 {
                return String(format: NSLocalizedString("%lld%% · charging — full in %@", comment: ""), snap.percent, formatMinutes(m))
            }
            return String(format: NSLocalizedString("%lld%% · charging", comment: ""), snap.percent)
        }
        if snap.externalConnected {
            return String(format: NSLocalizedString("%lld%% · plugged in (not charging)", comment: ""), snap.percent)
        }
        let ourEstimateMin: Int?
        if let w = model.avgWatts1h, w > 0.5 {
            let hours = snap.remainingWh / w
            ourEstimateMin = Int(hours * 60)
        } else if let live = model.liveWatts, live.watts > 0.5, !live.isCharging {
            let hours = snap.remainingWh / live.watts
            ourEstimateMin = Int(hours * 60)
        } else {
            ourEstimateMin = nil
        }
        if let m = ourEstimateMin {
            return String(format: NSLocalizedString("%lld%% · ~%@ of battery left", comment: ""), snap.percent, formatMinutes(m))
        }
        return String(format: NSLocalizedString("%lld%% · on battery", comment: ""), snap.percent)
    }

    private func subtext(snap: BatterySnapshot) -> String? {
        var parts: [String] = []
        if !snap.isCharging, let w = model.avgWatts1h {
            parts.append(String(format: NSLocalizedString("Last hour avg: %.1f W", comment: ""), w))
        }
        if !snap.isCharging, let m = snap.macOsTimeRemainingMin, m > 0 {
            parts.append(String(format: NSLocalizedString("macOS estimate: %@", comment: ""), formatMinutes(m)))
        }
        parts.append("\(String(format: "%.1f", snap.remainingWh)) / \(String(format: "%.1f", snap.fullWh)) Wh")
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func formatMinutes(_ min: Int) -> String {
        let h = min / 60
        let m = min % 60
        if h > 0 {
            return String(format: NSLocalizedString("%d h %d min", comment: ""), h, m)
        }
        return String(format: NSLocalizedString("%d min", comment: ""), m)
    }
}

struct BatteryGlyph: View {
    let percent: Int
    let isCharging: Bool

    var body: some View {
        GeometryReader { geo in
            let bodyWidth = geo.size.width * 0.88
            let tipWidth = geo.size.width * 0.07
            let tipGap = geo.size.width * 0.02

            ZStack(alignment: .leading) {
                HStack(spacing: tipGap) {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary, lineWidth: 1.5)
                        .frame(width: bodyWidth)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.secondary)
                        .frame(width: tipWidth, height: geo.size.height * 0.45)
                }
                RoundedRectangle(cornerRadius: 2)
                    .fill(fillColor)
                    .frame(width: max(0, (bodyWidth - 4) * CGFloat(percent) / 100), height: geo.size.height - 6)
                    .padding(2)
                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: bodyWidth)
                }
            }
        }
    }

    private var fillColor: Color {
        if isCharging { return .blue }
        if percent <= 10 { return .red }
        if percent <= 25 { return .orange }
        return .green
    }
}

struct HeroCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(headline)
                .font(.title2).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            if !model.hero.topThree.isEmpty {
                HStack(spacing: 12) {
                    ForEach(model.hero.topThree, id: \.id) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: IconCache.shared.icon(forAppPath: app.parentAppPath))
                                .resizable().frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(app.displayName).font(.caption).lineLimit(1)
                                Text(String(format: "%.0f%%", model.sharePercent(of: app)))
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.background.tertiary))
                    }
                    Spacer()
                }
            }
            Text(subtext)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.04)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var headline: String {
        let h = model.hero
        let range = NSLocalizedString(model.range.displayKey, comment: "")
        if let delta = h.deltaPercent, delta < 0, h.onBatterySeconds > 0 {
            if let first = h.topThree.first {
                let p = Int(model.sharePercent(of: first).rounded())
                return String(format: NSLocalizedString("%@: battery dropped %lld%% — mainly %@ (%lld%%)", comment: ""), range, -delta, first.displayName, p)
            }
            return String(format: NSLocalizedString("%@: battery dropped %lld%%", comment: ""), range, -delta)
        }
        if h.onBatterySeconds == 0 && h.onAcSeconds > 0 {
            return String(format: NSLocalizedString("%@: plugged in the whole time — no battery use", comment: ""), range)
        }
        if let first = h.topThree.first {
            let p = Int(model.sharePercent(of: first).rounded())
            return String(format: NSLocalizedString("%@: top consumer was %@ (%lld%%)", comment: ""), range, first.displayName, p)
        }
        return String(format: NSLocalizedString("%@: not enough data yet", comment: ""), range)
    }

    private var subtext: String {
        let h = model.hero
        var parts: [String] = []
        if h.onBatterySeconds > 0 {
            parts.append(String(format: NSLocalizedString("on battery for %@", comment: ""), formatDuration(h.onBatterySeconds)))
        }
        if h.onAcSeconds > 0 {
            parts.append(String(format: NSLocalizedString("plugged in for %@", comment: ""), formatDuration(h.onAcSeconds)))
        }
        if h.sleepSeconds > 60 {
            parts.append(String(format: NSLocalizedString("asleep for %@", comment: ""), formatDuration(h.sleepSeconds)))
        }
        if let f = h.firstPercent, let l = h.lastPercent {
            parts.append(String(format: NSLocalizedString("battery %lld%% → %lld%%", comment: ""), f, l))
        }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private func formatDuration(_ sec: Int64) -> String {
        let h = sec / 3600
        let m = (sec % 3600) / 60
        if h > 0 {
            return String(format: NSLocalizedString("%dh %dm", comment: ""), h, m)
        }
        return String(format: NSLocalizedString("%dm", comment: ""), m)
    }
}

struct CompareCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let delta = model.compare.deltaPercent {
            HStack(spacing: 12) {
                Image(systemName: delta < 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(delta < 0 ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(delta: delta))
                        .font(.system(size: 13, weight: .medium))
                    Text(String(format: NSLocalizedString("Compared to the previous %@", comment: ""), NSLocalizedString(model.range.displayKey, comment: "")))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
        } else if !model.compare.hasPrevious && model.stats.sampleCount > 0 {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock")
                    .font(.title3).foregroundStyle(.secondary)
                Text("Need a bit more data to compare with previous period")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary.opacity(0.5)))
        }
    }
    private func headline(delta: Double) -> String {
        let absVal = Int(delta.magnitude.rounded())
        let cmp = NSLocalizedString(model.range.displayKey, comment: "")
        if delta < -5 {
            return String(format: NSLocalizedString("%lld%% less battery used than the previous %@", comment: ""), absVal, cmp)
        }
        if delta > 5 {
            return String(format: NSLocalizedString("%lld%% more battery used than the previous %@", comment: ""), absVal, cmp)
        }
        return String(format: NSLocalizedString("Similar to the previous %@ (%lld%% difference)", comment: ""), cmp, absVal)
    }
}

struct OnBatteryTipCard: View {
    let app: GroupedApp
    @EnvironmentObject var model: AppModel
    var body: some View {
        if shouldShow {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.system(size: 13, weight: .semibold))
                    Text("If it doesn't need to run in the background while on battery, consider quitting it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.orange.opacity(0.4), lineWidth: 0.5)
            )
        }
    }
    private var isOnBatteryNow: Bool {
        guard let recent = model.batteryTimeline.last else { return false }
        return recent.onBattery
    }
    private var shouldShow: Bool {
        guard isOnBatteryNow else { return false }
        return app.level == .high && !app.isSystem
    }
    private var headline: String {
        let p = Int(model.sharePercent(of: app).rounded())
        return String(format: NSLocalizedString("You're on battery — %@ is using %lld%% of your battery load", comment: ""), app.displayName, p)
    }
}

struct NarrativeCard: View {
    let app: GroupedApp
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let n = model.narrative, n.activeMinutes > 0 {
            HStack(spacing: 12) {
                Image(systemName: "clock.badge.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(activeText(n: n))
                        .font(.system(size: 13, weight: .medium))
                    if let h = n.peakHourLocal {
                        Text(peakText(hour: h))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
        }
    }

    private func activeText(n: AppNarrative) -> String {
        let mins = n.activeMinutes
        if mins >= 60 {
            let h = mins / 60; let m = mins % 60
            return String(format: NSLocalizedString("%@ was active for %lld hours %lld minutes", comment: ""), app.displayName, h, m)
        }
        return String(format: NSLocalizedString("%@ was active for %lld minutes", comment: ""), app.displayName, mins)
    }
    private func peakText(hour: Int) -> String {
        let hourStr = String(format: "%02d:00", hour)
        return String(format: NSLocalizedString("Peak hour: around %@", comment: ""), hourStr)
    }
}

struct EmptyDetailView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: model.stats.sampleCount == 0 ? "hourglass" : "magnifyingglass")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            if model.stats.sampleCount == 0 {
                Text("Collecting data").font(.title2)
                Text("OpenMacBattery just started. The daemon is checking all apps every minute in the background — charts will fill in within a few minutes.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480)
            } else {
                Text("Nothing to show in this range").font(.title2)
                Text("Try a different time range from the toolbar.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppHeader: View {
    let app: GroupedApp
    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: IconCache.shared.icon(forAppPath: app.parentAppPath))
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(app.displayName).font(.title2).fontWeight(.semibold)
                    if app.isSystem {
                        Text("System").font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).stroke(.secondary, lineWidth: 0.5))
                    }
                }
                Text(app.bundleId ?? app.parentAppPath ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct SummaryCards: View {
    let app: GroupedApp
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            StatCard(label: "Battery share", value: shareString, accent: Color(app.level.color))
            StatCard(label: "CPU time", value: EnergyFormatter.formatCpuNs(app.cpuNs))
            StatCard(label: "Wakeups", value: EnergyFormatter.formatCount(app.wakeups))
            StatCard(label: "Range", value: rangeText)
        }
    }
    private var shareString: String {
        let p = model.sharePercent(of: app)
        if p < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", p)
    }
    private var rangeText: String {
        NSLocalizedString(model.range.displayKey, comment: "")
    }
}

struct StatCard: View {
    let label: LocalizedStringKey
    let value: String
    var accent: Color = .accentColor
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).fontWeight(.medium).monospacedDigit()
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
    }
}

struct EnergyTimelineCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card(title: "Consumption over time") {
            if model.detailTimeline.isEmpty {
                Text("No data in this range.")
                    .foregroundStyle(.secondary)
                    .frame(height: 200)
            } else {
                Chart {
                    ForEach(model.detailTimeline) { p in
                        BarMark(
                            x: .value("Time", p.date),
                            y: .value("Consumption", Double(max(p.energyRaw, 0)))
                        )
                        .foregroundStyle(Color.accentColor)
                    }
                }
                .chartXScale(domain: rangeStart ... rangeEnd)
                .frame(height: 220)
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine()
                    }
                }
            }
        }
    }
    private var rangeEnd: Date { Date() }
    private var rangeStart: Date { Date().addingTimeInterval(-Double(model.range.seconds)) }
}

struct BatteryTimelineCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card(title: "Battery level") {
            if model.batteryTimeline.isEmpty {
                Text("No battery readings.")
                    .foregroundStyle(.secondary)
                    .frame(height: 120)
            } else {
                Chart {
                    ForEach(model.sleepPeriods) { sleep in
                        RectangleMark(
                            xStart: .value("Sleep start", sleep.start),
                            xEnd: .value("Sleep end", sleep.end),
                            yStart: .value("min", 0),
                            yEnd: .value("max", 100)
                        )
                        .foregroundStyle(Color.gray.opacity(0.18))
                    }
                    ForEach(model.batteryTimeline) { p in
                        LineMark(
                            x: .value("Time", p.date),
                            y: .value("Battery %", p.percent)
                        )
                        .foregroundStyle(p.onBattery ? Color.green : Color.blue)
                        .interpolationMethod(.linear)
                    }
                }
                .chartXScale(domain: rangeStart ... rangeEnd)
                .chartYScale(domain: 0...100)
                .frame(height: 140)
                .chartYAxis { AxisMarks(position: .leading) }
                if !model.sleepPeriods.isEmpty {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.18)).frame(width: 14, height: 8)
                        Text("asleep").font(.caption2).foregroundStyle(.secondary)
                        Rectangle().fill(Color.green).frame(width: 14, height: 2)
                        Text("on battery").font(.caption2).foregroundStyle(.secondary)
                        Rectangle().fill(Color.blue).frame(width: 14, height: 2)
                        Text("plugged in").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private var rangeEnd: Date { Date() }
    private var rangeStart: Date { Date().addingTimeInterval(-Double(model.range.seconds)) }
}

struct TopBarCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card(title: "Top consumers") {
            let top = Array(model.apps.prefix(10))
            if top.isEmpty {
                Text("No data.").foregroundStyle(.secondary).frame(height: 120)
            } else {
                Chart {
                    ForEach(top) { app in
                        BarMark(
                            x: .value("Share", model.sharePercent(of: app)),
                            y: .value("App", app.displayName)
                        )
                        .foregroundStyle(app.id == model.selectedAppId ? Color.accentColor : Color.accentColor.opacity(0.45))
                        .annotation(position: .trailing) {
                            Text(String(format: "%.1f%%", model.sharePercent(of: app)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .chartXScale(domain: 0...max(100, top.first.map { model.sharePercent(of: $0) + 5 } ?? 100))
                .frame(height: CGFloat(28 * top.count + 40))
            }
        }
    }
}

struct Card<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }
}
