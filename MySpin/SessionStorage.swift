// SessionStorage.swift
// Persystencja sesji jazdy na dysk telefonu (Documents/sessions/<UUID>.json).
//
// Format: JSON skompresowany (gzip nie warto — sesje 1h to ~200KB JSON).
// Index: SessionMeta — lekki rekord do listy w UI bez ładowania pełnych punktów.

import Foundation
import Combine

// MARK: — Lekki rekord do listy

/// Metadane sesji — to co potrzebujemy w bibliotece bez ładowania wszystkich punktów GPS.
struct SessionMeta: Identifiable, Codable, Equatable {
    let id:           UUID
    let startTime:    Date
    let endTime:      Date
    let totalDistKm:  Double
    let maxSpeedKmh:  Double
    let maxLeanLeft:  Double
    let maxLeanRight: Double
    let pointCount:   Int
    let isMerged:     Bool

    var durationSec: Int { Int(endTime.timeIntervalSince(startTime)) }

    init(from summary: SessionSummary) {
        self.id           = summary.id
        self.startTime    = summary.startTime
        self.endTime      = summary.endTime
        self.totalDistKm  = summary.totalDistKm
        self.maxSpeedKmh  = summary.maxSpeedKmh
        // Sanityzacja: stare sesje mogą mieć zepsute lean (artefakt Eulera ~180°).
        // Motocykl fizycznie nie przekracza ~65° → tnij do 75°.
        self.maxLeanLeft  = min(summary.maxLeanLeft,  75)
        self.maxLeanRight = min(summary.maxLeanRight, 75)
        self.pointCount   = summary.points.count
        self.isMerged     = summary.mergedFromIDs != nil
    }

    // Custom Codable init: stare .meta pliki bez pola isMerged → fallback false
    init(from decoder: Decoder) throws {
        let c         = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(UUID.self,   forKey: .id)
        startTime     = try c.decode(Date.self,   forKey: .startTime)
        endTime       = try c.decode(Date.self,   forKey: .endTime)
        totalDistKm   = try c.decode(Double.self, forKey: .totalDistKm)
        maxSpeedKmh   = try c.decode(Double.self, forKey: .maxSpeedKmh)
        maxLeanLeft   = try c.decode(Double.self, forKey: .maxLeanLeft)
        maxLeanRight  = try c.decode(Double.self, forKey: .maxLeanRight)
        pointCount    = try c.decode(Int.self,    forKey: .pointCount)
        isMerged      = try c.decodeIfPresent(Bool.self, forKey: .isMerged) ?? false
    }
}

// MARK: — Storage

/// Singleton — zarządza katalogiem `Documents/sessions/`.
/// Każda sesja: jeden plik `<uuid>.json` + jeden plik `<uuid>.meta` (lekki rekord).
final class SessionStorage: ObservableObject {
    static let shared = SessionStorage()

    /// @Published — UI biblioteki re-renderuje się gdy lista się zmieni.
    @Published private(set) var library: [SessionMeta] = []

