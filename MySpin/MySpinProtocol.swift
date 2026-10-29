// MySpinProtocol.swift
// Stałe i pomocnicze funkcje binarne protokołu mySPIN v1.2.0
//
// Format pakietu TCP:
//   Bajt 0:     type         (1B)
//   Bajt 1–4:   field_b      (UInt32 little-endian, zawsze 0)
//   Bajt 5–8:   payload_len  (UInt32 little-endian)
//   Bajt 9+:    payload

import Foundation

// MARK: — Typy pakietów

enum MySpinPacket: UInt8 {
    // Handshake
    case clientProtocolVersion    = 1
    case serverProtocolAck        = 2
    case clientInit               = 11
    case serverInitAck            = 12
    case serverInit               = 14
    case clientInitDone           = 17
    case serverInitDone           = 18

    // Runtime — od motocykla
    case touchEvent               = 21
    case pixelFormatAck           = 22
    case overrideCompression      = 23
    case setPixelFormat           = 24
    case screenRequest            = 25
    case softkeyEvent             = 31
    case setFrameCompression      = 33
    case setBlockMode             = 39
    case clientSettings           = 58
    case voiceSupportInfo         = 61
    case clientSettings2          = 69
    case positionInformation      = 27
    case dataSubscription         = 54   // phone→moto: subskrypcja kanałów danych
    case dataUpdate               = 55   // moto→phone: JSON update dla kanału
    case clientRawData            = 131

    // Runtime — wysyłamy
    case framebufferUpdate        = 26
    case screenActivation         = 36
    case appList                  = 70
    case audio                    = 35
    case serverCustomData         = 128  // ping-pong response do type 129
    case serverCustomMessage      = 129

    var name: String {
        switch self {
        case .clientProtocolVersion:  return "ClientProtocolVersion"
        case .serverProtocolAck:      return "ServerProtocolAck"
        case .clientInit:             return "ClientInit"
        case .serverInitAck:          return "ServerInitAck"
        case .serverInit:             return "ServerInit"
        case .clientInitDone:         return "ClientInitDone"
        case .serverInitDone:         return "ServerInitDone"
        case .touchEvent:             return "TouchEvent"
        case .softkeyEvent:           return "SoftkeyEvent"
        case .framebufferUpdate:      return "FramebufferUpdate"
        case .screenRequest:          return "ScreenRequest"
        case .positionInformation:    return "PositionInformation"
        case .dataSubscription:       return "DataSubscription"
        case .dataUpdate:             return "DataUpdate"
        case .serverCustomData:       return "ServerCustomData(Ping)"
        case .serverCustomMessage:    return "ServerCustomMessage(Ping)"
        case .clientRawData:          return "ClientRawData"
        default:                      return "Packet(\(self.rawValue))"
        }
    }
}

func packetName(_ type: UInt8) -> String {
    MySpinPacket(rawValue: type)?.name ?? "Unknown(\(type))"
}

// MARK: — Kodowanie binarne (little-endian)

extension Data {
    /// Uint32 LE → 4 bajty
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }

    /// String z 4-bajtowym prefixem długości (LE) — format mySPIN
    mutating func appendWStr(_ s: String) {
        let bytes = s.utf8
        appendLE(UInt32(bytes.count))
        append(contentsOf: bytes)
    }

    /// Inicjalizacja z hex stringa (spacje ignorowane). "04 01 00" → Data([4,1,0])
    init(hexString: String) {
        let clean = hexString.filter { !$0.isWhitespace }
        var bytes = [UInt8]()
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2, limitedBy: clean.endIndex) ?? clean.endIndex
            if let b = UInt8(clean[idx..<next], radix: 16) { bytes.append(b) }
            idx = next
        }
        self = Data(bytes)
    }

    /// Czyta UInt32 LE z podanego offsetu
    /// Używa startIndex — bezpieczne na slice'ach i po removeFirst()
    func readLE32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        guard base + 4 <= endIndex else { return 0 }
        return UInt32(self[base])
            | UInt32(self[base + 1]) << 8
            | UInt32(self[base + 2]) << 16
            | UInt32(self[base + 3]) << 24
    }
}

