// MySpinSession.swift
// TCP połączenie z motocyklem — protokół binarny mySPIN v1.2.0

import Network
import UIKit
import Combine

// MARK: — Stan TCP

enum TCPState: Equatable {
    case idle
    case connecting
    case handshaking(step: Int)
    case connected
    case failed(String)
    case disconnected

    var label: String {
        switch self {
        case .idle:                   return "TCP: idle"
        case .connecting:             return "TCP: łączę..."
        case .handshaking(let s):     return "TCP: handshake \(s)/7"
        case .connected:              return "TCP: POŁĄCZONY ✓"
        case .failed(let e):          return "TCP błąd: \(e)"
        case .disconnected:           return "TCP: rozłączony"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: — Event od motocykla

enum MySpinEvent {
    case softkeyPressed(SoftkeyEvent)
    case vehicleData(VehicleData)
    case screenRequest
    case rawPacket(type: UInt8, payload: Data)
}

// MARK: — Sesja TCP

final class MySpinSession: ObservableObject {

    @Published var tcpState:   TCPState = .idle {
        didSet { tcpStateChangedAt = Date() }   // do watchdoga zablokowanego handshake'u
    }
    /// Kiedy stan TCP ostatnio się ZMIENIŁ (każdy krok handshake resetuje licznik).
    private(set) var tcpStateChangedAt = Date()
    var displaySize = CGSize(width: 864, height: 320)
    // packets — NIE @Published (powodowało re-rendery na każdy log).
    // UI czyta przez timer/refresh. Ring buffer 200 wpisów wystarczy do diagnostyki.
    var packets: [RawPacketEntry] = []
    /// Notyfikacja dla UI — wywoływana raz na 1s zamiast per-append (throttling)
    @Published var packetsRevision: Int = 0
    private var pendingPacketNotify = false

    var onEvent: ((MySpinEvent) -> Void)?
    var frameProvider: (() -> Data?)?
    /// Callback wywoływany przy evencie joysticka — pełny event (keyId, action, raw hex).
    var onSoftkeyPressed: ((SoftkeyEvent) -> Void)?
    /// Diagnostyka: każdy nieznany/nieobsłużony pakiet runtime (keyId niemożliwy — typ + hex).
    /// Używane w Fazie 1 mapowania joysticka żeby złapać eventy o nieoczekiwanym typie.
    var onUnknownPacket: ((UInt8, String) -> Void)?
    /// Callback gdy motocykl zmienia tryb noc/dzień (IS_NIGHT channel 0x00000003)
    var onIsNightChanged: ((Bool) -> Void)?
    /// Store telemetrii — aktualizowany bezpośrednio z type 55
    /// STRONG ref (nie weak) — TelemetryStore nie trzyma Session, brak cyklu retencji.
    var telemetryStore: TelemetryStore?

    private(set) var screenWidth:  UInt32 = 864
    private(set) var screenHeight: UInt32 = 320

    private var connection:    NWConnection?
    private let queue = DispatchQueue(label: "com.myspin.tcp", qos: .userInitiated)
    /// Kolejka renderowania JPEG — poza main thread (20ms/klatka przy 864×320)
    private let renderQueue = DispatchQueue(label: "com.myspin.render", qos: .userInitiated)
    private var receiveBuffer  = Data()
    private var frameTimer:    Timer?

    /// Callback z RTT (s) każdej wysłanej klatki → do adaptive JPEG quality w ContentView
    var onFrameRTT: ((TimeInterval) -> Void)?
    /// Każdy wpis logu połączenia (łączenie, rozłączenie, błędy) — do dziennika łącza.
    var onLog: ((String) -> Void)?

    // MARK: — Połącz / Rozłącz

    func connect(host: String = "192.168.10.2", port: UInt16 = 7195) {
        switch tcpState {
        case .idle, .disconnected, .failed: break
        default: return
        }

        sessionStartTime = Date()
        tcpState = .connecting
        logTele("🔌 Łączę z motocyklem \(host):\(port)...")

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            tcpState = .failed("Zły port"); return
        }

        let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)

        // ── KRYTYCZNE: TCP_NODELAY + disable delayed ACK ──
        // Domyślnie NWConnection ma WŁĄCZONY Nagle's algorithm, który:
        //   1) Buforuje małe send'y czekając na ACK poprzedniego pakietu (~200ms)
        //   2) Przy delayed ACK po stronie motocykla (~40ms) → łącznie 200-500ms LAG per klatka
        // To główne źródło "rosnącego o 1s laga" — fragmentowane klatki czekają w kernel buffer.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay                = true   // wyłącz Nagle
        tcpOptions.disableAckStretching   = true   // szybsze ACK z naszej strony
        tcpOptions.connectionTimeout      = 5      // sekundy na połączenie
        tcpOptions.keepaliveIdle          = 10     // szybkie wykrywanie martwego połączenia
        tcpOptions.keepaliveInterval      = 5
        tcpOptions.keepaliveCount         = 2

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.serviceClass = .interactiveVideo    // priorytet QoS w stosie sieciowym

        connection = NWConnection(to: ep, using: params)

        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { self?.handleTCPState(state) }
        }
        // Diagnostyka zrywania połączenia: czy sieć pod spodem zniknęła, zanim padło TCP.
        connection?.viabilityUpdateHandler = { [weak self] ok in
            DispatchQueue.main.async { self?.logTele(ok ? "sieć pod TCP: działa" : "⚠️ sieć pod TCP: nie przenosi danych") }
        }
        connection?.pathUpdateHandler = { [weak self] path in
            let ifs = path.availableInterfaces.map { $0.name }.joined(separator: "+")
            DispatchQueue.main.async { self?.logTele("ścieżka TCP: \(path.status) przez \(ifs.isEmpty ? "nic" : ifs)") }
        }
        connection?.start(queue: queue)
    }

