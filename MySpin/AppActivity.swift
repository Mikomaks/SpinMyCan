// AppActivity.swift
// Czy apka jest na pierwszym planie — czytane z dowolnego wątku.
//
// Po co: w tle (zablokowany telefon w kieszeni, inna apka na wierzchu) iOS pozwala
// apce zużywać najwyżej 80% jednego rdzenia w ciągu minuty i po przekroczeniu ją
// ubija (raport „cpu_resource_fatal"). Interfejs telefonu nie jest wtedy widoczny,
// więc źródła danych zwalniają jego odświeżanie do minimum. Deska na motocyklu
// nie zależy od tego — bierze wartości bezpośrednio, a nie przez interfejs.

import UIKit

enum AppActivity {
    private static let lock = NSLock()
    private static var foreground = true
    private static var installed = false

    static var isForeground: Bool {
        lock.lock(); defer { lock.unlock() }
        return foreground
    }

    /// Wołać raz, z wątku głównego, na starcie apki.
    static func install() {
        guard !installed else { return }
        installed = true
        set(UIApplication.shared.applicationState != .background)
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in set(true) }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in set(true) }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in set(false) }
    }

    /// Tylko do pomiaru (env LEGACY_UI_RATE, DEBUG): stare tempo odświeżania interfejsu,
    /// żeby dało się porównać zużycie procesora przed i po.
    static let legacyRates: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LEGACY_UI_RATE"] != nil
        #else
        return false
        #endif
    }()

    /// Arkusz ustawień zasłania ekran główny, a jest jego częścią: każde odświeżenie
    /// danych przelicza też cały arkusz, co przy 12 odświeżeniach na sekundę dławiło
    /// przewijanie. Gdy jest otwarty, źródła danych zwalniają do raz na sekundę
    /// (jak w tle) — w ustawieniach liczby na żywo są tylko diagnostyką.
    static var isSettingsOpen: Bool {
        get { lock.lock(); defer { lock.unlock() }; return settingsOpen }
        set { lock.lock(); settingsOpen = newValue; lock.unlock() }
    }
    private static var settingsOpen = false

    /// Najkrótszy odstęp między odświeżeniami interfejsu telefonu przez źródło danych,
    /// które normalnie odświeża co `normal` sekund.
    static func uiInterval(_ normal: TimeInterval) -> TimeInterval {
        if legacyRates { return normal }
        lock.lock(); defer { lock.unlock() }
        if !foreground || settingsOpen { return max(normal, 1.0) }
        return normal
    }

    private static func set(_ value: Bool) {
        lock.lock(); foreground = value; lock.unlock()
    }
}
