// ObdDiagnostics.swift
// Trouble codes of the motorcycle through the CAN board. Full description: docs/DIAGNOSTICS.md.
//
// Two sources:
//  1. Frame 0x441 — the bike broadcasts its list of stored codes by itself, about 9 times
//     a second. Reading it needs no transmission at all, so it always works (StoredCodeCollector).
//     This is the list that matches the FI light.
//  2. OBD requests (ISO 15765-4) sent by the board (firmware v9+, diag_core.h): service 04
//     clears the codes, service 03 reads the emission-related ones (on the GSX-S1000GX that
//     list is empty even when 0x441 has codes — do not treat it as "no faults").
// Only decoding and decisions live here — covered by FeatureSelfTest.

import Foundation

enum DiagOp: UInt8 {
    case ping = 0x01     // czy sterowniki odpowiadają na OBD (nic nie zmienia)
    case read = 0x03     // odczyt zapisanych kodów (nic nie zmienia)
    case clear = 0x04    // skasowanie kodów i lampki FI
    case probe = 0x05    // odczyt kodów trzema sposobami adresowania (płytka od v10)
}

/// Sposób adresowania zapytania (diag_core.h).
enum DiagAddr: UInt8 {
    case func11 = 0      // ogólne 11-bit 0x7DF
    case phys11 = 1      // sterownik silnika 11-bit 0x7E0
    case func29 = 2      // ogólne 29-bit 0x18DB33F1
}

/// Ile ramek komendy płytka wysłała i ile nikt nie potwierdził.
struct DiagTx: Equatable {
    var sent = 0
    var failed = 0
    var errorCounter = 0
}

struct DiagReply: Equatable {
    let ecu: UInt32
    var ext = false          // adres 29-bitowy
    let bytes: [UInt8]

    /// Odpowiedź OBD (ISO-TP złożona przez płytkę), a nie surowa ramka „z ciekawości”.
    var isObd: Bool { ext ? (ecu & 0xFFFF_FF00) == 0x18DA_F100 : (0x7E8...0x7EF).contains(ecu) }
}

/// Stored trouble codes as broadcast in frame 0x441.
struct StoredCodes: Equatable {
    var total = 0                // how many codes the bike says it has
    var codes: [String] = []     // in list order; shorter than `total` when not every position was seen
    var complete: Bool { codes.count == total }
}

/// Puts the list of stored codes together from 0x441 frames. One frame carries one code:
/// byte 3 = number of codes, byte 4 = position 1…n (cycles), bytes 1–2 = the code.
/// With no codes bytes 0–5 are zero.
struct StoredCodeCollector {
    static let frameID: UInt16 = 0x441
    private(set) var frames = 0
    private var zeroFrames = 0       // consecutive frames saying "no codes"
    private var total = 0
    private var byPosition: [Int: String] = [:]

    mutating func ingest(_ d: [UInt8]) {
        guard d.count >= 5 else { return }
        frames += 1
        let n = Int(d[3])
        guard n > 0 else {
            zeroFrames += 1
            if zeroFrames >= 2 { total = 0; byPosition = [:] }
            return
        }
        zeroFrames = 0
        if n != total { total = n; byPosition = [:] }      // the list changed — start over
        let pos = Int(d[4])
        guard (1...n).contains(pos), d[1] != 0 || d[2] != 0 else { return }
        byPosition[pos] = Obd.dtc(d[1], d[2])
    }

    private var list: StoredCodes {
        StoredCodes(total: total, codes: byPosition.keys.sorted().compactMap { byPosition[$0] })
    }

    /// The answer once it is certain: an empty list (two "no codes" frames in a row) or every
    /// position seen. nil = keep listening.
    var result: StoredCodes? {
        if total == 0 { return zeroFrames >= 2 ? StoredCodes() : nil }
        return byPosition.count == total ? list : nil
    }

    /// Best answer when the time is up. nil = the frame did not show up at all.
    var partial: StoredCodes? { frames == 0 ? nil : list }
}

enum DiagStep: Equatable {
    case listening          // reading the list of stored codes (no transmission)
    case clearing(Int)      // clear request, attempt 1…3 (three ways of addressing)
    case verifying          // reading the list again after clearing
    case probing            // OBD test: read request sent three ways
}

