// ContentView.swift
// Główny ekran — BT handshake → WiFi → TCP → dane z motocykla

import SwiftUI
import Network
import ExternalAccessory
import Combine
import UIKit
import CoreLocation
import MapKit
import Photos
import WebKit

struct ContentView: View {

    @StateObject private var bt         = BTManager()
    @StateObject private var session    = MySpinSession()
    @StateObject private var renderer   = FrameRenderer(width: 864, height: 320)
    @StateObject private var telemetry  = TelemetryStore()
    @StateObject private var motion      = MotionManager()
    @StateObject private var nowPlaying  = NowPlayingManager()
    @StateObject private var spotify     = SpotifyWebManager()
    @StateObject private var recorder    = SessionRecorder()
    @StateObject private var replay      = ReplayManager()
    @StateObject private var weather     = WeatherManager()
    @StateObject private var snakeGame   = SnakeGame()
    @StateObject private var sudoku      = SudokuGame()
    @StateObject private var mapSnap     = MapSnapshotManager()
    @StateObject private var perfMeter   = PerfMeter()
    @StateObject private var navManager  = NavManager()
    @StateObject private var lyrics      = LyricsManager()
    @StateObject private var memories    = MemoriesManager()
    @StateObject private var segments    = SegmentManager()
    @StateObject private var bikeLink    = BikeLinkManager()
    @State private var showSegments      = false
    @State private var showBusViewer     = false
    @State private var showSettings      = false
    /// Kalibracja dwupunktowa w ustawieniach — zwinięta, bo ustawia się ją raz.
    @State private var showTwoPointCal   = false
    /// Do którego miejsca przewinąć ustawienia po otwarciu (np. po tapnięciu pigułki CAN).
    @State private var settingsAnchor: String? = nil
    @State private var navSearchText     = ""
    @StateObject private var videoProvider = VideoFrameProvider()
    @ObservedObject private var storage  = SessionStorage.shared

    // Podsumowanie sesji — gdy non-nil wyświetlamy RideSheet (ten sam widok co trasa z biblioteki)
    @State private var sessionSummary:      SessionSummary? = nil
    @State private var showLibrary:         Bool = false
    @State private var showPlayer:          Bool = false
    @State private var showRecoveryAlert:   Bool = false

    // ── Grace period: BT zerwane podczas nagrywania ──
    // Nagrywanie NIE jest przerywane — czekamy na powrót BT.
    // Po 1h: powiadomienie z pytaniem o zakończenie. Po 4h: auto-zapis.
    @State private var btLostAt:            Date? = nil
    @State private var lastTcpConnectAttempt: Date? = nil   // throttling auto-reconnectu TCP
    @State private var btGraceNotified:     Bool  = false
    @State private var showEndRouteAlert:   Bool  = false
    // Czy bieżące nagrywanie jest „przypięte do motocykla" (auto lub moto obecne
    // podczas nagrywania). Tylko takie sesje grace-pauzujemy przy utracie połączenia —
    // ręczne nagrywanie w trybie standalone (bez moto) NIE jest pauzowane.
    @State private var recordingBikeTied:   Bool  = false
    // Jednorazowy setup — onAppear (na NavigationView) potrafi odpalić się >1×,
    // a drugie previewTimer.resume() = over-resume DispatchSource → crash.
    @State private var didSetup:            Bool  = false
    // Użytkownik ręcznie zatrzymał sensory (przycisk Stop) — wtedy heartbeat ich
    // nie wznawia. Domyślnie false = sensory zawsze żywe. Nagrywanie i tak wymusza ON.
    @State private var sensorsManuallyStopped: Bool = false
    private let graceNotifySec: TimeInterval = 3600      // 1h → powiadomienie
    private let graceAutoSaveSec: TimeInterval = 4 * 3600 // 4h → auto-zapis


    @State private var spotifyClientID: String = ""

    /// Stan joysticka — ref-type żeby closure onEvent zawsze widziała aktualną wartość
    @StateObject private var joyState = JoystickState()
    // Ustawienia TCP (można zmienić)
    @State private var tcpHost = "192.168.10.2"
    @State private var tcpPort = "7195"

    // UI
    @State private var pickerBind: BindPick? = nil   // otwarta grafika wyboru przycisku
    // lastEvent przeniesiony do joyState.lastEvent

    @State private var wifiSSID:     String? = nil
    @State private var wifiPassword: String? = nil
    @State private var wifiConnectStatus: String? = nil   // komunikat po próbie połączenia

    // Motyw: true = ciemny (domyślny), false = jasny
    @AppStorage("dashboardDark") private var isDark: Bool = true

    /// Gdy ON — sensory (GPS + IMU) i zapis wyników tylko gdy BT jest aktywne.
    /// Domyślnie włączone. Wyłącz jeśli używasz apki bez motocykla.
    @AppStorage("requireBTForSensors") private var requireBT: Bool = true

    /// Auto-nagrywanie trasy — start gdy BT aktywne, stop gdy BT odpada.
    @AppStorage("autoRecord") private var autoRecord: Bool = true
    @AppStorage("skipIdlePoints") private var skipIdlePoints: Bool = true

    /// Aktywny ekran dashboardu (0=klasyczny, 1=lean, 2=snake) — zapisany.
    @AppStorage("activeScreen") private var activeScreen: Int = 0
    @AppStorage("ambientBG") private var ambientBG: Bool = true
    @AppStorage("bikeLink") private var bikeLinkOn: Bool = true
    // Domyślnie włączony: pierwsze jazdy mają same zostawić materiał do rozszyfrowania
    // szyny. Miejsce jest ograniczone limitem (BikeLinkManager.logQuotaBytes).
    @AppStorage("canRawLog") private var canRawLog: Bool = true
    @AppStorage("bikeLean") private var bikeLeanOn: Bool = true
    @AppStorage("bikeSpeed") private var bikeSpeedOn: Bool = true
    @AppStorage("liveActivity") private var liveActivityOn: Bool = true
    @State private var showClearCodes = false
    @State private var frameStats = FrameStats()
    @State private var wifiWatch = WifiWatch()
    /// Ostatnio używany ekran nawigacji — udostępniony cel otwiera ten, a nie zawsze navClassic.
    @AppStorage("lastNavScreen") private var lastNavScreen: Int = DashboardScreen.navClassic.rawValue
    /// Źródło zdjęć Wspomnień: "" = miks (wszystkie), inaczej localIdentifier albumu.
    @AppStorage("memoriesAlbumID") private var memoriesAlbumID: String = ""
    /// Liczba ulubionych — do podpisu w pickerze (liczona razem z albumami).
    @State private var favoritesCount: Int = 0
    @State private var memoryAlbums: [MemoriesManager.AlbumInfo] = []
    @State private var showAlbumPicker = false
    @State private var showRiderMode = false
    /// Kolejność ekranów (CSV rawValues) — przestawiana drag&drop, zapisana lokalnie.
    @AppStorage("screenOrder") private var screenOrderRaw: String = ""

    // Background task — trzyma proces żywy gdy app schodzi w tło
    @State private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

    // Podgląd dashboardu — renderowany przez własny timer (nie .onReceive)
    @State private var dashboardImage: UIImage?
    private let previewTimer = DispatchSource.makeTimerSource(queue: .main)

