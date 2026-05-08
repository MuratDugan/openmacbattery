import SwiftUI
import AppKit

/// Apple → BatTracker → About BatTracker
enum AboutPanel {
    static func show() {
        let credits = NSAttributedString(
            string: NSLocalizedString(
                "Per-app battery & energy tracker for macOS.\nFind out who's draining your battery — looking back, not just right now.\n\nData stays on this Mac. Nothing is sent over the network.",
                comment: ""
            ),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "OpenMacBattery",
            .applicationVersion: "0.1",
            .version: "1",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"):
                NSLocalizedString("© 2026 — open source, free for personal use", comment: "")
        ])
    }
}

/// Help → BatTracker Help
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Group {
                    Text("OpenMacBattery Help").font(.title).fontWeight(.semibold)
                    Text("Tells you what's draining your battery and which app is responsible — looking back, not just right now. Activity Monitor only knows the present moment; OpenMacBattery remembers the past.")
                        .foregroundStyle(.secondary)
                }

                section(title: "Quick Start") {
                    bullet("At the top of the detail panel you'll see **Drawing now: X watts** — your live system draw.")
                    bullet("The sidebar lists apps sorted by energy. Badges (**High / Medium / Low**) reflect their share of the total.")
                    bullet("Use the **Today / This week** menu at the top to look back as far as your data goes.")
                    bullet("**On battery only** filter — strips out measurements taken while plugged in. The real question is who eats your battery while unplugged.")
                }

                section(title: "Quitting an app") {
                    bullet("**Right-click** any app in the sidebar → Quit or Force Quit.")
                    bullet("System services (mdworker_shared, coreaudiod, etc.) cannot be quit from here.")
                    bullet("After quitting you'll see the impact in the live readings within 1-2 minutes.")
                }

                section(title: "Comparisons and warnings") {
                    bullet("The current period is automatically compared to the previous one: **\"Today: 25% less battery than yesterday\"**.")
                    bullet("If an app is using **×N more than usual**, it gets a small orange warning in the sidebar.")
                    bullet("On battery, if a high consumer is selected, the detail panel shows an orange **quit suggestion** card.")
                }

                section(title: "Joules vs scores?") {
                    Text("Apple's `ri_billed_energy` counter is undocumented. To display real joule values, run a one-time calibration:")
                        .foregroundStyle(.secondary)
                    Text("openmacbattery calibrate --duration 300")
                        .font(.system(.caption, design: .monospaced))
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.background.tertiary))
                    Text("Without calibration the UI shows percentages and level badges — relative comparisons are always correct.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section(title: "Where is the data?") {
                    bullet("`~/Library/Application Support/BatteryTracker/data.db` — only you can read it (600 permissions).")
                    bullet("Nothing is sent over the network. There is no networking code.")
                    bullet("Raw samples are kept 7 days, hourly summaries 180 days. Cleaned automatically.")
                }

                section(title: "Troubleshooting") {
                    bullet("No data filling in? Check Settings to confirm background tracking is enabled.")
                    bullet("Sidebar empty? The daemon needs to run for at least 2 minutes (deltas need 2 samples).")
                    bullet("Logs: Settings → \"Open log\".")
                    bullet("Reset all data: in Terminal, `openmacbattery reset --confirm`.")
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 500, idealHeight: 700)
    }

    @ViewBuilder
    private func section<Content: View>(title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }
    @ViewBuilder
    private func bullet(_ markdown: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(.init(markdown))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
