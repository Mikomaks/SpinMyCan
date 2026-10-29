import SwiftUI

// MARK: — Język aplikacji

/// Wybór języka apki: systemowy, polski albo angielski.
/// iOS czyta `AppleLanguages` przy starcie procesu, więc zmiana działa w pełni
/// (deska, widget, powiadomienia) dopiero po ponownym uruchomieniu apki.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, pl, en

    var id: String { rawValue }

    private static let key = "AppleLanguages"

    /// Język wybrany ręcznie w apce; `.system` gdy brak nadpisania.
    static var current: AppLanguage {
        get {
            // Tylko domena apki — `standard` zwróciłby też globalną listę języków z iOS
            let app = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
            guard let first = (app?[key] as? [String])?.first else { return .system }
            if first.hasPrefix("pl") { return .pl }
            if first.hasPrefix("en") { return .en }
            return .system
        }
        set {
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: key)
            }
        }
    }

    /// Nazwy języków zawsze w ich własnym języku — żeby dało się wrócić, nawet nie rozumiejąc obecnego.
    var title: String {
        switch self {
        case .system: return String(localized: "Jak w systemie")
        case .pl:     return "Polski"
        case .en:     return "English"
        }
    }
}

/// Karta w ustawieniach: picker języka + skrót do systemowych ustawień apki.
struct LanguageCard: View {
    @State private var choice = AppLanguage.current
    @State private var needsRestart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader("Język", icon: "globe", tint: .blue) {
                Picker("Język", selection: $choice) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .labelsHidden()
            }
            if needsRestart {
                // Dwujęzycznie — apka wciąż mówi starym językiem, a nowy może być jedynym zrozumiałym
                Text(verbatim: "Zamknij apkę i otwórz ją ponownie. / Close and reopen the app.")
                    .font(.caption).foregroundColor(.orange)
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Język w Ustawieniach iOS", systemImage: "arrow.up.forward.app")
                    .font(.subheadline)
            }
        }
        .card()
        .onChange(of: choice) { _, new in
            AppLanguage.current = new
            needsRestart = true
        }
    }
}
