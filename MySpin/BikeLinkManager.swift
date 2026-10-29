// BikeLinkManager.swift
// Odbiór danych z mostka CAN→BLE (płytka ESP32 wpięta w złącze diagnostyczne
// motocykla). Format pakietów opisany w firmware/can-ble-bridge/src/main.cpp.
//
// Połączenie jest w pełni automatyczne: po pierwszym znalezieniu płytki apka
// zapamiętuje jej identyfikator i trzyma w iOS „wiszące" żądanie połączenia bez
// limitu czasu — płytka dostaje zasilanie z zapłonem, zaczyna się rozgłaszać
// i system łączy ją sam, także gdy apka jest w tle.
//
// Niezależne od BT iAP2 motocykla (BTManager) — to osobny kanał Bluetooth LE.

import Foundation
import Combine
import CoreBluetooth
import QuartzCore

// MARK: — Telemetria (pakiet 18 B, 20 Hz)

struct BikeTelemetry: Equatable {
    var rpm = 0
    var gear = 0            // 0 = luz, 1–6
    var gearInTransit = false   // dźwignia w połowie zmiany: szyna podaje wtedy wartość spoza 0–6
    var throttleRaw = 0     // 0 = zamknięty, ~172 = pełny (do kalibracji w jeździe)
    var throttle10 = 0      // to samo z dwoma dodatkowymi bitami: 0 … ~690
    var leanWord = 32768    // kąt przechyłu policzony przez motocykl (ramka 0x1A5)
    var accelWords = [32768, 32768, 32768]   // wzdłużne, pionowe, boczne; 1 g ≈ 5000
    var engineFresh = false // ramka 0x1A1 widziana w ostatnich 0,5 s
    var leanFresh = false   // ramka 0x1A5
    var accelFresh = false  // ramka 0x181
    var simulated = false   // płytka ma wgrany program testowy (sztuczna szyna)
    var busFps = 0          // ramek na szynie w ostatniej sekundzie
    var fwVersion = 0       // 0 = program płytki sprzed numeracji

    // ── Część rozszerzona pakietu (program płytki od wersji 4, 48 bajtów) ──
    // Skale i dowody: tools/can/SYGNALY.md. `ext` = pakiet ją zawiera.
    var ext = false
    var pulsesFresh = false, wheelFresh = false, suspFresh = false, envFresh = false
    var modeFresh = false, tcFresh = false, suspSetFresh = false, dampFresh = false, cruiseFresh = false
    var coolantRaw = 0          // 0x1A5 b4
    var switches = 0            // 0x1A5 b5: 0x04 sprzęgło, 0x10 przycisk startu
    var tpsRaw = 0              // 0x1A1 b4b5, 10 bitów: 18 zamknięta … 327 pełny gaz
    var wheelFrontRaw = 0       // 0x19D b0b1
    var wheelRearRaw = 0        // 0x19D b2b3
    var pulseCount = 0          // 0x221 b0b1, licznik impulsów przedniego koła (zawija się)
    var suspFrontRaw = 0        // 0x17D b0b1; mniejsza = bardziej ugięte
    var suspRearRaw = 0         // 0x17D b2b3
    var dampCmd = 0             // 0x17D b4
    var odometerKm = 0          // 0x231, 20 bitów
    var airRaw = 0              // 0x231 b5
    var rideModeRaw = 0         // 0x331 b5 >> 4: 1 = A, 2 = B, 3 = C
    var tcLevel = 0             // 0x335 b3 >> 4: 0 = OFF, 1–7 (bieżący tryb jazdy)
    var preloadMode = 0         // 0x1AD b3 >> 4: 2 AUTO, 3 SOLO, 4 SOLO+bagaż, 5 DUO
    var dampMode = 0            // 0x32D b0 & 15: 0 H, 1 M, 2 S, 3 U
    var dampUserFront = 0       // korekta w trybie U, −3…+3
    var dampUserRear = 0
    var cruiseOn = false        // 0x341 b3 & 0x10
    /// Odstęp połączenia Bluetooth przyznany przez telefon [ms] (program płytki od v8); nil = nieznany.
    var connIntervalMs: Double? = nil

    /// Płyn chłodzący w °C (potwierdzone z wyświetlaczem motocykla).
    var coolantC: Double? { ext && leanFresh ? 0.625 * Double(coolantRaw) - 30 : nil }
    /// Powietrze w °C — ten sam czujnik co na wyświetlaczu motocykla, bez jego wygładzania.
    var airC: Double? { ext && envFresh ? Double(airRaw) - 30 : nil }
    /// Tryb jazdy jako litera; nil, gdy nieznany.
    var rideMode: String? {
        guard ext, modeFresh, (1...3).contains(rideModeRaw) else { return nil }
        return ["A", "B", "C"][rideModeRaw - 1]
    }
    /// Tryb tłumienia zawieszenia (ACTIVE DAMPING) jako litera H/M/S/U; nil, gdy nieznany.
    var dampLetter: String? {
        guard ext, dampFresh, (0...3).contains(dampMode) else { return nil }
        return ["H", "M", "S", "U"][dampMode]
    }
    /// Przebieg z licznika [km]; nil, gdy brak świeżej ramki 0x231.
    var odometer: Int? { ext && envFresh && odometerKm > 0 ? odometerKm : nil }
    /// Poziom trakcji bieżącego trybu (0 = OFF); nil, gdy brak danych albo wartość spoza 0–7.
    var traction: Int? { ext && tcFresh && tcLevel <= 7 ? tcLevel : nil }
    var clutchPulled: Bool { ext && leanFresh && switches & 0x04 != 0 }
    /// Manetka gazu w procentach (0 = zamknięta, 690 = do oporu).
    var throttlePct: Double { min(100, max(0, Double(throttle10) / 6.9)) }

    /// Przechył w konwencji apki: < 0 = lewo, > 0 = prawo.
    var leanDeg: Double { Double(leanWord - 32768) * 180.0 / 32768.0 }

    /// Przyspieszenia w g: wzdłużne, pionowe (≈ −1 na postoju), boczne.
    var accelG: [Double] { accelWords.map { Double($0 - 32768) / 5000.0 } }

