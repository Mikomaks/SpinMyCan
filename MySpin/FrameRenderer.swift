// FrameRenderer.swift
// Dashboard motocykla — dane z telefonu (GPS + IMU)
// Canvas 864×320 → JPEG na wyświetlacz mySPIN
//
// Styl: czerwony dominujący na bardzo ciemnym tle
// Czcionka: Monocraft (https://github.com/IdreesInc/Monocraft)
//   → dodaj Monocraft.ttf do projektu + UIAppFonts w Info.plist
//   → bez pliku: automatyczny fallback na SF Mono (też wygląda dobrze)
//
// Układ 864×320:
//   [32px HEADER: status GPS, brand, czas, alt]
//   [210px LEAN] | [444px SPEED] | [210px STATS]
//   [30px LEAN BAR: wizualny pasek kąta przechyłu]

import UIKit
import CoreText
import Combine

final class FrameRenderer: ObservableObject {

    // MARK: — Wymiary i jakość
    let width:  Int
    let height: Int
    var jpegQuality: CGFloat = 0.55   // przy skali 1 (864×320) to ok. 35 KB na klatkę
                                       // Adaptive (ContentView.onFrameRTT): 0.40 … maxStreamQuality zależnie od RTT
    /// Górna granica jakości klatki na motocykl. Wyżej nie ma sensu: w jeździe 2026-10-13
    /// jakość stała na 0,85 (klatki 70 kB, ok. 850 kB/s po WiFi motocykla), a wyświetlacz
    /// i tak brał ok. 12 klatek na sekundę. Przy 0,60 klatka ma ok. 40 kB, obraz na
    /// rozdzielczości wyświetlacza wygląda tak samo, a radio telefonu ma o połowę mniej pracy.
    static let maxStreamQuality: CGFloat = 0.60

    // MARK: — Motyw (ciemny/jasny) — przełączany z ContentView
    var isDarkMode: Bool = true

    // MARK: — Dane do renderowania (ustawiaj z MotionManager przed każdym render())
    var speedKmh:     Double = 0
    var maxSpeedKmh:  Double = 0
    var leanAngleDeg: Double = 0   // < 0 = lewo (L),  > 0 = prawo (R), stopnie
    var maxLeanLeft:  Double = 0   // absolutne stopnie
    var maxLeanRight: Double = 0   // absolutne stopnie
    var gForce:       Double = 0
    var maxGforce:    Double = 0
    var headingDeg:   Double = -1  // -1 = brak GPS
    var altitudeM:    Double = 0
    var tripDistKm:   Double = 0
    var gpsAccuracy:  Double = -1  // metry (-1 = brak sygnału)
    var sessionSec:   Int    = 0
    var avgSpeedKmh:  Double = 0   // średnia prędkość jazdy (HUD)
    var recordingActive: Bool = false   // czy trasa się nagrywa (mrugająca kropka REC)
    var sunsetString: String = ""  // godzina zachodu słońca "20:41" (HUD)

    // Kalibracja — -1=idle, 5..1=odliczanie, 0=pomiar, -2=done
    var calibrationCountdown: Int = -1

    /// Zamrożony czas dla zrzutów wzorcowych (zegar w nagłówku i mruganie REC
    /// zależą od zegara, więc bez tego dwa rendery tej samej sceny różnią się
    /// pikselami i nie da się ich porównać). W normalnej pracy nil = teraz.
    var debugNow: Date? = nil
    var nowDate: Date { debugNow ?? Date() }

    // Pogoda — temperatura otoczenia z OpenMeteo (nil = brak danych)
    var temperatureC: Double? = nil

    // Pasek informacyjny: pogoda na trasie, wiatr boczny, odcinek (kolejność = ważność)
    var infoChips: [DashChip] = []
    /// Dane z mostka CAN (obroty, bieg); nil = brak płytki, deska wygląda jak dotąd.
    var bike: BikeTelemetry? = nil
    // Ekran „Terminal CAN” (HackerScreen.swift)
    var hackerLines: [HackerLine] = []
    var hackerTable: [UInt16: [UInt8]] = [:]
    /// Źródło przechyłu do znaczka w nagłówku; nil = mostek wyłączony, znaczka nie ma.
    var leanSource: LeanSource? = nil
    /// Ruch zawieszenia −1…+1 z mostka CAN (słupki F/R przy modelu motocykla; + = ugięcie); nil = brak danych.
    var suspTravel: (front: Double, rear: Double)? = nil

    // Żywe tło: bardzo wolne, rozmyte plamy koloru (patrz `prepareAmbient`).
    var ambientEnabled: Bool = true
    var ambientImage: UIImage? = nil

    // Now Playing (prawy panel) — gdy npTitle pusty → fallback do statystyk
    var npTitle:     String   = ""
    var npArtist:    String   = ""
    var npArtwork:   UIImage? = nil
    var npElapsed:   Double   = 0
    var npDuration:  Double   = 0
    var npIsPlaying: Bool     = false

    // Disco: zsynchronizowane linijki tekstu (karaoke) — ustawiane z ContentView.
    var lyricsLines:  [LyricLine] = []
    var lyricsStatus: String      = ""

    // Wspomnienia: bieżący + poprzedni KADR (1-3 zdjęcia mozaiki), czas zmiany, podpis.
    var memCurrent:  [UIImage] = []
    var memPrevious: [UIImage] = []
    var memSwitchAt: TimeInterval = 0
    var memCaption:  String = ""
    var memStatus:   String = ""
    // Cache dominującego koloru okładki (przeliczany gdy okładka się zmieni).
    var discoAccent: UIColor = UIColor(red: 0.9, green: 0.2, blue: 0.6, alpha: 1)
    var discoBGTop:  UIColor = UIColor(white: 0.06, alpha: 1)
    var discoBGBot:  UIColor = UIColor(white: 0.02, alpha: 1)
    var discoColorArtwork: UIImage? = nil   // tożsamość okładki (===) dla cache
    var discoColorDark: Bool = true         // motyw dla którego policzono kolory (cache)

    // Aktywny ekran + stan gier/mapy
    var activeScreen:   Int             = 0
    var snakeSnapshot:  SnakeSnapshot?  = nil
    var sudokuSnapshot: SudokuSnapshot? = nil
    var mapImage:       UIImage?        = nil
    var perfSnapshot:   PerfSnapshot?   = nil

    // Turn-by-turn nawigacja (ustawiane gdy trasa aktywna)
    var navActive:            Bool   = false
    var navInstruction:       String = ""
    var navDistanceToNext:    Double = 0
    var navRemainingDistance: Double = 0
    var navRemainingTime:     Double = 0

    // Stan animacji ekranu Lean (renderer to klasa → przeżywa między klatkami)
    var leanEased:  Double  = 0    // wygładzony kąt (płynny ruch motocykla)
    var leanPulse:  CGFloat = 0    // "pop" dużej liczby przy nowym maksie
    var leanPulseL: CGFloat = 0    // pop etykiety MAX L
    var leanPulseR: CGFloat = 0    // pop etykiety MAX R
    var animPhase:  CGFloat = 0    // ciągła faza (oddychający glow)
    var lastMaxL:   Double  = 0
    var lastMaxR:   Double  = 0
    var leanTrail:  [Double] = []  // ring buffer ostatnich kątów (kometa-ślad)
    // Sylwetka GSX-S1000GX (asset z vektoryzacji zdjęcia) + cache tintu
    lazy var bikeSilhouette: UIImage? = UIImage(named: "gsxSilhouette")
    var bikeTintCache: UIImage? = nil
    var bikeTintDark:  Bool = true


    init(width: Int = 864, height: Int = 320) {
        self.width  = width
        self.height = height
    }

    // MARK: — Render

    /// JPEG Data — do wysyłania przez TCP na wyświetlacz motocykla
    /// Ile pikseli na punkt ma klatka wysyłana na motocykl. 1 = dokładnie tyle, ile
    /// ma wyświetlacz (864×320). Wcześniej szła skala ekranu telefonu (3), czyli
    /// 2592×960: dziewięć razy więcej pikseli do narysowania, zakodowania, przesłania
    /// przez WiFi motocykla i zdekodowania przez wyświetlacz — główne źródło opóźnienia.
    var streamScale: CGFloat = 1

    func render() -> Data? {
        // autoreleasepool — render + JPEG enkodowane co klatkę na wątku tła;
        // drenaż tymczasów CoreGraphics zapobiega narastaniu pamięci (Jetsam).
        autoreleasepool { renderImage(scale: streamScale).jpegData(compressionQuality: jpegQuality) }
    }

    /// UIImage — do podglądu w aplikacji (bez JPEG roundtrip). Bez podanej skali
    /// rysuje w skali ekranu telefonu (ostry podgląd i zrzuty kontrolne).
    func renderImage(scale: CGFloat? = nil) -> UIImage {
        let sz = CGSize(width: width, height: height)
        let fmt = UIGraphicsImageRendererFormat.default()
        if let scale { fmt.scale = scale }
        return UIGraphicsImageRenderer(size: sz, format: fmt)
            .image { [self] _ in paint(sz) }
    }

    // MARK: — Layout (wszystkie wymiary w jednym miejscu)

    struct Layout {
        let W, H: CGFloat
        let hH: CGFloat = 32   // header height
        let fH: CGFloat = 0    // brak paska lean — panele główne mają całą wysokość
        let lW: CGFloat = 210  // lean panel width
        let sW: CGFloat = 210  // stats panel width

        var mainY: CGFloat { hH }
        var mainH: CGFloat { H - hH - fH }
        var cX:    CGFloat { lW }           // center panel x start
        var cW:    CGFloat { W - lW - sW }  // center panel width (444px)
        var stX:   CGFloat { W - sW }       // stats panel x start
        var ftY:   CGFloat { H - fH }       // footer y
    }

    // MARK: — Palety kolorów

    // Ciemna (domyślna): czarne tło, czerwony akcent
    struct DarkPalette {
        static let RED      = UIColor(red: 1.00, green: 0.08, blue: 0.02, alpha: 1)
        static let RED_DIM  = UIColor(red: 0.55, green: 0.04, blue: 0.01, alpha: 1)
        static let RED_LINE = UIColor(red: 0.70, green: 0.05, blue: 0.01, alpha: 0.50)
        static let RED_GLOW = UIColor(red: 1.00, green: 0.08, blue: 0.02, alpha: 0.22)
        static let BLUE     = UIColor(red: 0.05, green: 0.52, blue: 1.00, alpha: 1)
        static let ORANGE   = UIColor(red: 1.00, green: 0.48, blue: 0.00, alpha: 1)
        static let GREEN    = UIColor(red: 0.20, green: 0.85, blue: 0.20, alpha: 1)
        static let BG       = UIColor(red: 0.04, green: 0.03, blue: 0.07, alpha: 1)
        static let BG_DARK  = UIColor(red: 0.03, green: 0.02, blue: 0.05, alpha: 1)
        static let BG_HDR   = UIColor(red: 0.07, green: 0.03, blue: 0.06, alpha: 1)
        static let BG_FTR   = UIColor(red: 0.05, green: 0.02, blue: 0.04, alpha: 1)
        static let FG       = UIColor.white
        // Szarości TEKSTU podbite pod czytelność na motocyklu (słońce + JPEG):
        // było 0.65 / 0.30 / 0.16 — najciemniejsze etykiety ginęły na tle.
        static let GRAY     = UIColor(white: 0.84, alpha: 1)
        static let DIM      = UIColor(white: 0.58, alpha: 1)
        static let DIMMER   = UIColor(white: 0.42, alpha: 1)
        // Tła torów i siatek (łuk przechyłu, pasek postępu, kratki gier) —
        // zostają ciemne, żeby nie konkurowały z treścią.
        static let TRACK    = UIColor(white: 0.30, alpha: 1)
    }

