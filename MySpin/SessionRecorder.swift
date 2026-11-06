// SessionRecorder.swift
// Nagrywanie sesji jazdy: prędkość, lean, G-force, GPS co 1s
// Eksport do CSV + podsumowanie sesji
//
// Problem: gdy zdejmujesz telefon z uchwytu, może się przechylić → lean kąty się psują.
// Rozwiązanie: gdy prędkość GPS < 5 km/h przez > 3s → ZAMRAŻAMY statystyki lean.
// Po powrocie > 5 km/h → wznawiamy. CSV zawiera raw data — można to potem filtrować.

import Foundation
import CoreLocation
import Combine

// MARK: — Punkt danych sesji

struct SessionPoint: Identifiable, Codable {
    /// Stabilne ID w obrębie sesji — kolejny indeks 0..N (a nie UUID, żeby reload dawał te same wartości).
    let id:        Int
    let timestamp: Date
    let speedKmh:  Double
    let leanDeg:   Double   // może być nieprecyzyjny gdy telefon zdjęty
    let gForce:    Double
    let latitude:  Double   // 0 = brak GPS
    let longitude: Double
    let altitudeM: Double
    let headingDeg: Double  // -1 = brak
    let isMoving:  Bool     // czy prędkość > 5 km/h w tym momencie
    // Z mostka CAN — nil, gdy płytka nie podawała danych (i we wszystkich starszych trasach).
    var rpm:      Int? = nil
    var gear:     Int? = nil   // 0 = luz
    var throttle: Int? = nil   // surowy 10-bitowy, 0 … ~690
}

// MARK: — Utwór grany w trakcie trasy

/// Zmiana utworu (Spotify / odtwarzacz systemowy) — zapisywana w chwili, gdy zaczął grać.
struct SessionTrack: Codable, Equatable {
    let time:   Date
    let title:  String
    let artist: String

    var label: String { artist.isEmpty ? title : "\(artist) — \(title)" }

    /// A track counts toward the ride only if it played at least this long (skips don't count).
    static let minPlaySec: TimeInterval = 10

    /// Drops tracks played shorter than `minPlaySec` (until the next track or `end`),
    /// then merges neighbours left identical (A, skipped B, A → one A).
    static func played(_ raw: [SessionTrack], until end: Date) -> [SessionTrack] {
        var out: [SessionTrack] = []
        for (i, t) in raw.enumerated() {
            let stop = i + 1 < raw.count ? raw[i + 1].time : end
            guard stop.timeIntervalSince(t.time) >= minPlaySec else { continue }
            if let last = out.last, last.title == t.title, last.artist == t.artist { continue }
            out.append(t)
        }
        return out
    }
}

// MARK: — Podsumowanie sesji

struct SessionSummary: Identifiable, Codable {
    /// Stabilne ID — UUID nadawany RAZ przy starcie nagrania, persystowane na dysk.
    let id: UUID
    let startTime:     Date
    let endTime:       Date
    let totalDistKm:   Double
    let maxSpeedKmh:   Double
    let avgSpeedKmh:   Double    // liczona tylko gdy isMoving
    let maxLeanLeft:   Double   // tylko gdy isMoving (zdjęcie telefonu nie wlicza)
    let maxLeanRight:  Double
    let maxGforce:     Double
    let points:        [SessionPoint]

    // Metadane scalenia — nil jeśli sesja jest oryginalna
    var mergedFromIDs:          [UUID]? = nil
    var mergedSegmentBoundaries: [Int]? = nil   // indeks w points[] gdzie zaczyna się każdy segment
    /// Utwory grane w trakcie trasy (nil w trasach sprzed v1.18.0).
    var tracks: [SessionTrack]? = nil

    /// Utwór grający w danej chwili (ostatni rozpoczęty przed `time`).
    func track(at time: Date) -> SessionTrack? {
        tracks?.last { $0.time <= time }
    }

    /// Całkowity czas od startu do końca — RAZEM z postojami.
    var durationSec: Int { Int(endTime.timeIntervalSince(startTime)) }