    private let dir: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        // Documents/sessions/
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        reloadLibrary()
    }

    // MARK: — API

    /// Zapisuje sesję do pliku JSON + odświeża indeks.
    func save(_ summary: SessionSummary) throws {
        let url     = fileURL(for: summary.id)
        let metaURL = metaFileURL(for: summary.id)
        let data    = try encoder.encode(summary)
        try data.write(to: url, options: .atomic)
        let meta    = SessionMeta(from: summary)
        let metaData = try encoder.encode(meta)
        try metaData.write(to: metaURL, options: .atomic)

        // Odśwież listę na main thread; kopia do folderu w iCloud Drive (jeśli podłączony)
        DispatchQueue.main.async { [weak self] in
            self?.reloadLibrary()
            RouteCloudSync.shared.sync()
        }
    }

    /// Wczytuje pełną sesję (z punktami) — używane przy odtwarzaniu.
    /// Starsze trasy mogą być już tylko w folderze iCloud Drive (RouteCloudSync) — wtedy
    /// plik jest stamtąd ściągany (chwilę to trwa, potrzebny internet).
    func load(id: UUID) -> SessionSummary? {
        let url = fileURL(for: id)
        guard let data = (try? Data(contentsOf: url)) ?? RouteCloudSync.shared.cloudData(url.lastPathComponent),
              let summary = try? decoder.decode(SessionSummary.self, from: data)
        else { return nil }
        return summary
    }

    /// Usuwa sesję z dysku + odświeża indeks.
    func delete(id: UUID) {
        RouteCloudSync.shared.deleteFromCloud(id)
        try? FileManager.default.removeItem(at: fileURL(for: id))
        try? FileManager.default.removeItem(at: metaFileURL(for: id))
        DispatchQueue.main.async { [weak self] in self?.reloadLibrary() }
    }

    /// Zwraca URL pliku JSON sesji — np. dla CSV export sharing.
    func fileURL(for id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).json")
    }

    private func metaFileURL(for id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).meta")
    }

    // MARK: — Indeks

    // MARK: — Concatenate sessions

    /// Łączy wybrane sesje w jedną nową — punkty są time-shifted tak,
    /// żeby nie było dziur między kolejnymi sesjami (logiczna konkatenacja).
    /// Statystyki: max ze wszystkich, dystans = suma, średnia = punkty-ważona.
    /// Zapisuje rezultat do storage i zwraca jego ID.
    @discardableResult
    func concatenate(_ summaries: [SessionSummary]) -> SessionSummary? {
        guard !summaries.isEmpty else { return nil }
        let sorted = summaries.sorted { $0.startTime < $1.startTime }

        let baseStart = sorted[0].startTime
        var allPoints: [SessionPoint] = []
        var allTracks: [SessionTrack] = []
        var cumulative: TimeInterval = 0

        for s in sorted {
            let shift = baseStart.addingTimeInterval(cumulative).timeIntervalSince(s.startTime)
            for t in s.tracks ?? [] {
                allTracks.append(SessionTrack(time: t.time.addingTimeInterval(shift), title: t.title, artist: t.artist))
            }
            for p in s.points {
                let timeIn = p.timestamp.timeIntervalSince(s.startTime)
                let newTs  = baseStart.addingTimeInterval(cumulative + timeIn)
                allPoints.append(SessionPoint(
                    id:         allPoints.count,
                    timestamp:  newTs,
                    speedKmh:   p.speedKmh,
                    leanDeg:    p.leanDeg,
                    gForce:     p.gForce,
                    latitude:   p.latitude,
                    longitude:  p.longitude,
                    altitudeM:  p.altitudeM,
                    headingDeg: p.headingDeg,
                    isMoving:   p.isMoving,
                    rpm: p.rpm, gear: p.gear, throttle: p.throttle
                ))
            }
            cumulative += s.endTime.timeIntervalSince(s.startTime)
        }

        let movingPts = allPoints.filter { $0.isMoving }
        let avgSpeed: Double = movingPts.isEmpty ? 0
            : movingPts.reduce(0) { $0 + $1.speedKmh } / Double(movingPts.count)

        // Granice segmentów — ile punktów miały poprzednie sesje (skumulowane)
        var boundaries: [Int] = [0]
        var acc = 0
        for s in sorted.dropLast() {
            acc += s.points.count
            boundaries.append(acc)
        }

        let merged = SessionSummary(
            id:           UUID(),
            startTime:    baseStart,
            endTime:      baseStart.addingTimeInterval(cumulative),
            totalDistKm:  sorted.reduce(0) { $0 + $1.totalDistKm },
            maxSpeedKmh:  sorted.map(\.maxSpeedKmh).max() ?? 0,
            avgSpeedKmh:  avgSpeed,
            maxLeanLeft:  sorted.map(\.maxLeanLeft).max()  ?? 0,
            maxLeanRight: sorted.map(\.maxLeanRight).max() ?? 0,
            maxGforce:    sorted.map(\.maxGforce).max()    ?? 0,
            points:       allPoints,
            mergedFromIDs:           sorted.map(\.id),
            mergedSegmentBoundaries: boundaries,
            tracks:                  allTracks.isEmpty ? nil : allTracks
        )

        do {
            try save(merged)
            // Usuń źródłowe sesje — są już zawarte w scalonej
            for s in sorted { delete(id: s.id) }
            return merged
        } catch {
            print("[SessionStorage] concatenate save failed: \(error)")
            return nil
        }
    }

    /// Rozdziela scaloną sesję z powrotem na oryginalne segmenty.
    /// Zwraca tablicę nowych SessionSummary (zapisane na dysku) lub nil gdy brak metadanych.
    @discardableResult
    func split(_ summary: SessionSummary) -> [SessionSummary]? {
        guard let boundaries = summary.mergedSegmentBoundaries,
              !boundaries.isEmpty else { return nil }
        let pts = summary.points
        var results: [SessionSummary] = []
        for i in 0..<boundaries.count {
            let start = boundaries[i]
            let end   = i + 1 < boundaries.count ? boundaries[i + 1] : pts.count
            guard start < end, end <= pts.count else { continue }
            let segPts = pts[start..<end].enumerated().map { (idx, p) in
                SessionPoint(id: idx, timestamp: p.timestamp, speedKmh: p.speedKmh,
                             leanDeg: p.leanDeg, gForce: p.gForce,
                             latitude: p.latitude, longitude: p.longitude,
                             altitudeM: p.altitudeM, headingDeg: p.headingDeg,
                             isMoving: p.isMoving,
                             rpm: p.rpm, gear: p.gear, throttle: p.throttle)
            }
            let movPts = segPts.filter { $0.isMoving }
            let avgV: Double = movPts.isEmpty ? 0
                : movPts.reduce(0) { $0 + $1.speedKmh } / Double(movPts.count)
            let seg = SessionSummary(
                id:           UUID(),
                startTime:    segPts.first!.timestamp,
                endTime:      segPts.last!.timestamp,
                totalDistKm:  0,   // nie da się odtworzyć dokładnie bez GPS kolejnych punktów
                maxSpeedKmh:  segPts.map(\.speedKmh).max() ?? 0,
                avgSpeedKmh:  avgV,
                maxLeanLeft:  segPts.filter { $0.leanDeg < 0 }.map { -$0.leanDeg }.max() ?? 0,
                maxLeanRight: segPts.filter { $0.leanDeg > 0 }.map(\.leanDeg).max() ?? 0,
                maxGforce:    segPts.map(\.gForce).max() ?? 0,
                points:       Array(segPts),
                tracks:       Self.tracks(of: summary, from: segPts.first!.timestamp, to: segPts.last!.timestamp)
            )
            if let saved = try? { try save(seg); return seg }() { results.append(saved) }
        }
        // Usuń scaloną sesję
        delete(id: summary.id)
        return results.isEmpty ? nil : results
    }

    /// Utwory segmentu: grający na jego starcie (z czasem startu segmentu) + rozpoczęte w trakcie.
    private static func tracks(of s: SessionSummary, from: Date, to: Date) -> [SessionTrack]? {
        var out: [SessionTrack] = []
        if let first = s.track(at: from) { out.append(SessionTrack(time: from, title: first.title, artist: first.artist)) }
        out += (s.tracks ?? []).filter { $0.time > from && $0.time <= to }
        return out.isEmpty ? nil : out
    }

    /// Skanuje katalog, czyta meta-pliki, sortuje malejąco po starcie.
    /// Jeśli .meta brakuje (sesja zapisana w starszej wersji) — pomija.
    private func reloadLibrary() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else {
            library = []
            return
        }
        let metas = files
            .filter { $0.pathExtension == "meta" }
            .compactMap { url -> SessionMeta? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SessionMeta.self, from: data)
            }
            .sorted { $0.startTime > $1.startTime }
        library = metas
    }
}
