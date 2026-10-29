// RiderModeView.swift
// TRYB PASAŻERA — „daj komuś telefon i jedź".
//
// Pełnoekranowy licznik przechyłu na EKRANIE TELEFONU (nie na desce motocykla):
// wielki kąt, łuk ze strefami, sylwetka GSX przechylająca się na żywo, rekordy
// L/R, prędkość i G. Jednym przyciskiem startuje nagrywanie telemetrii — trasa
// ląduje w tej samej Bibliotece tras co nagrania z motocykla.
//
// MODUŁ NIEZALEŻNY: ten plik nie zmienia niczego w głównej aplikacji.
//  • czyta tylko istniejące MotionManager / SessionRecorder (żadnych własnych
//    sensorów ani timerów — dane karmi ten sam heartbeat 1 Hz co zawsze)
//  • orientację ustawia tylko na czas swojego działania i przywraca pion na wyjściu
//  • zamknięcie widoku nie zatrzymuje trwającego nagrania (świadomie — można
//    schować podgląd i nagrywać dalej)

import SwiftUI
import UIKit

struct RiderModeView: View {

    @ObservedObject var motion:   MotionManager
    @ObservedObject var recorder: SessionRecorder
    /// Wywoływane przy zatrzymaniu nagrania — główny widok pokazuje podsumowanie.
    var onFinish: (SessionSummary) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    /// Pion (false) / poziom (true) — zapamiętywane między uruchomieniami.
    @AppStorage("riderModeLandscape") private var landscape = false
    /// Która ze stron poziomu jest zablokowana — patrz `applyOrientation()`.
    @State private var landscapeMask: UIInterfaceOrientationMask = .landscapeRight
    /// Wybrany motocykl (sylwetka) — zapamiętywany.
    @AppStorage("riderModeBike") private var bikeRaw = BikeModel.gsx.rawValue
    @State private var showControls = true
    @State private var hideTask: DispatchWorkItem?
    /// Zero przechyłu ustawione przyciskiem kalibracji (trwałe).
    @AppStorage("riderCalibOffset") private var calibOffset = 0.0
    /// Rekordy liczone LOKALNIE z tego samego kąta co wyświetlany — inaczej
    /// kropki MAX pokazywałyby wartości z innego (roll-owego) źródła.
    @State private var maxL = 0.0
    @State private var maxR = 0.0

    private var bike: BikeModel { BikeModel(rawValue: bikeRaw) ?? .gsx }

    // ── Motyw czerwony (Candy Daring Red, jak plakat trasy) ──
    private static let redBright = Color(red: 1.00, green: 0.22, blue: 0.22)
    private static let redMain   = Color(red: 0.84, green: 0.04, blue: 0.13)
    private static let redDeep   = Color(red: 0.35, green: 0.01, blue: 0.05)
    /// Strony rekordów jak w małym wskaźniku na desce: lewa niebieska, prawa czerwona.
    private static let maxLeftColor  = Color(red: 0.20, green: 0.62, blue: 1.00)
    private static let maxRightColor = Color(red: 1.00, green: 0.22, blue: 0.14)

    /// Intensywność czerwieni rośnie z kątem — magnitudę widać, a całość zostaje w czerwieni.
    private func leanColor(_ deg: Double) -> Color {
        let t = min(abs(deg) / 55.0, 1.0)          // 0 = pion, 1 = mocny przechył
        return Color(red: 0.80 + 0.20 * t,
                     green: 0.16 * (1 - t) + 0.04,
                     blue:  0.20 * (1 - t) + 0.06)
    }

    /// Kąt osi „w prawo na ekranie” w układzie URZĄDZENIA — tego potrzebuje
    /// `MotionManager.lean(from:screenRotationDeg:)`.
    ///
    /// Znaki wyprowadzone z UIOrientation.h, bo w poziomie kąty wychodziły odwrotnie:
    ///   landscapeRight == UIDeviceOrientationLandscapeLeft → „home button on the right”,
    ///   czyli dolna krawędź (oś −y) wskazuje w prawo → prawo = (0,−1,0) → −90°.
    ///   landscapeLeft  → home button po lewej → prawo = (0,+1,0) → +90°.
    /// Wcześniej było odwrotnie, stąd lustrzany przechył po obróceniu telefonu.
    private var interfaceRotation: Double {
        let io = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.interfaceOrientation
        switch io {
        case .landscapeLeft:       return  90
        case .landscapeRight:      return -90
        case .portraitUpsideDown:  return 180   // prawo = (−1,0,0) ✓
        default:                   return   0   // pion: prawo = (+1,0,0) ✓
        }
    }

