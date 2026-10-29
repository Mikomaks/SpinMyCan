// WeatherManager.swift
// Pobiera temperaturę otoczenia z Open-Meteo API (free, bez klucza).
//
// Endpoint: https://api.open-meteo.com/v1/forecast?latitude=...&longitude=...&current_weather=true
// Refresh: co 15 min (lub przy zmianie pozycji o > 5 km).
//
// POGODA NA TRASIE (`ahead`): osobne zapytanie o opad w krokach 15-minutowych.
//   • z nawigacją — w kilkunastu punktach trasy naraz (Open-Meteo przyjmuje listę
//     współrzędnych i oddaje listę wyników), każdy punkt sprawdzany o godzinie,
//     o której TAM dojedziemy, a nie „teraz"
//   • bez nawigacji — w miejscu, w którym jesteśmy: „deszcz za 40 min"
// Do tego wiatr tu i teraz, z którego liczymy składową boczną względem kursu.

import Foundation
import CoreLocation
import Combine

/// Punkt trasy do sprawdzenia: gdzie i ile metrów drogi nas od niego dzieli.
struct RoutePoint {
    let coord: CLLocationCoordinate2D
    let distM: Double
}

/// Wynik pogody na trasie. Trzyma czasy BEZWZGLĘDNE i dystanse z chwili pobrania,
/// żeby „za 18 min / 25 km" samo malało między odświeżeniami (co 10 min),
/// zamiast stać w miejscu do następnego zapytania.
struct WeatherAhead: Equatable {
    var fetchedAt: Date
    var onRoute: Bool                 // true = liczone wzdłuż trasy nawigacji
    var rainAt: Date? = nil           // kiedy wjedziemy w deszcz (nil = sucho w horyzoncie)
    var rainDistM: Double? = nil      // ile drogi było do deszczu w chwili pobrania
    var rainMmH: Double = 0           // natężenie w tamtym miejscu
    var rainingNow: Bool = false
    var dryAt: Date? = nil            // pada teraz → kiedy przestanie / wyjedziemy
    var dryDistM: Double? = nil
    var navRemainingAtFetch: Double = 0
    var horizonMin: Int = 0           // jak daleko w przód sięgało sprawdzenie
    var horizonKm: Double = 0
    var reachesDestination: Bool = false
    var windKmh: Double = 0
    var gustKmh: Double = 0
    var windFromDeg: Double = 0

    /// Próg „pada": 0.1 mm na kwadrans. Poniżej modele sieją fałszywą mżawką.
    static let wetThreshold = 0.1

