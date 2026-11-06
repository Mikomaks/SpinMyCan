// BTManager.swift
// Połączenie z motocyklem przez Bluetooth iAP2
// Protokół: com.bosch.myspin.pairing
// Wiadomości: newline-terminated JSON

import ExternalAccessory
import Foundation
import Combine
import UIKit

// MARK: — Stan BT

enum BTState: Equatable {
    case idle
    case waitingForAccessory
    case sessionOpen
    case handshaking(step: String)
    case wlanState(String)
    case failed(String)
    case disconnected

    var label: String {
        switch self {
        case .idle:                    return "Idle"
        case .waitingForAccessory:     return String(localized: "Czekam na motocykl BT...")
        case .sessionOpen:             return String(localized: "BT: sesja otwarta")
        case .handshaking(let s):      return String(localized: "BT handshake: \(s)")
        case .wlanState(let s):        return String(localized: "WiFi motocykla: \(s)")
        case .failed(let e):           return String(localized: "BT błąd: \(e)")
        case .disconnected:            return String(localized: "BT rozłączony")
        }
    }

    var isActive: Bool {
        switch self {
        case .sessionOpen, .handshaking, .wlanState: return true
        default: return false
        }
    }
}

// MARK: — BTManager

final class BTManager: NSObject, ObservableObject, StreamDelegate {

    static let protocolString = "com.bosch.myspin.pairing"
    /// TEST (test/bt-own-channel): our own channel, the only one declared in Info.plist on this branch.
    static let ownProtocolString = "com.spinmycan.dash"

    @Published var state: BTState = .idle {
        didSet { stateChangedAt = Date() }   // do watchdoga zablokowanego handshake'u
    }
    @Published var receivedMessages: [BTMessage] = []

    /// Kiedy stan BT ostatnio się ZMIENIŁ — każdy krok handshake resetuje licznik.
    private(set) var stateChangedAt = Date()
    /// Ile razy próbowaliśmy odblokować handshake łagodnie (przed twardym reconnectem).
    private var handshakeRetries = 0

    // Wywołane gdy motocykl zgłasza że WiFi jest gotowe
    // Parametry: ssid (jeśli w payloadzie), password (jeśli w payloadzie)
    var onWlanReady: ((_ ssid: String?, _ password: String?) -> Void)?
    /// Zdarzenia połączenia (podłączenie, rozłączenie, błędy strumienia, zmiany stanu WiFi
    /// motocykla) — do dziennika łącza. Wołane z dowolnego wątku.
    var onEvent: ((String) -> Void)?

    private var accessory: EAAccessory?
    private var session:   EASession?
    private var inputBuffer = Data()
    private var outputReady = false
    private var isStarted   = false   // czy user kliknął Start BT

    // MARK: — Start/Stop

    func start() {
        isStarted = true
        EAAccessoryManager.shared().registerForLocalNotifications()

        NotificationCenter.default.addObserver(
            self, selector: #selector(didConnect(_:)),
            name: .EAAccessoryDidConnect, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(didDisconnect(_:)),
            name: .EAAccessoryDidDisconnect, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )

        appendMessage(direction: .system, text: "Szukam podłączonych akcesoriów...")
        DispatchQueue.main.async { self.state = .waitingForAccessory }

        let accessories = EAAccessoryManager.shared().connectedAccessories
        appendMessage(direction: .system, text: "Znalezionych akcesoriów: \(accessories.count)")

        for acc in accessories {
            appendMessage(direction: .system,
                          text: "Akcesorium: \(acc.name) | protokoły: \(acc.protocolStrings.joined(separator: ", "))")
            probeChannels(acc)
            tryOpen(acc)
        }
    }

    func stop() {
        isStarted = false
        closeSession()
        DispatchQueue.main.async { self.state = .disconnected }
    }

    // Gdy apka wraca na pierwszy plan — sprawdź czy strumienie żyją, jeśli nie reconnect
    @objc private func appDidBecomeActive() {
        guard isStarted else { return }
        if case .disconnected = state { reconnect(); return }
        if case .failed      = state { reconnect(); return }
        // Sprawdź czy outputStream nadal otwarty
        if let os = session?.outputStream, os.streamStatus == .open { return }
        appendMessage(direction: .system, text: "Foreground: strumień BT padł — reconnect")
        reconnect()
    }

    private func reconnect() {
        closeSession()
        handshakeRetries = 0
        DispatchQueue.main.async { self.state = .waitingForAccessory }
        let accessories = EAAccessoryManager.shared().connectedAccessories
        appendMessage(direction: .system, text: "Reconnect: akcesoriów \(accessories.count)")
        for acc in accessories { tryOpen(acc) }
    }

    // MARK: — Watchdog zablokowanego handshake'u