    static func parse(_ d: Data) -> BikeTelemetry? {
        let b = [UInt8](d)
        guard b.count >= 18, b[0] == 2 else { return nil }
        func word(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        var t = BikeTelemetry()
        t.engineFresh = b[1] & 0x01 != 0
        t.leanFresh   = b[1] & 0x02 != 0
        t.accelFresh  = b[1] & 0x04 != 0
        t.simulated   = b[1] & 0x80 != 0
        t.rpm         = word(2)
        t.throttleRaw = Int(b[4])
        t.throttle10  = Int(b[4]) << 2 | Int(b[5] >> 6)
        let gear      = Int(b[5] & 0x0F)
        if gear <= 6 { t.gear = gear } else { t.gearInTransit = true }
        t.leanWord    = word(6)
        t.accelWords  = [word(8), word(10), word(12)]
        t.busFps      = word(14)
        t.fwVersion   = Int(b[17])
        // Część rozszerzona: surowe bajty ramek w kolejności jak na szynie (starszy pierwszy).
        // Ucięty pakiet (telefon bez większego MTU) albo starsza płytka = tylko część podstawowa.
        guard b.count >= 48 else { return t }
        func be(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        t.ext           = true
        t.pulsesFresh   = b[1] & 0x08 != 0
        t.wheelFresh    = b[18] & 0x01 != 0
        t.suspFresh     = b[18] & 0x02 != 0
        t.envFresh      = b[18] & 0x04 != 0
        t.modeFresh     = b[18] & 0x08 != 0
        t.tcFresh       = b[18] & 0x10 != 0
        t.suspSetFresh  = b[18] & 0x20 != 0
        t.dampFresh     = b[18] & 0x40 != 0
        t.cruiseFresh   = b[18] & 0x80 != 0
        t.coolantRaw    = Int(b[19])
        t.switches      = Int(b[20])
        t.tpsRaw        = be(21) >> 6
        t.wheelFrontRaw = be(23)
        t.wheelRearRaw  = be(25)
        t.pulseCount    = be(27)
        t.suspFrontRaw  = be(29)
        t.suspRearRaw   = be(31)
        t.dampCmd       = Int(b[33])
        t.odometerKm    = Int(b[34]) << 12 | Int(b[35]) << 4 | Int(b[36]) >> 4
        t.airRaw        = Int(b[37])
        t.rideModeRaw   = Int(b[38] >> 4)
        t.tcLevel       = Int(b[41] >> 4)
        t.dampUserFront = Int(b[43] & 0x0F) - 7
        t.dampUserRear  = Int(b[44] & 0x0F) - 7
        t.preloadMode   = Int(b[45] >> 4)
        t.dampMode      = Int(b[46] & 0x0F)
        t.cruiseOn      = b[47] & 0x10 != 0
        if b.count >= 49, b[48] > 0 { t.connIntervalMs = Double(b[48]) * 1.25 }
        return t
    }
}

// MARK: — Prędkość z koła i zakres zawieszenia

/// Przelicznik „jednostka z szyny → km/h" dla przedniego koła, wyznaczany z GPS.
///
/// Jednostka 0,01 km/h to wniosek z testu na stojaku, nie pomiar w jeździe. Dlatego
/// prędkość z koła trafia na deskę dopiero, gdy GPS ją potwierdzi: zbieramy pary
/// (koło, GPS) przy równej jeździe i liczymy medianę ilorazu. Dopóki zbiór jest za
/// mały albo zbyt rozrzucony — przelicznika nie ma i deska pokazuje GPS jak dotąd.
struct WheelSpeedCalibration: Equatable {
    static let expected = 0.01          // km/h na jednostkę wg testu na stojaku
    static let tolerance = 0.25         // wynik dalej niż ±25% od oczekiwanego = nie wierzymy
    static let minSamples = 30          // ok. pół minuty równej jazdy
    static let window = 180

    private(set) var ratios: [Double] = []
    private(set) var factor: Double?    // km/h na jednostkę; nil = jeszcze niepotwierdzony
    private var lastGps: Double?

    init(stored: Double? = nil) {
        if let s = stored, Self.plausible(s) { factor = s }
    }

    static func plausible(_ k: Double) -> Bool { abs(k / expected - 1) <= tolerance }

    /// Jedna próbka na sekundę. Zwraca true, gdy przelicznik się zmienił (do zapisania).
    mutating func add(wheelRaw: Int, gpsKmh: Double, gpsAccuracy: Double) -> Bool {
        defer { lastGps = gpsKmh }
        // Tylko pewny GPS, wyraźna prędkość i jazda bez przyspieszania/hamowania
        // (GPS spóźnia się o ok. sekundę, więc przy zmianach prędkości iloraz kłamie).
        guard gpsAccuracy > 0, gpsAccuracy <= 15, gpsKmh >= 30, wheelRaw > 0,
              let prev = lastGps, abs(gpsKmh - prev) < 2 else { return false }
        ratios.append(gpsKmh / Double(wheelRaw))
        if ratios.count > Self.window { ratios.removeFirst(ratios.count - Self.window) }
        guard ratios.count >= Self.minSamples else { return false }
        let sorted = ratios.sorted()
        let median = sorted[sorted.count / 2]
        let spread = (sorted[sorted.count * 3 / 4] - sorted[sorted.count / 4]) / median
        guard Self.plausible(median), spread < 0.05 else { return false }
        if let f = factor, abs(median / f - 1) < 0.002 { return false }
        factor = median
        return true
    }

    func kmh(_ wheelRaw: Int) -> Double? { factor.map { Double(wheelRaw) * $0 } }
}

/// Zakres pracy czujnika skoku: skrajne wartości, jakie widzieliśmy. Skali w milimetrach
/// nie znamy, więc słupek na desce pokazuje ugięcie względem tego zakresu — a zakres
/// sam się poszerza, gdy zawieszenie pójdzie dalej niż dotąd.
struct SuspensionRange: Equatable {
    var extended: Int      // największa wartość = najbardziej rozciągnięte
    var compressed: Int    // najmniejsza = najbardziej ugięte

    /// Punkty startowe z testów na postoju: przód 1532 w powietrzu (stojak), 1119 z kierowcą;
    /// tył 674 w trybie DUO na nóżce, ok. 422 przy podskakiwaniu na siodle.
    static let front = SuspensionRange(extended: 1532, compressed: 1000)
    static let rear = SuspensionRange(extended: 680, compressed: 400)

    /// Poszerza zakres o nową próbkę; true, gdy coś się zmieniło.
    mutating func include(_ raw: Int) -> Bool {
        guard raw > 0 else { return false }
        if raw > extended { extended = raw; return true }
        if raw < compressed { compressed = raw; return true }
        return false
    }

    /// Ugięcie 0…1 (0 = rozciągnięte, 1 = najgłębiej, jak dotąd widzieliśmy).
    func travel(_ raw: Int) -> Double {
        guard extended > compressed else { return 0 }
        return min(1, max(0, Double(extended - raw) / Double(extended - compressed)))
    }
}

/// Ruch zawieszenia względem położenia „w zwykłej jeździe": +1 = mocno ugięte
/// (nurkowanie przodu przy hamowaniu, przysiad tyłu przy przyspieszaniu), −1 = mocno
/// rozciągnięte, 0 = tak jak przy równej jeździe. Położenie odniesienia uczy się samo
/// (wolna średnia podczas jazdy), więc nie zależy od obciążenia ani nastawy napięcia.
struct SuspensionMotion: Equatable {
    /// Pełne wychylenie słupka w jednostkach czujnika — z jazdy 2026-10-13: przód chodzi
    /// ok. ±300 przy zwykłym hamowaniu i przyspieszaniu, tył ok. ±50.
    static let frontSpan = 450.0, rearSpan = 120.0
    static let settleSeconds = 20.0

    private(set) var base: Double?
    private var last: CFTimeInterval = 0

    /// `moving` = motocykl jedzie; na postoju odniesienie stoi w miejscu.
    mutating func update(raw: Int, now: CFTimeInterval, moving: Bool) {
        guard raw > 0 else { return }
        guard let b = base else { base = Double(raw); last = now; return }
        let dt = min(1, max(0, now - last)); last = now
        if moving { base = b + (Double(raw) - b) * dt / Self.settleSeconds }
    }

    func value(raw: Int, span: Double) -> Double {
        guard let b = base, raw > 0 else { return 0 }
        return min(1, max(-1, (b - Double(raw)) / span))     // mniejsza liczba = bardziej ugięte
    }
}

// MARK: — Aktualizacja programu płytki przez Bluetooth

/// Program płytki dołączony do apki (`make fw-bundle`): plik binarny i jego podpis.
/// Podpis (HMAC-SHA256) powstaje na komputerze; apka nie zna klucza, więc potrafi
/// wysłać tylko dokładnie ten program — płytka każdy inny odrzuci.
struct FirmwareImage: Equatable {
    let version: Int
    let data: Data
    let tag: Data

    static func load(bin: URL, meta: URL) -> FirmwareImage? {
        guard let data = try? Data(contentsOf: bin),
              let raw = try? Data(contentsOf: meta),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let version = json["version"] as? Int, let size = json["size"] as? Int,
              let hex = json["hmac"] as? String, size == data.count, hex.count == 64 else { return nil }
        var tag = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            tag.append(b); i = j
        }
        return FirmwareImage(version: version, data: data, tag: tag)
    }

    static let bundled: FirmwareImage? = {
        guard let bin = Bundle.main.url(forResource: "bridge_fw", withExtension: "bin"),
              let meta = Bundle.main.url(forResource: "bridge_fw", withExtension: "json"),
              let img = load(bin: bin, meta: meta) else { return nil }
        #if DEBUG
        // Test odmowy na prawdziwej płytce: celowo zepsuty podpis.
        if ProcessInfo.processInfo.environment["OTA_BAD_TAG"] != nil {
            var bad = img.tag; bad[0] ^= 0x01
            return FirmwareImage(version: img.version, data: img.data, tag: bad)
        }
        #endif
        return img
    }()
}

enum FirmwareUpdateState: Equatable {
    case idle
    case starting
    case sending(Double)     // postęp 0…1
    case verifying           // płytka sprawdza podpis
    case restarting          // przyjęła program, startuje nowy
    case done(Int)           // wróciła z tą wersją
    case failed(String)

    var busy: Bool {
        switch self {
        case .starting, .sending, .verifying, .restarting: return true
        default: return false
        }
    }
}

/// Logika wysyłania programu, bez Bluetooth (żeby dało się ją przetestować):
/// pilnuje pozycji, okna niepotwierdzonych danych i reakcji na odpowiedzi płytki.
/// Protokół: firmware/can-ble-bridge/src/ota_core.h.
struct FirmwareSender {
    enum Step: Equatable { case wait, pump, end, restarting, failed(String) }

    /// Tyle bajtów może czekać na potwierdzenie. Kolejka w płytce mieści 12 kB.
    static let window = 6144
    static let stallSeconds = 3.0
    static let maxRewinds = 5

    let image: FirmwareImage
    private(set) var sent = 0
    private(set) var acked = 0
    private(set) var rewinds = 0
    private var lastProgress: CFTimeInterval

    init(image: FirmwareImage, now: CFTimeInterval) {
        self.image = image
        lastProgress = now
    }

    var progress: Double { image.data.isEmpty ? 0 : Double(acked) / Double(image.data.count) }

    func beginMessage() -> Data {
        var m = Data([0x01])
        m.append(Self.le32(image.data.count))
        m.append(UInt8(truncatingIfNeeded: image.version))
        m.append(image.tag)
        return m
    }

    static let endMessage = Data([0x03])
    static let abortMessage = Data([0x04])

    /// Następna paczka danych albo nil, gdy okno jest pełne lub wszystko już poszło.
    mutating func nextChunk(maxWrite: Int) -> Data? {
        let room = Self.window - (sent - acked)
        let n = min(maxWrite - 5, image.data.count - sent, room)
        guard n > 0 else { return nil }
        var m = Data([0x02])
        m.append(Self.le32(sent))
        m.append(image.data.subdata(in: sent..<(sent + n)))
        sent += n
        return m
    }

