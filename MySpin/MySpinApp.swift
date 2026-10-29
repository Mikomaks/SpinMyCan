// MySpinApp.swift
// Punkt wejścia aplikacji

import SwiftUI

@main
struct MySpinApp: App {
    // Potrzebny WYŁĄCZNIE do blokady orientacji w trybie pasażera.
    // Domyślnie trzyma pion — czyli zachowanie głównej apki bez zmian.
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Trwały łapacz crashy — musi być pierwszą rzeczą, zanim cokolwiek padnie.
        CrashReporter.install()
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
