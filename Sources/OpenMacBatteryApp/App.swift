import SwiftUI
import AppKit
import OpenMacBatteryCore

@main
struct OpenMacBatteryApp: App {
    @StateObject private var model = AppModel()
    @State private var showOnboarding: Bool = !DaemonInstaller.isInstalled

    init() {
        // Mevcut plist farklı bir binary'ye işaret ediyorsa (örn. /opt/homebrew/bin'den
        // /Applications/OpenMacBattery.app içine geçiş) VEYA plist var ama daemon yüklü değilse
        // (bootout sonrası yeniden açılış), sessizce yeniden kur.
        let cli = embeddedCLIPath()
        guard FileManager.default.fileExists(atPath: cli) else { return }
        if !DaemonInstaller.isInstalled { return }
        let installedPath = DaemonInstaller.installedBinaryPath()
        let pathChanged = installedPath != nil && installedPath != cli
        let needsBootstrap = !DaemonInstaller.isRunning()
        if pathChanged || needsBootstrap {
            try? DaemonInstaller.install(binaryPath: cli)
        }
    }

    var body: some Scene {
        Window("OpenMacBattery", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { model.refreshNow() }
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView(isPresented: $showOnboarding)
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { model.refreshNow() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About OpenMacBattery") { AboutPanel.show() }
                Divider()
                BatteryDetailsWindowOpener()
                LanguageMenuItem()
            }
            // Help → BatTracker Yardımı
            CommandGroup(replacing: .help) {
                HelpMenuItem()
            }
        }

        Settings {
            SettingsView()
        }

        Window("OpenMacBattery Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)

        Window("Battery Details", id: "batteryDetails") {
            BatteryDetailsView(compact: false)
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

/// CommandGroup içinden SwiftUI'nin openWindow Environment'ını kullanmak için ufak bir View.
struct HelpMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("OpenMacBattery Help") {
            openWindow(id: "help")
        }
        .keyboardShortcut("?", modifiers: .command)
    }
}
