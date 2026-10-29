// HackerScreen.swift
// Ekran deski „Terminal CAN”: surowe ramki z szyny motocykla na żywo, zielony tekst
// na czarnym, bez ozdobników (deszcz znaków, ACCESS GRANTED itp. usunięte w 1.16.0).
// Wszystko na nim jest prawdziwe: strumień ramek z płytki (ten sam co w logu),
// odczyt sygnałów z SYGNALY.md i tabela kodów błędów z ramki 0x441.
// Czcionka 9 i 18 pt — Monocraft jest ostry tylko w wielokrotnościach 9 (skala 1:1).

import UIKit

extension FrameRenderer {

    private enum Term {
        static let bg     = UIColor(red: 0.00, green: 0.025, blue: 0.00, alpha: 1)
        static let green  = UIColor(red: 0.22, green: 1.00, blue: 0.42, alpha: 1)
        static let dim    = UIColor(red: 0.10, green: 0.50, blue: 0.21, alpha: 1)
        static let bright = UIColor(red: 0.80, green: 1.00, blue: 0.86, alpha: 1)
        static let amber  = UIColor(red: 1.00, green: 0.72, blue: 0.16, alpha: 1)
        static let red    = UIColor(red: 1.00, green: 0.28, blue: 0.28, alpha: 1)
        static let footer = "> mode: LISTEN_ONLY  //  GSX-S1000GX"
    }

    /// Szerokość znaku Monocraft (advance 720/1080 em).
    private func cw(_ size: CGFloat) -> CGFloat { size * 720 / 1080 }

