// ObdDiagnostics.swift
// Kody błędów motocykla przez płytkę CAN (program płytki od wersji 9, diag_core.h).
// Płytka wysyła standardowe zapytanie OBD (ISO 15765-4, adres 0x7DF) i przekazuje
// odpowiedzi sterowników. Tu tylko dekodowanie — testowane w FeatureSelfTest.

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

enum DiagState: Equatable {
    case idle
    case running(DiagOp)
    case finished(DiagOp, [DiagReply], DiagTx)
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

    /// Którym adresowaniem kasować, skoro dany sterownik odpowiedział na odczyt.
    /// 0x7DF zostało już sprawdzone bez odpowiedzi, więc 11-bit = bezpośrednio do 0x7E0.
    static func clearAddr(for r: DiagReply) -> DiagAddr? {
        guard r.isObd, r.bytes.first == 0x43 else { return nil }
        return r.ext ? .func29 : .phys11
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
            return c.map { code in meaning(code).map { "\(code) — \($0)" } ?? code }.joined(separator: "\n")
        }
    }
}
