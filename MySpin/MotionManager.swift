// MotionManager.swift
// Telemetria z telefonu: GPS (prędkość, kurs, dystans) + IMU (lean angle, G-force)
// Wymaga NSLocationWhenInUseUsageDescription w Info.plist

import CoreMotion
import CoreLocation
import Combine
import UIKit

final class MotionManager: NSObject, ObservableObject {

    // MARK: — Published Data

    @Published var speedKmh:     Double = 0
    @Published var maxSpeedKmh:  Double = 0
    /// Średnia prędkość jazdy (tylko próbki > 5 km/h — postoje nie zaniżają).
    @Published var avgSpeedKmh:  Double = 0
    private var speedSum:    Double = 0
    private var speedCount:  Int    = 0
    /// Godzina zachodu słońca "20:41" (liczona lokalnie z GPS). Pusty = brak danych.
    @Published var sunsetString: String = ""
    private var sunsetDay: Int = -1
    /// Lean: < 0 = lewo (L), > 0 = prawo (R) — stopnie. Wartość NA ŻYWO (czuła, do wskaźnika).
    @Published var leanAngleDeg: Double = 0
    /// Lean wygładzony medianą 0.5s — bez spike'ów. To trafia do CSV i do rekordu MAX.
    @Published var leanSmoothedDeg: Double = 0

    /// Przechył z czujnika motocykla (mostek CAN), w tej samej konwencji znaku.
    /// Zwraca nil, gdy brak świeżych danych — wtedy próbka idzie z telefonu, jak dotąd.
    /// Ustawiać PRZED `start()`; wołane z kolejki IMU przy każdej próbce (30 Hz).
    var externalLean: (() -> Double?)? = nil
    /// Skąd pochodzi bieżący `leanAngleDeg` — do pokazania w interfejsie.
    @Published private(set) var leanFromBike = false
    /// Przechył z TELEFONU (po offsecie montażu), liczony zawsze — także wtedy, gdy
    /// wyświetlamy czujnik motocykla. Kalibracje telefonu korzystają wyłącznie z niego,
    /// więc nie rozjeżdżają się i telefon może przejąć w każdej chwili.
    /// Bez mostka CAN jest zawsze równy `leanAngleDeg`.
    private(set) var phoneLeanDeg: Double = 0
    /// Najświeższy ważny przechył (motocykl albo telefon) prosto z kolejki czujnika —
    /// bez progu zmiany i bez przeskoku na wątek główny. Czyta go renderer klatek,
    /// żeby wskazanie na motocyklu nie czekało na odświeżenie interfejsu telefonu.
    var liveLeanDeg: Double {
        stateLock.lock(); defer { stateLock.unlock() }
        return _liveLean
    }
    private var _liveLean: Double = 0

    // Wartości czytane wprost przez renderer deski i zapis logu (pod `stateLock`), żeby
    // nie zależały od tego, jak często odświeża się interfejs telefonu.
    var liveGForce: Double { stateLock.lock(); defer { stateLock.unlock() }; return _liveG }
    var livePhoneLeanDeg: Double { stateLock.lock(); defer { stateLock.unlock() }; return _livePhone }
    /// Rekordy trasy liczone na każdej próbce czujnika: przechył w lewo, w prawo, przeciążenie.
    var liveMax: (left: Double, right: Double, g: Double) {
        stateLock.lock(); defer { stateLock.unlock() }
        return (_maxL, _maxR, _maxG)
    }
    private var _liveG: Double = 0
    private var _livePhone: Double = 0
    private var _maxL: Double = 0, _maxR: Double = 0, _maxG: Double = 0
    private var _gateSpeed: Double = 0          // prędkość GPS do bramki rekordów
    private var _highRate = false
    private var lastCommitAt: TimeInterval = 0
    private var lastMaxCommit: (Double, Double, Double) = (0, 0, 0)

    /// Pełne tempo odświeżania interfejsu (30 Hz) — tylko dla widoku pasażera, który
    /// pokazuje przechył na cały ekran. Zwykły interfejs dostaje 10 Hz, a w tle 1 Hz.
    func setHighRateUI(_ on: Bool) {
        stateLock.lock(); _highRate = on; stateLock.unlock()
    }

    /// Przechył liczony z WEKTORA GRAWITACJI w płaszczyźnie ekranu, w układzie
    /// URZĄDZENIA (0° = telefon pionowo, dodatnie = przechylony w prawo).
    ///
    /// Po co osobno od `leanAngleDeg`: tamten bierze `attitude.roll`, czyli obrót
    /// wokół osi X telefonu. Gdy telefon obrócić do poziomu, przechył przestaje
    /// padać na tę oś (przechodzi w pitch) i odczyt jest błędny — to dlatego tryb
    /// pasażera po obrocie pokazywał złe wartości. Kąt z grawitacji jest niezależny
    /// od orientacji; konsument dodaje tylko obrót interfejsu (0/±90/180).
    ///
    /// Główna deska NIE korzysta z tego pola — jej ścieżka zostaje bez zmian.
    @Published var gravityVec = SIMD3<Double>(0, -1, 0)