    func paintHackerScreen(_ l: Layout) {
        let W = l.W, H = l.H
        let t = nowDate.timeIntervalSince1970
        Term.bg.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: W, height: H))

        let live = !hackerTable.isEmpty

        // ── Nagłówek: prompt ──
        let up = Int(t) % 86_400
        let fw = bike.map { "fw v\($0.fwVersion)" } ?? "fw ?"
        write("root@gsx-s1000gx:~# ./canbridge -i can0 -b 500000 --listen-only",
              x: 6, y: 8, size: 9, color: Term.green)
        writeR(String(format: "[%@] [UP %02d:%02d:%02d]", fw, up / 3600, (up / 60) % 60, up % 60),
               x: W - 6, y: 8, size: 9, color: Term.dim)
        Term.dim.withAlphaComponent(0.8).setFill()
        UIRectFill(CGRect(x: 0, y: 16, width: W, height: 1))

        // ── Lewa kolumna: candump ──
        let leftW: CGFloat = 520
        paintCandump(x: 6, top: 22, width: leftW, bottom: H - 26, t: t, live: live)
        Term.dim.withAlphaComponent(0.6).setFill()
        UIRectFill(CGRect(x: leftW + 10, y: 20, width: 1, height: H - 46))

        // ── Prawa kolumna: dekodowanie ──
        paintDecode(x: leftW + 20, width: W - leftW - 26, top: 22, live: live, t: t)

        // ── Pasek na dole ──
        Term.dim.withAlphaComponent(0.8).setFill()
        UIRectFill(CGRect(x: 0, y: H - 22, width: W, height: 1))
        write(Term.footer, x: 6, y: H - 11, size: 9, color: Term.amber)
        let fps = bike?.busFps ?? 0
        writeR(live ? "can0 UP  \(fps) fr/s" : "can0 DOWN", x: W - 6, y: H - 11, size: 9,
               color: live ? Term.green : Term.red)
    }

    /// Lista ramek jak z `candump -ta`: najnowsza na dole, zmienione bajty świecą.
    private func paintCandump(x: CGFloat, top: CGFloat, width: CGFloat, bottom: CGFloat, t: Double, live: Bool) {
        let size: CGFloat = 9, lh: CGFloat = 11
        let rows = Int((bottom - top) / lh)
        let font = mono(size)
        guard live else {
            write("can0: waiting for carrier...", x: x, y: top + 6, size: size, color: Term.amber)
            write("> podłącz płytkę CAN i włącz zapłon", x: x, y: top + 6 + lh, size: size, color: Term.dim)
            return
        }
        let lines = hackerLines.suffix(rows)
        for (i, ln) in lines.enumerated() {
            let s = NSMutableAttributedString()
            func add(_ text: String, _ c: UIColor, _ bg: UIColor? = nil) {
                var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: c]
                if let bg { a[.backgroundColor] = bg }
                s.append(NSAttributedString(string: text, attributes: a))
            }
            add(String(format: "(%09.3f)  can0  ", ln.t), Term.dim)
            add(String(format: "%03X", ln.id), Term.amber)
            add(String(format: "   [%d]  ", ln.data.count), Term.dim)
            for (j, b) in ln.data.enumerated() {
                let hot = ln.changed & (1 << j) != 0
                add(String(format: "%02X", b), hot ? Term.bright : Term.green,
                    hot ? Term.green.withAlphaComponent(0.22) : nil)
                add(" ", Term.green)
            }
            // kolumna ASCII jak w `candump -a`
            let ascii = ln.data.map { (0x20...0x7E).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            add("  '" + ascii + "'", Term.dim)
            s.draw(at: CGPoint(x: x, y: (top + CGFloat(i) * lh).rounded()))
        }
    }

    /// Prawa kolumna: odczyt znanych sygnałów, „wykresy” z ASCII, tabela kodów błędów.
    private func paintDecode(x: CGFloat, width: CGFloat, top: CGFloat, live: Bool, t: Double) {
        var y = top + 6
        write("// LIVE DECODE", x: x, y: y, size: 9, color: Term.amber)
        let ecuOk = live && (bike?.engineFresh ?? false)
        writeR(ecuOk ? "ECU 0x7E8 ONLINE" : "ECU ----", x: x + width, y: y, size: 9,
               color: ecuOk ? Term.green : Term.red)
        y += 20
        guard live, let b = bike else {
            write("NO SIGNAL", x: x, y: y + 4, size: 18, color: Term.red)
            return
        }
        func bar(_ frac: Double, _ n: Int) -> String {
            let k = max(0, min(n, Int((frac * Double(n)).rounded())))
            return "[" + String(repeating: "#", count: k) + String(repeating: ".", count: n - k) + "]"
        }
        let cols = Int(width / cw(9)) - 8

        // Obroty i bieg
        let gear = b.gear == 0 ? "N" : "\(b.gear)"
        write(String(format: "RPM %5d", b.rpm), x: x, y: y, size: 18, color: Term.bright)
        writeR("GEAR \(gear)", x: x + width, y: y, size: 18, color: b.gear == 0 ? Term.green : Term.bright)
        y += 16
        write(bar(Double(b.rpm) / 11_000, cols) + String(format: " %3.0f%%", Double(b.rpm) / 110),
              x: x, y: y, size: 9, color: b.rpm > 9_000 ? Term.red : Term.green)
        y += 16

        // Przechył: wskaźnik ASCII z kropką
        let lean = leanAngleDeg
        let half = cols / 2
        let pos = max(-half, min(half, Int((lean / 60 * Double(half)).rounded())))
        var gauge = Array(repeating: Character("."), count: half * 2 + 1)
        gauge[half] = "|"
        gauge[half + pos] = "O"
        write(String(format: "LEAN %@ %4.1f°", lean < -1 ? "L" : (lean > 1 ? "R" : " "), abs(lean)),
              x: x, y: y, size: 18, color: Term.bright)
        writeR(String(format: "TPS %3.0f%%", b.throttlePct), x: x + width, y: y, size: 18, color: Term.green)
        y += 16
        write("<" + String(gauge) + ">", x: x, y: y, size: 9, color: abs(lean) > 40 ? Term.amber : Term.green)
        y += 16

        // Prędkość i temperatury
        write(String(format: "SPD %03.0f", speedKmh), x: x, y: y, size: 18, color: Term.bright)
        let h2o = b.coolantC.map { String(format: "H2O %3.0f°", $0) } ?? "H2O ---"
        writeR(h2o, x: x + width, y: y, size: 18, color: (b.coolantC ?? 0) >= 115 ? Term.red : Term.green)
        y += 20

        // Surowe smaczki: IMU, zawieszenie, kody błędów
        func word(_ d: [UInt8]?, _ i: Int) -> Int? {
            guard let d, d.count > i + 1 else { return nil }
            return Int(d[i]) << 8 | Int(d[i + 1])
        }
        if let ax = word(hackerTable[0x181], 0), let ay = word(hackerTable[0x181], 2), let az = word(hackerTable[0x181], 4) {
            write(String(format: "IMU 181  %+.2f %+.2f %+.2fg", Double(ax - 32768) / 5000,
                         Double(ay - 32768) / 5000, Double(az - 32768) / 5000),
                  x: x, y: y, size: 9, color: Term.green)
            y += 12
        }
        if let f = word(hackerTable[0x17D], 0), let r = word(hackerTable[0x17D], 2) {
            write(String(format: "SUSP 17D F %4d  R %4d", f, r), x: x, y: y, size: 9, color: Term.green)
            y += 12
        }
        write(String(format: "BUS %4d fr/s   IDs %d", b.busFps, hackerTable.count), x: x, y: y, size: 9, color: Term.green)
        y += 12
        // 0x441: b3 = liczba kodów, b4 = pozycja, b1b2 = kod (SAE J2012) — patrz SYGNALY.md
        if let d = hackerTable[0x441], d.count >= 5, d[3] > 0 {
            let blink = Int(t * 3) % 2 == 0
            write("DTC x\(d[3])  \(Obd.dtc(d[1], d[2]))  !!", x: x, y: y, size: 9, color: blink ? Term.red : Term.amber)
        } else {
            write("DTC 0x441: CLEAN", x: x, y: y, size: 9, color: Term.green)
        }
        y += 18

        // WATCH: kluczowe ramki z tabeli (ostatnia treść)
        write("// WATCH", x: x, y: y, size: 9, color: Term.amber)
        y += 12
        for (id, label) in [(UInt16(0x1A1), "ENG"), (0x1A5, "LEAN"), (0x19D, "WHL"), (0x331, "MODE")] {
            guard let d = hackerTable[id], y < 300 else { continue }
            let bytes = d.map { String(format: "%02X", $0) }.joined(separator: " ")
            write(String(format: "%03X %-4@ %@", id, label, bytes), x: x, y: y, size: 9, color: Term.dim)
            y += 12
        }
    }
}