    // Jasna (DAY): neutralna jasno-szara baza (digital style). Cyfra prędkości
    // jest deep red (SPEED_DIGIT) zamiast czarna — to jedyna istotna zmiana
    // koloru tekstu. Reszta paneli czarno/szara dla maksymalnej czytelności.
    struct LightPalette {
        static let RED      = UIColor(red: 0.78, green: 0.08, blue: 0.02, alpha: 1)   // deep red (akcent + cyfra prędkości)
        static let RED_DIM  = UIColor(red: 0.55, green: 0.06, blue: 0.02, alpha: 1)
        static let RED_LINE = UIColor(red: 0.65, green: 0.10, blue: 0.05, alpha: 0.40)
        static let RED_GLOW = UIColor(red: 1.00, green: 0.20, blue: 0.05, alpha: 0.18) // subtelny glow
        static let BLUE     = UIColor(red: 0.05, green: 0.35, blue: 0.85, alpha: 1)
        static let ORANGE   = UIColor(red: 0.90, green: 0.45, blue: 0.00, alpha: 1)
        static let GREEN    = UIColor(red: 0.05, green: 0.55, blue: 0.10, alpha: 1)
        // Neutralne jasno-szare tła (NIE krema — digital, nie analog)
        static let BG       = UIColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)   // off-white panele boczne
        static let BG_DARK  = UIColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1)   // delikatnie ciemniejsze (środek)
        static let BG_HDR   = UIColor(red: 0.88, green: 0.88, blue: 0.89, alpha: 1)   // szary header
        static let BG_FTR   = UIColor(red: 0.88, green: 0.88, blue: 0.89, alpha: 1)
        static let FG       = UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)   // prawie-czarny tekst (lean values etc.)
        static let GRAY     = UIColor(white: 0.16, alpha: 1)   // było 0.30 / 0.48 / 0.62
        static let DIM      = UIColor(white: 0.32, alpha: 1)
        static let DIMMER   = UIColor(white: 0.45, alpha: 1)
        static let TRACK    = UIColor(white: 0.48, alpha: 1)
    }

    // Aliasy — przełączają się dynamicznie na podstawie isDarkMode
    var RED:      UIColor { isDarkMode ? DarkPalette.RED      : LightPalette.RED      }
    var RED_DIM:  UIColor { isDarkMode ? DarkPalette.RED_DIM  : LightPalette.RED_DIM  }
    var RED_LINE: UIColor { isDarkMode ? DarkPalette.RED_LINE : LightPalette.RED_LINE }
    var RED_GLOW: UIColor { isDarkMode ? DarkPalette.RED_GLOW : LightPalette.RED_GLOW }
    var BLUE:     UIColor { isDarkMode ? DarkPalette.BLUE     : LightPalette.BLUE     }
    var ORANGE:   UIColor { isDarkMode ? DarkPalette.ORANGE   : LightPalette.ORANGE   }
    var GREEN:    UIColor { isDarkMode ? DarkPalette.GREEN    : LightPalette.GREEN    }
    var BG:       UIColor { isDarkMode ? DarkPalette.BG       : LightPalette.BG       }
    var BG_DARK:  UIColor { isDarkMode ? DarkPalette.BG_DARK  : LightPalette.BG_DARK  }
    var BG_HDR:   UIColor { isDarkMode ? DarkPalette.BG_HDR   : LightPalette.BG_HDR   }
    var BG_FTR:   UIColor { isDarkMode ? DarkPalette.BG_FTR   : LightPalette.BG_FTR   }
    var WHITE:    UIColor { isDarkMode ? DarkPalette.FG       : LightPalette.FG       }
    var GRAY:     UIColor { isDarkMode ? DarkPalette.GRAY     : LightPalette.GRAY     }
    var DIM:      UIColor { isDarkMode ? DarkPalette.DIM      : LightPalette.DIM      }
    var DIMMER:   UIColor { isDarkMode ? DarkPalette.DIMMER   : LightPalette.DIMMER   }
    var TRACK:    UIColor { isDarkMode ? DarkPalette.TRACK    : LightPalette.TRACK    }

    // Kolor głównej cyfry prędkości — biel w dark, deep crimson w light.
    // Daje "analogowy zegar" vibe zamiast płaskiego czarnego tekstu.
    var SPEED_DIGIT: UIColor { isDarkMode ? .white : RED }

    // MARK: — Żywe tło

    /// Trzy duże, rozmyte plamy koloru sunące po krzywych Lissajous z okresami
    /// 2–3,5 minuty. Tempo jest dobrane pod ograniczenie przesyłu: przy ~15 kl/s
    /// plama przesuwa się o ułamek piksela na klatkę, więc ruchu nie widać jako
    /// skoków — tło po prostu „jest inne" po kilkunastu sekundach.
    ///
    /// Rysowane w 1/4 rozdzielczości i rozciągane: plamy nie mają żadnych
    /// szczegółów, więc nic się nie traci, a koszt na klatkę jest pomijalny.
    func prepareAmbient(_ size: CGSize) {
        let t = nowDate.timeIntervalSinceReferenceDate
        let small = CGSize(width: size.width / 4, height: size.height / 4)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1; fmt.opaque = false
        // (kolor, krycie w środku, promień jako ułamek szerokości, okres X, okres Y, faza)
        let k: CGFloat = isDarkMode ? 1.0 : 0.55      // na jasnym tle delikatniej
        let blobs: [(UIColor, CGFloat, CGFloat, Double, Double, Double)] = [
            (UIColor(red: 1.00, green: 0.10, blue: 0.05, alpha: 1), 0.17 * k, 0.55, 173, 131, 0.0),
            (UIColor(red: 0.35, green: 0.15, blue: 0.95, alpha: 1), 0.15 * k, 0.60, 211, 157, 1.3),
            (UIColor(red: 0.95, green: 0.25, blue: 0.55, alpha: 1), 0.10 * k, 0.45, 149, 193, 2.6),
        ]
        ambientImage = UIGraphicsImageRenderer(size: small, format: fmt).image { ctx in
            let cg = ctx.cgContext
            let cs = CGColorSpaceCreateDeviceRGB()
            for (color, alpha, rFrac, px, py, phase) in blobs {
                let cx = small.width  * CGFloat(0.5 + 0.42 * sin(2 * .pi * t / px + phase))
                let cy = small.height * CGFloat(0.5 + 0.40 * cos(2 * .pi * t / py + phase * 0.7))
                // Oddech jasności — też wolny, żeby tło nie stało, gdy plamy są daleko.
                let breath = CGFloat(0.85 + 0.15 * sin(2 * .pi * t / 47 + phase))
                let colors = [color.withAlphaComponent(alpha * breath).cgColor,
                              color.withAlphaComponent(0).cgColor] as CFArray
                guard let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) else { continue }
                let c = CGPoint(x: cx, y: cy)
                cg.drawRadialGradient(g, startCenter: c, startRadius: 0,
                                      endCenter: c, endRadius: small.width * rFrac, options: [])
            }
        }
    }

    /// Nakłada żywe tło w obrębie `rect`. Obraz jest zawsze rozciągnięty na CAŁY
    /// ekran, a tylko przycinany — dzięki temu plamy przechodzą płynnie przez
    /// granice paneli, zamiast zaczynać się w każdym od nowa.
    func drawAmbient(in rect: CGRect, canvas: CGSize? = nil) {
        guard let img = ambientImage, let ctx = UIGraphicsGetCurrentContext() else { return }
        let full = CGSize(width: CGFloat(width), height: CGFloat(height))
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.interpolationQuality = .low     // plamy są rozmyte — dwuliniowe w zupełności wystarcza
        img.draw(in: CGRect(origin: .zero, size: canvas ?? full))
        ctx.restoreGState()
    }

    // MARK: — Główna funkcja rysowania

    func paint(_ size: CGSize) {
        let l = Layout(W: size.width, H: size.height)
        BG.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))

        let screen = DashboardScreen(rawValue: activeScreen) ?? .classic
        // Żywe tło pod ekranami o płaskim tle. Disco ma własny motyw z okładki,
        // wspomnienia i wideo to obraz na cały ekran — tam by tylko przeszkadzało.
        ambientImage = nil
        if ambientEnabled, ![.disco, .memories, .video, .hacker].contains(screen) {
            prepareAmbient(size)
            // Ekrany z klocków i tak zamalowują każdy panel własnym kolorem i same
            // nakładają tło — rysowanie go tu byłoby pracą wyrzuconą pod spód.
            if slots(for: screen, l) == nil {
                drawAmbient(in: CGRect(origin: .zero, size: size), canvas: size)
            }
        }
        switch screen {
        case .classic, .navClassic:
            // Ekrany złożone z klocków — patrz DashBlocks.swift
            paintSlots(slots(for: screen, l) ?? [])
        case .lean:    paintLeanScreen(l)
        case .snake:   paintSnakeScreen(l)
        case .sudoku:  paintSudokuScreen(l)
        case .navigation: paintNavScreen(l)
        case .performance: paintPerfScreen(l)
        case .disco: paintDisco(l)
        case .memories: paintMemories(l)
        case .hacker: paintHackerScreen(l)
        case .video:
            // Klatki wideo idą wprost z VideoFrameProvider (bypass renderera).
            // Ten placeholder pokazuje się tylko zanim pierwsza klatka będzie gotowa.
            BG_DARK.setFill(); UIRectFill(CGRect(origin: .zero, size: CGSize(width: l.W, height: l.H)))
            writeCtr(String(localized: "Isle of Man TT — ładowanie…"), x: l.W/2, y: l.H/2, size: 20, color: GRAY)
        }

        // Overlay kalibracji (ręczna) — odliczanie 5..1, pomiar 0, "Skalibrowano" -2
        if calibrationCountdown != -1 {
            drawCalibrationOverlay(l)
        }
    }

    // MARK: — Ekran DISCO (🪩 duża okładka + motyw z albumu + karaoke)

    func paintDisco(_ l: Layout) {
        let W = l.W, H = l.H
        let ctx = UIGraphicsGetCurrentContext()

        // Kolory z okładki (cache po tożsamości UIImage)
        refreshDiscoColors()

        // ── Tło: pionowy gradient z koloru albumu ──
        if let ctx, let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                          colors: [discoBGTop.cgColor, discoBGBot.cgColor] as CFArray,
                                          locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0),
                                   end: CGPoint(x: 0, y: H), options: [])
        } else {
            discoBGBot.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: W, height: H))
        }

        // ── Duża okładka: lewo-środek ──
        let pad: CGFloat = 18
        let artSize = min(H - 2 * 14, 292)
        let artX = pad
        let artY = (H - artSize) / 2
        let artRect = CGRect(x: artX, y: artY, width: artSize, height: artSize)
        let artPath = UIBezierPath(roundedRect: artRect, cornerRadius: 16)

        // Poświata w kolorze albumu pod okładką
        if let ctx {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 26, color: discoAccent.withAlphaComponent(0.75).cgColor)
            discoAccent.setFill(); artPath.fill()
            ctx.restoreGState()
        }
        if let img = npArtwork, let ctx {
            ctx.saveGState(); artPath.addClip()
            // aspect-fill
            let s = max(artSize / img.size.width, artSize / img.size.height)
            let dw = img.size.width * s, dh = img.size.height * s
            img.draw(in: CGRect(x: artRect.midX - dw/2, y: artRect.midY - dh/2, width: dw, height: dh))
            ctx.restoreGState()
        } else {
            writeCtr("♪", x: artRect.midX, y: artRect.midY, size: 90, color: discoFG(0.85))
        }
        discoFG(0.25).setStroke(); artPath.lineWidth = 1.5; artPath.stroke()

        // Play/pauza + mały pasek postępu pod okładką
        let barY = artY + artSize + 6
        if barY < H - 4 {
            let pw = artSize
            discoFG(0.18).setFill()
            UIBezierPath(roundedRect: CGRect(x: artX, y: barY, width: pw, height: 4), cornerRadius: 2).fill()
            if npDuration > 0 {
                let prog = CGFloat(min(max(npElapsed / npDuration, 0), 1))
                discoAccent.setFill()
                UIBezierPath(roundedRect: CGRect(x: artX, y: barY, width: pw * prog, height: 4), cornerRadius: 2).fill()
            }
        }

        // ── Prawa połowa: tytuł + artysta + karaoke ──
        let lyrX = artX + artSize + 24
        let lyrW = W - pad - lyrX
        drawDiscoText(x: lyrX, w: lyrW, H: H)
    }

    /// Prawa kolumna: tytuł/artysta u góry + zsynchronizowane linijki wyśrodkowane na aktualnej.
    func drawDiscoText(x: CGFloat, w: CGFloat, H: CGFloat) {
        // Nagłówek — kolor zależny od motywu (light/dark).
        writeClipped(npTitle.isEmpty ? "Nic nie gra" : npTitle,
                     x: x, y: 26, width: w, size: 18, color: discoFG(0.95), bold: true)
        writeClipped(npArtist, x: x, y: 48, width: w, size: 13, color: discoFG(0.7))

        // Linia oddzielająca w kolorze albumu
        discoAccent.withAlphaComponent(0.6).setFill()
        UIRectFill(CGRect(x: x, y: 62, width: w, height: 2))

        guard !lyricsLines.isEmpty else {
            let msg = lyricsStatus.isEmpty ? "🪩" : lyricsStatus
            writeCtr(msg, x: x + w/2, y: H/2 + 20, size: lyricsStatus.isEmpty ? 60 : 16, color: discoFG(0.5))
            return
        }

        // Karaoke z ZAWIJANIEM: bieżąca linijka duża (kolor akcentu), sąsiednie mniejsze
        // i przygaszone. Każda może zająć kilka wierszy (długi tekst nie jest ucinany).
        // Lead ~0.35s wyprzedza podświetlenie — kompensuje odczuwalne opóźnienie synchro.
        let lead = 0.35
        let cur = currentLyricIndex(at: npElapsed + lead)
        let cx  = x + w / 2
        let top: CGFloat = 74, bottom = H - 6
        let centerY = top + (bottom - top) / 2
        let window = 3
        let gap: CGFloat = 7

        func text(_ i: Int) -> String { lyricsLines[i].text.isEmpty ? "♪" : lyricsLines[i].text }
        func size(_ d: Int) -> CGFloat { d == 0 ? 21 : 15 }
        func col(_ d: Int)  -> UIColor { d == 0 ? discoAccentBright()
            : discoFG(CGFloat(max(0.22, 0.7 - Double(abs(d)) * 0.18))) }
        func maxLn(_ d: Int) -> Int { d == 0 ? 3 : 2 }

        // Bieżąca — wyśrodkowana pionowo na centerY
        let curH = drawWrappedCtr(text(cur), cx: cx, centerY: centerY, width: w,
                                  size: size(0), color: col(0), bold: true, maxLines: maxLn(0))
        // W dół
        var yTop = centerY + curH / 2 + gap
        for d in 1...window {
            let idx = cur + d
            guard idx < lyricsLines.count, yTop < bottom else { break }
            let h = drawWrappedTop(text(idx), cx: cx, topY: yTop, width: w,
                                   size: size(d), color: col(d), bold: false, maxLines: maxLn(d))
            yTop += h + gap
        }
        // W górę
        var yBottom = centerY - curH / 2 - gap
        for d in 1...window {
            let idx = cur - d
            guard idx >= 0, yBottom > top else { break }
            let h = measureWrapped(text(idx), width: w, size: size(d), bold: false, maxLines: maxLn(d))
            drawWrappedTop(text(idx), cx: cx, topY: yBottom - h, width: w,
                           size: size(d), color: col(d), bold: false, maxLines: maxLn(d))
            yBottom -= h + gap
        }
    }

    func wrapAttrs(size: CGFloat, bold: Bool, color: UIColor) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.alignment = .center
        return [.font: mono(size, bold: bold), .foregroundColor: color, .paragraphStyle: para]
    }

    /// Wysokość zawiniętego tekstu (ograniczona do maxLines) — do układania pionowego.
    func measureWrapped(_ text: String, width: CGFloat, size: CGFloat, bold: Bool, maxLines: Int) -> CGFloat {
        let a = wrapAttrs(size: size, bold: bold, color: .white)
        let maxH = CGFloat(maxLines) * ceil(mono(size, bold: bold).lineHeight) + 2
        let r = (text as NSString).boundingRect(with: CGSize(width: width, height: maxH),
                    options: [.usesLineFragmentOrigin], attributes: a, context: nil)
        return min(ceil(r.height), maxH)
    }

    /// Rysuje zawinięty tekst wyśrodkowany w poziomie, górna krawędź w topY. Zwraca wysokość.
    @discardableResult
    func drawWrappedTop(_ text: String, cx: CGFloat, topY: CGFloat, width: CGFloat,
                                size: CGFloat, color: UIColor, bold: Bool, maxLines: Int) -> CGFloat {
        let a = wrapAttrs(size: size, bold: bold, color: color)
        let h = measureWrapped(text, width: width, size: size, bold: bold, maxLines: maxLines)
        (text as NSString).draw(with: CGRect(x: cx - width/2, y: topY, width: width, height: h),
                                options: [.usesLineFragmentOrigin], attributes: a, context: nil)
        return h
    }

    /// Rysuje zawinięty tekst wyśrodkowany też pionowo na centerY. Zwraca wysokość.
    @discardableResult
    func drawWrappedCtr(_ text: String, cx: CGFloat, centerY: CGFloat, width: CGFloat,
                                size: CGFloat, color: UIColor, bold: Bool, maxLines: Int) -> CGFloat {
        let h = measureWrapped(text, width: width, size: size, bold: bold, maxLines: maxLines)
        drawWrappedTop(text, cx: cx, topY: centerY - h/2, width: width,
                       size: size, color: color, bold: bold, maxLines: maxLines)
        return h
    }

    func currentLyricIndex(at elapsed: Double) -> Int {
        var idx = 0
        for (i, line) in lyricsLines.enumerated() {
            if line.time <= elapsed { idx = i } else { break }
        }
        return idx
    }

    // MARK: — Dominujący kolor okładki

    func refreshDiscoColors() {
        // Przelicz gdy zmieni się okładka LUB motyw (light/dark).
        guard npArtwork !== discoColorArtwork || discoColorDark != isDarkMode else { return }
        discoColorArtwork = npArtwork
        discoColorDark = isDarkMode
        var h: CGFloat = 0.9, s: CGFloat = 0.6, b: CGFloat = 0.5
        if let img = npArtwork, let avg = Self.averageColor(img) {
            var a: CGFloat = 0
            UIColor(cgColor: avg).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        }
        if isDarkMode {
            // Akcent: nasycony, jasny wariant barwy albumu; tło mocno przyciemnione.
            discoAccent = UIColor(hue: h, saturation: min(1, max(0.55, s) * 1.2), brightness: min(1, max(0.7, b) + 0.15), alpha: 1)
            discoBGTop  = UIColor(hue: h, saturation: min(0.8, s), brightness: 0.16, alpha: 1)
            discoBGBot  = UIColor(hue: h, saturation: min(0.9, s), brightness: 0.04, alpha: 1)
        } else {
            // Light mode: akcent ciemniejszy (kontrast na jasnym), tło = delikatny odcień barwy.
            discoAccent = UIColor(hue: h, saturation: min(1, max(0.6, s)), brightness: min(0.75, max(0.45, b)), alpha: 1)
            discoBGTop  = UIColor(hue: h, saturation: min(0.22, s * 0.4), brightness: 0.98, alpha: 1)
            discoBGBot  = UIColor(hue: h, saturation: min(0.40, s * 0.6), brightness: 0.85, alpha: 1)
        }
    }

    func discoAccentBright() -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        discoAccent.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // W dark: rozjaśniamy akcent na podświetlenie; w light zostawiamy (już ciemny, czytelny).
        return isDarkMode ? UIColor(hue: h, saturation: min(1, s), brightness: 1.0, alpha: 1) : discoAccent
    }

    /// Kolor tekstu disco zależny od motywu: jasny na ciemnym tle (dark), ciemny na jasnym (light).
    func discoFG(_ alpha: CGFloat) -> UIColor {
        isDarkMode ? UIColor(white: 1, alpha: alpha) : UIColor(white: 0.08, alpha: alpha)
    }

    /// Średni kolor obrazu — rysuje do 1×1 kontekstu i czyta piksel. Tanie i wystarczające.
    static func averageColor(_ image: UIImage) -> CGColor? {
        guard let cg = image.cgImage else { return nil }
        var px: [UInt8] = [0, 0, 0, 0]
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                       blue: CGFloat(px[2]) / 255, alpha: 1).cgColor
    }

    // MARK: — Ekran WSPOMNIENIA (📸 slideshow zdjęć z przenikaniem)

    func paintMemories(_ l: Layout) {
        let W = l.W, H = l.H
        UIColor.black.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: W, height: H))

        guard !memCurrent.isEmpty else {
            let msg = memStatus.isEmpty ? "📸" : memStatus
            writeCtr(msg, x: W/2, y: H/2, size: memStatus.isEmpty ? 60 : 16, color: GRAY)
            return
        }

        // Fade 0→1 w ciągu 0.9s od zmiany kadru (płynne przenikanie).
        let dt = Date().timeIntervalSince1970 - memSwitchAt
        let fade = CGFloat(max(0, min(1, dt / 0.9)))

        // Obszar na zdjęcia (reszta u dołu na podpis) — musi zgadzać się z MemoriesManager.
        let areaH: CGFloat = 286
        let areaRect = CGRect(x: 0, y: 4, width: W, height: areaH)

        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: H))
        if !memPrevious.isEmpty && fade < 1 { drawMosaic(memPrevious, in: areaRect, alpha: 1) }
        drawMosaic(memCurrent, in: areaRect, alpha: fade)
        ctx.restoreGState()

        // Podpis na pasku u dołu (czytelny, bez zasłaniania zdjęć — te kończą się nad nim).
        if !memCaption.isEmpty {
            UIColor.black.withAlphaComponent(0.55).setFill()
            UIRectFill(CGRect(x: 0, y: H - 30, width: W, height: 30))
            writeCtr(memCaption, x: W/2, y: H - 15, size: 15, color: UIColor(white: 1, alpha: 0.92), bold: true)
        }
    }

    /// Mozaika 1-3 zdjęć obok siebie, każde w CAŁOŚCI (aspect-fit), wyśrodkowana w poziomie.
    /// Ekran 864×320 jest bardzo szeroki — pojedyncze zdjęcie pionowe byłoby maleńkie,
    /// więc kilka obok siebie wykorzystuje szerokość i nic nie jest przycięte.
    func drawMosaic(_ images: [UIImage], in area: CGRect, alpha: CGFloat) {
        guard !images.isEmpty else { return }
        let gap: CGFloat = 6
        // Szerokości po wpasowaniu w wysokość obszaru.
        var widths = images.map { img -> CGFloat in
            guard img.size.height > 0 else { return area.height }
            return area.height * (img.size.width / img.size.height)
        }
        var total = widths.reduce(0, +) + gap * CGFloat(images.count - 1)
        // Gdyby mimo pakowania nie mieściło się (np. bardzo panoramiczne) — przeskaluj w dół.
        var h = area.height
        if total > area.width {
            let k = area.width / total
            widths = widths.map { $0 * k }
            h *= k
            total = area.width
        }
        var x = area.midX - total / 2
        let y = area.midY - h / 2
        for (i, img) in images.enumerated() {
            img.draw(in: CGRect(x: x, y: y, width: widths[i], height: h),
                     blendMode: .normal, alpha: alpha)
            x += widths[i] + gap
        }
    }

    // MARK: — Ekran LEAN (motocykl się przechyla)

    // Strefy przechyłu — kolor wg agresywności kąta (wspólne dla obu motywów)
    func leanZoneColor(_ absDeg: Double) -> UIColor {
        switch absDeg {
        case ..<25: return UIColor(red: 0.18, green: 0.85, blue: 0.48, alpha: 1)   // zielony
        case ..<40: return UIColor(red: 0.97, green: 0.80, blue: 0.15, alpha: 1)   // żółty
        case ..<52: return UIColor(red: 1.00, green: 0.50, blue: 0.05, alpha: 1)   // pomarańcz
        default:    return UIColor(red: 1.00, green: 0.20, blue: 0.12, alpha: 1)   // czerwony
        }
    }

    func paintLeanScreen(_ l: Layout) {
        let W = l.W, H = l.H
        let cx = W / 2
        let pivotY: CGFloat = H - 14
        let R:      CGFloat = 214          // promień łuku HUD
        let maxDeg: Double  = 65

        // ── Animacja ──
        let target = max(-maxDeg, min(maxDeg, leanAngleDeg))
        // Czujnik motocykla jest czysty i szybki — łagodzimy go tylko odrobinę, żeby ruch był
        // płynny między klatkami. Telefon zostaje przy mocniejszym wygładzaniu.
        leanEased += (target - leanEased) * (leanSource == .bike ? 0.6 : 0.28)
        animPhase += 0.12
        if maxLeanLeft  > lastMaxL + 0.3 { leanPulseL = 1; leanPulse = 1 }
        if maxLeanRight > lastMaxR + 0.3 { leanPulseR = 1; leanPulse = 1 }
        lastMaxL = maxLeanLeft; lastMaxR = maxLeanRight
        leanPulse *= 0.88; leanPulseL *= 0.90; leanPulseR *= 0.90
        leanTrail.append(leanEased)
        if leanTrail.count > 16 { leanTrail.removeFirst(leanTrail.count - 16) }

        let lean   = leanEased
        let aLean  = abs(lean)
        let zone   = leanZoneColor(aLean)
        let dirCol = lean < -1.5 ? BLUE : (lean > 1.5 ? RED : GRAY)
        let breath = 0.5 + 0.5 * sin(animPhase)
        let ctx    = UIGraphicsGetCurrentContext()

        func arcPoint(_ deg: Double, _ r: CGFloat) -> CGPoint {
            let a = CGFloat(deg) * .pi / 180
            return CGPoint(x: cx + r * sin(a), y: pivotY - r * cos(a))
        }
        func arcStroke(_ from: Double, _ to: Double, _ color: UIColor, _ width: CGFloat, _ r: CGFloat) {
            let path = UIBezierPath()
            var first = true; var d = from
            while d <= to + 0.001 {
                let p = arcPoint(d, r)
                if first { path.move(to: p); first = false } else { path.addLine(to: p) }
                d += 1.5
            }
            color.setStroke(); path.lineWidth = width
            path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
        }

        // ── Vignette (ciemniejsze rogi) ──
        if let ctx, isDarkMode {
            let cols = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.55).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols, locations: [0.55, 1]) {
                ctx.saveGState()
                ctx.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: H/2), startRadius: 0,
                                       endCenter: CGPoint(x: cx, y: H/2), endRadius: W*0.62, options: [])
                ctx.restoreGState()
            }
        }

        // ── Radialna poświata od pivota, tinted strefą ──
        if let ctx {
            let gc = arcPoint(lean, R * 0.62)
            let a = 0.10 + 0.16 * CGFloat(min(aLean/55.0, 1)) + 0.04 * breath
            let cols = [zone.withAlphaComponent(a).cgColor, zone.withAlphaComponent(0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols, locations: [0, 1]) {
                ctx.saveGState()
                ctx.drawRadialGradient(g, startCenter: gc, startRadius: 0, endCenter: gc, endRadius: 300, options: [])
                ctx.restoreGState()
            }
        }

        // ── Subtelny pochylający się horyzont ──
        if let ctx {
            ctx.saveGState()
            ctx.translateBy(x: cx, y: H * 0.40)
            ctx.rotate(by: CGFloat(lean * 0.45 * .pi / 180))   // damped
            let hp = UIBezierPath()
            hp.move(to: CGPoint(x: -W, y: 0)); hp.addLine(to: CGPoint(x: W, y: 0))
            dirCol.withAlphaComponent(0.22).setStroke(); hp.lineWidth = 1.5; hp.stroke()
            ctx.restoreGState()
        }

        // ── Łuk HUD: tło + kolorowe strefy ──
        arcStroke(-maxDeg, maxDeg, TRACK.withAlphaComponent(isDarkMode ? 0.5 : 0.35), 12, R)
        for (lo, hi) in [(0.0, 25.0), (25.0, 40.0), (40.0, 52.0), (52.0, maxDeg)] {
            let c = leanZoneColor((lo + hi) / 2).withAlphaComponent(0.9)
            arcStroke(lo, hi, c, 9, R)            // prawa
            arcStroke(-hi, -lo, c, 9, R)          // lewa (lustro)
        }

        // ── Ticki + etykiety co 15°, główne 0/30/45/60 ──
        for deg in stride(from: -60, through: 60, by: 15) {
            let major = abs(deg) % 30 == 0 || abs(deg) == 45
            let p1 = arcPoint(Double(deg), R + 7)
            let p2 = arcPoint(Double(deg), R + (major ? 17 : 12))
            let t = UIBezierPath(); t.move(to: p1); t.addLine(to: p2)
            (deg == 0 ? WHITE : GRAY).withAlphaComponent(0.8).setStroke()
            t.lineWidth = major ? 2 : 1; t.stroke()
            if major && deg != 0 {        // 0° pomijamy (koliduje z dużą liczbą)
                let lp = arcPoint(Double(deg), R + 28)
                writeCtr("\(abs(deg))", x: lp.x, y: lp.y, size: 11, color: DIM, bold: false)
            }
        }

        // ── Znaczniki rekordów (max L / max R) — błysk przy nowym ──
        func peakMarker(_ deg: Double, _ col: UIColor, _ pulse: CGFloat) {
            guard abs(deg) > 1 else { return }
            let p = arcPoint(deg, R)
            let sz: CGFloat = 5 + pulse * 5
            col.withAlphaComponent(0.4 + 0.5 * pulse).setFill()
            UIBezierPath(ovalIn: CGRect(x: p.x - sz, y: p.y - sz, width: sz*2, height: sz*2)).fill()
            col.setStroke()
            let tick = UIBezierPath()
            tick.move(to: arcPoint(deg, R - 8)); tick.addLine(to: arcPoint(deg, R + 8))
            tick.lineWidth = 2.5; tick.stroke()
        }
        peakMarker(-maxLeanLeft,  BLUE, leanPulseL)
        peakMarker( maxLeanRight, RED,  leanPulseR)

        // ── Kometa-ślad ──
        for (i, d) in leanTrail.enumerated() {
            let frac = CGFloat(i) / CGFloat(max(1, leanTrail.count - 1))
            let p = arcPoint(d, R)
            let sz = 1.5 + frac * 4
            zone.withAlphaComponent(0.06 + 0.32 * frac).setFill()
            UIBezierPath(ovalIn: CGRect(x: p.x - sz, y: p.y - sz, width: sz*2, height: sz*2)).fill()
        }

        // ── Igła pivot → wskaźnik (cienka, glow) ──
        if let ctx {
            let tip = arcPoint(lean, R - 4)
            ctx.saveGState()
            let needle = UIBezierPath()
            needle.move(to: CGPoint(x: cx, y: pivotY)); needle.addLine(to: tip)
            zone.withAlphaComponent(0.35).setStroke(); needle.lineWidth = 7; needle.stroke()
            zone.setStroke(); needle.lineWidth = 2.5; needle.stroke()
            ctx.restoreGState()
        }

        // ── Wskaźnik bieżącego kąta — świecąca kropka z pierścieniem ──
        let tip = arcPoint(lean, R)
        let ringR: CGFloat = 11 + breath * 3
        zone.withAlphaComponent(0.5).setStroke()
        let ring = UIBezierPath(ovalIn: CGRect(x: tip.x - ringR, y: tip.y - ringR, width: ringR*2, height: ringR*2))
        ring.lineWidth = 2; ring.stroke()
        zone.setFill()
        UIBezierPath(ovalIn: CGRect(x: tip.x - 6, y: tip.y - 6, width: 12, height: 12)).fill()
        WHITE.setFill()
        UIBezierPath(ovalIn: CGRect(x: tip.x - 2.5, y: tip.y - 2.5, width: 5, height: 5)).fill()

        // ── Pochylający się motocykl GSX od pivota ──
        if let ctx {
            ctx.saveGState()
            ctx.translateBy(x: cx, y: pivotY)
            ctx.rotate(by: CGFloat(lean * .pi / 180))
            drawBikeRear(zone: zone)
            ctx.restoreGState()
        }

        // ── Duża wartość kąta (góra-środek) — pop + glow strefą ──
        let absReal = abs(leanAngleDeg)
        let side = leanAngleDeg < -1.5 ? "L" : (leanAngleDeg > 1.5 ? "R" : "")
        let numSize = 58 + leanPulse * 20
        let glowA   = 0.5 + 0.4 * leanPulse + 0.12 * breath
        writeGlow(String(format: "%@%.0f°", side.isEmpty ? "" : side + " ", absReal),
                  x: cx, y: 44, size: numSize, color: WHITE, glow: zone.withAlphaComponent(glowA))

        // ── Rogi: prędkość + G ──
        write(String(format: "%d", Int(max(0, speedKmh))), x: 18, y: 26, size: 30, color: WHITE, bold: true)
        write("km/h", x: 20, y: 50, size: 12, color: GRAY)
        let gCol = gForce > 1.0 ? ORANGE : (gForce > 0.5 ? WHITE : DIM)
        writeR(String(format: "%.1fg", gForce), x: W - 18, y: 26, size: 24, color: gCol, bold: true)
        writeR("G-FORCE", x: W - 18, y: 48, size: 11, color: DIMMER, bold: true)

        // ── MAX L / R przy końcach łuku ──
        writeR(String(format: "L %.0f°", maxLeanLeft),  x: 96,     y: H - 16, size: 16 + leanPulseL * 8, color: BLUE, bold: true)
        write (String(format: "R %.0f°", maxLeanRight), x: W - 96, y: H - 16, size: 16 + leanPulseR * 8, color: RED,  bold: true)
        // Etykiety NAD wartościami. Stały obok na tej samej wysokości i nachodziły
        // na „L 42°" / „R 39°" — nie było tego widać, dopóki były prawie czarne.
        writeR("MAX", x: 96,     y: H - 36, size: 10, color: DIMMER, bold: true)
        write ("MAX", x: W - 96, y: H - 36, size: 10, color: DIMMER, bold: true)
    }

    /// Tintowana sylwetka (cache — przelicz tylko gdy zmieni się motyw).
    func tintedBike() -> UIImage? {
        if bikeTintCache == nil || bikeTintDark != isDarkMode {
            let col = isDarkMode ? UIColor(white: 0.14, alpha: 1) : UIColor(white: 0.20, alpha: 1)
            bikeTintCache = bikeSilhouette?.withTintColor(col, renderingMode: .alwaysOriginal)
            bikeTintDark  = isDarkMode
        }
        return bikeTintCache
    }

    /// Sylwetka Suzuki GSX-S1000GX od tyłu (asset z vektoryzacji zdjęcia).
    /// Origin = punkt styku opony z podłożem, oś -y do góry.
    /// Rysowana z glow-rimem w kolorze strefy przechyłu.
    func drawBikeRear(zone: UIColor, height targetH: CGFloat = 150) {
        guard let img = tintedBike() else { return }
        let aspect  = img.size.width / img.size.height
        let targetW = targetH * aspect
        let rect = CGRect(x: -targetW / 2, y: -targetH, width: targetW, height: targetH)

        // Cień kontaktu pod oponą
        UIColor.black.withAlphaComponent(0.30).setFill()
        UIBezierPath(ovalIn: CGRect(x: -targetW * 0.26, y: -7, width: targetW * 0.52, height: 13)).fill()

        // Sylwetka z poświatą (glow rim) w kolorze strefy
        if let ctx = UIGraphicsGetCurrentContext() {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 8, color: zone.withAlphaComponent(0.85).cgColor)
            img.draw(in: rect)
            ctx.restoreGState()
            img.draw(in: rect)   // drugie przejście — ostra sylwetka na wierzchu poświaty
        } else {
            img.draw(in: rect)
        }
    }

    // MARK: — Ekran SNAKE

    func paintSnakeScreen(_ l: Layout) {
        guard let g = snakeSnapshot else {
            writeCtr(String(localized: "Snake — ładowanie..."), x: l.W/2, y: l.H/2, size: 20, color: GRAY)
            return
        }
        let W = l.W, H = l.H
        let topBar: CGFloat = 30
        let margin: CGFloat = 10
        let cell = floor(min((W - 2*margin) / CGFloat(g.cols),
                             (H - topBar - margin) / CGFloat(g.rows)))
        let gridW = cell * CGFloat(g.cols)
        let gridH = cell * CGFloat(g.rows)
        let ox = (W - gridW) / 2
        let oy = topBar + (H - topBar - gridH) / 2

        // Pasek wyniku
        write("SNAKE", x: 14, y: topBar/2, size: 16, color: GREEN, bold: true)
        writeR(String(localized: "Wynik: \(g.score)"), x: W - 14, y: topBar/2, size: 16, color: WHITE, bold: true)

        // Plansza
        BG_DARK.setFill()
        UIRectFill(CGRect(x: ox, y: oy, width: gridW, height: gridH))
        TRACK.setStroke()
        let border = UIBezierPath(rect: CGRect(x: ox, y: oy, width: gridW, height: gridH))
        border.lineWidth = 2; border.stroke()

        func cellRect(_ c: Int, _ r: Int) -> CGRect {
            CGRect(x: ox + CGFloat(c)*cell + 1, y: oy + CGFloat(r)*cell + 1,
                   width: cell - 2, height: cell - 2)
        }

        // Jedzenie
        ORANGE.setFill()
        UIBezierPath(ovalIn: cellRect(g.food.0, g.food.1)).fill()

        // Wąż
        for (i, seg) in g.snake.enumerated() {
            let col = i == 0 ? GREEN : GREEN.withAlphaComponent(0.65)
            col.setFill()
            UIBezierPath(roundedRect: cellRect(seg.0, seg.1), cornerRadius: 3).fill()
        }

        // Komunikaty
        if g.gameOver {
            let bx = CGRect(x: W/2 - 170, y: H/2 - 38, width: 340, height: 76)
            BG.withAlphaComponent(0.85).setFill()
            UIBezierPath(roundedRect: bx, cornerRadius: 10).fill()
            RED.setStroke()
            let bp = UIBezierPath(roundedRect: bx, cornerRadius: 10); bp.lineWidth = 2; bp.stroke()
            writeCtr("GAME OVER", x: W/2, y: H/2 - 12, size: 26, color: RED, bold: true)
            writeCtr(String(localized: "Wynik \(g.score)  •  OK = zagraj ponownie"), x: W/2, y: H/2 + 18, size: 14, color: WHITE)
        } else if !g.started {
            writeCtr(String(localized: "Wciśnij kierunek joystickiem aby zacząć"), x: W/2, y: oy + gridH/2, size: 16, color: WHITE, bold: true)
        }
    }

    // MARK: — Ekran SUDOKU

    func paintSudokuScreen(_ l: Layout) {
        guard let s = sudokuSnapshot else {
            writeCtr(String(localized: "Sudoku — ładowanie..."), x: l.W/2, y: l.H/2, size: 20, color: GRAY)
            return
        }
        let W = l.W, H = l.H
        let topBar: CGFloat = 26
        let cell: CGFloat = 31
        let grid = cell * 9                       // 279
        let ox = (W - grid) / 2
        let oy = topBar + (H - topBar - grid) / 2

        // Pasek górny
        let srcName: String
        switch s.source {
        case "Dnia": srcName = String(localized: "Dnia")
        case "Online": srcName = "Online"
        default: srcName = String(localized: "Losowa")
        }
        write("SUDOKU", x: 14, y: topBar/2, size: 15, color: BLUE, bold: true)
        writeCtr("\(srcName) · \(s.difficulty)", x: W/2, y: topBar/2, size: 13, color: GRAY, bold: true)
        writeR("\(s.filled)/81", x: W - 14, y: topBar/2, size: 14, color: WHITE, bold: true)

        if s.generating {
            writeCtr(String(localized: "Generuję planszę..."), x: W/2, y: H/2, size: 22, color: GRAY, bold: true)
            return
        }

        // Dedykowane kolory Sudoku — wysoki kontrast w obu trybach,
        // linie wyraźnie różne od cyfr (fix: w dark GRAY ≈ białe cyfry → zlewanie).
        let boardBG   = isDarkMode ? UIColor(white: 0.16, alpha: 1) : UIColor.white
        let gridThin  = isDarkMode ? UIColor(white: 0.45, alpha: 1) : UIColor(white: 0.70, alpha: 1)
        let gridThick = isDarkMode ? UIColor(white: 0.80, alpha: 1) : UIColor(white: 0.30, alpha: 1)
        let givenCol  = isDarkMode ? UIColor.white                  : UIColor(white: 0.08, alpha: 1)
        let playerCol = isDarkMode ? UIColor(red: 0.45, green: 0.80, blue: 1.0, alpha: 1)
                                   : UIColor(red: 0.05, green: 0.35, blue: 0.85, alpha: 1)
        let hlNeutral = isDarkMode ? UIColor.white : UIColor.black

        // Tło planszy
        boardBG.setFill()
        UIRectFill(CGRect(x: ox, y: oy, width: grid, height: grid))

        let curR = s.cursor / 9, curC = s.cursor % 9
        let curVal = s.entries[s.cursor]

        // Podświetlenie wiersza/kolumny/boxa kursora + tych samych cyfr
        for idx in 0..<81 {
            let r = idx/9, c = idx%9
            let sameRCB = r == curR || c == curC || (r/3 == curR/3 && c/3 == curC/3)
            let sameVal = curVal != 0 && s.entries[idx] == curVal
            if sameRCB || sameVal {
                if sameVal { playerCol.withAlphaComponent(isDarkMode ? 0.28 : 0.16).setFill() }
                else       { hlNeutral.withAlphaComponent(isDarkMode ? 0.10 : 0.06).setFill() }
                UIRectFill(CGRect(x: ox + CGFloat(c)*cell, y: oy + CGFloat(r)*cell, width: cell, height: cell))
            }
        }

        // Ukończone wiersze/kolumny/boxy — pulsujące zielone tło (pomoc wizualna)
        if !s.completed.isEmpty {
            let pulse = 0.5 + 0.5 * sin(CACurrentMediaTime() * 3.2)   // 0..1
            let gAlpha = CGFloat(0.18 + 0.34 * pulse)
            GREEN.withAlphaComponent(gAlpha).setFill()
            for idx in s.completed {
                let r = idx/9, c = idx%9
                UIRectFill(CGRect(x: ox + CGFloat(c)*cell, y: oy + CGFloat(r)*cell, width: cell, height: cell))
            }
        }

        // Komórka kursora — podświetlenie (pomarańcz=edycja, żółty=nawigacja)
        let curCol: UIColor = s.editing ? ORANGE : .systemYellow
        curCol.withAlphaComponent(s.editing ? 0.50 : 0.32).setFill()
        UIRectFill(CGRect(x: ox + CGFloat(curC)*cell, y: oy + CGFloat(curR)*cell, width: cell, height: cell))

        // Cyfry
        for idx in 0..<81 {
            let v = s.entries[idx]
            guard v != 0 else { continue }
            let r = idx/9, c = idx%9
            let cx = ox + CGFloat(c)*cell + cell/2
            let cy = oy + CGFloat(r)*cell + cell/2
            let col: UIColor
            if s.conflicts.contains(idx)      { col = RED }
            else if s.givens[idx] != 0        { col = givenCol }   // podpowiedź
            else                              { col = playerCol }  // wpis gracza
            // W dark mode pogrubiamy też wpisy gracza — lepsza czytelność na ciemnym tle.
            let isBold = s.givens[idx] != 0 || isDarkMode
            writeCtr("\(v)", x: cx, y: cy, size: 21, color: col, bold: isBold)
        }

        // Linie siatki — kolory dedykowane, wyraźnie różne od cyfr
        for i in 0...9 {
            let thick = i % 3 == 0
            (thick ? gridThick : gridThin).setStroke()
            let lw: CGFloat = thick ? 2 : 0.75
            let vx = ox + CGFloat(i)*cell
            let v = UIBezierPath(); v.move(to: CGPoint(x: vx, y: oy)); v.addLine(to: CGPoint(x: vx, y: oy+grid))
            v.lineWidth = lw; v.stroke()
            let hy = oy + CGFloat(i)*cell
            let h = UIBezierPath(); h.move(to: CGPoint(x: ox, y: hy)); h.addLine(to: CGPoint(x: ox+grid, y: hy))
            h.lineWidth = lw; h.stroke()
        }

        // Panel "Teraz gra" po lewej (puste pole obok planszy)
        let leftW = ox - 16
        if leftW > 120 {
            drawNowPlayingBox(px: 8, py: oy, pw: leftW, ph: grid)
        }

        // Panel sterowania po prawej (kompaktowy)
        let hintX = ox + grid + 20
        if hintX < W - 20 {
            let hints = s.editing
                ? [String(localized: "EDYCJA"), String(localized: "Góra/Dół:"), String(localized: "  cyfra"), String(localized: "OK: zatwierdź"), String(localized: "Back: anuluj")]
                : [String(localized: "NAWIGACJA"), String(localized: "D-pad: kursor"), String(localized: "OK: edytuj"), String(localized: "Back: wyjście")]
            for (i, line) in hints.enumerated() {
                write(line, x: hintX, y: oy + 16 + CGFloat(i)*20,
                      size: i == 0 ? 13 : 11, color: i == 0 ? (s.editing ? ORANGE : GRAY) : DIM, bold: i == 0)
            }
        }

        // Watermark SpinMyCan @mikomaks_ — subtelny, prawy dolny róg
        let wmAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: GRAY.withAlphaComponent(0.5)
        ]
        let wm = "SpinMyCan @mikomaks_" as NSString
        let wmSz = wm.size(withAttributes: wmAttrs)
        wm.draw(at: CGPoint(x: W - wmSz.width - 12, y: H - wmSz.height - 7), withAttributes: wmAttrs)

        // Wygrana
        if s.solved {
            let bw: CGFloat = 280, bh: CGFloat = 64
            let bx = CGRect(x: W/2 - bw/2, y: H/2 - bh/2, width: bw, height: bh)
            BG.withAlphaComponent(0.9).setFill()
            UIBezierPath(roundedRect: bx, cornerRadius: 10).fill()
            GREEN.setStroke()
            let bp = UIBezierPath(roundedRect: bx, cornerRadius: 10); bp.lineWidth = 2; bp.stroke()
            writeCtr(String(localized: "ROZWIĄZANE! 🎉"), x: W/2, y: H/2, size: 24, color: GREEN, bold: true)
        }
    }

    // MARK: — Ekran NAWIGACJA (mapa CarPlay-style + telemetria + now playing)

    func paintNavScreen(_ l: Layout) {
        let W = l.W, H = l.H
        let leftW:  CGFloat = 175
        let rightW: CGFloat = 195
        let mapX = leftW
        let mapW = W - leftW - rightW          // 494

        // Tła paneli bocznych
        BG.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: leftW, height: H))
        UIRectFill(CGRect(x: W - rightW, y: 0, width: rightW, height: H))

        // ── Mapa (środek) ──
        let mapRect = CGRect(x: mapX, y: 0, width: mapW, height: H)
        if let img = mapImage, let ctx = UIGraphicsGetCurrentContext() {
            ctx.saveGState(); ctx.clip(to: mapRect); img.draw(in: mapRect); ctx.restoreGState()
            drawNavCursor(cx: mapX + mapW/2, cy: H/2)   // heading-up → strzałka zawsze w górę
        } else {
            BG_DARK.setFill(); UIRectFill(mapRect)
            writeCtr(String(localized: "Czekam na GPS / mapę…"), x: mapX + mapW/2, y: H/2, size: 16, color: GRAY)
        }

        // ── Banner turn-by-turn ──
        if navActive {
            // Górny pasek: dystans do manewru + instrukcja
            let bw = mapW - 12
            let bx = CGRect(x: mapX + 6, y: 6, width: bw, height: 56)
            BG.withAlphaComponent(0.9).setFill()
            UIBezierPath(roundedRect: bx, cornerRadius: 10).fill()
            BLUE.withAlphaComponent(0.6).setStroke()
            let bp = UIBezierPath(roundedRect: bx, cornerRadius: 10); bp.lineWidth = 1.5; bp.stroke()
            writeGlow(fmtDist(navDistanceToNext), x: mapX + 60, y: 34, size: 26, color: WHITE, glow: BLUE.withAlphaComponent(0.5))
            writeClipped(navInstruction, x: mapX + 116, y: 34, width: bw - 120, size: 15, color: WHITE, bold: true)

            // Dolny pasek: pozostały dystans + ETA
            let ey = H - 22
            BG.withAlphaComponent(0.85).setFill()
            UIBezierPath(roundedRect: CGRect(x: mapX + 6, y: ey - 16, width: bw, height: 30), cornerRadius: 8).fill()
            write(fmtDist(navRemainingDistance), x: mapX + 16, y: ey, size: 15, color: GREEN, bold: true)
            let mins = Int(navRemainingTime / 60)
            writeR("≈ \(mins) min", x: mapX + mapW - 16, y: ey, size: 15, color: WHITE, bold: true)
        }

        // Separatory paneli
        TRACK.setStroke()
        for x in [mapX, W - rightW] {
            let s = UIBezierPath(); s.move(to: CGPoint(x: x, y: 0)); s.addLine(to: CGPoint(x: x, y: H))
            s.lineWidth = 1; s.stroke()
        }

        // ── Lewy panel: prędkość + lean (cyfry, bez wskaźnika) ──
        let lcx = leftW / 2
        writeGlow("\(Int(max(0, speedKmh)))", x: lcx, y: 58, size: 64, color: SPEED_DIGIT,
                  glow: RED.withAlphaComponent(0.5))
        writeCtr("km/h", x: lcx, y: 102, size: 16, color: GRAY)

        RED_LINE.setStroke()
        let sep = UIBezierPath(); sep.move(to: CGPoint(x: 14, y: 122)); sep.addLine(to: CGPoint(x: leftW - 14, y: 122))
        sep.lineWidth = 0.5; sep.stroke()

        let lean = leanAngleDeg
        let side = lean < -1.5 ? "L" : (lean > 1.5 ? "R" : "•")
        let leanCol = lean < -1.5 ? BLUE : (lean > 1.5 ? RED : GRAY)
        writeCtr("LEAN", x: lcx, y: 140, size: 11, color: DIMMER, bold: true)
        writeCtr(String(format: "%@ %.0f°", side, abs(lean)), x: lcx, y: 166, size: 32, color: leanCol, bold: true)

        writeR(String(format: "L %.0f°", maxLeanLeft),  x: lcx - 6, y: 202, size: 15, color: BLUE, bold: true)
        write (String(format: "R %.0f°", maxLeanRight), x: lcx + 6, y: 202, size: 15, color: RED,  bold: true)

        writeCtr("G-FORCE", x: lcx, y: 234, size: 11, color: DIMMER, bold: true)
        let gCol = gForce > 1.0 ? ORANGE : (gForce > 0.5 ? WHITE : DIM)
        writeCtr(String(format: "%.1fg", gForce),        x: lcx, y: 256, size: 22, color: gCol, bold: true)
        writeCtr(String(format: "MAX %.1fg", maxGforce), x: lcx, y: 276, size: 9,  color: DIMMER)

        // ── Prawy panel: Now Playing (kompakt) ──
        drawNowPlayingBox(px: W - rightW + 6, py: 8, pw: rightW - 12, ph: H - 16)
    }

    // MARK: — Ekran POMIARY (miernik osiągów GPS)

    func paintPerfScreen(_ l: Layout) {
        guard let p = perfSnapshot else {
            writeCtr(String(localized: "Pomiary — ładowanie..."), x: l.W/2, y: l.H/2, size: 20, color: GRAY); return
        }
        let W = l.W, H = l.H

        // Pasek górny
        write(String(localized: "POMIARY"), x: 14, y: 16, size: 15, color: ORANGE, bold: true)
        let stateCol = p.running ? RED : (p.armed ? GREEN : GRAY)
        writeR(p.stateLabel, x: W - 14, y: 16, size: 14, color: stateCol, bold: true)
        // separator
        RED_LINE.setStroke()
        let sep = UIBezierPath(); sep.move(to: CGPoint(x: 12, y: 32)); sep.addLine(to: CGPoint(x: W-12, y: 32))
        sep.lineWidth = 0.5; sep.stroke()

        // ── Lewa kolumna: prędkość + czas/dystans przejazdu ──
        let lcx = W * 0.26
        writeGlow("\(Int(max(0, p.speed)))", x: lcx, y: 120, size: 92, color: SPEED_DIGIT,
                  glow: RED.withAlphaComponent(0.5))
        writeCtr("km/h", x: lcx, y: 178, size: 18, color: GRAY)

        if p.running {
            writeGlow(String(format: "%.2f s", p.elapsed), x: lcx, y: 232, size: 36, color: GREEN, glow: nil)
            writeCtr(String(format: "%.0f m", p.distance), x: lcx, y: 270, size: 16, color: DIM, bold: true)
        } else {
            writeCtr(String(format: "MAX %d km/h", Int(p.maxSpeed)), x: lcx, y: 234, size: 18, color: GRAY, bold: true)
            writeCtr(String(localized: "Zatrzymaj się i rusz aby zmierzyć"), x: lcx, y: 264, size: 11, color: DIMMER)
        }

        // ── Prawa siatka wyników (na żywo lub ostatni przejazd) ──
        func fT(_ t: Double?) -> String { t == nil ? "—" : String(format: "%.2fs", t!) }
        let r = p.lastRun
        let z60v   = p.running ? p.zeroTo60   : r?.zeroTo60
        let z100v  = p.running ? p.zeroTo100  : r?.zeroTo100
        let sixtyv = p.running ? ((p.zeroTo60 != nil && p.zeroTo100 != nil) ? p.zeroTo100! - p.zeroTo60! : nil)
                               : r?.sixtyTo100
        let qv     = p.running ? p.quarter    : r?.quarterMile
        let trapv  = p.running ? p.quarterTrap : r?.quarterTrap
        let d4v    = p.running ? p.zeroTo400m : r?.zeroTo400m

        let gx: CGFloat = W * 0.50
        let gw = (W - gx - 14) / 2
        let gh: CGFloat = 78
        let gy0: CGFloat = 42
        let gyGap: CGFloat = 10

        func cell(_ col: Int, _ row: Int, _ label: String, _ value: String, _ sub: String?, _ accent: UIColor) {
            let x = gx + CGFloat(col) * (gw + 12)
            let y = gy0 + CGFloat(row) * (gh + gyGap)
            BG_DARK.setFill()
            UIBezierPath(roundedRect: CGRect(x: x, y: y, width: gw, height: gh), cornerRadius: 8).fill()
            let cxc = x + gw/2
            writeCtr(label, x: cxc, y: y + 16, size: 11, color: DIMMER, bold: true)
            writeCtr(value, x: cxc, y: y + (sub == nil ? 46 : 42), size: 26, color: accent, bold: true)
            if let sub { writeCtr(sub, x: cxc, y: y + 64, size: 10, color: DIM) }
        }

        cell(0, 0, "0–60 km/h",  fT(z60v),  nil, GREEN)
        cell(1, 0, "0–100 km/h", fT(z100v), nil, GREEN)
        cell(0, 1, "60–100",     fT(sixtyv), nil, BLUE)
        cell(1, 1, "0–400 m",    fT(d4v),   nil, BLUE)
        cell(0, 2, String(localized: "¼ mili"),     fT(qv),    trapv == nil ? nil : String(format: "@ %d km/h", Int(trapv!)), ORANGE)
        cell(1, 2, "MAX",        "\(Int(p.maxSpeed))", "km/h", RED)
    }

    /// Strzałka pozycji (kursor nawigacji) — trójkąt do góry.
    func drawNavCursor(cx: CGFloat, cy: CGFloat) {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: cx, y: cy - 15))
        p.addLine(to: CGPoint(x: cx - 11, y: cy + 11))
        p.addLine(to: CGPoint(x: cx, y: cy + 4))
        p.addLine(to: CGPoint(x: cx + 11, y: cy + 11))
        p.close()
        // poświata
        BLUE.withAlphaComponent(0.35).setFill()
        UIBezierPath(ovalIn: CGRect(x: cx - 16, y: cy - 16, width: 32, height: 32)).fill()
        BLUE.setFill(); p.fill()
        UIColor.white.setStroke(); p.lineWidth = 1.5; p.stroke()
    }


    // MARK: — Header

    // MARK: — Lean Panel (lewy, 210px)

    // MARK: — Speed Panel (środek, 444px)

    // MARK: — Now Playing Panel (prawy, 210px)
    // Gdy npTitle pusty → fallback do statystyk

    /// Panel "Teraz gra" w dowolnym prostokącie (używany na ekranie Sudoku po lewej).
    func drawNowPlayingBox(px: CGFloat, py: CGFloat, pw: CGFloat, ph: CGFloat) {
        let cx = px + pw / 2

        // Okładka
        let artSize: CGFloat = min(pw - 30, 120)
        let artX = cx - artSize / 2
        let artY = py + 14
        let artRect = CGRect(x: artX, y: artY, width: artSize, height: artSize)
        let artPath = UIBezierPath(roundedRect: artRect, cornerRadius: 8)
        if let img = npArtwork, !npTitle.isEmpty {
            if let ctx = UIGraphicsGetCurrentContext() {
                ctx.saveGState(); artPath.addClip(); img.draw(in: artRect); ctx.restoreGState()
            }
        } else {
            TRACK.withAlphaComponent(0.25).setFill(); artPath.fill()
            writeCtr("♪", x: cx, y: artY + artSize/2, size: 40, color: DIM)
        }
        RED_LINE.setStroke(); artPath.lineWidth = 1.0; artPath.stroke()

        guard !npTitle.isEmpty else {
            writeCtr(String(localized: "Nic nie gra"), x: cx, y: artY + artSize + 24, size: 13, color: DIM)
            return
        }

        // Play/pause badge
        let badgeR: CGFloat = 10
        let badgeX = artX + artSize - badgeR - 3, badgeY = artY + artSize - badgeR - 3
        BG_DARK.withAlphaComponent(0.8).setFill()
        UIBezierPath(ovalIn: CGRect(x: badgeX-badgeR, y: badgeY-badgeR, width: badgeR*2, height: badgeR*2)).fill()
        writeCtr(npIsPlaying ? "▶" : "⏸", x: badgeX, y: badgeY, size: 9, color: npIsPlaying ? GREEN : DIM)

        // Tytuł + artysta
        let textX = px + 8, textW = pw - 16
        let titleY = artY + artSize + 20
        writeClipped(npTitle,  x: textX, y: titleY,      width: textW, size: 14, color: WHITE, bold: true)
        writeClipped(npArtist, x: textX, y: titleY + 19, width: textW, size: 12, color: GRAY)

        // Progress bar
        let barX = px + 8, barW = pw - 16, barY = titleY + 36, barH: CGFloat = 5
        TRACK.withAlphaComponent(0.45).setFill()
        UIBezierPath(roundedRect: CGRect(x: barX, y: barY, width: barW, height: barH), cornerRadius: 2.5).fill()
        if npDuration > 0 {
            let fillW = barW * CGFloat(min(max(npElapsed/npDuration, 0), 1))
            if fillW > 1 {
                RED.setFill()
                UIBezierPath(roundedRect: CGRect(x: barX, y: barY, width: fillW, height: barH), cornerRadius: 2.5).fill()
            }
        }
        let timeY = barY + barH + 9
        write (fmtSeconds(npElapsed),  x: barX,        y: timeY, size: 11, color: DIM, bold: true)
        writeR(fmtSeconds(npDuration), x: barX + barW, y: timeY, size: 11, color: DIM, bold: true)
    }

    // MARK: — Stats Fallback (prawy panel gdy nic nie gra)

    // MARK: — Separatory

    // MARK: — Calibration Overlay

    func drawCalibrationOverlay(_ l: Layout) {
        let W = l.W, H = l.H
        let cx = W / 2, cy = H / 2

        // Przyciemnienie tła (ręczna kalibracja)
        UIColor.black.withAlphaComponent(0.72).setFill()
        UIRectFill(CGRect(origin: .zero, size: CGSize(width: W, height: H)))

        if calibrationCountdown == -2 {
            // ── Stan: Skalibrowano ✓ (ręczna kalibracja) ─────────────────
            writeGlow("✓", x: cx, y: cy - 14, size: 64, color: GREEN,
                      glow: GREEN.withAlphaComponent(0.45))
            writeCtr(String(localized: "SKALIBROWANO"), x: cx, y: cy + 40, size: 14,
                     color: GREEN, bold: true)
        } else {
            // ── Stan: Odliczanie / Pomiar ─────────────────────────────────
            writeCtr(String(localized: "JEDŹ PROSTO"), x: cx, y: cy - 70, size: 13,
                     color: WHITE, bold: true)

            // Duży licznik
            let num = calibrationCountdown > 0 ? "\(calibrationCountdown)" : "●"
            let col = calibrationCountdown > 0 ? ORANGE : RED
            writeGlow(num, x: cx, y: cy - 8, size: 76, color: col,
                      glow: col.withAlphaComponent(0.40))

            // Pasek postępu: 5s → pełny, 0 → pusty
            let barW: CGFloat = 260
            let barX = cx - barW / 2
            let barY = cy + 48
            let barH: CGFloat = 8

            // Tło
            WHITE.withAlphaComponent(0.15).setFill()
            UIBezierPath(roundedRect: CGRect(x: barX, y: barY, width: barW, height: barH),
                         cornerRadius: 4).fill()

            // Fill — maleje z upływem czasu
            let progress = CGFloat(max(calibrationCountdown, 0)) / 5.0
            if progress > 0 {
                ORANGE.setFill()
                UIBezierPath(roundedRect: CGRect(x: barX, y: barY,
                                                 width: barW * progress, height: barH),
                             cornerRadius: 4).fill()
            }

            writeCtr(String(localized: "przechyl poprawnie zamontowany telefon"), x: cx, y: barY + 22,
                     size: 9, color: DIM)
        }

        // Obramowanie całości (sygnał wizualny że tryb aktywny)
        ORANGE.withAlphaComponent(calibrationCountdown == -2 ? 0.0 : 0.6).setStroke()
        let border = UIBezierPath(rect: CGRect(x: 2, y: 2, width: W - 4, height: H - 4))
        border.lineWidth = 3; border.stroke()
    }

    // MARK: — Text helpers

    func write(_ text: String, x: CGFloat, y: CGFloat,
                       size: CGFloat, color: UIColor, bold: Bool = false) {
        let a: [NSAttributedString.Key: Any] = [.font: mono(size, bold: bold), .foregroundColor: color]
        let ns = text as NSString; let sz = ns.size(withAttributes: a)
        ns.draw(in: px(CGRect(x: x, y: y - sz.height/2, width: sz.width, height: sz.height)),
                withAttributes: a)
    }

    /// Początek napisu w całych pikselach: Monocraft jest pikselową czcionką i w skali 1:1
    /// (strumień na wyświetlacz) pół piksela przesunięcia rozmazuje kreski liter.
    func px(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: ceil(r.width), height: ceil(r.height))
    }

    func writeCtr(_ text: String, x: CGFloat, y: CGFloat,
                           size: CGFloat, color: UIColor, bold: Bool = false) {
        let a: [NSAttributedString.Key: Any] = [.font: mono(size, bold: bold), .foregroundColor: color]
        let ns = text as NSString; let sz = ns.size(withAttributes: a)
        ns.draw(in: px(CGRect(x: x - sz.width/2, y: y - sz.height/2,
                              width: sz.width, height: sz.height)), withAttributes: a)
    }

    /// Jak `writeCtr`, ale środkuje FAKTYCZNY kształt znaków, a nie ich pole w czcionce.
    /// W czcionce o stałej szerokości „1" czy „C" nie leżą pośrodku swojego pola, więc
    /// pojedynczy znak w ramce (bieg, tryb jazdy) wyglądał na przesunięty. Tu środek
    /// rysunku znaku trafia dokładnie w (x, y), w poziomie i w pionie.
    func writeInkCtr(_ text: String, x: CGFloat, y: CGFloat,
                     size: CGFloat, color: UIColor, bold: Bool = false) {
        let font = mono(size, bold: bold)
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: a))
        // Obrys znaków względem początku linii bazowej (oś y w górę).
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard ink.width > 0, ink.height > 0, !ink.isNull else {
            writeCtr(text, x: x, y: y, size: size, color: color, bold: bold)
            return
        }
        (text as NSString).draw(at: CGPoint(x: (x - ink.midX).rounded(), y: (y - font.ascender + ink.midY).rounded()),
                                withAttributes: a)
    }

    func writeR(_ text: String, x: CGFloat, y: CGFloat,
                        size: CGFloat, color: UIColor, bold: Bool = false) {
        let a: [NSAttributedString.Key: Any] = [.font: mono(size, bold: bold), .foregroundColor: color]
        let ns = text as NSString; let sz = ns.size(withAttributes: a)
        ns.draw(in: px(CGRect(x: x - sz.width, y: y - sz.height/2,
                              width: sz.width, height: sz.height)), withAttributes: a)
    }

    func writeGlow(_ text: String, x: CGFloat, y: CGFloat,
                            size: CGFloat, color: UIColor, glow: UIColor?) {
        var a: [NSAttributedString.Key: Any] = [.font: mono(size, bold: true), .foregroundColor: color]
        if let g = glow {
            let sh = NSShadow()
            // shadowBlurRadius 14 → 6: ~3x szybszy render bez wyraźnej różnicy wizualnej
            sh.shadowColor = g; sh.shadowOffset = .zero; sh.shadowBlurRadius = 6
            a[.shadow] = sh
        }
        let ns = text as NSString; let sz = ns.size(withAttributes: a)
        ns.draw(in: px(CGRect(x: x - sz.width/2, y: y - sz.height/2,
                              width: sz.width, height: sz.height)), withAttributes: a)
    }

    /// Tekst z obcinaniem ogona (dla długich tytułów/artystów)
    func writeClipped(_ text: String, x: CGFloat, y: CGFloat,
                               width: CGFloat, size: CGFloat, color: UIColor, bold: Bool = false) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let a: [NSAttributedString.Key: Any] = [
            .font: mono(size, bold: bold),
            .foregroundColor: color,
            .paragraphStyle: para
        ]
        let ns = text as NSString
        let sz = ns.size(withAttributes: a)
        ns.draw(in: px(CGRect(x: x, y: y - sz.height / 2, width: width, height: sz.height)),
                withAttributes: a)
    }

    /// DateFormatter dla zegara w headerze — singleton, żeby nie alokować na każdą klatkę (15fps)
    static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Monocraft (wymagany .ttf w bundlu + UIAppFonts), fallback: SF Mono
    func mono(_ size: CGFloat, bold: Bool = false) -> UIFont {
        for name in bold ? ["Monocraft-Bold", "Monocraft Bold", "Monocraft"] : ["Monocraft"] {
            if let f = UIFont(name: name, size: size) { return f }
        }
        return UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    // MARK: — Formatters

    func fmtDist(_ m: Double) -> String {
        m >= 1000 ? String(format: "%.1f km", m / 1000) : String(format: "%.0f m", m)
    }

    func fmtSeconds(_ t: Double) -> String {
        guard t > 0 else { return "--:--" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    func fmtTime(_ s: Int) -> String {
        let h = s/3600, m = (s%3600)/60, ss = s%60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss)
                     : String(format: "%02d:%02d", m, ss)
    }

    func hdgString() -> String {
        guard headingDeg >= 0 else { return "—" }
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let dir  = dirs[Int((headingDeg + 22.5) / 45.0) % 8]
        return "\(dir)  \(Int(headingDeg))°"
    }
}

// MARK: — Xcode Canvas Preview
// Cmd+S → natychmiastowy podgląd dashboardu bez deployu na telefon.
// Otwórz Canvas: Editor ▸ Canvas (Opt+Cmd+Return).
// Żeby szybko testować zmiany w renderze: zmieniaj wartości poniżej i zapisuj.

#if DEBUG
import SwiftUI

private func makeTestRenderer(dark: Bool = true) -> FrameRenderer {
    let r = FrameRenderer(width: 864, height: 320)
    r.isDarkMode     = dark
    r.speedKmh       = 127
    r.maxSpeedKmh    = 168
    r.leanAngleDeg   = -23.4
    r.maxLeanLeft    = 41.2
    r.maxLeanRight   = 38.7
    r.gForce         = 0.45
    r.headingDeg     = 52          // NE
    r.altitudeM      = 320
    r.temperatureC   = 18
    r.tripDistKm     = 42.5
    r.sessionSec     = 3612        // 1h 0m 12s
    r.gpsAccuracy    = 8
    return r
}

// ── Zrzut ekranu KLASYCZNEGO z pełnym headerem (env CLASSIC_SHOT=1) ──
extension FrameRenderer {
    static func debugWriteClassicShot(dark: Bool = true) {
        let r = FrameRenderer(width: 864, height: 320)
        r.isDarkMode = dark
        r.activeScreen = DashboardScreen.classic.rawValue
        r.speedKmh = 87; r.maxSpeedKmh = 168; r.avgSpeedKmh = 54
        r.leanAngleDeg = -18; r.maxLeanLeft = 42; r.maxLeanRight = 39
        r.gForce = 0.4; r.maxGforce = 1.1
        r.headingDeg = 52; r.altitudeM = 320; r.temperatureC = 18
        r.tripDistKm = 42.5; r.sessionSec = 3612; r.gpsAccuracy = 8
        r.recordingActive = true; r.sunsetString = "20:41"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("classic.png")
        try? r.renderImage().pngData()?.write(to: url)
        NSLog("[CLASSIC_SHOT] zapisano \(url.path)")
    }
}

// ── Zrzuty WZORCOWE ekranów składanych z klocków (env BLOCK_SHOT=1) ──
// Sceny są w pełni deterministyczne (zamrożony czas, stałe dane), więc dwa
// przebiegi dają identyczne piksele. Służy do sprawdzania, że przebudowa
// renderera niczego nie przesunęła: zrzut przed → zmiana → zrzut po → diff.
extension FrameRenderer {
    static func debugWriteBlockShots() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("blockshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func gradient(_ a: UIColor, _ b: UIColor, _ size: CGSize) -> UIImage {
            UIGraphicsImageRenderer(size: size).image { ctx in
                let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1])!
                ctx.cgContext.drawLinearGradient(g, start: .zero,
                    end: CGPoint(x: size.width, y: size.height), options: [])
            }
        }
        func base(dark: Bool, screen: DashboardScreen) -> FrameRenderer {
            let r = FrameRenderer(width: 864, height: 320)
            r.debugNow = Date(timeIntervalSince1970: 1_760_000_000)
            r.isDarkMode = dark
            r.activeScreen = screen.rawValue
            r.speedKmh = 87; r.maxSpeedKmh = 168; r.avgSpeedKmh = 54
            r.leanAngleDeg = -18; r.maxLeanLeft = 42; r.maxLeanRight = 39
            r.gForce = 0.4; r.maxGforce = 1.1
            r.headingDeg = 52; r.altitudeM = 320; r.temperatureC = 18
            r.tripDistKm = 42.5; r.sessionSec = 3612; r.gpsAccuracy = 8
            r.recordingActive = true; r.sunsetString = "20:41"
            return r
        }
        func music(_ r: FrameRenderer) {
            r.npTitle = "Midnight City"; r.npArtist = "M83"
            r.npArtwork = gradient(UIColor(red: 0.55, green: 0.10, blue: 0.75, alpha: 1),
                                   UIColor(red: 1.00, green: 0.45, blue: 0.10, alpha: 1),
                                   CGSize(width: 300, height: 300))
            r.npDuration = 240; r.npElapsed = 96; r.npIsPlaying = true
        }
        var scenes: [(String, FrameRenderer)] = []
        scenes.append(("classic_dark",  base(dark: true,  screen: .classic)))
        scenes.append(("classic_light", base(dark: false, screen: .classic)))
        let cm = base(dark: true, screen: .classic); music(cm)
        scenes.append(("classic_music", cm))
        let lean3 = base(dark: true, screen: .classic)
        lean3.speedKmh = 7; lean3.leanAngleDeg = 44; lean3.recordingActive = false
        lean3.sunsetString = ""; lean3.temperatureC = nil; lean3.gpsAccuracy = -1; lean3.headingDeg = -1
        scenes.append(("classic_sparse", lean3))
        scenes.append(("navclassic_idle", base(dark: true, screen: .navClassic)))
        let nv = base(dark: true, screen: .navClassic); music(nv)
        nv.navActive = true; nv.navInstruction = "Skręć w prawo w ulicę Długą"
        nv.navDistanceToNext = 420; nv.navRemainingDistance = 38_400; nv.navRemainingTime = 2520
        nv.mapImage = gradient(UIColor(white: 0.20, alpha: 1), UIColor(red: 0.10, green: 0.25, blue: 0.20, alpha: 1),
                               CGSize(width: 600, height: 400))
        scenes.append(("navclassic_nav", nv))
        let nl = base(dark: false, screen: .navClassic)
        nl.navActive = true; nl.navInstruction = "Na rondzie drugi zjazd"
        nl.navDistanceToNext = 1250; nl.navRemainingDistance = 9_300; nl.navRemainingTime = 840
        scenes.append(("navclassic_light", nl))

        // ── Sceny z paskiem informacyjnym (pogoda na trasie, wiatr, odcinek) ──
        let c1 = base(dark: true, screen: .classic); music(c1)
        c1.infoChips = [DashChip(text: "☔ deszcz za 25 km · 18 min", tone: .rain),
                        DashChip(text: "💨 34 km/h z lewej", tone: .warn)]
        scenes.append(("chips_rain_wind", c1))
        let c2 = base(dark: true, screen: .classic)
        c2.infoChips = [DashChip(text: "sucho przez 3 h", tone: .quiet)]
        scenes.append(("chips_dry", c2))
        let c3 = base(dark: false, screen: .classic)
        c3.infoChips = [DashChip(text: "⏱ Przełęcz Salmopolska  −1.2 s", tone: .good),
                        DashChip(text: "☔ pada · sucho za 12 km", tone: .rain)]
        scenes.append(("chips_segment_light", c3))
        let c4 = base(dark: true, screen: .navClassic); music(c4)
        c4.navActive = true; c4.navInstruction = "Skręć w prawo w ulicę Długą"
        c4.navDistanceToNext = 420; c4.navRemainingDistance = 38_400; c4.navRemainingTime = 2520
        c4.mapImage = nv.mapImage
        c4.infoChips = [DashChip(text: "☔ ulewa za 8.4 km · 7 min", tone: .rain)]
        scenes.append(("chips_nav", c4))
        let c5 = base(dark: true, screen: .classic)
        c5.infoChips = [DashChip(text: "🏁 Przełęcz Salmopolska  2:31.4  −1.2 s  REKORD", tone: .good),
                        DashChip(text: "☔ mżawka za 40 min", tone: .rain),
                        DashChip(text: "💨 55 km/h z prawej", tone: .bad)]
        scenes.append(("chips_overflow", c5))

        // ── Mostek CAN: bieg + obroty (sama liczba) na panelu prędkości ──
        func engine(_ r: FrameRenderer, rpm: Int, gear: Int) {
            var t = BikeTelemetry()
            t.rpm = rpm; t.gear = gear; t.engineFresh = true; t.leanFresh = true; t.busFps = 900
            r.bike = t
        }
        let b1 = base(dark: true, screen: .classic); music(b1); engine(b1, rpm: 5400, gear: 4)
        b1.leanSource = .bike
        scenes.append(("bike_cruise", b1))
        let b2 = base(dark: true, screen: .classic); engine(b2, rpm: 11_300, gear: 2); b2.speedKmh = 128
        scenes.append(("bike_3digits", b2))
        let b3 = base(dark: false, screen: .classic); engine(b3, rpm: 1300, gear: 0); b3.speedKmh = 0
        b3.leanSource = .bike
        scenes.append(("bike_neutral_light", b3))
        let b4 = base(dark: true, screen: .classic); engine(b4, rpm: 9800, gear: 3)
        b4.infoChips = [DashChip(text: "☔ deszcz za 25 km · 18 min", tone: .rain)]
        scenes.append(("bike_chips", b4))
        // Mostek włączony, ale płytka milczy → znaczek PHONE; do tego najdłuższe teksty w nagłówku
        let s1 = base(dark: true, screen: .classic); s1.leanSource = .phone
        s1.avgSpeedKmh = 104; s1.gpsAccuracy = 15; s1.headingDeg = 315; s1.altitudeM = 1240; s1.temperatureC = -12
        scenes.append(("src_phone_long_header", s1))
        let s2 = base(dark: false, screen: .navClassic); s2.leanSource = .phone
        scenes.append(("src_phone_light_nav", s2))
        let s3 = base(dark: true, screen: .navClassic); s3.leanSource = .bike; s3.recordingActive = false
        let s4 = base(dark: true, screen: .classic); s4.leanSource = .simulated
        scenes.append(("src_simulated", s4))
        scenes.append(("src_bike_nav", s3))
        // Dane z silnika nieświeże (zapłon wyłączony) → deska bez zmian
        let b5 = base(dark: true, screen: .classic); music(b5); engine(b5, rpm: 0, gear: 0); b5.bike?.engineFresh = false
        scenes.append(("bike_stale_same_as_classic_music", b5))

        // ── Mostek CAN, program płytki v4: tryb + trakcja, płyn, gaz, powietrze, zawieszenie ──
        func ext(_ r: FrameRenderer, mode: Int, tc: Int, coolant: Double, throttle: Double, air: Double,
                 susp: (Double, Double) = (0.45, -0.15)) {
            guard var t = r.bike else { return }
            t.ext = true; t.envFresh = true; t.modeFresh = true; t.tcFresh = true; t.suspFresh = true
            t.rideModeRaw = mode; t.tcLevel = tc
            t.dampFresh = true; t.dampMode = mode == 1 ? 2 : 1; t.odometerKm = 23_418
            t.coolantRaw = Int(((coolant + 30) / 0.625).rounded()); t.airRaw = Int(air) + 30
            t.throttle10 = Int(throttle * 6.9); t.throttleRaw = t.throttle10 >> 2
            r.bike = t
            r.suspTravel = (susp.0, susp.1)
            r.leanSource = .bike
        }
        let e1 = base(dark: true, screen: .classic); music(e1); engine(e1, rpm: 5400, gear: 4)
        ext(e1, mode: 2, tc: 3, coolant: 88, throttle: 34, air: 21)
        scenes.append(("ext_cruise", e1))
        let e2 = base(dark: false, screen: .classic); engine(e2, rpm: 11_300, gear: 2); e2.speedKmh = 128
        ext(e2, mode: 1, tc: 0, coolant: 118, throttle: 100, air: 31, susp: (-0.6, 0.95))
        scenes.append(("ext_hot_light_3digits", e2))
        let e3 = base(dark: true, screen: .classic); engine(e3, rpm: 0, gear: 1); e3.speedKmh = 0
        ext(e3, mode: 3, tc: 7, coolant: 42, throttle: 0, air: 9, susp: (0, 0))
        e3.leanAngleDeg = -90
        scenes.append(("ext_crash_90_cold", e3))
        // Terminal CAN z prawdziwymi bajtami z logu jazdy (canlogs/can_20261025_170920.csv)
        func hacker(_ name: String, dtc: Bool, granted: Bool) {
            let h = base(dark: true, screen: .hacker); engine(h, rpm: 5400, gear: 4)
            ext(h, mode: 2, tc: 1, coolant: 88, throttle: 34, air: 18)
            h.leanAngleDeg = -23.5; h.speedKmh = 87
            if var b = h.bike { b.busFps = 1970; b.fwVersion = 10; h.bike = b }
            // stały czas — powtarzalny zrzut
            h.debugNow = Date(timeIntervalSince1970: granted ? 1_792_950_000.4 : 1_792_950_013.3)
            let sample: [(UInt16, [UInt8])] = [
                (0x1A1, [0x15, 0x18, 0x56, 0x84, 0x06, 0xC0, 0x05, 0x00]), (0x1A5, [0x75, 0xC3, 0x80, 0x00, 0x75, 0x00, 0x05, 0x00]),
                (0x181, [0x80, 0x0F, 0x6D, 0x2A, 0x85, 0x04, 0x01, 0x10]), (0x17D, [0x04, 0x34, 0x01, 0xFC, 0x09, 0x00, 0x02, 0x33]),
                (0x19D, [0x21, 0xFC, 0x21, 0x6A, 0x00, 0x00, 0x0B, 0xC5]), (0x175, [0x7F, 0xF9, 0x7F, 0xFA, 0x7F, 0xF4, 0x01, 0x7B]),
                (0x179, [0x80, 0x1B, 0x6D, 0x39, 0x85, 0x0B, 0x01, 0x3D]), (0x221, [0x9E, 0x13, 0x10, 0xE5, 0x80, 0x00, 0x03, 0x00]),
            ]
            var lines: [HackerLine] = []
            for i in 0..<30 {
                let (id, d0) = sample[i % sample.count]
                var d = d0; d[7] = UInt8((i * 37) & 0xFF); d[i % 6] ^= UInt8(i & 0x0F)
                lines.append(HackerLine(t: 1234.5 + Double(i) * 0.04, id: id, data: d, changed: UInt8(1 << (i % 6)) | 0x80))
            }
            h.hackerLines = lines
            var table = Dictionary(uniqueKeysWithValues: sample.map { ($0.0, $0.1) })
            table[0x441] = dtc ? [0x00, 0xC1, 0x55, 0x05, 0x01, 0x00, 0x0A, 0x00] : [0, 0, 0, 0, 0, 0, 0x09, 0]
            h.hackerTable = table
            scenes.append((name, h))
        }
        hacker("hacker_clean", dtc: false, granted: false)
        hacker("hacker_dtc_granted", dtc: true, granted: true)
        let hNo = base(dark: true, screen: .hacker); hNo.hackerTable = [:]
        scenes.append(("hacker_no_board", hNo))
        // Telefon po staremu: liczba przechyłu obcięta do 65°
        let e4 = base(dark: true, screen: .classic); e4.leanSource = .phone; e4.leanAngleDeg = 72
        scenes.append(("ext_phone_lean_capped_65", e4))
        let e5 = base(dark: true, screen: .navClassic); engine(e5, rpm: 4200, gear: 5)
        ext(e5, mode: 2, tc: 2, coolant: 119, throttle: 12, air: 17)
        scenes.append(("ext_nav_hot", e5))

        // Każdy bieg i każdy tryb w ramce — do sprawdzenia, że znak leży na środku.
        for g in 0...6 {
            let r = base(dark: true, screen: .classic); engine(r, rpm: 3000 + g * 500, gear: g)
            ext(r, mode: 1 + g % 3, tc: g, coolant: 80, throttle: Double(g) * 15, air: 20)
            scenes.append(("ink_gear\(g)", r))
        }

        // ── Żywe tło: trzy chwile (ruch), ekran lean, wyłączone, oraz JPEG jak na motocykl ──
        for (i, dt) in [0.0, 30.0, 90.0].enumerated() {
            let r = base(dark: true, screen: .classic); music(r)
            r.debugNow = Date(timeIntervalSince1970: 1_760_000_000 + dt)
            scenes.append(("ambient_t\(i)", r))
        }
        scenes.append(("ambient_lean", base(dark: true, screen: .lean)))
        let off = base(dark: true, screen: .classic); music(off); off.ambientEnabled = false
        scenes.append(("ambient_off", off))
        let jr = base(dark: true, screen: .classic); music(jr); jr.jpegQuality = 0.40
        try? jr.render()?.write(to: dir.appendingPathComponent("ambient_q40.jpg"))
        off.jpegQuality = 0.40
        try? off.render()?.write(to: dir.appendingPathComponent("ambient_off_q40.jpg"))

        // Koszt: średni czas klatki z tłem i bez (30 renderów każdy)
        func avgMs(_ r: FrameRenderer) -> Double {
            let t0 = CACurrentMediaTime()
            for _ in 0..<30 { _ = r.render() }
            return (CACurrentMediaTime() - t0) / 30 * 1000
        }
        let on = base(dark: true, screen: .classic); music(on)
        var timing = String(format: "klatka z tłem: %.1f ms\nklatka bez tła: %.1f ms\n", avgMs(on), avgMs(off))
        // Porównanie skali strumienia: czas klatki i rozmiar JPEG przy kilku jakościach.
        for sc in [1, 3] as [CGFloat] {
            let r = base(dark: true, screen: .classic); music(r); engine(r, rpm: 5400, gear: 4)
            ext(r, mode: 2, tc: 3, coolant: 88, throttle: 34, air: 21)
            r.streamScale = sc
            for q in [0.40, 0.55, 0.70, 0.80, 0.90] as [CGFloat] {
                r.jpegQuality = q
                let n = r.render()?.count ?? 0
                timing += String(format: "skala %.0f, jakość %.2f: %.1f ms, %d bajtów\n", sc, q, avgMs(r), n)
                if sc == 1 || q == 0.40 {
                    try? r.render()?.write(to: dir.appendingPathComponent(String(format: "stream_x%.0f_q%02.0f.jpg", sc, q * 100)))
                }
            }
        }
        try? timing.write(to: dir.appendingPathComponent("timing.txt"), atomically: true, encoding: .utf8)

        for (name, r) in scenes {
            try? r.renderImage().pngData()?.write(to: dir.appendingPathComponent("\(name).png"))
            // To samo dokładnie tak, jak dostaje wyświetlacz (864×320, JPEG)
            try? r.renderImage(scale: r.streamScale).jpegData(compressionQuality: FrameRenderer.maxStreamQuality)?
                .write(to: dir.appendingPathComponent("\(name)_tft.jpg"))
        }
        NSLog("[BLOCK_SHOT] zapisano \(scenes.count) scen w \(dir.path)")
    }
}