    /// Składa wynik z odpowiedzi API. Czysta funkcja — bez sieci i zegara,
    /// żeby dało się ją sprawdzić na spreparowanych danych.
    ///  - `series[i]`: opad w kwadransach dla punktu i; `times`: początki kwadransów
    ///  - `speedMS`: prędkość, z jaką pokonujemy trasę (do wyliczenia, KIEDY gdzie będziemy)
    static func build(points: [RoutePoint], series: [[Double]], times: [TimeInterval],
                      now: Date, speedMS: Double, onRoute: Bool,
                      navRemaining: Double, reachesDestination: Bool,
                      windKmh: Double, gustKmh: Double, windFromDeg: Double) -> WeatherAhead {
        var out = WeatherAhead(fetchedAt: now, onRoute: onRoute)
        out.navRemainingAtFetch = navRemaining
        out.reachesDestination = reachesDestination
        out.windKmh = windKmh; out.gustKmh = gustKmh; out.windFromDeg = windFromDeg
        guard !points.isEmpty, !times.isEmpty, points.count == series.count else { return out }

        let t0 = times[0]
        func slot(_ date: Date) -> Int { Int(floor((date.timeIntervalSince1970 - t0) / 900.0)) }
        func mm(_ i: Int, _ k: Int) -> Double? {
            guard k >= 0, k < series[i].count else { return nil }
            return series[i][k]
        }

        if onRoute {
            // Każdy punkt trasy sprawdzamy w kwadransie, w którym TAM będziemy.
            let v = max(3.0, speedMS)
            var checked: [(dist: Double, eta: Date, mm: Double)] = []
            for (i, p) in points.enumerated() {
                let eta = now.addingTimeInterval(p.distM / v)
                guard let m = mm(i, slot(eta)) else { break }   // poza zasięgiem prognozy
                checked.append((p.distM, eta, m))
            }
            guard let last = checked.last else { return out }
            out.horizonKm = last.dist / 1000
            out.horizonMin = Int(last.eta.timeIntervalSince(now) / 60)
            out.reachesDestination = reachesDestination && checked.count == points.count
            out.rainingNow = (checked.first?.mm ?? 0) >= wetThreshold
            if out.rainingNow {
                if let d = checked.first(where: { $0.mm < wetThreshold }) {
                    out.dryAt = d.eta; out.dryDistM = d.dist
                }
                out.rainMmH = (checked.first?.mm ?? 0) * 4
            } else if let r = checked.first(where: { $0.mm >= wetThreshold }) {
                out.rainAt = r.eta; out.rainDistM = r.dist; out.rainMmH = r.mm * 4
            }
        } else {
            // Bez trasy: stoimy w miejscu prognozy i patrzymy w przód w czasie.
            let k0 = max(0, slot(now))
            let s = series[0]
            guard k0 < s.count else { return out }
            out.horizonMin = (s.count - k0) * 15
            out.rainingNow = s[k0] >= wetThreshold
            if out.rainingNow {
                out.rainMmH = s[k0] * 4
                if let k = (k0..<s.count).first(where: { s[$0] < wetThreshold }) {
                    out.dryAt = Date(timeIntervalSince1970: t0 + Double(k) * 900)
                }
            } else if let k = (k0..<s.count).first(where: { s[$0] >= wetThreshold }) {
                out.rainAt = Date(timeIntervalSince1970: t0 + Double(k) * 900)
                out.rainMmH = s[k] * 4
            }
        }
        return out
    }

    private static func rainWord(_ mmH: Double) -> String {
        mmH < 1 ? String(localized: "mżawka") : (mmH < 4 ? String(localized: "deszcz") : String(localized: "ulewa"))
    }

    /// Pigułki na deskę. `navRemaining` = bieżący dystans do celu (maleje w czasie
    /// jazdy, więc kilometry do deszczu liczą się na żywo), `headingDeg` < 0 = brak kursu.
    func chips(now: Date, navRemaining: Double, headingDeg: Double) -> [DashChip] {
        var out: [DashChip] = []
        let driven = onRoute ? max(0, navRemainingAtFetch - navRemaining) : 0
        func mins(_ d: Date) -> Int { max(0, Int((d.timeIntervalSince(now) / 60).rounded())) }
        func km(_ m: Double) -> String {
            let left = max(0, m - driven) / 1000
            return left < 10 ? String(format: "%.1f km", left) : String(format: "%.0f km", left)
        }
        func span(_ m: Int) -> String { m >= 90 ? String(format: "%.0f h", (Double(m) / 60).rounded()) : "\(m) min" }

        if rainingNow {
            if let d = dryAt {
                let tail = (onRoute && dryDistM != nil) ? String(localized: "sucho za \(km(dryDistM!))") : String(localized: "jeszcze \(span(mins(d)))")
                out.append(DashChip(text: String(localized: "☔ pada · \(tail)"), tone: .rain))
            } else {
                out.append(DashChip(text: String(localized: "☔ pada"), tone: .rain))
            }
        } else if let r = rainAt {
            let m = mins(r)
            let word = Self.rainWord(rainMmH)
            if m <= 1 {
                out.append(DashChip(text: String(localized: "☔ \(word) tuż przed tobą"), tone: .rain))
            } else if onRoute, let dist = rainDistM {
                out.append(DashChip(text: String(localized: "☔ \(word) za \(km(dist)) · \(span(m))"), tone: .rain))
            } else {
                out.append(DashChip(text: String(localized: "☔ \(word) za \(span(m))"), tone: .rain))
            }
        } else if horizonMin > 0 {
            let txt = onRoute
                ? (reachesDestination ? String(localized: "sucho do celu") : String(format: String(localized: "sucho przez %.0f km"), horizonKm))
                : String(localized: "sucho przez \(span(horizonMin))")
            out.append(DashChip(text: txt, tone: .quiet))
        }

        // Wiatr boczny: liczy się składowa prostopadła do kierunku jazdy.
        // Porywy bierzemy do oceny, bo to one przestawiają motocykl na pasie.
        if headingDeg >= 0, gustKmh >= 30 {
            var rel = (windFromDeg - headingDeg).truncatingRemainder(dividingBy: 360)
            if rel > 180 { rel -= 360 }; if rel < -180 { rel += 360 }
            let cross = gustKmh * abs(sin(rel * .pi / 180))
            if cross >= 30 {
                let side = rel > 0 ? String(localized: "z prawej") : String(localized: "z lewej")
                // Krótko, żeby zmieścił się OBOK pigułki deszczu (środek deski ma 444 px).
                out.append(DashChip(text: String(format: "💨 %.0f km/h %@", cross, side),
                                    tone: cross >= 50 ? .bad : .warn))
            }
        }
        return out
    }
}

