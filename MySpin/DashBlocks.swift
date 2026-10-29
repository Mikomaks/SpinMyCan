// DashBlocks.swift
// KLOCKI deski — samodzielne kawałki ekranu motocykla.
//
// Każdy klocek umie się narysować w DOWOLNYM prostokącie (`draw…Block(in:)`),
// a ekran to po prostu lista „klocek + prostokąt" (`DashSlot`). Dzięki temu
// nowy ekran składa się z gotowych części zamiast kopiować rysowanie:
//
//     case .navClassic: return threeColumn(l, center: .navMap)
//
// Jak dodać klocek:
//   1. dopisz przypadek w `DashBlock`
//   2. napisz `func drawCośBlock(in r: CGRect)` — wszystkie współrzędne licz
//      od `r`, nigdy od zera ani od stałych rozmiarów ekranu
//   3. dopisz go w `draw(_:in:)`
// Jak dodać ekran: dopisz przypadek w `slots(for:_:)`.
//
// Ekrany specjalne (disco, wspomnienia, gry, pełnoekranowy lean, osiągi) mają
// własne rysowanie w FrameRenderer.swift — nie składają się z kolumn.
//
// Plik jest rozszerzeniem FrameRenderer, więc korzysta z jego palety, pisania
// tekstu i formaterów; dlatego tamte składowe nie są już `private`.

import UIKit

/// Katalog klocków.
/// Skąd pochodzi przechył pokazywany na desce.
enum LeanSource {
    case bike, phone
    /// Płytka ma wgrany program testowy — kąt jest sztuczny.
    case simulated
}

enum DashBlock {
    case header        // pasek stanu: GPS, REC, średnia, kompas, zachód, wysokość, temperatura, zegar
    case lean          // mini-HUD przechyłu z sylwetką motocykla
    case speed         // wielki prędkościomierz + MAX i przeciążenie
    case navMap        // mapa nawigacji z banerem manewru
    case nowPlaying    // teraz gra (bez muzyki sam przechodzi w `stats`)
    case stats         // trip / czas / wysokość / kurs
    case infoStrip     // rząd pigułek: pogoda na trasie, wiatr boczny, odcinek (pusty = nic nie rysuje)
}

/// Pigułka paska informacyjnego. Treść składa ContentView z menedżerów
/// (pogoda, odcinki) — renderer tylko ją rysuje.
struct DashChip: Equatable {
    enum Tone { case rain, good, warn, bad, quiet }
    var text: String
    var tone: Tone
}

/// Miejsce klocka na ekranie. `separators` = cienkie linie na krawędziach
/// TEGO prostokąta (rysowane na końcu, nad wszystkimi klockami).
struct DashSlot {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left  = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
    }
    let block: DashBlock
    let rect: CGRect
    var separators: Edges = []
}

extension FrameRenderer {

    // MARK: — Składanie ekranów

    /// Ekrany złożone z klocków. nil = ekran specjalny, rysuje się sam.
    func slots(for screen: DashboardScreen, _ l: Layout) -> [DashSlot]? {
        switch screen {
        case .classic:    return threeColumn(l, center: .speed)
        case .navClassic: return threeColumn(l, center: .navMap)
        default:          return nil
        }
    }

    /// Układ „deska": nagłówek + przechył | środek | muzyka. Zmienia się tylko środek.
    func threeColumn(_ l: Layout, center: DashBlock) -> [DashSlot] {
        [ DashSlot(block: .header,     rect: CGRect(x: 0,     y: 0,       width: l.W,  height: l.hH)),
          DashSlot(block: .lean,       rect: CGRect(x: 0,     y: l.mainY, width: l.lW, height: l.mainH)),
          DashSlot(block: center,      rect: CGRect(x: l.cX,  y: l.mainY, width: l.cW, height: l.mainH),
                   separators: [.left, .right]),
          DashSlot(block: .nowPlaying, rect: CGRect(x: l.stX, y: l.mainY, width: l.sW, height: l.mainH)),
          // Pasek pigułek u góry środka; na mapie zjeżdża pod baner manewru.
          DashSlot(block: .infoStrip,
                   rect: CGRect(x: l.cX, y: l.mainY + ((center == .navMap && navActive) ? 62 : 7),
                                width: l.cW, height: 24)) ]
    }

    func paintSlots(_ slots: [DashSlot]) {
        for s in slots { draw(s.block, in: s.rect) }
        RED_LINE.setFill()
        for s in slots {
            if s.separators.contains(.left) {
                UIRectFill(CGRect(x: s.rect.minX, y: s.rect.minY, width: 1, height: s.rect.height))
            }
            if s.separators.contains(.right) {
                UIRectFill(CGRect(x: s.rect.maxX - 1, y: s.rect.minY, width: 1, height: s.rect.height))
            }
        }
    }

    func draw(_ block: DashBlock, in r: CGRect) {
        switch block {
        case .header:     drawHeaderBlock(in: r)
        case .lean:       drawLeanBlock(in: r)
        case .speed:      drawSpeedBlock(in: r)
        case .navMap:     drawNavMapBlock(in: r)
        case .nowPlaying: drawNowPlayingBlock(in: r)
        case .stats:      drawStatsBlock(in: r)
        case .infoStrip:  drawInfoStripBlock(in: r)
        }
    }

    // MARK: — Pasek informacyjny (pigułki)

