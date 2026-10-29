// VideoFrameProvider.swift
// Ekran „Wideo”: playlista filmów odtwarzanych na desce jako gotowe klatki JPEG 864×320.
//   - wbudowany Isle of Man TT (video_tt.mjpg w bundlu, robi go `make video`),
//   - filmy dodane w apce z Galerii albo Plików (VideoImporter → Documents/Videos/*.mjpg).
//
// Dawniej film był dekodowany w telefonie (AVPlayer + CADisplayLink). Oba stają, gdy
// telefon jest zablokowany albo apka jest w tle — a tak się jeździ: na desce był czarny
// ekran albo zatrzymana klatka. Teraz nie ma dekodowania ani GPU: klatka to wycinek
// pliku zmapowanego w pamięci, wybrany według zegara. Działa tak samo w tle.
//
// start()/stop() — ekran wideo wybrany / zostawiony; po powrocie leci dalej od tego miejsca.
// Joystick: pauza, ±10 s, następny film. Przy pauzie i chwilę po każdej komendzie na
// klatkę nakładany jest pasek z czasem (OSD) — tylko wtedy klatka jest przerysowywana.

import Foundation
import Combine
import UIKit

final class VideoFrameProvider: ObservableObject {

    struct Item: Identifiable, Equatable {
        let id: String          // "builtin" albo nazwa pliku w Documents/Videos
        let title: String
        let url: URL
        let builtin: Bool
        let seconds: Double
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var currentID: String = ""
    @Published private(set) var paused = false
    /// Postęp dodawania filmu 0…1 (nil = nic się nie dodaje).
    @Published private(set) var importProgress: Double?
    @Published private(set) var importStatus: String?

    static let builtinID = "builtin"
    static let seekStep: TimeInterval = 10
    private static let osdTime: TimeInterval = 1.8
    private static let currentKey = "videoCurrent"

    private let builtinName: String
    private let lock = NSLock()

    // ── Stan odtwarzania (pod lockiem — currentFrame() woła wątek renderu) ──
    private var playlist: [Item] = []
    private var cur = 0
    private var openedID: String?
    private var file: Data?            // zmapowany plik (nie wczytuje się cały do pamięci)
    private var offsets: [Int] = []    // początki klatek + koniec ostatniej, liczone od początku pliku
    private var fps: Double = 15
    private var active = false         // ekran wideo wybrany
    private var userPaused = false
    private var playStart: TimeInterval?   // zegar systemowy w chwili „pozycja 0”
    private var pausedPos: TimeInterval = 0
    private var osd: (text: String, until: TimeInterval)?
    private var osdCache: (key: String, data: Data)?

    private var importTask: Task<Void, Never>?

    init(builtinName: String = "video_tt") {
        self.builtinName = builtinName
        reloadItems()
    }

    // MARK: — Cykl życia

    func start() {
        lock.lock(); defer { lock.unlock() }
        openIfNeeded()
        active = true
        if !userPaused, playStart == nil { playStart = Self.now - pausedPos }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        freeze()
        active = false
    }

    // MARK: — Sterowanie (joystick i apka)

    func togglePause() {
        lock.lock()
        userPaused.toggle()
        if userPaused { freeze() } else if active { playStart = Self.now - pausedPos }
        if !userPaused { showOSD("▶ " + timeLabel()) }
        let p = userPaused
        lock.unlock()
        publish { $0.paused = p }
    }

    func seek(by delta: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard file != nil else { return }
        let pos = min(max(0, position() + delta), max(0, duration() - 0.5))
        setPosition(pos)
        showOSD((delta < 0 ? "◀◀ " : "▶▶ ") + timeLabel())
    }

    func next() {
        lock.lock(); defer { lock.unlock() }
        guard !playlist.isEmpty else { return }
        open(index: (cur + 1) % playlist.count)
    }

    func select(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard let i = playlist.firstIndex(where: { $0.id == id }) else { return }
        open(index: i)
    }