final class WeatherManager: ObservableObject {

    @Published var temperatureC: Double? = nil
    @Published var lastUpdate:   Date?   = nil
    /// Pogoda na trasie / w miejscu — nil dopóki nie przyjdzie pierwsza odpowiedź.
    @Published var ahead: WeatherAhead? = nil

    private var aheadFetchedAt: Date? = nil
    private var aheadLocation: CLLocation? = nil
    private var aheadKey = ""            // zmiana celu albo włączenie nawigacji = pobierz od razu
    private var aheadBusy = false
    // Kopia dla renderera, który czyta z wątku tła (dostawca klatek).
    private let aheadLock = NSLock()
    private var aheadCopy: WeatherAhead? = nil

    func aheadSnapshot() -> WeatherAhead? {
        aheadLock.lock(); defer { aheadLock.unlock() }
        return aheadCopy
    }
    private let aheadInterval: TimeInterval = 10 * 60

    private var lastFetchLocation: CLLocation? = nil
    private let fetchInterval:     TimeInterval = 15 * 60   // 15 min
    private let moveThresholdM:    CLLocationDistance = 5_000

    /// Wywoływane z MotionManager przy aktualizacji GPS.
    /// Sprawdza czy minęło 15 min albo przemieściliśmy się > 5 km — wtedy fetchuje.
    func updateIfNeeded(at coord: CLLocationCoordinate2D) {
        let now = Date()
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)

        let stale     = lastUpdate.map { now.timeIntervalSince($0) > fetchInterval } ?? true
        let moved     = lastFetchLocation.map { loc.distance(from: $0) > moveThresholdM } ?? true
        guard stale || moved else { return }