    /// Wersja z bundla (CFBundleShortVersionString ← MARKETING_VERSION). „v1.1.0".
    static var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "v\(v)"
    }

    /// Raport z poprzedniego crasha/Jetsam (jeśli był) — pokazywany kartą na górze.

    /// Ostrzeżenie gdy podpis apki zaraz wygaśnie (darmowe konto Apple = 7 dni).
    /// Lepiej zobaczyć to w garażu niż 300 km od domu.
    private var expiryWarningCard: some View {
        let days = ProvisioningInfo.daysLeft ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            Label(days < 0 ? "Podpis aplikacji wygasł" : "Podpis wygasa za \(days) dni",
                  systemImage: "hourglass.bottomhalf.filled")
                .font(.headline).foregroundColor(.red)
            Text(days < 0
                 ? "iOS przestanie uruchamiać apkę. Podłącz telefon do Maca i odśwież."
                 : "Darmowe konto Apple podpisuje apkę tylko na 7 dni. Odśwież PRZED wyjazdem.")
                .font(.caption).foregroundColor(.secondary)
            Text("Na Macu:  make refresh")
                .font(.system(size: 12, design: .monospaced))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray5)).cornerRadius(6)
        }
        .padding()
        .background(Color.red.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: AppStyle.cardRadius, style: .continuous).stroke(Color.red.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: AppStyle.cardRadius, style: .continuous))
    }

    var body: some View {
        #if DEBUG
        let _ = ProcessInfo.processInfo.environment["PRINT_CHANGES"] != nil ? Self._printChanges() : ()
        #endif
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    // Pod otwartymi ustawieniami ekranu głównego nie widać, a jego przeliczanie
                    // przy każdej zmianie danych dławiło przewijanie arkusza.
                    PausedWhileHidden(paused: showSettings) {
                    VStack(spacing: 14) {
                        appHeader
                        if ProvisioningInfo.isExpiringSoon { expiryWarningCard }

                        heroCard.id("hero")
                        statusPills
                        if wifiSSID != nil, !session.tcpState.isConnected { wifiHintCard }
                        liveCard.id("live")

                        screenStrip.id("screens")
                        if activeScreen == DashboardScreen.sudoku.rawValue { sudokuCard }
                        if activeScreen == DashboardScreen.performance.rawValue { perfCard }
                        if activeScreen == DashboardScreen.navigation.rawValue
                            || activeScreen == DashboardScreen.navClassic.rawValue { navCard }
                        if activeScreen == DashboardScreen.memories.rawValue { memoriesCard }
                        if activeScreen == DashboardScreen.video.rawValue {
                            VideoPlaylistCard(video: videoProvider)
                        }

                        recorderCard.id("ride")
                        segmentsCard.id("segments")
                        libraryCard.id("library")
                        musicCard

                        Button { openSettings() } label: {
                            LinkRow(title: "Ustawienia i diagnostyka", icon: "gearshape.fill", tint: .secondary)
                        }
                        .buttonStyle(.plain)
                        .card(padding: 6)
                        .id("settings")

                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    }
                    .equatable()
                }
                .background(AppStyle.pageBackground)
                .onAppear {
                    #if DEBUG
                    if let anchor = ProcessInfo.processInfo.environment["UI_SCROLL"] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { proxy.scrollTo(anchor, anchor: .top) }
                    }
                    #endif
                }
            }
            // Własny nagłówek w treści zamiast systemowego paska.
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(isPresented: $showSettings) { settingsSheet }
            .onChange(of: showSettings) { _, open in
                AppActivity.isSettingsOpen = open
                if !open { renderDashboardPreview() }   // podgląd od razu aktualny po zamknięciu
            }
            .fullScreenCover(item: $sessionSummary)    { s in RideSheet(summary: s) }
            .fullScreenCover(isPresented: $showRiderMode) {
                RiderModeView(motion: motion, recorder: recorder) { summary in
                    sessionSummary = summary   // po STOP pokaż podsumowanie jak zwykle
                }
            }
            .alert("Odzyskaj przerwaną sesję", isPresented: $showRecoveryAlert) {
                Button("Odzyskaj i zapisz") {
                    if let recovered = recorder.recoverInterruptedSession() {
                        sessionSummary = recovered
                    }
                }
                Button("Usuń", role: .destructive) {
                    recorder.clearInterruptedSession()
                }
            } message: {
                Text("Poprzednia sesja została przerwana (crash lub zamknięcie apki). Czy chcesz ją odzyskać?")
            }
            .alert("Zakończyć trasę?", isPresented: $showEndRouteAlert) {
                Button("Zakończ i zapisz") { finishCurrentRoute() }
                Button("Kontynuuj nagrywanie", role: .cancel) { }
            } message: {
                Text("Motocykl wyłączony od godziny, a trasa wciąż jest nagrywana. Zostanie automatycznie zapisana po 4 godzinach.")
            }
            .fullScreenCover(isPresented: $showLibrary) {
                SessionLibraryView(storage: storage) { summary in
                    replay.load(summary)
                    replay.play()
                    // Pokaż odtwarzacz po krótkim opóźnieniu (sheet musi zniknąć najpierw)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showPlayer = true
                    }
                }
            }
            .fullScreenCover(isPresented: $showSegments) {
                SegmentsView(manager: segments) { if !motion.isActive { motion.start() } }
            }
            .fullScreenCover(isPresented: $showPlayer) {
                SessionPlayerView(replay: replay)
            }
        }
        .onAppear { setup() }
        // Połączenie z motocyklem = BT aktywne LUB deska (TCP) połączona.
        // BT (iAP2) to w mySPIN głównie kanał handshake — po aktywacji deska jedzie
        // po WiFi/TCP, a BT bywa „nieaktywne" mimo normalnej jazdy. Dlatego stanem
        // połączenia steruje CIĄGŁY heartbeat (manageBikeConnection), a te onChange
        // odpalają tylko EDGE „właśnie się połączyłem" (auto-start nagrywania).
        // Auto-start jest na edge, żeby ręczny STOP nie był nadpisywany co sekundę.
        .onChange(of: bt.state) { newState in
            if newState.isActive { onBikeConnectedEdge() }
        }
        .onChange(of: session.tcpState) { newTcp in
            if newTcp.isConnected { onBikeConnectedEdge() }
        }
        // requireBT steruje tylko auto-nagrywaniem — sensory zostają żywe zawsze,
        // więc na zmianę toggla tylko upewniamy się, że motion działa.
        .onChange(of: requireBT) { _ in
            if !motion.isActive { motion.start() }
        }
        // ── Background task: trzyma app żywą gdy zminimalizowana ──
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            startBackgroundTask()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            endBackgroundTask()
            motion.refreshOnForeground()   // CoreMotion mogło zasnąć w tle — wznów
            checkPendingSharedDestination()   // cel udostępniony z Apple Maps (share sheet)
        }
    }

    /// Odczytuje cel udostępniony z Apple Maps przez Share Extension (App Group)
    /// i startuje nawigację 1:1. Rozszerzenie zapisuje albo gotowe współrzędne
    /// (z MKMapItem / starego linku ?ll=…), albo surowy krótki link maps.apple/p/…,
    /// który NavManager rozwiązuje przez sieć. No-op gdy nic nie czeka.
    private func checkPendingSharedDestination() {
        guard let d = UserDefaults(suiteName: "group.com.mikomaks.myspin") else { return }
        let lat  = d.object(forKey: "pendingDestLat") as? Double
        let lon  = d.object(forKey: "pendingDestLon") as? Double
        let link = d.string(forKey: "pendingDestLink")
        let name = d.string(forKey: "pendingDestName")
        guard lat != nil || link != nil else { return }
        // Wyczyść od razu, żeby nie odpalać wielokrotnie.
        ["pendingDestLat", "pendingDestLon", "pendingDestLink", "pendingDestName", "pendingDestTime"]
            .forEach { d.removeObject(forKey: $0) }

        if let lat, let lon, abs(lat) <= 90, abs(lon) <= 180, lat != 0 || lon != 0 {
            navManager.navigateToSharedLink("https://maps.apple.com/?ll=\(lat),\(lon)",
                                            name: name, from: motion.lastLocationCoord)
        } else if let link {
            navManager.navigateToSharedLink(link, name: name, from: motion.lastLocationCoord)
        } else {
            return
        }
        // Wspólny mechanizm obu ekranów nawigacji: jeśli już jesteś na którymś —
        // zostań na nim; inaczej otwórz ostatnio używany ekran nawigacji.
        if activeScreen != DashboardScreen.navigation.rawValue
            && activeScreen != DashboardScreen.navClassic.rawValue {
            setActiveScreen(lastNavScreen)
        }
    }

    // MARK: — Wspomnienia (wybór źródła zdjęć)

    var memoriesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader("Wspomnienia — źródło zdjęć", icon: "photo.stack")

            // UWAGA: NIE używamy Picker(.menu) — podgląd dashboardu odświeża się co 1s
            // (dashboardImage to @State), więc całe body się przebudowuje i wyskakujące
            // menu jest natychmiast zamykane („pulsuje", nie da się przewinąć).
            // Arkusz z listą przeżywa przebudowę rodzica i lepiej znosi długie listy.
            Button {
                loadMemoryAlbums(force: true)
                showAlbumPicker = true
            } label: {
                HStack {
                    Text(currentMemorySourceName)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.vertical, 8).padding(.horizontal, 10)
                .background(Color(.systemBackground))
                .cornerRadius(8)
            }

            Text(memoriesAlbumID.isEmpty
                 ? "Miks: zdjęcia z tego dnia w poprzednich latach, ulubione ❤️ i losowe z biblioteki. Uwaga: losowe obejmują też zrzuty ekranu."
                 : "Tylko wybrany album. Zdjęcia grupowane po dniach, po 1-3 obok siebie.")
                .font(.caption).foregroundColor(.secondary)

            if memoryAlbums.isEmpty {
                Text("(nie znalazłem albumów — sprawdź dostęp do Zdjęć)")
                    .font(.caption2).foregroundColor(.orange)
            }
        }
        .card()
        .onAppear { loadMemoryAlbums() }
        .fullScreenCover(isPresented: $showAlbumPicker) { albumPickerSheet }
    }

    /// Nazwa aktualnie wybranego źródła (do przycisku).
    private var currentMemorySourceName: String {
        if memoriesAlbumID.isEmpty { return "Wszystkie (tego dnia + ulubione + losowe)" }
        if memoriesAlbumID == MemoriesManager.favoritesID {
            return favoritesCount > 0 ? "Ulubione · \(favoritesCount) zdjęć" : "Ulubione"
        }
        if let a = memoryAlbums.first(where: { $0.id == memoriesAlbumID }) {
            return "\(a.title) · \(a.count) zdjęć"
        }
        return "Wybrany album"
    }

    /// Lista źródeł w arkuszu — odporna na 1Hz przebudowę widoku pod spodem.
    private var albumPickerSheet: some View {
        NavigationView {
            List {
                Section {
                    albumRow(id: "", title: "Wszystkie", subtitle: "tego dnia + ulubione + losowe")
                    albumRow(id: MemoriesManager.favoritesID, title: "Ulubione",
                             subtitle: favoritesCount > 0 ? "\(favoritesCount) zdjęć z serduszkiem"
                                                          : "zdjęcia oznaczone serduszkiem")
                }
                Section("Twoje albumy") {
                    if memoryAlbums.isEmpty {
                        Text("Brak albumów (albo jeszcze się ładują)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(memoryAlbums) { a in
                        albumRow(id: a.id, title: a.title, subtitle: "\(a.count) zdjęć")
                    }
                }
            }
            .navigationTitle("Źródło zdjęć")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BackButton { showAlbumPicker = false }
                }
            }
        }
    }

    private func albumRow(id: String, title: String, subtitle: String) -> some View {
        Button {
            memoriesAlbumID = id
            memories.stop(); memories.start()   // przebuduj kadry na nowym źródle
            showAlbumPicker = false
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundColor(.primary)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if memoriesAlbumID == id {
                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                }
            }
        }
    }

    /// Wczytuje listę albumów w tle (fetch PhotoKit potrafi chwilę potrwać).
    private func loadMemoryAlbums(force: Bool = false) {
        guard force || memoryAlbums.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let list = MemoriesManager.availableAlbums()
            let favs = MemoriesManager.favoritesCount()
            DispatchQueue.main.async { memoryAlbums = list; favoritesCount = favs }
        }
    }

    // MARK: — BT + WiFi Card (scalona)

    /// Opcje automatycznego nagrywania tras (ustawienia).
    var recordingOptionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader("Nagrywanie tras", icon: "record.circle")

            Toggle(isOn: $autoRecord) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nagrywaj trasę automatycznie")
                        .font(.subheadline)
                    Text("Start po połączeniu z motocyklem, pauza gdy połączenie zniknie, wznowienie po powrocie")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .tint(AppStyle.accent)

            Toggle(isOn: $skipIdlePoints) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pomijaj postój bez motocykla")
                        .font(.subheadline)
                    Text("Postój z połączonym motocyklem (światła, korek) zapisuje się normalnie. Pomijany jest tylko postój bez połączenia")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .tint(AppStyle.accent)

            Toggle(isOn: $requireBT) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Wyniki tylko z motocyklem")
                        .font(.subheadline)
                    Text("Auto-nagrywanie rusza tylko wtedy, gdy telefon jest połączony z motocyklem")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .tint(AppStyle.accent)
        }
        .card()
    }

    var btCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ── Bluetooth ──
            CardHeader("Bluetooth motocykla", icon: "dot.radiowaves.left.and.right", tint: .blue)

            HStack {
                Circle().fill(btColor).frame(width: 8, height: 8)
                Text(bt.state.label).font(.subheadline)
                Spacer()
            }

            HStack(spacing: 8) {
                Button("Start BT") { bt.start() }
                    .buttonStyle(.bordered)
                    .disabled(bt.state.isActive)
                Button("Stop BT") { bt.stop() }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(!bt.state.isActive)
            }

            Divider()

            // ── WiFi motocykla (inline) ──
            CardHeader("WiFi motocykla", icon: "wifi", tint: .blue)

            if let ssid = wifiSSID {
                // SSID + hasło w jednym wierszu
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(ssid)
                            .font(.system(.subheadline, design: .monospaced).bold())
                        Spacer()
                        if let pw = wifiPassword {
                            Button {
                                UIPasteboard.general.string = pw
                                wifiConnectStatus = "✅ Skopiowano hasło"
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .font(.caption)
                        }
                    }
                    if let pw = wifiPassword {
                        Text("Hasło: \(pw)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
                .background(AppStyle.inset)
                .cornerRadius(6)

                if let status = wifiConnectStatus {
                    Text(status).font(.caption).foregroundColor(.green)
                }

                Button {
                    if let pw = wifiPassword {
                        UIPasteboard.general.string = pw
                        wifiConnectStatus = "✅ Hasło w schowku — wybierz \(wifiSSID ?? "") i wklej"
                    }
                    if let url = URL(string: "App-Prefs:root=WIFI"),
                       UIApplication.shared.canOpenURL(url) {
                        UIApplication.shared.open(url)
                    } else if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Otwórz ustawienia WiFi", systemImage: "wifi.circle.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(wifiPassword == nil)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash").foregroundColor(.secondary)
                    Text(wifiStatusLabel).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .card()
    }


    var wifiStatusLabel: String {
        switch bt.state {
        case .wlanState(let s): return "Stan WiFi: \(s)"
        case .handshaking:      return "Czekam na WiFi od motocykla..."
        default:                return "Brak danych WiFi — uruchom BT najpierw"
        }
    }

    // MARK: — TCP Card

    var tcpCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader("Przesył obrazu (TCP)", icon: "network", tint: .blue)

            HStack {
                Circle()
                    .fill(tcpColor)
                    .frame(width: 8, height: 8)
                Text(session.tcpState.label)
                    .font(.subheadline)
                Spacer()
                Text("\(Int(session.displaySize.width))×\(Int(session.displaySize.height))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button(action: toggleTCP) {
                    Label(
                        session.tcpState.isConnected ? "Rozłącz" : "Połącz TCP",
                        systemImage: session.tcpState.isConnected ? "xmark.circle" : "bolt.horizontal"
                    )
                    .font(.caption.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(session.tcpState.isConnected ? .red : .blue)
            }

            // Format klatki — ustalony z pcapng (26-byte header + JPEG)
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
                Text("Format: 26B header + JPEG (z pcapng)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .card()
    }

    // MARK: — Motion Card (GPS + IMU z telefonu)

    var sensorsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader("Czujniki telefonu", icon: "location.fill") {
                HStack(spacing: 5) {
                    Circle().fill(gpsStatusColor).frame(width: 8, height: 8)
                    Text(gpsStatusText).font(.caption).foregroundColor(.secondary)
                }
            }

            // ── Prędkość + Lean ──
            HStack(spacing: 0) {
                MiniTelValue(label: "km/h",
                             value: "\(Int(motion.speedKmh))",
                             color: motion.speedKmh > 0 ? .cyan : .secondary)
                Divider().frame(height: 36)
                MiniTelValue(label: "MAX km/h",
                             value: "\(Int(motion.maxSpeedKmh))",
                             color: .gray)
                Divider().frame(height: 36)
                MiniTelValue(label: leanCardLabel,
                             value: String(format: "%.1f°", abs(motion.leanAngleDeg)),
                             color: leanCardColor)
                Divider().frame(height: 36)
                MiniTelValue(label: "G-force",
                             value: String(format: "%.1fg", motion.gForce),
                             color: motion.gForce > 1.0 ? .orange : (motion.gForce > 0.4 ? .white : .secondary))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(AppStyle.inset)
            .cornerRadius(8)

            // ── Max Lean + Statystyki ──
            HStack(spacing: 0) {
                MiniTelValue(label: "MAX L",
                             value: String(format: "%.1f°", motion.maxLeanLeft),
                             color: .blue)
                Divider().frame(height: 36)
                MiniTelValue(label: "MAX R",
                             value: String(format: "%.1f°", motion.maxLeanRight),
                             color: .red)
                Divider().frame(height: 36)
                MiniTelValue(label: "HDG",
                             value: compassLabel,
                             color: motion.headingDeg >= 0 ? .white : .secondary)
                Divider().frame(height: 36)
                MiniTelValue(label: "SESSION",
                             value: motionFmtTime(motion.sessionSec),
                             color: motion.isActive ? .green : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(AppStyle.inset)
            .cornerRadius(8)

            // ── Przyciski ──
            HStack(spacing: 8) {
                Button {
                    if motion.isActive { motion.stop(); sensorsManuallyStopped = true }
                    else               { motion.start(); sensorsManuallyStopped = false }
                } label: {
                    Label(motion.isActive ? "Stop" : "Start",
                          systemImage: motion.isActive ? "stop.fill" : "play.fill")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(motion.isActive ? .red : .green)

                Button { motion.resetStats() } label: {
                    Label("Zeruj MAX", systemImage: "arrow.counterclockwise")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)

                Button {
                    motion.startCalibration()
                } label: {
                    Label("Zeruj kąt", systemImage: "scope")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(motion.calibrationCountdown != -1)

            }
            .font(.caption.bold())

            // ── Kalibracja dwupunktowa (garaż ↔ pion) — ustawiana raz, więc zwinięta ──
            DisclosureGroup(isExpanded: $showTwoPointCal) {
                VStack(alignment: .leading, spacing: 8) {
                    // Codzienny 1-klik: moto w pozycji garażowej (nóżka + kierownica max L)
                    Button {
                        motion.calibrateFromGarage()
                    } label: {
                        Label("Kalibruj z garażu", systemImage: "house.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(.purple)
                    .disabled(!motion.hasGarageCal)
                    Text("Codziennie: motocykl na nóżce + kierownica maksymalnie w lewo → 1 klik → po wyprostowaniu idealne zero.")
                        .font(.system(size: 10)).foregroundColor(.secondary)

                    // Pomiary wzorcowe (raz)
                    HStack(spacing: 8) {
                        Button { motion.captureGarageRef() } label: {
                            Label("Zmierz garaż (A)", systemImage: "1.circle")
                                .frame(maxWidth: .infinity).padding(.vertical, 5)
                        }.buttonStyle(.bordered).tint(.purple)
                        Button { motion.captureUprightRef() } label: {
                            Label("Zmierz pion (B)", systemImage: "2.circle")
                                .frame(maxWidth: .infinity).padding(.vertical, 5)
                        }.buttonStyle(.bordered).tint(.purple)
                    }
                    .font(.caption.bold())
                    Button { motion.recomputeCalDelta() } label: {
                        Label("Przelicz różnicę (B − A)", systemImage: "equal.circle")
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                    }.buttonStyle(.bordered).tint(.purple).font(.caption.bold())

                    // 3 zmienne — edytowalne
                    calField("Garaż (A)", $motion.calGarageRaw)
                    calField("Pion (B)",  $motion.calUprightRaw)
                    calField("Różnica Δ", $motion.calDelta)
                }
                .padding(.top, 8)
            } label: {
                Text("Kalibracja dwupunktowa (garaż ↔ pion)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .tint(.secondary)
        }
        .card()
    }

    // Computed helpers dla motionCard
    var gpsStatusColor: Color {
        let a = motion.gpsAccuracy
        if a < 0 { return .gray }
        if a < 20 { return .green }
        if a < 60 { return .yellow }
        return .red
    }

    var gpsStatusText: String {
        guard motion.gpsAccuracy > 0 else { return "Brak GPS" }
        return String(format: "GPS %.0fm", motion.gpsAccuracy)
    }

    var leanCardLabel: String {
        let l = motion.leanAngleDeg
        if l < -1.5 { return "← L" }
        if l >  1.5 { return "R →" }
        return "LEAN"
    }

    /// Edytowalne pole jednej zmiennej kalibracji (w stopniach).
    private func calField(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).frame(width: 96, alignment: .leading)
            TextField("0.0", value: value, format: .number.precision(.fractionLength(1)))
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .frame(maxWidth: .infinity)
            Text("°").font(.caption).foregroundColor(.secondary)
        }
    }

    var leanCardColor: Color {
        let l = motion.leanAngleDeg
        if l < -1.5 { return .blue }
        if l >  1.5 { return .red }
        return .secondary
    }

    var compassLabel: String {
        let d = motion.headingDeg
        guard d >= 0 else { return "—" }
        let dirs = ["N","NE","E","SE","S","SW","W","NW"]
        return dirs[Int((d + 22.5) / 45.0) % 8]
    }

    func motionFmtTime(_ s: Int) -> String {
        let h = s/3600, m = (s%3600)/60, ss = s%60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss)
                     : String(format: "%02d:%02d", m, ss)
    }

    // MARK: — Spotify Card

    var spotifyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardHeader("Spotify", icon: "music.note", tint: .green)
                Spacer()
                // Wskaźnik stanu
                HStack(spacing: 5) {
                    Circle()
                        .fill(spotify.isConnected ? Color.green : Color.gray.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(spotify.statusText)
                        .font(.caption)
                        .foregroundColor(spotify.isConnected ? .green : .secondary)
                        .lineLimit(1)
                }
            }

            if !spotify.isConnected {
                // ── Instrukcja i Client ID ──
                VStack(alignment: .leading, spacing: 6) {
                    Text("Wymaga bezpłatnego Spotify Developer Account:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("1. developer.spotify.com → utwórz app\n2. Redirect URI: wassup-myspin://spotify-callback\n3. Wklej Client ID poniżej")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(6)
                        .background(AppStyle.inset)
                        .cornerRadius(6)

                    HStack(spacing: 8) {
                        TextField("Client ID (32 znaki hex)", text: $spotifyClientID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: spotifyClientID) {
                                spotify.clientID = spotifyClientID
                            }

                        Button {
                            spotify.clientID = spotifyClientID
                            spotify.authenticate()
                        } label: {
                            Text("Połącz")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(spotifyClientID.count < 20)
                    }
                }
            } else {
                // ── Połączony: pokaż co gra ──
                HStack(spacing: 10) {
                    if let art = spotify.artwork {
                        Image(uiImage: art)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .cornerRadius(4)
                            .clipped()
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(.systemGray5))
                            .frame(width: 40, height: 40)
                            .overlay(Image(systemName: "music.note").foregroundColor(.secondary))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if spotify.title.isEmpty {
                            Text("Nic nie gra").font(.caption).foregroundColor(.secondary)
                        } else {
                            Text(spotify.title)
                                .font(.caption.bold())
                                .lineLimit(1)
                            Text(spotify.artist)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button {
                        spotify.disconnect()
                        spotifyClientID = spotify.clientID
                    } label: {
                        Text("Rozłącz")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                // Notice o nowych uprawnieniach (sterowanie joystickiem wymaga modify scope)
                if spotify.statusText.contains("modify") {
                    Text("💡 Rozłącz i połącz ponownie — potrzebne nowe uprawnienie do sterowania odtwarzaniem")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Skąd deska bierze „co gra": system (MR) albo Spotify (SP)
            Group {
                if !nowPlaying.title.isEmpty {
                    Text("🎵 MR: \(nowPlaying.title) — \(nowPlaying.artist)")
                        .foregroundColor(.green)
                } else if !spotify.title.isEmpty {
                    Text("🎵 SP: \(spotify.title) — \(spotify.artist)")
                        .foregroundColor(.cyan)
                } else {
                    Text("🎵 \(nowPlaying.debugInfo)")
                        .foregroundColor(.orange)
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card()
    }

    // MARK: — Screen Card (wybór ekranu wyświetlacza)

    /// Ekrany w kolejności użytkownika (CSV z @AppStorage) + dopięcie nowych na końcu.
    private func orderedScreens() -> [DashboardScreen] { Self.orderedScreens(screenOrderRaw) }

    /// Grający utwór — te same źródła co deska (odtwarzacz systemowy, potem Spotify);
    /// nil, gdy nic nie gra. Do trasy i logu CAN (zapis, jaka piosenka leciała).
    static weak var nowPlayingRef: NowPlayingManager?
    static weak var spotifyRef: SpotifyWebManager?
    static func playingTrack() -> (title: String, artist: String)? {
        if let np = nowPlayingRef, !np.title.isEmpty { return np.isPlaying ? (np.title, np.artist) : nil }
        if let sp = spotifyRef, !sp.title.isEmpty, sp.isPlaying { return (sp.title, sp.artist) }
        return nil
    }
    static func playingTrackLabel() -> String? {
        playingTrack().map { $0.artist.isEmpty ? $0.title : "\($0.artist) — \($0.title)" }
    }

    /// Wspólne z joystickiem (▲▼ idą po tej samej kolejności co pasek ekranów w apce).
    static func orderedScreens(_ csv: String) -> [DashboardScreen] {
        var seen = Set<Int>()
        var raws = csv.split(separator: ",").compactMap { Int($0) }
            .filter { DashboardScreen(rawValue: $0) != nil && seen.insert($0).inserted }
        for s in DashboardScreen.allCases where !raws.contains(s.rawValue) { raws.append(s.rawValue) }
        return raws.compactMap { DashboardScreen(rawValue: $0) }
    }

    var screenCard: some View {
        let screens = orderedScreens()
        return VStack(alignment: .leading, spacing: 8) {
            CardHeader("Ekrany na desce", icon: "rectangle.on.rectangle")

            Toggle(isOn: Binding(get: { isDark }, set: { setDashTheme(dark: $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ciemna deska").font(.subheadline)
                    Text("Wyłącz na pełne słońce — jasne tło, ciemne cyfry")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .tint(AppStyle.accent)

            Toggle(isOn: $ambientBG) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Żywe tło").font(.subheadline)
                    Text("Bardzo wolne, rozmyte plamy koloru w tle ekranów")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .tint(AppStyle.accent)

            Text("Kolejność ekranów: przeciągnij uchwyt ☰ po prawej. Dotknięcie wiersza wybiera ekran.")
                .font(.caption).foregroundColor(.secondary)

            List(selection: Binding<DashboardScreen?>(
                get: { DashboardScreen(rawValue: activeScreen) },
                set: { if let s = $0 { setActiveScreen(s.rawValue) } }
            )) {
                ForEach(screens, id: \.self) { screen in
                    HStack(spacing: 10) {
                        Image(systemName: screen.icon)
                            .frame(width: 22)
                            .foregroundColor(activeScreen == screen.rawValue ? AppStyle.accent : .secondary)
                        Text(screen.title)
                            .font(.system(size: 14, weight: activeScreen == screen.rawValue ? .bold : .regular))
                    }
                    .tag(screen)
                    .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                    .listRowBackground(activeScreen == screen.rawValue
                                       ? AppStyle.accent.opacity(0.14) : AppStyle.inset)
                }
                .onMove { from, to in
                    var raws = screens.map { $0.rawValue }
                    raws.move(fromOffsets: from, toOffset: to)
                    screenOrderRaw = raws.map(String.init).joined(separator: ",")
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .listStyle(.plain)
            .frame(height: CGFloat(screens.count) * 54 + 6)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .tint(AppStyle.accent)
        }
        .card()
    }

    // MARK: — Sudoku Card (nowa gra + trudność)

    var sudokuCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardHeader("Sudoku", icon: "square.grid.3x3")
                Spacer()
                let s = sudoku.display
                if s.generating {
                    Text("Generuję...").font(.caption).foregroundColor(.orange)
                } else if s.solved {
                    Text("Rozwiązane! 🎉").font(.caption.bold()).foregroundColor(.green)
                } else {
                    Text("\(s.filled)/81").font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                }
            }

            // Plansza dnia + online
            HStack(spacing: 6) {
                Button {
                    sudoku.dailyGame()
                } label: {
                    Label("Plansza dnia", systemImage: "calendar")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent).tint(AppStyle.accent)

                Button {
                    sudoku.fetchOnline()
                } label: {
                    Label("Z internetu", systemImage: "globe")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                }
                .buttonStyle(.bordered).tint(.secondary)
            }

            if !sudoku.note.isEmpty {
                Text(sudoku.note).font(.caption).foregroundColor(.orange)
            }

            Text("Losowa plansza lokalna (offline):")
                .font(.caption).foregroundColor(.secondary)

            HStack(spacing: 6) {
                ForEach(SudokuDifficulty.allCases, id: \.self) { diff in
                    Button {
                        sudoku.newGame(diff)
                    } label: {
                        Text(diff.title)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.bordered)
                    .tint(sudoku.difficulty == diff ? AppStyle.accent : .gray)
                }
            }

            Text("Sterowanie joystickiem: d-pad rusza kursorem, OK edytuje komórkę, Góra/Dół zmienia cyfrę, Back wychodzi. Stan zapisuje się automatycznie. Plansza dnia działa offline (ta sama dla wszystkich danego dnia).")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .card()
    }

    // MARK: — Navigation Card (turn-by-turn)

    var navCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardHeader("Nawigacja", icon: "location.north.line.fill")
                Spacer()
                Image(systemName: navManager.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(isOn: $navManager.voiceEnabled) {
                    Text("Zapowiedzi głosowe")
                }
                .labelsHidden().tint(AppStyle.accent)
            }

            if navManager.isActive {
                // Aktywna trasa
                VStack(alignment: .leading, spacing: 4) {
                    Text("→ \(navManager.destinationName)")
                        .font(.subheadline.bold()).lineLimit(1)
                    Text(navManager.nextInstruction)
                        .font(.caption).foregroundColor(.blue).lineLimit(2)
                    Text(String(format: "Pozostało %.1f km · ≈ %d min",
                                navManager.remainingDistance/1000, Int(navManager.remainingTime/60)))
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppStyle.inset).cornerRadius(8)

                Button(role: .destructive) { navManager.stop() } label: {
                    Label("Zakończ nawigację", systemImage: "xmark.circle")
                        .font(.caption.bold()).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered).tint(.red)
            } else {
                // Wyszukiwanie celu
                HStack(spacing: 6) {
                    TextField("Dokąd jedziemy?", text: $navSearchText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { navManager.search(navSearchText, near: motion.lastLocationCoord) }
                    Button {
                        navManager.search(navSearchText, near: motion.lastLocationCoord)
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppStyle.accent)
                }

                // Cel 1:1 z Apple Maps: udostępnij miejsce → Kopiuj → wklej tutaj
                // (krótkie linki maps.apple/p/… NavManager rozwiązuje przez sieć)
                Button {
                    let link = UIPasteboard.general.string ?? ""
                    navManager.navigateToSharedLink(link, name: nil, from: motion.lastLocationCoord)
                } label: {
                    Label("Wklej link z Apple Maps", systemImage: "doc.on.clipboard")
                        .font(.caption.bold()).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered).tint(.secondary)

                if !navManager.statusNote.isEmpty {
                    Text(navManager.statusNote).font(.caption).foregroundColor(.orange)
                }

                ForEach(navManager.searchResults.prefix(5), id: \.self) { item in
                    Button {
                        if let coord = motion.lastLocationCoord {
                            navManager.startNavigation(to: item, from: coord)
                        } else {
                            navManager.statusNote = "Brak GPS — nie mogę policzyć trasy"
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "mappin.circle.fill").foregroundColor(.red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name ?? "—").font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.primary).lineLimit(1)
                                if let loc = item.placemark.title {
                                    Text(loc).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(10)
                        .background(AppStyle.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Text("Mapa działa przez LTE (kafelki + trasa). Głos zapowiada manewry przez słuchawki/interkom.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .card()
    }

    // MARK: — Performance Card (historia pomiarów)

    var perfCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardHeader("Pomiary osiągów", icon: "stopwatch")
                Spacer()
                if !perfMeter.runs.isEmpty {
                    Button { perfMeter.clearRuns() } label: {
                        Image(systemName: "trash").font(.caption)
                    }.tint(.red)
                }
            }

            Text("Zatrzymaj się i rusz — pomiar startuje automatycznie. GPS + akcelerometr telefonu, zero zależności od motocykla.")
                .font(.caption).foregroundColor(.secondary)

            if perfMeter.runs.isEmpty {
                Text("Brak przejazdów. Wybierz ekran Pomiary, wystartuj ze stania.")
                    .font(.caption).foregroundColor(.secondary).padding(.vertical, 6)
            } else {
                ForEach(perfMeter.runs.prefix(6)) { run in
                    HStack(spacing: 8) {
                        Text(perfRunDate(run.date))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 74, alignment: .leading)
                        perfChip("0-100", run.zeroTo100)
                        perfChip("¼mi", run.quarterMile)
                        Spacer()
                        Text("\(Int(run.maxSpeed)) km/h")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan)
                    }
                    .padding(.vertical, 4).padding(.horizontal, 8)
                    .background(AppStyle.inset).cornerRadius(6)
                }
            }
        }
        .card()
    }

    private func perfChip(_ label: String, _ t: Double?) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
            Text(t == nil ? "—" : String(format: "%.2fs", t!))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(t == nil ? .secondary : .green)
        }
    }

    private func perfRunDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "dd.MM HH:mm"; return f.string(from: d)
    }

    // MARK: — Keybindy ekranu (per-ekran mapowanie joysticka)

    /// Etykieta akcji podwójnego kliknięcia na danym ekranie (nil = brak).
    private func doubleActionLabel(_ s: DashboardScreen) -> String? {
        switch joyState.doubleAction(s) {
        case "__calibrate": return "Kalibracja lean"
        case "__exit":      return "Wyjście do klasycznego"
        case "__nextVideo": return "Następny film"
        default:            return nil
        }
    }

    /// Przyjazna nazwa przycisku (Góra/Dół/...) — bez hex.
    private func buttonName(_ keyId: UInt8) -> String {
        if keyId == 0 { return "—" }
        return JoyButton(rawValue: keyId)?.label ?? "Klawisz \(keyId)"
    }

    /// Przypisuje keyId do akcji lub slotu „goto".
    private func assignKey(_ keyId: UInt8, to bindId: String) {
        if bindId.hasPrefix("goto.") {
            let p = bindId.split(separator: ".")
            if p.count == 3, let scr = Int(p[1]), let slot = Int(p[2]) {
                KeyBindings.setGotoKey(keyId, screen: scr, slot: slot)
            }
        } else if bindId.hasPrefix("dbl.") {
            let p = bindId.split(separator: ".")
            if p.count == 2, let scr = Int(p[1]) {
                KeyBindings.setDoubleKey(keyId, screen: scr)
            }
        } else {
            KeyBindings.setActionKey(keyId, actionId: bindId)
        }
        joyState.bindingsRevision &+= 1
    }

    var bindingsCard: some View {
        let scr = DashboardScreen(rawValue: activeScreen) ?? .classic
        let _ = joyState.bindingsRevision   // zależność → odświeżenie po zmianie bindu
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardHeader("Keybindy: \(scr.title)", icon: "gamecontroller.fill")
                Spacer()
                Button { KeyBindings.resetAll(); joyState.bindingsRevision &+= 1 } label: {
                    Text("Reset").font(.caption.bold()).foregroundColor(.red)
                }
            }
            Text("Kliknij przycisk po prawej i wybierz z grafiki joysticka. Zapisuje się od razu, osobno dla każdego ekranu.")
                .font(.caption).foregroundColor(.secondary)

            // Akcje tego ekranu
            ForEach(scr.actions) { action in
                bindingRow(label: action.label,
                           keyId: KeyBindings.key(for: action),
                           bindId: action.id, accent: .blue)
            }

            if let dblLbl = doubleActionLabel(scr) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.tap.fill").font(.caption2).foregroundColor(.orange)
                    Text("2× kliknięcie = \(dblLbl)")
                        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                    bindButton(keyId: KeyBindings.doubleKey(screen: activeScreen),
                               bindId: "dbl.\(activeScreen)", title: "Podwójne kliknięcie", accent: .orange)
                }
                Text("Back na motocyklu wychodzi z mySPIN — nie użyjemy go. Zamiast tego 2× szybko wybrany guzik.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            Divider()
            Text("Przejdź do ekranu (opcjonalne skróty):")
                .font(.caption.bold()).foregroundColor(.secondary)

            ForEach(0..<2, id: \.self) { slot in
                gotoRow(slot: slot)
            }
        }
        .card()
    }

    /// Przycisk pokazujący przypisany klawisz — tap otwiera grafikę wyboru.
    private func bindButton(keyId: UInt8, bindId: String, title: String, accent: Color) -> some View {
        Button {
            pickerBind = BindPick(bind: bindId, title: title)
        } label: {
            HStack(spacing: 5) {
                Text(buttonName(keyId)).font(.system(size: 12, weight: .semibold))
                Image(systemName: "pencil").font(.system(size: 9))
            }
            .foregroundColor(keyId == 0 ? .secondary : accent)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background((keyId == 0 ? Color(.systemGray5) : accent.opacity(0.15)))
            .cornerRadius(7)
        }
        .buttonStyle(.plain)
    }

    private func bindingRow(label: String, keyId: UInt8, bindId: String, accent: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
            bindButton(keyId: keyId, bindId: bindId, title: label, accent: accent)
        }
    }

    private func gotoRow(slot: Int) -> some View {
        let bindId = "goto.\(activeScreen).\(slot)"
        let key = KeyBindings.gotoKey(screen: activeScreen, slot: slot)
        return HStack(spacing: 6) {
            Image(systemName: "arrowshape.turn.up.right.fill")
                .font(.caption2).foregroundColor(.indigo)
            Picker("", selection: Binding(
                get: { KeyBindings.gotoTarget(screen: activeScreen, slot: slot) },
                set: { KeyBindings.setGotoTarget($0, screen: activeScreen, slot: slot); joyState.bindingsRevision &+= 1 }
            )) {
                ForEach(orderedScreens(), id: \.self) { s in
                    Text(s.title).tag(s.rawValue)
                }
            }
            .pickerStyle(.menu).font(.system(size: 11))
            Spacer()
            bindButton(keyId: key, bindId: bindId, title: "Przejdź do ekranu", accent: .indigo)
        }
    }

    // MARK: — Grafika wyboru przycisku joysticka (d-pad)

    private func joyButtonPicker(_ pick: BindPick) -> some View {
        func btn(_ b: JoyButton) -> some View {
            Button {
                assignKey(b.rawValue, to: pick.bind); pickerBind = nil
            } label: {
                Text(b.label)
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 92, height: 48)
                    .background(Color.blue.opacity(0.18))
                    .foregroundColor(.blue)
                    .cornerRadius(12)
            }
        }
        return VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("Wybierz przycisk").font(.headline)
                Text(pick.title).font(.subheadline).foregroundColor(.secondary)
            }
            // Układ jak prawdziwy d-pad
            VStack(spacing: 10) {
                btn(.up)
                HStack(spacing: 10) { btn(.left); btn(.ok); btn(.right) }
                btn(.down)
                btn(.back)
            }
            HStack(spacing: 12) {
                Button("Wyczyść", role: .destructive) {
                    assignKey(0, to: pick.bind); pickerBind = nil
                }
                Button("Anuluj") { pickerBind = nil }
            }
            .font(.callout)
            .padding(.top, 4)
        }
        .padding(24)
    }

    // MARK: — Joystick Card

    // MARK: — Recorder Card

    var recorderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader("Trasa", icon: "record.circle") {
                if recorder.isRecording {
                    HStack(spacing: 6) {
                        Circle().fill(Color.red).frame(width: 8, height: 8)
                        Text(motionFmtTime(recorder.recordingSec))
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                            .foregroundColor(.red)
                    }
                } else if autoRecord {
                    Text("auto")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(AppStyle.inset, in: Capsule())
                }
            }

            if recorder.isRecording {
                HStack(spacing: 0) {
                    StatTile(label: "KM", value: String(format: "%.1f", recorder.currentDistKm))
                    StatTile(label: "MAX KM/H", value: "\(Int(recorder.maxSpeedKmh))")
                    StatTile(label: "MAX L", value: String(format: "%.0f°", recorder.maxLeanLeft), color: .blue)
                    StatTile(label: "MAX P", value: String(format: "%.0f°", recorder.maxLeanRight), color: .red)
                }
                .padding(.vertical, 10)
                .background(AppStyle.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Button {
                if recorder.isRecording {
                    // Stop → pokaż podsumowanie
                    if let summary = recorder.stop() {
                        sessionSummary = summary
                    }
                } else {
                    recorder.start()
                }
            } label: {
                Label(recorder.isRecording ? "Zatrzymaj i podsumuj" : "Nagraj trasę",
                      systemImage: recorder.isRecording ? "stop.fill" : "record.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? Color(.label) : AppStyle.accent)
            .foregroundStyle(recorder.isRecording ? Color(.systemBackground) : .white)

            // ── Tryb pasażera — pełny ekran telefonu jako licznik przechyłu ──
            Button {
                showRiderMode = true
            } label: {
                LinkRow(title: "Licznik przechyłu na cały ekran", icon: "iphone.gen3.radiowaves.left.and.right", tint: .orange)
            }
            .buttonStyle(.plain)

            if !recorder.isRecording {
                Text(autoRecord
                     ? "Trasa zacznie się nagrywać sama po połączeniu z motocyklem."
                     : "Auto-nagrywanie jest wyłączone — trasę startujesz ręcznie.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .card()
    }

    // MARK: — Segments Card (ulubione odcinki)

    /// Znaczek źródła przechyłu w nagłówku deski; nil = mostek wyłączony, znaczka nie ma.
    static func leanSource(enabled: Bool, fromBike: Bool, simulated: Bool) -> LeanSource? {
        guard enabled else { return nil }
        guard fromBike else { return .phone }
        return simulated ? .simulated : .bike
    }

    var bikeLinkCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardHeader("Mostek CAN", icon: "cable.connector")
                Spacer()
                Toggle("", isOn: $bikeLinkOn)
                    .labelsHidden()
                    .tint(AppStyle.accent)
            }
            .onChange(of: bikeLinkOn) { _, on in
                if on { bikeLink.start() } else { bikeLink.stop() }
            }

            if bikeLinkOn {
                HStack(spacing: 8) {
                    Circle()
                        .fill(bikeLink.state == .connected ? Color.green
                              : (bikeLink.state == .searching || bikeLink.state == .connecting ? .orange : .red))
                        .frame(width: 8, height: 8)
                    Text(bikeLink.state.label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let t = bikeLink.live {
                    HStack {
                        bikeStat(t.engineFresh ? "\(t.rpm)" : "—", "OBR/MIN")
                        bikeStat(t.engineFresh ? (t.gear == 0 ? "N" : "\(t.gear)") : "—", "BIEG")
                        bikeStat(t.engineFresh ? "\(t.throttleRaw)" : "—", "GAZ (SUR.)")
                        bikeStat(t.leanFresh ? String(format: "%.1f°", abs(t.leanDeg)) : "—",
                                 t.leanFresh ? (t.leanDeg < -0.5 ? "PRZECHYŁ L" : (t.leanDeg > 0.5 ? "PRZECHYŁ P" : "PRZECHYŁ")) : "PRZECHYŁ")
                    }
                    if t.ext {
                        HStack {
                            bikeStat(t.coolantC.map { String(format: "%.0f°C", $0) } ?? "—", "PŁYN")
                            bikeStat(t.airC.map { String(format: "%.0f°C", $0) } ?? "—", "POWIETRZE")
                            bikeStat(t.rideMode ?? "—", "TRYB")
                            bikeStat(t.traction.map { $0 == 0 ? "OFF" : "\($0)" } ?? "—", "TRAKCJA")
                        }
                    }
                    Text((t.busFps > 0 ? "\(t.busFps) ramek/s na magistrali"
                                       : "Płytka połączona, magistrala milczy (zapłon wyłączony albo nie wpięta)")
                         + (t.fwVersion > 0 ? " · program płytki v\(t.fwVersion)" : ""))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    // Jakość łącza Bluetooth: przy dużych stratach wskazania na desce się spóźniają.
                    if bikeLink.quality.rate > 0 {
                        let ql = bikeLink.quality
                        let bad = ql.lost * 10 > ql.rate || ql.maxGapMs > 150
                        Text("Łącze: \(ql.rate) pakietów/s"
                             + (ql.lost > 0 ? ", zgubione \(ql.lost)" : "")
                             + ", najdłuższa przerwa \(ql.maxGapMs) ms"
                             + (t.connIntervalMs.map { String(format: ", odstęp Bluetooth %.0f ms", $0) } ?? ""))
                            .font(.caption2)
                            .foregroundColor(bad ? .orange : .secondary)
                    }
                    if t.simulated {
                        Label("Płytka nadaje dane testowe — nie wpinaj jej tak w motocykl.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.bold())
                            .foregroundColor(.orange)
                    }
                }

                firmwareUpdateRow
                if bikeLink.diagSupported { diagnosticsRow }

                Toggle(isOn: $bikeLeanOn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Przechył z czujnika motocykla").font(.subheadline)
                        Text(motion.leanFromBike ? "Teraz: czujnik motocykla"
                                                 : "Teraz: telefon (przejmuje sam, gdy płytka milczy)")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                .tint(.red)
                .onChange(of: bikeLeanOn) { _, on in bikeLink.setUseBikeLean(on) }

                Toggle(isOn: $bikeSpeedOn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prędkość z przedniego koła").font(.subheadline)
                        Text(bikeLink.wheelFactor.map {
                                String(format: "Przelicznik potwierdzony GPS-em (%.2f%% względem założenia). Reaguje od razu, działa w tunelu.",
                                       ($0 / WheelSpeedCalibration.expected - 1) * 100)
                             } ?? "Czeka na potwierdzenie z GPS: ok. pół minuty równej jazdy powyżej 30 km/h. Do tego czasu deska pokazuje GPS.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                .tint(.red)
                .onChange(of: bikeSpeedOn) { _, on in bikeLink.setUseWheelSpeed(on) }

                Toggle(isOn: $canRawLog) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Zapis ramek do rozszyfrowania").font(.subheadline)
                        Text(String(format: "Wszystkie ramki + GPS i przechył telefonu, ok. 50 MB na godzinę jazdy. Logi starsze niż 14 dni znikają same. Zajęte: %.0f MB z %.0f.",
                                    Double(bikeLink.logTotalBytes) / 1_048_576,
                                    Double(BikeLinkManager.logQuotaBytes) / 1_048_576))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                .tint(.red)
                .onChange(of: canRawLog) { _, on in bikeLink.setLogging(on) }

                if canRawLog, !bikeLink.logName.isEmpty {
                    Text(String(format: "%@ · %.1f MB · %d ID%@", bikeLink.logName,
                                Double(bikeLink.logBytes) / 1_048_576, bikeLink.logIDs,
                                bikeLink.logLost > 0 ? " · zgubione pakiety: \(bikeLink.logLost)" : ""))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Button {
                    showBusViewer = true
                } label: {
                    LinkRow(title: "Podgląd magistrali na żywo", icon: "waveform.path.ecg")
                }
                .buttonStyle(.plain)

                HStack(spacing: 10) {
                    Button {
                        let files = BikeLinkManager.logFiles()
                        guard !files.isEmpty else { return }
                        let av = UIActivityViewController(activityItems: files, applicationActivities: nil)
                        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                           let root  = scene.windows.first?.rootViewController {
                            var vc = root
                            while let pres = vc.presentedViewController { vc = pres }
                            vc.present(av, animated: true)
                        }
                    } label: {
                        Label("Wyślij logi", systemImage: "square.and.arrow.up")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button("Zapomnij płytkę") { bikeLink.forget() }
                        .font(.caption)
                        .buttonStyle(.bordered)
                }
            }
        }
        .card()
    }

    /// Kody błędów motocykla przez płytkę (OBD). Odczyt nic nie zmienia; kasowanie po potwierdzeniu.
    private var diagnosticsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("KODY BŁĘDÓW (FI)").font(.caption2.bold()).foregroundColor(.secondary)
            HStack(spacing: 8) {
                Button {
                    bikeLink.runDiagnostic(.probe)
                } label: {
                    Label("Odczytaj", systemImage: "magnifyingglass").font(.subheadline.bold())
                }
                .buttonStyle(.bordered)
                Button(role: .destructive) {
                    showClearCodes = true
                } label: {
                    Label("Skasuj kody", systemImage: "trash").font(.subheadline.bold())
                }
                .buttonStyle(.bordered)
                .disabled(bikeLink.diagClearAddr == nil)
                Spacer()
            }
            .disabled(diagBusy)
            .confirmationDialog("Skasować kody błędów i lampkę FI?", isPresented: $showClearCodes, titleVisibility: .visible) {
                Button("Skasuj kody", role: .destructive) {
                    if let addr = bikeLink.diagClearAddr { bikeLink.runDiagnostic(.clear, addr: addr) }
                }
                Button("Anuluj", role: .cancel) {}
            } message: {
                Text("Zapłon włączony, silnik ZGASZONY, motocykl stoi. Płytka na kilka sekund zacznie nadawać na szynę, potem wraca do samego nasłuchu. Jeśli usterka nadal jest, kod i lampka wrócą.")
            }
            switch bikeLink.diagState {
            case .idle:
                Text(bikeLink.diagClearAddr == nil
                     ? "Zapłon włączony, silnik zgaszony. Odczyt niczego nie zmienia; kasowanie odblokuje się, gdy motocykl odpowie kodami."
                     : "Zapłon włączony, silnik zgaszony. Odczyt niczego nie zmienia.")
                    .font(.caption2).foregroundColor(.secondary)
            case .running(let op):
                HStack(spacing: 6) {
                    ProgressView()
                    Text(op == .clear ? "Kasuję kody…" : "Pytam sterowniki…").font(.caption)
                }
            case .finished(let op, let replies, let tx):
                VStack(alignment: .leading, spacing: 4) {
                    if !replies.contains(where: \.isObd) {
                        Text("Żaden sterownik nie odpowiedział na OBD.").font(.caption).foregroundColor(.orange)
                    }
                    ForEach(replies.indices, id: \.self) { i in
                        let r = replies[i]
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Obd.ecuName(r.ecu, ext: r.ext)).font(.caption.bold())
                            Text(Obd.summary(op, r)).font(.caption.monospaced())
                        }
                    }
                    Text("Zapytań wysłanych \(tx.sent), bez potwierdzenia \(tx.failed), licznik błędów nadawania \(tx.errorCounter)")
                        .font(.caption2).foregroundColor(tx.failed > 0 || tx.sent == 0 ? .orange : .secondary)
                    Button("OK") { bikeLink.clearDiagnosticResult() }.font(.caption)
                }
            case .failed(let msg):
                VStack(alignment: .leading, spacing: 4) {
                    Text(msg).font(.caption).foregroundColor(.orange)
                    Button("OK") { bikeLink.clearDiagnosticResult() }.font(.caption)
                }
            }
        }
        .padding(.top, 4)
    }

    private var diagBusy: Bool {
        if case .running = bikeLink.diagState { return true }
        return false
    }

    /// Aktualizacja programu płytki przez Bluetooth: przycisk, postęp i wynik.
    /// Osobno od liczb na żywo, bo w trakcie restartu płytki tamte znikają.
    @ViewBuilder
    private var firmwareUpdateRow: some View {
        let target = BikeLinkManager.currentFirmware
        switch bikeLink.updateState {
        case .idle:
            if let t = bikeLink.live, !t.simulated, t.fwVersion < target {
                if bikeLink.updateSupported, FirmwareImage.bundled != nil {
                    let running = t.engineFresh && t.rpm > 0
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            bikeLink.startFirmwareUpdate()
                        } label: {
                            Label("Zaktualizuj płytkę do v\(target)", systemImage: "arrow.down.circle.fill")
                                .font(.subheadline.bold())
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppStyle.accent)
                        .disabled(running)
                        Text(running ? "Zgaś silnik — płytka przyjmuje nowy program tylko na postoju."
                                     : "Trwa ok. minuty. Trzymaj telefon przy motocyklu i nie wyłączaj zapłonu.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                } else {
                    Text("Jest nowszy program płytki (v\(target)). Ta wersja płytki nie umie jeszcze aktualizacji przez Bluetooth — raz trzeba wgrać kablem: make fw-flash")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        case .starting:
            firmwareProgress(nil, "Łączę się z płytką…")
        case .sending(let p):
            firmwareProgress(p, String(format: "Wysyłam program: %.0f%%", p * 100))
        case .verifying:
            firmwareProgress(1, "Płytka sprawdza podpis…")
        case .restarting:
            firmwareProgress(nil, "Płytka uruchamia nowy program…")
        case .done(let v):
            HStack {
                Label("Płytka zaktualizowana do v\(v)", systemImage: "checkmark.circle.fill")
                    .font(.caption.bold()).foregroundColor(.green)
                Spacer()
                Button("OK") { bikeLink.clearUpdateResult() }.font(.caption)
            }
        case .failed(let why):
            VStack(alignment: .leading, spacing: 6) {
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.bold()).foregroundColor(.orange)
                Button("OK") { bikeLink.clearUpdateResult() }.font(.caption)
            }
        }
    }

    private func firmwareProgress(_ value: Double?, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let value { ProgressView(value: value).tint(AppStyle.accent) } else { ProgressView().tint(AppStyle.accent) }
            HStack {
                Text(text).font(.caption2).foregroundColor(.secondary)
                Spacer()
                if case .sending = bikeLink.updateState {
                    Button("Przerwij") { bikeLink.cancelFirmwareUpdate() }.font(.caption2)
                }
            }
        }
    }

    private func bikeStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.headline, design: .monospaced))
            Text(label).font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    var segmentsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardHeader("Odcinki", icon: "flag.checkered")
                Spacer()
                Text("\(segments.segments.count)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(AppStyle.inset)
                    .cornerRadius(6)
            }

            SegmentRecorderControl(manager: segments) { if !motion.isActive { motion.start() } }

            if !segments.liveText.isEmpty, !segments.isRecording {
                Text(segments.liveText)
                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .foregroundColor(.green)
            }

            Button {
                showSegments = true
            } label: {
                LinkRow(title: "Wszystkie odcinki i przejazdy", icon: "list.bullet")
            }
            .buttonStyle(.plain)
        }
        .card()
    }

    /// Pigułki paska informacyjnego deski, w kolejności ważności: odcinek, potem
    /// pogoda. Statyczna, bo woła ją też dostawca klatek z wątku tła — stąd
    /// odczyt przez migawki pod blokadą, a nie wprost z @Published.
    static func dashChips(segments: SegmentManager?, weather: WeatherManager?,
                          navRemaining: Double, headingDeg: Double) -> [DashChip] {
        var out: [DashChip] = []
        if let c = segments?.chipSnapshot() { out.append(c) }
        if let a = weather?.aheadSnapshot() {
            out += a.chips(now: Date(), navRemaining: navRemaining, headingDeg: headingDeg)
        }
        return out
    }

    // MARK: — Library Card (zapisane sesje)

    var libraryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardHeader("Biblioteka tras", icon: "books.vertical", tint: .purple)
                Spacer()
                Text("\(storage.library.count)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(AppStyle.inset)
                    .cornerRadius(6)
            }

            if storage.library.isEmpty {
                Text("Brak nagranych tras. Każda nagrana trasa pojawi się tutaj.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                // Pokaż 2 najnowsze sesje + przycisk zobacz wszystkie
                ForEach(storage.library.prefix(2)) { meta in
                    Button {
                        if let s = storage.load(id: meta.id) {
                            replay.load(s)
                            replay.play()
                            showPlayer = true
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                                .foregroundColor(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(libRowTitle(meta))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text(libRowSubtitle(meta))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(10)
                        .background(AppStyle.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                showLibrary = true
            } label: {
                LinkRow(title: "Wszystkie zapisane trasy", icon: "list.bullet", tint: .purple)
            }
            .buttonStyle(.plain)
        }
        .card()
    }

    private func libRowTitle(_ m: SessionMeta) -> String {
        let f = DateFormatter(); f.dateFormat = "dd.MM HH:mm"
        return "\(f.string(from: m.startTime)) · \(motionFmtTime(m.durationSec))"
    }

    private func libRowSubtitle(_ m: SessionMeta) -> String {
        String(format: "%.1f km · max %d km/h · L%.0f° R%.0f°",
               m.totalDistKm, Int(m.maxSpeedKmh), m.maxLeanLeft, m.maxLeanRight)
    }

    // MARK: — Ekran główny: podgląd deski, stan połączeń, dane na żywo

    /// Nagłówek aplikacji: znak, nazwa, wersja z ważnością podpisu i wejście do ustawień.
    /// Wersja zostaje na widoku — po niej widać, która kompilacja jest na telefonie.
    var appHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "motorcycle.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(
                    LinearGradient(colors: [Color(red: 1.0, green: 0.30, blue: 0.26), AppStyle.accent,
                                            Color(red: 0.55, green: 0.03, blue: 0.10)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: AppStyle.accent.opacity(0.35), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text("SpinMyCan")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                HStack(spacing: 6) {
                    Text(Self.appVersion)
                    if let exp = ProvisioningInfo.shortLabel {
                        Text("·")
                        Text("podpis \(exp)")
                            .foregroundStyle(ProvisioningInfo.isExpiringSoon ? Color.red : Color.secondary)
                    }
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button { openSettings() } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(AppStyle.cardBackground, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    /// Podgląd tego, co widać (albo będzie widać) na wyświetlaczu motocykla.
    var heroCard: some View {
        VStack(spacing: 10) {
            ZStack {
                Color.black
                if let img = dashboardImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(864.0 / 320.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 6) {
                Circle()
                    .fill(session.tcpState.isConnected ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(session.tcpState.isConnected
                     ? "Na wyświetlaczu motocykla · \(session.framesSent) klatek"
                     : "Podgląd — tak będzie wyglądać deska")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    setDashTheme(dark: !isDark)
                } label: {
                    Image(systemName: isDark ? "sun.max.fill" : "moon.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isDark ? .yellow : .indigo)
                        .frame(width: 32, height: 28)
                        .background(AppStyle.inset, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
        }
        .card(padding: 10)
    }

    private func setDashTheme(dark: Bool) {
        isDark = dark
        renderer.isDarkMode = dark
        renderDashboardPreview()   // natychmiast, bez czekania na timer
    }

    private func openSettings(at anchor: String? = nil) {
        settingsAnchor = anchor
        showSettings = true
    }

    /// Połączenie z wyświetlaczem motocykla jednym zdaniem (szczegóły w diagnostyce).
    private var bikeStatus: (text: String, color: Color) {
        switch session.tcpState {
        case .connected:                return ("Obraz leci", .green)
        case .connecting, .handshaking: return ("Łączę…", .yellow)
        default:                        break
        }
        if bt.state.isActive { return ("Bluetooth OK", .yellow) }
        if case .failed = bt.state { return ("Błąd Bluetooth", .red) }
        return ("Niepołączony", .gray)
    }

    private var canStatus: (text: String, color: Color) {
        guard bikeLinkOn else { return ("Wyłączony", .gray) }
        switch bikeLink.state {
        case .connected:
            if bikeLink.live?.simulated == true { return ("Symulacja", .orange) }
            return ((bikeLink.live?.busFps ?? 0) > 0 ? "Dane płyną" : "Połączony", .green)
        case .connecting:        return ("Łączę…", .yellow)
        case .searching:         return ("Czeka na zapłon", .gray)
        case .bluetoothOff:      return ("Bluetooth wył.", .red)
        case .unauthorized:      return ("Brak zgody", .red)
        case .unsupported, .off: return ("Niedostępny", .gray)
        }
    }

    /// Trzy pigułki: wyświetlacz motocykla, mostek CAN, GPS. Tapnięcie otwiera szczegóły.
    var statusPills: some View {
        HStack(spacing: 8) {
            Button { openSettings(at: "bt") } label: {
                StatusPill(icon: "display", title: "DESKA", value: bikeStatus.text, color: bikeStatus.color)
            }
            Button { openSettings(at: "can") } label: {
                StatusPill(icon: "cable.connector", title: "CAN", value: canStatus.text, color: canStatus.color)
            }
            Button { openSettings(at: "sensors") } label: {
                StatusPill(icon: "location.fill", title: "GPS",
                           value: motion.gpsAccuracy > 0 ? String(format: "±%.0f m", motion.gpsAccuracy) : "Brak sygnału",
                           color: gpsStatusColor)
            }
        }
        .buttonStyle(.plain)
    }

    /// Motocykl podał swoją sieć WiFi, a obraz jeszcze nie leci — trzeba do niej dołączyć.
    var wifiHintCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader("Dołącz do WiFi motocykla", icon: "wifi", tint: .green)
            Text("Motocykl czeka w sieci \(wifiSSID ?? ""). Hasło skopiuję do schowka — wybierz tę sieć w ustawieniach i wklej.")
                .font(.caption).foregroundColor(.secondary)
            Button {
                if let pw = wifiPassword {
                    UIPasteboard.general.string = pw
                    wifiConnectStatus = "✅ Hasło w schowku — wybierz \(wifiSSID ?? "") i wklej"
                }
                if let url = URL(string: "App-Prefs:root=WIFI"),
                   UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url)
                } else if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Otwórz ustawienia WiFi", systemImage: "wifi.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .card()
    }

    /// Skąd idzie przechył — mały znaczek w nagłówku „Na żywo" (jak na desce).
    @ViewBuilder private var leanSourceBadge: some View {
        if let src = Self.leanSource(enabled: bikeLinkOn, fromBike: motion.leanFromBike,
                                     simulated: bikeLink.live?.simulated == true) {
            let (text, color): (String, Color) = src == .bike ? ("CAN", .green)
                : (src == .simulated ? ("SIM", .orange) : ("TELEFON", .secondary))
            Text(text)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(color.opacity(0.14), in: Capsule())
        }
    }

    /// Prędkość, przechył, bieg i rekordy — to, na co patrzy się najczęściej.
    var liveCard: some View {
        let lean = motion.leanAngleDeg
        let engine = bikeLink.live.flatMap { $0.engineFresh ? $0 : nil }
        return VStack(alignment: .leading, spacing: 14) {
            CardHeader("Na żywo", icon: "speedometer") {
                leanSourceBadge
                Button { motion.resetStats() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 28)
                        .background(AppStyle.inset, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                StatTile(label: "KM/H", value: "\(Int(motion.speedKmh))", big: true)
                Divider().frame(height: 44)
                StatTile(label: lean < -1.5 ? "PRZECHYŁ W LEWO" : (lean > 1.5 ? "PRZECHYŁ W PRAWO" : "PRZECHYŁ"),
                         value: String(format: "%.0f°", abs(lean)), color: leanCardColor, big: true)
                if let e = engine {
                    Divider().frame(height: 44)
                    StatTile(label: "\(e.rpm) OBR/MIN", value: e.gear == 0 ? "N" : "\(e.gear)",
                             color: e.gear == 0 ? .green : .primary, big: true)
                }
            }

            HStack(spacing: 0) {
                StatTile(label: "MAX KM/H", value: "\(Int(motion.maxSpeedKmh))")
                StatTile(label: "MAX L", value: String(format: "%.0f°", motion.maxLeanLeft), color: .blue)
                StatTile(label: "MAX P", value: String(format: "%.0f°", motion.maxLeanRight), color: .red)
                StatTile(label: "PRZECIĄŻENIE", value: String(format: "%.1f", motion.gForce), unit: "g",
                         color: motion.gForce > 1.0 ? .orange : .primary)
            }
            .padding(.vertical, 10)
            .background(AppStyle.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            // Zero przechyłu ustawia się tylko dla telefonu — czujnik motocykla go nie potrzebuje.
            if !motion.leanFromBike {
                HStack(spacing: 8) {
                    Button {
                        motion.startCalibration()
                    } label: {
                        Label(motion.calibrationCountdown >= 0 ? "Zero za \(motion.calibrationCountdown) s"
                              : (motion.calibrationCountdown == -2 ? "Skalibrowano" : "Wyzeruj przechył"),
                              systemImage: motion.calibrationCountdown == -2 ? "checkmark" : "scope")
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .disabled(motion.calibrationCountdown != -1)

                    if motion.hasGarageCal {
                        Button {
                            motion.calibrateFromGarage()
                        } label: {
                            Label("Zero z garażu", systemImage: "house.fill")
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .font(.caption.weight(.semibold))
                .tint(.secondary)
            }
        }
        .card()
    }

    private func screenShortTitle(_ s: DashboardScreen) -> String {
        switch s {
        case .classic:     return "Klasyczny"
        case .lean:        return "Przechył"
        case .snake:       return "Snake"
        case .sudoku:      return "Sudoku"
        case .navigation:  return "Nawigacja"
        case .performance: return "Pomiary"
        case .video:       return "Wideo"
        case .navClassic:  return "Mapa + deska"
        case .disco:       return "Disco"
        case .memories:    return "Wspomnienia"
        case .hacker:      return "Terminal"
        }
    }

    /// Szybki wybór ekranu deski — poziomy pasek w kolejności ustawionej w ustawieniach.
    var screenStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader("Ekran na desce", icon: "rectangle.on.rectangle") {
                Button { openSettings(at: "display") } label: {
                    Text("Kolejność")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(orderedScreens(), id: \.self) { screen in
                            let on = activeScreen == screen.rawValue
                            Button { setActiveScreen(screen.rawValue) } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: screen.icon)
                                        .font(.system(size: 18, weight: .semibold))
                                    Text(screenShortTitle(screen))
                                        .font(.system(size: 11, weight: .semibold))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                                .frame(width: 92, height: 64)
                                .foregroundStyle(on ? Color.white : Color.primary)
                                .background(on ? AnyShapeStyle(AppStyle.accent.gradient) : AnyShapeStyle(AppStyle.inset),
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .id(screen)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)   // pasek od krawędzi do krawędzi karty
                .onAppear { proxy.scrollTo(DashboardScreen(rawValue: activeScreen), anchor: .center) }
                .onChange(of: activeScreen) { _, new in
                    withAnimation { proxy.scrollTo(DashboardScreen(rawValue: new), anchor: .center) }
                }
            }
        }
        .card()
    }

    /// Co teraz gra (system albo Spotify) — tylko gdy coś gra.
    @ViewBuilder var musicCard: some View {
        let useSpotify = nowPlaying.title.isEmpty && !spotify.title.isEmpty
        let title = useSpotify ? spotify.title : nowPlaying.title
        let artist = useSpotify ? spotify.artist : nowPlaying.artist
        let art = useSpotify ? spotify.artwork : nowPlaying.artwork
        if !title.isEmpty {
            HStack(spacing: 12) {
                Group {
                    if let art {
                        Image(uiImage: art).resizable().scaledToFill()
                    } else {
                        ZStack {
                            AppStyle.inset
                            Image(systemName: "music.note").foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "waveform")
                    .foregroundStyle(.green)
            }
            .card(padding: 12)
        }
    }

    // MARK: — Ustawienia i diagnostyka (arkusz)

    private var settingsSheet: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 14) {
                        SectionTitle("Deska na motocyklu")
                        screenCard.id("display")
                        bindingsCard.id("keys")

                        SectionTitle("Jazda")
                        recordingOptionsCard.id("recording")
                        RouteCloudCard().id("cloud")
                        sensorsCard.id("sensors")

                        SectionTitle("Dane z motocykla")
                        bikeLinkCard.id("can")

                        SectionTitle("Muzyka")
                        spotifyCard.id("spotify")

                        SectionTitle("Diagnostyka połączenia")
                        btCard.id("bt")
                        tcpCard.id("tcp")

                        SectionTitle("Aplikacja")
                        liveActivityCard.id("island")
                        aboutCard.id("about")
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
                .background(AppStyle.pageBackground)
                .onAppear {
                    guard let anchor = settingsAnchor else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        withAnimation { proxy.scrollTo(anchor, anchor: .top) }
                    }
                }
            }
            .navigationTitle("Ustawienia")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BackButton { showSettings = false }
                }
            }
            .fullScreenCover(item: $pickerBind) { pick in joyButtonPicker(pick) }
            .fullScreenCover(isPresented: $showBusViewer) {
                BusViewerView(link: bikeLink, loggingOn: canRawLog, phoneLean: motion.phoneLeanDeg)
            }
        }
    }

    /// Stan jazdy dla Live Activity — te same źródła co deska (CAN, gdy płynie; inaczej telefon).
    private func updateLiveActivity() {
        let snap = bikeLink.snapshot()
        let can = snap.map { $0.engineFresh && !$0.simulated } ?? false
        let records = motion.liveMax
        let state = RideActivityAttributes.ContentState(
            speedKmh: Int((bikeLink.wheelSpeedKmh() ?? max(0, motion.speedKmh)).rounded()),
            gear: can && snap?.gearInTransit == false ? snap?.gear : nil,
            rpm: can ? snap?.rpm : nil,
            coolantC: snap?.coolantC.map { Int($0.rounded()) },
            leanDeg: Int((bikeLink.leanDeg() ?? motion.liveLeanDeg).rounded()),
            maxLeft: Int(records.left.rounded()),
            maxRight: Int(records.right.rounded()),
            dashConnected: session.tcpState.isConnected,
            canConnected: can)
        RideLiveActivityManager.shared.sync(enabled: liveActivityOn, state: state)
    }

    private var liveActivityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader("Dynamic Island", icon: "capsule.fill", tint: .orange) {
                Toggle("", isOn: $liveActivityOn).labelsHidden()
            }
            Text("Logo apki i prędkość w wyspie, a po rozwinięciu i na ekranie blokady bieg, obroty, płyn, przechył i stan deski. Pojawia się po otwarciu apki.")
                .font(.caption).foregroundColor(.secondary)
            if let err = RideLiveActivityManager.shared.lastError {
                Text("iOS nie pozwolił: \(err)").font(.caption2).foregroundColor(.orange)
            }
        }
        .card()
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader("SpinMyCan", icon: "info.circle.fill", tint: .gray) {
                Text(Self.appVersion)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let exp = ProvisioningInfo.shortLabel {
                HStack {
                    Text("Podpis aplikacji ważny jeszcze").font(.subheadline)
                    Spacer()
                    Text(exp)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(ProvisioningInfo.isExpiringSoon ? .red : .secondary)
                }
                Text("Darmowe konto Apple podpisuje apkę na 7 dni. Odświeżenie na Macu: make refresh")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .card()
    }

    // MARK: — Render podglądu dashboardu    // MARK: — Render podglądu dashboardu

    private func renderDashboardPreview() {
        // GDY TRANSMISJA ISTNIEJE: podgląd = dokładnie ta sama klatka JPEG, którą
        // dostaje wyświetlacz motocykla. Zero rozjazdu render-w-apce ↔ ekran.
        if session.tcpState.isConnected, let f = session.lastSentFrame, let img = UIImage(data: f) {
            dashboardImage = img
            return
        }
        // Brak transmisji → renderujemy lokalnie (ten sam kod co frameProvider).
        // Ekran wideo offline — podgląd z VideoFrameProvider
        if activeScreen == DashboardScreen.video.rawValue {
            if let f = videoProvider.currentFrame(), let img = UIImage(data: f) {
                dashboardImage = img
                return
            }
        }
        renderer.isDarkMode   = isDark
        renderer.ambientEnabled = ambientBG
        // Prędkość z przedniego koła, gdy mostek ją podaje i GPS potwierdził przelicznik.
        renderer.speedKmh     = bikeLink.wheelSpeedKmh() ?? motion.speedKmh
        renderer.maxSpeedKmh  = motion.maxSpeedKmh
        renderer.avgSpeedKmh  = motion.avgSpeedKmh
        renderer.recordingActive = recorder.isRecording
        renderer.sunsetString = motion.sunsetString
        renderer.leanAngleDeg = motion.leanAngleDeg
        renderer.maxLeanLeft  = motion.maxLeanLeft
        renderer.maxLeanRight = motion.maxLeanRight
        renderer.gForce       = motion.gForce
        renderer.maxGforce    = motion.maxGforce
        renderer.headingDeg   = motion.headingDeg
        renderer.altitudeM    = motion.altitudeM
        renderer.tripDistKm   = motion.tripDistKm
        renderer.gpsAccuracy  = motion.gpsAccuracy
        renderer.sessionSec   = motion.sessionSec
        renderer.temperatureC = weather.temperatureC
        renderer.infoChips    = Self.dashChips(segments: segments, weather: weather,
                                               navRemaining: navManager.remainingDistance,
                                               headingDeg: motion.headingDeg)
        renderer.bike         = bikeLink.snapshot()
        if activeScreen == DashboardScreen.hacker.rawValue {
            let feed = bikeLink.hackerFeed()
            renderer.hackerLines = feed.lines
            renderer.hackerTable = feed.table
        }
        renderer.suspTravel   = bikeLink.suspensionTravel()
        renderer.leanSource   = Self.leanSource(enabled: bikeLinkOn, fromBike: motion.leanFromBike,
                                                simulated: renderer.bike?.simulated == true)
        // Now Playing: system (MR/MP) ma priorytet, fallback → Spotify Web API
        let useSpotify = nowPlaying.title.isEmpty && !spotify.title.isEmpty
        renderer.npTitle     = useSpotify ? spotify.title          : nowPlaying.title
        renderer.npArtist    = useSpotify ? spotify.artist         : nowPlaying.artist
        renderer.npArtwork   = useSpotify ? spotify.artwork        : nowPlaying.artwork
        renderer.npElapsed   = useSpotify ? spotify.currentElapsed : nowPlaying.currentElapsed
        renderer.npDuration  = useSpotify ? spotify.duration       : nowPlaying.duration
        renderer.npIsPlaying           = useSpotify ? spotify.isPlaying      : nowPlaying.isPlaying
        renderer.calibrationCountdown  = motion.calibrationCountdown
        renderer.activeScreen   = activeScreen
        renderer.snakeSnapshot  = snakeGame.snapshot()
        renderer.sudokuSnapshot = sudoku.snapshot()
        renderer.mapImage       = mapSnap.mapImage
        renderer.perfSnapshot   = perfMeter.snapshot()
        renderer.navActive            = navManager.isActive
        renderer.navInstruction       = navManager.nextInstruction
        renderer.navDistanceToNext    = navManager.distanceToNext
        renderer.navRemainingDistance = navManager.remainingDistance
        renderer.navRemainingTime     = navManager.remainingTime
        // Disco: karaoke lyrics (podgląd w apce)
        if activeScreen == DashboardScreen.disco.rawValue {
            lyrics.update(title: renderer.npTitle, artist: renderer.npArtist, duration: renderer.npDuration)
            let snap = lyrics.snapshot()
            renderer.lyricsLines  = snap.lines
            renderer.lyricsStatus = snap.status
        }
        // Wspomnienia: bieżące/poprzednie zdjęcie (podgląd w apce)
        if activeScreen == DashboardScreen.memories.rawValue {
            let ms = memories.snapshot()
            renderer.memCurrent = ms.current; renderer.memPrevious = ms.previous
            renderer.memSwitchAt = ms.switchAt; renderer.memCaption = ms.caption; renderer.memStatus = ms.status
        }
        dashboardImage = renderer.renderImage()
    }

    // MARK: — Ekrany dashboardu

    /// Ustawia aktywny ekran + zarządza cyklem życia gry Snake i mapy.
    private func setActiveScreen(_ idx: Int) {
        activeScreen = idx
        if idx == DashboardScreen.snake.rawValue { snakeGame.start() } else { snakeGame.stop() }
        // Mapa aktywna na ekranie „Nawigacja" ORAZ „Nawigacja + deska"
        if idx == DashboardScreen.navigation.rawValue || idx == DashboardScreen.navClassic.rawValue {
            lastNavScreen = idx   // udostępniony cel wróci na ten ekran
            mapSnap.dark = isDark
            mapSnap.start()
        } else {
            mapSnap.stop()
        }
        // Ekran wideo: odtwarzanie tylko gdy wybrany. Klatki idą zwykłą drogą (na prośbę motocykla).
        if idx == DashboardScreen.video.rawValue {
            videoProvider.start()
        } else {
            videoProvider.stop()
        }
        // Terminal CAN: surowe ramki z płytki tylko, gdy ekran wybrany.
        bikeLink.setHackerActive(idx == DashboardScreen.hacker.rawValue)
        // Wspomnienia: ładuj zdjęcia tylko gdy ekran aktywny (oszczędza pamięć/sieć).
        if idx == DashboardScreen.memories.rawValue { memories.start() } else { memories.stop() }
        renderDashboardPreview()   // natychmiastowy refresh podglądu
    }

    // MARK: — Background task

    private func startBackgroundTask() {
        guard bgTaskID == .invalid else { return }
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "MySpin.FrameSend") {
            // Expiry handler — iOS daje zazwyczaj ~30s, ale z location mode działa dłużej
            self.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard bgTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskID)
        bgTaskID = .invalid
    }

    // MARK: — Setup

    /// Jednorazowo (v1.16.1): sprząta po teście YouTube z 25.10 (YouTubeProbe, usunięty) —
    /// klatki testowe i pamięć podręczna przeglądarki z filmem (~40 MB). Apka nie używa
    /// WKWebView (logowanie Spotify idzie przez ASWebAuthenticationSession, osobny magazyn).
    private func removeYouTubeTestLeftovers() {
        let key = "cleanup.youtubeProbe"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for url in [docs.appendingPathComponent("yttest"),
                    caches.appendingPathComponent("WebKit"),
                    fm.temporaryDirectory.appendingPathComponent("WebKit")] {
            try? fm.removeItem(at: url)
        }
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                modifiedSince: .distantPast) {
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    private func setup() {
        guard !didSetup else { return }   // idempotentnie — chroni przed over-resume timera
        didSetup = true
        removeYouTubeTestLeftovers()
        bikeLink.pruneOldLogs()
        KeyBindings.clearShortcutsOnce()
        RouteCloudSync.shared.sync()
        #if DEBUG
        if ProcessInfo.processInfo.environment["DISCO_SHOT"] != nil {
            let forceLight = ProcessInfo.processInfo.environment["DISCO_LIGHT"] != nil
            FrameRenderer.debugWriteDiscoShot(dark: forceLight ? false : isDark)
        }
        if ProcessInfo.processInfo.environment["CLASSIC_SHOT"] != nil {
            FrameRenderer.debugWriteClassicShot(dark: isDark)
        }
        if ProcessInfo.processInfo.environment["BLOCK_SHOT"] != nil {
            FrameRenderer.debugWriteBlockShots()
        }
        if ProcessInfo.processInfo.environment["FEATURE_TEST"] != nil {
            FeatureSelfTest.run()
        }
        if let path = ProcessInfo.processInfo.environment["VIDEO_IMPORT"],
           let copy = try? PickedMovie.copyToTemp(URL(fileURLWithPath: path)) {
            // Przeróbka filmu jak z Galerii (test w symulatorze).
            videoProvider.importVideo(from: copy, title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
        }
        if ProcessInfo.processInfo.environment["BUS_UI"] != nil {
            bikeLink.debugSeedBus()
            // Podgląd magistrali otwiera się z ustawień, więc najpierw one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { openSettings(at: "can") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { showBusViewer = true }
        }
        if let anchor = ProcessInfo.processInfo.environment["SETTINGS_UI"] {
            if ProcessInfo.processInfo.environment["UI_DEMO"] != nil { bikeLink.debugSeedBus() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { openSettings(at: anchor.isEmpty ? nil : anchor) }
        }
        if ProcessInfo.processInfo.environment["UI_DEMO"] != nil {
            // Dane pokazowe do zrzutów ekranu głównego w symulatorze.
            bikeLink.debugSeedBus()
            motion.maxLeanLeft = 38; motion.maxLeanRight = 41; motion.maxSpeedKmh = 164
            if segments.segments.isEmpty { FeatureSelfTest.seed(segments) }
        }
        if ProcessInfo.processInfo.environment["SEGMENTS_UI"] != nil {
            if segments.segments.isEmpty { FeatureSelfTest.seed(segments) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showSegments = true }
        }
        if ProcessInfo.processInfo.environment["RIDER_MODE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                showRiderMode = true
                // Symulator nie ma IMU — wstrzykujemy rekordy, żeby dało się
                // sprawdzić kropki MAX na łuku.
                if ProcessInfo.processInfo.environment["RIDER_FAKE"] != nil {
                    motion.maxLeanLeft = 38
                    motion.maxLeanRight = 47
                    motion.maxSpeedKmh = 164
                }
            }
        }
        if ProcessInfo.processInfo.environment["SHARE_UI"] != nil {
            // Konfigurator plakatu na trasie pokazowej.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { SessionShareHelper.shareScreenshot(FeatureSelfTest.demoRide()) }
        }
        if ProcessInfo.processInfo.environment["RIDE_UI"] != nil {
            // Widok trasy jak po „Zakończ trasę” (trasa pokazowa z silnikiem i piosenkami).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { sessionSummary = FeatureSelfTest.demoRide() }
        }
        if ProcessInfo.processInfo.environment["SHARE_SHOT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                // Bez tras w bibliotece (czysty symulator) — trasa pokazowa z silnikiem i piosenkami.
                let s = storage.library.first.flatMap { storage.load(id: $0.id) } ?? FeatureSelfTest.demoRide()
                SessionShareHelper.debugRenderShare(s, name: "share_1day.png", options: ShareOptions())
                var all = ShareOptions()
                all.songsOnMap = true; all.songList = true
                SessionShareHelper.debugRenderShare(s, name: "share_full.png", options: all)
                all.gearsPie = true
                SessionShareHelper.debugRenderShare(s, name: "share_pie.png", options: all)
                all.gearsPie = false
                all.format = .post
                SessionShareHelper.debugRenderShare(s, name: "share_post.png", options: all)
                // Wariant wielodniowy — test zakresu dat (trasa 14→16 sierpnia)
                var multi = s
                let cal = Calendar.current
                if let newEnd = cal.date(byAdding: .day, value: 2, to: s.endTime) {
                    multi = SessionSummary(
                        id: UUID(), startTime: s.startTime, endTime: newEnd,
                        totalDistKm: s.totalDistKm, maxSpeedKmh: s.maxSpeedKmh,
                        avgSpeedKmh: s.avgSpeedKmh, maxLeanLeft: s.maxLeanLeft,
                        maxLeanRight: s.maxLeanRight, maxGforce: s.maxGforce, points: s.points)
                    SessionShareHelper.debugRenderShare(multi, name: "share_3day.png")
                }
            }
        }
        if ProcessInfo.processInfo.environment["MEM_SHOT"] != nil {
            memories.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                let ms = memories.snapshot()
                renderer.activeScreen = DashboardScreen.memories.rawValue
                // Fallback mock (biblioteka symulatora bywa pusta) — weryfikacja mozaiki:
                // 2 pionowe + 1 poziome = najgorszy przypadek pakowania szerokości.
                func mock(_ w: Int, _ h: Int, _ c1: UIColor, _ c2: UIColor, _ label: String) -> UIImage {
                    UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { c in
                        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [c1.cgColor, c2.cgColor] as CFArray, locations: [0,1])!
                        c.cgContext.drawLinearGradient(g, start: .zero,
                            end: CGPoint(x: w, y: h), options: [])
                        (label as NSString).draw(at: CGPoint(x: 20, y: 20),
                            withAttributes: [.font: UIFont.boldSystemFont(ofSize: CGFloat(h)/6),
                                             .foregroundColor: UIColor.white])
                    }
                }
                let mocks = [
                    mock(1200, 1600, .systemIndigo, .systemPink,   "PION 3:4"),
                    mock(1600,  900, .systemTeal,   .systemOrange, "POZIOM 16:9"),
                    mock(1200, 1600, .systemGreen,  .systemYellow, "PION 3:4"),
                ]
                renderer.memCurrent = ms.current.isEmpty ? mocks : ms.current
                renderer.memPrevious = ms.previous
                renderer.memSwitchAt = ms.switchAt - 2
                renderer.memCaption = ms.caption.isEmpty ? "14 sierpnia 2023" : ms.caption
                renderer.memStatus = ms.status
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("mem.png")
                try? renderer.renderImage().pngData()?.write(to: url)
                NSLog("[MEM_SHOT] zapisano — realneZdjęcia=\(ms.current.count) status=\(ms.status)")
            }
        }
        #endif
        CrashReporter.startHeartbeat()   // ślad życia + footprint pamięci (diagnostyka Jetsam)
        AppActivity.install()            // pierwszy plan / tło — od tego zależy tempo odświeżania interfejsu
        // Podepnij TelemetryStore pod sesję TCP (do debugowania OBD)
        session.telemetryStore = telemetry

        // Ustaw motyw na starcie
        renderer.isDarkMode = isDark

        // Powiadomienia — pytanie o zakończenie trasy po grace period
        #if DEBUG
        // Zrzuty ekranu w symulatorze: systemowe pytanie o powiadomienia zasłaniałoby widok.
        let quietUI = ProcessInfo.processInfo.environment["UI_DEMO"] != nil
        #else
        let quietUI = false
        #endif
        if !quietUI { NotificationManager.shared.setup() }
        NotificationManager.shared.onEndRouteRequested = {
            finishCurrentRoute()
        }

        // Auto-start BT — nie trzeba klikać ręcznie przy każdym uruchomieniu
        bt.start()

        // Sensory telefonu (GPS + IMU) — ZAWSZE aktywne gdy app otwarta. To żywy
        // dashboard: wskaźniki (lean/prędkość/G) mają pokazywać na bieżąco niezależnie
        // od BT. requireBT steruje tylko AUTO-NAGRYWANIEM, nie wyświetlaniem sensorów.
        // Przechył: czujnik motocykla, gdy mostek CAN podaje świeży kąt; inaczej telefon.
        // Musi być ustawione przed startem IMU.
        bikeLink.setUseBikeLean(bikeLeanOn)
        bikeLink.setUseWheelSpeed(bikeSpeedOn)
        motion.externalLean = { [weak bikeLink] in bikeLink?.leanDeg() }
        motion.start()
        nowPlaying.start()

        // Mostek CAN→BLE: łączy się sam, gdy płytka dostanie zasilanie z zapłonem.
        // Do logu idzie przechył z TELEFONU — punkt odniesienia niezależny od motocykla.
        ContentView.nowPlayingRef = nowPlaying
        ContentView.spotifyRef = spotify
        bikeLink.phoneSample = { [weak motion, weak weather] in
            guard let m = motion else { return nil }
            let c = m.lastLocationCoord
            return PhoneSample(speedKmh: m.speedKmh, leanDeg: m.livePhoneLeanDeg, gForce: m.liveGForce,
                               lat: c?.latitude, lon: c?.longitude, altitudeM: m.altitudeM,
                               headingDeg: m.headingDeg, gpsAccuracy: m.gpsAccuracy,
                               temperatureC: weather?.temperatureC)
        }
        bikeLink.setLogging(canRawLog)
        if bikeLinkOn { bikeLink.start() }
        #if DEBUG
        // Próba obciążenia: sztuczne czujniki i telemetria jak w jeździe (pomiar zużycia procesora).
        if ProcessInfo.processInfo.environment["LOAD_TEST"] != nil {
            motion.debugStartLoad()
            bikeLink.debugStartLoad()
        }
        // Skrót zmiany motywu z joysticka: ▲▼▲▼ wstrzyknięte jak z motocykla.
        if ProcessInfo.processInfo.environment["JOY_COMBO"] != nil {
            let js = joyState
            for (i, key) in JoystickState.themeCombo.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(i) * 0.25) {
                    js.handleEvent(SoftkeyEvent(keyId: key, action: 1, rawPayload: Data()))
                }
            }
        }
        // Test aktualizacji płytki bez dotykania telefonu: po połączeniu startuje sama.
        if ProcessInfo.processInfo.environment["OTA_AUTOSTART"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak bikeLink] in
                guard let b = bikeLink, b.updateSupported,
                      (b.live?.fwVersion ?? 0) != BikeLinkManager.currentFirmware else { return }
                b.startFirmwareUpdate()
            }
        }
        #endif

        // Sprawdź czy jest przerwana sesja do odzyskania (crash / iOS kill)
        if recorder.hasInterruptedSession {
            showRecoveryAlert = true
        }

        // Cel udostępniony z Apple Maps (share sheet) przed uruchomieniem apki
        checkPendingSharedDestination()

        // Spotify Web API — auto-connect jeśli mamy zapisany token
        spotifyClientID = spotify.clientID
        spotify.tryAutoConnect()

        // Timer podglądu — 1Hz. Handler jest ustawiany NIŻEJ (po recorderze)
        // żeby snapshots danych recoreder'a i renderDashboardPreview() były w jednym callbacku.
        previewTimer.schedule(deadline: .now() + 0.1, repeating: 1.0, leeway: .milliseconds(200))

        // Frame provider — każde wywołanie aktualizuje renderer danymi z telefonu
        // i zwraca JPEG 864×320 wysyłany na wyświetlacz motocykla (15 fps)
        session.frameProvider = { [weak renderer, weak motion, weak nowPlaying, weak spotify, weak weather, weak snakeGame, weak sudoku, weak mapSnap, weak perfMeter, weak navManager, weak videoProvider, weak recorder, weak lyrics, weak memories, weak segments, weak bikeLink] in
            guard let r = renderer, let m = motion else { return nil }
            let screen = UserDefaults.standard.integer(forKey: "activeScreen")
            r.activeScreen = screen
            r.ambientEnabled = UserDefaults.standard.object(forKey: "ambientBG") as? Bool ?? true
            // Ekran wideo: klatki wprost z VideoFrameProvider (bypass renderera)
            if screen == DashboardScreen.video.rawValue {
                if let f = videoProvider?.currentFrame() { return f }
                return r.render()   // placeholder zanim pierwsza klatka gotowa
            }
            r.snakeSnapshot  = snakeGame?.snapshot()
            r.sudokuSnapshot = sudoku?.snapshot()
            r.mapImage       = mapSnap?.mapImage
            r.perfSnapshot   = perfMeter?.snapshot()
            r.navActive            = navManager?.isActive ?? false
            r.navInstruction       = navManager?.nextInstruction ?? ""
            r.navDistanceToNext    = navManager?.distanceToNext ?? 0
            r.navRemainingDistance = navManager?.remainingDistance ?? 0
            r.navRemainingTime     = navManager?.remainingTime ?? 0
            r.speedKmh     = bikeLink?.wheelSpeedKmh() ?? m.speedKmh
            r.maxSpeedKmh  = m.maxSpeedKmh
            r.avgSpeedKmh  = m.avgSpeedKmh
            r.recordingActive = recorder?.isRecording ?? false
            r.sunsetString = m.sunsetString
            // Przechył z motocykla bierzemy wprost z mostka, w chwili rysowania klatki —
            // bez czekania na takt czujnika telefonu i przeskok na wątek główny.
            r.leanAngleDeg = bikeLink?.leanDeg() ?? m.liveLeanDeg
            // Przeciążenie i rekordy też spod zamka czujnika, nie z pól interfejsu —
            // tamte w tle odświeżają się raz na sekundę.
            let records = m.liveMax
            r.maxLeanLeft  = records.left
            r.maxLeanRight = records.right
            r.gForce       = m.liveGForce
            r.maxGforce    = records.g
            r.headingDeg   = m.headingDeg
            r.altitudeM    = m.altitudeM
            r.tripDistKm   = m.tripDistKm
            r.gpsAccuracy  = m.gpsAccuracy
            r.sessionSec   = m.sessionSec
            r.temperatureC = weather?.temperatureC
            r.infoChips    = ContentView.dashChips(segments: segments, weather: weather,
                                                   navRemaining: navManager?.remainingDistance ?? 0,
                                                   headingDeg: m.headingDeg)
            r.bike         = bikeLink?.snapshot()
            if screen == DashboardScreen.hacker.rawValue, let feed = bikeLink?.hackerFeed() {
                r.hackerLines = feed.lines
                r.hackerTable = feed.table
            }
            r.suspTravel   = bikeLink?.suspensionTravel()
            r.leanSource   = ContentView.leanSource(
                enabled: UserDefaults.standard.object(forKey: "bikeLink") as? Bool ?? true,
                fromBike: m.leanFromBike, simulated: r.bike?.simulated == true)
            // Now Playing: system (MR/MP) ma priorytet, fallback → Spotify Web API
            let useSp = (nowPlaying?.title ?? "").isEmpty && !(spotify?.title ?? "").isEmpty
            r.npTitle     = useSp ? (spotify?.title          ?? "") : (nowPlaying?.title         ?? "")
            r.npArtist    = useSp ? (spotify?.artist         ?? "") : (nowPlaying?.artist        ?? "")
            r.npArtwork   = useSp ? spotify?.artwork                : nowPlaying?.artwork
            r.npElapsed   = useSp ? (spotify?.currentElapsed ?? 0) : (nowPlaying?.currentElapsed ?? 0)
            r.npDuration  = useSp ? (spotify?.duration       ?? 0) : (nowPlaying?.duration       ?? 0)
            r.npIsPlaying          = useSp ? (spotify?.isPlaying  ?? false) : (nowPlaying?.isPlaying ?? false)
            r.calibrationCountdown = m.calibrationCountdown
            // Disco: karaoke lyrics — pobierz przy zmianie utworu (debounce po kluczu w managerze)
            if screen == DashboardScreen.disco.rawValue {
                lyrics?.update(title: r.npTitle, artist: r.npArtist, duration: r.npDuration)
                let snap = lyrics?.snapshot()
                r.lyricsLines  = snap?.lines  ?? []
                r.lyricsStatus = snap?.status ?? ""
            }
            if screen == DashboardScreen.memories.rawValue, let ms = memories?.snapshot() {
                r.memCurrent = ms.current; r.memPrevious = ms.previous
                r.memSwitchAt = ms.switchAt; r.memCaption = ms.caption; r.memStatus = ms.status
            }
            return r.render()
        }

        // Gdy BT mówi że WiFi motocykla jest gotowe — pokaż kredentiale
        // Dziennik zdarzeń połączenia (canlogs/link_*.csv, wiersze E): co puściło pierwsze,
        // gdy deska nagle się rozłącza — Bluetooth z motocyklem, WiFi czy samo TCP.
        let linkEvent: (String, String) -> Void = { [weak bikeLink] source, text in
            let clean = text.replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\n", with: " ")
            bikeLink?.logLink(String(format: "E,%.1f,%@,%@", Date().timeIntervalSince1970, source, clean))
        }
        bt.onEvent = { linkEvent("bt", $0) }
        session.onLog = { linkEvent("tcp", $0) }
        wifiWatch.start { linkEvent("wifi", $0) }

        bt.onWlanReady = { ssid, password in
            self.wifiSSID     = ssid
            self.wifiPassword = password
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                guard let port = UInt16(self.tcpPort) else { return }
                self.session.connect(host: self.tcpHost, port: port)
            }
        }

        // Joystick — strong capture (brak retain cycle: joyState nie trzyma session)
        joyState.motion  = motion
        joyState.spotify = spotify
        joyState.snake   = snakeGame
        joyState.sudoku  = sudoku
        joyState.perf    = perfMeter
        joyState.memories = memories
        joyState.video    = videoProvider
        joyState.currentScreen = { UserDefaults.standard.integer(forKey: "activeScreen") }
        joyState.setScreen     = { idx in
            DispatchQueue.main.async { self.setActiveScreen(idx) }
        }
        joyState.toggleTheme   = {
            DispatchQueue.main.async { self.setDashTheme(dark: !self.isDark) }
        }
        // Mapa nawigacji — czyta GPS/heading z MotionManager + trasa z NavManager
        mapSnap.motion = motion
        mapSnap.nav    = navManager
        // Miernik osiągów — karmiony prędkością z GPS (czas fixu)
        motion.onSpeedUpdate = { [weak perfMeter] kmh, t in
            perfMeter?.feed(speedKmh: kmh, at: t)
        }
        // Uruchom odpowiedni ekran od razu po starcie
        if activeScreen == DashboardScreen.snake.rawValue { snakeGame.start() }
        if activeScreen == DashboardScreen.navigation.rawValue
            || activeScreen == DashboardScreen.navClassic.rawValue { mapSnap.dark = isDark; mapSnap.start() }
        if activeScreen == DashboardScreen.video.rawValue { videoProvider.start() }
        if activeScreen == DashboardScreen.memories.rawValue { memories.start() }
        if activeScreen == DashboardScreen.hacker.rawValue { bikeLink.setHackerActive(true) }
        let js = joyState   // lokalna referencja dla closure
        session.onSoftkeyPressed = { ev in
            js.handleEvent(ev)
        }
        // Diagnostyka Fazy 1: nieznane pakiety też trafiają do monitora joysticka
        session.onUnknownPacket = { type, hex in
            DispatchQueue.main.async { js.logRaw("❓ nieznany type=\(type)  hex:\(hex)") }
        }

        // ── Auto night mode ──────────────────────────────────────────────
        // Motocykl wysyła IS_NIGHT (0x00000003) gdy zapali się światło drogowe.
        // Automatycznie przełączamy motyw dashboardu (bez dotykania telefonu).
        // ContentView to struct — nie używamy [weak self], zamiast tego silne referencje
        // do konkretnych StateObject (renderer jest klasą — można weak).
        let rend = renderer
        session.onIsNightChanged = { [weak rend] isNight in
            rend?.isDarkMode = isNight
            // isDark @AppStorage aktualizujemy przez DispatchQueue.main bo @AppStorage wymaga main
            DispatchQueue.main.async {
                UserDefaults.standard.set(isNight, forKey: "dashboardDark")
            }
        }

        // ── Adaptive JPEG quality ─────────────────────────────────────────
        // RTT < 30ms  → podnosimy jakość (do FrameRenderer.maxStreamQuality)
        // RTT > 80ms  → obniżamy jakość (min 0.40) — mniejszy pakiet = niższa latency
        // (zakres dla klatki 864×320; przy dawnej potrójnej skali było 0.20–0.65)
        // Hystereza: zmiana co max ±0.02 na krok wzwyż, ±0.05 w dół (szybsza reakcja na lag)
        session.onFrameRTT = { [weak renderer] rtt in
            guard let r = renderer else { return }
            frameStats.add(rtt)
            let q = r.jpegQuality
            if rtt < 0.030 && q < FrameRenderer.maxStreamQuality {
                r.jpegQuality = min(FrameRenderer.maxStreamQuality, q + 0.02)
            } else if rtt > 0.080 && q > 0.40 {
                r.jpegQuality = max(0.40, q - 0.05)
            }
        }

        // ── Heartbeat 1Hz: zarządzanie połączeniem + snapshot danych dla recorder'a ──
        // Recorder ma własny timer 1s do zapisu punktów, a my co 1s wstrzykujemy mu
        // świeże wartości z motion (thread-safe przez publiczne properties).
        let rec = recorder
        let mot = motion
        // [self] — bezpieczne dla struct: @StateObject/@State property wrappers trzymają
        // swoje storage w HeapStorage, kopia struct'u nadal adresuje ten sam box.
        previewTimer.setEventHandler { [self] in
            // ── Ciągłe zarządzanie połączeniem z motocyklem (1Hz heartbeat) ──
            // Jedno źródło prawdy zamiast kruchych event'ów BT/TCP → brak zawieszeń
            // w stanie „paused". Heartbeat działa dopóki app żyje (GPS trzyma ją w tle).
            manageBikeConnection()
            autoConnectTCPIfNeeded()   // ciągły reconnect przesyłu (nie tylko raz z onWlanReady)

            // Snapshot danych dla recorder'a (1Hz)
            rec.isBikeConnected    = isOnBike   // postój z moto (światła) → zapisuj; bez moto → pomiń
            rec.latestSpeed        = mot.speedKmh
            // Do CSV idzie kąt WYGŁADZONY (mediana 0.5s) — surowy potrafił złapać
            // chwilowy spike z wraparoundu Eulera i zapisać fałszywe 60°+.
            rec.latestLean         = mot.leanSmoothedDeg
            let records = mot.liveMax
            rec.latestMaxLeanLeft  = records.left
            rec.latestMaxLeanRight = records.right
            rec.latestGforce    = mot.liveGForce
            if let coord = mot.lastLocationCoord {
                rec.latestLatitude  = coord.latitude
                rec.latestLongitude = coord.longitude
                // Weather refresh — fetcher sam pilnuje cache (15 min lub > 5 km od ostatniego)
                weather.updateIfNeeded(at: coord)
                navManager.update(location: coord)   // turn-by-turn śledzenie

                // Pogoda na trasie: z nawigacją próbkujemy trasę (krok ≥10 km, do 14 punktów,
                // czyli cała trasa do ~130 km albo rzadziej przy dłuższej), bez — bieżące miejsce.
                let nav = navManager
                let remaining = nav.remainingDistance
                weather.updateAheadIfNeeded(
                    at: coord,
                    routeKey: nav.isActive ? "nav|\(nav.destinationName)" : "free",
                    route: { nav.isActive
                        ? nav.pointsAhead(from: coord, stepM: max(10_000, min(remaining, 300_000) / 13), maxCount: 14)
                        : ([], false) },
                    speedMS: nav.cruiseSpeedMS, navRemaining: remaining)

                // Odcinki: czas liczymy ze znacznika fixa GPS, nie z chwili heartbeatu.
                segments.ingest(coord: coord, speedKmh: mot.speedKmh, leanDeg: mot.leanSmoothedDeg,
                                accuracy: mot.gpsAccuracy, time: mot.lastLocationTime ?? Date())
            }
            rec.latestAltitude  = mot.altitudeM
            rec.latestHeading   = mot.headingDeg
            bikeLink.feedGPS(kmh: mot.speedKmh, accuracy: mot.gpsAccuracy)   // uczy przelicznik prędkości z koła
            // Dziennik łącza: jak szła wysyłka klatek na wyświetlacz w ostatniej sekundzie.
            if session.tcpState.isConnected {
                let f = frameStats.take(sent: session.framesSent, dropped: session.framesDropped)
                bikeLink.logLink(String(format: "F,%.1f,%d,%d,%.0f,%.0f,%d,%.2f,%.1f", Date().timeIntervalSince1970,
                                        f.sent, f.dropped, f.rttAvg * 1000, f.rttMax * 1000, session.frameSkipFactor,
                                        renderer.jpegQuality, Double(session.lastSentFrame?.count ?? 0) / 1024))
            }
            rec.latestTrack = Self.playingTrack()
            bikeLink.setPlayingTrack(Self.playingTrackLabel())
            if let b = bikeLink.snapshot(), b.engineFresh, !b.simulated {
                rec.latestEngine = (b.rpm, b.gear, b.throttle10)
            } else {
                rec.latestEngine = nil
            }
            // Dynamic Island / ekran blokady: nasze logo i jazda na żywo (co najwyżej co 2 s)
            updateLiveActivity()
            // Render podglądu w UI — tylko gdy ktoś może go zobaczyć (ustawienia go zasłaniają)
            if (AppActivity.isForeground && !AppActivity.isSettingsOpen) || AppActivity.legacyRates { renderDashboardPreview() }
        }
        previewTimer.resume()
    }

    // MARK: — Zakończenie trasy (grace period / ręczne / 4h auto)

    /// Czy jesteśmy „na motocyklu": BT aktywne LUB deska (TCP) połączona.
    private var isOnBike: Bool { bt.state.isActive || session.tcpState.isConnected }

    /// CIĄGŁY (1Hz) auto-reconnect przesyłu. Wcześniej TCP startował TYLKO raz —
    /// z `onWlanReady` po handshake BT. Jak deska odpadła/wróciła albo WiFi telefonu
    /// dołączyło się z opóźnieniem, przesył się nie wznawiał („BT jest, a nic nie leci").
    /// Teraz: dopóki BT sesja żyje (WiFi motocykla powinno być), a TCP nie jest połączone,
    /// próbujemy połączyć co 5s. connect() jest idempotentne (no-op gdy już łączy/gra),
    /// a nieudana próba (WiFi jeszcze nie dołączone) po prostu ponowi się za 5s.
    private func autoConnectTCPIfNeeded() {
        // Watchdogi obu warstw — ani handshake BT, ani TCP nie mają własnych timeoutów,
        // więc bez tego potrafią wisieć w nieskończoność (BT: „WiFi się nie odpala",
        // TCP: „stuck 1/7"). Każdy postęp resetuje ich liczniki.
        bt.checkStalledHandshake()
        session.checkStalledConnection()

        guard bt.state.isActive else { return }        // tylko gdy deska po BT gotowa
        switch session.tcpState {
        case .idle, .disconnected, .failed:
            let now = Date()
            if let last = lastTcpConnectAttempt, now.timeIntervalSince(last) < 5 { return }
            lastTcpConnectAttempt = now
            if let port = UInt16(tcpPort) { session.connect(host: tcpHost, port: port) }
        default:
            break   // connecting / handshaking / connected — czekaj
        }
    }

    /// EDGE: właśnie połączono z motocyklem → wyczyść grace, sensory ON,
    /// auto-start nagrywania (raz, na krawędzi — nie nadpisuje ręcznego STOP).
    private func onBikeConnectedEdge() {
        btLostAt = nil
        if btGraceNotified {
            btGraceNotified = false
            NotificationManager.shared.clearGraceNotification()
        }
        if recorder.isRecording && recorder.isPaused {
            recorder.resume()
            recordingBikeTied = true
        } else if autoRecord && !recorder.isRecording {
            recorder.start()
            recordingBikeTied = true
        }
    }

    /// CIĄGŁE (1Hz): sensory zawsze żywe; pauza/wznowienie nagrywania wg realnego
    /// stanu połączenia. Bez auto-startu (żeby ręczny STOP przetrwał). Odporne na
    /// kruche kolejności event'ów BT/TCP — nic się nie zawiesza w „paused".
    private func manageBikeConnection() {
        // Sensory żywe gdy app otwarta (wskaźniki na bieżąco), chyba że user je ręcznie
        // zatrzymał. Nagrywanie ma priorytet — zawsze wymusza sensory ON.
        if !motion.isActive && (!sensorsManuallyStopped || recorder.isRecording) {
            motion.start()
        }
        // Nie nagrywamy: nic więcej do zrobienia (wyzeruj przypięcie do moto).
        guard recorder.isRecording else {
            recordingBikeTied = false
            return
        }
        if isOnBike {
            recordingBikeTied = true          // moto obecne → to sesja motocyklowa
            if btLostAt != nil { btLostAt = nil }
            if recorder.isPaused { recorder.resume() }
        } else if recordingBikeTied {
            // Sesja motocyklowa, ale moto zniknęło → grace period.
            // GPS zostaje włączony (trzyma app żywą), pauzujemy tylko punkty.
            if btLostAt == nil { btLostAt = Date() }
            if !recorder.isPaused { recorder.pause() }
            let elapsed = Date().timeIntervalSince(btLostAt!)
            if elapsed >= graceAutoSaveSec {
                finishCurrentRoute()
            } else if elapsed >= graceNotifySec && !btGraceNotified {
                btGraceNotified = true
                NotificationManager.shared.sendGracePeriodNotification()
                showEndRouteAlert = true
            }
        }
        // else: ręczne nagrywanie standalone (bez moto) → NIE pauzujemy, leci dalej.
    }

    /// Finalizuje aktualnie nagrywaną trasę, zapisuje do biblioteki i czyści grace period.
    private func finishCurrentRoute() {
        if recorder.isRecording, let summary = recorder.stop() {
            sessionSummary = summary
        }
        btLostAt = nil
        btGraceNotified = false
        NotificationManager.shared.clearGraceNotification()
        // Sensory zostają aktywne — dashboard ma dalej pokazywać żywe wskaźniki.
    }

    // MARK: — TCP akcja

    private func toggleTCP() {
        if session.tcpState.isConnected {
            session.disconnect()
        } else {
            // 1. Powiedz motocyklowi przez BT że jesteśmy połączeni z WiFi
            bt.sendPhoneTCPConnected()
            // 2. Poczekaj chwilę żeby motocykl przetworzył BT wiadomość
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let port = UInt16(self.tcpPort) else { return }
                self.session.connect(host: self.tcpHost, port: port)
            }
        }
    }

    // MARK: — Kolory

    var btColor: Color {
        switch bt.state {
        case .wlanState("CONNECTED"), .wlanState("READY"): return .green
        case .sessionOpen, .handshaking:                   return .yellow
        case .failed:                                      return .red
        default:                                           return .gray
        }
    }

    var tcpColor: Color {
        switch session.tcpState {
        case .connected:            return .green
        case .connecting,
             .handshaking:         return .yellow
        case .failed:               return .red
        default:                    return .gray
        }
    }

    func msgColor(_ dir: BTMessage.Direction) -> Color {
        switch dir {
        case .sent:     return .blue
        case .received: return .green
        case .system:   return .secondary
        }
    }

}

// MARK: — Cel wyboru przycisku (grafika d-pad)

struct BindPick: Identifiable {
    var id: String { bind }
    let bind: String     // "snake.up" lub "goto.<screen>.<slot>"
    let title: String
}

// MARK: — Akcje joysticka

/// Fizyczne przyciski joysticka motocykla — keyId odkryte z pcapng (type 67).
enum JoyButton: UInt8, CaseIterable {
    case up    = 0x1E   // 30
    case down  = 0x1F   // 31
    case left  = 0x20   // 32
    case right = 0x21   // 33
    case ok    = 0x0C   // 12
    case back  = 0x0E   // 14

    var label: String {
        switch self {
        case .up:    return "Góra"
        case .down:  return "Dół"
        case .left:  return "Lewo"
        case .right: return "Prawo"
        case .ok:    return "OK"
        case .back:  return "Back"
        }
    }
    /// Co przycisk robi (sterowanie muzyką + ekrany).
    var actionLabel: String {
        switch self {
        case .up:    return "▲ Poprzedni ekran"
        case .down:  return "▼ Następny ekran"
        case .left:  return "⏮ Poprzedni"
        case .right: return "⏭ Następny"
        case .ok:    return "⏯ Play / Pause"
        case .back:  return "⊙ Kalibracja"
        }
    }
}

final class JoystickState: ObservableObject {
    @Published var lastKeyId:    Int        = -1
    @Published var lastEvent:    String     = "—"
    /// Monitor diagnostyczny — ostatnie surowe eventy.
    @Published var recentEvents: [String]   = []
    /// Learn-mode: id akcji/slotu którego uczymy się ("snake.up" lub "goto.<screen>.<slot>").
    @Published var listeningBinding: String? = nil
    /// Inkrementowane po zapisaniu bindu — wymusza odświeżenie UI (bindy są w UserDefaults).
    @Published var bindingsRevision: Int = 0

    // Referencje do sterowników — ustawiane raz w setup()
    weak var motion:  MotionManager?
    weak var spotify: SpotifyWebManager?
    weak var snake:   SnakeGame?
    weak var sudoku:  SudokuGame?
    weak var perf:    PerfMeter?
    weak var memories: MemoriesManager?
    weak var video:   VideoFrameProvider?

    /// Odczyt/zmiana aktywnego ekranu — wstrzykiwane z ContentView (closure nad @AppStorage).
    var currentScreen: () -> Int = { 0 }
    var setScreen:     (Int) -> Void = { _ in }   // bezwzględny indeks ekranu
    /// Przełączenie motywu deski (jasny/ciemny) — wstrzykiwane z ContentView.
    var toggleTheme:   () -> Void = { }

    /// Skrót do rzadko używanej zmiany motywu: ▲▼▲▼ (fizyczne przyciski) w ciągu 1,5 s.
    /// Na zwykłych ekranach ▲/▼ zmieniają ekran, więc te cztery wciśnięcia kończą się
    /// na tym samym ekranie, na którym zaczęto — zostaje tylko zmiana motywu.
    static let themeCombo: [UInt8] = [0x1E, 0x1F, 0x1E, 0x1F]
    static let themeComboWindow: TimeInterval = 1.5
    private var comboKeys: [(key: UInt8, t: TimeInterval)] = []

    /// Notuje wciśnięcie; true, gdy właśnie domknęło skrót zmiany motywu.
    func noteComboKey(_ key: UInt8, at t: TimeInterval) -> Bool {
        comboKeys.append((key, t))
        if comboKeys.count > Self.themeCombo.count { comboKeys.removeFirst(comboKeys.count - Self.themeCombo.count) }
        guard comboKeys.map(\.key) == Self.themeCombo,
              t - comboKeys[0].t <= Self.themeComboWindow else { return false }
        comboKeys.removeAll()
        return true
    }

    /// ▲▼ po kolejności ustawionej w apce („Kolejność”), nie po numerach ekranów —
    /// inaczej po przestawieniu kolejności joystick skakał „losowo”.
    private func cycleScreen(_ delta: Int) {
        let order = ContentView.orderedScreens(UserDefaults.standard.string(forKey: "screenOrder") ?? "")
        setScreen(Self.cycled(from: currentScreen(), delta: delta, order: order.map(\.rawValue)))
    }

    static func cycled(from current: Int, delta: Int, order: [Int]) -> Int {
        guard !order.isEmpty else { return current }
        let i = order.firstIndex(of: current) ?? 0
        let n = order.count
        return order[((i + delta) % n + n) % n]
    }

    /// Smart-previous: pierwsze wciśnięcie = restart utworu, drugie w ciągu 3s = poprzedni.
    private var lastPrevPress: Date = .distantPast
    private let prevDoubleWindow: TimeInterval = 3.0

    /// Double-click (zamiennik martwego Back / long-pressu — protokół nie daje pewnych
    /// eventów przytrzymania). Dwa wciśnięcia tego samego guzika < doubleWindow = akcja
    /// specjalna. Single jest odraczany o okno, żeby nie odpalał się razem z double.
    private var lastDblDown: Date = .distantPast
    private var pendingSingle: DispatchWorkItem? = nil
    private let doubleWindow: TimeInterval = 0.45

    /// Akcja podwójnego kliknięcia na danym ekranie (to co robił long-press).
    /// "__exit" = wyjście do klasycznego, "__calibrate" = kalibracja. nil = brak.
    func doubleAction(_ s: DashboardScreen) -> String? {
        switch s {
        case .classic:        return "__calibrate"
        case .snake, .sudoku: return "__exit"
        case .video:          return "__nextVideo"
        default:              return nil   // lean (single OK już kalibruje), perf, nav
        }
    }

    private static let monitorFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// Wpis do monitora diagnostycznego (wołane też dla nieznanych pakietów).
    func logRaw(_ line: String) {
        let stamped = "\(Self.monitorFmt.string(from: Date()))  \(line)"
        recentEvents.insert(stamped, at: 0)
        if recentEvents.count > 12 { recentEvents.removeLast(recentEvents.count - 12) }
    }

    /// Obsługa pełnego eventu joysticka (type 67): diagnostyka + learn-mode + routing wg bindów.
    func handleEvent(_ ev: SoftkeyEvent) {
        let id = Int(ev.keyId)
        lastKeyId = id
        lastEvent = "Key \(id) act=\(ev.action) \(ev.isPressed ? "↓" : "↑")"
        logRaw("keyId=\(id) action=\(ev.action) \(ev.isPressed ? "↓ down" : "↑ up")  hex:\(ev.rawPayload.hex)")

        // Reagujemy na WCIŚNIĘCIE (down). Motocykl bywa nie wysyła „up", więc nie
        // opieramy niczego na puszczeniu.
        guard ev.isPressed else { return }

        // Skrót zmiany motywu. Czwarte wciśnięcie dalej robi swoje (▼ wraca na ekran startowy).
        if noteComboKey(ev.keyId, at: ProcessInfo.processInfo.systemUptime) {
            logRaw("🎨 ▲▼▲▼ — zmiana motywu deski")
            toggleTheme()
        }

        let screenRaw = currentScreen()
        let screen = DashboardScreen(rawValue: screenRaw) ?? .classic

        // ── Double-click na przypisanym guziku → akcja specjalna ──
        if let dbl = doubleAction(screen), ev.keyId == KeyBindings.doubleKey(screen: screenRaw) {
            let now = Date()
            if now.timeIntervalSince(lastDblDown) < doubleWindow {
                // Drugie kliknięcie → akcja specjalna, anuluj zaległy single.
                pendingSingle?.cancel(); pendingSingle = nil
                lastDblDown = .distantPast
                if dbl == "__exit"      { setScreen(DashboardScreen.classic.rawValue) }
                else if dbl == "__calibrate" { motion?.startCalibration() }
                else if dbl == "__nextVideo" { video?.next() }
            } else {
                // Pierwsze kliknięcie → odrocz normalną akcję guzika o okno double.
                lastDblDown = now
                let work = DispatchWorkItem { [weak self] in
                    self?.runSingle(ev.keyId, screen: screen, screenRaw: screenRaw)
                }
                pendingSingle = work
                DispatchQueue.main.asyncAfter(deadline: .now() + doubleWindow, execute: work)
            }
            return
        }

        runSingle(ev.keyId, screen: screen, screenRaw: screenRaw)
    }

    /// Pojedyncze wciśnięcie: slot „Przejdź do" (priorytet) albo akcja ekranu.
    private func runSingle(_ keyId: UInt8, screen: DashboardScreen, screenRaw: Int) {
        if let target = KeyBindings.gotoTarget(forKey: keyId, screen: screenRaw) {
            setScreen(target)
            return
        }
        if let actionId = KeyBindings.actionId(forKey: keyId, screen: screen) {
            execute(actionId)
        }
    }

    /// Wykonuje akcję po jej stabilnym id.
    private func execute(_ actionId: String) {
        switch actionId {
        // Muzyka
        case "classic.prev":
            let now = Date()
            if now.timeIntervalSince(lastPrevPress) < prevDoubleWindow {
                spotify?.previousTrack(); lastPrevPress = .distantPast
            } else {
                spotify?.seekToStart(); lastPrevPress = now
            }
        case "classic.next", "disco.next":           spotify?.nextTrack()
        case "classic.playpause", "disco.playpause": spotify?.togglePlayPause()
        case "disco.prev":
            let now = Date()
            if now.timeIntervalSince(lastPrevPress) < prevDoubleWindow {
                spotify?.previousTrack(); lastPrevPress = .distantPast
            } else {
                spotify?.seekToStart(); lastPrevPress = now
            }

        // Kalibracja
        case "classic.calibrate", "lean.calibrate": motion?.startCalibration()

        // Przełączanie ekranów
        case "classic.screenPrev", "lean.screenPrev", "nav.screenPrev", "perf.screenPrev", "video.screenPrev", "navc.screenPrev", "disco.screenPrev", "mem.screenPrev", "hack.screenPrev": cycleScreen(-1)
        case "classic.screenNext", "lean.screenNext", "nav.screenNext", "perf.screenNext", "video.screenNext", "navc.screenNext", "disco.screenNext", "mem.screenNext", "hack.screenNext": cycleScreen(+1)

        // Wspomnienia — ręczna zmiana zdjęcia
        case "mem.next": memories?.manualNext()
        case "mem.prev": memories?.manualPrev()

        // Wideo
        case "video.back":      video?.seek(by: -VideoFrameProvider.seekStep)
        case "video.forward":   video?.seek(by: VideoFrameProvider.seekStep)
        case "video.playpause": video?.togglePause()

        // Pomiary
        case "perf.reset": perf?.resetCurrent()

        // Snake
        case "snake.up":      snake?.turn((0, -1))
        case "snake.down":    snake?.turn((0,  1))
        case "snake.left":    snake?.turn((-1, 0))
        case "snake.right":   snake?.turn(( 1, 0))
        case "snake.restart": snake?.okPressed()

        // Sudoku
        case "sudoku.up":    sudoku?.up()
        case "sudoku.down":  sudoku?.down()
        case "sudoku.left":  sudoku?.left()
        case "sudoku.right": sudoku?.right()
        case "sudoku.ok":    sudoku?.okPressed()

        default: break
        }
    }
}

// MARK: — Zamrażanie zasłoniętej treści

/// Treść, której SwiftUI nie aktualizuje, dopóki `paused` jest prawdą (zasłania ją arkusz).
/// Po odsłonięciu aktualizuje się od razu do bieżącego stanu.
struct PausedWhileHidden<Content: View>: View, Equatable {
    let paused: Bool
    let content: Content

    init(paused: Bool, @ViewBuilder content: () -> Content) {
        self.paused = paused
        self.content = content()
    }

    static func == (a: Self, b: Self) -> Bool { a.paused && b.paused }

    var body: some View { content }
}

// MARK: — DiagBox (diagnostyczne pudełko z licznikiem)

struct DiagBox: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .black, design: .monospaced))
                .foregroundColor(color)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .animation(AppStyle.animateNumbers ? .easeOut(duration: 0.2) : nil, value: value)
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

// MARK: — MiniTelValue

struct MiniTelValue: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundColor(color)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(AppStyle.animateNumbers ? .numericText() : .identity)
                .animation(AppStyle.animateNumbers ? .easeOut(duration: 0.3) : nil, value: value)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
                .tracking(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

// MARK: — BT Log View

struct BTLogView: View {
    @ObservedObject var manager: BTManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(manager.receivedMessages) { msg in
                            HStack(alignment: .top, spacing: 6) {
                                Text(msg.timeString)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 80, alignment: .leading)
                                Text(msg.prefix)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(dirColor(msg.direction))
                                    .frame(width: 12)
                                Text(msg.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.primary)
                            }
                            .id(msg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: manager.receivedMessages.count) {
                    if let last = manager.receivedMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .navigationTitle("BT Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BackButton { dismiss() }
                }
            }
        }
    }

    func dirColor(_ dir: BTMessage.Direction) -> Color {
        switch dir {
        case .sent:     return .blue
        case .received: return .green
        case .system:   return .secondary
        }
    }
}

// MARK: — Telemetry Log View
//
// Log telemetryczny — POKAZUJE TYLKO:
//   🔌 ✅ ❌ — stan połączenia
//   🏍  📤 ⟳ — cykl życia subskrypcji danych
//   🟢 🔄 📊 — wartości kanałów (niezerowe, zmiany, batchowe podsumowania)
//   🔘 — przyciski motocyklisty
//   ⚠️ — nieznane pakiety / coś wymagającego uwagi
//
// Każdy wpis to pojedyncza linia — łatwa do skopiowania i wysłania.

struct TelemetryLogView: View {
    @ObservedObject var session: MySpinSession
    @Environment(\.dismiss) var dismiss

    @State private var frozen:     [RawPacketEntry] = []
    @State private var isFrozen    = false
    @State private var filter      = LogFilter.all
    @State private var searchText  = ""
    @State private var autoScroll  = true

    enum LogFilter: String, CaseIterable {
        case all       = "Wszystko"
        case values    = "🟢 Wartości"       // tylko wiersze z 🟢/🔄/📊
        case changes   = "🔄 Zmiany"          // tylko zmiany wartości
        case nonzero   = "🟢 Niezerowe"       // tylko wiersze z 🟢
        case lifecycle = "🔌 Połączenie"     // tylko 🔌✅❌🏍📤⟳
        case warnings  = "⚠️ Uwagi"           // tylko ⚠️❌
    }

    var displayPackets: [RawPacketEntry] {
        let source = isFrozen ? frozen : session.packets
        return source.filter { pkt in
            let t = pkt.name
            let passFilter: Bool = {
                switch filter {
                case .all:       return true
                case .values:    return t.contains("🟢") || t.contains("🔄") || t.contains("📊")
                case .changes:   return t.contains("🔄") || t.contains("🟢")
                case .nonzero:   return t.contains("🟢")
                case .lifecycle: return t.contains("🔌") || t.contains("✅") || t.contains("❌")
                                    || t.contains("🏍") || t.contains("📤") || t.contains("⟳")
                case .warnings:  return t.contains("⚠️") || t.contains("❌")
                }
            }()
            let passSearch = searchText.isEmpty
                || pkt.name.localizedCaseInsensitiveContains(searchText)
            return passFilter && passSearch
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                toolbar
                Divider()
                summaryBar
                Divider()
                logList
            }
            .navigationTitle("Log telemetrii")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BackButton { dismiss() }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        UIPasteboard.general.string = displayPackets
                            .map { "[\($0.timeString)] \($0.name)" }
                            .joined(separator: "\n")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                }
            }
        }
    }

    // ── Pasek narzędzi ──
    var toolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if !isFrozen { frozen = session.packets }
                    isFrozen.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isFrozen ? "play.fill" : "pause.fill")
                        Text(isFrozen ? "Play" : "Pauza")
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(isFrozen ? Color.orange.opacity(0.2) : Color.blue.opacity(0.1))
                    .foregroundColor(isFrozen ? .orange : .blue)
                    .cornerRadius(8)
                }

                Toggle(isOn: $autoScroll) { Text("Auto") }
                    .toggleStyle(.button)
                    .font(.caption.bold())
                    .controlSize(.small)

                Text("\(displayPackets.count)/\(session.packets.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    session.clearPackets()
                    frozen = []
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LogFilter.allCases, id: \.self) { f in
                        Button(f.rawValue) { filter = f }
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(filter == f ? Color.blue : Color(.systemGray5))
                            .foregroundColor(filter == f ? .white : .primary)
                            .cornerRadius(6)
                    }
                }
                .padding(.horizontal, 12)
            }

            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Szukaj (np. RPM, Gear)...", text: $searchText)
                    .font(.system(size: 12, design: .monospaced))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(AppStyle.inset)
            .cornerRadius(8)
            .padding(.horizontal, 12).padding(.bottom, 6)
        }
        .background(Color(.systemBackground))
    }

    // ── Pasek z liczbikami ze statusu ──
    var summaryBar: some View {
        HStack(spacing: 12) {
            summaryItem("t55", "\(session.type55Count)",
                       session.type55Count > 0 ? .green : .gray)
            summaryItem("resub", "\(session.resubCount)",
                       session.resubCount > 0 ? .blue : .gray)
            summaryItem("ping", "\(session.pingCount)",
                       session.pingCount > 0 ? .green : .gray)
            if let store = session.telemetryStore {
                summaryItem("ch", "\(store.rawChannels.count)",
                           store.rawChannels.count > 0 ? .green : .gray)
                summaryItem("zm", "\(store.changeCount)",
                           store.changeCount > 0 ? .yellow : .gray)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(AppStyle.inset)
    }

    @ViewBuilder
    func summaryItem(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.secondary)
        }
    }

    // ── Lista logów ──
    var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(displayPackets) { pkt in
                        TelemetryLogRow(entry: pkt)
                            .id(pkt.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .onChange(of: session.packetsRevision) {
                guard autoScroll, !isFrozen else { return }
                if let last = displayPackets.last {
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: — Wiersz logu telemetrii

struct TelemetryLogRow: View {
    let entry: RawPacketEntry

    // Rozbij wiadomość na emoji + resztę — emoji określa typ, wiadomość jest w .name
    var emoji: String {
        // Pierwszy widoczny znak to emoji. Jeśli brak — "·".
        if let first = entry.name.first { return String(first) }
        return "·"
    }

    var bgColor: Color {
        let n = entry.name
        if n.contains("🟢") { return Color.green.opacity(0.12) }
        if n.contains("🔄") { return Color.yellow.opacity(0.10) }
        if n.contains("❌") { return Color.red.opacity(0.10) }
        if n.contains("⚠️") { return Color.orange.opacity(0.10) }
        if n.contains("✅") { return Color.blue.opacity(0.08) }
        if n.contains("📊") { return Color.purple.opacity(0.06) }
        return .clear
    }

    var textColor: Color {
        let n = entry.name
        if n.contains("🟢") { return .primary }
        if n.contains("❌") { return .red }
        if n.contains("⚠️") { return .orange }
        return .primary
    }

    var isMultiline: Bool { entry.name.contains("\n") }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.timeString)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(entry.name)
                .font(.system(size: 11,
                              weight: entry.name.contains("🟢") || entry.name.contains("✅")
                                      ? .bold : .regular,
                              design: .monospaced))
                .foregroundColor(textColor)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(bgColor)
        .cornerRadius(4)
    }
}

// MARK: — Session Summary View

/// Trasa po „Zakończ trasę” (i po odzyskaniu przerwanej) — ten sam widok co trasa
/// otwarta z biblioteki: mapa z odtwarzaniem, wykresy, statystyki, eksport.
struct RideSheet: View {
    @StateObject private var replay: ReplayManager

    init(summary: SessionSummary) {
        _replay = StateObject(wrappedValue: { let r = ReplayManager(); r.load(summary); return r }())
    }

    var body: some View { SessionPlayerView(replay: replay) }
}

/// Część widoku trasy pod wykresami: czas, przeciążenie, silnik, piosenki, usuwanie.
struct RideExtrasView: View {
    let summary: SessionSummary
    var seek: (TimeInterval) -> Void
    var onDeleted: () -> Void
    @State private var routeDeleted = false

    private func fmtTime(_ s: Int) -> String {
        let h = s/3600, m = (s%3600)/60, ss = s%60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss)
                     : String(format: "%02d:%02d", m, ss)
    }

    var body: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                SummaryStatBox(label: "W RUCHU", value: fmtTime(summary.movingSec),
                               icon: "timer", color: .green)
                SummaryStatBox(label: "ŁĄCZNIE", value: fmtTime(summary.durationSec),
                               icon: "clock", color: .secondary)
                SummaryStatBox(label: "MAX G-FORCE", value: String(format: "%.2f g", summary.maxGforce),
                               icon: "arrow.up.circle", color: .orange)
                SummaryStatBox(label: "PUNKTÓW GPS", value: "\(summary.points.count)",
                               icon: "mappin.and.ellipse", color: .blue)
            }
            .padding(.horizontal)

            // ── Silnik (tylko trasy nagrane z mostkiem CAN) ──
            if let eng = summary.engineStats {
                VStack(alignment: .leading, spacing: 8) {
                    CardHeader("Silnik", icon: "engine.combustion")
                        .padding(.horizontal)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        SummaryStatBox(label: "MAX OBROTY", value: "\(eng.maxRPM)",
                                       icon: "gauge.high", color: .red)
                        SummaryStatBox(label: "ŚRED. OBROTY W RUCHU", value: "\(eng.avgRPM)",
                                       icon: "gauge.medium", color: .orange)
                    }
                    .padding(.horizontal)

                    // Czas na biegach: sześć słupków, wysokość = udział czasu
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(0..<6, id: \.self) { i in
                            VStack(spacing: 3) {
                                Text(String(format: "%.0f%%", eng.gearShare[i] * 100))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.red.opacity(0.75))
                                    .frame(height: max(2, 60 * eng.gearShare[i]))
                                Text("\(i + 1)")
                                    .font(.system(.caption, design: .monospaced).weight(.bold))
                                Text(fmtTime(Int(eng.gearSeconds[i + 1].rounded())))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 110, alignment: .bottom)
                    .padding(.horizontal)

                    Text("Zmian biegów: \(eng.shifts)"
                         + (eng.coverage < 0.95 ? String(format: " · dane z silnika dla %.0f%% trasy", eng.coverage * 100) : ""))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
            }


            // ── Piosenki (od v1.18.0) — dotknięcie przewija odtwarzanie do tej chwili ──
            if let tracks = summary.tracks, !tracks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    CardHeader("Muzyka", icon: "music.note", tint: .green)
                        .padding(.horizontal)
                    ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                        let at = t.time.timeIntervalSince(summary.startTime)
                        Button { seek(at) } label: {
                            HStack(spacing: 10) {
                                Text(fmtTime(max(0, Int(at))))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 58, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(t.artist).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if t == summary.favoriteTrack {
                                    Image(systemName: "star.fill").foregroundColor(.yellow).font(.caption)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                    }
                }
            }

            // ── Usuń trasę (przytrzymaj — celowo, żeby nie skasować przypadkiem) ──
            Label(routeDeleted ? "Trasa usunięta ✓" : "Przytrzymaj, aby usunąć trasę",
                  systemImage: routeDeleted ? "checkmark.circle" : "trash")
                .font(.caption.bold())
                .foregroundColor(routeDeleted ? .secondary : .red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background((routeDeleted ? Color.gray : Color.red).opacity(0.12))
                .cornerRadius(10)
                .padding(.horizontal)
                .onLongPressGesture(minimumDuration: 0.8) {
                    guard !routeDeleted else { return }
                    SessionStorage.shared.delete(id: summary.id)
                    routeDeleted = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { onDeleted() }
                }
        }
    }
}

// MARK: — Kafelek statystyki

private struct SummaryStatBox: View {
    let label: String
    let value: String
    let icon:  String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.caption)
                Text(label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .tracking(0.5)
            }
            Text(value)
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundColor(.primary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .cornerRadius(12)
    }
}

#Preview {
    ContentView()
}

/// Sekundowe podsumowanie wysyłki klatek na wyświetlacz (do dziennika łącza).
/// Dotykane tylko z wątku głównego (wywołanie zwrotne RTT i takt 1 Hz).
final class FrameStats {
    private var sum = 0.0, maxRtt = 0.0, n = 0
    private var lastSent = 0, lastDropped = 0

    func add(_ rtt: TimeInterval) {
        sum += rtt; n += 1; maxRtt = max(maxRtt, rtt)
    }

    func take(sent: Int, dropped: Int) -> (sent: Int, dropped: Int, rttAvg: Double, rttMax: Double) {
        defer { sum = 0; n = 0; maxRtt = 0; lastSent = sent; lastDropped = dropped }
        return (max(0, sent - lastSent), max(0, dropped - lastDropped), n > 0 ? sum / Double(n) : 0, maxRtt)
    }
}

/// Pilnuje, czy telefon ma w ogóle połączenie WiFi (z czymkolwiek), i zgłasza zmiany.
/// Sam stan sieci, bez nazwy — do odróżnienia „iPhone zgubił WiFi motocykla" od
/// „WiFi było, a padło tylko połączenie z deską".
final class WifiWatch {
    private var monitor: NWPathMonitor?
    private var last: NWPath.Status?

    func start(_ report: @escaping (String) -> Void) {
        guard monitor == nil else { return }
        let m = NWPathMonitor(requiredInterfaceType: .wifi)
        m.pathUpdateHandler = { [weak self] path in
            guard let self, path.status != self.last else { return }
            self.last = path.status
            report(path.status == .satisfied ? "WiFi telefonu: połączone" : "WiFi telefonu: BRAK połączenia (\(path.status))")
        }
        m.start(queue: DispatchQueue(label: "wifiwatch"))
        monitor = m
    }
}
