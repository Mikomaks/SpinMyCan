// RideActivityAttributes.swift
// Dane Live Activity (Dynamic Island i ekran blokady) — jazda na żywo.
//
// UWAGA: identyczna kopia jest w MySpin/RideActivityAttributes.swift (apka startuje
// i aktualizuje aktywność, rozszerzenie ride_widget ją rysuje). ActivityKit łączy obie
// strony po nazwie typu i kształcie danych — zmiana tu = ta sama zmiana tam.

import ActivityKit
import Foundation

struct RideActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var speedKmh: Int
        var gear: Int?          // 0 = luz; nil = brak danych z CAN albo w trakcie zmiany biegu
        var rpm: Int?
        var coolantC: Int?
        var leanDeg: Int        // ujemny = lewo
        var maxLeft: Int
        var maxRight: Int
        var dashConnected: Bool // obraz idzie na wyświetlacz motocykla
        var canConnected: Bool  // dane płyną z płytki CAN
    }
}
