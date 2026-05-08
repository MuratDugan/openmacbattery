import SwiftUI
import OpenMacBatteryCore

/// Apple → Battery Details… and toolbar button popover.
struct BatteryDetailsView: View {
    @EnvironmentObject var model: AppModel
    var compact: Bool = true

    var body: some View {
        let snap = model.batterySnapshot
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BatteryGlyph(
                    percent: snap?.percent ?? 0,
                    isCharging: snap?.isCharging == true || snap?.externalConnected == true
                )
                .frame(width: 38, height: 20)
                Text("Battery Details").font(.headline)
                Spacer()
                if let s = snap {
                    Text("\(s.percent)%").font(.headline).monospacedDigit()
                        .foregroundStyle(percentColor(s))
                }
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)
            Divider()

            if let s = snap {
                VStack(spacing: 0) {
                    row("Full Charge Capacity", "\(formatThousands(s.maxCapacity_mAh)) mAh")
                    row("Design Capacity", "\(formatThousands(s.designCapacity_mAh)) mAh")
                    row("Health", "\(s.healthPercent)%\(healthSuffix(s))")
                    row("Charge Cycles", "\(s.cycleCount)")
                    row("Manufacture Date", "—")
                        .help("Apple Silicon Macs don't expose this in a parseable format")
                    row("Battery Temperature", String(format: "%.1f °C", s.temperatureC))
                    row("Voltage", String(format: "%.2f V", Double(s.voltage_mV)/1000))
                    row(dischargeLabel(s), dischargeValue(s))
                    row("Full at", String(format: "%.1f Wh", s.fullWh))
                    row("Energy now", String(format: "%.1f Wh", s.remainingWh))
                    row("Low Power Mode", s.lowPowerModeEnabled ? "Enabled" : "Disabled")
                    if let m = s.macOsTimeRemainingMin {
                        row("macOS estimate", formatMinutes(m))
                    }
                    if let serial = s.serial {
                        row("Serial", serial, monospaced: true)
                    }
                }
            } else {
                Text("Could not read battery information.")
                    .padding(16).foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Text("Refreshes every 15 seconds")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh now") { model.refreshLiveWatts() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: compact ? 360 : 460)
        .background(.background)
    }

    @ViewBuilder
    private func row(_ key: LocalizedStringKey, _ value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer(minLength: 24)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: monospaced ? .monospaced : .default))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func percentColor(_ s: BatterySnapshot) -> Color {
        if s.isCharging { return .blue }
        if s.percent <= 10 { return .red }
        if s.percent <= 25 { return .orange }
        return .green
    }
    private func healthSuffix(_ s: BatterySnapshot) -> String {
        if s.healthPercent >= 80 { return NSLocalizedString(" (good)", comment: "") }
        if s.healthPercent >= 60 { return NSLocalizedString(" (fair)", comment: "") }
        return NSLocalizedString(" (poor)", comment: "")
    }
    private func dischargeLabel(_ s: BatterySnapshot) -> LocalizedStringKey {
        if s.isCharging { return "Charging current" }
        if s.externalConnected { return "Drawing" }
        return "Discharging with"
    }
    private func dischargeValue(_ s: BatterySnapshot) -> String {
        let watts = Double(abs(s.amperage_mA)) * Double(s.voltage_mV) / 1_000_000.0
        return String(format: "%.2f W  ·  %d mA", watts, abs(s.amperage_mA))
    }
    private func formatMinutes(_ m: Int) -> String {
        let h = m / 60; let mm = m % 60
        if h > 0 {
            return String(format: NSLocalizedString("%d h %d min", comment: ""), h, mm)
        }
        return String(format: NSLocalizedString("%d min", comment: ""), mm)
    }
    private func formatThousands(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

struct BatteryDetailsWindowOpener: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Battery Details…") { openWindow(id: "batteryDetails") }
            .keyboardShortcut("b", modifiers: [.command, .option])
    }
}
