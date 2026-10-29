// NavManager.swift
// Turn-by-turn nawigacja przez Apple MapKit (MKDirections) + głos (AVSpeech).
// Wyszukiwanie celu (MKLocalSearch), liczenie trasy, śledzenie kroków,
// dystans do najbliższego manewru, zapowiedzi głosowe.

import MapKit
import CoreLocation
import AVFoundation
import Combine

final class NavManager: NSObject, ObservableObject {

    @Published var isActive          = false
    @Published var destinationName   = ""
    @Published var nextInstruction   = "—"
    @Published var distanceToNext: Double = 0    // m do najbliższego manewru
    @Published var remainingDistance: Double = 0 // m
    @Published var remainingTime:  Double = 0    // s
    @Published var searchResults: [MKMapItem] = []
    @Published var statusNote = ""
    @Published var voiceEnabled = true

    private(set) var routeCoords: [CLLocationCoordinate2D] = []
    private var steps: [MKRoute.Step] = []
    private var stepIndex = 0
    private var routeSpeed: Double = 12   // m/s — do szacowania ETA
    private let synth = AVSpeechSynthesizer()
    private var lastSpoken = ""

    // MARK: — Wyszukiwanie celu

    func search(_ query: String, near coord: CLLocationCoordinate2D?) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        if let coord {
            req.region = MKCoordinateRegion(center: coord, latitudinalMeters: 40000, longitudinalMeters: 40000)
        }
        statusNote = String(localized: "Szukam…")
        MKLocalSearch(request: req).start { [weak self] resp, _ in
            DispatchQueue.main.async {
                self?.searchResults = resp?.mapItems ?? []
                self?.statusNote = (resp?.mapItems.isEmpty ?? true) ? String(localized: "Brak wyników") : ""
            }
        }
    }

    // MARK: — Cel z linku Apple Maps (udostępnij → kopiuj link → wklej)

    /// Parsuje link maps.apple.com i startuje nawigację do tych współrzędnych 1:1
    /// (ten sam silnik Apple = identyczna trasa co w Apple Maps).
    func navigateToAppleMapsLink(_ link: String, from coord: CLLocationCoordinate2D?) {
        navigateToSharedLink(link, name: nil, from: coord)
    }

    /// Wspólne wejście dla share sheet i „wklej link". Stare linki (?ll=…) parsujemy
    /// lokalnie; nowe krótkie (maps.apple/p/…) NIE mają współrzędnych w URL —
    /// pobieramy stronę przez sieć i wyciągamy je z przekierowania albo HTML.
    func navigateToSharedLink(_ link: String, name: String?, from coord: CLLocationCoordinate2D?) {
        if let dest = Self.parseCoordinate(from: link) {
            navigate(to: dest, name: name, from: coord)
            return
        }
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.hasPrefix("http") == true else {
            statusNote = String(localized: "Nie znalazłem współrzędnych w linku")
            return
        }
        statusNote = String(localized: "Rozwiązuję link…")
        URLSession.shared.dataTask(with: url) { [weak self] data, resp, _ in
            let finalURL = resp?.url?.absoluteString ?? ""
            let html = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let dest = Self.parseCoordinate(from: finalURL) ?? Self.extractCoordinate(fromHTML: html)
            DispatchQueue.main.async {
                guard let self else { return }
                if let dest {
                    self.navigate(to: dest, name: name, from: coord)
                } else {
                    self.statusNote = String(localized: "Link bez współrzędnych — użyj Udostępnij → MySpin Nawiguj")
                }
            }
        }.resume()
    }

    private func navigate(to dest: CLLocationCoordinate2D, name: String?, from coord: CLLocationCoordinate2D?) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: dest))
        item.name = name ?? String(localized: "Cel z Apple Maps")
        startNavigation(to: item, from: coord ?? dest)
    }

    /// Szuka pary lat,lon w HTML strony maps.apple.com (parametry snapshotów map,
    /// osadzony JSON miejsca itp.). Kolejność wzorców: od najbardziej wiarygodnych.
    static func extractCoordinate(fromHTML html: String) -> CLLocationCoordinate2D? {
        guard !html.isEmpty else { return nil }
        let patterns = [
            #"center=(-?\d+\.\d+)(?:,|%2C)(-?\d+\.\d+)"#,
            #"coordinate=(-?\d+\.\d+)(?:,|%2C)(-?\d+\.\d+)"#,
            #"[?&]ll=(-?\d+\.\d+)(?:,|%2C)(-?\d+\.\d+)"#,
            #""latitude"\s*:\s*(-?\d+\.\d+)\s*,\s*"longitude"\s*:\s*(-?\d+\.\d+)"#
        ]
        let range = NSRange(html.startIndex..., in: html)
        for pat in patterns {
            guard let re = try? NSRegularExpression(pattern: pat),
                  let m = re.firstMatch(in: html, range: range),
                  m.numberOfRanges >= 3,
                  let r1 = Range(m.range(at: 1), in: html),
                  let r2 = Range(m.range(at: 2), in: html),
                  let lat = Double(html[r1]), let lon = Double(html[r2]),
                  abs(lat) <= 90, abs(lon) <= 180, lat != 0 || lon != 0
            else { continue }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }

    /// Wyciąga „lat,lon" z parametrów linku Apple Maps (ll/daddr/coordinate/q/sll).
    static func parseCoordinate(from link: String) -> CLLocationCoordinate2D? {
        guard let comps = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let items = comps.queryItems ?? []
        for key in ["ll", "daddr", "coordinate", "sll", "center", "q"] {
            guard let v = items.first(where: { $0.name.lowercased() == key })?.value else { continue }
            let p = v.split(separator: ",")
            if p.count >= 2, let lat = Double(p[0]), let lon = Double(p[1]),
               abs(lat) <= 90, abs(lon) <= 180 {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        return nil
    }

    // MARK: — Start nawigacji

    func startNavigation(to item: MKMapItem, from coord: CLLocationCoordinate2D) {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: coord))
        req.destination = item
        req.transportType = .automobile
        statusNote = String(localized: "Liczę trasę…")
        MKDirections(request: req).calculate { [weak self] resp, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let route = resp?.routes.first else {
                    self.statusNote = String(localized: "Nie udało się policzyć trasy"); return
                }
                self.steps = route.steps
                self.stepIndex = 0
                self.routeCoords = route.polyline.coordinatesArray()
                self.destinationName = item.name ?? String(localized: "Cel")
                self.remainingDistance = route.distance
                self.remainingTime = route.expectedTravelTime
                self.routeSpeed = route.expectedTravelTime > 0 ? max(3, route.distance / route.expectedTravelTime) : 12
                self.isActive = true
                self.searchResults = []
                self.statusNote = ""
                self.advanceInstruction()
            }
        }
    }

    // MARK: — Aktualizacja pozycji (z GPS, ~1 Hz)

    func update(location: CLLocationCoordinate2D) {
        guard isActive, stepIndex < steps.count else { return }
        let here = CLLocation(latitude: location.latitude, longitude: location.longitude)

        guard let end = steps[stepIndex].polyline.coordinatesArray().last else { return }
        let toManeuver = here.distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        distanceToNext = toManeuver

        // Pozostały dystans = do manewru + suma przyszłych kroków
        var rest = toManeuver
        if stepIndex + 1 < steps.count {
            for i in (stepIndex+1)..<steps.count { rest += steps[i].distance }
        }
        remainingDistance = rest
        remainingTime = rest / routeSpeed

        // Osiągnięto manewr → następny krok
        if toManeuver < 25 {
            stepIndex += 1
            if stepIndex >= steps.count {
                arrived()
            } else {
                advanceInstruction()
            }
        }
    }

    private func advanceInstruction() {
        var idx = stepIndex
        while idx < steps.count && steps[idx].instructions.isEmpty { idx += 1 }
        let instr = idx < steps.count ? steps[idx].instructions : String(localized: "Kontynuuj prosto")
        nextInstruction = instr.isEmpty ? String(localized: "Jedź prosto") : instr
        speak(nextInstruction)
    }

    private func arrived() {
        nextInstruction = String(localized: "Dojechałeś do celu 🏁")
        distanceToNext = 0; remainingDistance = 0; remainingTime = 0
        speak(String(localized: "Dojechałeś do celu"))
        isActive = false
    }

    func stop() {
        isActive = false; steps = []; routeCoords = []; stepIndex = 0
        nextInstruction = "—"; destinationName = ""
        distanceToNext = 0; remainingDistance = 0; remainingTime = 0
        searchResults = []; statusNote = ""
    }

    // MARK: — Punkty trasy przed nami (dla pogody na trasie)

    /// Prędkość, z jaką Apple szacuje przejazd tej trasy (m/s).
    var cruiseSpeedMS: Double { routeSpeed }

    /// Punkty co `stepM` metrów drogi, licząc od miejsca na trasie najbliższego
    /// `here`. Ostatni punkt to cel, jeśli mieści się w limicie — zwracane `reachesEnd`.
    func pointsAhead(from here: CLLocationCoordinate2D, stepM: Double, maxCount: Int)
        -> (points: [RoutePoint], reachesEnd: Bool) {
        guard isActive, routeCoords.count > 1 else { return ([], false) }
        let me = CLLocation(latitude: here.latitude, longitude: here.longitude)
        // Najbliższy wierzchołek polilinii = nasze miejsce na trasie.
        var best = 0; var bestD = Double.greatestFiniteMagnitude
        for (i, c) in routeCoords.enumerated() {
            let d = me.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            if d < bestD { bestD = d; best = i }
        }
        var out = [RoutePoint(coord: here, distM: 0)]
        var acc = 0.0, next = stepM
        var prev = CLLocation(latitude: routeCoords[best].latitude, longitude: routeCoords[best].longitude)
        var i = best + 1
        while i < routeCoords.count, out.count < maxCount {
            let cur = CLLocation(latitude: routeCoords[i].latitude, longitude: routeCoords[i].longitude)
            acc += cur.distance(from: prev)
            if acc >= next {
                out.append(RoutePoint(coord: routeCoords[i], distM: acc))
                next += stepM
            }
            prev = cur; i += 1
        }
        let reachedEnd = i >= routeCoords.count
        if reachedEnd, out.count < maxCount + 1, let last = routeCoords.last, acc - (out.last?.distM ?? 0) > 500 {
            out.append(RoutePoint(coord: last, distM: acc))
        }
        return (out, reachedEnd)
    }

    // MARK: — Głos

    private func speak(_ text: String) {
        guard voiceEnabled, !text.isEmpty, text != lastSpoken else { return }
        lastSpoken = text
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers, .mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier == "pl" ? "pl-PL" : "en-US")
        u.rate = 0.5
        synth.speak(u)
    }
}

// MARK: — MKPolyline → współrzędne

extension MKPolyline {
    func coordinatesArray() -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
