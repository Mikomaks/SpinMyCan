// ShareConfigView.swift
// Konfigurator plakatu trasy (PNG 1080×1920 do udostępnienia): podgląd na żywo i przełączniki,
// co ma być na mapie i pod nią. Wybór zapamiętany (ShareOptions.saved).
// Rysowanie: SessionShareHelper (SessionLibraryView.swift).

import SwiftUI

/// Format pliku: relacja Instagrama 9:16, post 4:5 albo naturalna długość plakatu.
enum PosterFormat: String, Codable, CaseIterable {
    case story, post, free

    var label: String {
        switch self {
        case .story: return String(localized: "Relacja 9:16")
        case .post:  return String(localized: "Post 4:5")
        case .free:  return String(localized: "Cały plakat")
        }
    }
    /// Wysokość przy szerokości 1080; nil = taka, jaka wyjdzie.
    var height: CGFloat? {
        switch self {
        case .story: return 1920
        case .post:  return 1350
        case .free:  return nil
        }
    }
}

/// Co trafia na plakat trasy.
struct ShareOptions: Codable, Equatable {
    var format: PosterFormat = .story
    // Na mapie
    var mapLabels = true      // plakietki max prędkości i przechyłu
    var songsOnMap = false    // numerowane kółka w miejscu, gdzie zaczął się utwór
    // Pod mapą
    var stats = true          // max / średnia / max G
    var lean = true
    var engine = true         // max i średnie obroty, zmiany biegów (mostek CAN)
    var gears = true          // udział czasu na biegach
    var gearsPie = false      // biegi jako wykres kołowy zamiast słupków
    var favSong = true        // najdłużej grający utwór
    var songList = false      // lista utworów (numery = kółka na mapie)
    var time = true
    var watermark = true

    static let maxListedSongs = 6
    private static let key = "shareOptions"

    static var saved: ShareOptions {
        guard let d = UserDefaults.standard.data(forKey: key),
              let o = try? JSONDecoder().decode(ShareOptions.self, from: d) else { return ShareOptions() }
        return o
    }

    init() {}

    /// Brakujące pola (zapis ze starszej wersji) = wartości domyślne.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShareOptions()
        format     = (try? c.decode(PosterFormat.self, forKey: .format)) ?? d.format
        mapLabels  = (try? c.decode(Bool.self, forKey: .mapLabels)) ?? d.mapLabels
        songsOnMap = (try? c.decode(Bool.self, forKey: .songsOnMap)) ?? d.songsOnMap
        stats      = (try? c.decode(Bool.self, forKey: .stats)) ?? d.stats
        lean       = (try? c.decode(Bool.self, forKey: .lean)) ?? d.lean
        engine     = (try? c.decode(Bool.self, forKey: .engine)) ?? d.engine
        gears      = (try? c.decode(Bool.self, forKey: .gears)) ?? d.gears
        gearsPie   = (try? c.decode(Bool.self, forKey: .gearsPie)) ?? d.gearsPie
        favSong    = (try? c.decode(Bool.self, forKey: .favSong)) ?? d.favSong
        songList   = (try? c.decode(Bool.self, forKey: .songList)) ?? d.songList
        time       = (try? c.decode(Bool.self, forKey: .time)) ?? d.time
        watermark  = (try? c.decode(Bool.self, forKey: .watermark)) ?? d.watermark
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }

    /// Czy zmiana dotyczy mapy (wtedy trzeba ją wyrenderować od nowa — to chwilę trwa):
    /// to, co na niej narysowane, albo jej rozmiar (zależy od liczby bloków pod nią).
    func mapDiffers(from o: ShareOptions, for s: SessionSummary) -> Bool {
        mapLabels != o.mapLabels || songsOnMap != o.songsOnMap
            || SessionShareHelper.posterLayout(s, self).map != SessionShareHelper.posterLayout(s, o).map
    }
}

extension SessionSummary {
    /// Utwór, który grał najdłużej (do następnego utworu albo do końca trasy).
    var favoriteTrack: SessionTrack? {
        guard let t = tracks, !t.isEmpty else { return nil }
        var best: (SessionTrack, TimeInterval)?
        for (i, tr) in t.enumerated() {
            let end = i + 1 < t.count ? t[i + 1].time : endTime
            let d = end.timeIntervalSince(tr.time)
            if best == nil || d > best!.1 { best = (tr, d) }
        }
        return best?.0
    }
}