    /// Odpowiedź płytki: [stan][pozycja u32 LE][wersja].
    mutating func handle(_ reply: Data, now: CFTimeInterval) -> Step {
        let b = [UInt8](reply)
        guard b.count >= 5 else { return .wait }
        let offset = Int(b[1]) | Int(b[2]) << 8 | Int(b[3]) << 16 | Int(b[4]) << 24
        switch b[0] {
        case 0x10:      // READY
            sent = 0; acked = 0; lastProgress = now
            return .pump
        case 0x11:      // ACK
            guard offset <= image.data.count, offset >= acked else { return .wait }
            if offset > acked { lastProgress = now; rewinds = 0 }
            acked = offset
            return acked == image.data.count ? .end : .pump
        case 0x23:      // dziura w danych — płytka podaje, od której pozycji chce dalej
            guard offset <= image.data.count else { return .failed("Płytka podała pozycję poza programem") }
            sent = offset; acked = offset; lastProgress = now
            return .pump
        case 0x12: return .restarting
        case 0x20: return .failed("Motocykl jedzie albo pracuje silnik. Zgaś silnik i spróbuj ponownie.")
        case 0x21: return .failed("Płytka odrzuciła rozmiar programu.")
        case 0x22: return .failed("Błąd zapisu w pamięci płytki. Stary program działa dalej.")
        case 0x24: return .failed("Zły podpis programu — płytka go odrzuciła. Stary program działa dalej.")
        case 0x25: return .failed("Płytka nie doczekała się danych. Stary program działa dalej.")
        case 0x26: return .failed("Płytka nie była gotowa na dane. Spróbuj ponownie.")
        case 0x27: return .failed("Aktualizacja przerwana.")
        default:   return .wait
        }
    }

    /// Wołać co sekundę: gdy potwierdzenia stanęły, wracamy do ostatniej potwierdzonej pozycji.
    mutating func stalled(now: CFTimeInterval) -> Step {
        guard now - lastProgress > Self.stallSeconds else { return .wait }
        rewinds += 1
        if rewinds > Self.maxRewinds { return .failed("Płytka przestała odpowiadać. Stary program działa dalej.") }
        sent = acked
        lastProgress = now
        return acked == image.data.count ? .end : .pump
    }

    private static func le32(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
}

// MARK: — Strumień surowy (do rozszyfrowywania kolejnych ramek)

struct CanRawPacket: Equatable {
    struct Record: Equatable {
        var id: UInt16
        var count: UInt8     // ramki od poprzedniego zrzutu
        var data: [UInt8]
    }
    var seq: UInt8
    var boardMs: UInt32
    var records: [Record]

    static func parse(_ d: Data) -> CanRawPacket? {
        let b = [UInt8](d)
        guard b.count >= 6, b[0] == 2 else { return nil }
        let ms = UInt32(b[2]) | UInt32(b[3]) << 8 | UInt32(b[4]) << 16 | UInt32(b[5]) << 24
        var recs: [Record] = []
        var i = 6
        while i < b.count {
            guard i + 4 <= b.count else { return nil }
            let dlc = Int(b[i + 2])
            guard dlc <= 8, i + 4 + dlc <= b.count else { return nil }
            recs.append(Record(id: UInt16(b[i]) | UInt16(b[i + 1]) << 8,
                               count: b[i + 3],
                               data: Array(b[(i + 4)..<(i + 4 + dlc)])))
            i += 4 + dlc
        }
        return CanRawPacket(seq: b[1], boardMs: ms, records: recs)
    }
}

// MARK: — Stan magistrali (podgląd na żywo i szukanie sygnałów)

/// Jedno ID na szynie — wiersz w podglądzie magistrali.
/// Jedna linia ekranu „Terminal CAN”: ramka z czasem płytki i maską bajtów, które się zmieniły.
struct HackerLine {
    let t: Double
    let id: UInt16
    let data: [UInt8]
    let changed: UInt8
}

struct BusRow: Identifiable, Equatable {
    let id: UInt16
    var data: [UInt8]
    var rate: Double          // ramek na sekundę na szynie
    var recent: UInt8         // maska bajtów zmienionych w ostatniej sekundzie
    var noisy: UInt8          // maska bajtów, które zmieniają się same (licznik, suma, szum)
    var baseline: [UInt8]?    // stan zapamiętany przyciskiem „Zapamiętaj stan"

    /// Bajty spokojne w tle, które teraz różnią się od zapamiętanych —
    /// czyli to, co zareagowało na ruch dźwignią, przełącznikiem itd.
    var diff: UInt8 {
        guard let base = baseline else { return 0 }
        var m: UInt8 = 0
        for i in 0..<min(data.count, base.count, 8) where noisy & (1 << i) == 0 && data[i] != base[i] {
            m |= 1 << i
        }
        return m
    }
}

/// Ostatnia zawartość każdego ID + prosta metoda różnicowa: zapamiętaj stan
/// spoczynkowy (przy okazji ucząc się, które bajty szumią same z siebie),
/// potem pokaż tylko to, co się od niego różni. Czysta logika, bez Bluetooth.
final class BusTable {
    private struct Entry {
        var data: [UInt8]
        var changedAt = [Double](repeating: -1000, count: 8)
        var rate = 0.0
        var lastT: Double
        var noisy: UInt8 = 0
        var baseline: [UInt8]? = nil
    }

    static let wheelID: UInt16 = 0x221   // b1 = kandydat na licznik impulsów koła

    private var entries: [UInt16: Entry] = [:]
    private var learnUntil: Double? = nil
    private var wheel: [(t: Double, total: Double)] = []
    private var wheelLast: UInt8? = nil
    private var wheelTotal = 0.0

    var count: Int { entries.count }
    var isLearning: Bool { learnUntil != nil }

    func reset() {
        entries = [:]; learnUntil = nil
        wheel = []; wheelLast = nil; wheelTotal = 0
    }

    /// Zaczyna uczenie tła: przez `duration` sekund każdy bajt, który się zmieni,
    /// zostaje uznany za szum; stan z początku staje się punktem odniesienia.
    func startLearning(at now: Double, duration: Double = 3) {
        learnUntil = now + duration
        for (id, var e) in entries {
            e.noisy = 0
            e.baseline = e.data
            entries[id] = e
        }
    }

    func clearBaseline() {
        learnUntil = nil
        for (id, var e) in entries {
            e.noisy = 0; e.baseline = nil
            entries[id] = e
        }
    }

    /// Kończy uczenie, gdy minął czas (wołane także bez nowych ramek).
    func tick(at now: Double) {
        if let u = learnUntil, now >= u { learnUntil = nil }
    }

    func ingest(_ p: CanRawPacket, at now: Double) {
        tick(at: now)
        let learning = learnUntil != nil
        for r in p.records {
            if var e = entries[r.id] {
                let dt = now - e.lastT
                if dt > 0.02 {
                    let inst = Double(r.count) / dt
                    e.rate = e.rate == 0 ? inst : e.rate * 0.7 + inst * 0.3
                }
                for i in 0..<min(r.data.count, 8) where i >= e.data.count || e.data[i] != r.data[i] {
                    e.changedAt[i] = now
                    if learning { e.noisy |= 1 << i }
                }
                e.data = r.data
                e.lastT = now
                entries[r.id] = e
            } else {
                var e = Entry(data: r.data, lastT: now)
                if learning { e.baseline = r.data }
                entries[r.id] = e
            }
            if r.id == Self.wheelID, r.data.count > 1 {
                wheelSample(r.data[1], boardT: Double(p.boardMs) / 1000)
            }
        }
    }

    func rows(at now: Double) -> [BusRow] {
        entries.keys.sorted().map { id in
            let e = entries[id]!
            var recent: UInt8 = 0
            for i in 0..<8 where now - e.changedAt[i] < 1.0 { recent |= 1 << i }
            return BusRow(id: id, data: e.data, rate: e.rate, recent: recent,
                          noisy: e.noisy, baseline: e.baseline)
        }
    }

    /// Tempo licznika 0x221 b1 w impulsach na sekundę (okno do 2 s, czas z zegara płytki).
    /// Eksperymentalne: przelicznik na km/h wyjdzie dopiero z logu z jazdy.
    var wheelPulsesPerSec: Double? {
        guard let a = wheel.first, let b = wheel.last, b.t - a.t >= 0.5 else { return nil }
        return (b.total - a.total) / (b.t - a.t)
    }

    private func wheelSample(_ v: UInt8, boardT: Double) {
        if let f = wheel.last, boardT < f.t {      // płytka się zrestartowała
            wheel = []; wheelLast = nil
        }
        if let last = wheelLast { wheelTotal += Double(v &- last) }
        wheelLast = v
        wheel.append((boardT, wheelTotal))
        while let f = wheel.first, boardT - f.t > 2.0 { wheel.removeFirst() }
    }
}

/// Stan telefonu zapisywany obok ramek — punkt odniesienia przy szukaniu,
/// który bajt na szynie jest prędkością, przechyłem, temperaturą itd.
struct PhoneSample {
    var speedKmh = 0.0
    var leanDeg = 0.0
    var gForce = 0.0
    var lat: Double? = nil
    var lon: Double? = nil
    var altitudeM = 0.0
    var headingDeg = -1.0
    var gpsAccuracy = -1.0
    var temperatureC: Double? = nil
    var track: String? = nil        // „wykonawca — tytuł” grającego utworu
}

/// Plik logu: tekst, jedna linia = jedno zdarzenie, czas w sekundach od startu logu.
///   C,t,ms_płytki,ID,liczba_ramek,dane_hex
///   P,t,km/h,przechył_telefonu°,g,lat,lon,wysokość_m,kurs,dokładność_gps_m,temp_°C
///   L,t,zgubione_pakiety
///   M,t,tekst znacznika
///   S,t,wykonawca — tytuł (utwór zaczął grać; od apki v1.18.0)
/// Analiza: tools/can/canlog.py.
final class CanLogWriter {
    let url: URL
    private let handle: FileHandle
    private var buf = Data()
    private(set) var bytes = 0
    private let t0 = CACurrentMediaTime()
    private static let hex = Array("0123456789ABCDEF".utf8)

