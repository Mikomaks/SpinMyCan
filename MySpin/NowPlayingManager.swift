// NowPlayingManager.swift
// Odczyt "Now Playing" z systemu: Spotify, Apple Music, Tidal, itd.
//
// iOS 17: MRMediaRemoteGetNowPlayingInfo działa TYLKO po:
//   1. MRMediaRemoteRegisterForNowPlayingNotifications(queue) — inicjalizuje pipeline danych
//   2. beginReceivingRemoteControlEvents() — rejestruje jako remote control receiver
//   3. AVAudioSession .ambient — aktywuje sesję audio
// Bez kroku 1 callback zawsze zwraca pusty słownik (iOS 17 zmienił to zachowanie).

import UIKit
import Combine
import MediaPlayer
import AVFoundation
import Darwin

// MARK: — Sygnatury MediaRemote (private framework)

private typealias MRGetNowPlayingInfoFn   = @convention(c) (DispatchQueue, @escaping ([String: Any]?) -> Void) -> Void
private typealias MRRegisterForNotifsFn   = @convention(c) (DispatchQueue) -> Void
private typealias MRUnregisterForNotifsFn = @convention(c) () -> Void

final class NowPlayingManager: ObservableObject {

    // MARK: — Publikowane właściwości

    @Published var title:     String   = ""
    @Published var artist:    String   = ""
    @Published var artwork:   UIImage? = nil
    @Published var elapsed:   Double   = 0
    @Published var duration:  Double   = 0
    @Published var isPlaying: Bool     = false
    @Published var debugInfo: String   = "—"

    // MARK: — Prywatne

    private var pollTimer:     DispatchSourceTimer?
    private var observers:     [NSObjectProtocol] = []
    private var storedElapsed: Double = 0
    private var lastFetchTime: Date   = Date()

    private var mrGetInfo:    MRGetNowPlayingInfoFn?
    private var mrRegister:   MRRegisterForNotifsFn?
    private var mrUnregister: MRUnregisterForNotifsFn?

    // MARK: — Init

