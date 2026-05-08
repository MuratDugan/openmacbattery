import SwiftUI
import AppKit
import OpenMacBatteryCore

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var installing = false
    @State private var installResult: Result<Void, Error>? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.batteryblock.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("Welcome to OpenMacBattery")
                .font(.title)
                .fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 8) {
                BulletRow(icon: "clock", text: "Checks every running app on your Mac once per minute.")
                BulletRow(icon: "battery.75percent", text: "Tells you which app drained your battery — looking back, not just now.")
                BulletRow(icon: "lock.shield", text: "Your data stays on this Mac. Nothing is sent over the network.")
                BulletRow(icon: "leaf", text: "Uses almost no battery itself (~1-2 joules per hour).")
            }
            .padding(.horizontal, 16)

            Spacer().frame(height: 4)

            switch installResult {
            case .success:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Background tracking enabled.")
                }
                .font(.system(size: 13, weight: .medium))
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            case .failure(let err):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Install failed: \(String(describing: err))")
                        .font(.caption)
                }
                Button("Try again") { runInstall() }
            case .none:
                if installing {
                    ProgressView().controlSize(.small)
                    Text("Installing…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button {
                        runInstall()
                    } label: {
                        Label("Enable background tracking", systemImage: "play.fill")
                            .frame(minWidth: 240)
                    }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)

                    Button("Not now") { isPresented = false }
                        .controlSize(.small)
                }
            }

            Text("You can toggle this anytime in ⚙ Settings.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 460)
    }

    private func runInstall() {
        installing = true
        installResult = nil
        Task.detached {
            do {
                let cli = embeddedCLIPath()
                try DaemonInstaller.install(binaryPath: cli)
                await MainActor.run {
                    installResult = .success(())
                    installing = false
                }
            } catch {
                await MainActor.run {
                    installResult = .failure(error)
                    installing = false
                }
            }
        }
    }
}

struct BulletRow: View {
    let icon: String
    let text: LocalizedStringKey
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

func embeddedCLIPath() -> String {
    if let res = Bundle.main.resourcePath {
        let p = res + "/openmacbattery"
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    let cwd = FileManager.default.currentDirectoryPath
    let dev = cwd + "/.build/release/openmacbattery"
    if FileManager.default.fileExists(atPath: dev) { return dev }
    return "/opt/homebrew/bin/openmacbattery"
}