    init?(dir: URL, now: Date = Date()) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        url = dir.appendingPathComponent("can_\(f.string(from: now)).csv")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
        line("# MySpin CAN log v1, start \(ISO8601DateFormatter().string(from: now))")
        line("# C,t,board_ms,id,n,data | P,t,kmh,phone_lean_deg,g,lat,lon,alt_m,heading,gps_acc_m,temp_c | L,t,lost | M,t,text | S,t,song")
    }

    var t: Double { CACurrentMediaTime() - t0 }

    func line(_ s: String) {
        buf.append(contentsOf: s.utf8)
        buf.append(0x0A)
        if buf.count > 32_768 { flush() }
    }

    func can(_ p: CanRawPacket) {
        let head = String(format: "C,%.3f,%u,", t, p.boardMs)
        for r in p.records {
            buf.append(contentsOf: head.utf8)
            buf.append(contentsOf: String(r.id, radix: 16, uppercase: true).utf8)
            buf.append(contentsOf: ",\(r.count),".utf8)
            for byte in r.data {
                buf.append(Self.hex[Int(byte >> 4)])
                buf.append(Self.hex[Int(byte & 0x0F)])
            }
            buf.append(0x0A)
        }
        if buf.count > 32_768 { flush() }
    }

    func phone(_ s: PhoneSample) {
        let lat = s.lat.map { String(format: "%.6f", $0) } ?? ""
        let lon = s.lon.map { String(format: "%.6f", $0) } ?? ""
        let tmp = s.temperatureC.map { String(format: "%.1f", $0) } ?? ""
        line(String(format: "P,%.3f,%.1f,%.1f,%.2f,%@,%@,%.0f,%.0f,%.0f,%@",
                    t, s.speedKmh, s.leanDeg, s.gForce, lat, lon,
                    s.altitudeM, s.headingDeg, s.gpsAccuracy, tmp))
        if let tr = s.track, !tr.isEmpty, tr != lastTrack {
            lastTrack = tr
            line(String(format: "S,%.3f,", t) + tr.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))
        }
    }
    private var lastTrack: String?

    /// Znacznik wpisany ręcznie (np. odczyt z zegarów) — jedna linia, bez znaków łamiących format.
    func mark(_ text: String) {
        let clean = text.replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
        line(String(format: "M,%.3f,", t) + clean)
        flush()
    }

    func flush() {
        guard !buf.isEmpty else { return }
        try? handle.write(contentsOf: buf)
        bytes += buf.count
        buf.removeAll(keepingCapacity: true)
    }

    func close() {
        flush()
        try? handle.close()
    }
}

// MARK: — Menedżer połączenia

final class BikeLinkManager: NSObject, ObservableObject {
    enum LinkState: Equatable {
        case off, bluetoothOff, unauthorized, unsupported, searching, connecting, connected

        var label: String {
            switch self {
            case .off:          return "Wyłączony"
            case .bluetoothOff: return "Bluetooth w telefonie jest wyłączony"
            case .unauthorized: return "Brak zgody na Bluetooth (Ustawienia → MySpin)"
            case .unsupported:  return "To urządzenie nie obsługuje Bluetooth LE"
            case .searching:    return "Czekam na płytkę (włącz zapłon)"
            case .connecting:   return "Łączę…"
            case .connected:    return "Połączono"
            }
        }
    }

    static let serviceUUID = CBUUID(string: "E298C31B-A001-46D9-8045-3E60B3B38DC6")
    static let teleUUID    = CBUUID(string: "531855D0-77DE-44E5-B26C-6DD5A615D194")
    static let rawUUID     = CBUUID(string: "7C0A6F52-3B1E-4D7A-9E55-0A2C4B8F1D93")
    static let otaUUID     = CBUUID(string: "9E0B6C1D-52A7-4F3E-8D14-6B7C2A905E31")
    static let diagUUID    = CBUUID(string: "3D8F1A62-7C4B-4E19-A0D5-5B2E9C71F084")
    private static let savedKey = "bikeLink.peripheral"
    private static let wheelKey = "bikeLink.wheelFactor"
    private static let suspKey  = "bikeLink.suspRange"     // [przód rozc., przód ugięte, tył rozc., tył ugięte]
    /// Najnowszy program płytki: ten dołączony do apki, a gdy go brak — numer z repozytorium
    /// (firmware/can-ble-bridge, FW_VERSION).
    static var currentFirmware: Int { FirmwareImage.bundled?.version ?? 6 }
    /// Limit miejsca na logi; po przekroczeniu znikają najstarsze.
    static let logQuotaBytes = 1_000_000_000
    /// Logi starsze niż tyle znikają z telefonu (do rozszyfrowania i tak nagrywa się świeże;
    /// stare są na Macu w canlogs/ — zgrywane kablem/WiFi).
    static let logMaxAge: TimeInterval = 14 * 86_400

    private static func storedWheelCalibration() -> WheelSpeedCalibration {
        WheelSpeedCalibration(stored: UserDefaults.standard.object(forKey: wheelKey) as? Double)
    }

    private static func storedSuspension() -> (front: SuspensionRange, rear: SuspensionRange) {
        guard let v = UserDefaults.standard.array(forKey: suspKey) as? [Int], v.count == 4,
              v[0] > v[1], v[2] > v[3] else { return (.front, .rear) }
        return (SuspensionRange(extended: v[0], compressed: v[1]), SuspensionRange(extended: v[2], compressed: v[3]))
    }