    func clearPackets() {
        DispatchQueue.main.async { self.packets.removeAll() }
    }

    func disconnect() {
        // Guard: jeśli już rozłączeni — nic nie rób (zapobiega double-disconnect chaos)
        guard connection != nil else { return }

        frameTimer?.invalidate();       frameTimer       = nil
        frameSourceTimer?.cancel();     frameSourceTimer = nil
        resubTimer?.invalidate();       resubTimer       = nil
        isSendingFrame  = false   // krytyczne: renderQueue może trzymać klatkę w locie
        frameTickCounter = 0
        rttSamples.removeAll()
        frameSkipFactor = 1
        connection?.cancel();           connection  = nil
        receiveBuffer = Data()
        appListSent   = false
        screenRequestsSinceLastTimer = 0
        DispatchQueue.main.async { self.tcpState = .disconnected; self.lastSentFrame = nil }
        logTele("🔌 Rozłączono od motocykla (sesja \(String(format: "%.1f", Date().timeIntervalSince(sessionStartTime)))s)")
    }

    // MARK: — Watchdog zablokowanego połączenia

    /// Handshake nie ma własnego timeoutu: gdy motocykl nie odpowie (np. zrywa
    /// poprzednią sesję), stan zostaje w `.handshaking(step: 1)` NA ZAWSZE — a ani
    /// `connect()`, ani auto-reconnect nie ponawiają, bo oba wznawiają tylko z
    /// idle/disconnected/failed. Efekt: „TCP stuck na 1/7" po paru rozłączeniach.
    /// Ten watchdog (wołany co 1s z heartbeatu) zrywa martwe połączenie, żeby
    /// auto-reconnect mógł spróbować od nowa. Każdy postęp handshake'u (zmiana
    /// stanu) resetuje licznik, więc wolny-ale-żywy handshake nie jest przerywany.
    func checkStalledConnection(timeout: TimeInterval = 8) {
        switch tcpState {
        case .connecting, .handshaking:
            guard Date().timeIntervalSince(tcpStateChangedAt) > timeout else { return }
            logTele("⚠️ Połączenie utknęło na \(tcpState.label) — zrywam i próbuję od nowa")
            if connection != nil {
                disconnect()
            } else {
                // disconnect() ma guard na connection != nil — bez tego stan zostałby zawieszony.
                tcpState = .disconnected
            }
        default:
            break
        }
    }

