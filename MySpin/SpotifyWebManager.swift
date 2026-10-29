// SpotifyWebManager.swift
// Spotify Web API — autoryzacja PKCE + polling /v1/me/player co 3s
//
// SETUP (jednorazowo):
//   1. Idź na https://developer.spotify.com/dashboard → utwórz nową aplikację (bezpłatnie)
//   2. Skopiuj Client ID (32-znakowy hex)
//   3. W ustawieniach apki Spotify Developer: dodaj Redirect URI:
//         wassup-myspin://spotify-callback
//   4. W aplikacji: wprowadź Client ID → przycisk "Połącz Spotify"
//
// Brak potrzeby client_secret (flow PKCE), brak SDK, tylko URLSession.

import UIKit
import AuthenticationServices
import CryptoKit
import Security
import Combine

final class SpotifyWebManager: NSObject, ObservableObject {

    // MARK: — Stałe

    private static let kClientID     = "spotify_client_id"
    private static let kAccessToken  = "spotify_access_token"
    private static let kRefreshToken = "spotify_refresh_token"
    private static let kTokenExpiry  = "spotify_token_expiry"
    private static let redirectScheme = "wassup-myspin"
    private static let redirectURI    = "wassup-myspin://spotify-callback"
    private static let scopes = "user-read-playback-state user-read-currently-playing user-modify-playback-state"
    private static let apiBase = "https://api.spotify.com/v1"

    // MARK: — Opublikowane właściwości

    @Published var title:      String   = ""
    @Published var artist:     String   = ""
    @Published var artwork:    UIImage? = nil
    @Published var isPlaying:  Bool     = false
    @Published var elapsed:    Double   = 0
    @Published var duration:   Double   = 0
    @Published var isConnected: Bool    = false
    @Published var statusText:  String  = "Nie połączony"

    /// Interpolowane — do płynnego progress bara
    var currentElapsed: Double {
        guard isPlaying else { return elapsed }
        return elapsed + Date().timeIntervalSince(lastFetchTime)
    }

    // MARK: — Prywatne

    private var lastFetchTime: Date = Date()
    private var pollTimer:     DispatchSourceTimer?
    private var authSession:   ASWebAuthenticationSession?
    private var codeVerifier:  String = ""
    /// Adres okładki BIEŻĄCEGO utworu. Służy też jako znacznik aktualności:
    /// odpowiedź sieciowa dla innego adresu jest odrzucana (utwór już się zmienił).
    private var artworkURL: String = ""
    private var artworkTries = 0
    private var artworkRetry: DispatchWorkItem?
    /// Throttle sterowania — spam guzika (np. wielokrotny rewind) zalewał sieć
    /// wywołaniami; przy jeździe potrafiło to zdławić łącze i wywrócić przesył na deskę.
    private var lastControlAt = Date.distantPast
    private let minControlInterval: TimeInterval = 0.25   // cap ~4 akcje/s

    // MARK: — Trwałe ustawienia (UserDefaults)