    static var logDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("canlogs")
    }

    // Interfejs (wątek główny)
    @Published private(set) var state: LinkState = .off
    @Published private(set) var live: BikeTelemetry? = nil   // odświeżane ~4 Hz
    @Published private(set) var logName = ""
    @Published private(set) var logBytes = 0
    @Published private(set) var logIDs = 0
    @Published private(set) var logLost = 0
    @Published private(set) var logTotalBytes = 0            // wszystkie pliki razem
    @Published private(set) var markerCount = 0
    /// Przelicznik prędkości z koła potwierdzony GPS-em (km/h na jednostkę); nil = jeszcze nie.
    @Published private(set) var wheelFactor: Double? = BikeLinkManager.storedWheelCalibration().factor
    /// Aktualizacja programu płytki przez Bluetooth: czy płytka ją umie i co się teraz dzieje.
    /// Jakość łącza z płytką w ostatniej sekundzie: ile pakietów telemetrii doszło, ile
    /// zginęło po drodze (dziury w numeracji) i najdłuższa przerwa między dwoma kolejnymi.
    struct LinkQuality: Equatable {
        var rate = 0
        var lost = 0
        var maxGapMs = 0
        var late = 0        // ile przerw między pakietami przekroczyło 60 ms
    }
    @Published private(set) var quality = LinkQuality()
    @Published private(set) var updateSupported = false
    @Published private(set) var updateState: FirmwareUpdateState = .idle
    /// Płytka umie odczytać/skasować kody błędów (program od wersji 9).
    @Published private(set) var diagSupported = false
    @Published private(set) var diagState: DiagState = .idle
    /// Adresowanie, na które motocykl odpowiedział kodami (z ostatniego odczytu) — tym kasujemy.
    @Published private(set) var diagClearAddr: DiagAddr?
    // Podgląd magistrali — odświeżany tylko, gdy jest otwarty.
    @Published private(set) var busRows: [BusRow] = []
    @Published private(set) var busLearning = false
    @Published private(set) var wheelRate: Double? = nil

    /// Dostarcza stan telefonu do logu (wołane 10 Hz z kolejki BLE).
    var phoneSample: (() -> PhoneSample?)? = nil

    // Wszystko poniżej dotykane wyłącznie z kolejki `q`.
    private let q = DispatchQueue(label: "bikelink.ble")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rawChar: CBCharacteristic?
    private var rawOn = false
    private var otaChar: CBCharacteristic?
    private var diagChar: CBCharacteristic?
    private var diagOp: DiagOp?
    private var diagReplies: [DiagReply] = []
    private var diagTimeout: DispatchWorkItem?
    private var sender: FirmwareSender?
    private var otaTimer: DispatchSourceTimer?
    private var otaWaitingRestart = false       // płytka przyjęła program, czekamy na powrót
    private var otaSawDisconnect = false
    private var otaDeadline: CFTimeInterval = 0
    private var otaTarget = 0
    private var otaFlowing = false              // płytka gotowa na dane (po READY, przed END)
    private var otaWriteInFlight = false        // paczka czeka na potwierdzenie
    private var lastPublish: CFTimeInterval = 0
    private var wantLog = false
    private var viewerActive = false
    // Ekran „Terminal CAN” na desce: ostatnie zmienione ramki i ostatnia treść każdego ID.
    private var hackerActive = false
    private let hackLock = NSLock()
    private var hackLines: [HackerLine] = []
    private var hackTable: [UInt16: [UInt8]] = [:]
    private var lastBusPublish: CFTimeInterval = 0
    private let bus = BusTable()
    private var log: CanLogWriter?
    private var closedLogBytes = 0
    private var lastRawAt: CFTimeInterval = 0
    private var lastSeq: UInt8?
    private var seenIDs = Set<UInt16>()
    private var lost = 0
    private var markers = 0
    private var phoneTimer: DispatchSourceTimer?
    private var phoneTicks = 0
    /// Dane pokazowe (tylko DEBUG) — Bluetooth wtedy nie startuje.
    private var debugSeeded = false

    // Dane dla renderera (czytane z wątku renderującego).
    private let lock = NSLock()
    private var playingTrack: String?     // pod `lock`; ustawiane z wątku głównego co 1 s
    private var latest: BikeTelemetry?
    private var latestAt: CFTimeInterval = 0
    private var lastGear = 0        // ostatni pełny bieg (kolejka BLE)
    // Dziennik łącza: mały plik zawsze, niezależnie od zapisu ramek (kolejka BLE)
    private var linkLog: FileHandle?
    // Pomiar jakości łącza (kolejka BLE)
    private var qSeq: UInt8?
    private var qCount = 0, qLost = 0, qLate = 0
    private var qMaxGap: CFTimeInterval = 0, qLastAt: CFTimeInterval = 0, qWindow: CFTimeInterval = 0
    // Pod `lock`: przelicznik prędkości i zakresy zawieszenia
    private var wheelCal = BikeLinkManager.storedWheelCalibration()
    private var useWheelSpeed = true
    private var suspFront = BikeLinkManager.storedSuspension().front
    private var suspRear = BikeLinkManager.storedSuspension().rear
    private var suspDirty = false
    private var motionFront = SuspensionMotion(), motionRear = SuspensionMotion()
    private var suspSavedAt: CFTimeInterval = 0
    private var useBikeLean = true

    // MARK: Publiczne

    func start() {
        q.async {
            guard self.central == nil, !self.debugSeeded else { return }
            self.central = CBCentralManager(delegate: self, queue: self.q,
                                            options: [CBCentralManagerOptionShowPowerAlertKey: false])
            self.publishLogTotal()
        }
    }

    func stop() {
        q.async {
            if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
            self.central?.stopScan()
            self.central?.delegate = nil
            self.central = nil
            self.peripheral = nil
            self.rawChar = nil
            self.rawOn = false
            self.closeLog()
            self.clearLatest()
            self.publish(.off)
        }
    }

    /// Zapomina zapamiętaną płytkę i szuka od nowa (po wymianie płytki).
    func forget() {
        q.async {
            UserDefaults.standard.removeObject(forKey: Self.savedKey)
            if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
            self.peripheral = nil
            self.rawChar = nil
            self.rawOn = false
            self.seek()
        }
    }

    func setLogging(_ on: Bool) {
        q.async {
            self.wantLog = on
            if !on { self.closeLog() }
            self.updateRawSubscription()
        }
    }

    /// Ekran „Terminal CAN” wybrany na desce — tylko wtedy płytka wysyła surowe ramki dla niego.
    func setHackerActive(_ on: Bool) {
        q.async {
            guard self.hackerActive != on else { return }
            self.hackerActive = on
            if !on {
                self.hackLock.lock(); self.hackLines = []; self.hackLock.unlock()
            }
            self.updateRawSubscription()
        }
    }

    /// Dla renderera (dowolny wątek): ostatnie ramki (najnowsza na końcu) i tabela ID → bajty.
    func hackerFeed() -> (lines: [HackerLine], table: [UInt16: [UInt8]]) {
        hackLock.lock(); defer { hackLock.unlock() }
        return (hackLines, hackTable)
    }

    /// Podgląd magistrali otwarty/zamknięty — tylko wtedy publikujemy wiersze do interfejsu.
    func setViewerActive(_ on: Bool) {
        q.async {
            self.viewerActive = on
            self.updateRawSubscription()
            if on { self.publishBus(force: true) }
        }
    }

    /// „Zapamiętaj stan": 3 s uczenia tła, potem podgląd pokazuje tylko różnice.
    func learnBaseline() {
        q.async {
            self.bus.startLearning(at: CACurrentMediaTime())
            self.publishBus(force: true)
            self.q.asyncAfter(deadline: .now() + 3.1) { [weak self] in
                guard let self else { return }
                self.bus.tick(at: CACurrentMediaTime())
                self.publishBus(force: true)
            }
        }
    }

    func clearBaseline() {
        q.async {
            self.bus.clearBaseline()
            self.publishBus(force: true)
        }
    }

    /// Dopisuje znacznik do otwartego logu (np. odczyt z zegarów w danej chwili).
    func addMarker(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        q.async {
            guard let w = self.log else { return }
            w.mark(trimmed)
            self.markers += 1
            let n = self.markers
            DispatchQueue.main.async { self.markerCount = n }
        }
    }

    /// Grający utwór do logu (linia S przy zmianie). Wołane z wątku głównego.
    func setPlayingTrack(_ label: String?) {
        lock.lock(); playingTrack = label; lock.unlock()
    }

    /// Usuwa wszystkie zapisane logi (bieżący zostaje zamknięty i też znika).
    func deleteAllLogs() {
        q.async {
            self.closeLog()
            for f in Self.logFiles() { try? FileManager.default.removeItem(at: f) }
            DispatchQueue.main.async { self.logName = ""; self.logBytes = 0 }
            self.publishLogTotal()
        }
    }

    /// Czy przechył ma iść z czujnika motocykla (przełącznik w karcie „Mostek CAN").
    func setUseBikeLean(_ on: Bool) {
        lock.lock(); useBikeLean = on; lock.unlock()
    }

    /// Przechył z motocykla w konwencji apki (< 0 = lewo). nil, gdy wyłączone albo
    /// brak świeżej ramki w ostatnim pół sekundy — wtedy MotionManager liczy z telefonu.
    func leanDeg() -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard useBikeLean, let t = latest, t.leanFresh,
              CACurrentMediaTime() - latestAt < 0.5 else { return nil }
        return t.leanDeg
    }

    /// Czy prędkość na desce ma iść z przedniego koła (przełącznik w karcie „Mostek CAN").
    func setUseWheelSpeed(_ on: Bool) {
        lock.lock(); useWheelSpeed = on; lock.unlock()
    }

    /// Prędkość z przedniego koła w km/h. nil, gdy wyłączone, brak świeżej ramki, płytka
    /// ma stary program albo przelicznik nie został jeszcze potwierdzony GPS-em —
    /// wtedy deska pokazuje prędkość z GPS jak dotąd.
    func wheelSpeedKmh() -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard useWheelSpeed, let t = latest, t.ext, t.wheelFresh, !t.simulated,
              CACurrentMediaTime() - latestAt < 0.5 else { return nil }
        return wheelCal.kmh(t.wheelFrontRaw)
    }

    /// Raz na sekundę z prędkością GPS: uczy przelicznik prędkości z koła.
    func feedGPS(kmh: Double, accuracy: Double) {
        lock.lock()
        var changed: Double? = nil
        if let t = latest, t.ext, t.wheelFresh, !t.simulated, CACurrentMediaTime() - latestAt < 0.5,
           wheelCal.add(wheelRaw: t.wheelFrontRaw, gpsKmh: kmh, gpsAccuracy: accuracy) {
            changed = wheelCal.factor
        }
        lock.unlock()
        guard let k = changed else { return }
        UserDefaults.standard.set(k, forKey: Self.wheelKey)
        DispatchQueue.main.async { self.wheelFactor = k }
    }

    /// Zapomina przelicznik — deska wraca do GPS, dopóki nie nauczy się go od nowa.
    func resetWheelCalibration() {
        lock.lock(); wheelCal = WheelSpeedCalibration(); lock.unlock()
        UserDefaults.standard.removeObject(forKey: Self.wheelKey)
        wheelFactor = nil
    }

    /// Ruch zawieszenia −1…+1 (przód, tył) względem położenia w równej jeździe; + = ugięcie.
    func suspensionTravel() -> (front: Double, rear: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let t = latest, t.ext, t.suspFresh, CACurrentMediaTime() - latestAt < 1.0 else { return nil }
        return (motionFront.value(raw: t.suspFrontRaw, span: SuspensionMotion.frontSpan),
                motionRear.value(raw: t.suspRearRaw, span: SuspensionMotion.rearSpan))
    }

    /// Najświeższe dane dla renderera; nil, gdy płytka milczy dłużej niż sekundę.
    func snapshot() -> BikeTelemetry? {
        lock.lock(); defer { lock.unlock() }
        guard let t = latest, CACurrentMediaTime() - latestAt < 1.0 else { return nil }
        return t
    }

    static func logFiles() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "csv" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func fileSize(_ url: URL) -> Int {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
    }

    static func logTotalBytes() -> Int {
        logFiles().reduce(0) { $0 + fileSize($1) }
    }

    /// Usuwa najstarsze logi, aż całość zmieści się w limicie. `keep` (otwarty plik) zostaje.
    /// Nazwy plików zawierają datę, więc kolejność alfabetyczna = chronologiczna.
    @discardableResult
    static func pruneLogs(in dir: URL = logDir, quota: Int = logQuotaBytes, keep: URL? = nil,
                          maxAge: TimeInterval? = logMaxAge, now: Date = Date()) -> Int {
        let all = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "csv" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var total = all.reduce(0) { $0 + fileSize($1) }
        var removed = 0
        for f in all {
            if f.lastPathComponent == keep?.lastPathComponent { continue }
            let tooOld = maxAge.map { age in logDate(f.lastPathComponent).map { now.timeIntervalSince($0) > age } ?? false } ?? false
            guard tooOld || total > quota else { continue }
            let size = fileSize(f)
            if (try? FileManager.default.removeItem(at: f)) != nil {
                total -= size
                removed += 1
            }
        }
        return removed
    }

    /// Data z nazwy pliku: can_20261025_170920.csv / link_… (czas lokalny telefonu).
    static func logDate(_ name: String) -> Date? {
        guard let r = name.range(of: #"_\d{8}_\d{6}"#, options: .regularExpression) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "_yyyyMMdd_HHmmss"
        return f.date(from: String(name[r]))
    }

    /// Sprzątanie przy starcie apki (bez czekania na płytkę).
    func pruneOldLogs() {
        q.async {
            if Self.pruneLogs(keep: self.log?.url) > 0 { self.publishLogTotal() }
        }
    }

    // MARK: Wewnętrzne (kolejka q)

    private func publish(_ s: LinkState) {
        DispatchQueue.main.async {
            if self.state != s { self.state = s }
            if s != .connected, self.live != nil { self.live = nil }
        }
    }

    private func clearLatest() {
        lock.lock(); latest = nil; lock.unlock()
    }

    private func seek() {
        guard let c = central, c.state == .poweredOn else { return }
        if peripheral == nil,
           let s = UserDefaults.standard.string(forKey: Self.savedKey), let id = UUID(uuidString: s),
           let p = c.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = p
            p.delegate = self
        }
        if peripheral?.state == .connected { return }
        // Żądanie bez limitu czasu: iOS połączy, gdy tylko płytka dostanie zasilanie.
        if let p = peripheral, p.state == .disconnected { c.connect(p) }
        // Skan równolegle — łapie nową płytkę i przypadek, gdy iOS zapomniał starą.
        if !c.isScanning { c.scanForPeripherals(withServices: [Self.serviceUUID]) }
        publish(.searching)
    }

    // MARK: Dziennik łącza

    /// Wiersz do dziennika łącza (`canlogs/link_*.csv`): T = Bluetooth z płytką,
    /// F = wysyłka klatek na wyświetlacz. Kilkadziesiąt bajtów na sekundę, więc zawsze włączony.
    func logLink(_ line: String) {
        q.async { self.writeLink(line) }
    }

    private func writeLink(_ line: String) {
        if linkLog == nil {
            try? FileManager.default.createDirectory(at: Self.logDir, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"
            let url = Self.logDir.appendingPathComponent("link_\(f.string(from: Date())).csv")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            linkLog = try? FileHandle(forWritingTo: url)
            try? linkLog?.write(contentsOf: Data("# T,czas,pakiety/s,zgubione,przerwa_ms,przerw_ponad_60ms,odstep_bt_ms | F,czas,klatki/s,pominiete,rtt_sr_ms,rtt_max_ms,co_ktora,jakosc,kB | E,czas,zrodlo,zdarzenie\n".utf8))
        }
        // Wersja z `try`, nie stare `write(_:)`: tamto przy błędzie zapisu (pełny dysk, plik
        // niedostępny) rzuca wyjątek Objective-C, którego Swift nie złapie — i wywraca apkę.
        try? linkLog?.write(contentsOf: Data((line + "\n").utf8))
    }

    // MARK: Aktualizacja programu płytki

    /// Wysyła płytce program dołączony do apki. Płytka przyjmie go tylko na postoju
    /// i tylko z poprawnym podpisem; w razie czegokolwiek zostaje przy starym.
    func startFirmwareUpdate() {
        q.async {
            guard self.sender == nil, !self.otaWaitingRestart, let img = FirmwareImage.bundled,
                  let p = self.peripheral, let ch = self.otaChar, p.state == .connected else { return }
            self.sender = FirmwareSender(image: img, now: CACurrentMediaTime())
            self.otaTarget = img.version
            self.otaSawDisconnect = false
            self.otaFlowing = false
            self.otaWriteInFlight = false
            self.setUpdate(.starting)
            self.updateRawSubscription()
            p.writeValue(self.sender!.beginMessage(), for: ch, type: .withResponse)
            let t = DispatchSource.makeTimerSource(queue: self.q)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.otaTick() }
            t.resume()
            self.otaTimer = t
        }
    }

    func cancelFirmwareUpdate() {
        q.async {
            guard self.sender != nil else { return }
            if let p = self.peripheral, let ch = self.otaChar, p.state == .connected {
                p.writeValue(FirmwareSender.abortMessage, for: ch, type: .withResponse)
            }
            self.finishUpdate(.failed("Aktualizacja przerwana."))
        }
    }

    /// Po obejrzeniu wyniku: wróć do stanu wyjściowego.
    func clearUpdateResult() {
        q.async { if self.sender == nil, !self.otaWaitingRestart { self.setUpdate(.idle) } }
    }

    private func setUpdate(_ s: FirmwareUpdateState) {
        DispatchQueue.main.async { if self.updateState != s { self.updateState = s } }
    }

    private func finishUpdate(_ s: FirmwareUpdateState) {
        sender = nil
        otaFlowing = false
        otaWriteInFlight = false
        otaWaitingRestart = false
        otaTimer?.cancel(); otaTimer = nil
        setUpdate(s)
        updateRawSubscription()
    }

    /// Wysyła następną paczkę. Każda idzie z potwierdzeniem odbioru przez płytkę, a kolejna
    /// rusza dopiero po nim (`didWriteValueFor`). Wolniej niż zapis bez potwierdzenia, ale
    /// tamten w praktyce stawał: iPhone przestawał zgłaszać gotowość do wysyłki i transmisja
    /// zamierała po kilkudziesięciu kilobajtach.
    private func otaPump() {
        guard sender != nil, otaFlowing, !otaWriteInFlight,
              let p = peripheral, let ch = otaChar, p.state == .connected else { return }
        // Rozmiar jak dla zapisu bez potwierdzenia = jedna paczka radiowa, bez dzielenia na części.
        let maxWrite = p.maximumWriteValueLength(for: .withoutResponse)
        guard let chunk = sender?.nextChunk(maxWrite: maxWrite) else { return }
        otaWriteInFlight = true
        p.writeValue(chunk, for: ch, type: .withResponse)
    }

    private func otaApply(_ step: FirmwareSender.Step) {
        guard let s = sender, let p = peripheral, let ch = otaChar else { return }
        switch step {
        case .wait:
            break
        case .pump:
            otaFlowing = true
            setUpdate(.sending(s.progress))
            otaPump()
        case .end:
            otaFlowing = false
            setUpdate(.verifying)
            p.writeValue(FirmwareSender.endMessage, for: ch, type: .withResponse)
        case .restarting:
            otaFlowing = false
            sender = nil
            otaWaitingRestart = true
            otaDeadline = CACurrentMediaTime() + 45
            setUpdate(.restarting)
        case .failed(let why):
            finishUpdate(.failed(why))
        }
    }

    private func handleOta(_ d: Data) {
        guard sender != nil else { return }
        let step = sender!.handle(d, now: CACurrentMediaTime())
        otaApply(step)
    }

    private func otaTick() {
        let now = CACurrentMediaTime()
        if otaWaitingRestart {
            if now > otaDeadline {
                finishUpdate(.failed("Płytka nie wróciła po restarcie. Włącz i wyłącz zapłon; jeśli wróci ze starą wersją, nic się nie stało."))
            }
            return
        }
        guard sender != nil else { return }
        let step = sender!.stalled(now: now)
        if step != .wait { otaWriteInFlight = false }   // zaległe potwierdzenie już nie przyjdzie
        if case .failed = step, let p = peripheral, let ch = otaChar, p.state == .connected {
            p.writeValue(FirmwareSender.abortMessage, for: ch, type: .withResponse)
        }
        otaApply(step)
    }

    /// Strumień surowy jest potrzebny tylko do zapisu logu i do otwartego podglądu.
    private func updateRawSubscription() {
        let want = (wantLog || viewerActive || hackerActive) && sender == nil     // w trakcie aktualizacji całe łącze dla niej
        guard let p = peripheral, let ch = rawChar, p.state == .connected, want != rawOn else { return }
        rawOn = want
        p.setNotifyValue(want, for: ch)
    }

    private func publishLogTotal() {
        closedLogBytes = Self.logFiles()
            .filter { $0.lastPathComponent != log?.url.lastPathComponent }
            .reduce(0) { $0 + Self.fileSize($1) }
        let total = closedLogBytes + (log?.bytes ?? 0)
        DispatchQueue.main.async { self.logTotalBytes = total }
    }

    private func publishBus(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard viewerActive, force || now - lastBusPublish >= 0.25 else { return }
        lastBusPublish = now
        bus.tick(at: now)
        let rows = bus.rows(at: now), learning = bus.isLearning, wheel = bus.wheelPulsesPerSec
        DispatchQueue.main.async {
            self.busRows = rows
            if self.busLearning != learning { self.busLearning = learning }
            self.wheelRate = wheel
        }
    }

    private func openLogIfNeeded() {
        let now = CACurrentMediaTime()
        // Nowy plik po dłuższej przerwie (kolejna jazda), ten sam przy chwilowym zerwaniu.
        if log != nil, now - lastRawAt > 600 { closeLog() }
        lastRawAt = now
        guard log == nil, let w = CanLogWriter(dir: Self.logDir) else { return }
        log = w
        Self.pruneLogs(keep: w.url)
        lastSeq = nil; seenIDs = []; lost = 0; markers = 0; phoneTicks = 0
        let name = w.url.lastPathComponent
        DispatchQueue.main.async {
            self.logName = name; self.logBytes = 0; self.logIDs = 0; self.logLost = 0; self.markerCount = 0
        }
        publishLogTotal()

        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.phoneTick() }
        timer.resume()
        phoneTimer = timer
    }

    private func phoneTick() {
        guard let w = log else { return }
        // Bez połączenia nie ma z czym zestawiać — nie zapisujemy samego telefonu.
        if peripheral?.state == .connected, var s = phoneSample?() {
            lock.lock(); s.track = playingTrack; lock.unlock()
            w.phone(s)
        }
        phoneTicks += 1
        if phoneTicks % 10 == 0 {
            w.flush()
            let bytes = w.bytes, ids = seenIDs.count, lostNow = lost, total = closedLogBytes + w.bytes
            DispatchQueue.main.async {
                self.logBytes = bytes; self.logIDs = ids; self.logLost = lostNow; self.logTotalBytes = total
            }
        }
        // Długa jazda: co minutę pilnujemy limitu miejsca.
        if phoneTicks % 600 == 0, closedLogBytes + w.bytes > Self.logQuotaBytes {
            Self.pruneLogs(keep: w.url)
            publishLogTotal()
        }
    }

    private func closeLog() {
        phoneTimer?.cancel()
        phoneTimer = nil
        log?.close()
        log = nil
        publishLogTotal()
    }

    private func handleRaw(_ d: Data) {
        guard let p = CanRawPacket.parse(d) else { return }
        bus.ingest(p, at: CACurrentMediaTime())
        publishBus()
        if hackerActive { feedHacker(p) }
        guard wantLog else { return }
        openLogIfNeeded()
        guard let w = log else { return }
        if let last = lastSeq {
            let gap = Int(p.seq &- last &- 1)
            if gap > 0 { lost += gap; w.line(String(format: "L,%.3f,%d", w.t, gap)) }
        }
        lastSeq = p.seq
        for r in p.records { seenIDs.insert(r.id) }
        w.can(p)
    }

    /// Do ekranu „Terminal CAN”: ramki, w których coś się zmieniło (z maską zmienionych bajtów).
    private func feedHacker(_ p: CanRawPacket) {
        hackLock.lock(); defer { hackLock.unlock() }
        let t = Double(p.boardMs) / 1000
        for r in p.records {
            let old = hackTable[r.id]
            var mask: UInt8 = 0
            for i in 0..<min(r.data.count, 8) where old == nil || i >= old!.count || old![i] != r.data[i] { mask |= 1 << i }
            hackTable[r.id] = r.data
            guard mask != 0 else { continue }
            hackLines.append(HackerLine(t: t, id: r.id, data: r.data, changed: mask))
        }
        if hackLines.count > 64 { hackLines.removeFirst(hackLines.count - 64) }
    }

    private func handleTelemetry(_ d: Data) {
        guard var t = BikeTelemetry.parse(d) else { return }
        // Po aktualizacji: pierwsza telemetria po ponownym połączeniu mówi, który program wstał.
        if otaWaitingRestart, otaSawDisconnect {
            finishUpdate(t.fwVersion == otaTarget
                ? .done(otaTarget)
                : .failed("Płytka wróciła z wersją v\(t.fwVersion) zamiast v\(otaTarget) — nowy program nie został przyjęty."))
        }
        // W połowie zmiany biegu zostaje ostatni pełny bieg — żadnych wartości pośrednich na ekranie.
        if t.gearInTransit { t.gear = lastGear } else { lastGear = t.gear }
        let now = CACurrentMediaTime()
        // Jakość łącza: numer pakietu (bajt 16) rośnie o 1; dziura = pakiety zgubione w radiu.
        let seq = d[d.startIndex + 16]
        if let last = qSeq { qLost += Int(seq &- last &- 1) }
        qSeq = seq
        qCount += 1
        if qLastAt > 0 {
            qMaxGap = max(qMaxGap, now - qLastAt)
            if now - qLastAt > 0.060 { qLate += 1 }
        }
        qLastAt = now
        if qWindow == 0 { qWindow = now }
        if now - qWindow >= 1 {
            let stats = LinkQuality(rate: qCount, lost: qLost, maxGapMs: Int((qMaxGap * 1000).rounded()), late: qLate)
            // Ostatnie pole: odstęp połączenia przyznany przez telefon [ms], 0 = płytka go nie podaje.
            let tail = String(format: "%d,%d,%d,%d,%.2f", stats.rate, stats.lost, stats.maxGapMs, stats.late, t.connIntervalMs ?? 0)
            if let w = log { w.line(String(format: "T,%.3f,", w.t) + tail) }
            writeLink(String(format: "T,%.1f,", Date().timeIntervalSince1970) + tail)
            qCount = 0; qLost = 0; qLate = 0; qMaxGap = 0; qWindow = now
            DispatchQueue.main.async { if self.quality != stats { self.quality = stats } }
        }
        lock.lock()
        latest = t; latestAt = now
        // Zakres zawieszenia poszerza się sam; zapis najwyżej raz na 10 s.
        var saveSusp: [Int]? = nil
        if t.ext, t.suspFresh {
            let moving = t.wheelFresh && t.wheelFrontRaw > 2000        // powyżej ok. 20 km/h
            motionFront.update(raw: t.suspFrontRaw, now: now, moving: moving)
            motionRear.update(raw: t.suspRearRaw, now: now, moving: moving)
        }
        if t.ext, t.suspFresh, !t.simulated {
            if suspFront.include(t.suspFrontRaw) { suspDirty = true }
            if suspRear.include(t.suspRearRaw) { suspDirty = true }
            if suspDirty, now - suspSavedAt > 10 {
                suspDirty = false; suspSavedAt = now
                saveSusp = [suspFront.extended, suspFront.compressed, suspRear.extended, suspRear.compressed]
            }
        }
        lock.unlock()
        if let v = saveSusp { UserDefaults.standard.set(v, forKey: Self.suspKey) }
        // Do interfejsu telefonu 4 razy na sekundę, a w tle i przy otwartych ustawieniach raz —
        // każde odświeżenie przelicza cały ekran apki.
        if now - lastPublish >= AppActivity.uiInterval(0.25) {
            lastPublish = now
            DispatchQueue.main.async { if self.live != t { self.live = t } }
        }
    }

    #if DEBUG
    private var loadTimer: DispatchSourceTimer?
    /// Próba obciążenia (env LOAD_TEST): sztuczna telemetria 30 pakietów na sekundę, jak z płytki
    /// w jeździe — do pomiaru zużycia procesora w symulatorze, gdzie Bluetooth nie działa.
    func debugStartLoad() {
        q.async {
            guard self.loadTimer == nil else { return }
            self.debugSeeded = true
            self.central?.delegate = nil
            self.central = nil
            self.publish(.connected)
            var n = 0
            let t = DispatchSource.makeTimerSource(queue: self.q)
            t.schedule(deadline: .now() + 1, repeating: 1.0 / 30.0)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                n += 1
                let x = Double(n) / 30
                var b = [UInt8](repeating: 0, count: 48)
                let rpm = Int(5000 + 2500 * sin(x / 3)), lean = Int(32768 + 28 * sin(x / 2.3) * 32768 / 180)
                let thr = Int(300 + 280 * sin(x / 1.7)), v = Int(9000 + 3000 * sin(x / 5))
                b[0] = 2; b[1] = 0x0F
                b[2] = UInt8(rpm & 255); b[3] = UInt8(rpm >> 8)
                b[4] = UInt8(thr >> 2); b[5] = UInt8((thr & 3) << 6 | 4)
                b[6] = UInt8(lean & 255); b[7] = UInt8(lean >> 8)
                for i in stride(from: 8, to: 14, by: 2) { b[i] = 0x00; b[i + 1] = 0x80 }
                b[14] = 0xB2; b[15] = 0x07; b[16] = UInt8(n & 255); b[17] = 7
                b[18] = 0xFF; b[19] = 190; b[20] = 0
                b[23] = UInt8(v >> 8); b[24] = UInt8(v & 255); b[25] = b[23]; b[26] = b[24]
                let f = Int(1000 + 200 * sin(x * 2)), r = Int(490 + 30 * sin(x * 1.3))
                b[29] = UInt8(f >> 8); b[30] = UInt8(f & 255); b[31] = UInt8(r >> 8); b[32] = UInt8(r & 255); b[33] = 10
                b[34] = 0x05; b[35] = 0x9C; b[36] = 0x40; b[37] = 48
                b[38] = 0x20; b[39] = 0x61; b[40] = 0x14; b[41] = 0x10
                b[42] = 0x07; b[43] = 0x77; b[44] = 0x77; b[45] = 0x37; b[46] = 0x41
                self.handleTelemetry(Data(b))
            }
            t.resume()
            self.loadTimer = t
        }
    }

    /// Dane pokazowe do obejrzenia podglądu magistrali w symulatorze (env BUS_UI=1).
    func debugSeedBus() {
        q.async {
            // Symulator nie ma Bluetooth — blokujemy start menedżera, żeby jego zgłoszenie
            // „nieobsługiwane" nie skasowało danych pokazowych.
            self.debugSeeded = true
            self.central?.delegate = nil
            self.central = nil
            self.viewerActive = true
            let t0 = CACurrentMediaTime() - 4
            var t = t0
            func packet(_ brake: UInt8, _ counter: UInt8) -> CanRawPacket {
                CanRawPacket(seq: counter, boardMs: UInt32((t - t0) * 1000) + 60_000, records: [
                    .init(id: 0x1A1, count: 10, data: [0x0E, 0xB5 &+ counter, 0x05, 0x84, 0x0B, 0, counter & 15, 0]),
                    .init(id: 0x1A5, count: 10, data: [0x74, 0xE2, 0x80, 0, 0xC4, 0, counter & 15, 0]),
                    .init(id: 0x1A9, count: 10, data: [0, 0, brake, 0x4C, 0, 0, counter & 15, 0]),
                    .init(id: 0x181, count: 10, data: [0x80, 0x48, 0x6D, 0x3F, 0x85, 0x6C &+ counter, counter & 15, counter &* 37]),
                    .init(id: 0x221, count: 5, data: [0, counter &* 3, 0x07, 0x65, 0x80, 0, counter & 15, 0]),
                    .init(id: 0x3B1, count: 1, data: [0xA4, 0xAE, 0x08, 0x01, 0xCC, 0xBA, 0x01, 0]),
                ])
            }
            for i in 0..<10 { self.bus.ingest(packet(0x7D, UInt8(i)), at: t); t += 0.1 }
            self.bus.startLearning(at: t, duration: 1.5)
            for i in 10..<30 { self.bus.ingest(packet(0x7D, UInt8(i)), at: t); t += 0.1 }
            for i in 30..<40 { self.bus.ingest(packet(0x95, UInt8(i)), at: t); t += 0.1 }
            var tele = BikeTelemetry()
            tele.rpm = 3765; tele.gear = 4; tele.throttleRaw = 5; tele.throttle10 = 22
            tele.leanWord = 29922; tele.accelWords = [32840, 27967, 34156]
            tele.engineFresh = true; tele.leanFresh = true; tele.accelFresh = true
            tele.busFps = 1970; tele.fwVersion = Self.currentFirmware
            let rows = self.bus.rows(at: t), wheel = self.bus.wheelPulsesPerSec
            DispatchQueue.main.async {
                self.state = .connected; self.live = tele
                self.busRows = rows; self.wheelRate = wheel
                self.logName = "can_20261010_101500.csv"; self.logBytes = 18_400_000; self.logIDs = 28
            }
        }
    }
    #endif
}