    /// Rząd pigułek wyśrodkowany w `r`. Gdy się nie mieszczą, odpadają te z końca
    /// listy — kolejność w `infoChips` jest więc kolejnością ważności.
    func drawInfoStripBlock(in r: CGRect) {
        guard !infoChips.isEmpty else { return }
        let size: CGFloat = 13, padX: CGFloat = 10, gap: CGFloat = 8
        let font = mono(size, bold: true)
        var chips = infoChips
        func widths() -> [CGFloat] {
            chips.map { ($0.text as NSString).size(withAttributes: [.font: font]).width + padX * 2 }
        }
        var ws = widths()
        while chips.count > 1, ws.reduce(0, +) + gap * CGFloat(chips.count - 1) > r.width - 12 {
            chips.removeLast(); ws = widths()
        }
        let total = min(r.width - 12, ws.reduce(0, +) + gap * CGFloat(chips.count - 1))
        var x = r.midX - total / 2
        for (chip, w0) in zip(chips, ws) {
            let w = min(w0, r.width - 12)
            let box = CGRect(x: x, y: r.minY, width: w, height: r.height)
            let accent: UIColor
            switch chip.tone {
            case .rain:  accent = BLUE
            case .good:  accent = GREEN
            case .warn:  accent = ORANGE
            case .bad:   accent = RED
            case .quiet: accent = DIM
            }
            let path = UIBezierPath(roundedRect: box, cornerRadius: r.height / 2)
            BG.withAlphaComponent(0.90).setFill(); path.fill()
            if chip.tone != .quiet {
                accent.withAlphaComponent(0.75).setStroke(); path.lineWidth = 1.5; path.stroke()
            }
            writeClipped(chip.text, x: box.minX + padX, y: box.midY, width: w - padX * 2 + 4,
                         size: size, color: chip.tone == .quiet ? GRAY : accent, bold: true)
            x += w + gap
        }
    }