// ── Zrzut ekranu DISCO z mockowym utworem (uruchamiane env DISCO_SHOT=1) ──
extension FrameRenderer {
    static func debugWriteDiscoShot(dark: Bool = true) {
        // Mock okładka — diagonalny gradient (fiolet→pomarańcz), żeby motyw miał z czego liczyć kolor
        let art = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).image { ctx in
            let cg = ctx.cgContext
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor(red: 0.55, green: 0.10, blue: 0.75, alpha: 1).cgColor,
                         UIColor(red: 1.00, green: 0.45, blue: 0.10, alpha: 1).cgColor] as CFArray,
                locations: [0, 1])!
            cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: 300, y: 300), options: [])
        }
        let r = FrameRenderer(width: 864, height: 320)
        r.isDarkMode  = dark
        r.activeScreen = DashboardScreen.disco.rawValue
        r.npTitle     = "Midnight City"
        r.npArtist    = "M83"
        r.npArtwork   = art
        r.npDuration  = 240
        r.npElapsed   = 96
        r.npIsPlaying = true
        r.lyricsLines = [
            .init(time: 88,  text: "Lights are running down the line"),
            .init(time: 92,  text: "A very long test line to check how the wrapping behaves on the display tonight"),
            .init(time: 96,  text: "Another long line of made-up words to see the wrap and the karaoke highlight"),
            .init(time: 100, text: "Every corner, one more song"),
            .init(time: 104, text: "Engine humming through the night"),
            .init(time: 108, text: "Hold the throttle, find the line"),
        ]
        let png = r.renderImage().pngData()
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("disco.png")
        try? png?.write(to: url)
        NSLog("[DISCO_SHOT] zapisano \(url.path)")
    }
}