    /// Klatka JPEG dla bieżącej chwili; nil, gdy ekran wideo nie gra albo brak pliku.
    /// Wołane z wątku renderu (frameProvider) i z głównego (podgląd).
    func currentFrame() -> Data? {
        lock.lock()
        guard active else { lock.unlock(); return nil }
        openIfNeeded()
        guard file != nil else { lock.unlock(); return nil }
        var idx = Int(position() * fps)
        if idx >= offsets.count - 1 {
            // koniec filmu → następny z playlisty (jeden film = od początku)
            open(index: (cur + 1) % max(1, playlist.count))
            idx = 0
        }
        guard let file, offsets.count > 1 else { lock.unlock(); return nil }
        idx = min(idx, offsets.count - 2)
        let jpeg = file.subdata(in: offsets[idx] ..< offsets[idx + 1])
        var text: String?
        if userPaused { text = "❚❚ " + timeLabel() }
        else if let o = osd, Self.now < o.until { text = o.text }
        let progress = position() / max(1, duration())
        let key = "\(cur)/\(idx)/\(text ?? "")"
        let cached = osdCache?.key == key ? osdCache?.data : nil
        lock.unlock()

        guard let text else { return jpeg }
        if let cached { return cached }
        let out = Self.compose(jpeg, text: text, progress: progress) ?? jpeg
        lock.lock(); osdCache = (key, out); lock.unlock()
        return out
    }

    // MARK: — Playlista (pliki)

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Videos", isDirectory: true)
    }