    /// Przechył = WZNIESIENIE poprzecznej osi ekranu nad poziom.
    ///
    /// Wcześniej liczyliśmy `atan2(g.x, -g.y)`, czyli kąt grawitacji rzutowanej na
    /// płaszczyznę ekranu. To zawyża odczyt, gdy telefon jest odchylony do tyłu
    /// (pitch φ): wychodzi `atan2(sinθ, cosθ·cosφ)`, czyli przechył ×1/cos φ.
    /// Pasażer trzyma telefon mocno odchylony, więc przy φ≈60° realne 20° pokazywało
    /// 36°, a lekkie drgnięcie potrafiło wybić maksa 65°.
    ///
    /// Tutaj bierzemy składową grawitacji WZDŁUŻ poprzecznej osi ekranu i porównujemy
    /// z resztą wektora. `|g|` skraca się, pitch wypada z równania całkowicie.
    /// Bez pitchu wynik jest identyczny jak stary wzór minus `screenRotationDeg`,
    /// więc konwencja orientacji zostaje bez zmian.
    static func lean(from g: SIMD3<Double>, screenRotationDeg: Double) -> Double {
        let a   = screenRotationDeg * .pi / 180
        let lat = g.x * cos(a) + g.y * sin(a)          // oś „w prawo na ekranie”
        let rest = max(0, g.x*g.x + g.y*g.y + g.z*g.z - lat*lat)
        return atan2(lat, sqrt(rest)) * (180 / .pi)
    }

    @Published var maxLeanLeft:  Double = 0   // abs deg
    @Published var maxLeanRight: Double = 0   // abs deg
    @Published var maxGforce: Double = 0  // max EMA-wygładzone G
    @Published var gForce:       Double = 0   // g-siła (przyspieszenie telefonu)
    @Published var headingDeg:   Double = -1  // kurs GPS 0=N, 90=E; -1=brak
    @Published var altitudeM:    Double = 0
    @Published var tripDistKm:   Double = 0
    @Published var gpsAccuracy:  Double = -1  // metry (-1 = brak sygnału)
    @Published var sessionSec:   Int    = 0
    @Published var isActive:     Bool   = false

    // MARK: — Private

    private let cm  = CMMotionManager()
    private let loc = CLLocationManager()

    // MARK: — Kalibracja (odliczanie ręczne)

    /// -1=idle, 5..1=odliczanie, 0=pomiar, -2="Skalibrowano"(2s)
    @Published var calibrationCountdown: Int = -1

    private var lastLoc:          CLLocation?
    /// Ostatnia współrzędna GPS — udostępniana do SessionRecorder
    private(set) var lastLocationCoord: CLLocationCoordinate2D? = nil
    /// Znacznik czasu ostatniego fixa GPS (nie chwila odczytu) — do pomiaru czasu odcinków.
    private(set) var lastLocationTime: Date? = nil
    /// Callback przy aktualizacji prędkości z GPS (kmh, czas fixu) — do PerfMeter
    var onSpeedUpdate: ((Double, Date) -> Void)? = nil
    private var sessionStart:     Date?
    // Throttling — ostatnie wartości IMU jakie skomitowaliśmy do @Published
    private var lastLeanCommit:   Double = 0
    private var lastPhoneCommit:  Double = 0
    private var lastFromBike:     Bool   = false
    private var lastGCommit:      Double = 0
    // Rolling median (75. percentyl) — twardy filtr spikeów
    // 30 próbek (1s @ 30Hz): spike 1-9 klatek całkowicie wycięty, latency ~0.30s
    private var gBuffer:          [Double] = []
    private let gBufferSize:      Int    = 30
    private let gPercentile:      Double = 0.75
    // Bufor mediany leanu — 21 próbek @30Hz = 0.7s. Rozmiar dobrany testem offline:
    //   okno 15 → glitch 8-klatkowy przeciekał (38° zamiast 31°)
    //   okno 21 → glitch 8 i 15-klatkowy odrzucony w całości, realny zakręt 47° zachowany 1:1
    //   okno 31 → to samo co 21, ale większe opóźnienie
    private var leanBuffer:       [Double] = []
    private let leanBufferSize:   Int    = 21