// MARK: — CoreBluetooth

extension BikeLinkManager: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            seek()
        case .poweredOff:
            peripheral = nil; rawChar = nil; rawOn = false
            clearLatest()
            publish(.bluetoothOff)
        case .unauthorized:
            publish(.unauthorized)
        case .unsupported:
            publish(.unsupported)
        default:
            break
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if peripheral?.identifier != p.identifier {
            if let old = peripheral { c.cancelPeripheralConnection(old) }
            peripheral = p
            p.delegate = self
            UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedKey)
        }
        if p.state == .disconnected {
            c.connect(p)
            publish(.connecting)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        guard p.identifier == peripheral?.identifier else { return }
        c.stopScan()
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedKey)
        publish(.connecting)
        p.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        q.asyncAfter(deadline: .now() + 2) { [weak self] in self?.seek() }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        rawChar = nil
        rawOn = false
        otaChar = nil
        diagChar = nil
        if diagOp != nil { diagFinish(.failed("Połączenie z płytką zerwane w trakcie komendy.")) }
        qSeq = nil; qLastAt = 0; qWindow = 0; qCount = 0; qLost = 0; qLate = 0; qMaxGap = 0
        DispatchQueue.main.async { self.updateSupported = false; self.diagSupported = false; self.quality = LinkQuality() }
        if otaWaitingRestart {
            otaSawDisconnect = true          // spodziewane: płytka startuje nowy program
        } else if sender != nil {
            finishUpdate(.failed("Połączenie z płytką zerwane w trakcie wysyłania. Stary program działa dalej."))
        }
        clearLatest()
        seek()
    }

    // MARK: — Kody błędów (OBD przez płytkę)

    /// Odczyt albo skasowanie kodów błędów. Płytka sama odmówi, gdy silnik pracuje
    /// albo koło się kręci, i wraca do samego nasłuchu najpóźniej po kilku sekundach.
    func runDiagnostic(_ op: DiagOp, addr: DiagAddr = .func11) {
        q.async { [self] in
            guard diagOp == nil else { return }
            guard let p = peripheral, let ch = diagChar, p.state == .connected else {
                DispatchQueue.main.async { self.diagState = .failed("Płytka niepołączona albo ma za stary program (potrzebny v9).") }
                return
            }
            diagOp = op
            diagReplies = []
            DispatchQueue.main.async { self.diagState = .running(op) }
            p.writeValue(Data([op.rawValue, addr.rawValue]), for: ch, type: .withResponse)
            let t = DispatchWorkItem { [weak self] in
                self?.diagFinish(.failed("Płytka nie zakończyła komendy w 15 s."))
            }
            diagTimeout = t
            q.asyncAfter(deadline: .now() + 15, execute: t)
        }
    }

    func clearDiagnosticResult() {
        q.async { [self] in
            guard diagOp == nil else { return }
            DispatchQueue.main.async { self.diagState = .idle }
        }
    }

    /// Powiadomienie płytki (od v10): [0x00][op][ID 4 B, bit 0x80 = 29-bit][len][dane]
    /// albo [status][op][liczba][wysłane][odrzucone][licznik błędów nadawania].
    private func handleDiag(_ d: Data) {
        let b = [UInt8](d)
        guard let op = diagOp, b.count >= 3 else { return }
        switch b[0] {
        case 0x00:
            guard b.count >= 7 else { return }
            let ext = b[5] & 0x80 != 0
            let id = UInt32(b[2]) | UInt32(b[3]) << 8 | UInt32(b[4]) << 16 | UInt32(b[5] & 0x1F) << 24
            let n = min(Int(b[6]), b.count - 7)
            let reply = DiagReply(ecu: id, ext: ext, bytes: Array(b[7 ..< 7 + n]))
            // Ostatnia odpowiedź każdego sterownika (po „przetwarzam…” przychodzi właściwa).
            diagReplies.removeAll { $0.ecu == id && $0.ext == ext }
            diagReplies.append(reply)
        case 0x30:
            var tx = DiagTx()
            if b.count >= 6 { tx = DiagTx(sent: Int(b[3]), failed: Int(b[4]), errorCounter: Int(b[5])) }
            let replies = diagReplies.sorted { ($0.isObd ? 0 : 1, $0.ecu) < ($1.isObd ? 0 : 1, $1.ecu) }
            if op == .probe || op == .read {
                let addr = replies.lazy.compactMap { Obd.clearAddr(for: $0) }.first
                DispatchQueue.main.async { self.diagClearAddr = addr }
            }
            diagFinish(.finished(op, replies, tx))
        case 0x20: diagFinish(.failed("Płytka odmówiła: silnik pracuje albo koło się kręci. Zgaś silnik, zapłon zostaw włączony."))
        case 0x21: diagFinish(.failed("Płytka zajęta — spróbuj za kilka sekund."))
        case 0x22: diagFinish(.failed("Szyna CAN milczy — włącz zapłon."))
        case 0x23: diagFinish(.failed("Płytka nie zdołała nadać zapytania (nikt go nie potwierdził). Wróciła do samego nasłuchu."))
        default:   diagFinish(.failed(String(format: "Nieznana odpowiedź płytki 0x%02X.", b[0])))
        }
    }

    private func diagFinish(_ state: DiagState) {
        diagTimeout?.cancel()
        diagTimeout = nil
        diagOp = nil
        DispatchQueue.main.async { self.diagState = state }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            // Nie nasza płytka albo błąd — rozłącz, seek() spróbuje ponownie.
            central?.cancelPeripheralConnection(p)
            return
        }
        p.discoverCharacteristics([Self.teleUUID, Self.rawUUID, Self.otaUUID, Self.diagUUID], for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        var haveTelemetry = false
        for ch in service.characteristics ?? [] {
            if ch.uuid == Self.teleUUID {
                p.setNotifyValue(true, for: ch)
                haveTelemetry = true
            } else if ch.uuid == Self.rawUUID {
                rawChar = ch
                rawOn = false
                updateRawSubscription()
            } else if ch.uuid == Self.otaUUID {
                otaChar = ch
                p.setNotifyValue(true, for: ch)
            } else if ch.uuid == Self.diagUUID {
                diagChar = ch
                p.setNotifyValue(true, for: ch)
            }
        }
        let canUpdate = otaChar != nil, canDiag = diagChar != nil
        DispatchQueue.main.async { self.updateSupported = canUpdate; self.diagSupported = canDiag }
        guard haveTelemetry else {
            central?.cancelPeripheralConnection(p)
            return
        }
        publish(.connected)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        if ch.uuid == Self.teleUUID {
            handleTelemetry(d)
        } else if ch.uuid == Self.rawUUID {
            handleRaw(d)
        } else if ch.uuid == Self.otaUUID {
            handleOta(d)
        } else if ch.uuid == Self.diagUUID {
            handleDiag(d)
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == Self.otaUUID, sender != nil else { return }
        if let error {
            finishUpdate(.failed("Płytka odrzuciła dane aktualizacji (\(error.localizedDescription)). Stary program działa dalej."))
            return
        }
        otaWriteInFlight = false
        otaPump()
    }
}
