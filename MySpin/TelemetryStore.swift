// TelemetryStore.swift
// Przechowuje i mapuje dane telemetryczne z motocykla (type 55 DataUpdate).
//
// Identyfikatory kanałów telemetrii (niezbędne do współdziałania z wyświetlaczem):
//   0x9FCB4386 → RPM              DISPLAY_ENGINE_SPEED
//   0x833F41EB → Speed km/h       DISPLAY_VEHICLE_SPEED
//   0xE343911B → Fuel %           FUEL_LEVEL
//   0x02EDB78E → Gear             GEAR_LEVEL_POSITION
//   0x318E5203 → Ride Mode        TRANSFER_SHIFT_INDICATION
//   0x32DA65B1 → Ambient Temp °C  AMBIENT_TEMP
//   0xDE74F274 → Pitch/Tilt °     PITCH_ANGLE
//   0xEE3DD907 → Throttle %       PEDAL_POSITION (zakres 0–100)
//   0x90F66D09 → Yaw Rate °/s     YAW_RATE
//   0xC8CC087B → Engine On        RUNNING_STANDBY
//   0x00000002 → Is Moving        IS_MOVING
//   0x00000003 → Is Night         IS_NIGHT
//   0xB45CEC94 → Dist to Empty    DISTANCE_TO_EMPTY (km)
//   0x7D22F7FE → Speed accurate   VEHICLE_SPEED_ACCURATE
//   0x3FEBE1C1 → Lateral accel    LATERAL_ACCELERATION
//   0x6D982AAC → Steering angle   STEERING_WHEEL_ANGLE
//   0x2821BD75 → Low Fuel warn    LOW_FUEL_WARNING (bool)
//   0x271F516C → Mileage          TOTAL_MILEAGE

import Foundation
import Combine

// MARK: — Identyfikatory kanałów

extension UInt32 {
    // Główne wskaźniki
    static let chRPM:           UInt32 = 0x9FCB4386  // DISPLAY_ENGINE_SPEED
    static let chSpeed:         UInt32 = 0x833F41EB  // DISPLAY_VEHICLE_SPEED
    static let chFuel:          UInt32 = 0xE343911B  // FUEL_LEVEL
    static let chGear:          UInt32 = 0x02EDB78E  // GEAR_LEVEL_POSITION
    static let chRideMode:      UInt32 = 0x318E5203  // TRANSFER_SHIFT_INDICATION
    static let chAmbientTemp:   UInt32 = 0x32DA65B1  // AMBIENT_TEMP
    static let chTilt:          UInt32 = 0xDE74F274  // PITCH_ANGLE
    static let chThrottle:      UInt32 = 0xEE3DD907  // PEDAL_POSITION (0–100%)
    static let chYawRate:       UInt32 = 0x90F66D09  // YAW_RATE
    static let chEngineOn:      UInt32 = 0xC8CC087B  // RUNNING_STANDBY
    // Dodatkowe
    static let chIsMoving:      UInt32 = 0x00000002  // IS_MOVING
    static let chIsNight:       UInt32 = 0x00000003  // IS_NIGHT
    static let chDistToEmpty:   UInt32 = 0xB45CEC94  // DISTANCE_TO_EMPTY
    static let chSpeedAccurate: UInt32 = 0x7D22F7FE  // VEHICLE_SPEED_ACCURATE
    static let chLowFuel:       UInt32 = 0x2821BD75  // LOW_FUEL_WARNING
    static let chMileage:       UInt32 = 0x271F516C  // TOTAL_MILEAGE
    // Poprzednie błędne mappingi — zachowane żeby nie usuwać info
    // 0x0BC7DF81 = PARK_BRAKE_STATUS (nie ride mode!)
    // 0x3FEBE1C1 = LATERAL_ACCELERATION (nie tilt!)
    // 0x6D982AAC = STEERING_WHEEL_ANGLE (nie yaw rate!)
}

// MARK: — TelemetryStore

final class TelemetryStore: ObservableObject {

    // Główne wskaźniki — NIE @Published (ECU dane nie działają, brak konsumentów w UI).
    // Trzymamy żeby nie psuć kompilacji innych plików, ale bez SwiftUI re-renderów.
    var rpm:           Double = 0
    var speed:         Double = 0
    var fuelPct:       Double = 0
    var gear:          Int    = 0
    var rideMode:      Int    = 0
    var ambientTemp:   Double = 0
    var tiltAngle:     Double = 0
    var throttle:      Double = 0
    var yawRate:       Double = 0
    var engineOn:      Bool   = false
    var isMoving:      Bool   = false
    var isNight:       Bool   = false
    var distToEmpty:   Double = 0
    var lowFuelWarn:   Bool   = false
    var mileage:       Double = 0

    // rawChannels — niepublishowany, zaktualizowany pod TelemetryView pokazany lokalnie
    var rawChannels: [UInt32: String] = [:]
    private(set) var previousValues:  [UInt32: String] = [:]
    var lastUpdate: Date = .distantPast
    var processedCount: Int = 0
    var changeCount:    Int = 0