    /// Czas faktycznej JAZDY — sumuje tylko odcinki, w których się ruszałeś.
    /// Liczony z odstępów między kolejnymi punktami: odstęp liczy się, gdy punkt
    /// jest „w ruchu". Przerwy > 60 s (postój z pominiętymi punktami albo pauza
    /// nagrywania) są odrzucane, żeby nie doliczyć przerwy jako jazdy.
    var movingSec: Int {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count {
            let dt = points[i].timestamp.timeIntervalSince(points[i-1].timestamp)
            guard dt > 0, dt <= 60 else { continue }
            if points[i].isMoving { total += dt }
        }
        return Int(total)
    }

    /// Tytuł sesji do wyświetlenia w bibliotece — "12.05 14:32 · 18 km · 102 km/h".
    var displayTitle: String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm"
        return "\(f.string(from: startTime)) · \(String(format: "%.1f km", totalDistKm)) · \(Int(maxSpeedKmh)) km/h"
    }

    func csvString() -> String {
        var lines = ["timestamp,speed_kmh,lean_deg,gforce,latitude,longitude,altitude_m,heading_deg,is_moving,rpm,gear,throttle_raw,song"]
        let fmt = ISO8601DateFormatter()
        /// Pole CSV w cudzysłowie, gdy ma przecinek albo cudzysłów (tytuły piosenek).
        func csvField(_ s: String) -> String {
            s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        for p in points {
            lines.append([
                fmt.string(from: p.timestamp),
                String(format: "%.1f", p.speedKmh),
                String(format: "%.2f", p.leanDeg),
                String(format: "%.3f", p.gForce),
                p.latitude  != 0 ? String(format: "%.6f", p.latitude)  : "",
                p.longitude != 0 ? String(format: "%.6f", p.longitude) : "",
                String(format: "%.1f", p.altitudeM),
                p.headingDeg >= 0 ? String(format: "%.1f", p.headingDeg) : "",
                p.isMoving ? "1" : "0",
                p.rpm.map(String.init) ?? "",
                p.gear.map(String.init) ?? "",
                p.throttle.map(String.init) ?? "",
                csvField(track(at: p.timestamp)?.label ?? "")
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: — Statystyki silnika z trasy (tylko gdy mostek CAN podawał dane)

struct EngineStats: Equatable {
    var maxRPM = 0
    var avgRPM = 0                 // średnia w ruchu
    var gearSeconds = [Double](repeating: 0, count: 7)   // 0 = luz, 1–6
    var shifts = 0                 // zmiany między biegami 1–6 (wrzucenie z luzu się nie liczy)
    var coverage = 0.0             // jaka część punktów trasy ma dane z silnika (0…1)

    /// Udział czasu na biegach 1–6 (suma = 1), do słupków w podsumowaniu.
    var gearShare: [Double] {
        let total = gearSeconds[1...].reduce(0, +)
        return total > 0 ? gearSeconds[1...].map { $0 / total } : [Double](repeating: 0, count: 6)
    }

    /// nil, gdy żaden punkt trasy nie ma danych z silnika.
    static func compute(_ points: [SessionPoint]) -> EngineStats? {
        var s = EngineStats()
        var withData = 0, movingRpmSum = 0, movingCount = 0
        var lastGear: Int? = nil
        for (i, p) in points.enumerated() {
            guard let rpm = p.rpm else { lastGear = nil; continue }
            withData += 1
            s.maxRPM = max(s.maxRPM, rpm)
            if p.isMoving { movingRpmSum += rpm; movingCount += 1 }
            guard let gear = p.gear, (0...6).contains(gear) else { continue }
            // Punkt reprezentuje odstęp do następnego; przerwy w nagraniu nie liczą się jako jazda.
            let dt = i + 1 < points.count ? points[i + 1].timestamp.timeIntervalSince(p.timestamp) : 1
            s.gearSeconds[gear] += (dt > 0 && dt <= 5) ? dt : 1
            if let last = lastGear, last != gear, last > 0, gear > 0 { s.shifts += 1 }
            lastGear = gear
        }
        guard withData > 0 else { return nil }
        s.avgRPM = movingCount > 0 ? movingRpmSum / movingCount : 0
        s.coverage = Double(withData) / Double(points.count)
        return s
    }
}

extension SessionSummary {
    var engineStats: EngineStats? { EngineStats.compute(points) }
}

// MARK: — Snapshot sesji w toku (auto-save co 30s na wypadek crasha/kill)

private struct InProgressSession: Codable {
    let sessionId:    UUID
    let startTime:    Date
    let points:       [SessionPoint]
    let maxSpeedKmh:  Double
    let maxLeanLeft:  Double
    let maxLeanRight: Double
    let maxGforce:    Double
    let currentDistKm: Double
    var tracks:       [SessionTrack]? = nil
}

// MARK: — SessionRecorder

final class SessionRecorder: ObservableObject {

    @Published var isRecording:    Bool         = false
    @Published var isPaused:       Bool         = false   // grace period — moto wyłączone, nie zapisujemy postoju
    /// Pomijaj stacjonarne punkty w trasie (żeby postój nie tworzył martwych wierszy).
    /// Czytane na żywo z ustawień (@AppStorage "skipIdlePoints"); domyślnie ON.
    var skipIdlePoints: Bool { UserDefaults.standard.object(forKey: "skipIdlePoints") as? Bool ?? true }
    /// Czy motocykl jest połączony (BT/TCP) — wstrzykiwane co 1s z ContentView.
    /// Postój Z motocyklem (światła, korek) NALEŻY do trasy → zapisujemy.
    /// Pomijamy tylko postój BEZ motocykla (telefon leży, sesja standalone).
    var isBikeConnected: Bool = false
    @Published var pointCount:     Int          = 0
    @Published var currentDistKm:  Double       = 0
    @Published var recordingSec:   Int          = 0

    private var points:      [SessionPoint] = []
    private var startTime:   Date           = Date()
    private var sessionId:   UUID           = UUID()
    private var recordTimer: DispatchSourceTimer?
    private var secTimer:    DispatchSourceTimer?

    // MARK: — Auto-save (crash / iOS kill recovery)

    private var tempURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("session_inprogress.json")
    }

    /// Czy istnieje przerwana sesja do odzyskania
    var hasInterruptedSession: Bool {
        FileManager.default.fileExists(atPath: tempURL.path)
    }

    /// Odczytuje przerwaną sesję z dysku i zapisuje ją do biblioteki.
    /// Zwraca podsumowanie gotowe do pokazania użytkownikowi.
    func recoverInterruptedSession() -> SessionSummary? {
        guard let data     = try? Data(contentsOf: tempURL),
              let snapshot = try? JSONDecoder().decode(InProgressSession.self, from: data),
              !snapshot.points.isEmpty
        else {
            clearInterruptedSession()
            return nil
        }
        let movingPts = snapshot.points.filter { $0.isMoving }
        let avgSpeed  = movingPts.isEmpty ? 0.0
            : movingPts.reduce(0) { $0 + $1.speedKmh } / Double(movingPts.count)
        let end = snapshot.points.last?.timestamp ?? Date()
        let snapPlayed = SessionTrack.played(snapshot.tracks ?? [], until: end)
        let summary = SessionSummary(
            id:           snapshot.sessionId,
            startTime:    snapshot.startTime,
            endTime:      end,
            totalDistKm:  snapshot.currentDistKm,
            maxSpeedKmh:  snapshot.maxSpeedKmh,
            avgSpeedKmh:  avgSpeed,
            maxLeanLeft:  snapshot.maxLeanLeft,
            maxLeanRight: snapshot.maxLeanRight,
            maxGforce:    snapshot.maxGforce,
            points:       snapshot.points,
            tracks:       snapPlayed.isEmpty ? nil : snapPlayed
        )
        clearInterruptedSession()
        try? SessionStorage.shared.save(summary)
        return summary
    }

    func clearInterruptedSession() {
        try? FileManager.default.removeItem(at: tempURL)
    }

    /// Zapisuje aktualny stan sesji na dysk (co 30 punktów = co 30s)
    private func autoSave() {
        let snapshot = InProgressSession(
            sessionId:    sessionId,
            startTime:    startTime,
            points:       points,
            maxSpeedKmh:  maxSpeedKmh,
            maxLeanLeft:  maxLeanLeft,
            maxLeanRight: maxLeanRight,
            maxGforce:    maxGforce,
            currentDistKm: currentDistKm,
            tracks:       tracks
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: tempURL, options: .atomic)
    }

    // Snapshoty danych — ustawiane z zewnątrz (ContentView) co 1s
    var latestSpeed:        Double = 0
    var latestLean:         Double = 0
    var latestGforce:       Double = 0
    var latestLatitude:     Double = 0
    var latestLongitude:    Double = 0
    var latestAltitude:     Double = 0
    var latestHeading:      Double = -1
    /// Świeże dane z silnika (mostek CAN) albo nil — ustawiane razem z resztą co 1 s.
    var latestEngine: (rpm: Int, gear: Int, throttle: Int)? = nil
    /// Grający teraz utwór (nil = nic nie gra) — ustawiane razem z resztą co 1 s.
    var latestTrack: (title: String, artist: String)? = nil
    private var tracks: [SessionTrack] = []
    // Max lean z MotionManager (30Hz) — dokładniejsze niż liczenie z 1Hz latestLean
    var latestMaxLeanLeft:  Double = 0
    var latestMaxLeanRight: Double = 0

    // Statystyki (zamrażane gdy telefon zdjęty)
    private(set) var maxSpeedKmh:  Double = 0
    private(set) var maxLeanLeft:  Double = 0
    private(set) var maxLeanRight: Double = 0
    private(set) var maxGforce:    Double = 0

    // Zamrażanie danych gdy telefon zdjęty z uchwytu (prędkość < 10 km/h)
    private var slowSince: Date? = nil

    // MARK: — Start / Stop

    /// Pauza zapisu punktów (grace period — moto wyłączone). Sesja pozostaje aktywna.
    func pause()  { isPaused = true }
    /// Wznowienie po powrocie BT motocykla.
    func resume() { isPaused = false }

    func start() {
        guard !isRecording else { return }
        isRecording    = true
        isPaused       = false
        startTime      = Date()
        sessionId      = UUID()
        recordingSec   = 0
        pointCount     = 0
        currentDistKm  = 0
        maxSpeedKmh    = 0
        maxLeanLeft    = 0
        maxLeanRight   = 0
        maxGforce      = 0
        slowSince      = nil
        points.removeAll()
        tracks.removeAll()

        // Timer punktów danych — co 1s
        let rt = DispatchSource.makeTimerSource(queue: .main)
        rt.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(200))
        rt.setEventHandler { [weak self] in self?.recordPoint() }
        rt.resume()
        recordTimer = rt

        // Timer czasu sesji — co 1s
        let st = DispatchSource.makeTimerSource(queue: .main)
        st.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(200))
        st.setEventHandler { [weak self] in
            guard let self, self.isRecording else { return }
            self.recordingSec += 1
        }
        st.resume()
        secTimer = st
    }

    /// Zatrzymuje nagrywanie i zwraca podsumowanie sesji.
    func stop() -> SessionSummary? {
        guard isRecording else { return nil }
        isRecording = false
        isPaused    = false
        recordTimer?.cancel(); recordTimer = nil
        secTimer?.cancel();    secTimer    = nil

        guard !points.isEmpty else { return nil }

        let movingPoints = points.filter { $0.isMoving }
        let avgSpeed     = movingPoints.isEmpty ? 0
            : movingPoints.reduce(0) { $0 + $1.speedKmh } / Double(movingPoints.count)

        let endTime = Date()
        let played = SessionTrack.played(tracks, until: endTime)
        let summary = SessionSummary(
            id:           sessionId,
            startTime:    startTime,
            endTime:      endTime,
            totalDistKm:  currentDistKm,
            maxSpeedKmh:  maxSpeedKmh,
            avgSpeedKmh:  avgSpeed,
            maxLeanLeft:  maxLeanLeft,
            maxLeanRight: maxLeanRight,
            maxGforce:    maxGforce,
            points:       points,
            tracks:       played.isEmpty ? nil : played
        )
        // Auto-save na dysk — sesja jest dostępna w bibliotece nawet po restarcie app
        try? SessionStorage.shared.save(summary)
        clearInterruptedSession()   // wyczyść temp plik — sesja bezpiecznie zapisana
        return summary
    }

    // MARK: — Zapis punktu

    private func recordPoint() {
        guard isRecording else { return }
        // Grace period: moto wyłączone, BT zerwane → nie zapisuj postoju
        // (inaczej nabilibyśmy tysiące stacjonarnych punktów w jednym miejscu).
        guard !isPaused else { return }
        noteTrack()
        let kmh     = latestSpeed
        let isMoving = kmh > 10   // < 10 km/h = stój/zdejmowanie telefonu — nie licz leanu

        // POMIJANIE POSTOJU: tylko gdy stoisz BEZ połączenia z motocyklem.
        // Postój na światłach/w korku (motocykl podłączony) to część trasy → zapisujemy.
        // Pomijamy dopiero „martwy" postój bez moto (telefon leży, sesja standalone) —
        // inaczej godzinny postój = godzina pustych wierszy w CSV.
        if !isMoving && skipIdlePoints && !isBikeConnected { return }

        // Aktualizuj statystyki max-speed i gforce zawsze
        if kmh > maxSpeedKmh { maxSpeedKmh = kmh }
        if latestGforce > maxGforce { maxGforce = latestGforce }

        // Lean: aktualizuj tylko gdy jedzie > 10 km/h (telefon na uchwycie, koła toczą się)
        if isMoving {
            slowSince = nil
            // Używamy max lean z MotionManager (30Hz) — spójne z wyświetlaczem
            maxLeanLeft  = max(maxLeanLeft,  latestMaxLeanLeft)
            maxLeanRight = max(maxLeanRight, latestMaxLeanRight)
        } else {
            if slowSince == nil { slowSince = Date() }
        }

        // Lean zapisujemy TYLKO w ruchu. Na postoju (telefon w pochylonym uchwycie)
        // surowy kąt = offset montażu, nie realny przechył — zapis 0, żeby nie zaśmiecać
        // trasy fałszywym przechyłem w miejscu.
        let recordedLean = isMoving ? latestLean : 0.0
        let pt = SessionPoint(
            id:         points.count,
            timestamp:  Date(),
            speedKmh:   kmh,
            leanDeg:    recordedLean,
            gForce:     latestGforce,
            latitude:   latestLatitude,
            longitude:  latestLongitude,
            altitudeM:  latestAltitude,
            headingDeg: latestHeading,
            isMoving:   isMoving,
            rpm:        latestEngine?.rpm,
            gear:       latestEngine?.gear,
            throttle:   latestEngine?.throttle
        )
        points.append(pt)
        pointCount = points.count

        // Szacowany dystans (integracja prędkości × dt = 1s) — liczymy od 1 km/h (nie 10)
        // żeby GPS-owy dystans był ciągły nawet przy powolnej jeździe
        if kmh > 1 { currentDistKm += kmh / 3600.0 }

        // Auto-save co 30 punktów (co ~30s) — chroni przed crashem / iOS kill
        if points.count % 30 == 0 { autoSave() }
    }

    /// Nowy utwór → wpis z bieżącą chwilą. Pauza niczego nie zapisuje (po wznowieniu ten sam utwór
    /// nie tworzy drugiego wpisu).
    private func noteTrack() {
        guard let t = latestTrack, !t.title.isEmpty else { return }
        if let last = tracks.last, last.title == t.title, last.artist == t.artist { return }
        tracks.append(SessionTrack(time: Date(), title: t.title, artist: t.artist))
    }
}