/// What a finished read / clear / OBD test found.
struct DiagReport: Equatable {
    enum Kind { case read, clear, probe }
    var kind: Kind
    var before: StoredCodes?         // list from 0x441; nil = frame not seen
    var after: StoredCodes?          // clear only: the list read again afterwards
    var confirmed = false            // clear only: a control unit answered "cleared" (0x44)
    var refusal: UInt8?              // clear only: last refusal code (7F 04 xx)
    var replies: [DiagReply] = []    // replies to the last OBD command
    var tx = DiagTx()                // frames delivered / lost attempts, summed over the commands
}

enum DiagState: Equatable {
    case idle
    case running(DiagStep)
    case finished(DiagReport)
    case failed(String)
}

enum Obd {
    /// Kod w formacie SAE J2012 z dwóch bajtów: bity 7–6 = litera, 5–4 = pierwsza cyfra.
    static func dtc(_ a: UInt8, _ b: UInt8) -> String {
        let letter = ["P", "C", "B", "U"][Int(a >> 6)]
        return String(format: "%@%d%X%02X", letter, Int((a >> 4) & 0x3), Int(a & 0x0F), Int(b))
    }

    /// Kody z odpowiedzi na usługę 03: [43, liczba, kod, kod, ...]. nil = to nie taka odpowiedź.
    static func codes(_ bytes: [UInt8]) -> [String]? {
        guard bytes.first == 0x43, bytes.count >= 2 else { return nil }
        let n = Int(bytes[1])
        var out: [String] = []
        var i = 2
        while out.count < n, i + 1 < bytes.count {
            if bytes[i] != 0 || bytes[i + 1] != 0 { out.append(dtc(bytes[i], bytes[i + 1])) }
            i += 2
        }
        return out
    }

    /// Znaczenie znanych kodów (standard OBD; P-kody producenta — nieznane).
    static func meaning(_ code: String) -> String? {
        [
            "U0073": String(localized: "szyna CAN wyłączona (bus off)"),
            "U0100": String(localized: "brak łączności ze sterownikiem silnika"),
            "U0121": String(localized: "brak łączności z ABS"),
            "U0123": String(localized: "brak łączności z czujnikiem ruchu (IMU)"),
            "U0132": String(localized: "brak łączności ze sterownikiem zawieszenia"),
            "U0155": String(localized: "brak łączności z zegarami"),
        ][code]
    }

    /// Sterownik po adresie odpowiedzi. 0x7E8 to w OBD zawsze sterownik silnika.
    static func ecuName(_ id: UInt32, ext: Bool = false) -> String {
        if ext { return String(format: String(localized: "sterownik %08X (29-bit)"), id) }
        return id == 0x7E8 ? String(localized: "silnik (7E8)") : String(format: String(localized: "sterownik %03X"), id)
    }

    /// Order in which the clear request is tried. The engine control unit of the GX answered
    /// the direct 11-bit address (2026-10-25); the general ones are the fallback for other bikes.
    static let clearOrder: [DiagAddr] = [.phys11, .func11, .func29]

    enum ClearOutcome: Equatable {
        case confirmed            // a control unit answered 0x44
        case refused(UInt8)       // 7F 04 xx
        case silent               // nobody answered
    }

    /// What the replies to one clear request (service 04) mean.
    static func clearOutcome(_ replies: [DiagReply]) -> ClearOutcome {
        let obd = replies.filter(\.isObd)
        if obd.contains(where: { $0.bytes.first == 0x44 }) { return .confirmed }
        if let no = obd.first(where: { $0.bytes.count >= 3 && $0.bytes[0] == 0x7F && $0.bytes[1] == 0x04 && $0.bytes[2] != 0x78 }) {
            return .refused(no.bytes[2])
        }
        return .silent
    }

    /// After such a refusal another way of addressing reaches the same control unit in the
    /// same state — trying again makes no sense.
    static func refusalIsFinal(_ nrc: UInt8) -> Bool { nrc == 0x22 || nrc == 0x33 }

    /// The board refused or failed the command (status codes from diag_core.h).
    static func boardError(_ status: UInt8) -> String {
        switch status {
        case 0x20: return String(localized: "Płytka odmówiła: silnik pracuje albo koło się kręci. Zgaś silnik, zapłon zostaw włączony.")
        case 0x21: return String(localized: "Płytka zajęta — spróbuj za kilka sekund.")
        case 0x22: return String(localized: "Szyna CAN milczy — włącz zapłon.")
        case 0x23: return String(localized: "Płytka nie zdołała nadać zapytania (nikt go nie potwierdził). Wróciła do samego nasłuchu.")
        default:   return String(format: String(localized: "Nieznana odpowiedź płytki 0x%02X."), status)
        }
    }