// MARK: — Budowanie pakietów

struct MySpinPacketBuilder {

    /// Nagłówek 9 bajtów + payload
    static func build(type ptype: UInt8, payload: Data = Data()) -> Data {
        var pkt = Data()
        pkt.append(ptype)
        pkt.appendLE(0)                          // field_b = 0
        pkt.appendLE(UInt32(payload.count))      // payload_len
        pkt.append(payload)
        return pkt
    }

    /// Pakiet bez payload
    static func build(type ptype: MySpinPacket, payload: Data = Data()) -> Data {
        build(type: ptype.rawValue, payload: payload)
    }

    // ── Konkretne pakiety handshake ──

    /// ServerProtocolAcknowledge (type 2) — potwierdzamy wersję protokołu
    static func serverProtocolAck() -> Data {
        build(type: .serverProtocolAck, payload: Data([0x01]))
    }

    /// ServerInitAcknowledge (type 12) — potwierdzamy ClientInit
    static func serverInitAck() -> Data {
        build(type: .serverInitAck, payload: Data([0x01]))
    }

    /// ServerInit (type 14) — mówimy motocyklowi czym jesteśmy
    ///
    /// Format payload (ustalony na potrzeby współdziałania z wyświetlaczem):
    ///   1B  flaga sukcesu (0x01)
    ///   4B+N nazwa serwera (wstr)
    ///   1B  obsługiwane kompresje (0x06 = JPEG|ZLIB)
    ///   1B  liczba ekranów
    ///   4B+N nazwa systemu (wstr)
    /// ServerInit (type 14)
    ///
    /// Exact 15-byte payload reverse-engineered from pcapng capture of real mySPIN iOS app:
    ///   01          status = success
    ///   01          compression = JPEG (0x01)
    ///   0e 00 00 00 server capabilities (LE uint32 = 14)
    ///   01          number of screens
    ///   03 00       osName length (2-byte LE = 3)
    ///   69 4f 53    "iOS"
    ///   01 00 00    trailing flags/padding
    static func serverInit() -> Data {
        let payload = Data([0x01, 0x01, 0x0e, 0x00, 0x00, 0x00, 0x01,
                            0x03, 0x00, 0x69, 0x4f, 0x53, 0x01, 0x00, 0x00])
        return build(type: .serverInit, payload: payload)
    }

    /// ServerInitDone (type 18) — kończymy handshake z naszej strony
    static func serverInitDone() -> Data {
        build(type: .serverInitDone, payload: Data([0x01]))
    }

