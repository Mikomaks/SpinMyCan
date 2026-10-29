// OrientationLock.swift
// Sterowanie orientacją ekranu — potrzebne WYŁĄCZNIE dla trybu pasażera
// (RiderModeView), gdzie użytkownik wybiera pion/poziom i ma to zostać.
//
// BEZPIECZEŃSTWO GŁÓWNEJ APKI: domyślna blokada to `.portrait` — czyli
// dokładnie to samo zachowanie co przed dodaniem tego pliku. Tryb pasażera
// zmienia ją tylko na czas swojego działania i PRZYWRACA pion przy zamknięciu.
// Bez wejścia w tryb pasażera nic się nie zmienia.

import UIKit
import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Aktualnie dozwolone orientacje. Domyślnie pion (jak cała apka do tej pory).
    static var lock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.lock
    }

    /// Ubicie apki (przesunięcie w przełączniku apek): zamknij Dynamic Island — inaczej
    /// zostaje na ekranie z ostatnimi liczbami. Apka żyje w tle (GPS), więc iOS to woła.
    func applicationWillTerminate(_ application: UIApplication) {
        RideLiveActivityManager.endAllBeforeExit()
    }
}

enum OrientationLock {

    /// Ustawia dozwoloną orientację i wymusza obrót (iOS 16+).
    static func set(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.lock = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in
            // Błąd = system odmówił obrotu (np. blokada obrotu w Centrum sterowania).
            // Nie robimy nic — widok i tak działa w bieżącej orientacji.
        }
    }

    /// Przywraca zachowanie głównej aplikacji (pion).
    static func reset() { set(.portrait) }
}