    /// Handshake BT nie ma własnego timeoutu na ŻADNYM kroku:
    ///   sessionOpen → detectRequest → [iviDetectResponse] → initRequest
    ///   → [iviInitResponse] → wlanReady → [iviWlanStateNotification] → WiFi
    /// Gdy motocykl nie odpowie (typowo: jeszcze się wybudza albo sprząta po
    /// poprzedniej sesji), stan wisi w nieskończoność — a `isActive` dalej zwraca
    /// true, więc reszta apki myśli „BT działa", podczas gdy WiFi motocykla nigdy
    /// nie wstało. Objaw: „zacina się na handshake i WiFi się nie odpala".
    ///
    /// Drabinka naprawcza (wołane co 1s z heartbeatu):
    ///   1-2 próba → ponów handshake od początku (tanie, sesja/stream żyją)
    ///   3 próba   → pełny reconnect (zamknij sesję, otwórz od nowa)
    /// Każdy postęp (zmiana stanu) resetuje licznik, więc wolny-ale-żywy handshake
    /// nie jest przerywany.
    func checkStalledHandshake(timeout: TimeInterval = 6) {
        guard isStarted else { return }
        let stalledFor = Date().timeIntervalSince(stateChangedAt)

        switch state {
        case .sessionOpen, .handshaking:
            guard stalledFor > timeout else { return }
            if handshakeRetries < 2 && outputReady {
                handshakeRetries += 1
                appendMessage(direction: .system,
                              text: "⚠️ Handshake utknął na \(state.label) (\(Int(stalledFor))s) — ponawiam (\(handshakeRetries)/2)")
                sendPhoneDetectRequest()   // restart handshake od początku
            } else {
                appendMessage(direction: .system,
                              text: "⚠️ Handshake nie odpowiada — pełny reconnect BT")
                reconnect()
            }

        case .wlanState(let s) where s != "READY" && s != "CONNECTED":
            // Motocykl zgłosił WiFi, ale nie w stanie gotowym. Zwykle dośle kolejną
            // notyfikację gdy wstanie — ale jeśli milczy, delikatnie przypominamy
            // (dłuższy timeout, żeby nie przeszkadzać gdy WiFi realnie się podnosi).
            guard stalledFor > 20 else { return }
            appendMessage(direction: .system,
                          text: "⚠️ WiFi motocykla wisi w stanie \(s) — ponawiam phoneWlanState READY")
            sendPhoneWlanReady()

        default:
            break
        }
    }

    // MARK: — Notifications

    @objc private func didConnect(_ n: Notification) {
        guard let acc = n.userInfo?[EAAccessoryKey] as? EAAccessory else { return }
        appendMessage(direction: .system, text: "Podłączono akcesorium: \(acc.name)")
        probeChannels(acc)
        tryOpen(acc)
    }

    @objc private func didDisconnect(_ n: Notification) {
        // Motocykl wyłączony / BT rozłączony.
        // Jeśli user uruchomił BT (isStarted) → zamknij sesję i wróć do oczekiwania.
        // Strumienie wygenerują też .endEncountered → reconnect() za 2s (nieszkodliwe — sprzątnie po raz drugi).
        appendMessage(direction: .system, text: "BT: motocykl odłączony")
        closeSession()
        guard isStarted else {
            DispatchQueue.main.async { self.state = .disconnected }
            return
        }
        appendMessage(direction: .system, text: "Czekam na ponowne podłączenie motocykla...")
        DispatchQueue.main.async { self.state = .waitingForAccessory }
    }

    // MARK: — Channel test (test/bt-own-channel)

    /// Logs everything iOS reports about the accessory and tries to open a session on our own channel.
    private func probeChannels(_ acc: EAAccessory) {
        appendMessage(direction: .system, text: "🧪 TEST kanału: \(acc.manufacturer) / \(acc.modelNumber) / fw \(acc.firmwareRevision) / hw \(acc.hardwareRevision)")
        appendMessage(direction: .system, text: "🧪 Kanały ogłoszone przez motocykl (\(acc.protocolStrings.count)): \(acc.protocolStrings)")
        let declared = Bundle.main.object(forInfoDictionaryKey: "UISupportedExternalAccessoryProtocols") as? [String] ?? []
        appendMessage(direction: .system, text: "🧪 Kanały zadeklarowane w apce: \(declared)")
        if let s = EASession(accessory: acc, forProtocol: Self.ownProtocolString) {
            appendMessage(direction: .system, text: "🧪 ✅ Własny kanał \(Self.ownProtocolString) OTWARTY")
            s.inputStream?.close(); s.outputStream?.close()
        } else {
            appendMessage(direction: .system, text: "🧪 ❌ Własny kanał \(Self.ownProtocolString) — EASession nil")
        }
    }