    /// Przelicza listę filmów z dysku (po dodaniu / usunięciu).
    func reloadItems() {
        var list: [Item] = []
        if let url = Bundle.main.url(forResource: builtinName, withExtension: "mjpg"),
           let s = Self.seconds(url) {
            list.append(Item(id: Self.builtinID, title: "Isle of Man TT", url: url, builtin: true, seconds: s))
        }
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let dated = files.filter { $0.pathExtension == "mjpg" }.map { url in
            (url, (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }) {
            guard let s = Self.seconds(url) else { continue }
            list.append(Item(id: url.lastPathComponent, title: url.deletingPathExtension().lastPathComponent,
                             url: url, builtin: false, seconds: s))
        }
        lock.lock()
        let curID = openedID ?? UserDefaults.standard.string(forKey: Self.currentKey) ?? Self.builtinID
        playlist = list
        if let i = list.firstIndex(where: { $0.id == curID }) {
            cur = i
        } else {
            cur = 0
            if openedID != nil { open(index: 0) }   // grany film usunięty
        }
        let shownID = list.isEmpty ? "" : list[cur].id
        lock.unlock()
        publish { $0.items = list; $0.currentID = shownID }
    }

    func delete(_ id: String) {
        guard let item = items.first(where: { $0.id == id }), !item.builtin else { return }
        lock.lock()
        if openedID == id { file = nil; offsets = []; openedID = nil }
        lock.unlock()
        try? FileManager.default.removeItem(at: item.url)
        reloadItems()
    }

    /// Dodaje film: przerabia go w telefonie na klatki deski (VideoImporter).
    /// `src` to kopia tymczasowa — usuwana po przeróbce.
    func importVideo(from src: URL, title: String) {
        guard importTask == nil else { return }
        publish { $0.importProgress = 0; $0.importStatus = String(localized: "Przerabiam „\(title)”…") }
        let bg = UIApplication.shared.beginBackgroundTask(withName: "video-import")
        importTask = Task.detached(priority: .userInitiated) { [weak self] in
            let dst = Self.uniqueURL(for: title)
            var last = -1.0
            do {
                let n = try await VideoImporter.convert(src, to: dst) { p in
                    guard p - last >= 0.01 else { return }
                    last = p
                    self?.publish { $0.importProgress = p }
                }
                let t = String(format: "%d:%02d", n / 15 / 60, n / 15 % 60)
                self?.publish { $0.importStatus = String(localized: "Dodano „\(title)” (\(t))") }
            } catch {
                try? FileManager.default.removeItem(at: dst)
                self?.publish { $0.importStatus = String(localized: "Nie udało się: \(error.localizedDescription)") }
            }
            try? FileManager.default.removeItem(at: src)
            await MainActor.run {
                self?.importTask = nil
                self?.importProgress = nil
                self?.reloadItems()
                UIApplication.shared.endBackgroundTask(bg)
            }
        }
    }

    // MARK: — Wewnętrzne (wołać pod lockiem)

    nonisolated private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func position() -> TimeInterval {
        playStart.map { Self.now - $0 } ?? pausedPos
    }

    private func duration() -> TimeInterval {
        Double(max(0, offsets.count - 1)) / fps
    }

    private func freeze() {
        if let s = playStart { pausedPos = Self.now - s }
        playStart = nil
    }

    private func setPosition(_ pos: TimeInterval) {
        pausedPos = pos
        playStart = active && !userPaused ? Self.now - pos : nil
    }

    private func showOSD(_ text: String) {
        osd = (text, Self.now + Self.osdTime)
    }

    private func timeLabel() -> String {
        "\(Self.clock(position())) / \(Self.clock(duration()))"
    }

    nonisolated private static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func openIfNeeded() {
        if file == nil, !playlist.isEmpty { open(index: min(cur, playlist.count - 1)) }
    }

    /// Otwiera film z playlisty od początku i pokazuje jego tytuł.
    private func open(index: Int) {
        guard playlist.indices.contains(index) else { return }
        let item = playlist[index]
        cur = index
        if openedID != item.id {
            guard let (data, offs, rate) = Self.load(item.url) else {
                print("⚠️ VideoFrameProvider: nie da się otworzyć \(item.url.lastPathComponent)")
                return
            }
            file = data; offsets = offs; fps = rate
            openedID = item.id
            osdCache = nil
        }
        setPosition(0)
        if playlist.count > 1 { showOSD("▶ " + item.title) }
        UserDefaults.standard.set(item.id, forKey: Self.currentKey)
        publish { $0.currentID = item.id }
    }

    private func publish(_ change: @escaping (VideoFrameProvider) -> Void) {
        DispatchQueue.main.async { [weak self] in if let self { change(self) } }
    }

    nonisolated private static func uniqueURL(for title: String) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clean = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = clean.isEmpty ? "Film" : String(clean.prefix(60))
        var url = folder.appendingPathComponent(base + ".mjpg")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).mjpg"); n += 1
        }
        return url
    }

    // MARK: — Format pliku

    /// Nagłówek: "MSV1", u16 fps, u16 0, u32 liczba klatek, (liczba+1) × u32 przesunięcia od danych.
    nonisolated private static func load(_ url: URL) -> (Data, [Int], Double)? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
              data.count > 12, data.prefix(4) == Data("MSV1".utf8) else { return nil }
        func u32(_ at: Int) -> Int {
            data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
        }
        let rate = data.withUnsafeBytes { Int(UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self))) }
        let count = u32(8)
        let dataStart = 12 + (count + 1) * 4
        guard count > 0, rate > 0, data.count >= dataStart else { return nil }
        let offs = (0...count).map { dataStart + u32(12 + $0 * 4) }
        guard offs.last! <= data.count else { return nil }
        return (data, offs, Double(rate))
    }

    /// Długość filmu z samego nagłówka (bez mapowania całego pliku).
    nonisolated private static func seconds(_ url: URL) -> Double? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 12), d.count == 12, d.prefix(4) == Data("MSV1".utf8) else { return nil }
        let b = [UInt8](d)
        let rate = Int(b[4]) | Int(b[5]) << 8
        let count = Int(b[8]) | Int(b[9]) << 8 | Int(b[10]) << 16 | Int(b[11]) << 24
        return rate > 0 && count > 0 ? Double(count) / Double(rate) : nil
    }

    // MARK: — Pasek na klatce (OSD)

    nonisolated private static let osdFont = UIFont(name: "Monocraft", size: 27)
        ?? .monospacedSystemFont(ofSize: 27, weight: .bold)

    /// Klatka z paskiem na dole: tekst i postęp filmu. Czcionka 27 (ostra wielokrotność 9).
    nonisolated static func compose(_ jpeg: Data, text: String, progress: Double) -> Data? {
        guard let img = UIImage(data: jpeg) else { return nil }
        let size = CGSize(width: 864, height: 320)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).jpegData(withCompressionQuality: 0.7) { ctx in
            img.draw(in: CGRect(origin: .zero, size: size))
            UIColor(white: 0, alpha: 0.65).setFill()
            ctx.fill(CGRect(x: 0, y: 262, width: 864, height: 58), blendMode: .normal)
            (text as NSString).draw(at: CGPoint(x: 18, y: 268),
                                    withAttributes: [.font: osdFont, .foregroundColor: UIColor.white])
            UIColor(white: 1, alpha: 0.25).setFill()
            ctx.fill(CGRect(x: 18, y: 306, width: 828, height: 4), blendMode: .normal)
            UIColor(red: 1, green: 0.27, blue: 0.2, alpha: 1).setFill()
            ctx.fill(CGRect(x: 18, y: 306, width: (828 * min(1, max(0, progress))).rounded(), height: 4), blendMode: .normal)
        }
    }
}