struct ShareConfigView: View {
    let summary: SessionSummary
    @Environment(\.dismiss) private var dismiss

    @State private var options = ShareOptions.saved
    @State private var mapImage: UIImage?
    @State private var mapFor: ShareOptions?
    @State private var preview: UIImage?
    @State private var mapLoading = false

    private var hasEngine: Bool { summary.engineStats != nil }
    private var hasSongs: Bool { !(summary.tracks ?? []).isEmpty }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
            // Podgląd przypięty nad listą — widać zmianę przy każdym przełączniku.
            ZStack {
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(radius: 4)
                } else {
                    Color.black.aspectRatio(1080.0 / 1920, contentMode: .fit)
                }
                if mapLoading { ProgressView().tint(.white) }
            }
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(.systemGroupedBackground))

            List {
                Section {
                    Picker("Format", selection: $options.format) {
                        ForEach(PosterFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Format")
                } footer: {
                    Text("Relacja i post mają stały rozmiar pod Instagrama — przy wielu blokach plakat jest zmniejszany, nic nie jest ucinane.")
                }

                Section("Na mapie") {
                    Toggle("Max prędkość i przechył", isOn: $options.mapLabels)
                    Toggle("Gdzie zaczęła się piosenka", isOn: $options.songsOnMap).disabled(!hasSongs)
                }

                Section("Jazda") {
                    Toggle("Max, średnia, przeciążenie", isOn: $options.stats)
                    Toggle("Przechył", isOn: $options.lean)
                    Toggle("Czas jazdy", isOn: $options.time)
                }

                Section {
                    Toggle("Obroty i zmiany biegów", isOn: $options.engine)
                    Toggle("Czas na biegach", isOn: $options.gears)
                    Toggle("Biegi jako wykres kołowy", isOn: $options.gearsPie).disabled(!options.gears)
                } header: {
                    Text("Silnik")
                } footer: {
                    if !hasEngine { Text("Ta trasa nie ma danych z płytki CAN.") }
                }
                .disabled(!hasEngine)

                Section {
                    Toggle("Utwór trasy (grał najdłużej)", isOn: $options.favSong)
                    Toggle("Lista piosenek", isOn: $options.songList)
                } header: {
                    Text("Muzyka")
                } footer: {
                    Text(hasSongs ? String(localized: "Piosenki z odtwarzacza w trakcie trasy: \(summary.tracks?.count ?? 0).")
                                  : String(localized: "W tej trasie nie zapisały się piosenki (zapis od wersji 1.18.0)."))
                }
                .disabled(!hasSongs)

                Section {
                    Toggle("Podpis SpinMyCan @mikomaks_", isOn: $options.watermark)
                }
            }
            }
            .navigationTitle("Plakat trasy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BackButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Udostępnij") {
                        options.save()
                        let img = SessionShareHelper.poster(summary, mapImage: mapImage, options: options)
                        SessionShareHelper.sharePoster(img, for: summary)
                    }
                    .disabled(mapLoading)
                }
            }
        }
        .onAppear { refresh() }
        .onChange(of: options) { _, _ in refresh() }
    }

    /// Plakat od nowa; mapa tylko gdy zmieniło się to, co na niej (MKMapSnapshotter trwa ok. sekundy).
    private func refresh() {
        // Od razu — z mapą, która już jest (przy innym rozmiarze przyciętą); nowa podmieni się po chwili.
        preview = SessionShareHelper.poster(summary, mapImage: mapImage, options: options)
        if let m = mapFor, !options.mapDiffers(from: m, for: summary) { return }
        let want = options
        mapLoading = true
        SessionShareHelper.mapSnapshot(for: summary, options: want) { img in
            guard want == options || !options.mapDiffers(from: want, for: summary) else { return }   // nowsze zmiany w drodze
            mapImage = img
            mapFor = want
            mapLoading = false
            preview = SessionShareHelper.poster(summary, mapImage: img, options: options)
        }
    }
}