    // MARK: — Session

    private func tryOpen(_ acc: EAAccessory) {
        guard acc.protocolStrings.contains(Self.protocolString) else {
            appendMessage(direction: .system,
                          text: "⚠ \(acc.name) nie obsługuje \(Self.protocolString)")
            return
        }
        openSession(with: acc)
    }

    private func openSession(with acc: EAAccessory) {
        accessory = acc
        let s = EASession(accessory: acc, forProtocol: Self.protocolString)
        guard let s = s else {
            appendMessage(direction: .system, text: "❌ EASession zwrócił nil!")
            DispatchQueue.main.async { self.state = .failed("EASession nil") }
            return
        }
        session = s

        s.inputStream?.delegate  = self
        s.outputStream?.delegate = self
        s.inputStream?.schedule(in: .main,  forMode: .default)
        s.outputStream?.schedule(in: .main, forMode: .default)
        s.inputStream?.open()
        s.outputStream?.open()

        outputReady = false
        appendMessage(direction: .system, text: "✓ EASession otwarty dla: \(acc.name), czekam na stream ready...")
        DispatchQueue.main.async { self.state = .sessionOpen }
        // NIE wysyłamy tu — czekamy na .hasSpaceAvailable w StreamDelegate
    }

    private func closeSession() {
        session?.inputStream?.close()
        session?.outputStream?.close()
        session?.inputStream?.remove(from: .main, forMode: .default)
        session?.outputStream?.remove(from: .main, forMode: .default)
        session     = nil
        accessory   = nil
        inputBuffer = Data()
        outputReady = false
    }

    // MARK: — Handshake JSON

    private func sendPhoneDetectRequest() {
        let msg: [String: Any] = [
            "version": "3",
            "type":    "phoneDetectRequest",
            "id":      UUID().uuidString
        ]
        send(msg)
        appendMessage(direction: .sent, text: "phoneDetectRequest")
        DispatchQueue.main.async { self.state = .handshaking(step: "detectRequest") }
    }

    private func sendPhoneInitRequest() {
        let region = Locale.current.region?.identifier.lowercased() ?? "en"
        let msg: [String: Any] = [
            "type": "phoneInitRequest",
            "payload": [
                "phoneOS":    "iOS",
                "regionCode": region,
                "version":    3
            ],
            "id": UUID().uuidString
        ]
        send(msg)
        appendMessage(direction: .sent, text: "phoneInitRequest (region: \(region))")
        DispatchQueue.main.async { self.state = .handshaking(step: "initRequest") }
    }

    func sendPhoneTCPConnected() {
        let msg: [String: Any] = [
            "type":    "phoneWlanStateNotification",
            "payload": ["phoneWlanState": "CONNECTED"],
            "id":      UUID().uuidString
        ]
        send(msg)
        appendMessage(direction: .sent, text: "phoneWlanState: CONNECTED (TCP gotowy)")
    }

    private func sendPhoneWlanReady() {
        let msg: [String: Any] = [
            "type":    "phoneWlanStateNotification",
            "payload": ["phoneWlanState": "READY"],
            "id":      UUID().uuidString
        ]
        send(msg)
        appendMessage(direction: .sent, text: "phoneWlanState: READY")
        DispatchQueue.main.async { self.state = .handshaking(step: "wlanReady →") }
    }

    // MARK: — Dispatch wiadomości od motocykla