    // MARK: — Obliczone

    var gearLabel: String    { gear == 0 ? "N" : "\(gear)" }
    var rideModeLabel: String { ["A", "B", "C", "D"][safe: rideMode] ?? "\(rideMode)" }
    var rpmFraction:   Double { min(1, max(0, rpm  / 13_000)) }
    var speedFraction: Double { min(1, max(0, speed / 260)) }
    var fuelFraction:  Double { min(1, max(0, fuelPct / 100)) }

    /// Czy kanał paliwa ma prawdziwą wartość liczbową (nie "not supported")?
    var fuelKnown: Bool {
        guard let raw = rawChannels[.chFuel] else { return false }
        return !raw.hasPrefix("[")   // "[not supported]" zaczyna się od "["
    }

    var fuelDisplay: String { fuelKnown ? String(format: "%.0f%%", fuelPct) : "—%" }

    var fuelWarning: Bool { fuelPct > 0 && fuelPct < 15 }

    /// Czy nigdy nie dostaliśmy żadnych danych?
    var hasData:     Bool { !rawChannels.isEmpty }

    /// Czy dane są "żywe" — engine on i ostatni update < 3s temu
    var isLive:      Bool { engineOn && lastUpdate > Date().addingTimeInterval(-3) }

    /// "Brak danych" tylko gdy rawChannels całkowicie puste (nigdy nie podłączono)
    var isIdle:      Bool { !hasData }

    /// Czytelny status dla UI
    var statusLabel: String {
        if !hasData       { return String(localized: "Oczekiwanie na dane...") }
        if engineOn       { return String(localized: "Dane na żywo 🟢") }
        return String(localized: "Silnik wyłączony — dane statyczne")
    }

    /// Kolor wskaźnika statusu
    var statusLive: Bool { isLive }

    /// Kanały z wartością != "[not supported]" — każdy kanał który dostał json["value"]
    /// Zawiera RÓWNIEŻ kanały z wartością 0 — żebyśmy widzieli co motocykl w ogóle obsługuje
    var receivedChannels: [(id: UInt32, name: String, value: String)] {
        rawChannels
            .filter { !$0.value.hasPrefix("[") }          // wyklucz tylko "not supported"
            .sorted { liveSort($0.value) > liveSort($1.value) }  // największe wartości na górze
            .map { (id: $0.key, name: knownChannelName($0.key), value: $0.value) }
    }

    /// Kanały z wartością != 0 / != false — faktycznie niezerowe
    var liveChannels: [(id: UInt32, name: String, value: String)] {
        rawChannels
            .filter { isNonZero($0.value) }
            .sorted { liveSort($0.value) > liveSort($1.value) }  // największe wartości na górze
            .map { (id: $0.key, name: knownChannelName($0.key), value: $0.value) }
    }

    /// Wszystkie kanały posortowane: niezerowe pierwsze, "not supported" na końcu
    var allChannelsSorted: [(id: UInt32, name: String, value: String)] {
        rawChannels
            .sorted { a, b in
                let aLive = isNonZero(a.value)
                let bLive = isNonZero(b.value)
                if aLive != bLive { return aLive }   // live na górze
                return a.key < b.key
            }
            .map { (id: $0.key, name: knownChannelName($0.key), value: $0.value) }
    }

    private func isNonZero(_ val: String) -> Bool {
        if val.hasPrefix("[") { return false }        // "[not supported]"
        if val == "0" || val == "false" || val == "0.000" { return false }
        if val == "notset" || val == "not set" { return false }   // VEHICLE_ID itp.
        if let d = Double(val) { return d != 0 }
        return !val.isEmpty
    }

    private func liveSort(_ val: String) -> Double {
        if let d = Double(val) { return abs(d) }
        return val == "true" ? 1 : 0
    }

    func knownChannelName(_ id: UInt32) -> String {
        switch id {
        case .chRPM:           return "RPM"
        case .chSpeed:         return "Speed km/h"
        case .chFuel:          return "Fuel %"
        case .chGear:          return "Gear"
        case .chRideMode:      return "Ride Mode"
        case .chAmbientTemp:   return "Temp °C"
        case .chTilt:          return "Pitch °"
        case .chThrottle:      return "Throttle %"
        case .chYawRate:       return "Yaw Rate °/s"
        case .chEngineOn:      return "Engine On"
        case .chIsMoving:      return "Is Moving"
        case .chIsNight:       return "Is Night"
        case .chDistToEmpty:   return "Dist to Empty km"
        case .chSpeedAccurate: return "Speed Accurate"
        case .chLowFuel:       return "Low Fuel Warn"
        case .chMileage:       return "Mileage"
        case 0x0BC7DF81:       return "Park Brake"
        case 0x3FEBE1C1:       return "Lateral Accel"
        case 0x6D982AAC:       return "Steering Angle"
        case 0xEDCE10E1:       return "Vehicle ID"
        case 0xDC55FE4A:       return "RPM accurate"
        case 0x42CF35C6:       return "Roll angle"
        case 0x0267A2BB:       return "Unk(0267)"
        case 0x0F6F3287:       return "Unk(0F6F)"
        default:               return "???"
        }
    }