    /// AppList (type 70) — lista aplikacji wysyłana po handshake w odpowiedzi na type 67.
    ///
    /// Payload zarejestrowany z pcapng (realny mySPIN iOS, 850B, 12 aplikacji Bosch/third-party).
    /// Motocykl potrzebuje tej wiadomości żeby aktywować wyświetlanie klatek.
    static func appList() -> Data {
        // 850 dokładnych bajtów z pcapng, wygenerowane przez parser Pythona
        let hex =
            "00000000" +
            "" +
            "" +
            "" +
            "" +
            "" +
            "" +
            "" +
            "" +
            "" +
            "" +
            "" +
            "" +
            ""
        var payload = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            if let byte = UInt8(hex[i..<j], radix: 16) { payload.append(byte) }
            i = j
        }
        return build(type: .appList, payload: payload)
    }

    // ── Pakiety runtime ──

    /// ScreenActivation (type 36) — aktywuje wyświetlanie klatek na ekranie motocykla.
    ///
    /// Zaobserwowane w pcapng (realny mySPIN iOS):
    ///   on=true  → `01 00 00 00 00 00`   (screen active/init)
    ///   on=false → `04 00 00 00 00 00`   (screen inactive)
    ///   toggle   → `04 01 00 00 00 00`   (stream start?)
    static func screenActivation(on: Bool) -> Data {
        let payload: Data = on
            ? Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00])
            : Data([0x04, 0x00, 0x00, 0x00, 0x00, 0x00])
        return build(type: .screenActivation, payload: payload)   // type 36
    }

    /// FramebufferUpdate (type 26) — wysyła klatkę JPEG.
    ///
    /// Format payload zidentyfikowany z pcapng (realny mySPIN iOS, 3 klatki):
    ///   [0-3]   00 00 00 00     — zero field
    ///   [4-7]   01 00 00 00     — rect count = 1 (4B LE)
    ///   [8]     00              — screen ID = 0
    ///   [9-10]  60 03           — width = 864 (2B LE)
    ///   [11-12] 40 01           — height = 320 (2B LE)
    ///   [13-14] 03 02           — encoding flags (constant)
    ///   [15]    01              — compression = JPEG
    ///   [16-18] 00 00 00        — padding
    ///   [19]    04              — constant
    ///   [20-21] 64 64           — quality params (100, 100)
    ///   [22-25] XX XX XX XX     — JPEG data length (4B LE)
    ///   [26+]   JPEG data
    static func framebufferUpdate(jpeg: Data, width: UInt32 = 864, height: UInt32 = 320) -> Data {
        var payload = Data()
        payload.appendLE(UInt32(0))                         // [0-3]  zero field
        payload.appendLE(UInt32(1))                         // [4-7]  rect count = 1
        payload.append(0x00)                                // [8]    screen ID = 0
        payload.append(UInt8(width  & 0xFF))                // [9]    width low byte
        payload.append(UInt8(width  >> 8))                  // [10]   width high byte
        payload.append(UInt8(height & 0xFF))                // [11]   height low byte
        payload.append(UInt8(height >> 8))                  // [12]   height high byte
        payload.append(contentsOf: [0x03, 0x02])            // [13-14] encoding flags
        payload.append(0x01)                                // [15]   JPEG compression
        payload.append(contentsOf: [0x00, 0x00, 0x00])      // [16-18] padding
        payload.append(0x04)                                // [19]   constant
        payload.append(contentsOf: [0x64, 0x64])            // [20-21] quality 100,100
        payload.appendLE(UInt32(jpeg.count))                // [22-25] JPEG length
        payload.append(jpeg)                                // [26+]  JPEG data
        return build(type: .framebufferUpdate, payload: payload)
    }

    /// DataSubscription (type 54) — subskrybuje 80 kanałów danych od motocykla.
    ///
    /// Format: [2B LE count] [count × 4B LE channel_id]
    /// Lista kanałów wyekstrahowana z pcapng realnego mySPIN iOS.
    static func dataSubscription() -> Data {
        let channelIds: [UInt32] = [
            0x00000001, 0x00000002, 0x00000003, 0x0156C4B3, 0x0267A2BB,
            0x02EDB78E, 0x084374FD, 0x0AE537F4, 0x0BBFE288, 0x0BC7DF81,
            0x0F6F3287, 0x1166C981, 0x137D344E, 0x15EF5993, 0x16CCA940,
            0x1CD35363, 0x1F824BAD, 0x271F516C, 0x27D013FE, 0x2821BD75,
            0x2CC0DBEC, 0x318E5203, 0x32DA65B1, 0x3DC60FC7, 0x3E8A93BF,
            0x3FEBE1C1, 0x42CF35C6, 0x43388D1C, 0x43F71B3F, 0x451617F8,
            0x486C6EC1, 0x50E4C4CF, 0x540DF80D, 0x57D36E5E, 0x5F5CF9F7,
            0x6B60AE39, 0x6D982AAC, 0x6FCA4449, 0x7079FD63, 0x73436A4C,
            0x746062C9, 0x781190A4, 0x7D22F7FE, 0x80D5FFDD, 0x82E560FF,
            0x833F41EB, 0x8A6FEA60, 0x8CFBF3D5, 0x8F7B8E73, 0x90F66D09,
            0x91644F6C, 0x955F48E5, 0x9FCB4386, 0xA056EE25, 0xA5A64F9D,
            0xAA6AE335, 0xAAA97AF0, 0xAC729AAD, 0xAD31101E, 0xADFFD0E0,
            0xAFE088C9, 0xB45CEC94, 0xBBA0F777, 0xC0366DAD, 0xC0E3A10F,
            0xC54D5279, 0xC8537BE2, 0xC8CC087B, 0xCB085DF9, 0xDBB15B72,
            0xDC55FE4A, 0xDE74F274, 0xE343911B, 0xE84600FA, 0xEDCE10E1,
            0xEE3DD907, 0xF18B12BB, 0xF31C07FD, 0xF77A054B, 0xF81C8965
        ]
        var payload = Data()
        // 2B LE count
        payload.append(UInt8(channelIds.count & 0xFF))
        payload.append(UInt8(channelIds.count >> 8))
        // 4B LE per channel_id
        for cid in channelIds {
            payload.appendLE(cid)
        }
        return build(type: .dataSubscription, payload: payload)
    }

    /// ServerCustomData (type 128) — odpowiedź ping na type 129 (ServerCustomMessage).
    ///
    /// Motocykl wysyła type 129 z 4B LE counter.
    /// Odpowiadamy type 128 z tym samym counter — utrzymuje połączenie.
    static func pingResponse(counter: UInt32) -> Data {
        var payload = Data()
        payload.appendLE(counter)
        return build(type: .serverCustomData, payload: payload)
    }
}