        lastFetchLocation = loc
        fetch(lat: coord.latitude, lon: coord.longitude)
    }

    // MARK: — Pogoda na trasie

    /// Wołane z heartbeatu 1 Hz; samo pilnuje, kiedy naprawdę iść do sieci.
    /// `points` puste = bez nawigacji (sprawdzamy bieżące miejsce).
    func updateAheadIfNeeded(at coord: CLLocationCoordinate2D, routeKey: String,
                             route: () -> (points: [RoutePoint], reachesEnd: Bool),
                             speedMS: Double, navRemaining: Double) {
        guard !aheadBusy else { return }
        let now = Date()
        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let stale = aheadFetchedAt.map { now.timeIntervalSince($0) > aheadInterval } ?? true
        let moved = aheadLocation.map { loc.distance(from: $0) > 5_000 } ?? true
        guard stale || moved || routeKey != aheadKey else { return }

        aheadKey = routeKey
        aheadLocation = loc
        aheadFetchedAt = now          // także przy błędzie — ponowimy za 10 min, nie co sekundę
        let r = route()
        fetchAhead(here: coord, points: r.points, speedMS: speedMS,
                   navRemaining: navRemaining, reachesDestination: r.reachesEnd)
    }

    func fetchAhead(here: CLLocationCoordinate2D, points: [RoutePoint], speedMS: Double,
                    navRemaining: Double, reachesDestination: Bool,
                    completion: ((WeatherAhead?) -> Void)? = nil) {
        let onRoute = !points.isEmpty
        let pts = onRoute ? points : [RoutePoint(coord: here, distM: 0)]
        guard var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else { return }
        let f = { (v: Double) in String(format: "%.4f", v) }
        comps.queryItems = [
            URLQueryItem(name: "latitude",  value: pts.map { f($0.coord.latitude)  }.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: pts.map { f($0.coord.longitude) }.joined(separator: ",")),
            URLQueryItem(name: "minutely_15", value: "precipitation"),
            URLQueryItem(name: "forecast_minutely_15", value: onRoute ? "24" : "12"),   // 6 h / 3 h
            URLQueryItem(name: "current", value: "wind_speed_10m,wind_direction_10m,wind_gusts_10m"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
            URLQueryItem(name: "timeformat", value: "unixtime")
        ]
        guard let url = comps.url else { return }
        aheadBusy = true
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 12)) { [weak self] data, _, error in
            // Jeden punkt → obiekt, wiele punktów → lista. Sprowadzamy do listy.
            var items: [[String: Any]] = []
            if let data, let json = try? JSONSerialization.jsonObject(with: data) {
                if let arr = json as? [[String: Any]] { items = arr }
                else if let one = json as? [String: Any] { items = [one] }
            }
            let series = items.compactMap { ($0["minutely_15"] as? [String: Any])?["precipitation"] as? [Any] }
                .map { $0.map { ($0 as? Double) ?? 0 } }       // null w prognozie = brak danych = 0
            let times = ((items.first?["minutely_15"] as? [String: Any])?["time"] as? [Any] ?? [])
                .compactMap { ($0 as? Double) ?? ($0 as? Int).map(Double.init) }
            let cur = items.first?["current"] as? [String: Any] ?? [:]

            var result: WeatherAhead? = nil
            if series.count == pts.count, !times.isEmpty {
                result = WeatherAhead.build(
                    points: pts, series: series, times: times, now: Date(), speedMS: speedMS,
                    onRoute: onRoute, navRemaining: navRemaining, reachesDestination: reachesDestination,
                    windKmh: cur["wind_speed_10m"] as? Double ?? 0,
                    gustKmh: cur["wind_gusts_10m"] as? Double ?? 0,
                    windFromDeg: cur["wind_direction_10m"] as? Double ?? 0)
            } else {
                print("[Weather] ahead failed: \(error?.localizedDescription ?? "zły format") (\(items.count)/\(pts.count))")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.aheadBusy = false
                if let result {                            // przy błędzie zostaje poprzedni wynik
                    self.ahead = result
                    self.aheadLock.lock(); self.aheadCopy = result; self.aheadLock.unlock()
                }
                completion?(result)
            }
        }.resume()
    }

    private func fetch(lat: Double, lon: Double) {
        guard var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else { return }
        comps.queryItems = [
            URLQueryItem(name: "latitude",       value: "\(lat)"),
            URLQueryItem(name: "longitude",      value: "\(lon)"),
            URLQueryItem(name: "current_weather", value: "true"),
            URLQueryItem(name: "temperature_unit", value: "celsius")
        ]
        guard let url = comps.url else { return }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "GET"

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self,
                  let data,
                  error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cw   = json["current_weather"] as? [String: Any],
                  let temp = cw["temperature"]      as? Double
            else {
                print("[Weather] fetch failed: \(error?.localizedDescription ?? "no data")")
                return
            }
            DispatchQueue.main.async {
                self.temperatureC = temp
                self.lastUpdate   = Date()
                print("[Weather] \(String(format: "%.1f", temp))°C")
            }
        }.resume()
    }
}