// ── Widok do Canvas (i opcjonalnie do UI aplikacji jako Debug card) ──
struct RendererPreviewView: View {
    var dark: Bool = true
    var body: some View {
        Image(uiImage: makeTestRenderer(dark: dark).renderImage())
            .resizable()
            .aspectRatio(864.0 / 320.0, contentMode: .fit)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

#Preview("Dashboard — Dark", traits: .sizeThatFitsLayout) {
    RendererPreviewView(dark: true)
        .padding(8)
        .background(.black)
}

#Preview("Dashboard — Light", traits: .sizeThatFitsLayout) {
    RendererPreviewView(dark: false)
        .padding(8)
        .background(.gray)
}

#Preview("Dashboard — Now Playing", traits: .sizeThatFitsLayout) {
    let r = makeTestRenderer(dark: true)
    r.npTitle     = "Blinding Lights"
    r.npArtist    = "The Weeknd"
    r.npElapsed   = 95
    r.npDuration  = 200
    r.npIsPlaying = true
    return Image(uiImage: r.renderImage())
        .resizable()
        .aspectRatio(864.0 / 320.0, contentMode: .fit)
        .background(Color.black)
        .padding(8)
}

#Preview("Dashboard — Calibration", traits: .sizeThatFitsLayout) {
    let r = makeTestRenderer()
    r.calibrationCountdown = 3     // odliczanie
    return Image(uiImage: r.renderImage())
        .resizable()
        .aspectRatio(864.0 / 320.0, contentMode: .fit)
        .background(Color.black)
        .padding(8)
}
#endif
