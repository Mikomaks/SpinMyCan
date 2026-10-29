// MemoriesManager.swift
// Ekran „Wspomnienia" — slideshow zdjęć z biblioteki (w tym iCloud Photos).
//
// UWAGA: kuratorowane „Wspomnienia" z apki Zdjęcia (For You) są PRYWATNE —
// nie ma publicznego API. Odtwarzamy je własną kuracją:
//   • „tego dnia" w poprzednich latach (±3 dni od dzisiaj)
//   • ulubione (❤️)
//   • losowe z biblioteki
//
// SPÓJNOŚĆ CZASOWA: zdjęcia NIE są tasowane pojedynczo (to dawało chaos:
// 2024 → 2023 → 2026 → wczoraj). Grupujemy je po DNIU i pokazujemy dzień po dniu —
// jak prawdziwe wspomnienie. Losowa jest tylko kolejność DNI, wewnątrz dnia
// chronologicznie.
//
// MOZAIKA: ekran 864×320 jest bardzo szeroki i niski. Pojedyncze zdjęcie pionowe
// wyglądałoby w nim jak znaczek, więc pakujemy 1-3 zdjęcia z tego samego dnia obok
// siebie (ile się zmieści przy skalowaniu do wysokości). Każde w całości (aspect-FIT),
// nigdy przycięte.
//
// Wątki: PhotoKit callbacki lecą na różnych kolejkach; renderer czyta na wątku
// tła → cały stan pod NSLock, snapshot() bezpieczny cross-thread.

import UIKit
import Photos
import Combine

/// Jeden „kadr" slideshow: 1-3 zdjęcia z tego samego dnia + wspólny podpis.
struct MemorySlide {
    let assets:  [PHAsset]
    let caption: String
}

final class MemoriesManager: NSObject, ObservableObject {

    // MARK: — Stan pod zamkiem (czytany z wątku renderującego)
    private let lock = NSLock()
    private var _current:  [UIImage] = []
    private var _previous: [UIImage] = []
    private var _switchAt: TimeInterval = 0      // czas ostatniej zmiany (dla fade w rendererze)
    private var _caption:  String = ""           // np. „14 sierpnia 2023"
    private var _status:   String = ""           // komunikat gdy brak zdjęć/dostępu

    struct Snapshot {
        let current:  [UIImage]
        let previous: [UIImage]
        let switchAt: TimeInterval
        let caption:  String
        let status:   String
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(current: _current, previous: _previous,
                        switchAt: _switchAt, caption: _caption, status: _status)
    }

    // MARK: — Prywatne
    private var slides: [MemorySlide] = []
    private var index  = 0
    private var cache  = [String: UIImage]()     // localIdentifier → obraz (okno prefetch)
    private var advanceTimer: DispatchSourceTimer?
    private let imgQueue = DispatchQueue(label: "MySpin.memories", qos: .utility)
    private let manager = PHImageManager.default()
    private var isRunning = false
    private let slideSeconds: Double = 7.0        // ile trzyma jeden kadr
    /// Obszar na zdjęcia w klatce 864×320 (reszta to podpis) — musi zgadzać się z rendererem.
    static let photoAreaH: CGFloat = 286
    static let photoAreaW: CGFloat = 864
    private let gap: CGFloat = 6                  // odstęp między zdjęciami w mozaice

    // MARK: — Start / Stop (z ContentView przy wejściu/wyjściu na ekran)

