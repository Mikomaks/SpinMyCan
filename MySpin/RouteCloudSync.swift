// RouteCloudSync.swift
// Kopia tras w folderze na iCloud Drive wskazanym raz przez użytkownika (np. iCloud Drive/MySpin/Trasy).
//
// Bez uprawnienia iCloud w apce (to wymaga płatnego konta deweloperskiego): folder wybrany
// w systemowym oknie plików daje apce trwały dostęp przez zakładkę (security-scoped bookmark),
// a iCloud Drive sam wysyła pliki na serwer i ściąga je przy otwarciu.
//
// Co robi sync (kolejka w tle, po każdym zapisie trasy i przy starcie apki):
//   1. każdą trasę z telefonu (Documents/sessions/<uuid>.json + .meta) kopiuje do folderu,
//      jeśli tam jej brak albo ma inny rozmiar,
//   2. trasy starsze niż `keepLocalDays` usuwa z telefonu — ale TYLKO gdy kopia ma ten sam
//      rozmiar i iCloud potwierdza, że już jest na serwerze. Plik .meta zostaje, więc trasa
//      dalej jest w bibliotece; otwarcie jej ściąga plik z chmury (SessionStorage.load).
// Usunięcie trasy w apce usuwa też kopię w chmurze. Odłączenie folderu najpierw ściąga
// z powrotem trasy, których nie ma w telefonie.

import Foundation
import Combine

final class RouteCloudSync: ObservableObject {
    static let shared = RouteCloudSync()

    @Published private(set) var folderName: String?
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var cloudCount = 0      // tras w folderze
    @Published private(set) var cloudOnlyCount = 0  // tras tylko w chmurze (usuniętych z telefonu)

    /// Tyle dni trasy zostają też w telefonie (do oglądania bez internetu).
    nonisolated static let keepLocalDays = 30
    nonisolated private static let bookmarkKey = "routesCloudBookmark"
    nonisolated private static let nameKey = "routesCloudFolderName"

    let q = DispatchQueue(label: "routes.cloud", qos: .utility)
    private let localDir: URL
    private let defaults: UserDefaults

    /// Parametry tylko dla testów (FeatureSelfTest: katalogi tymczasowe, osobne UserDefaults).
    init(localDir: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions", isDirectory: true),
         defaults: UserDefaults = .standard) {
        self.localDir = localDir
        self.defaults = defaults
        if defaults.data(forKey: Self.bookmarkKey) != nil {
            folderName = defaults.string(forKey: Self.nameKey)
        }
    }

    // MARK: — API (wątek główny)