    private static func normalize(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }; if d < -180 { d += 360 }
        return d
    }

    /// Przechył pokazywany w tym widoku. Liczony z grawitacji jako wzniesienie
    /// poprzecznej osi ekranu — odporny na to, JAK MOCNO pasażer odchyla telefon
    /// do siebie (stary wzór zawyżał kąt o 1/cos(pitch) i wybijał 65° z byle drgnięcia).
    private var lean: Double {
        // Mostek CAN: kąt policzony przez motocykl nie zależy od tego, jak leży telefon,
        // więc ma pierwszeństwo. Gdy płytka zamilknie, wracamy do grawitacji poniżej.
        // Bez obcinania do ±65° — czujnik motocykla podaje prawdziwy kąt w całym zakresie.
        if motion.leanFromBike { return motion.leanAngleDeg }
        let raw = MotionManager.lean(from: motion.gravityVec,
                                     screenRotationDeg: interfaceRotation) - calibOffset
        return max(-65, min(65, Self.normalize(raw)))
    }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < geo.size.width      // poziom = niższy ekran
            ZStack {
                Color.black.ignoresSafeArea()

                // Poświata rosnąca z przechyłem
                RadialGradient(colors: [leanColor(lean).opacity(0.30), .clear],
                               center: .center, startRadius: 0,
                               endRadius: min(geo.size.width, geo.size.height) * 0.8)
                    .ignoresSafeArea()
                    .animation(.easeOut(duration: 0.4), value: lean)

                // POZIOM: wskaźnik skaluje się na CAŁĄ dostępną wysokość, statystyki
                // w wąskim słupku obok. Wcześniej zostawało pół ekranu pustego.
                if compact {
                    HStack(spacing: 12) {
                        leanGauge(size: min(geo.size.height * 0.96, geo.size.width * 0.62))
                            .frame(maxWidth: .infinity)
                        statsColumn(big: true)
                            .frame(width: min(geo.size.width * 0.24, 260))
                            .padding(.top, 52)      // pod chipem modelu
                            .padding(.bottom, 96)   // nad przyciskiem nagrywania
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 12)
                } else {
                    VStack(spacing: 18) {
                        leanGauge(size: min(geo.size.width * 0.96, geo.size.height * 0.58))
                        statsRow
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 16)
                }

                // Timer nagrywania — WIDOCZNY ZAWSZE gdy nagrywa (nie chowa się
                // razem z ikonami; po kliknięciu „nagrywaj" ma być stale na oku).
                if recorder.isRecording {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Circle().fill(.red).frame(width: 10, height: 10)
                                .opacity(recordingBlink ? 1 : 0.2)
                            Text(fmt(recorder.recordingSec))
                                .font(.system(size: compact ? 22 : 26, weight: .heavy, design: .monospaced))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, compact ? 14 : 96)
                    }
                    .allowsHitTesting(false)
                }

                if showControls { controlsOverlay(compact: compact) }
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleControls() }
            .onChange(of: motion.gravityVec) { _ in trackMax(lean) }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            // Bez tego UIDevice.current.orientation zwraca .unknown, więc
            // applyOrientation() nie wiedziałoby, w którą stronę trzymasz telefon.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            applyOrientation()
            UIApplication.shared.isIdleTimerDisabled = true   // ekran nie gaśnie
            if !motion.isActive { motion.start() }
            motion.setHighRateUI(true)       // ten widok pokazuje przechył na cały ekran — pełne 30 Hz
            scheduleHide()
        }
        .onDisappear {
            motion.setHighRateUI(false)
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            OrientationLock.reset()          // przywróć pion głównej apki
            hideTask?.cancel()
            // isIdleTimerDisabled zostaje pod kontrolą MotionManagera (nagrywanie trwa)
        }
    }

    // MARK: — Wskaźnik przechyłu

    /// Strefy przechyłu (heatmapa) — ta sama skala co na desce motocykla.
    private func zoneColor(_ deg: Double) -> Color {
        switch abs(deg) {
        case ..<25: return Color(red: 0.18, green: 0.85, blue: 0.48)
        case ..<40: return Color(red: 0.97, green: 0.80, blue: 0.15)
        case ..<52: return Color(red: 1.00, green: 0.50, blue: 0.05)
        default:    return Color(red: 1.00, green: 0.20, blue: 0.12)
        }
    }

    private func leanGauge(size: CGFloat) -> some View {
        let maxDeg = 60.0
        let lw = size * 0.040
        // Łuk odsunięty od krawędzi na tyle, żeby liczby rekordów zmieściły się
        // NA ZEWNĄTRZ niego i nie wychodziły poza ramkę wskaźnika.
        let inset = size * 0.085
        return ZStack {
            // ── Heatmapa: łuk pomalowany strefami (zielony → czerwony), lustrzanie ──
            ForEach(Array(stride(from: -maxDeg, to: maxDeg, by: 2.0).enumerated()), id: \.offset) { _, d in
                ArcShape(from: d, to: d + 2.3, inset: inset)
                    .stroke(zoneColor(d + 1), style: .init(lineWidth: lw, lineCap: .butt))
            }

            // ── Podziałka co 10° + opisy ──
            ForEach(Array(stride(from: -60, through: 60, by: 10).enumerated()), id: \.offset) { _, d in
                TickShape(deg: Double(d), long: d % 30 == 0, inset: inset)
                    .stroke(.white.opacity(d == 0 ? 0.85 : 0.45),
                            lineWidth: d % 30 == 0 ? 2.5 : 1.5)
            }

            // ── KRESKI rekordów MAX — osobno w lewo i w prawo ──
            if maxL > 2 { maxDot(deg: -min(maxL, maxDeg), value: maxL, size: size, inset: inset) }
            if maxR > 2 { maxDot(deg:  min(maxR, maxDeg), value: maxR, size: size, inset: inset) }

            // ── Wskaźnik bieżący ──
            TickShape(deg: lean, long: true, inset: inset)
                .stroke(.white, style: .init(lineWidth: 4, lineCap: .round))
                .shadow(color: zoneColor(lean), radius: 10)

            // ── Sylwetka W ŚRODKU koła, przechyla się na żywo ──
            BikeSilhouetteView(model: bike, color: zoneColor(lean))
                .frame(height: size * 0.40)
                .shadow(color: zoneColor(lean).opacity(0.7), radius: 12)
                .rotationEffect(.degrees(lean))
                .offset(y: -size * 0.03)
                .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.7), value: lean)

            // ── Liczba POD sylwetką ──
            VStack(spacing: 0) {
                Text(String(format: "%.0f°", abs(lean)))
                    .font(.system(size: size * 0.17, weight: .black, design: .rounded))
                    .foregroundStyle(zoneColor(lean))
                    .monospacedDigit()
                    .shadow(color: zoneColor(lean).opacity(0.7), radius: size * 0.04)
                    .contentTransition(.numericText())
                Text(lean < -1.5 ? "LEWO" : (lean > 1.5 ? "PRAWO" : "—"))
                    .font(.system(size: size * 0.045, weight: .heavy))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .offset(y: size * 0.33)
        }
        .frame(width: size, height: size)
    }

    /// Kropka rekordu na łuku + mała wartość obok.
    /// Znacznik rekordu — jeden do jednego z małym wskaźnikiem na desce
    /// (`FrameRenderer.drawLeanPanel`): kreska PRZECINAJĄCA łuk symetrycznie
    /// plus liczba tuż NA ZEWNĄTRZ, a strony rozróżnione kolorem —
    /// lewa niebieska, prawa czerwona. Kolor strefy się tu nie nadaje, bo
    /// zlewał się z heatmapą pod spodem i rekordu nie było widać.
    private func maxDot(deg: Double, value: Double, size: CGFloat, inset: CGFloat) -> some View {
        let r = size / 2 - inset
        let a = CGFloat(deg - 90) * .pi / 180
        let col = deg < 0 ? Self.maxLeftColor : Self.maxRightColor
        let reach = size * 0.048               // proporcja z deski: ±7 px przy R=74
        return ZStack {
            // Czarna obwódka — kreska musi być czytelna także tam, gdzie łuk
            // ma zbliżony kolor (czerwona strefa pod czerwonym rekordem prawym).
            TickShape(deg: deg, innerDrop: reach, outerRise: reach, inset: inset)
                .stroke(.black.opacity(0.85), style: .init(lineWidth: size * 0.030, lineCap: .round))
            TickShape(deg: deg, innerDrop: reach, outerRise: reach, inset: inset)
                .stroke(col, style: .init(lineWidth: size * 0.019, lineCap: .round))
                .shadow(color: col.opacity(0.9), radius: size * 0.022)

            Text(String(format: "%.0f°", value))
                .font(.system(size: size * 0.058, weight: .heavy, design: .rounded))
                .foregroundStyle(col)
                .monospacedDigit()
                .shadow(color: .black, radius: size * 0.012)
                .offset(x: cos(a) * (r + size * 0.052), y: sin(a) * (r + size * 0.052))
        }
    }

    // MARK: — Statystyki

    /// Pion — statystyki w rzędzie pod wskaźnikiem.
    private var statsRow: some View {
        HStack(spacing: 12) {
            ForEach(statItems, id: \.label) { s in
                stat(s.value, s.label, s.color, size: 30)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Poziom — statystyki w słupku obok wskaźnika (większe, jest miejsce).
    private func statsColumn(big: Bool) -> some View {
        VStack(spacing: big ? 20 : 14) {
            ForEach(statItems, id: \.label) { s in
                stat(s.value, s.label, s.color, size: big ? 42 : 30)
            }
        }
    }

    /// VMAX zamiast G — maksymalna prędkość jest ciekawsza dla pasażera.
    private var statItems: [(value: String, label: String, color: Color)] {
        [(   "\(Int(motion.speedKmh))",                     "km/h",  .white),
         (   "\(Int(motion.maxSpeedKmh))",                  "VMAX",  Self.redBright),
         (String(format: "%.0f°", maxL),                    "MAX L", .white.opacity(0.9)),
         (String(format: "%.0f°", maxR),                    "MAX R", .white.opacity(0.9))]
    }

    private func stat(_ value: String, _ label: String, _ color: Color, size: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .foregroundStyle(color).monospacedDigit()
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(label)
                .font(.system(size: size * 0.33, weight: .heavy)).tracking(1.5)
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: — Sterowanie (pływające ikony)

    private func controlsOverlay(compact: Bool) -> some View {
        VStack {
            HStack(spacing: 12) {
                iconButton("xmark", tint: .white.opacity(0.9)) { dismiss() }
                Spacer()
                if recorder.isRecording {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                            .opacity(recordingBlink ? 1 : 0.25)
                        Text(fmt(recorder.recordingSec))
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                // Wybór motocykla — cyklicznie po dostępnych sylwetkach
                Button {
                    let all = BikeModel.allCases
                    let i = all.firstIndex(of: bike) ?? 0
                    bikeRaw = all[(i + 1) % all.count].rawValue
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    scheduleHide()
                } label: {
                    Text(bike.rawValue)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                // KALIBRACJA — zeruje bieżącą pozycję. Potrzebna po każdej zmianie
                // sposobu trzymania telefonu (także po obrocie pion/poziom).
                iconButton("scope", tint: .white.opacity(0.9)) {
                    calibrate()
                }
                iconButton(landscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate",
                           tint: .white.opacity(0.9)) {
                    landscape.toggle()
                    applyOrientation()
                    // Obrót zmienia sposób trzymania telefonu — stare zero i rekordy
                    // przestają pasować. Kalibrujemy od nowa po ustabilizowaniu obrotu.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { calibrate() }
                    scheduleHide()
                }
            }
            .padding(.horizontal, 18).padding(.top, 8)

            Spacer()

            // Nagrywanie — duży, jednoznaczny przycisk.
            // W poziomie przesunięty w prawo (pod słupek statystyk) — wyśrodkowany
            // nachodziłby na sylwetkę motocykla we wskaźniku.
            HStack {
                Spacer()
                Button {
                if recorder.isRecording {
                    if let s = recorder.stop() { onFinish(s) }
                } else {
                    motion.resetStats()      // czysty licznik dla nowego kierowcy
                    maxL = 0; maxR = 0
                    recorder.start()
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                scheduleHide()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle")
                        .font(.system(size: 22, weight: .bold))
                    Text(recorder.isRecording ? "ZATRZYMAJ" : "NAGRYWAJ")
                        .font(.system(size: 16, weight: .heavy)).tracking(2)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 26).padding(.vertical, 14)
                .background(recorder.isRecording ? Color.red : Color.white.opacity(0.16),
                            in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                }
                if !compact { Spacer() }
            }
            .padding(.trailing, compact ? 44 : 0)
            .padding(.bottom, 26)
        }
        .transition(.opacity)
    }

    private func iconButton(_ systemName: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    // Mruganie kropki REC — bez timera, z zegara systemowego.
    private var recordingBlink: Bool { Int(Date().timeIntervalSince1970 * 2) % 2 == 0 }

    private func fmt(_ s: Int) -> String {
        let h = s/3600, m = (s%3600)/60, sec = s%60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    // MARK: — Orientacja / auto-ukrywanie

    /// Ustawia bieżącą pozycję telefonu jako 0° i zeruje rekordy.
    private func calibrate() {
        calibOffset = MotionManager.lean(from: motion.gravityVec,
                                        screenRotationDeg: interfaceRotation)
        maxL = 0; maxR = 0
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Rekordy z tego samego kąta, który pokazujemy (nie z roll-owego źródła).
    private func trackMax(_ v: Double) {
        if v < -2 { maxL = max(maxL, -v) }
        if v >  2 { maxR = max(maxR,  v) }
    }

    /// Blokuje KONKRETNĄ orientację, nigdy maski `.landscape`.
    ///
    /// `.landscape` zawiera landscapeLeft ORAZ landscapeRight, więc iOS mógł
    /// swobodnie przeskakiwać między nimi — widok obracał się sam, bez tapnięcia
    /// w guzik. Gorzej: przy takim przeskoku `interfaceRotation` zmieniało się
    /// z +90 na −90, czyli kompensacja odwracała ZNAK przechyłu i kąty leciały
    /// na odwrót. Jedna orientacja = stała kompensacja i zero samoobrotów.
    private func applyOrientation() {
        guard landscape else { OrientationLock.set(.portrait); return }

        // Stronę wybieramy raz, wg tego jak telefon jest TERAZ trzymany, żeby obrót
        // po tapnięciu był najmniejszy. Orientacja urządzenia jest odwrotna do
        // orientacji interfejsu (device .landscapeLeft → interface .landscapeRight).
        switch UIDevice.current.orientation {
        case .landscapeLeft:  landscapeMask = .landscapeRight
        case .landscapeRight: landscapeMask = .landscapeLeft
        default: break               // pion/faceUp/nieznana → zostaje poprzedni wybór
        }
        OrientationLock.set(landscapeMask)
    }

    /// Ikony chowają się TYLKO w trakcie nagrywania (czysty wskaźnik dla pasażera).
    /// Przed startem zostają widoczne — inaczej osoba, której dajesz telefon,
    /// nie miałaby czym uruchomić nagrywania. Tap zawsze przywraca.
    private func scheduleHide() {
        withAnimation(.easeOut(duration: 0.2)) { showControls = true }
        hideTask?.cancel()
        guard recorder.isRecording else { return }   // nie nagrywa → nie chowaj
        let t = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.4)) { showControls = false }
        }
        hideTask = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: t)
    }

    private func toggleControls() {
        if showControls {
            hideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.25)) { showControls = false }
        } else {
            scheduleHide()
        }
    }
}

// MARK: — Kształty wskaźnika

/// Łuk wycinka od `from`° do `to`° (0 = pion, dodatnie = w prawo).
private struct ArcShape: Shape {
    let from: Double, to: Double
    /// Odsunięcie łuku od krawędzi. Większe niż kiedyś, bo etykiety rekordów
    /// idą teraz NA ZEWNĄTRZ łuku (jak w małym wskaźniku na desce).
    var inset: CGFloat = 8
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2 - inset
        // 0° ma być u góry → przesunięcie o -90°
        p.addArc(center: c, radius: r,
                 startAngle: .degrees(from - 90), endAngle: .degrees(to - 90),
                 clockwise: false)
        return p
    }
}

/// Kreska na łuku pod kątem `deg`.
private struct TickShape: Shape {
    let deg: Double
    var long: Bool = false
    /// Jak głęboko kreska wchodzi do środka i jak daleko wystaje na zewnątrz.
    /// Domyślne wartości = zwykła podziałka; rekordy MAX podają własne.
    var innerDrop: CGFloat? = nil
    var outerRise: CGFloat = 8
    var inset: CGFloat = 8
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2 - inset
        let a = CGFloat(deg - 90) * .pi / 180
        let inner = r - (innerDrop ?? (long ? 26 : 14))
        p.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
        p.addLine(to: CGPoint(x: c.x + cos(a) * (r + outerRise), y: c.y + sin(a) * (r + outerRise)))
        return p
    }
}
