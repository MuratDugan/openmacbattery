import SwiftUI
import AppKit

struct AppLanguage: Identifiable, Hashable {
    let code: String          // "en", "tr", "zh-Hans", ...; nil = system default
    let nativeName: String    // gösterilecek ad
    let englishName: String   // hover/tooltip
    var id: String { code }
}

enum AppLanguages {
    static let supported: [AppLanguage] = [
        .init(code: "en",      nativeName: "English",       englishName: "English"),
        .init(code: "tr",      nativeName: "Türkçe",        englishName: "Turkish"),
        .init(code: "zh-Hans", nativeName: "简体中文",       englishName: "Simplified Chinese"),
        .init(code: "es",      nativeName: "Español",       englishName: "Spanish"),
        .init(code: "de",      nativeName: "Deutsch",       englishName: "German"),
        .init(code: "fr",      nativeName: "Français",      englishName: "French"),
        .init(code: "ja",      nativeName: "日本語",         englishName: "Japanese"),
        .init(code: "pt-BR",   nativeName: "Português (BR)", englishName: "Brazilian Portuguese")
    ]

    /// Şu an aktif dil kodu — UserDefaults'tan AppleLanguages array'inin ilk elemanı.
    static var current: String? {
        UserDefaults.standard.array(forKey: "AppleLanguages")?.first as? String
    }

    /// Dili kalıcı olarak ayarla — restart sonrası devreye girer.
    static func set(_ code: String?) {
        if let code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            // Sistem varsayılanına dön
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }
}

/// Apple menüsünde "Language" alt menüsü.
struct LanguageMenuItem: View {
    @State private var current: String? = AppLanguages.current

    var body: some View {
        Menu {
            // Sistem varsayılanı (kullanıcı override yapmadıysa burası seçili)
            Button {
                changeLanguage(to: nil)
            } label: {
                if current == nil {
                    Label("Use system language", systemImage: "checkmark")
                } else {
                    Text("Use system language")
                }
            }
            Divider()
            ForEach(AppLanguages.supported) { lang in
                Button {
                    changeLanguage(to: lang.code)
                } label: {
                    if current == lang.code {
                        Label(lang.nativeName, systemImage: "checkmark")
                    } else {
                        Text(lang.nativeName)
                    }
                }
            }
        } label: {
            Text("Language")
        }
    }

    private func changeLanguage(to code: String?) {
        AppLanguages.set(code)
        current = code
        promptRestart(for: code)
    }

    private func promptRestart(for code: String?) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Restart to change language", comment: "")
        alert.informativeText = NSLocalizedString("OpenMacBattery needs to restart for the new language to take effect.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Restart Now", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
        alert.alertStyle = .informational

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            relaunch()
        }
    }

    private func relaunch() {
        // Aynı .app bundle'ı tekrar aç, mevcut process'i kapat
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()
        // Kısa gecikme — yeni process başlasın
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }
}