    /// Folder wybrany w oknie plików (.fileImporter z [.folder]).
    func setFolder(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData()
            defaults.set(data, forKey: Self.bookmarkKey)
            defaults.set(url.lastPathComponent, forKey: Self.nameKey)
            folderName = url.lastPathComponent
            sync()
        } catch {
            status = "Nie da się zapamiętać folderu: \(error.localizedDescription)"
        }
    }

    /// Odłącza folder; trasy, których nie ma w telefonie, najpierw wracają z chmury.
    func disconnect() {
        busy = true
        status = "Ściągam trasy z chmury…"
        q.async { [self] in
            var failed = 0
            _ = withFolder { folder in
                for meta in localMetas() where !exists(local(meta)) {
                    let name = meta.deletingPathExtension().lastPathComponent + ".json"
                    if let d = coordinatedRead(folder.appendingPathComponent(name)) {
                        if (try? d.write(to: localDir.appendingPathComponent(name), options: .atomic)) == nil { failed += 1 }
                    } else { failed += 1 }
                }
            }
            DispatchQueue.main.async { [self] in
                busy = false
                if failed > 0 {
                    status = "Nie ściągnęło się \(failed) tras — folder zostaje podłączony. Sprawdź internet."
                    return
                }
                defaults.removeObject(forKey: Self.bookmarkKey)
                defaults.removeObject(forKey: Self.nameKey)
                folderName = nil
                cloudCount = 0; cloudOnlyCount = 0
                status = "Folder odłączony, wszystkie trasy są w telefonie."
            }
        }
    }

    func sync() {
        guard folderName != nil else { return }
        DispatchQueue.main.async { self.busy = true }
        q.async { [self] in
            var copied = 0, offloaded = 0, cloud = 0, cloudOnly = 0
            let ok = withFolder { folder in
                let cutoff = Date().addingTimeInterval(-Double(Self.keepLocalDays) * 86_400)
                for meta in localMetas() {
                    let json = local(meta)
                    let names = [meta, json].filter { exists($0) }
                    for src in names {
                        let dst = folder.appendingPathComponent(src.lastPathComponent)
                        if size(dst) != size(src), coordinatedCopy(src, to: dst) { copied += 1 }
                    }
                    guard exists(json) else { continue }
                    // Stara trasa: z telefonu znika dopiero, gdy kopia jest cała i na serwerze iCloud.
                    let dst = folder.appendingPathComponent(json.lastPathComponent)
                    if let start = startTime(meta), start < cutoff,
                       size(dst) == size(json), uploaded(dst),
                       (try? FileManager.default.removeItem(at: json)) != nil {
                        offloaded += 1
                    }
                }
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                cloud = files.filter { $0.pathExtension == "meta" }.count
                cloudOnly = localMetas().filter { !exists(local($0)) }.count
            }
            DispatchQueue.main.async { [self] in
                busy = false
                guard ok else { status = "Brak dostępu do folderu — wybierz go jeszcze raz."; return }
                cloudCount = cloud
                cloudOnlyCount = cloudOnly
                let f = DateFormatter(); f.dateFormat = "HH:mm"
                var s = "Zsynchronizowano \(f.string(from: Date()))"
                if copied > 0 { s += " · wysłane pliki: \(copied)" }
                if offloaded > 0 { s += " · zwolnione z telefonu: \(offloaded)" }
                status = s
            }
        }
    }

    // MARK: — Dla SessionStorage (dowolny wątek)

    /// Trasa z chmury (ściąga plik, jeśli iCloud trzyma go tylko na serwerze). Blokuje do końca.
    nonisolated func cloudData(_ fileName: String) -> Data? {
        var out: Data?
        _ = withFolder { out = coordinatedRead($0.appendingPathComponent(fileName)) }
        return out
    }

    /// Usuwa kopię trasy z chmury (gdy trasa jest usuwana w apce).
    nonisolated func deleteFromCloud(_ id: UUID) {
        q.async { [self] in
            _ = withFolder { folder in
                for ext in ["json", "meta"] {
                    let url = folder.appendingPathComponent("\(id.uuidString).\(ext)")
                    guard exists(url) else { continue }
                    var err: NSError?
                    NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &err) {
                        try? FileManager.default.removeItem(at: $0)
                    }
                }
            }
        }
    }

    // MARK: — Pliki (nonisolated — kolejka q albo wątek wołającego)

    /// Folder z zakładki, z dostępem na czas `body`. false = brak folderu / dostępu.
    nonisolated private func withFolder(_ body: (URL) -> Void) -> Bool {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return false }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return false }
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        if stale, let fresh = try? url.bookmarkData() {
            defaults.set(fresh, forKey: Self.bookmarkKey)
        }
        body(url)
        return true
    }

    nonisolated private func localMetas() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: localDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "meta" }
    }

    nonisolated private func local(_ meta: URL) -> URL {
        meta.deletingPathExtension().appendingPathExtension("json")
    }

    nonisolated private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Rozmiar pliku; nil = brak. Dla pliku trzymanego tylko na serwerze iCloud to rozmiar logiczny.
    nonisolated private func size(_ url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    /// Czy iCloud potwierdził wysłanie na serwer. Folder spoza iCloud (np. „Na iPhonie”) = false:
    /// usuwanie z telefonu nic by wtedy nie dało.
    nonisolated private func uploaded(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey])
        return v?.isUbiquitousItem == true && v?.ubiquitousItemIsUploaded == true
    }

    nonisolated private func startTime(_ meta: URL) -> Date? {
        guard let d = try? Data(contentsOf: meta) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(SessionMeta.self, from: d))?.startTime
    }

    nonisolated private func coordinatedCopy(_ src: URL, to dst: URL) -> Bool {
        var ok = false
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: dst, options: .forReplacing, error: &err) { url in
            let fm = FileManager.default
            try? fm.removeItem(at: url)
            ok = (try? fm.copyItem(at: src, to: url)) != nil
        }
        return ok && size(dst) == size(src)
    }

    nonisolated private func coordinatedRead(_ url: URL) -> Data? {
        var out: Data?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { out = try? Data(contentsOf: $0) }
        return out
    }
}