    /// Środkowy panel z mapą heading-up + bannerem turn-by-turn (dla navClassic).
    func drawNavMapBlock(in r: CGRect) {
        let px = r.minX, py = r.minY, pw = r.width, ph = r.height
        let rect = CGRect(x: px, y: py, width: pw, height: ph)

        BG_DARK.setFill(); UIRectFill(rect)

        if let img = mapImage, let ctx = UIGraphicsGetCurrentContext(), img.size.width > 0 {
            ctx.saveGState(); ctx.clip(to: rect)
            // Aspect-fill mapy w panelu (bez zniekształceń)
            let s  = max(pw / img.size.width, ph / img.size.height)
            let dw = img.size.width * s, dh = img.size.height * s
            img.draw(in: CGRect(x: rect.midX - dw/2, y: rect.midY - dh/2, width: dw, height: dh))
            ctx.restoreGState()
            drawNavCursor(cx: rect.midX, cy: rect.midY)   // heading-up → strzałka w górę
        } else {
            writeCtr(String(localized: "Ustaw cel w karcie Nawigacja (w apce)"), x: rect.midX, y: rect.midY - 8, size: 15, color: GRAY)
            writeCtr(String(localized: "albo wklej link z Apple Maps"), x: rect.midX, y: rect.midY + 14, size: 12, color: DIM)
        }

        // ── Banner turn-by-turn (góra) ──
        if navActive {
            let bw = pw - 12
            let bx = CGRect(x: px + 6, y: py + 6, width: bw, height: 50)
            BG.withAlphaComponent(0.9).setFill()
            UIBezierPath(roundedRect: bx, cornerRadius: 10).fill()
            BLUE.withAlphaComponent(0.6).setStroke()
            let bp = UIBezierPath(roundedRect: bx, cornerRadius: 10); bp.lineWidth = 1.5; bp.stroke()
            writeGlow(fmtDist(navDistanceToNext), x: px + 54, y: py + 31, size: 22, color: WHITE, glow: BLUE.withAlphaComponent(0.5))
            writeClipped(navInstruction, x: px + 104, y: py + 31, width: bw - 108, size: 14, color: WHITE, bold: true)

            // Dolny pasek: pozostały dystans + ETA
            let ey = py + ph - 14
            BG.withAlphaComponent(0.85).setFill()
            UIBezierPath(roundedRect: CGRect(x: px + 6, y: ey - 15, width: bw, height: 28), cornerRadius: 8).fill()
            write(fmtDist(navRemainingDistance), x: px + 14, y: ey, size: 14, color: GREEN, bold: true)
            writeR("≈ \(Int(navRemainingTime / 60)) min", x: px + pw - 14, y: ey, size: 14, color: WHITE, bold: true)
        }

        // ── Mała prędkość (róg) — zastępuje utracony wielki prędkościomierz ──
        let sp = "\(Int(max(0, speedKmh)))"
        let pill = CGRect(x: px + 8, y: py + ph - 42, width: 78, height: 30)
        if !navActive {   // gdy nawigacja aktywna, dolny pasek zajmuje to miejsce
            BG.withAlphaComponent(0.8).setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: 8).fill()
            write(sp, x: px + 14, y: py + ph - 27, size: 20, color: SPEED_DIGIT, bold: true)
            write("km/h", x: px + 14 + CGFloat(sp.count) * 13 + 4, y: py + ph - 22, size: 9, color: GRAY)
        }
    }

    func drawHeaderBlock(in r: CGRect) {
        BG_HDR.setFill()
        UIRectFill(r)
        RED.withAlphaComponent(0.55).setFill()
        UIRectFill(CGRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1))

        let cy = r.midY
        // Monocraft jest ostry tylko w wielokrotnościach 9 pt (piksel czcionki = 1/9 rozmiaru),
        // a deska idzie na wyświetlacz w skali 1:1 — 14 pt dawało nierówne kreski.
        let sz: CGFloat = 18

        // Zbieramy widoczne komórki (każda rysuje się wyśrodkowana na podanym x),
        // a potem rozkładamy je RÓWNOMIERNIE (space-evenly) na całej szerokości —
        // koniec ręcznych x-ów i nierównych odstępów. Kolejność: lewo → prawo.
        // Waga = względna szerokość slotu (1 = zwykła komórka).
        var cells: [(weight: CGFloat, draw: (CGFloat) -> Void)] = []
        func add(weight: CGFloat = 1, _ draw: @escaping (CGFloat) -> Void) {
            cells.append((weight, draw))
        }

        // GPS: satelita zielony + dokładność, gdy jest fix; czerwony i przekreślony, gdy nie ma.
        let gpsFix = gpsAccuracy > 0
        let accStr = gpsFix ? "\(Int(gpsAccuracy))m" : ""
        let accCol = gpsAccuracy < 20 ? GRAY : DIM
        add { cx in
            let tw = accStr.isEmpty ? 0
                : (accStr as NSString).size(withAttributes: [.font: self.mono(sz, bold: true)]).width
            let icon: CGFloat = 18, gap: CGFloat = accStr.isEmpty ? 0 : 6
            let startX = cx - (icon + gap + tw) / 2
            self.drawSatellite(cx: startX + icon / 2, cy: cy,
                               color: gpsFix ? self.GREEN : self.RED, crossed: !gpsFix)
            if !accStr.isEmpty {
                self.write(accStr, x: startX + icon + gap, y: cy, size: sz, color: accCol, bold: true)
            }
        }

        // Źródło przechyłu: czujnik motocykla (CAN) albo telefon. Tylko gdy mostek włączony.
        if let src = leanSource {
            add(weight: 0.75) { cx in self.drawLeanSourceCell(src, cx: cx, cy: cy, size: sz) }
        }

        // REC — sama mrugająca czerwona kropka (napis nie mieści się przy czcionce 18)
        if recordingActive {
            add(weight: 0.3) { cx in
                guard Int(self.nowDate.timeIntervalSince1970 * 2) % 2 == 0 else { return }
                self.RED.setFill()
                UIBezierPath(ovalIn: CGRect(x: cx.rounded() - 5, y: cy.rounded() - 5, width: 10, height: 10)).fill()
            }
        }

        // Średnia prędkość („AVG", bo „Ø" w tej czcionce wygląda jak zero), bez jednostki —
        // przy czcionce 18 „AVG 104 km/h" zajmowało miejsce sąsiadów.
        if avgSpeedKmh >= 1 {
            let s = String(format: "AVG %.0f", avgSpeedKmh)
            add { cx in self.writeCtr(s, x: cx, y: cy, size: sz, color: self.GRAY, bold: true) }
        }

        // Kompas (strzałka + kierunek)
        add { cx in self.drawCompassCell(cx: cx, cy: cy, size: sz) }

        // Zachód słońca
        if !sunsetString.isEmpty {
            let s = "🌅 \(sunsetString)"
            add { cx in self.writeCtr(s, x: cx, y: cy, size: sz, color: self.GRAY, bold: true) }
        }

        // Wysokość
        if altitudeM != 0 {
            let s = String(format: "▲%.0fm", altitudeM)
            add { cx in self.writeCtr(s, x: cx, y: cy, size: sz, color: self.DIM) }
        }

        // Temperatura powietrza: czujnik motocykla, gdy mostek go podaje; inaczej prognoza.
        if let temp = bike?.airC ?? temperatureC {
            let s = String(format: "%d°C", Int(temp.rounded()))
            let c: UIColor = temp < 5 ? BLUE : (temp > 28 ? ORANGE : GRAY)
            add { cx in self.writeCtr(s, x: cx, y: cy, size: sz, color: c, bold: true) }
        }

        // Zegar
        let timeStr = Self.clockFormatter.string(from: nowDate)
        add { cx in self.writeCtr(timeStr, x: cx, y: cy, size: sz, color: self.WHITE, bold: true) }

        // ── Rozłóż równomiernie: sloty proporcjonalne do wag, komórka w środku swojego ──
        let total = max(1, cells.reduce(0) { $0 + $1.weight })
        let margin: CGFloat = 10
        let usable = r.width - margin * 2
        var before: CGFloat = 0
        for cell in cells {
            cell.draw(r.minX + margin + usable * (before + cell.weight / 2) / total)
            before += cell.weight
        }
    }

    /// Komórka „ikona + CAN/PHONE" — skąd bierzemy przechył.
    func drawLeanSourceCell(_ src: LeanSource, cx: CGFloat, cy: CGFloat, size: CGFloat) {
        let bike = src != .phone
        let text = src == .bike ? "CAN" : (src == .simulated ? "SIM" : "PHONE")
        let color = src == .bike ? GREEN : (src == .simulated ? ORANGE : DIM)
        let tw = (text as NSString).size(withAttributes: [.font: mono(size, bold: true)]).width
        let icon = bike ? Self.leanIconBike : Self.leanIconPhone
        let box: CGFloat = 17, gap: CGFloat = 4
        let iw = icon == nil ? 0 : box + gap
        let startX = cx - (iw + tw) / 2
        if let icon {
            // Dopasowanie z zachowaniem proporcji w kwadracie box×box.
            let k = min(box / icon.size.width, box / icon.size.height)
            let w = icon.size.width * k, h = icon.size.height * k
            icon.withTintColor(color, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: startX + (box - w) / 2, y: cy - h / 2, width: w, height: h))
        }
        write(text, x: startX + iw, y: cy, size: size, color: color, bold: true)
    }

    private static let leanIconCfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
    static let leanIconBike  = UIImage(systemName: "motorcycle.fill", withConfiguration: leanIconCfg)
        ?? UIImage(systemName: "scooter", withConfiguration: leanIconCfg)
    static let leanIconPhone = UIImage(systemName: "iphone", withConfiguration: leanIconCfg)

    /// Satelita (korpus, dwa panele, fale sygnału) wpisany w ok. 18×18 px.
    /// `crossed` = brak sygnału: bez fal, z ukośnym przekreśleniem.
    func drawSatellite(cx: CGFloat, cy: CGFloat, color: UIColor, crossed: Bool) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.translateBy(x: cx - 1, y: cy - 1)
        ctx.rotate(by: -.pi / 4)        // panele po skosie, antena w prawy dolny róg
        color.setFill(); color.setStroke()
        UIBezierPath(roundedRect: CGRect(x: -2.5, y: -3.5, width: 5, height: 7), cornerRadius: 1).fill()
        for side: CGFloat in [-1, 1] {
            UIRectFill(CGRect(x: side > 0 ? 4 : -9.5, y: -2.5, width: 5.5, height: 5))     // panel
            UIRectFill(CGRect(x: side > 0 ? 2.5 : -4, y: -0.6, width: 1.5, height: 1.2))   // łącznik
        }
        if !crossed {
            for radius: CGFloat in [3.2, 6] {
                let arc = UIBezierPath(arcCenter: CGPoint(x: 0, y: 3.5), radius: radius,
                                       startAngle: .pi * 0.25, endAngle: .pi * 0.75, clockwise: true)
                arc.lineWidth = 1.4; arc.lineCapStyle = .round; arc.stroke()
            }
        }
        ctx.restoreGState()

        if crossed {
            let slash = UIBezierPath()
            slash.move(to: CGPoint(x: cx - 8, y: cy - 8))
            slash.addLine(to: CGPoint(x: cx + 8, y: cy + 8))
            slash.lineCapStyle = .round
            BG_HDR.setStroke(); slash.lineWidth = 4.5; slash.stroke()   // odcięcie od ikony
            color.setStroke(); slash.lineWidth = 2; slash.stroke()
        }
    }

    /// Komórka „kropka + tekst" wyśrodkowana jako grupa na cx.
    func drawDotText(cx: CGFloat, cy: CGFloat, dot: UIColor, text: String,
                             color: UIColor, size: CGFloat, dotSize: CGFloat = 10) {
        let tw = (text as NSString).size(withAttributes: [.font: mono(size, bold: true)]).width
        let gap: CGFloat = 5
        let startX = cx - (dotSize + gap + tw) / 2
        dot.setFill()
        UIBezierPath(ovalIn: CGRect(x: startX, y: cy - dotSize/2, width: dotSize, height: dotSize)).fill()
        write(text, x: startX + dotSize + gap, y: cy, size: size, color: color, bold: true)
    }

    /// Komórka kompasu (strzałka + „N 045°") wyśrodkowana jako grupa na cx.
    func drawCompassCell(cx: CGFloat, cy: CGFloat, size: CGFloat) {
        guard headingDeg >= 0 else {
            writeCtr("— COMPASS", x: cx, y: cy, size: size, color: DIM); return
        }
        let dirs = ["N","NE","E","SE","S","SW","W","NW"]
        let dir  = dirs[Int((headingDeg + 22.5) / 45.0) % 8]
        let text = "\(dir) \(Int(headingDeg))°"
        let tw = (text as NSString).size(withAttributes: [.font: mono(size, bold: true)]).width
        let arrowW: CGFloat = 20
        let startX = cx - (arrowW + tw) / 2
        drawCompassArrow(x: startX + 10, y: cy, headingDeg: headingDeg, size: 9, color: RED)
        write(text, x: startX + arrowW, y: cy, size: size, color: WHITE, bold: true)
    }

    /// Mała strzałka kompasu rotowana o headingDeg (0=N=góra, 90=E=prawo).
    func drawCompassArrow(x: CGFloat, y: CGFloat, headingDeg: Double,
                                   size: CGFloat, color: UIColor) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.translateBy(x: x, y: y)
        ctx.rotate(by: CGFloat(headingDeg * .pi / 180.0))
        let path = UIBezierPath()
        path.move   (to: CGPoint(x: 0,         y: -size))           // top
        path.addLine(to: CGPoint(x: size * 0.7, y: size * 0.7))     // bottom-right
        path.addLine(to: CGPoint(x: 0,         y: size * 0.35))     // notch
        path.addLine(to: CGPoint(x: -size * 0.7, y: size * 0.7))    // bottom-left
        path.close()
        color.setFill()
        path.fill()
        ctx.restoreGState()
    }

    func drawLeanBlock(in r: CGRect) {
        let px = r.minX, py = r.minY, pw = r.width, ph = r.height
        let cx = px + pw / 2

        BG.setFill()
        UIRectFill(CGRect(x: px, y: py, width: pw, height: ph))
        drawAmbient(in: r)

        writeCtr("LEAN", x: cx, y: py + 13, size: 18, color: DIMMER, bold: true)

        RED_LINE.setStroke()
        let sep = UIBezierPath()
        sep.move(to: CGPoint(x: px + 18, y: py + 24))
        sep.addLine(to: CGPoint(x: px + pw - 18, y: py + 24))
        sep.lineWidth = 0.5; sep.stroke()

        let lean = max(-65.0, min(65.0, leanAngleDeg))   // clamp do ±65° — spójne na preview i TFT
        // Rysunek (łuk, model) zostaje w ±65°, ale LICZBA z czujnika motocykla idzie
        // bez obcinania: po przewróceniu ma pokazać 90°, nie 65°. Telefon po staremu.
        let absL = leanSource == .bike ? abs(leanAngleDeg) : abs(lean)
        let isL  = lean < -1.5
        let isR  = lean >  1.5
        let zone = leanZoneColor(absL)
        let col  = isL ? BLUE : (isR ? RED : GRAY)

        // ── Półkole (mini HUD) nad modelem: strefy + wskaźnik + kreski MAX L/R ──
        let maxDeg: Double = 60
        let pivotY = py + 128
        let R: CGFloat = 74
        func arcPt(_ deg: Double, _ r: CGFloat) -> CGPoint {
            let a = CGFloat(deg) * .pi / 180
            return CGPoint(x: cx + r * sin(a), y: pivotY - r * cos(a))
        }
        func arcStroke(_ from: Double, _ to: Double, _ c: UIColor, _ w: CGFloat, _ r: CGFloat) {
            let path = UIBezierPath()
            var first = true; var d = from
            while d <= to + 0.001 {
                let p = arcPt(d, r)
                if first { path.move(to: p); first = false } else { path.addLine(to: p) }
                d += 2
            }
            c.setStroke(); path.lineWidth = w
            path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
        }
        // Tło łuku + kolorowe strefy (lustrzane L/R)
        arcStroke(-maxDeg, maxDeg, TRACK.withAlphaComponent(0.4), 7, R)
        for (lo, hi) in [(0.0, 25.0), (25.0, 40.0), (40.0, 52.0), (52.0, maxDeg)] {
            let c = leanZoneColor((lo + hi) / 2).withAlphaComponent(0.9)
            arcStroke(lo, hi, c, 5, R); arcStroke(-hi, -lo, c, 5, R)
        }
        // Kreski rekordów MAX (lewa niebieska, prawa czerwona)
        func maxTick(_ deg: Double, _ c: UIColor) {
            guard abs(deg) > 1 else { return }
            let t = UIBezierPath()
            t.move(to: arcPt(deg, R - 7)); t.addLine(to: arcPt(deg, R + 7))
            c.setStroke(); t.lineWidth = 2.5; t.stroke()
        }
        maxTick(-min(maxLeanLeft, maxDeg),  BLUE)
        maxTick( min(maxLeanRight, maxDeg), RED)
        // Małe liczby przy kreskach MAX — konkretna wartość rekordu
        func maxLabel(_ deg: Double, _ val: Double, _ c: UIColor) {
            guard val > 2 else { return }
            let p = arcPt(deg, R + 22)
            writeCtr(String(format: "%.0f°", val), x: p.x, y: p.y, size: 18, color: c, bold: true)
        }
        maxLabel(-min(maxLeanLeft, maxDeg),  maxLeanLeft,  BLUE)
        maxLabel( min(maxLeanRight, maxDeg), maxLeanRight, RED)
        // Wskaźnik bieżącego kąta — kropka strefy z białym rdzeniem
        let tip = arcPt(lean, R)
        zone.setFill()
        UIBezierPath(ovalIn: CGRect(x: tip.x - 5, y: tip.y - 5, width: 10, height: 10)).fill()
        WHITE.setFill()
        UIBezierPath(ovalIn: CGRect(x: tip.x - 2, y: tip.y - 2, width: 4, height: 4)).fill()

        // Liczba w misie łuku
        writeGlow(String(format: "%.0f°", absL),
                  x: cx, y: pivotY - 22, size: 36, color: col,
                  glow: (isL || isR) ? col.withAlphaComponent(0.4) : nil)

        // Model motocykla GSX pochylający się, pod półkolem
        if let ctx = UIGraphicsGetCurrentContext() {
            ctx.saveGState()
            ctx.translateBy(x: cx, y: py + ph - 16)
            ctx.rotate(by: CGFloat(lean * .pi / 180))
            drawBikeRear(zone: zone, height: min(ph - 170, 112))
            ctx.restoreGState()
        }

        if let t = suspTravel { drawSuspensionBars(front: t.front, rear: t.rear, in: r) }
    }

    /// Dwa słupki w prawym dolnym rogu bloku przechyłu: ruch przodu (F) i tyłu (R) zawieszenia
    /// względem położenia w równej jeździe (kreska w połowie). W górę = ugięcie (przód nurkuje
    /// przy hamowaniu, tył przysiada przy przyspieszaniu), w dół = rozciągnięcie. Wartości −1…+1.
    func drawSuspensionBars(front: Double, rear: Double, in r: CGRect) {
        let h = min(64, r.height - 190), w: CGFloat = 8
        guard h >= 30 else { return }
        let bottom = r.maxY - 26, mid = bottom - h / 2
        writeCtr("SUSP", x: r.maxX - 44 + 13, y: bottom - h - 9, size: 9, color: DIMMER, bold: true)
        for (i, item) in [("F", front), ("R", rear)].enumerated() {
            let x = r.maxX - 44 + CGFloat(i) * 18
            let track = CGRect(x: x, y: bottom - h, width: w, height: h)
            TRACK.withAlphaComponent(0.55).setFill()
            UIBezierPath(roundedRect: track, cornerRadius: 3).fill()
            let v = CGFloat(min(1, max(-1, item.1)))
            let len = abs(v) * h / 2
            if len > 1 {
                // Ugięcie pomarańczowe (mocne — czerwone), rozciągnięcie szare.
                let col = v > 0 ? (v > 0.85 ? RED : ORANGE) : GRAY
                col.withAlphaComponent(0.9).setFill()
                UIBezierPath(rect: CGRect(x: x, y: v > 0 ? mid - len : mid, width: w, height: len)).fill()
            }
            WHITE.withAlphaComponent(0.8).setFill()
            UIBezierPath(rect: CGRect(x: x - 2, y: mid - 0.5, width: w + 4, height: 1)).fill()
            writeCtr(item.0, x: x + w / 2, y: bottom + 10, size: 9, color: DIMMER, bold: true)
        }
    }

    func drawSpeedBlock(in r: CGRect) {
        let px = r.minX, py = r.minY, pw = r.width, ph = r.height
        let cx = px + pw / 2

        BG_DARK.setFill()
        UIRectFill(CGRect(x: px, y: py, width: pw, height: ph))
        drawAmbient(in: r)

        // ── Kotwice pionowe (stabilne, niezależne od liczby cyfr) ──
        // Panel: py..py+ph (32..290).  Dolny separator pod cyfrą + 38px na MAX/G-FORCE.
        let sepY        = py + ph - 52              // separator pod blokiem prędkości
        let digitY      = py + (ph - 52) / 2 - 8    // środek cyfry — w środku obszaru NAD separatorem
        let kmhY        = sepY - 18                 // "km/h" — fixed 18px nad separatorem (nie zależy od fsize)
        let bottomLblY  = py + ph - 40
        let bottomValY  = py + ph - 23

        // Radialna poświata — wycentrowana na cyfrze
        if let ctx = UIGraphicsGetCurrentContext() {
            let gc = CGPoint(x: cx, y: digitY)
            let cs = CGColorSpaceCreateDeviceRGB()
            let colors = [RED_GLOW.cgColor,
                          RED_GLOW.withAlphaComponent(0).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1.0]) {
                ctx.saveGState()
                ctx.clip(to: CGRect(x: px, y: py, width: pw, height: ph))
                ctx.drawRadialGradient(grad,
                    startCenter: gc, startRadius: 0,
                    endCenter:   gc, endRadius:   152,
                    options: [])
                ctx.restoreGState()
            }
        }

        // Cyfra prędkości — biel w dark, deep RED w light (zamiast czarnej)
        let spd    = max(0, speedKmh)
        let digits = Int(spd) >= 100 ? 3 : (Int(spd) >= 10 ? 2 : 1)
        let fsize: CGFloat = digits >= 3 ? 118 : 148

        writeGlow("\(Int(spd))",
                  x: cx, y: digitY,
                  size: fsize, color: SPEED_DIGIT,
                  glow: RED.withAlphaComponent(isDarkMode ? 0.55 : 0.45))

        writeCtr("km/h", x: cx, y: kmhY, size: 18, color: GRAY)

        // ── Separator z watermarkiem pośrodku: ─── SpinMyCan @mikomaks_ ─── ──
        let wmAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: GRAY.withAlphaComponent(0.65)   // GRAY=65% white → widoczne po JPEG
        ]
        let wmText = "SpinMyCan @mikomaks_"
        let wmSz   = (wmText as NSString).size(withAttributes: wmAttrs)
        let wmGap:  CGFloat = 8   // odstęp między linią a tekstem
        let wmX    = cx - wmSz.width / 2
        let wmY    = sepY - wmSz.height / 2

        RED_LINE.setStroke()
        // lewa część separatora
        let slL = UIBezierPath()
        slL.move(to: CGPoint(x: px + 22, y: sepY))
        slL.addLine(to: CGPoint(x: wmX - wmGap, y: sepY))
        slL.lineWidth = 0.5; slL.stroke()
        // prawa część separatora
        let slR = UIBezierPath()
        slR.move(to: CGPoint(x: wmX + wmSz.width + wmGap, y: sepY))
        slR.addLine(to: CGPoint(x: px + pw - 22, y: sepY))
        slR.lineWidth = 0.5; slR.stroke()
        // tekst watermarku
        (wmText as NSString).draw(at: CGPoint(x: wmX, y: wmY), withAttributes: wmAttrs)

        // Przebieg z licznika (mostek CAN) — środek wiersza, wtedy MAX i G-FORCE rozsuwają się na boki.
        let odo = bike.flatMap { $0.engineFresh ? $0.odometer : nil }
        let qX  = px + pw * (odo != nil ? 1.0 / 6 : 1.0 / 3)
        if let odo {
            writeCtr("ODO",        x: cx, y: bottomLblY, size: 9,  color: DIMMER, bold: true)
            writeCtr("\(odo) km", x: cx, y: bottomValY, size: 18, color: GRAY,   bold: true)
        }
        writeCtr("MAX",                         x: qX, y: bottomLblY, size: 9,  color: DIMMER, bold: true)
        // MAX value: w light mode lekki red akcent (spójność z cyfrą), w dark szary
        writeCtr("\(Int(maxSpeedKmh)) km/h",    x: qX, y: bottomValY, size: 18,
                 color: isDarkMode ? GRAY : RED_DIM, bold: true)

        let g2X  = px + pw * (odo != nil ? 5.0 / 6 : 2.0 / 3)
        let gCol = gForce > 1.0 ? ORANGE : (gForce > 0.5 ? WHITE : DIM)
        writeCtr("G-FORCE",                              x: g2X, y: bottomLblY, size: 9, color: DIMMER, bold: true)
        writeCtr(String(format: "%.1fg", gForce),        x: g2X, y: bottomValY, size: 18, color: gCol,   bold: true)
        // MAX G — mała wartość pod spodem, spójnie z MAX km/h
        writeCtr(String(format: "MAX %.1fg", maxGforce), x: g2X, y: bottomValY + 14, size: 9, color: DIMMER, bold: false)

        if let b = bike, b.engineFresh { drawEngineOverlay(b, in: r, digitY: digitY) }
    }

    /// Bieg (ramka z lewej strony cyfry prędkości) i obroty jako sama liczba pod nim.
    /// Rysowane tylko, gdy mostek CAN podaje świeże dane z silnika.
    func drawEngineOverlay(_ b: BikeTelemetry, in r: CGRect, digitY: CGFloat) {
        let boxW: CGFloat = 50, boxH: CGFloat = 64
        let box = CGRect(x: r.minX + 20, y: digitY - boxH / 2 - 10, width: boxW, height: boxH)
        let gearCol = b.gear == 0 ? GREEN : WHITE
        let frame = UIBezierPath(roundedRect: box, cornerRadius: 8)
        BG_DARK.withAlphaComponent(0.55).setFill(); frame.fill()
        gearCol.withAlphaComponent(0.85).setStroke(); frame.lineWidth = 1.5; frame.stroke()
        writeInkCtr(b.gear == 0 ? "N" : "\(b.gear)", x: box.midX, y: box.midY, size: 45, color: gearCol, bold: true)

        writeCtr("\(b.rpm)", x: box.midX, y: box.maxY + 14, size: 18, color: GRAY, bold: true)
        writeCtr("RPM", x: box.midX, y: box.maxY + 29, size: 9, color: DIMMER, bold: true)

        // Gaz: szeroki pasek pod cyfrą prędkości, wypełnia się z lewej, procent w środku.
        // Kolor tekstu w rozcieńczeniu: jasny pasek w ciemnym motywie, ciemny w jasnym,
        // a procent (pełny kolor tekstu) zostaje czytelny i na torze, i na wypełnieniu.
        let barW = r.width - 2 * (20 + boxW + 22)
        let bar = CGRect(x: r.midX - barW / 2, y: r.maxY - 52 - 18 - 36, width: barW, height: 18)
        let pct = b.throttlePct
        WHITE.withAlphaComponent(0.10).setFill()
        UIBezierPath(roundedRect: bar, cornerRadius: 5).fill()
        if pct > 0.5, let ctx = UIGraphicsGetCurrentContext() {
            ctx.saveGState()
            UIBezierPath(roundedRect: bar, cornerRadius: 5).addClip()
            WHITE.withAlphaComponent(0.30).setFill()
            // Ścieżka, nie UIRectFill — ten drugi nadpisuje piksele i gubi przezroczystość.
            UIBezierPath(rect: CGRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(pct / 100),
                                      height: bar.height)).fill()
            ctx.restoreGState()
        }
        writeCtr("\(Int(pct.rounded()))%", x: bar.midX, y: bar.midY, size: 18, color: WHITE, bold: true)

        drawBikeStatusColumn(b, in: r, top: box.minY, boxW: boxW, boxH: boxH)
    }

    /// Od tej temperatury płynu liczba przy prędkości robi się czerwona.
    /// 115, nie 105: w korku płyn normalnie dochodzi do ok. 106 °C (wtedy pracuje wentylator),
    /// co widać w logu z jazdy 2026-10-13 — to nie jest jeszcze przegrzanie.
    static let coolantHotC = 115.0

    /// Prawa strona cyfry prędkości, lustrzanie do biegu: tryb jazdy z poziomem trakcji
    /// w ramce, pod nią temperatura płynu. Każda część rysuje się tylko, gdy płytka
    /// (program od wersji 4) podaje świeżą wartość.
    func drawBikeStatusColumn(_ b: BikeTelemetry, in r: CGRect, top: CGFloat, boxW: CGFloat, boxH: CGFloat) {
        let box = CGRect(x: r.maxX - 20 - boxW, y: top, width: boxW, height: boxH)
        if let mode = b.rideMode {
            let frame = UIBezierPath(roundedRect: box, cornerRadius: 8)
            BG_DARK.withAlphaComponent(0.55).setFill(); frame.fill()
            GRAY.withAlphaComponent(0.7).setStroke(); frame.lineWidth = 1.5; frame.stroke()
            // Tryb zawieszenia (ACTIVE DAMPING H/M/S/U) w tym samym kafelku, pod trakcją.
            let damp = b.dampLetter
            writeInkCtr(mode, x: box.midX, y: box.minY + (damp != nil ? 21 : 25), size: 36, color: WHITE, bold: true)
            if let tc = b.traction {
                writeCtr(tc == 0 ? "TC OFF" : "TC \(tc)", x: box.midX, y: box.maxY - (damp != nil ? 21 : 12), size: 9,
                         color: tc == 0 ? ORANGE : GRAY, bold: true)
            }
            if let damp {
                writeCtr("SUS \(damp)", x: box.midX, y: box.maxY - 9, size: 9, color: GRAY, bold: true)
            }
        }
        if let c = b.coolantC {
            let col: UIColor = c >= Self.coolantHotC ? RED : (c < 50 ? BLUE : GRAY)
            writeCtr("\(Int(c.rounded()))°C", x: box.midX, y: box.maxY + 14, size: 18, color: col, bold: true)
            writeCtr("ENGINE", x: box.midX, y: box.maxY + 29, size: 9, color: DIMMER, bold: true)
        }
    }

    func drawNowPlayingBlock(in r: CGRect) {
        guard !npTitle.isEmpty else {
            drawStatsBlock(in: r)
            return
        }

        let px = r.minX, py = r.minY, pw = r.width, ph = r.height
        let cx = px + pw / 2

        BG.setFill()
        UIRectFill(CGRect(x: px, y: py, width: pw, height: ph))
        drawAmbient(in: r)

        // ── Okładka albumu — skaluje się z wysokością panelu (dół = progress bar) ──
        // Budżet pod okładką: tytuł 20 + artysta 20 + bar 14 + czasy 20 + marginesy.
        let artSize: CGFloat = min(pw - 36, ph - 110)
        let artX = px + (pw - artSize) / 2
        let artY = py + 10
        let artRect = CGRect(x: artX, y: artY, width: artSize, height: artSize)
        let artPath = UIBezierPath(roundedRect: artRect, cornerRadius: 10)

        if let img = npArtwork {
            if let ctx = UIGraphicsGetCurrentContext() {
                ctx.saveGState()
                artPath.addClip()
                img.draw(in: artRect)
                ctx.restoreGState()
            }
        } else {
            // Placeholder gdy brak okładki
            TRACK.withAlphaComponent(0.25).setFill()
            artPath.fill()
            writeCtr("♪", x: cx, y: artY + artSize / 2, size: 44, color: DIM)
        }
        // Obramowanie
        RED_LINE.setStroke()
        artPath.lineWidth = 1.0
        artPath.stroke()

        // ── Play/Pause badge (prawy dolny róg okładki) ────────────────────
        let badgeR: CGFloat = 11
        let badgeX = artX + artSize - badgeR - 4
        let badgeY = artY + artSize - badgeR - 4
        BG_DARK.withAlphaComponent(0.80).setFill()
        UIBezierPath(ovalIn: CGRect(x: badgeX - badgeR, y: badgeY - badgeR,
                                    width: badgeR*2, height: badgeR*2)).fill()
        let badge = npIsPlaying ? "▶" : "⏸"
        writeCtr(badge, x: badgeX, y: badgeY, size: 9, color: npIsPlaying ? GREEN : DIM)

        // Blok tekst+progress ZAKOTWICZONY DO DOŁU panelu (nie wisi w środku).
        let panelBottom = py + ph
        let timeY   = panelBottom - 16                 // czasy tuż nad dolną krawędzią
        let barH: CGFloat = 5
        let barY    = timeY - 12
        let artistY = barY - 18
        let titleY  = artistY - 24

        // ── Tytuł ─────────────────────────────────────────────────────────
        let textX  = px + 8
        let textW  = pw - 16
        writeClipped(npTitle,  x: textX, y: titleY,      width: textW, size: 18, color: WHITE, bold: true)

        // ── Artysta ───────────────────────────────────────────────────────
        writeClipped(npArtist, x: textX, y: artistY,     width: textW, size: 18, color: GRAY)

        // ── Progress bar ──────────────────────────────────────────────────
        let barMgn: CGFloat = 8
        let barX  = px + barMgn
        let barW  = pw - barMgn * 2

        // Tło
        TRACK.withAlphaComponent(0.45).setFill()
        UIBezierPath(roundedRect: CGRect(x: barX, y: barY, width: barW, height: barH),
                     cornerRadius: 2.5).fill()

        // Fill
        if npDuration > 0 {
            let progress = CGFloat(min(max(npElapsed / npDuration, 0), 1))
            let fillW = barW * progress
            if fillW > 1 {
                RED.setFill()
                UIBezierPath(roundedRect: CGRect(x: barX, y: barY, width: fillW, height: barH),
                             cornerRadius: 2.5).fill()
                // Kursor
                RED.withAlphaComponent(0.9).setFill()
                let knobX = barX + fillW - 3
                UIBezierPath(ovalIn: CGRect(x: knobX, y: barY - 1.5, width: 7, height: 8)).fill()
            }
        }

        // ── Czasy: elapsed / duration (timeY policzone wyżej, zakotwiczone do dołu) ──
        write (fmtSeconds(npElapsed),  x: barX,       y: timeY, size: 9, color: DIM, bold: true)
        writeR(fmtSeconds(npDuration), x: barX + barW, y: timeY, size: 9, color: DIM, bold: true)
    }

    func drawStatsBlock(in r: CGRect) {
        let px = r.minX, py = r.minY, pw = r.width, ph = r.height
        let cx = px + pw / 2

        BG.setFill()
        UIRectFill(CGRect(x: px, y: py, width: pw, height: ph))
        drawAmbient(in: r)

        let step  = ph / 4.0
        let items: [(String, String, UIColor)] = [
            ("TRIP",    String(format: "%.1f km", tripDistKm),    GRAY),
            ("SESSION", fmtTime(sessionSec),                       GRAY),
            ("ALT",     altitudeM != 0 ? String(format: "%.0f m", altitudeM) : "— m", GRAY),
            ("HDG",     hdgString(),                               headingDeg >= 0 ? WHITE : DIM),
        ]

        for (i, (label, value, col)) in items.enumerated() {
            let bY = py + CGFloat(i) * step + step * 0.18
            writeCtr(label, x: cx, y: bY + 11, size: 9, color: DIMMER, bold: true)
            writeCtr(value, x: cx, y: bY + 32, size: 27, color: col, bold: true)
        }
    }
}
