// RideLiveActivityManager.swift
// Live Activity jazdy: nasze logo (obrotomierz) i prędkość w Dynamic Island, a po
// rozwinięciu i na ekranie blokady bieg, obroty, płyn, przechył i stan deski/CAN.
// Wygląd rysuje rozszerzenie ride_widget (RideLiveActivity.swift).
//
// Zasady iOS: aktywność da się ZACZĄĆ tylko z apką na pierwszym planie; aktualizować
// można też z tła (apka żyje w tle dzięki GPS). Aktualizujemy najwyżej co 2 s i tylko
// po zmianie — wyspa to podgląd, nie wskaźnik do jazdy, a każda zmiana kosztuje baterię.
// Gdy apka zginie, po 2 min iOS przyciemnia aktywność (staleDate) zamiast pokazywać
// stare liczby jak świeże.

import ActivityKit
import Foundation

@MainActor
final class RideLiveActivityManager {
    static let shared = RideLiveActivityManager()

    private var activity: Activity<RideActivityAttributes>?
    private var lastState: RideActivityAttributes.ContentState?
    private var lastUpdate = Date.distantPast
    private var adopted = false
    private(set) var lastError: String?

    private static let minInterval: TimeInterval = 2
    private static let staleAfter: TimeInterval = 120

    /// Wołane co sekundę z heartbeatu. `enabled` = przełącznik w ustawieniach.
    func sync(enabled: Bool, state: RideActivityAttributes.ContentState) {
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            endAll()
            return
        }
        adoptExistingOnce()
        if let a = activity, a.activityState == .ended || a.activityState == .dismissed {
            activity = nil   // zamknięta przez użytkownika albo system — wróci przy następnym otwarciu apki
        }
        guard let activity else {
            if AppActivity.isForeground { start(state) }
            return
        }
        let now = Date()
        guard state != lastState, now.timeIntervalSince(lastUpdate) >= Self.minInterval else { return }
        lastState = state
        lastUpdate = now
        let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(Self.staleAfter))
        Task { await activity.update(content) }
    }

    /// Aktywność z poprzedniego uruchomienia apki (przeżywa jej zamknięcie) — przejmij ją
    /// zamiast tworzyć drugą; nadmiarowe zamknij.
    private func adoptExistingOnce() {
        guard !adopted else { return }
        adopted = true
        let existing = Activity<RideActivityAttributes>.activities
        activity = existing.first
        for extra in existing.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func start(_ state: RideActivityAttributes.ContentState) {
        do {
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
            activity = try Activity.request(attributes: RideActivityAttributes(), content: content, pushType: nil)
            lastState = state
            lastUpdate = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func endAll() {
        activity = nil
        lastState = nil
        for a in Activity<RideActivityAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