    private func handleMessage(_ json: [String: Any]) {
        let type    = json["type"]    as? String ?? "unknown"
        let payload = json["payload"] as? [String: Any] ?? [:]

        let pretty = payload.isEmpty ? type : "\(type) \(payload)"
        appendMessage(direction: .received, text: pretty)

        switch type {

        case "iviDetectResponse":
            sendPhoneInitRequest()

        case "iviInitResponse":
            if let version    = payload["version"]    as? Int    { appendMessage(direction: .system, text: "  version: \(version)") }
            if let customer   = payload["customerID"] as? String { appendMessage(direction: .system, text: "  customerID: \(customer)") }
            if let connType   = payload["connectionType"]    as? String { appendMessage(direction: .system, text: "  connectionType: \(connType)") }
            if let authType   = payload["authenticationType"] as? String { appendMessage(direction: .system, text: "  auth: \(authType)") }
            sendPhoneWlanReady()

        case "iviWlanStateNotification":
            let wlanState = payload["iviWlanState"] as? String ?? "?"
            DispatchQueue.main.async { self.state = .wlanState(wlanState) }

            // Loguj payload bez sekretów — log da się wyeksportować przez „Wyślij logi”
            appendMessage(direction: .system, text: "WiFi motocykla: \(wlanState)")
            let secretKeys: Set<String> = ["password", "psk", "passphrase"]
            var redacted = payload
            for k in secretKeys where redacted[k] != nil { redacted[k] = "***" }
            appendMessage(direction: .system, text: "  payload: \(redacted)")

            let ssid     = payload["ssid"]     as? String
            let password = payload["password"] as? String
                        ?? payload["psk"]      as? String
                        ?? payload["passphrase"] as? String
            let band     = payload["frequencyBand"] as? String
                        ?? payload["band"]          as? String

            if let ssid { appendMessage(direction: .system, text: "  SSID: \(ssid)") }
            if let password { appendMessage(direction: .system, text: "  Hasło: \(password.prefix(2))*** (\(password.count) zn.)") }
            if let band { appendMessage(direction: .system, text: "  Band: \(band)") }

            if wlanState == "READY" || wlanState == "CONNECTED" {
                handshakeRetries = 0   // handshake domknięty — zeruj drabinkę watchdoga
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.onWlanReady?(ssid, password)
                }
            }

        default:
            // Logujemy wszystko inne — nieznane wiadomości też są ciekawe
            break
        }
    }

    // MARK: — StreamDelegate

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            appendMessage(direction: .system, text: "Stream openCompleted: \(aStream === session?.outputStream ? "output" : "input")")
            // Output stream otwarty — możemy pisać
            if aStream === session?.outputStream {
                outputReady = true
                appendMessage(direction: .system, text: "Output stream gotowy → startujemy handshake")
                sendPhoneDetectRequest()
            }

        case .hasSpaceAvailable:
            // Pierwsze hasSpaceAvailable = stream gotowy (na wypadek gdyby openCompleted nie przyszedł)
            if !outputReady, aStream === session?.outputStream {
                outputReady = true
                appendMessage(direction: .system, text: "Output stream hasSpace → startujemy handshake")
                sendPhoneDetectRequest()
            }

        case .hasBytesAvailable:
            readBytes()

        case .errorOccurred:
            let err = aStream.streamError?.localizedDescription ?? "?"
            appendMessage(direction: .system, text: "❌ Stream error: \(err) — reconnect za 2s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.isStarted else { return }
                self.reconnect()
            }

        case .endEncountered:
            appendMessage(direction: .system, text: "Stream zakończony — reconnect za 2s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.isStarted else { return }
                self.reconnect()
            }

        default:
            break
        }
    }

    private func readBytes() {
        guard let stream = session?.inputStream else { return }
        var buf = [UInt8](repeating: 0, count: 2048)

        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            guard n > 0 else { break }
            let chunk = Data(buf[0..<n])
            inputBuffer.append(chunk)

            // Dump każdego odebranego chunka — żeby nic nie umknęło
            let hex    = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let ascii  = chunk.map { ($0 >= 32 && $0 < 127) ? String(UnicodeScalar($0)) : "." }.joined()
            appendMessage(direction: .received, text: "RAW[\(n)B] \(ascii)")
            appendMessage(direction: .received, text: "HEX: \(hex)")
        }

        // Parsuj kompletne linie JSON (zakończone \n)
        while let newlineIdx = inputBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = inputBuffer[inputBuffer.startIndex..<newlineIdx]
            inputBuffer.removeSubrange(inputBuffer.startIndex...newlineIdx)
            guard !lineData.isEmpty else { continue }
            if let json = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any] {
                handleMessage(json)
            } else {
                let raw = String(bytes: lineData, encoding: .utf8) ?? lineData.map { String(format: "%02x", $0) }.joined()
                appendMessage(direction: .received, text: "NON-JSON: \(raw)")
            }
        }
    }

    private func send(_ dict: [String: Any]) {
        guard let stream = session?.outputStream else {
            appendMessage(direction: .system, text: "⚠ Próba wysłania bez aktywnego outputStream")
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              var str  = String(data: data, encoding: .utf8) else { return }
        str += "\n"
        let bytes = Array(str.utf8)
        stream.write(bytes, maxLength: bytes.count)
    }

    // MARK: — Log

    func appendMessage(direction: BTMessage.Direction, text: String) {
        if direction == .system { onEvent?(text) }
        let msg = BTMessage(direction: direction, text: text)
        DispatchQueue.main.async {
            self.receivedMessages.append(msg)
            if self.receivedMessages.count > 300 {
                self.receivedMessages.removeFirst(self.receivedMessages.count - 300)
            }
        }
    }
}

// MARK: — BTMessage

struct BTMessage: Identifiable {
    enum Direction { case sent, received, system }
    let id        = UUID()
    let timestamp = Date()
    let direction: Direction
    let text:      String

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: timestamp)
    }

    var prefix: String {
        switch direction {
        case .sent:     return "→"
        case .received: return "←"
        case .system:   return "·"
        }
    }
}
