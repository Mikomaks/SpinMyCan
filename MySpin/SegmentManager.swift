// SegmentManager.swift
// ULUBIONE ODCINKI — nagrywasz kawałek drogi (start → stop), a przy każdym
// kolejnym przejeździe apka sama go rozpoznaje i pokazuje na żywo, ile jesteś
// przed albo za swoim najlepszym czasem.
//
// Jak to działa:
//   • NAGRYWANIE: „Nagraj odcinek" → jedziesz → „Zakończ". Zapisujemy ślad
//     (pozycja, dystans od startu, czas od startu, prędkość, przechył).
//     Postój na początku i końcu jest przycinany — odcinek zaczyna się tam,
//     gdzie faktycznie ruszyłeś.
//   • ROZPOZNANIE: start i meta to BRAMKI — odcinki prostopadłe do kierunku
//     jazdy. Przejazd liczy się, gdy przetniesz bramkę startu we właściwą stronę
//     (z drugiej strony drogi albo w przeciwnym kierunku się nie załapie).
//     Chwilę przecięcia interpolujemy między dwiema próbkami GPS, więc czas
//     nie skacze o całą sekundę mimo próbkowania 1 Hz.
//   • NA ŻYWO: bieżącą pozycję rzutujemy na ślad najlepszego przejazdu i
//     porównujemy czas w TYM SAMYM miejscu drogi: delta = mój czas − rekord.
//   • META: przecięcie bramki mety → przejazd trafia do historii; lepszy czas
//     staje się nowym profilem odniesienia.
//
// Wszystko dzieje się na głównym wątku (heartbeat 1 Hz). Renderer czyta tylko
// `chipSnapshot()` — pod blokadą, bo rysuje na wątku tła.

import Foundation
import CoreLocation
import Combine

struct SegPoint: Codable, Equatable {
    var lat: Double
    var lon: Double
    var d: Double        // metry od startu odcinka
    var t: Double        // sekundy od startu
    var kmh: Double
    var lean: Double
}

struct SegRun: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var timeSec: Double
    var maxLeanL: Double
    var maxLeanR: Double
    var vmax: Double
    var avgKmh: Double
}

struct Segment: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var created: Date
    /// Geometria + profil czasu NAJLEPSZEGO przejazdu (do porównań na żywo).
    var points: [SegPoint]
    var runs: [SegRun]

    var lengthM: Double { points.last?.d ?? 0 }
    var best: SegRun? { runs.min { $0.timeSec < $1.timeSec } }
}

/// Płaski układ lokalny (metry) wokół punktu odniesienia. Na dystansach
/// odcinka (kilka–kilkadziesiąt km) błąd rzutu jest pomijalny wobec GPS.
private struct Flat {
    let lat0: Double, lon0: Double, kx: Double
    init(lat: Double, lon: Double) {
        lat0 = lat; lon0 = lon; kx = cos(lat * .pi / 180)
    }
    func xy(_ lat: Double, _ lon: Double) -> (x: Double, y: Double) {
        ((lon - lon0) * 111_320 * kx, (lat - lat0) * 110_540)
    }
}

/// Bramka: punkt + kierunek jazdy. `along` < 0 = jeszcze przed bramką.
private struct Gate {
    let flat: Flat
    let dx: Double, dy: Double
    init?(at p: SegPoint, toward q: SegPoint) {
        flat = Flat(lat: p.lat, lon: p.lon)
        let v = flat.xy(q.lat, q.lon)
        let len = (v.x * v.x + v.y * v.y).squareRoot()
        guard len > 1 else { return nil }
        dx = v.x / len; dy = v.y / len
    }
    func coords(_ lat: Double, _ lon: Double) -> (along: Double, lateral: Double) {
        let p = flat.xy(lat, lon)
        return (p.x * dx + p.y * dy, -p.x * dy + p.y * dx)
    }
}

final class SegmentManager: ObservableObject {

    // MARK: — Stan publiczny (UI)