    /// Zamek na stanie dzielonym między handlerem IMU (wątek tła) a main (kalibracja).
    /// KRYTYCZNE: bez tego równoległe callbacki CoreMotion niszczyły COW-bufor
    /// `gBuffer` → SIGSEGV w Array.append (crash losowo w trakcie jazdy).
    private let stateLock = NSLock()

    /// JEDNA, SZEREGOWA kolejka IMU na cały cykl życia. Apple wymaga tu kolejki
    /// szeregowej; `OperationQueue()` jest domyślnie WSPÓŁBIEŻNA (maxConcurrent = -1),
    /// więc callbacki 30 Hz wchodziły równolegle na kilku wątkach. Reużywamy jej też
    /// dlatego, że refreshOnForeground() tworzył nową kolejkę przy każdym wejściu na
    /// 1. plan — stary i nowy strumień nakładały się na tym samym buforze.
    private let imuQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "MySpin.IMU"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private var timerBag          = Set<AnyCancellable>()
    private var sessionTimer:     DispatchSourceTimer?
    private var calibrationTimer: DispatchSourceTimer?
    private var modeCalTimer:     DispatchSourceTimer?
    // Kalibracja kąta montażu (deg). Trwała — przeżywa restart (didSet zapisuje).
    // Backing storage — NIE dotykać bezpośrednio poza sekcją pod `stateLock`.
    private var _mountOffset: Double = UserDefaults.standard.double(forKey: "mountOffset") {
        didSet { UserDefaults.standard.set(_mountOffset, forKey: "mountOffset") }
    }
    /// Offset montażu. Czytany z wątku IMU, zapisywany z main (kalibracja) → pod zamkiem.
    /// UWAGA: w sekcji już trzymającej `stateLock` używaj `_mountOffset` (NSLock nie jest
    /// rekurencyjny — zagnieżdżone użycie tego akcesora = deadlock).
    private var mountOffset: Double {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _mountOffset }
        set {
            stateLock.lock()
            _mountOffset = newValue
            // Zmiana punktu zerowego (kalibracja) unieważnia próbki w buforze mediany —
            // były liczone względem starego offsetu. Bez tego przez ~0.5s mediana kłamie.
            leanBuffer.removeAll(keepingCapacity: true)
            stateLock.unlock()
        }
    }

    // MARK: — Mode Calibration (histogram)
    // Próbkujemy lean co 0.5s podczas jazdy > 20 km/h.
    // Moda rozkładu = "jedź prosto" = powinno być 0°.
    // Jeśli moda ≠ 0° → stopniowo korygujemy mountOffset.
    //
    // Rozdzielczość 0.5° (key = Int(leanDeg × 2), wartość = liczba próbek).
    private var modeHistogram:    [Int: Int] = [:]
    private var modeHistSamples:  Int = 0
    /// Postęp zbierania próbek (0–100%). Gdy 100% → kalibracja aktywna.
    @Published var modeCalProgress: Int = 0
    /// Referencja "punkt zerowy" — ustawiana przy każdej ręcznej kalibracji.
    /// Mode-cal może modyfikować mountOffset tylko w obrębie ±modeCalMaxDriftDeg
    /// od tej referencji — żeby długi zakręt nie znosił prawdziwego zera.
    private var manualOffsetReference: Double = 0

    private let modeCalMinSamples  = 120    // ~60s przy 2Hz zanim pierwsza korekcja
    private let modeCalSpeedMin    = 20.0   // km/h — poniżej nie próbkujemy
    private let modeCalApplyThresh = 1.5    // ° — minimalna różnica żeby korygować
    private let modeCalConfidence  = 0.15   // moda musi stanowić > 15% próbek
    private let modeCalCorrFactor  = 0.30   // 30% korekcji na krok (miękkie wejście)
    private let modeCalApplyEvery  = 40     // sprawdzaj modę co 40 nowych próbek
    private let modeCalMaxDriftDeg = 5.0    // ±5° od ręcznej kalibracji — limit dryfu

    override init() {
        super.init()
        loc.delegate         = self
        loc.desiredAccuracy  = kCLLocationAccuracyBestForNavigation
        loc.distanceFilter   = kCLDistanceFilterNone
        loc.headingFilter    = 1.0
        loc.allowsBackgroundLocationUpdates    = true   // GPS działa gdy app w tle
        loc.pausesLocationUpdatesAutomatically = false  // iOS nie wstrzymuje GPS
        loc.activityType = .automotiveNavigation   // lepszy sensor fusion GPS w pojeździe
    }

    // MARK: — Mode Calibration helpers

    /// Uruchamia 2Hz próbkowanie lean angle do histogramu.
    private func startModeCalTimer() {
        modeCalTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.sampleLeanForModeCal() }
        t.resume()
        modeCalTimer = t
    }

    /// Jeden tick próbkowania: dodaj lean do histogramu (tylko gdy prędkość OK).
    private func sampleLeanForModeCal() {
        guard speedKmh >= modeCalSpeedMin else { return }
        let key = Int(phoneLeanDeg * 2.0)   // rozdzielczość 0.5°
        modeHistogram[key, default: 0] += 1
        modeHistSamples += 1

        // Postęp do pierwszego progu kalibracji
        modeCalProgress = min(100, modeHistSamples * 100 / modeCalMinSamples)

        // Sprawdzaj modę co modeCalApplyEvery próbek (ale nie przed minimalnym progiem)
        if modeHistSamples >= modeCalMinSamples,
           modeHistSamples % modeCalApplyEvery == 0 {
            applyModeCalibration()
        }
    }

    /// Wyznacza modę histogramu i jeśli różni się od 0° — koryguje mountOffset.
    /// HARD CAP: mountOffset nie może odjechać dalej niż ±modeCalMaxDriftDeg
    /// od ostatniej ręcznej kalibracji. Inaczej długi zakręt zacząłby być
    /// traktowany jako "neutralna pozycja" i znosił prawdziwe zero.
    private func applyModeCalibration() {
        guard let (modeKey, modeCount) = modeHistogram.max(by: { $0.value < $1.value })
        else { return }

        let confidence = Double(modeCount) / Double(modeHistSamples)
        guard confidence >= modeCalConfidence else { return }

        let modeDeg = Double(modeKey) / 2.0    // cofnij skalowanie 0.5°
        guard abs(modeDeg) >= modeCalApplyThresh else { return }

        // Miękka korekcja: 30% różnicy na krok
        let correction = modeDeg * modeCalCorrFactor
        let proposed   = mountOffset + correction

        // ── Drift cap: ±5° od ostatniej ręcznej kalibracji ──
        let drift  = proposed - manualOffsetReference
        let capped = abs(drift) > modeCalMaxDriftDeg
            ? manualOffsetReference + (drift > 0 ? modeCalMaxDriftDeg : -modeCalMaxDriftDeg)
            : proposed
        // Jeśli już jesteśmy na cap'ie i mode-cal chce dalej w tę samą stronę → ignoruj
        let actualCorrection = capped - mountOffset
        guard abs(actualCorrection) > 0.001 else {
            // Cap aktywny i nie ma sensu robić więcej — wyczyść histogram, niech zbiera nowe próbki
            resetModeHistogram()
            return
        }
        mountOffset = capped

        // Przesuń histogram o realnie zastosowaną korekcję
        let shiftKeys = Int(actualCorrection * 2.0)
        var shifted: [Int: Int] = [:]
        for (k, v) in modeHistogram { shifted[k - shiftKeys, default: 0] += v }
        modeHistogram = shifted
    }

    /// Czyści histogram (po ręcznej lub auto kalibracji — jedziemy od nowa).
    private func resetModeHistogram() {
        modeHistogram.removeAll()
        modeHistSamples = 0
        modeCalProgress = 0
    }

    // MARK: — API

    func start() {
        guard !isActive else { return }
        isActive     = true
        sessionStart = Date()
        // Ekran nie usypia gdy sensory pracują — blokada ekranu → background →
        // iOS usypia app i zamraża IMU/GPS. To główna przyczyna „sensory stoją".
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = true }
        loc.requestWhenInUseAuthorization()
        startMotion()
        startSessionTimer()
        startModeCalTimer()
    }

    /// Powrót na 1. plan — CoreMotion potrafi „zasnąć" gdy app była w tle/ekran zgasł.
    /// Restartujemy strumień device-motion, żeby lean/G znów leciały (GPS wznawia się sam).
    func refreshOnForeground() {
        guard isActive else { return }
        // Wygaś stary strumień DO KOŃCA zanim wystartuje nowy — inaczej callbacki
        // starego i nowego nakładały się na tym samym stanie (crash przy wejściu w apkę).
        drainIMU()
        startMotion()
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = true }
    }

    /// Zatrzymuje device-motion i czeka aż kolejka IMU opróżni się z callbacków w locie.
    /// Handler nigdy nie robi sync-hopu na main (tylko async), więc to nie zablokuje main.
    private func drainIMU() {
        cm.stopDeviceMotionUpdates()
        imuQueue.cancelAllOperations()
        imuQueue.waitUntilAllOperationsAreFinished()
    }

    func stop() {
        isActive = false
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false }
        drainIMU()
        loc.stopUpdatingLocation()
        loc.stopUpdatingHeading()
        timerBag.removeAll()
        sessionTimer?.cancel();     sessionTimer     = nil
        calibrationTimer?.cancel(); calibrationTimer = nil
        modeCalTimer?.cancel();     modeCalTimer     = nil
    }

    /// Rozpocznij tryb kalibracji — 5s odliczanie, potem przechwycenie kąta
    func startCalibration() {
        guard calibrationCountdown == -1 else { return }   // już w toku
        calibrationCountdown = 5
        calibrationTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            switch self.calibrationCountdown {
            case 1...:
                self.calibrationCountdown -= 1
            case 0:
                // Pomiar — aktualna wartość lean = offset montażu
                self.mountOffset += self.phoneLeanDeg
                self.phoneLeanDeg = 0
                if !self.leanFromBike {
                    self.leanAngleDeg = 0
                    self.stateLock.lock(); self._liveLean = 0; self.stateLock.unlock()
                }
                self.manualOffsetReference = self.mountOffset   // nowy punkt zerowy
                self.resetModeHistogram()               // zacznij histogram od nowa
                self.calibrationCountdown = -2          // "Skalibrowano ✓"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.calibrationCountdown = -1     // wróć do idle
                }
                self.calibrationTimer?.cancel()
                self.calibrationTimer = nil
            default:
                break
            }
        }
        t.resume()
        calibrationTimer = t
    }

    /// Zeruje rekordy (max prędkość, max lean, dystans, czas)
    func resetStats() {
        maxSpeedKmh  = 0
        maxLeanLeft  = 0
        maxLeanRight = 0
        maxGforce = 0
        stateLock.lock(); _maxL = 0; _maxR = 0; _maxG = 0; stateLock.unlock()
        tripDistKm   = 0
        sessionSec   = 0
        sessionStart  = Date()
        avgSpeedKmh = 0; speedSum = 0; speedCount = 0
    }

    /// Kalibracja — ustawia aktualny lean jako 0° (stój prosto, motocykl pionowo)
    func calibrate() {
        mountOffset += phoneLeanDeg
        manualOffsetReference = mountOffset      // nowy punkt zerowy dla mode-cal drift cap
        resetModeHistogram()
    }

    // MARK: — Kalibracja dwupunktowa (garaż ↔ pion, z różnicą)
    // A = garaż: nóżka boczna + kierownica max L (zawsze ta sama pozycja wyjazdowa).
    // B = pion: podnośnik, kierownica prosto (prawdziwe zero).
    // delta = uprightRaw − garageRaw (stała). Codziennie w pozycji A klikasz
    // „Kalibruj z garażu" → mountOffset = teraz + delta → po wyprostowaniu idealne 0.

    /// Surowy odczyt żyroskopu (roll przed offsetem montażu), w stopniach.
    var currentRawRoll: Double { phoneLeanDeg + mountOffset }

    /// Odczyt A (garaż) — surowy roll przy nóżce + kierownicy max L. Edytowalny, trwały.
    @Published var calGarageRaw: Double = UserDefaults.standard.double(forKey: "cal.garageRaw") {
        didSet { UserDefaults.standard.set(calGarageRaw, forKey: "cal.garageRaw") }
    }
    /// Odczyt B (pion) — surowy roll na podnośniku, kierownica prosto. Edytowalny, trwały.
    @Published var calUprightRaw: Double = UserDefaults.standard.double(forKey: "cal.uprightRaw") {
        didSet { UserDefaults.standard.set(calUprightRaw, forKey: "cal.uprightRaw") }
    }
    /// Różnica delta = uprightRaw − garageRaw. Edytowalna, trwała (osobno od A/B).
    @Published var calDelta: Double = UserDefaults.standard.double(forKey: "cal.delta") {
        didSet { UserDefaults.standard.set(calDelta, forKey: "cal.delta") }
    }
    /// Czy mamy komplet do kalibracji z garażu (delta ustawiona).
    var hasGarageCal: Bool { calDelta != 0 || calUprightRaw != 0 || calGarageRaw != 0 }

    /// Zmierz A — zapisz bieżący surowy roll jako pozycję garażową.
    func captureGarageRef()  { calGarageRaw  = currentRawRoll }
    /// Zmierz B — zapisz bieżący surowy roll jako pion.
    func captureUprightRef() { calUprightRaw = currentRawRoll }
    /// Przelicz różnicę z A i B.
    func recomputeCalDelta() { calDelta = calUprightRaw - calGarageRaw }

    /// Codzienna kalibracja: moto w pozycji garażowej → ustaw zero z użyciem delty.
    /// mountOffset = surowy_teraz + delta  ⇒  po wyprostowaniu (pion) lean = 0.
    func calibrateFromGarage() {
        mountOffset = currentRawRoll + calDelta
        manualOffsetReference = mountOffset
        resetModeHistogram()
    }

    /// Symulacja jazdy — do testów bez motocykla
    func simulateRide() {
        speedKmh     = Double.random(in: 85...185)
        maxSpeedKmh  = max(maxSpeedKmh, speedKmh)
        let lean     = Double.random(in: -42...42)
        leanAngleDeg = lean
        phoneLeanDeg = lean
        if lean < 0 { maxLeanLeft  = max(maxLeanLeft,  -lean) }
        else         { maxLeanRight = max(maxLeanRight,  lean) }
        stateLock.lock()
        _liveLean = lean; _livePhone = lean; _gateSpeed = speedKmh
        _maxL = maxLeanLeft; _maxR = maxLeanRight
        stateLock.unlock()
        gForce       = Double.random(in: 0.05...0.7)
        headingDeg   = Double.random(in: 0...360)
        altitudeM    = Double.random(in: 180...450)
        tripDistKm  += Double.random(in: 0.05...0.2)
        gpsAccuracy  = Double.random(in: 5...18)
    }

    // MARK: — Private

    private func startMotion() {
        guard cm.isDeviceMotionAvailable else { return }
        // 30 Hz IMU — wystarczające dla wyświetlacza 15fps, dwa razy mniej @Published spam'u
        cm.deviceMotionUpdateInterval = 1.0 / 30.0
        // Background queue dla IMU (szeregowa, reużywana) — main robi tylko
        // @Published commit (≤20Hz, throttle by delta).
        cm.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: imuQueue) { [weak self] data, _ in
            guard let self, let d = data else { return }
            self.process(rollRad: d.attitude.roll,
                         gravity: SIMD3<Double>(d.gravity.x, d.gravity.y, d.gravity.z),
                         userAccel: SIMD3<Double>(d.userAcceleration.x, d.userAcceleration.y, d.userAcceleration.z))
        }
    }

    #if DEBUG
    private var loadTimer: DispatchSourceTimer?
    /// Próba obciążenia (env LOAD_TEST): sztuczny czujnik 30 Hz i GPS 1 Hz, jak w jeździe —
    /// do pomiaru zużycia procesora w symulatorze, gdzie prawdziwych czujników nie ma.
    func debugStartLoad() {
        guard loadTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "motion.loadtest"))
        var n = 0
        t.schedule(deadline: .now() + 1, repeating: 1.0 / 30.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            n += 1
            let x = Double(n) / 30
            let roll = (28 * sin(x / 2.3) + 2 * sin(x * 7)) * .pi / 180
            let g = SIMD3<Double>(sin(roll), -cos(roll), 0.05 * sin(x))
            let a = SIMD3<Double>(0.25 * sin(x * 1.7), 0.1 * sin(x * 3.1), 0.2 * cos(x * 0.9))
            self.imuQueue.addOperation { self.process(rollRad: roll, gravity: g, userAccel: a) }
            if n % 30 == 0 { DispatchQueue.main.async { self.simulateRide() } }
        }
        t.resume()
        loadTimer = t
    }
    #endif

    /// Jedna próbka czujnika ruchu telefonu. Zawsze na kolejce `imuQueue`.
    private func process(rollRad: Double, gravity gravVec: SIMD3<Double>, userAccel ua: SIMD3<Double>) {
        do {
            // Czujnik motocykla, jeśli akurat podaje świeży kąt (poza zamkiem — ma własny).
            let bikeLean = self.externalLean?()
            let fromBike = bikeLean != nil

            // ── Cały stan dzielony pod jednym zamkiem ────────────────────────────
            // Nawet przy szeregowej kolejce stary strumień (sprzed refreshOnForeground)
            // może chwilowo nakładać się na nowy — a Array/COW nie jest thread-safe.
            self.stateLock.lock()
            // Telefon liczymy zawsze: to on przejmuje, gdy motocykl zamilknie.
            let phoneLean = rollRad * (180.0 / .pi) - self._mountOffset
            let phoneValid = abs(phoneLean) <= 75.0
            let leanRaw = bikeLean ?? phoneLean
            // Zmiana źródła unieważnia bufor mediany — próbki były z innego czujnika.
            if fromBike != self.lastFromBike {
                self.lastFromBike = fromBike
                self.leanBuffer.removeAll(keepingCapacity: true)
            }
            // FIZYCZNY LIMIT: motocykl nie przekracza ~65°. Wartość > 75° = artefakt
            // wraparoundu kąta Eulera (singularność gdy telefon mocno pochylony przód/tył:
            // wybój, hamowanie, podrzut koła) — roll przeskakuje w stronę ±180°.
            // Taka klatka NIE może zaktualizować lean ani rekordu. G liczymy dalej.
            // Dotyczy tylko telefonu: kąt z czujnika motocykla nie ma tej wady, więc
            // przechodzi bez żadnego progu — także 90° po przewróceniu.
            let leanValid = fromBike || abs(leanRaw) <= 75.0

            // Surowy wektor grawitacji (`gravVec`) idzie dalej bez zmian — kąt liczy konsument
            // (patrz `lean(from:…)`), bo zależy od orientacji interfejsu, której MotionManager nie zna.
            let gRaw  = sqrt(ua.x*ua.x + ua.y*ua.y + ua.z*ua.z)
            // Rolling median (75. percentyl): spike < 9 klatek → całkowicie wycięty
            self.gBuffer.append(gRaw)
            if self.gBuffer.count > self.gBufferSize { self.gBuffer.removeFirst() }
            let sorted = self.gBuffer.sorted()
            let idx    = min(Int(Double(sorted.count) * self.gPercentile), sorted.count - 1)
            let g      = sorted[idx]

            // ── MEDIANA KROCZĄCA LEANU — filtr rekordu i zapisu do CSV ──────────
            // Pojedynczy filtr progowy nie wystarczał: glitch potrafi narastać po
            // kilka stopni na klatkę (więc omija filtr skoku) i zatrzymać się tuż pod
            // capem — stąd fałszywe „61°" przy realnych ~31°. Mediana z 0.7s całkowicie
            // wycina takie artefakty, a realny przechył w zakręcie (sekundy) przechodzi
            // nienaruszony. Ta sama technika co dla G-force.
            if leanValid {
                self._liveLean = leanRaw
                self.leanBuffer.append(leanRaw)
                if self.leanBuffer.count > self.leanBufferSize { self.leanBuffer.removeFirst() }
            }
            var leanMedian: Double? = nil
            if self.leanBuffer.count >= self.leanBufferSize {
                let sortedLean = self.leanBuffer.sorted()
                leanMedian = sortedLean[sortedLean.count / 2]
            }

            self._liveG = g
            if phoneValid { self._livePhone = phoneLean }

            // REKORDY — liczone tutaj, na każdej próbce, niezależnie od tego, jak często
            // odświeża się interfejs. Wpuszczamy TYLKO wygładzoną medianę, w realnej jeździe
            // (≥15 km/h) i tylko gdy fizycznie realną: motocykl uliczny nie przekracza
            // ~50-55° (podnóżki szorują), wszystko powyżej jest z definicji artefaktem telefonu.
            // Limit dotyczy telefonu; czujnikowi motocykla wierzymy w całym zakresie.
            let maxLeanRecordCap = 55.0
            if leanValid, self._gateSpeed >= 15, let m = leanMedian, fromBike || abs(m) <= maxLeanRecordCap {
                if m < 0 { self._maxL = max(self._maxL, -m) } else { self._maxR = max(self._maxR, m) }
            }
            if self._gateSpeed > 0 { self._maxG = max(self._maxG, g) }
            let maxNow = (self._maxL, self._maxR, self._maxG)

            // Przekazanie do interfejsu telefonu: tylko gdy coś się zmieniło (< 0.3° i < 0.05g
            // pomijamy) i nie częściej, niż interfejs tego potrzebuje. Każde takie przekazanie
            // przelicza cały ekran apki — 30 razy na sekundę zjadało prawie cały rdzeń, a w tle
            // iOS ubija apkę powyżej 80% przez minutę. Deska na motocyklu czyta wartości
            // „na żywo" spod zamka, więc to tempo jej nie dotyczy.
            let nowT = ProcessInfo.processInfo.systemUptime
            let minInterval = (self._highRate || AppActivity.legacyRates) ? 0 : AppActivity.uiInterval(0.1)
            let leanDelta = leanValid ? abs(leanRaw - self.lastLeanCommit) : 0
            let phoneDelta = phoneValid ? abs(phoneLean - self.lastPhoneCommit) : 0
            let gDelta    = abs(g - self.lastGCommit)
            let changed = leanDelta > 0.3 || phoneDelta > 0.3 || gDelta > 0.05 || maxNow != self.lastMaxCommit
            let shouldCommit = changed && nowT - self.lastCommitAt >= minInterval
            if shouldCommit {
                self.lastCommitAt = nowT
                if leanValid { self.lastLeanCommit = leanRaw }
                if phoneValid { self.lastPhoneCommit = phoneLean }
                self.lastGCommit = g
                self.lastMaxCommit = maxNow
            }
            self.stateLock.unlock()
            // ── Koniec sekcji krytycznej — zamka NIE trzymamy przez skok na main ──

            guard shouldCommit else { return }

            DispatchQueue.main.async {
                self.gForce = g
                self.gravityVec = gravVec        // tryb pasażera liczy z tego swój kąt
                if phoneValid { self.phoneLeanDeg = phoneLean }
                if self.leanFromBike != fromBike { self.leanFromBike = fromBike }
                if leanValid {
                    // WSKAŹNIK: zawsze pokazuj przechył na żywo (glitch >75° pomijamy).
                    self.leanAngleDeg = leanRaw
                    // Wygładzony kąt — to trafia do CSV (rekord trasy bez spike'ów).
                    if let m = leanMedian { self.leanSmoothedDeg = m }
                }
                if self.maxLeanLeft != maxNow.0 { self.maxLeanLeft = maxNow.0 }
                if self.maxLeanRight != maxNow.1 { self.maxLeanRight = maxNow.1 }
                if self.maxGforce != maxNow.2 { self.maxGforce = maxNow.2 }
            }
        }
    }

    private func startSessionTimer() {
        sessionTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in
            guard let self, let s = self.sessionStart else { return }
            self.sessionSec = Int(-s.timeIntervalSinceNow)
        }
        t.resume()
        sessionTimer = t
    }
}