    /// One code with its meaning, when known.
    static func describe(_ code: String) -> String {
        meaning(code).map { "\(code) — \($0)" } ?? code
    }

    /// The headline of a finished read or clear: what happened, in one or two sentences.
    /// `ok` = nothing left to do (green), otherwise the text is a warning.
    static func verdict(_ r: DiagReport) -> (text: String, ok: Bool) {
        switch r.kind {
        case .probe:
            return r.replies.contains(where: \.isObd)
                ? (String(localized: "Sterownik odpowiada na OBD."), true)
                : (String(localized: "Żaden sterownik nie odpowiedział na OBD."), false)
        case .read:
            guard let list = r.before else {
                return (String(localized: "Nie widzę listy kodów na szynie. Włącz zapłon i spróbuj ponownie."), false)
            }
            if list.total == 0 { return (String(localized: "Brak zapisanych kodów."), true) }
            return list.complete
                ? (String(localized: "Zapisane kody: \(list.total)"), false)
                : (String(localized: "Zapisane kody: \(list.total) (odczytane \(list.codes.count) — spróbuj ponownie)"), false)
        case .clear:
            let left = r.after.map { $0.total > 0 } ?? false
            if r.confirmed {
                if left { return (String(localized: "Sterownik potwierdził kasowanie, ale kody są znowu na liście — usterka nadal trwa."), false) }
                return r.after == nil
                    ? (String(localized: "Sterownik potwierdził kasowanie. Listy kodów nie udało się sprawdzić."), true)
                    : (String(localized: "Kody skasowane — lista w motocyklu jest pusta."), true)
            }
            if r.after != nil, !left, (r.before?.total ?? 0) > 0 {
                return (String(localized: "Lista kodów jest pusta, choć sterownik nie potwierdził kasowania."), true)
            }
            if let nrc = r.refusal {
                let why = refusal(nrc)
                return (String(localized: "Sterownik odmówił kasowania: \(why)."), false)
            }
            if r.tx.sent == 0 {
                return (String(localized: "Zapytanie nie wyszło na szynę (zajęta albo nikt nie potwierdza). Spróbuj ponownie."), false)
            }
            return (String(localized: "Żaden sterownik nie odpowiedział na kasowanie. Zapłon włączony, silnik zgaszony?"), false)
        }
    }

    /// Kody odmowy (UDS/OBD) po polsku.
    static func refusal(_ nrc: UInt8) -> String {
        switch nrc {
        case 0x11: return String(localized: "ta usługa nieobsługiwana")
        case 0x12: return String(localized: "ta funkcja nieobsługiwana")
        case 0x22: return String(localized: "warunki niespełnione (np. silnik pracuje)")
        case 0x31: return String(localized: "zapytanie poza zakresem")
        case 0x33: return String(localized: "wymaga zabezpieczenia serwisowego")
        case 0x78: return String(localized: "przetwarzam…")
        default: return String(format: String(localized: "odmowa 0x%02X"), nrc)
        }
    }

    /// Jedno zdanie o odpowiedzi sterownika na daną komendę.
    static func summary(_ op: DiagOp, _ r: DiagReply) -> String {
        let b = r.bytes
        if !r.isObd {
            let hexBytes = b.map { String(format: "%02X", $0) }.joined(separator: " ")
            return String(localized: "ramka: \(hexBytes)")
        }
        if b.count >= 3, b[0] == 0x7F {
            let why = refusal(b[2])
            return String(localized: "odmowa: \(why)")
        }
        switch op {
        case .ping:
            return b.first == 0x41 ? String(localized: "odpowiada na OBD") : String(localized: "nieznana odpowiedź")
        case .clear:
            return b.first == 0x44 ? String(localized: "kody skasowane") : String(localized: "nieznana odpowiedź")
        case .read, .probe:
            guard let c = codes(b) else { return String(localized: "nieznana odpowiedź") }
            if c.isEmpty { return String(localized: "brak zapisanych kodów") }
            return c.map(describe).joined(separator: "\n")
        }
    }
}