    // MARK: — Aktualizacja z type 55

    /// Wynik aktualizacji kanału — do logowania
    enum UpdateResult {
        case firstValue(String)              // pierwszy raz ten kanał dostał wartość
        case changed(old: String, new: String) // wartość się zmieniła
        case same                            // bez zmian
    }

    /// Kanał bez wartości (np. "status": "not supported") — zapisz w rawChannels i odśwież timestamp.
    /// Dzięki temu `isIdle` = false zaraz po pierwszym type 55, nawet bez silnika.
    @discardableResult
    func markUnsupported(channelId: UInt32, status: String) -> UpdateResult {
        let newRaw = "[\(status)]"
        let old = rawChannels[channelId]
        rawChannels[channelId] = newRaw
        lastUpdate = Date()
        processedCount += 1
        if old == nil {
            return .firstValue(newRaw)
        } else if old != newRaw {
            changeCount += 1
            return .changed(old: old ?? "", new: newRaw)
        }
        return .same
    }

    @discardableResult
    func update(channelId: UInt32, value: Any) -> UpdateResult {
        let num  = numericValue(value)
        let bool = boolValue(value)

        // Wykryj zmianę wartości
        let newRaw = formatRaw(value)
        let oldRaw = rawChannels[channelId]
        let result: UpdateResult = {
            if oldRaw == nil { return .firstValue(newRaw) }
            if oldRaw != newRaw {
                changeCount += 1
                return .changed(old: oldRaw ?? "", new: newRaw)
            }
            return .same
        }()
        if case .changed = result {
            previousValues[channelId] = oldRaw
        }

        // Surowy podgląd
        rawChannels[channelId] = newRaw
        lastUpdate = Date()
        processedCount += 1

        switch channelId {
        case .chRPM:
            rpm           = num ?? 0

        case .chSpeed:
            speed         = num ?? 0

        case .chFuel:
            fuelPct       = num ?? 0

        case .chGear:
            let g = Int(num ?? 0)
            gear = max(0, min(15, g))

        case .chRideMode:
            let m = Int(num ?? 0)
            rideMode = max(0, min(7, m))

        case .chAmbientTemp:
            ambientTemp   = num ?? 0

        case .chTilt:
            tiltAngle     = num ?? 0

        case .chThrottle:
            // PEDAL_POSITION: zakres 0–100 %
            throttle      = min(100, max(0, num ?? 0))

        case .chYawRate:
            yawRate       = num ?? 0

        case .chEngineOn:
            engineOn      = bool ?? (num != nil && num! > 0)

        case .chIsMoving:
            isMoving      = bool ?? (num != nil && num! > 0)

        case .chIsNight:
            isNight       = bool ?? (num != nil && num! > 0)

        case .chDistToEmpty:
            distToEmpty   = num ?? 0

        case .chLowFuel:
            lowFuelWarn   = bool ?? (num != nil && num! > 0)

        case .chMileage:
            mileage       = num ?? 0

        default:
            break
        }
        return result
    }

    // MARK: — Test / Symulacja

    /// Ręczne wypełnienie danych testowych — sprawdza czy pipeline Store→UI działa.
    func simulateTestData() {
        rpm           = 3500
        speed         = 75
        fuelPct       = 68
        gear          = 3
        rideMode      = 1
        ambientTemp   = 22
        tiltAngle     = -2.5
        throttle      = 35
        yawRate       = 12
        engineOn      = true
        isMoving      = true
        distToEmpty   = 142
        rawChannels[.chRPM]          = "3500"
        rawChannels[.chSpeed]        = "75"
        rawChannels[.chFuel]         = "68"
        rawChannels[.chGear]         = "3"
        rawChannels[.chEngineOn]     = "true"
        rawChannels[.chIsMoving]     = "true"
        rawChannels[.chAmbientTemp]  = "22"
        rawChannels[.chDistToEmpty]  = "142"
        lastUpdate = Date()
        processedCount += 1
    }

    // MARK: — Parsowanie wartości JSON

    private func numericValue(_ value: Any) -> Double? {
        switch value {
        case let n as Int:    return Double(n)
        case let n as Double: return n
        case let n as Float:  return Double(n)
        case let b as Bool:   return b ? 1.0 : 0.0
        case let s as String: return Double(s)
        default:              return nil
        }
    }

    private func boolValue(_ value: Any) -> Bool? {
        switch value {
        case let b as Bool:   return b
        case let n as Int:    return n != 0
        case let n as Double: return n != 0
        default:              return nil
        }
    }

    private func formatRaw(_ value: Any) -> String {
        switch value {
        case let b as Bool:   return b ? "true" : "false"
        case let n as Int:    return "\(n)"
        case let n as Double: return String(format: "%.3f", n)
        case let s as String: return s
        default:              return "\(value)"
        }
    }
}

// MARK: — Pomocnicze

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
