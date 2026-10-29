// NotificationManager.swift
// Powiadomienia lokalne — pytanie o zakończenie trasy gdy BT motocykla
// jest zerwane od dłuższego czasu (grace period).

import UserNotifications
import Foundation

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationManager()

    /// Wywoływane gdy user wybierze "Zakończ trasę" w powiadomieniu.
    var onEndRouteRequested: (() -> Void)?

    private let endActionID = "END_ROUTE"
    private let categoryID  = "ROUTE_GRACE"
    private let requestID   = "route_grace_notification"

    /// Rejestruje delegata + kategorię z akcją + prosi o uprawnienia.
    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let endAction = UNNotificationAction(
            identifier: endActionID,
            title:      String(localized: "Zakończ i zapisz trasę"),
            options:    [.foreground]
        )
        let category = UNNotificationCategory(
            identifier:        categoryID,
            actions:           [endAction],
            intentIdentifiers: [],
            options:           []
        )
        center.setNotificationCategories([category])
    }

    /// Wysyła powiadomienie "moto wyłączone od godziny — zakończyć trasę?".
    func sendGracePeriodNotification() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Trasa nadal nagrywana")
        content.body  = String(localized: "Motocykl wyłączony od godziny. Zakończyć i zapisać trasę?")
        content.sound = .default
        content.categoryIdentifier = categoryID

        let req = UNNotificationRequest(identifier: requestID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Usuwa wiszące powiadomienie (np. gdy BT wróciło zanim user zareagował).
    func clearGraceNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestID])
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
    }

    // MARK: — UNUserNotificationCenterDelegate

    /// Pokazuj powiadomienia nawet gdy app jest na pierwszym planie.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Reakcja na akcję "Zakończ trasę".
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == endActionID {
            DispatchQueue.main.async { self.onEndRouteRequested?() }
        }
        completionHandler()
    }
}