    // MARK: — Re-subskrypcja danych (publiczna — przycisk "Resub" w UI)

    func resubscribeData() {
        guard tcpState.isConnected else { return }
        sendActivationSequence()
    }

    // MARK: — Stan TCP

    private func handleTCPState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            // TCP ready — handshake odbywa się cicho, zalogujemy dopiero sukces
            tcpState = .handshaking(step: 1)
            receiveBuffer = Data()
            startReceiving()

        case .failed(let err):
            logTele("❌ TCP failed: \(err.localizedDescription)")
            tcpState = .failed(err.localizedDescription)

        case .cancelled:
            tcpState = .disconnected

        case .waiting(let err):
            logTele("⏳ TCP czeka na sieć: \(err.localizedDescription)")

        default: break
        }
    }

    // MARK: — Receive (bufor)

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                DispatchQueue.main.async {
                    self.logTele("❌ Recv error: \(error.localizedDescription)")
                    self.tcpState = .disconnected
                }
                return
            }

            if let data, !data.isEmpty {
                DispatchQueue.main.async {
                    self.receiveBuffer.append(data)
                    self.processBuffer()
                }
            }

            if isComplete {
                // Motocykl zamknął połączenie — odpowiedz FIN żeby uniknąć CLOSE_WAIT
                DispatchQueue.main.async {
                    self.logTele("🔚 Motocykl zamknął połączenie TCP")
                    self.disconnect()
                }
                return
            }

            self.startReceiving()
        }
    }

    // MARK: — Parse pakietów

    private func processBuffer() {
        while receiveBuffer.count >= 9 {
            let payLen = Int(receiveBuffer.readLE32(at: 5))
            guard receiveBuffer.count >= 9 + payLen else { return }

            let base    = receiveBuffer.startIndex
            let ptype   = receiveBuffer[base]
            let payload = receiveBuffer.subdata(in: base + 9 ..< base + 9 + payLen)
            receiveBuffer.removeFirst(9 + payLen)

            // Logowanie jest ZEWNĘTRZNIE — dispatch() loguje tylko pakiety telemetryczne.
            // Żadnych generycznych "← type=26" śmieci, to jest log TELEMETRII.
            dispatch(ptype: ptype, payload: payload)
        }
    }

    // MARK: — Dispatch

    private func dispatch(ptype: UInt8, payload: Data) {
        if case .connected = tcpState {
            handleRuntime(ptype: ptype, payload: payload)
        } else {
            handleHandshake(ptype: ptype, payload: payload)
        }
    }

    // MARK: — Handshake (7 kroków)

    private func handleHandshake(ptype: UInt8, payload: Data) {
        print("[HANDSHAKE] type=\(ptype) len=\(payload.count) state=\(tcpState.label)")
        switch ptype {
        case 1:   // ClientProtocolVersion
            tcpState = .handshaking(step: 2)
            sendRaw(MySpinPacketBuilder.serverProtocolAck())
            tcpState = .handshaking(step: 3)

        case 11:  // ClientInit
            parseClientInit(payload)
            tcpState = .handshaking(step: 4)
            sendRaw(MySpinPacketBuilder.serverInitAck())
            tcpState = .handshaking(step: 5)
            sendRaw(MySpinPacketBuilder.serverInit())
            tcpState = .handshaking(step: 6)
            sendRaw(MySpinPacketBuilder.serverInitDone())
            tcpState = .handshaking(step: 7)

        case 17:  // ClientInitDone
            let elapsed = Date().timeIntervalSince(sessionStartTime)
            logTele("✅ Połączono z motocyklem (\(String(format: "%.1f", elapsed))s) — \(Int(screenWidth))×\(Int(screenHeight))")
            tcpState = .connected
            DispatchQueue.main.async { [weak self] in
                self?.startFrameTimer()
                // NIE startujemy resubTimer automatycznie — data subscription wysyłamy
                // tylko raz w odpowiedzi na type 67. Zbyt częsty resub resetuje dane do 0.
            }

        case 58:  // ClientSettings — ignoruj cicho
            break

        case 61:  // VoiceSupportInfo — ignoruj cicho
            break

        case 69:  // ClientSettings2 (język) — może być triggerem init dla firmware v2
            if case .handshaking(let step) = tcpState, step < 4 {
                sendServerInitSequence()
            }
            // inaczej: ignoruj cicho

        default:
            // Nieznany pakiet w handshake — to może być coś ważnego, zaloguj
            logTele("⚠️ Nieznany pakiet w handshake: type=\(ptype) (\(payload.count)B) \(payload.prefix(8).hex)")
        }
    }

    // Wysyła ServerInitAck + ServerInit + ServerInitDone
    // Używane gdy typ 69 zastępuje typ 11 (protokół v2)
    private func sendServerInitSequence() {
        tcpState = .handshaking(step: 4)
        sendRaw(MySpinPacketBuilder.serverInitAck())
        tcpState = .handshaking(step: 5)
        sendRaw(MySpinPacketBuilder.serverInit())
        tcpState = .handshaking(step: 6)
        sendRaw(MySpinPacketBuilder.serverInitDone())
        tcpState = .handshaking(step: 7)
    }

    private func parseClientInit(_ data: Data) {
        // ClientInit format: 01 + 2B-LE-len + name + capabilities
        // Offset 14 (po "MySpin Host"): 2-byte LE width + 2-byte LE height
        // Zaobserwowane w pcapng: 0x0360=864, 0x0140=320
        guard data.count >= 18 else { return }
        let base = data.startIndex

        // Próba 1: 2-byte LE pair na offset 14 (po name "MySpin Host")
        if let nameLen = data.count > 2 ? Optional(Int(data[base+1]) | Int(data[base+2]) << 8) : nil {
            let wOff = 3 + nameLen
            if wOff + 4 <= data.count {
                let w = UInt32(data[base + wOff]) | UInt32(data[base + wOff + 1]) << 8
                let h = UInt32(data[base + wOff + 2]) | UInt32(data[base + wOff + 3]) << 8
                if (320...1920).contains(w) && (200...1080).contains(h) && w >= h {
                    screenWidth  = w
                    screenHeight = h
                    displaySize  = CGSize(width: CGFloat(w), height: CGFloat(h))
                    return
                }
            }
        }
        // Fallback: 864×320 (protokołowa rozdzielczość Suzuki TFT z pcapng)
    }

    // MARK: — Runtime

    private var appListSent       = false   // wysyłamy type 70 tylko raz
    private var lastActivationAt: Date = .distantPast  // rate-limit dla sendActivationSequence
    // Liczniki — celowo NIE @Published, żeby nie wywoływać re-renderów SwiftUI co klatkę
    var framesSent   = 0
    var framesDropped = 0
    /// Ostatnia klatka JPEG FAKTYCZNIE wysłana na wyświetlacz — podgląd w apce
    /// pokazuje dokładnie to, co widzi motocykl (zero rozjazdu render↔ekran).
    private(set) var lastSentFrame: Data?
    var type55Count  = 0
    var pingCount    = 0
    var resubCount   = 0

    /// Blokada: tylko jedna klatka w locie jednocześnie — zapobiega kolejkowaniu
    private var isSendingFrame = false
    /// Kiedy zaczęliśmy wysyłać bieżącą klatkę — do watchdoga stuck-connection
    private var frameSendStart: Date = .distantPast
    private var resubTimer: Timer?     // zarezerwowane (nie używane aktywnie)

    /// Adaptive frame skipping — gdy RTT rośnie, opuszczamy klatki żeby zmniejszyć kolejkę
    /// 1 = wysyłaj wszystkie, 2 = co drugą, 3 = co trzecią. Ustawiane z onFrameRTT.
    var frameSkipFactor: Int = 1
    private var frameTickCounter: Int = 0
    /// Statystyki RTT — średnia z ostatnich 10 klatek
    private var rttSamples: [TimeInterval] = []
    /// Rolling window: ile klatek motocykl PYTAŁ od ostatniego sendCurrentFrame przez timer
    private var screenRequestsSinceLastTimer: Int = 0

    private func handleRuntime(ptype: UInt8, payload: Data) {
        // DIAGNOSTYKA — print tylko nieznanych/ważnych pakietów.
        // Filtrujemy: 129=ping, 26=frameEcho, 55=dataUpdate, 25=screenRequest (bardzo częsty)
        if ptype != 129 && ptype != 26 && ptype != 55 && ptype != 25 {
            print("[RX] type=\(ptype) len=\(payload.count) hex=\(payload.prefix(12).hex)")
        }
        switch ptype {

        case 67:
            // Type 67 jest PRZECIĄŻONY (odkryte z pcapng prawdziwego mySPIN):
            //   • payload[0]==0x05 → EVENT JOYSTICKA (keyId na offset 5, down/up na offset 1)
            //   • inaczej          → VehicleInfo (motocykl się przedstawia)
            if let ev = SoftkeyEvent.fromType67(payload) {
                print("[JOY67] \(payload.hex) → keyId=\(ev.keyId) action=\(ev.action) pressed=\(ev.isPressed)")
                logTele("🕹 Joystick: keyId=\(ev.keyId) \(ev.isPressed ? "↓ down" : "↑ up") | hex: \(payload.hex)")
                onSoftkeyPressed?(ev)
                onEvent?(.softkeyPressed(ev))
            } else if !appListSent {
                appListSent = true
                sendRaw(MySpinPacketBuilder.appList())
                // Fallback: jeśli po 2s nie dostaniemy potwierdzenia, wysyłamy DataSub ręcznie
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, self.tcpState.isConnected else { return }
                    if self.telemetryStore?.rawChannels.isEmpty ?? true {
                        self.sendActivationSequence()
                    }
                }
            } else {
                sendActivationSequence()
            }

        case 31:
            // SoftkeyEvent — przycisk joysticka. Logujemy do in-app logu (diagnostyka na telefonie).
            let ev = SoftkeyEvent(rawPayload: payload)
            print("[TYPE31] \(payload.count)B: \(payload.hex) → keyId=\(ev.keyId) action=\(ev.action) pressed=\(ev.isPressed)")
            logTele("🕹 Joystick: keyId=\(ev.keyId) action=\(ev.action) \(ev.isPressed ? "↓" : "↑") | hex: \(payload.hex)")
            onSoftkeyPressed?(ev)
            onEvent?(.softkeyPressed(ev))

        case 25:   // ScreenRequest — motocykl prosi o klatkę (event-driven, najlepsza ścieżka)
            screenRequestsSinceLastTimer += 1
            onEvent?(.screenRequest)
            sendCurrentFrame()

        case 27:   // PositionInformation / VehicleData (binary)
            let vd = VehicleData(rawPayload: payload)
            onEvent?(.vehicleData(vd))

        case 55:   // DataUpdate — JSON z wartością kanału danych (NAJWAŻNIEJSZE!)
            type55Count += 1
            handleDataUpdate(payload)

        case 129:  // Ping od motocykla — cicho, tylko odpowiedź
            pingCount += 1
            if payload.count >= 4 {
                let counter = payload.readLE32(at: 0)
                sendRaw(MySpinPacketBuilder.pingResponse(counter: counter))
            }

        case 35:   // PacketClientState (IS_MOVING / IS_NIGHT / audio state) — cicho
            break

        case 26:   // FramebufferUpdate echo — cicho
            break

        default:
            // Diagnostyka joysticka: loguj nieznany typ do in-app logu (throttle 1/typ/2s).
            let now = Date()
            if now.timeIntervalSince(lastUnknownLogAt[ptype] ?? .distantPast) > 2.0 {
                lastUnknownLogAt[ptype] = now
                logTele("❓ Nieznany pakiet runtime: type=\(ptype) (\(payload.count)B) hex: \(payload.prefix(16).hex)")
                onUnknownPacket?(ptype, payload.prefix(16).hex)
            }
            onEvent?(.rawPacket(type: ptype, payload: payload))
        }
    }
    /// Throttle dla logowania nieznanych pakietów (typ → ostatni czas logu)
    private var lastUnknownLogAt: [UInt8: Date] = [:]

    /// Wysyła ScreenActivation + DataSubscription.
    /// Rate-limit: max raz na 5s — zapobiega zapychaniu kolejki gdy motocykl wysyła type-67 często.
    private func sendActivationSequence() {
        let now = Date()
        guard now.timeIntervalSince(lastActivationAt) >= 5.0 else { return }
        lastActivationAt = now
        sendRaw(MySpinPacketBuilder.screenActivation(on: true))
        sendRaw(MySpinPacketBuilder.dataSubscription())
        resubCount += 1
    }

    /// Czytelna nazwa kanału telemetrii do wyświetlenia w logu
    private func telemetryChannelName(_ id: UInt32) -> String {
        switch id {
        case 0x9FCB4386: return "RPM"
        case 0x833F41EB: return "Speed"          // DISPLAY_VEHICLE_SPEED
        case 0xE343911B: return "Fuel%"
        case 0x02EDB78E: return "Gear"
        case 0x318E5203: return "RideMode"        // TRANSFER_SHIFT_INDICATION
        case 0x32DA65B1: return "Temp°C"
        case 0xDE74F274: return "Pitch°"          // PITCH_ANGLE
        case 0xEE3DD907: return "Throttle%"       // PEDAL_POSITION
        case 0x90F66D09: return "YawRate"         // YAW_RATE
        case 0xC8CC087B: return "EngineOn"        // RUNNING_STANDBY
        case 0x00000002: return "IsMoving"        // IS_MOVING
        case 0x00000003: return "IsNight"         // IS_NIGHT
        case 0xB45CEC94: return "DistToEmpty"     // DISTANCE_TO_EMPTY
        case 0x7D22F7FE: return "SpeedAccurate"
        case 0x2821BD75: return "LowFuel"
        case 0x271F516C: return "Mileage"
        case 0xDC55FE4A: return "RPM_acc"
        case 0x42CF35C6: return "RollAngle"
        case 0xEDCE10E1: return "VehicleID"
        case 0x3FEBE1C1: return "LateralAccel"
        case 0x6D982AAC: return "SteeringAngle"
        case 0x0BC7DF81: return "ParkBrake"
        case 0x0267A2BB: return "Unk_0267"
        case 0x0F6F3287: return "Unk_0F6F"
        default:         return String(format: "0x%08X", id)
        }
    }

    // MARK: — DataUpdate (type 55) — szybki bypass (ECU zablokowane)

    private var sessionStartTime: Date = Date()

    private func handleDataUpdate(_ payload: Data) {
        guard payload.count >= 5 else { return }
        let channelId = payload.readLE32(at: 0)

        // PATENT 100%: parsujemy JSON KAŻDEGO kanału (4B channelId + JSON).
        // Jeśli ma "value" → realna telemetria. Jeśli tylko "status" → zapisujemy status
        // (np. "not supported" / "no_auth" / "error") — żeby DOKŁADNIE wiedzieć co moto wysyła.
        let jsonSlice = payload.subdata(in: 4 ..< payload.count)
        guard let json = try? JSONSerialization.jsonObject(with: jsonSlice) as? [String: Any] else {
            return
        }

        if let val = json["value"] {
            let wasNight = telemetryStore?.isNight ?? false
            telemetryStore?.update(channelId: channelId, value: val)
            // Auto night mode — tylko na realną zmianę
            if channelId == 0x00000003 {
                let isNight = telemetryStore?.isNight ?? false
                if isNight != wasNight { onIsNightChanged?(isNight) }
            }
        } else {
            // Brak "value" — zapisz realny status zwrócony przez motocykl
            let status = (json["status"] as? String)
                      ?? (json["error"]  as? String)
                      ?? "no_value"
            telemetryStore?.markUnsupported(channelId: channelId, status: status)
        }
    }

    // Flush statystyk: gdy mamy 80 kanałów lub po 2s od pierwszego pakietu w cyklu
    // MARK: — Klatki

    private var frameSourceTimer: DispatchSourceTimer?

    // DispatchSourceTimer działa w tle (działa gdy app jest zminimalizowana).
    // Strategia: wysyłka klatki jest EVENT-DRIVEN przez type 25 (ScreenRequest) —
    // motocykl prosi o następną, gdy jest gotów (w jazdach 8–20 na sekundę, nigdy więcej).
    // Ten timer to tylko SAFETY-NET — uruchamia klatkę gdy motocykl nie zapytał
    // przez >100ms (np. po nawigacji w menu). 10Hz zamiast 15Hz — mniej spam'u.
    // Ekran wideo idzie tą samą drogą. Dawny tryb „30 fps na siłę” pchał klatki szybciej,
    // niż wyświetlacz je brał — kolejka w TCP rosła i obraz się opóźniał.
    private let frameTimerHz: Double = 10

    private func startFrameTimer() {
        frameTimer?.invalidate(); frameTimer = nil
        frameSourceTimer?.cancel(); frameSourceTimer = nil

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.1,
                   repeating: 1.0 / frameTimerHz,
                   leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // Motocykl sam prosił o klatki — timer nie jest potrzebny
            if self.screenRequestsSinceLastTimer > 0 {
                self.screenRequestsSinceLastTimer = 0
                return
            }
            self.screenRequestsSinceLastTimer = 0
            self.sendCurrentFrame()
        }
        t.resume()
        frameSourceTimer = t
    }

    // Zawsze wywoływane na głównym wątku (przez DispatchSourceTimer na .main)
    private func sendCurrentFrame() {
        guard tcpState.isConnected else { return }

        // Adaptive frame skipping — gdy RTT > 200ms, pomijamy co drugą/trzecią klatkę,
        // żeby kernel TCP send buffer nie rósł szybciej niż WiFi nadąża wysyłać.
        frameTickCounter &+= 1
        if frameSkipFactor > 1 && (frameTickCounter % frameSkipFactor) != 0 {
            framesDropped += 1
            return
        }

        if isSendingFrame {
            // Watchdog 2s: jeśli contentProcessed nie przyszło → rozłącz
            // (może się zdarzyć gdy WiFi odpada w trakcie wysyłki klatki)
            if Date().timeIntervalSince(frameSendStart) > 1.5 {
                logTele("⚠️ TCP stuck >1.5s — rozłączam")
                disconnect()   // isSendingFrame = false wewnątrz disconnect()
            } else {
                framesDropped += 1
            }
            return
        }

        isSendingFrame = true
        frameSendStart = Date()

        // Snapshot danych lokalnie (main thread) — bezpieczne odczytanie @Published vars
        let provider  = frameProvider
        let sw = screenWidth
        let sh = screenHeight
        let sendStart = Date()

        // Render JPEG na renderQueue — zwalnia main thread z 15-25ms pracy co klatkę
        renderQueue.async { [weak self] in
            guard let self else { return }
            // autoreleasepool: enkodowanie JPEG (CoreGraphics/ImageIO) tworzy dużo
            // autoreleased tymczasów — bez ręcznego drenażu na wątku GCD pamięć rośnie
            // przy ciągłym renderowaniu aż do ubicia przez Jetsam (crash „po jakimś czasie").
            let (jpeg, packet): (Data, Data) = autoreleasepool {
                let j = provider?() ?? Self.makeTestJPEG(width: Int(sw), height: Int(sh))
                return (j, MySpinPacketBuilder.framebufferUpdate(jpeg: j, width: sw, height: sh))
            }
            DispatchQueue.main.async { self.lastSentFrame = jpeg }   // podgląd = realna klatka

            // NWConnection.send jest thread-safe — można wywołać z dowolnego wątku
            self.framesSent += 1
            self.connection?.send(content: packet, completion: .contentProcessed { [weak self] _ in
                let rtt = Date().timeIntervalSince(sendStart)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isSendingFrame = false
                    self.recordRTT(rtt)
                    self.onFrameRTT?(rtt)
                }
            })
        }
    }

    /// Rolling-window średnia RTT + automatyczne dostosowanie frameSkipFactor.
    /// Logika: średnia z 10 klatek; > 250ms → skip×3, > 150ms → skip×2, < 80ms → skip×1.
    /// Hystereza zapobiega oscylacji.
    private func recordRTT(_ rtt: TimeInterval) {
        rttSamples.append(rtt)
        if rttSamples.count > 10 { rttSamples.removeFirst() }
        guard rttSamples.count >= 5 else { return }

        let avg = rttSamples.reduce(0, +) / Double(rttSamples.count)
        let newSkip: Int
        if      avg > 0.250 { newSkip = 3 }
        else if avg > 0.150 { newSkip = 2 }
        else if avg < 0.080 { newSkip = 1 }
        else                { return }   // szara strefa — bez zmian

        if newSkip != frameSkipFactor {
            frameSkipFactor = newSkip
            // Reset window żeby nowy stan miał szansę się ustabilizować
            rttSamples.removeAll(keepingCapacity: true)
        }
    }

    private static func makeTestJPEG(width: Int, height: Int) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let img = renderer.image { ctx in
            // Ciemnoniebieski — widoczny sygnał że frames lecą
            UIColor(red: 0.05, green: 0.10, blue: 0.30, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return img.jpegData(compressionQuality: 0.8) ?? Data()
    }

    private func sendRaw(_ data: Data) {
        // .idempotent = fire-and-forget, brak blokowania NWConnection queue
        connection?.send(content: data, completion: .idempotent)
    }

    // MARK: — Log telemetrii

    /// Jedyna metoda logowania — wszystkie wpisy w logu są teraz telemetryczne.
    /// Emoji na początku wskazują typ:
    ///   🔌 TCP connect/disconnect      ✅ Handshake OK
    ///   🏍  VehicleInfo                 📤 Wysłano DataSubscription
    ///   🟢 Niezerowa wartość           🔄 Zmiana wartości
    ///   📊 Batch summary DataUpdate    ⟳ Re-subscribe
    ///   🔘 Przycisk                    ❌ Błąd
    ///   ⚠️ Uwaga / nieznany pakiet
    private func logTele(_ text: String) {
        // Print do konsoli — widoczne w `log stream`, zerowy koszt SwiftUI
        print("[MySpin] \(text)")
        onLog?(text)
        let entry = RawPacketEntry(direction: .system, type: 0,
                                   name: text, payloadLen: 0, detail: "")
        let append: () -> Void = {
            self.packets.append(entry)
            if self.packets.count > 200 {
                self.packets.removeFirst(self.packets.count - 200)
            }
            // Throttle SwiftUI notification do 1Hz
            if !self.pendingPacketNotify {
                self.pendingPacketNotify = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.pendingPacketNotify = false
                    self.packetsRevision &+= 1
                }
            }
        }
        if Thread.isMainThread { append() }
        else { DispatchQueue.main.async(execute: append) }
    }
}

// MARK: — RawPacketEntry

struct RawPacketEntry: Identifiable {
    enum Direction { case sent, received, system }
    let id        = UUID()
    let timestamp = Date()
    let direction: Direction
    let type:      UInt8
    let name:      String
    let payloadLen: Int
    let detail:    String

    // Statyczny formatter — pojedyncza instancja zamiast tworzenia nowej na każdy access
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var timeString: String { Self.timeFormatter.string(from: timestamp) }

    var prefix: String {
        switch direction {
        case .sent:     return "→"
        case .received: return "←"
        case .system:   return "·"
        }
    }
}