    @Published private(set) var segments: [Segment] = []
    @Published private(set) var isRecording = false
    @Published private(set) var recDistM: Double = 0
    @Published private(set) var recSec: Double = 0
    /// Opis dla UI: „Na odcinku: Przełęcz  −1.2 s" / wynik ostatniego przejazdu.
    @Published private(set) var liveText = ""
    @Published private(set) var liveActive = false

    // MARK: — Parametry

    static let gateHalfWidthM = 40.0     // pół szerokości bramki (GPS + szerokość drogi)
    static let minLengthM     = 150.0    // krótszych odcinków nie zapisujemy
    static let offRouteM      = 80.0     // dalej od śladu = zjechałeś z odcinka
    static let resultShowSec  = 12.0

    // MARK: — Prywatne

    private let storeURL: URL
    private let lock = NSLock()
    private var chip: DashChip? = nil

    // nagrywanie nowego odcinka
    private var recTrace: [SegPoint] = []
    private var recStart: Date? = nil
    private var recLast: CLLocation? = nil

    // dopasowanie na żywo
    private struct Live {
        var segID: UUID
        var start: Date            // interpolowana chwila przecięcia bramki startu
        var idx = 0                // indeks punktu odniesienia, za którym jesteśmy
        var trace: [SegPoint] = []
        var maxL = 0.0, maxR = 0.0, vmax = 0.0
        var off = 0                // kolejne próbki poza śladem
        var delta = 0.0
        var progress = 0.0
    }
    private var live: Live? = nil
    private var prevSample: (lat: Double, lon: Double, time: Date)? = nil
    private var resultUntil: Date? = nil
    private var gates: [UUID: (start: Gate, finish: Gate)] = [:]

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("segments.json")
        load()
    }

    // MARK: — Dane dla renderera (wątek tła)

    func chipSnapshot() -> DashChip? {
        lock.lock(); defer { lock.unlock() }
        return chip
    }
    private func setChip(_ c: DashChip?) {
        lock.lock(); chip = c; lock.unlock()
    }

    // MARK: — Nagrywanie nowego odcinka

    func startRecording() {
        guard !isRecording else { return }
        live = nil; liveActive = false
        recTrace = []; recStart = nil; recLast = nil
        recDistM = 0; recSec = 0
        isRecording = true
        liveText = "Nagrywam odcinek…"
        setChip(DashChip(text: "● ODCINEK 0.0 km", tone: .warn))
    }

    func cancelRecording() {
        isRecording = false
        recTrace = []; recStart = nil; recLast = nil
        liveText = ""
        setChip(nil)
    }

    /// Kończy nagrywanie i zapisuje odcinek. Zwraca nil, gdy wszystko OK,
    /// albo powód odrzucenia do pokazania użytkownikowi.
    @discardableResult
    func finishRecording(name: String) -> String? {
        guard isRecording else { return "Nie nagrywam" }
        let trace = Self.trimmed(recTrace)
        isRecording = false
        recTrace = []; recStart = nil; recLast = nil
        liveText = ""
        setChip(nil)

        guard trace.count >= 5, let last = trace.last, last.d >= Self.minLengthM else {
            return "Za krótki odcinek — potrzeba co najmniej \(Int(Self.minLengthM)) m jazdy"
        }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = Self.run(from: trace, date: Date())
        var seg = Segment(name: clean.isEmpty ? "Odcinek \(segments.count + 1)" : clean,
                          created: Date(), points: trace, runs: [first])
        seg.id = UUID()
        segments.insert(seg, at: 0)
        rebuildGates()
        save()
        return nil
    }

    /// Obcina postój na początku i końcu, a dystans i czas liczy od nowego startu.
    private static func trimmed(_ pts: [SegPoint]) -> [SegPoint] {
        guard let a = pts.firstIndex(where: { $0.kmh >= 8 }),
              let b = pts.lastIndex(where: { $0.kmh >= 8 }), b > a else { return [] }
        let cut = Array(pts[a...b])
        let d0 = cut[0].d, t0 = cut[0].t
        return cut.map { var p = $0; p.d -= d0; p.t -= t0; return p }
    }

    private static func run(from trace: [SegPoint], date: Date) -> SegRun {
        let time = trace.last?.t ?? 0
        let len  = trace.last?.d ?? 0
        return SegRun(date: date, timeSec: time,
                      maxLeanL: -(trace.map { $0.lean }.min() ?? 0).clamped(-90, 0),
                      maxLeanR:  (trace.map { $0.lean }.max() ?? 0).clamped(0, 90),
                      vmax: trace.map { $0.kmh }.max() ?? 0,
                      avgKmh: time > 0 ? len / time * 3.6 : 0)
    }

    // MARK: — Zarządzanie listą

    func rename(_ id: UUID, to name: String) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        segments[i].name = clean
        save()
    }

    func delete(_ id: UUID) {
        if live?.segID == id { live = nil; liveActive = false; liveText = ""; setChip(nil) }
        segments.removeAll { $0.id == id }
        rebuildGates()
        save()
    }

    // MARK: — Próbka z GPS (heartbeat 1 Hz, główny wątek)

    /// `time` = znacznik czasu samego fixa GPS (nie chwila wywołania) — inaczej
    /// do pomiaru dochodziłby losowy poślizg heartbeatu.
    func ingest(coord: CLLocationCoordinate2D, speedKmh: Double, leanDeg: Double,
                accuracy: Double, time: Date) {
        // Wynik gaśnie wg zegara ściennego, a nie czasu fixa — inaczej po utracie
        // GPS (tunel, garaż) pigułka z wynikiem wisiałaby na desce bez końca.
        expireResult()
        guard accuracy > 0, accuracy <= 50 else { return }
        // Ten sam fix drugi raz (GPS wolniejszy niż heartbeat) — nic nowego.
        if let p = prevSample, p.time == time { return }
        defer { prevSample = (coord.latitude, coord.longitude, time) }

        if isRecording {
            ingestRecording(coord, speedKmh, leanDeg, time)
            return
        }
        if live != nil {
            ingestLive(coord, speedKmh, leanDeg, time)
        } else {
            detectStart(coord, speedKmh, time)
        }
    }

    private func expireResult() {
        if live == nil, !isRecording, let u = resultUntil, Date() >= u {
            resultUntil = nil; liveText = ""; setChip(nil)
        }
    }

    private func ingestRecording(_ c: CLLocationCoordinate2D, _ kmh: Double, _ lean: Double, _ time: Date) {
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        if recStart == nil { recStart = time }
        let hop = recLast.map { here.distance(from: $0) } ?? 0
        // Stanie w miejscu: GPS „pływa" o metr-dwa i nabijałby fałszywy dystans.
        if recLast != nil, hop < 2 { recSec = time.timeIntervalSince(recStart!); return }
        recDistM += recLast == nil ? 0 : hop
        recLast = here
        recSec = time.timeIntervalSince(recStart!)
        recTrace.append(SegPoint(lat: c.latitude, lon: c.longitude, d: recDistM, t: recSec,
                                 kmh: kmh, lean: lean))
        setChip(DashChip(text: String(format: "● ODCINEK %.1f km", recDistM / 1000), tone: .warn))
    }

    /// Szuka przecięcia bramki startu któregokolwiek odcinka.
    private func detectStart(_ c: CLLocationCoordinate2D, _ kmh: Double, _ time: Date) {
        guard let prev = prevSample, kmh >= 10 else { return }
        for seg in segments {
            guard let g = gates[seg.id]?.start,
                  let tCross = Self.crossing(g, prev: prev, lat: c.latitude, lon: c.longitude, time: time)
            else { continue }
            var l = Live(segID: seg.id, start: tCross)
            l.trace = [SegPoint(lat: seg.points[0].lat, lon: seg.points[0].lon, d: 0, t: 0, kmh: kmh, lean: 0)]
            live = l
            liveActive = true
            resultUntil = nil
            ingestLive(c, kmh, 0, time)
            return
        }
    }

    /// Chwila przecięcia bramki między poprzednią a bieżącą próbką (albo nil).
    private static func crossing(_ g: Gate, prev: (lat: Double, lon: Double, time: Date),
                                 lat: Double, lon: Double, time: Date) -> Date? {
        let a = g.coords(prev.lat, prev.lon), b = g.coords(lat, lon)
        // Z „przed" na „za", bez teleportów (dziura w GPS nie może udawać przejazdu).
        guard a.along < 0, b.along >= 0, a.along > -250, b.along < 250 else { return nil }
        let u = -a.along / (b.along - a.along)
        let lateral = a.lateral + u * (b.lateral - a.lateral)
        guard abs(lateral) <= gateHalfWidthM else { return nil }
        return prev.time.addingTimeInterval(u * time.timeIntervalSince(prev.time))
    }

    private func ingestLive(_ c: CLLocationCoordinate2D, _ kmh: Double, _ lean: Double, _ time: Date) {
        guard var l = live, let si = segments.firstIndex(where: { $0.id == l.segID }) else {
            live = nil; liveActive = false; return
        }
        let seg = segments[si]
        let pts = seg.points
        let elapsed = time.timeIntervalSince(l.start)

        // ── Rzut na ślad odniesienia: szukamy tylko w przód od ostatniego miejsca ──
        let flat = Flat(lat: pts[0].lat, lon: pts[0].lon)
        let p = flat.xy(c.latitude, c.longitude)
        var bestDist = Double.greatestFiniteMagnitude, bestJ = l.idx, bestU = 0.0
        let hi = min(pts.count - 2, l.idx + 30)
        if l.idx <= hi {
            for j in l.idx...hi {
                let a = flat.xy(pts[j].lat, pts[j].lon), b = flat.xy(pts[j + 1].lat, pts[j + 1].lon)
                let vx = b.x - a.x, vy = b.y - a.y
                let len2 = vx * vx + vy * vy
                let u = len2 > 0 ? (((p.x - a.x) * vx + (p.y - a.y) * vy) / len2).clamped(0, 1) : 0
                let qx = a.x + u * vx, qy = a.y + u * vy
                let dist = ((p.x - qx) * (p.x - qx) + (p.y - qy) * (p.y - qy)).squareRoot()
                if dist < bestDist { bestDist = dist; bestJ = j; bestU = u }
            }
        }
        let A = pts[bestJ], B = pts[min(bestJ + 1, pts.count - 1)]
        let dNow = A.d + bestU * (B.d - A.d)
        let refT = A.t + bestU * (B.t - A.t)
        l.idx = bestJ
        l.progress = max(l.progress, dNow)
        l.delta = elapsed - refT
        l.vmax = max(l.vmax, kmh)
        if lean < 0 { l.maxL = max(l.maxL, -lean) } else { l.maxR = max(l.maxR, lean) }

        // ── Meta — sprawdzana ZANIM próbka trafi do śladu. Próbka, która wykrywa
        //    przecięcie, leży już ZA bramką; gdyby weszła do śladu, nowy rekord
        //    przesuwałby metę o kilka metrów przy każdym pobiciu czasu. ──
        if l.progress >= seg.lengthM * 0.8, let prev = prevSample, let g = gates[seg.id]?.finish,
           let tEnd = Self.crossing(g, prev: prev, lat: c.latitude, lon: c.longitude, time: time) {
            finishRun(l, segIndex: si, end: tEnd)
            return
        }

        l.trace.append(SegPoint(lat: c.latitude, lon: c.longitude, d: l.progress, t: elapsed,
                                kmh: kmh, lean: lean))

        // ── Zjazd z odcinka albo porzucenie ──
        l.off = bestDist > Self.offRouteM ? l.off + 1 : 0
        let refTotal = pts.last?.t ?? 0
        if l.off >= 5 || elapsed > refTotal * 3 + 120 {
            live = nil; liveActive = false
            liveText = "Odcinek \(seg.name) przerwany"
            setChip(DashChip(text: "⏱ \(seg.name) — przerwany", tone: .quiet))
            resultUntil = Date().addingTimeInterval(6)
            return
        }

        live = l
        let sign = l.delta <= 0 ? "−" : "+"
        let txt = String(format: "⏱ %@  %@%.1f s", seg.name, sign, abs(l.delta))
        liveText = txt
        setChip(DashChip(text: txt, tone: l.delta <= 0 ? .good : .bad))
    }

    private func finishRun(_ l: Live, segIndex si: Int, end: Date) {
        var seg = segments[si]
        let time = end.timeIntervalSince(l.start)
        let prevBest = seg.best?.timeSec
        let run = SegRun(date: end, timeSec: time, maxLeanL: l.maxL, maxLeanR: l.maxR,
                         vmax: l.vmax, avgKmh: time > 0 ? seg.lengthM / time * 3.6 : 0)
        seg.runs.insert(run, at: 0)

        let isRecord = prevBest.map { time < $0 } ?? true
        if isRecord, let lastRef = seg.points.last {
            // Nowy rekord staje się profilem odniesienia. Domykamy ślad na mecie,
            // żeby długość i czas zgadzały się z wynikiem co do bramki.
            var trace = l.trace
            trace.append(SegPoint(lat: lastRef.lat, lon: lastRef.lon,
                                  d: max(seg.lengthM, trace.last?.d ?? 0), t: time,
                                  kmh: trace.last?.kmh ?? 0, lean: 0))
            // Dystans musi rosnąć — szum GPS potrafi cofnąć rzut o metr.
            var mono: [SegPoint] = []
            for p in trace where mono.isEmpty || p.d > mono.last!.d || p.t > mono.last!.t {
                var q = p; q.d = max(q.d, mono.last?.d ?? 0); mono.append(q)
            }
            if mono.count >= 5 { seg.points = mono }
        }
        segments[si] = seg
        rebuildGates()
        save()

        live = nil; liveActive = false
        let diff = prevBest.map { time - $0 }
        var txt = "🏁 \(seg.name)  \(Self.fmt(time))"
        if let d = diff { txt += String(format: "  %@%.1f s", d <= 0 ? "−" : "+", abs(d)) }
        if isRecord, prevBest != nil { txt += "  REKORD" }
        liveText = txt
        setChip(DashChip(text: txt, tone: isRecord ? .good : .bad))
        resultUntil = Date().addingTimeInterval(Self.resultShowSec)
    }

    static func fmt(_ sec: Double) -> String {
        let m = Int(sec) / 60
        let s = sec - Double(m * 60)
        return m > 0 ? String(format: "%d:%04.1f", m, s) : String(format: "%.1f s", s)
    }

    // MARK: — Bramki

    private func rebuildGates() {
        gates = [:]
        for seg in segments {
            let p = seg.points
            guard p.count >= 2, let first = p.first, let last = p.last else { continue }
            // Kierunek liczymy z punktu ~30 m dalej — sąsiednie próbki są za blisko,
            // żeby szum GPS nie przekręcił bramki.
            let ahead  = p.first(where: { $0.d >= 30 }) ?? last
            let behind = p.last(where: { last.d - $0.d >= 30 }) ?? first
            guard let gs = Gate(at: first, toward: ahead),
                  let dir = Gate(at: behind, toward: last) else { continue }
            // Bramka mety stoi W PUNKCIE mety, z kierunkiem dojazdu do niej.
            let gf = Gate(flat: Flat(lat: last.lat, lon: last.lon), dx: dir.dx, dy: dir.dy)
            gates[seg.id] = (gs, gf)
        }
    }

    // MARK: — Zapis

    private func load() {
        if let data = try? Data(contentsOf: storeURL),
           let list = try? JSONDecoder().decode([Segment].self, from: data) {
            segments = list
        }
        rebuildGates()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(segments) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

private extension Gate {
    init(flat: Flat, dx: Double, dy: Double) {
        self.flat = flat; self.dx = dx; self.dy = dy
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.max(lo, Swift.min(hi, self)) }
}