    init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW)
        else {
            debugInfo = "MR: dlopen failed"
            return
        }
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            mrGetInfo = unsafeBitCast(sym, to: MRGetNowPlayingInfoFn.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            mrRegister = unsafeBitCast(sym, to: MRRegisterForNotifsFn.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteUnregisterForNowPlayingNotifications") {
            mrUnregister = unsafeBitCast(sym, to: MRUnregisterForNotifsFn.self)
        }
    }

    // MARK: — Start / Stop

    func start() {
        // 1. Inicjalizuj pipeline MediaRemote — KLUCZOWE dla iOS 17
        //    Bez tego MRMediaRemoteGetNowPlayingInfo zwraca zawsze pusty słownik.
        mrRegister?(.main)

        // 2. Zarejestruj obserwatorów notyfikacji MR (block-based, bez @objc)
        let nc = NotificationCenter.default
        let names = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        ]
        for name in names {
            let obs = nc.addObserver(
                forName: NSNotification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.fetchMR()
            }
            observers.append(obs)
        }

        // 3. Rejestruj jako remote control receiver (UIKit)
        DispatchQueue.main.async {
            UIApplication.shared.beginReceivingRemoteControlEvents()
        }

        // 4. Aktywuj sesję audio
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)

        // 5. Pierwsze pobranie z małym opóźnieniem (rejestracja musi zdążyć zadziałać)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.fetchMR()
        }

        // 6. Polling fallback co 2s
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 2.0, repeating: 2.0, leeway: .milliseconds(300))
        t.setEventHandler { [weak self] in self?.fetchMR() }
        t.resume()
        pollTimer = t

        debugInfo = "init: MRGet=\(mrGetInfo != nil ? "✓" : "✗") reg=\(mrRegister != nil ? "✓" : "✗")"
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        mrUnregister?()
        let nc = NotificationCenter.default
        observers.forEach { nc.removeObserver($0) }
        observers.removeAll()
    }

    /// Interpolowane elapsed — do płynnego progress bara w render loop
    var currentElapsed: Double {
        guard isPlaying else { return storedElapsed }
        return storedElapsed + Date().timeIntervalSince(lastFetchTime)
    }

    // MARK: — Fetch przez MediaRemote

    private func fetchMR() {
        guard let fn = mrGetInfo else {
            debugInfo = "MR: dlsym=nil → MP fallback"
            fetchViaMP()
            return
        }

        fn(.main) { [weak self] rawInfo in
            guard let self else { return }

            guard let info = rawInfo, !info.isEmpty else {
                // MR zwrócił nil/pusty — nic nie gra lub brak dostępu
                self.debugInfo = "MR: callback=nil → MP fallback"
                self.fetchViaMP()
                return
            }

            // Próbuj oba formaty kluczy (zależy od wersji iOS)
            let mrTitle  = (info["kMRMediaRemoteNowPlayingInfoTitle"]  as? String)
                        ?? (info["Title"]                               as? String) ?? ""
            let mrArtist = (info["kMRMediaRemoteNowPlayingInfoArtist"] as? String)
                        ?? (info["Artist"]                              as? String) ?? ""
            let mrDur    = (info["kMRMediaRemoteNowPlayingInfoDuration"]    as? Double)
                        ?? (info["Duration"]                                as? Double) ?? 0
            let mrElap   = (info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double)
                        ?? (info["ElapsedTime"]                             as? Double) ?? 0
            let mrRate   = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double)
                        ?? (info["PlaybackRate"]                             as? Double) ?? 0

            if mrTitle.isEmpty {
                // Mamy słownik, ale bez tytułu — loguj klucze do diagnozy
                let keys = info.keys.sorted().prefix(6).joined(separator: "|")
                self.debugInfo = "MR: \(info.count) kluczy, brak Title — [\(keys)]"
                self.fetchViaMP()
                return
            }

            // Artwork: kilka możliwych kluczy
            let artData: Data?
                = (info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data)
                ?? (info["ArtworkData"]                            as? Data)
                ?? (info["Artwork"]                                as? Data)

            self.applyInfo(
                title:       mrTitle,
                artist:      mrArtist,
                duration:    mrDur,
                elapsed:     mrElap,
                rate:        mrRate,
                artworkData: artData,
                source:      "MR"
            )
        }
    }

    // MARK: — Fallback: MPNowPlayingInfoCenter

    private func fetchViaMP() {
        let mpInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo

        guard let info = mpInfo,
              let t = info[MPMediaItemPropertyTitle] as? String,
              !t.isEmpty
        else {
            let count = MPNowPlayingInfoCenter.default().nowPlayingInfo?.count ?? -1
            if count < 0 {
                debugInfo = "MR→MP: oba nil (Spotify używa prywatnego API)"
            } else {
                debugInfo = "MP: \(count) kluczy, brak tytułu"
            }
            if !title.isEmpty { clearNowPlaying() }
            return
        }

        var artData: Data? = nil
        if let artItem = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork {
            artData = artItem.image(at: CGSize(width: 300, height: 300))
                             .flatMap { $0.jpegData(compressionQuality: 0.8) }
        }

        applyInfo(
            title:       t,
            artist:      info[MPMediaItemPropertyArtist] as? String ?? "",
            duration:    info[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0,
            elapsed:     info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0,
            rate:        info[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0,
            artworkData: artData,
            source:      "MP"
        )
    }

    // MARK: — Zastosuj dane

    private func applyInfo(title t: String, artist a: String,
                           duration d: Double, elapsed e: Double, rate: Double,
                           artworkData: Data?, source: String) {
        let trackChanged = t != title || a != artist
        title         = t
        artist        = a
        duration      = d
        storedElapsed = e
        lastFetchTime = Date()
        elapsed       = e
        isPlaying     = rate > 0
        debugInfo     = "\(source) ▶︎ \(t.prefix(22))"

        // Artwork: zawsze aktualizuj gdy dane dostępne (fix: ta sama piosenka po pauzie)
        // Jeśli artworkData = nil → zachowaj stare gdy ten sam utwór, wyczyść gdy zmiana
        if let data = artworkData {
            artwork = UIImage(data: data)
        } else if trackChanged {
            artwork = nil
        }
        if t.isEmpty { artwork = nil }
    }

    private func clearNowPlaying() {
        title = ""; artist = ""; artwork = nil
        isPlaying = false; elapsed = 0; duration = 0
    }
}
