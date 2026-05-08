import SwiftUI

/// Toolbar canlı watt refresh butonu — dolan halka + içte arrow.clockwise.
/// Halka son `model.lastLiveRefresh`'ten itibaren `cycleSec` (15s) süresinde dolar.
/// Model kendi 15s timer'ı ile refreshLiveWatts() çağırınca lastLiveRefresh güncellenir,
/// halka sıfırlanır. Tıklayınca: hızla %100'e doldurup refreshLiveWatts() tetikler.
struct RefreshRingButton: View {
    @ObservedObject var model: AppModel
    var cycleSec: TimeInterval = 15

    @State private var now: Date = Date()
    @State private var manualFillStartedAt: Date? = nil
    @State private var hovering: Bool = false

    private let manualFillDuration: TimeInterval = 0.30

    var body: some View {
        Button {
            tap()
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if model.loading {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .rotationEffect(.degrees(spinnerAngle))
                        .onAppear {
                            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                                spinnerAngle = 360
                            }
                        }
                        .onDisappear { spinnerAngle = 0 }
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
            }
            .frame(width: 22, height: 22)
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.secondary.opacity(0.08) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tooltip)
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { date in
            now = date
            // Model kendi timer'ı ile 15s'de bir refreshLiveWatts çağırıyor.
            // View sadece ilerlemeyi gösterir; otomatik tetikleme model'de.
        }
    }

    @State private var spinnerAngle: Double = 0

    private var progress: Double {
        if let manualStart = manualFillStartedAt {
            let elapsed = now.timeIntervalSince(manualStart)
            // Geri kalan kısmı (current → 1.0) animasyon süresinde tamamla
            let baseAtTap = baseProgress(at: manualStart)
            let frac = min(1.0, elapsed / manualFillDuration)
            return baseAtTap + (1.0 - baseAtTap) * frac
        }
        return baseProgress(at: now)
    }

    private func baseProgress(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(model.lastLiveRefresh)
        return min(1.0, max(0.0, elapsed / cycleSec))
    }

    private var ringColor: Color {
        if model.loading { return Color.accentColor }
        if progress >= 0.95 { return Color.accentColor }
        return Color.accentColor.opacity(0.85)
    }

    private var iconColor: Color {
        progress > 0.05 ? Color.accentColor : .secondary
    }

    private var tooltip: String {
        let remaining = max(0, cycleSec - now.timeIntervalSince(model.lastLiveRefresh))
        let template = NSLocalizedString("Live watts · next update in %ds · click to refresh now", comment: "")
        return String(format: template, Int(remaining))
    }

    private func tap() {
        guard manualFillStartedAt == nil else { return }
        let start = Date()
        manualFillStartedAt = start
        // Halka %100'e çıksın, sonra canlı watt'ı yenile
        DispatchQueue.main.asyncAfter(deadline: .now() + manualFillDuration) {
            model.refreshLiveWatts()
            // refreshLiveWatts senkron çalışır; lastLiveRefresh hemen güncellenir → halka sıfırlanır.
            manualFillStartedAt = nil
        }
    }
}
