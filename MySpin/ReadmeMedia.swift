// ReadmeMedia.swift — tylko DEBUG: grafiki do README (docs/media), na danych pokazowych.
//   README_SHOTS=1 → Documents/readme/
//     still_<ekran>.png          — ekrany deski 864×320 (1:1 jak na wyświetlaczu)
//     anim_<sekwencja>_NNNN.png  — klatki animacji (składa je tools/readme_media.sh)
//     done.txt                   — znak, że wszystko zapisane (mapa jest asynchroniczna)

#if DEBUG
import UIKit
import MapKit

extension FrameRenderer {

    static func debugWriteReadmeMedia() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("readme")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t0 = 1_792_400_000.0

        func save(_ r: FrameRenderer, _ name: String) {
            try? r.renderImage(scale: 1).pngData()?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        func gradient(_ a: UIColor, _ b: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300)).image { ctx in
                let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1])!
                ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 300, y: 300), options: [])
            }
        }
        let cover = gradient(UIColor(red: 0.55, green: 0.10, blue: 0.75, alpha: 1),
                             UIColor(red: 1.00, green: 0.45, blue: 0.10, alpha: 1))

        func base(_ screen: DashboardScreen, dark: Bool = true, t: Double = 0) -> FrameRenderer {
            let r = FrameRenderer(width: 864, height: 320)
            r.debugNow = Date(timeIntervalSince1970: t0 + t)
            r.isDarkMode = dark
            r.activeScreen = screen.rawValue
            r.speedKmh = 87; r.maxSpeedKmh = 168; r.avgSpeedKmh = 64
            r.leanAngleDeg = -18; r.maxLeanLeft = 42; r.maxLeanRight = 39
            r.gForce = 0.4; r.maxGforce = 1.1
            r.headingDeg = 52; r.altitudeM = 320; r.temperatureC = 18
            r.tripDistKm = 42.5; r.sessionSec = 3612 + Int(t); r.gpsAccuracy = 6
            r.recordingActive = true; r.sunsetString = "20:41"
            return r
        }
        func music(_ r: FrameRenderer, elapsed: Double = 96) {
            r.npTitle = "Neon Highway"; r.npArtist = "Demo Artist"; r.npArtwork = cover
            r.npDuration = 240; r.npElapsed = elapsed; r.npIsPlaying = true
        }
        /// Dane z płytki CAN: silnik, tryb jazdy B, trakcja 3, zawieszenie M, przebieg.
        func bike(_ r: FrameRenderer, rpm: Int, gear: Int, throttle: Double, coolant: Double = 88) {
            var b = BikeTelemetry()
            b.rpm = rpm; b.gear = gear; b.engineFresh = true; b.leanFresh = true; b.busFps = 1970; b.fwVersion = 10
            b.ext = true; b.envFresh = true; b.modeFresh = true; b.tcFresh = true; b.suspFresh = true; b.dampFresh = true
            b.rideModeRaw = 2; b.tcLevel = 3; b.dampMode = 1; b.odometerKm = 23_418
            b.coolantRaw = Int(((coolant + 30) / 0.625).rounded()); b.airRaw = 21 + 30
            b.throttle10 = Int(throttle * 6.9); b.throttleRaw = b.throttle10 >> 2
            r.bike = b
            r.leanSource = .bike
        }

        // ── Animacja 1: klasyczny ekran z płytką CAN — rozpędzanie, zmiany biegów, zakręty ──
        let fps = 12.0
        for i in 0..<84 {
            let t = Double(i) / fps
            let r = base(.classic, t: t); music(r, elapsed: 96 + t)
            let kmh = 62 + 70 * (0.5 - 0.5 * cos(t / 7 * .pi))
            let gear = kmh < 70 ? 3 : (kmh < 95 ? 4 : (kmh < 115 ? 5 : 6))
            let ratio: [Double] = [0, 0, 0, 72, 58, 50, 44]
            r.speedKmh = kmh
            r.leanAngleDeg = 34 * sin(t * 0.9)
            r.gForce = 0.3 + 0.25 * abs(sin(t * 0.9))
            bike(r, rpm: Int(kmh * ratio[gear]), gear: gear, throttle: 20 + 60 * max(0, sin(t / 7 * .pi)))
            r.suspTravel = (0.35 + 0.3 * sin(t * 2.1), -0.1 + 0.25 * sin(t * 1.7))
            save(r, String(format: "anim_classic_%04d", i))
        }

        // ── Animacja 2: Terminal CAN — przewijające się ramki ──
        let sample: [(UInt16, [UInt8])] = [
            (0x1A1, [0x15, 0x18, 0x56, 0x84, 0x06, 0xC0, 0x05, 0x00]), (0x1A5, [0x75, 0xC3, 0x80, 0x00, 0x75, 0x00, 0x05, 0x00]),
            (0x181, [0x80, 0x0F, 0x6D, 0x2A, 0x85, 0x04, 0x01, 0x10]), (0x17D, [0x04, 0x34, 0x01, 0xFC, 0x09, 0x00, 0x02, 0x33]),
            (0x19D, [0x21, 0xFC, 0x21, 0x6A, 0x00, 0x00, 0x0B, 0xC5]), (0x175, [0x7F, 0xF9, 0x7F, 0xFA, 0x7F, 0xF4, 0x01, 0x7B]),
            (0x179, [0x80, 0x1B, 0x6D, 0x39, 0x85, 0x0B, 0x01, 0x3D]), (0x221, [0x9E, 0x13, 0x10, 0xE5, 0x80, 0x00, 0x03, 0x00]),
        ]
        var lines: [HackerLine] = []
        func line(_ n: Int) -> HackerLine {
            let (id, d0) = sample[n % sample.count]
            var d = d0; d[7] = UInt8((n * 37) & 0xFF); d[n % 6] ^= UInt8(n & 0x0F)
            return HackerLine(t: 1234.5 + Double(n) * 0.04, id: id, data: d, changed: UInt8(1 << (n % 6)) | 0x80)
        }
        for n in 0..<30 { lines.append(line(n)) }
        for i in 0..<48 {
            let t = Double(i) / fps
            let h = base(.hacker, t: t)
            bike(h, rpm: 5200 + Int(400 * sin(t * 2)), gear: 4, throttle: 30 + 10 * sin(t))
            h.speedKmh = 87 + 4 * sin(t); h.leanAngleDeg = -23 + 10 * sin(t * 1.3)
            for k in 0..<3 { lines.removeFirst(); lines.append(line(30 + i * 3 + k)) }
            h.hackerLines = lines
            var table = Dictionary(uniqueKeysWithValues: sample.map { ($0.0, $0.1) })
            table[0x441] = [0, 0, 0, 0, 0, 0, 0x09, 0]
            h.hackerTable = table
            save(h, String(format: "anim_hacker_%04d", i))
        }

        // ── Animacja 3: przechył na cały ekran (bez płytki — z telefonu) ──
        for i in 0..<48 {
            let t = Double(i) / fps
            let r = base(.lean, t: t)
            r.leanAngleDeg = 41 * sin(t / 4 * 2 * .pi)
            r.leanSource = .phone
            save(r, String(format: "anim_lean_%04d", i))
        }

        // ── Ekrany nieruchome ──
        let phone = base(.classic); music(phone); phone.leanSource = .phone
        save(phone, "still_classic_phone")                                  // bez płytki CAN
        let light = base(.classic, dark: false); light.leanSource = .phone
        save(light, "still_classic_light")
        let can = base(.classic); music(can); bike(can, rpm: 5400, gear: 4, throttle: 34)
        can.suspTravel = (0.45, -0.15)
        save(can, "still_classic_can")
        let hot = base(.classic, dark: false); bike(hot, rpm: 11_300, gear: 2, throttle: 100, coolant: 104)
        hot.speedKmh = 128; hot.suspTravel = (-0.6, 0.95)
        save(hot, "still_classic_can_light")
        let lean = base(.lean); lean.leanAngleDeg = 38; lean.leanSource = .phone
        save(lean, "still_lean")

        let disco = base(.disco); music(disco)
        disco.lyricsLines = [
            .init(time: 88, text: "Lights are running down the line"),
            .init(time: 92, text: "Cold air hits the visor glass"),
            .init(time: 96, text: "Lean it over, hold the throttle"),
            .init(time: 100, text: "Every corner, one more song"),
            .init(time: 104, text: "Engine humming through the night"),
        ]
        save(disco, "still_disco")

        let perf = base(.performance)
        perf.perfSnapshot = PerfSnapshot(stateLabel: "Gotowy", armed: true, running: false, speed: 0, elapsed: 0,
                                         distance: 0, zeroTo60: 2.4, zeroTo100: 3.6, quarter: 11.4, quarterTrap: 196,
                                         zeroTo400m: 11.4, maxSpeed: 205, lastRun: nil)
        save(perf, "still_perf")

        let snake = base(.snake)
        let body: [(Int, Int)] = [(14, 6), (13, 6), (12, 6), (11, 6), (11, 7), (11, 8), (10, 8), (9, 8), (8, 8), (8, 9)]
        snake.snakeSnapshot = SnakeSnapshot(cols: 30, rows: 11, snake: body, food: (20, 4), score: 9,
                                            gameOver: false, started: true)
        save(snake, "still_snake")

        let sudoku = base(.sudoku)
        var givens = [Int](repeating: 0, count: 81), entries = [Int](repeating: 0, count: 81)
        for r in 0..<9 { for c in 0..<9 {
            let v = (r * 3 + r / 3 + c) % 9 + 1           // poprawna plansza
            if (r * 7 + c * 5) % 3 == 0 { givens[r * 9 + c] = v; entries[r * 9 + c] = v }
            else if (r + c) % 4 == 0 { entries[r * 9 + c] = v }
        } }
        sudoku.sudokuSnapshot = SudokuSnapshot(givens: givens, entries: entries, cursor: 40, editing: false,
                                               conflicts: [], completed: [], solved: false, generating: false,
                                               difficulty: "Średni", filled: entries.filter { $0 > 0 }.count,
                                               source: "Dnia")
        save(sudoku, "still_sudoku")

        // ── Nawigacja z prawdziwą mapą (Apple Maps, asynchronicznie) ──
        let opts = MKMapSnapshotter.Options()
        opts.size = CGSize(width: 494, height: 320)
        opts.scale = 1
        opts.mapType = .mutedStandard
        opts.pointOfInterestFilter = .excludingAll
        let center = CLLocationCoordinate2D(latitude: 50.0614, longitude: 19.9366)
        opts.camera = MKMapCamera(lookingAtCenter: center, fromDistance: 900, pitch: 0, heading: 30)
        opts.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        let snapper = MKMapSnapshotter(options: opts)
        snapper.start { [snapper] snap, _ in
            _ = snapper
            DispatchQueue.main.async {
                let nav = base(.navClassic); music(nav)
                nav.navActive = true; nav.navInstruction = "Skręć w prawo"
                nav.navDistanceToNext = 420; nav.navRemainingDistance = 38_400; nav.navRemainingTime = 2520
                nav.mapImage = snap?.image
                save(nav, "still_nav")
                let full = base(.navigation)
                full.navActive = true; full.navInstruction = "Skręć w prawo"
                full.navDistanceToNext = 420; full.navRemainingDistance = 38_400; full.navRemainingTime = 2520
                full.mapImage = snap?.image
                save(full, "still_nav_full")
                try? "ok".write(to: dir.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
                NSLog("[README_SHOTS] zapisano do \(dir.path)")
            }
        }
    }
}
#endif