// MARK: — CLLocationManagerDelegate

extension MotionManager: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last, l.horizontalAccuracy > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.gpsAccuracy = l.horizontalAccuracy
            if l.speed >= 0 {
                let kmh = l.speed * 3.6
                self.speedKmh    = kmh
                self.stateLock.lock(); self._gateSpeed = kmh; self.stateLock.unlock()
                self.maxSpeedKmh = max(self.maxSpeedKmh, kmh)
                // Średnia z próbek w ruchu (>5 km/h) — postoje nie zaniżają średniej.
                if kmh > 5 {
                    self.speedSum += kmh; self.speedCount += 1
                    self.avgSpeedKmh = self.speedSum / Double(self.speedCount)
                }
                self.onSpeedUpdate?(kmh, l.timestamp)   // miernik osiągów (czas fixu GPS)
            }
            self.altitudeM          = l.altitude
            self.lastLocationCoord  = l.coordinate
            self.lastLocationTime   = l.timestamp
            if let prev = self.lastLoc {
                let d = l.distance(from: prev) / 1000.0
                if d < 0.3 { self.tripDistKm += d }  // cap: sanity check
            }
            self.lastLoc = l
            self.updateSunset(l.coordinate)
        }
    }

    // MARK: — Zachód słońca (liczony lokalnie z GPS, bez API)

    private static let sunsetFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    /// Przelicza zachód raz na dobę (chyba że jeszcze go nie ma).
    private func updateSunset(_ c: CLLocationCoordinate2D) {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        guard day != sunsetDay || sunsetString.isEmpty else { return }
        if let s = Self.computeSunset(lat: c.latitude, lon: c.longitude, date: Date()) {
            sunsetString = Self.sunsetFmt.string(from: s)
            sunsetDay = day
        }
    }

    /// Zachód słońca wg równania słonecznego (NOAA/Wikipedia). nil = brak (okolice biegunów).
    static func computeSunset(lat: Double, lon: Double, date: Date) -> Date? {
        let deg = Double.pi / 180
        let jd  = date.timeIntervalSince1970 / 86400.0 + 2440587.5
        let n   = (jd - 2451545.0 + 0.0008).rounded()
        let jStar = n - lon / 360.0   // długość wsch. dodatnia — empirycznie poprawny znak
        var M = (357.5291 + 0.98560028 * jStar).truncatingRemainder(dividingBy: 360)
        if M < 0 { M += 360 }
        let Mr = M * deg
        let C  = 1.9148*sin(Mr) + 0.0200*sin(2*Mr) + 0.0003*sin(3*Mr)
        var lambda = (M + C + 180 + 102.9372).truncatingRemainder(dividingBy: 360)
        if lambda < 0 { lambda += 360 }
        let lr = lambda * deg
        let jTransit = 2451545.0 + jStar + 0.0053*sin(Mr) - 0.0069*sin(2*lr)
        let sinDelta = sin(lr) * sin(23.44 * deg)
        let delta = asin(sinDelta)
        let latR = lat * deg
        let cosOmega = (sin(-0.833 * deg) - sin(latR)*sin(delta)) / (cos(latR)*cos(delta))
        guard cosOmega >= -1, cosOmega <= 1 else { return nil }
        let omega = acos(cosOmega) / deg
        let jSet = jTransit + omega / 360.0
        return Date(timeIntervalSince1970: (jSet - 2440587.5) * 86400.0)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading h: CLHeading) {
        DispatchQueue.main.async { [weak self] in
            self?.headingDeg = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        guard s == .authorizedWhenInUse || s == .authorizedAlways else { return }
        loc.startUpdatingLocation()
        loc.startUpdatingHeading()
    }
}