// MARK: — Parsowanie pakietu SoftkeyEvent (type 31)

struct SoftkeyEvent {
    let rawPayload: Data
    let keyId:    UInt8
    let action:   UInt8       // 1 = wciśnięty (down), 2 = puszczony (up)
    var isPressed: Bool { action == 1 }

    /// Legacy: parsowanie pakietu type 31 ([1]=keyId, [2]=action).
    init(rawPayload: Data) {
        self.rawPayload = rawPayload
        let b = rawPayload.startIndex
        self.keyId  = rawPayload.count > 1 ? rawPayload[b+1] : 0
        self.action = rawPayload.count > 2 ? rawPayload[b+2] : 0
    }

    /// Explicit — używane dla type 67 key event (keyId na offset 5, down/up na offset 1).
    init(keyId: UInt8, action: UInt8, rawPayload: Data) {
        self.keyId = keyId
        self.action = action
        self.rawPayload = rawPayload
    }

    /// Parsuje key event z payloadu type 67: [0]=0x05 [1]=01/02 [5]=keyId.
    /// Zwraca nil jeśli to nie jest key event (np. prawdziwe VehicleInfo).
    static func fromType67(_ payload: Data) -> SoftkeyEvent? {
        let b = payload.startIndex
        guard payload.count >= 6, payload[b] == 0x05 else { return nil }
        let action = payload[b+1]          // 1=down, 2=up
        let keyId  = payload[b+5]
        return SoftkeyEvent(keyId: keyId, action: action, rawPayload: payload)
    }

    var description: String {
        "Key \(keyId) \(isPressed ? "WCIŚNIĘTY" : "PUSZCZONY") | hex: \(rawPayload.hex)"
    }
}

// MARK: — Parsowanie PositionInformation (type 27) — GPS i dane pojazdu

struct VehicleData {
    // Dane odczytywane z motocykla — klucze oparte na protokole mySPIN
    var speedKmh:     Double?
    var rpm:          Double?
    var gear:         Int?
    var fuelLevel:    Double?
    var rawPayload:   Data
}

// MARK: — Pomocnicze

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