    func start() {
        guard !isRunning else { return }
        isRunning = true
        setStatus(String(localized: "Wspomnienia — ładowanie…"))
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            buildAndBegin()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] st in
                if st == .authorized || st == .limited { self?.buildAndBegin() }
                else { self?.setStatus(String(localized: "Brak dostępu do Zdjęć — włącz w Ustawieniach")) }
            }
        default:
            setStatus(String(localized: "Brak dostępu do Zdjęć — włącz w Ustawieniach"))
        }
    }

    func stop() {
        isRunning = false
        advanceTimer?.cancel(); advanceTimer = nil
        imgQueue.async { [weak self] in self?.cache.removeAll() }
    }

    // MARK: — Kuracja

    private func buildAndBegin() {
        imgQueue.async { [weak self] in
            guard let self else { return }
            let built = self.curateSlides()
            guard !built.isEmpty else {
                self.setStatus(self.selectedAlbumID.isEmpty
                               ? String(localized: "Brak zdjęć w bibliotece")
                               : String(localized: "Wybrany album jest pusty — zmień źródło w apce"))
                return
            }
            self.slides = built
            self.index  = 0
            self.setStatus("")
            self.loadWindow()
            DispatchQueue.main.async { self.showCurrent(); self.startTimer() }
        }
    }

    /// Wybrane źródło zdjęć: pusty = miks („wszystkie"), `favoritesID` = same
    /// ulubione, inaczej localIdentifier albumu.
    /// Czytane na żywo z ustawień, żeby zmiana w UI działała po restarcie managera.
    private var selectedAlbumID: String {
        UserDefaults.standard.string(forKey: "memoriesAlbumID") ?? ""
    }

    /// Sentinel dla trybu „same ulubione". Nie może kolidować z localIdentifier
    /// albumu (te mają postać UUID/xxx), więc podkreślenia są bezpieczne.
    static let favoritesID = "__favorites__"

    /// Liczba ulubionych zdjęć — do podpisu w pickerze. Wołać z wątku tła.
    static func favoritesCount() -> Int {
        let o = PHFetchOptions()
        o.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue),
            NSPredicate(format: "favorite == YES")])
        return PHAsset.fetchAssets(with: o).count
    }

    /// Album do wyboru w UI.
    struct AlbumInfo: Identifiable, Hashable {
        let id: String      // PHAssetCollection.localIdentifier
        let title: String
        let count: Int
    }

    /// Lista albumów użytkownika (do pickera). Wołać z wątku tła — robi fetch PhotoKit.
    static func availableAlbums() -> [AlbumInfo] {
        var out: [AlbumInfo] = []
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let cols = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        cols.enumerateObjects { col, _, _ in
            let n = PHAsset.fetchAssets(in: col, options: opts).count
            guard n > 0, let title = col.localizedTitle else { return }
            out.append(AlbumInfo(id: col.localIdentifier, title: title, count: n))
        }
        return out.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Buduje kadry: kandydaci → grupowanie po dniu → losowa kolejność DNI →
    /// wewnątrz dnia chronologicznie → pakowanie po 1-3 w mozaikę.
    private func curateSlides() -> [MemorySlide] {
        var seen = Set<String>()
        func uniq(_ arr: [PHAsset]) -> [PHAsset] { arr.filter { seen.insert($0.localIdentifier).inserted } }

        let candidates: [PHAsset]
        if selectedAlbumID == Self.favoritesID {
            // Tryb ULUBIONE — tylko serduszka, bez limitu (grupowanie po dniach zostaje).
            candidates = uniq(fetchFavorites(limit: 0))
        } else if !selectedAlbumID.isEmpty,
           let col = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [selectedAlbumID], options: nil).firstObject {
            // Tryb ALBUM — bierzemy wszystko z niego (grupowanie po dniach zostaje).
            candidates = uniq(collect(PHAsset.fetchAssets(in: col, options: imageFetchOptions(nil, limit: 0))))
        } else {
            // Tryb WSZYSTKIE — limit z każdego źródła, żeby żadne nie zdominowało.
            candidates = Array(uniq(fetchOnThisDay()).prefix(80))
                + Array(uniq(fetchFavorites(limit: 60)).prefix(60))
                + Array(uniq(fetchRandom(limit: 60)).prefix(60))
        }
        guard !candidates.isEmpty else { return [] }

        // Grupowanie po dniu kalendarzowym.
        let cal = Calendar.current
        var byDay: [Date: [PHAsset]] = [:]
        for a in candidates {
            guard let d = a.creationDate else { continue }
            byDay[cal.startOfDay(for: d), default: []].append(a)
        }
        guard !byDay.isEmpty else { return [] }

        // Losowa kolejność DNI (żeby każde wejście dawało inny przebieg),
        // ale wewnątrz dnia chronologicznie — spójna opowieść.
        var out: [MemorySlide] = []
        for day in byDay.keys.shuffled() {
            let sorted = (byDay[day] ?? []).sorted {
                ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
            }
            let cap = caption(for: day)
            // Pakowanie w mozaikę: dokładamy zdjęcia póki mieszczą się w szerokości.
            var chunk: [PHAsset] = []
            var usedW: CGFloat = 0
            for a in sorted {
                let w = fittedWidth(a)
                let need = usedW + w + (chunk.isEmpty ? 0 : gap)
                if !chunk.isEmpty && (need > Self.photoAreaW || chunk.count >= 3) {
                    out.append(MemorySlide(assets: chunk, caption: cap))
                    chunk = [a]; usedW = w
                } else {
                    chunk.append(a); usedW = need
                }
            }
            if !chunk.isEmpty { out.append(MemorySlide(assets: chunk, caption: cap)) }
        }
        return Array(out.prefix(80))
    }

    /// Szerokość zdjęcia po wpasowaniu w wysokość obszaru (aspect-fit).
    private func fittedWidth(_ a: PHAsset) -> CGFloat {
        let w = CGFloat(a.pixelWidth), h = CGFloat(a.pixelHeight)
        guard w > 0, h > 0 else { return Self.photoAreaH }
        return Self.photoAreaH * (w / h)
    }

    /// Podpis kadru: „Tego dnia · 2023" gdy ta sama data w poprzednim roku,
    /// inaczej „14 sierpnia 2023".
    private func caption(for day: Date) -> String {
        let cal = Calendar.current
        let now = Date()
        let sameDayOfYear = cal.component(.month, from: day) == cal.component(.month, from: now)
            && abs(cal.component(.day, from: day) - cal.component(.day, from: now)) <= 3
        let year = cal.component(.year, from: day)
        if sameDayOfYear && year < cal.component(.year, from: now) {
            return String(localized: "Tego dnia · \(year)")
        }
        return Self.dayFormatter.string(from: day)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "d MMMM yyyy"
        return f
    }()

    private func imageFetchOptions(_ predicate: NSPredicate?, limit: Int) -> PHFetchOptions {
        let o = PHFetchOptions()
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var preds = [NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)]
        if let predicate { preds.append(predicate) }
        o.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: preds)
        if limit > 0 { o.fetchLimit = limit }
        return o
    }

    /// Zdjęcia z tego dnia (±3 dni) w poprzednich latach (do 12 lat wstecz).
    private func fetchOnThisDay() -> [PHAsset] {
        let cal = Calendar.current
        let now = Date()
        let curYear = cal.component(.year, from: now)
        var ranges: [NSPredicate] = []
        for year in (curYear - 12)..<curYear {
            var comps = cal.dateComponents([.month, .day], from: now)
            comps.year = year
            guard let center = cal.date(from: comps),
                  let start = cal.date(byAdding: .day, value: -3, to: center),
                  let end   = cal.date(byAdding: .day, value:  4, to: center) else { continue }
            ranges.append(NSPredicate(format: "creationDate >= %@ AND creationDate < %@",
                                      start as NSDate, end as NSDate))
        }
        guard !ranges.isEmpty else { return [] }
        let anyYear = NSCompoundPredicate(orPredicateWithSubpredicates: ranges)
        return collect(PHAsset.fetchAssets(with: imageFetchOptions(anyYear, limit: 120)))
    }

    private func fetchFavorites(limit: Int) -> [PHAsset] {
        collect(PHAsset.fetchAssets(with: imageFetchOptions(NSPredicate(format: "favorite == YES"), limit: limit)))
    }

    private func fetchRandom(limit: Int) -> [PHAsset] {
        let res = PHAsset.fetchAssets(with: imageFetchOptions(nil, limit: 0))
        guard res.count > 0 else { return [] }
        // Losowe indeksy z całej biblioteki (bez ładowania wszystkiego).
        let picks = Set((0..<res.count).shuffled().prefix(min(limit, res.count)))
        return picks.map { res.object(at: $0) }
    }

    private func collect(_ res: PHFetchResult<PHAsset>) -> [PHAsset] {
        var out: [PHAsset] = []
        res.enumerateObjects { a, _, _ in out.append(a) }
        return out
    }

    // MARK: — Timer + ładowanie okna

    private func startTimer() {
        advanceTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + slideSeconds, repeating: slideSeconds)
        t.setEventHandler { [weak self] in self?.advance() }
        t.resume()
        advanceTimer = t
    }

    private func advance() {
        guard !slides.isEmpty else { return }
        index = (index + 1) % slides.count
        imgQueue.async { [weak self] in self?.loadWindow() }
        showCurrent()
    }

    /// Ręczna zmiana z joysticka — przeskocz i zresetuj timer.
    func manualNext() { guard !slides.isEmpty else { return }; advance(); startTimer() }
    func manualPrev() {
        guard !slides.isEmpty else { return }
        index = (index - 1 + slides.count) % slides.count
        imgQueue.async { [weak self] in self?.loadWindow() }
        showCurrent(); startTimer()
    }

    /// Ładuje obrazy dla okna kadrów [index-1 … index+2], usuwa dalekie z cache.
    private func loadWindow() {
        guard !slides.isEmpty else { return }
        let want = (-1...2).map { (index + $0 + slides.count) % slides.count }
        let keep = Set(want.flatMap { slides[$0].assets.map(\.localIdentifier) })
        cache = cache.filter { keep.contains($0.key) }
        for i in want {
            for a in slides[i].assets where cache[a.localIdentifier] == nil {
                requestImage(a)
            }
        }
    }

    private func requestImage(_ asset: PHAsset) {
        let opt = PHImageRequestOptions()
        opt.isNetworkAccessAllowed = true          // pobierz z iCloud jeśli trzeba
        opt.deliveryMode = .highQualityFormat
        opt.resizeMode   = .fast
        opt.isSynchronous = false
        // Aspect-FIT: prosimy o rozmiar mieszczący się w wysokości obszaru (×2 dla ostrości).
        let ts = CGSize(width: Self.photoAreaW * 2, height: Self.photoAreaH * 2)
        manager.requestImage(for: asset, targetSize: ts, contentMode: .aspectFit, options: opt) { [weak self] img, info in
            guard let self, let img else { return }
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            self.imgQueue.async {
                self.cache[asset.localIdentifier] = img
                // Jeśli to zdjęcie z bieżącego kadru i przyszła pełna jakość — odśwież.
                if !degraded, self.index < self.slides.count,
                   self.slides[self.index].assets.contains(where: { $0.localIdentifier == asset.localIdentifier }) {
                    DispatchQueue.main.async { self.showCurrent() }
                }
            }
        }
    }

    /// Ustawia obrazy bieżącego kadru + poprzedni (do fade) + podpis, pod zamkiem.
    private func showCurrent() {
        guard !slides.isEmpty else { return }
        let slide = slides[index]
        imgQueue.async { [weak self] in
            guard let self else { return }
            let imgs = slide.assets.compactMap { self.cache[$0.localIdentifier] }
            guard !imgs.isEmpty else { return }   // jeszcze się ładuje — zostaw poprzedni kadr
            self.lock.lock()
            let changed = imgs.count != self._current.count
                || zip(imgs, self._current).contains { $0 !== $1 }
            if changed {
                if !self._current.isEmpty, self._caption != slide.caption || imgs.first !== self._current.first {
                    self._previous = self._current
                    self._switchAt = Date().timeIntervalSince1970
                }
                self._current = imgs
                self._caption = slide.caption
                if self._switchAt == 0 { self._switchAt = Date().timeIntervalSince1970 }
            }
            self.lock.unlock()
        }
    }

    private func setStatus(_ s: String) {
        lock.lock(); _status = s; lock.unlock()
    }
}