    var clientID: String {
        get { UserDefaults.standard.string(forKey: Self.kClientID) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Self.kClientID) }
    }

    // Tokeny w Keychainie — UserDefaults nie są szyfrowane i lecą do backupów
    private var accessToken: String? {
        get { Self.keychainToken(Self.kAccessToken) }
        set { Self.setKeychainToken(newValue, for: Self.kAccessToken) }
    }
    private var refreshToken: String? {
        get { Self.keychainToken(Self.kRefreshToken) }
        set { Self.setKeychainToken(newValue, for: Self.kRefreshToken) }
    }

    private static func keychainQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "spotify",
         kSecAttrAccount as String: key]
    }

    private static func keychainToken(_ key: String) -> String? {
        // Jednorazowa migracja ze starych wersji, które trzymały token w UserDefaults
        if let legacy = UserDefaults.standard.string(forKey: key) {
            setKeychainToken(legacy, for: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        var q = keychainQuery(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func setKeychainToken(_ value: String?, for key: String) {
        let q = keychainQuery(key)
        SecItemDelete(q as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    private var tokenExpiry: Date? {
        get { UserDefaults.standard.object(forKey: Self.kTokenExpiry) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.kTokenExpiry) }
    }

    // MARK: — Auto-connect przy starcie

    /// Próbuje podłączyć się automatycznie jeśli mamy zapisany token.
    func tryAutoConnect() {
        guard !clientID.isEmpty, refreshToken != nil else { return }
        if let expiry = tokenExpiry, Date() < expiry, accessToken != nil {
            isConnected = true
            statusText  = "Spotify ✓ (token ok)"
            startPolling()
        } else {
            // Token wygasł — odśwież
            statusText = "Spotify: odświeżam token..."
            refreshAccessToken { [weak self] success in
                if success {
                    self?.isConnected = true
                    self?.startPolling()
                } else {
                    self?.statusText = "Spotify: token wygasł — zaloguj ponownie"
                }
            }
        }
    }

    // MARK: — OAuth2 PKCE

    func authenticate() {
        guard !clientID.isEmpty else {
            statusText = "⚠️ Wprowadź Client ID z Spotify Developer Dashboard"
            return
        }

        codeVerifier = makeCodeVerifier()
        let challenge = makeCodeChallenge(codeVerifier)

        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id",             value: clientID),
            URLQueryItem(name: "redirect_uri",           value: Self.redirectURI),
            URLQueryItem(name: "response_type",          value: "code"),
            URLQueryItem(name: "scope",                  value: Self.scopes),
            URLQueryItem(name: "code_challenge_method",  value: "S256"),
            URLQueryItem(name: "code_challenge",         value: challenge),
            URLQueryItem(name: "show_dialog",            value: "false"),
        ]
        guard let authURL = comps.url else { return }

        statusText = "Spotify: otwieranie okna logowania..."
        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: Self.redirectScheme
        ) { [weak self] callbackURL, error in
            guard let self else { return }
            if let err = error as? ASWebAuthenticationSessionError,
               err.code == .canceledLogin {
                DispatchQueue.main.async { self.statusText = "Spotify: logowanie anulowane" }
                return
            }
            if let error {
                DispatchQueue.main.async { self.statusText = "Spotify auth: \(error.localizedDescription)" }
                return
            }
            guard let url = callbackURL,
                  let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "code" })?.value
            else {
                DispatchQueue.main.async { self.statusText = "Spotify: brak kodu OAuth" }
                return
            }
            self.exchangeCode(code)
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        authSession?.start()
    }

    func disconnect() {
        stopPolling()
        accessToken  = nil
        refreshToken = nil
        tokenExpiry  = nil
        isConnected  = false
        clearTrack()
        statusText   = "Spotify: rozłączono"
    }

    // MARK: — Token exchange

    private func exchangeCode(_ code: String) {
        guard !clientID.isEmpty else { return }
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(Self.redirectURI)",
            "client_id=\(clientID)",
            "code_verifier=\(codeVerifier)",
        ].joined(separator: "&")
        req.httpBody = body.data(using: .utf8)
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { self.statusText = "Spotify token: \(error.localizedDescription)" }
                return
            }
            self.handleTokenData(data)
        }.resume()
    }

    private func refreshAccessToken(completion: ((Bool) -> Void)? = nil) {
        guard let rt = refreshToken, !clientID.isEmpty else {
            completion?(false); return
        }
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else {
            completion?(false); return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(rt)",
            "client_id=\(clientID)",
        ].joined(separator: "&")
        req.httpBody = body.data(using: .utf8)
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { completion?(false); return }
            let ok = self.handleTokenData(data)
            DispatchQueue.main.async { completion?(ok) }
        }.resume()
    }

    @discardableResult
    private func handleTokenData(_ data: Data?) -> Bool {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = json["access_token"] as? String
        else {
            if let data, let err = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async { self.statusText = "Spotify token err: \(err.prefix(80))" }
            }
            return false
        }

        let expiresIn = json["expires_in"] as? Double ?? 3600
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.accessToken = at
            self.tokenExpiry = Date().addingTimeInterval(expiresIn - 120) // odśwież 2 min przed
            if let rt = json["refresh_token"] as? String { self.refreshToken = rt }
            self.isConnected = true
            self.statusText  = "Spotify ✓"
            self.startPolling()
        }
        return true
    }

    // MARK: — Polling

    func startPolling() {
        pollTimer?.cancel()
        fetchCurrentTrack()   // natychmiastowy fetch przy starcie

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 3.0, repeating: 3.0, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.fetchCurrentTrack() }
        t.resume()
        pollTimer = t
    }

    func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    // MARK: — Fetch /v1/me/player

    private func fetchCurrentTrack() {
        guard let token = accessToken else { return }

        // Profilaktyczne odświeżenie tokenu przed wygaśnięciem
        if let expiry = tokenExpiry, Date() > expiry {
            refreshAccessToken { [weak self] ok in
                if ok { self?.fetchCurrentTrack() }
            }
            return
        }

        guard let url = URL(string: "\(Self.apiBase)/me/player?additional_types=track") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            DispatchQueue.main.async {
                switch status {
                case 200:
                    if let data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.parsePlayerState(json)
                    }
                case 204:
                    if !self.title.isEmpty { self.clearTrack() }
                    self.statusText = "Spotify: nic nie gra"
                case 401:
                    self.accessToken = nil
                    self.refreshAccessToken()
                case 429:
                    self.statusText = "Spotify: rate limit (429)"
                default:
                    if let error {
                        self.statusText = "Spotify err: \(error.localizedDescription.prefix(40))"
                    } else {
                        self.statusText = "Spotify HTTP \(status)"
                    }
                }
            }
        }.resume()
    }

    private func parsePlayerState(_ json: [String: Any]) {
        guard let item = json["item"] as? [String: Any] else {
            clearTrack()
            statusText = "Spotify: brak 'item' w odpowiedzi"
            return
        }

        let newTitle  = item["name"] as? String ?? ""
        let artists   = item["artists"] as? [[String: Any]] ?? []
        let newArtist = artists.map { $0["name"] as? String ?? "" }.joined(separator: ", ")
        let dur       = (item["duration_ms"] as? Double ?? 0)  / 1000.0
        let prog      = (json["progress_ms"] as? Double ?? 0)  / 1000.0
        let playing   = json["is_playing"]   as? Bool   ?? false

        let trackChanged = newTitle != title || newArtist != artist
        title      = newTitle
        artist     = newArtist
        duration   = dur
        elapsed    = prog
        lastFetchTime = Date()
        isPlaying  = playing
        statusText = "Spotify \(playing ? "▶" : "⏸") \(newTitle.prefix(20))"

        // Artwork — pobierz tylko gdy zmienił się utwór
        if trackChanged {
            let albumImages = (item["album"] as? [String: Any])?["images"] as? [[String: Any]] ?? []
            // Spotify zwraca obrazy [640, 300, 64] — wybierz 300px
            let imgURL = albumImages.first(where: { ($0["width"] as? Int ?? 0) <= 350 })?["url"] as? String
                      ?? albumImages.first?["url"] as? String
                      ?? ""
            fetchArtwork(urlString: imgURL)
        } else if artwork == nil, artworkRetry == nil, !artworkURL.isEmpty {
            // Ten sam utwór, okładki wciąż nie ma i nie czeka żadne ponowienie —
            // np. po powrocie z tła, gdzie zaplanowana próba mogła przepaść.
            loadArtwork(artworkURL)
        }
    }

    /// Pobiera okładkę i PONAWIA, dopóki się nie uda albo utwór się nie zmieni.
    ///
    /// Wcześniej próba była dokładnie jedna i to w dodatku nieodwracalnie:
    /// `lastArtworkURL` ustawialiśmy PRZED pobraniem, więc po nieudanej próbie
    /// ten sam adres był na stałe zablokowany warunkiem `urlString != lastArtworkURL`.
    /// A że pobieranie startuje wyłącznie przy zmianie utworu, okładka nie
    /// wracała już nigdy — nawet przy działającym internecie. Teraz adres liczy
    /// się jako „załatwiony" dopiero po sukcesie.
    private func fetchArtwork(urlString: String) {
        artworkRetry?.cancel(); artworkRetry = nil
        artworkURL   = urlString
        artworkTries = 0
        // Nowy utwór = nie zostawiamy okładki poprzedniego. Wcześniej przy
        // nieudanym pobraniu wisiała stara, czyli pokazywaliśmy złą płytę.
        artwork = nil
        loadArtwork(urlString)
    }

    private func loadArtwork(_ urlString: String) {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self, urlString == self.artworkURL else { return }  // utwór się zmienił
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code < 400, let data, let img = UIImage(data: data) {
                    self.artwork = img
                    self.artworkTries = 0
                } else {
                    self.scheduleArtworkRetry(urlString)
                }
            }
        }.resume()
    }

    /// Ponawianie z rosnącym odstępem: 2, 4, 8, 16, 32 s i dalej co 32 s.
    /// Rośnie, żeby nie zasypywać sieci przy dłuższym braku zasięgu, ale nie
    /// poddaje się — okładka dojdzie sama, gdy zasięg wróci.
    private func scheduleArtworkRetry(_ urlString: String) {
        artworkTries += 1
        let delay = min(32.0, pow(2.0, Double(min(artworkTries, 5))))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.artworkRetry = nil
            guard urlString == self.artworkURL, self.artwork == nil else { return }
            self.loadArtwork(urlString)
        }
        artworkRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func clearTrack() {
        artworkRetry?.cancel(); artworkRetry = nil
        artworkURL = ""; artworkTries = 0
        title = ""; artist = ""; artwork = nil
        isPlaying = false; elapsed = 0; duration = 0
    }

    // MARK: — Sterowanie odtwarzaniem (joystick motocykla)

    func nextTrack() {
        playerControl(method: "POST", path: "/me/player/next")
    }

    func previousTrack() {
        playerControl(method: "POST", path: "/me/player/previous")
    }

    /// Przewija bieżący utwór na początek (restart). Używane do "smart previous".
    func seekToStart() {
        playerControl(method: "PUT", path: "/me/player/seek?position_ms=0")
    }

    func togglePlayPause() {
        if isPlaying {
            playerControl(method: "PUT", path: "/me/player/pause")
        } else {
            playerControl(method: "PUT", path: "/me/player/play")
        }
    }

    private func playerControl(method: String, path: String) {
        // Throttle floodu — odrzuć akcje szybsze niż minControlInterval (spam rewind/next).
        // Normalny double-click (>250ms odstępu) przechodzi; tylko spam <200ms jest cięty.
        let now = Date()
        guard now.timeIntervalSince(lastControlAt) >= minControlInterval else { return }
        lastControlAt = now

        guard let token = accessToken,
              let url = URL(string: "\(Self.apiBase)\(path)") else { return }

        // Odśwież token jeśli wygasł
        if let expiry = tokenExpiry, Date() > expiry {
            refreshAccessToken { [weak self] ok in
                if ok { self?.playerControl(method: method, path: path) }
            }
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 4

        URLSession.shared.dataTask(with: req) { [weak self] _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                switch status {
                case 204, 200:
                    // Sukces — po chwili odśwież stan
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self?.fetchCurrentTrack()
                    }
                case 401:
                    self?.refreshAccessToken()
                case 403:
                    // Brakuje scope user-modify-playback-state — wymagane ponowne logowanie
                    self?.statusText = "⚠️ Rozłącz i połącz Spotify ponownie (brak uprawnienia modify)"
                case 404:
                    self?.statusText = "Spotify: brak aktywnego urządzenia"
                default:
                    self?.statusText = "Spotify ctrl: HTTP \(status)"
                }
            }
        }.resume()
    }

    // MARK: — PKCE

    private func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeCodeChallenge(_ verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: — ASWebAuthenticationPresentationContextProviding

extension SpotifyWebManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            ?? UIWindow()
    }
}
