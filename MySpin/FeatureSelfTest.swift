// FeatureSelfTest.swift
// Autotest odcinków i pogody na trasie (env FEATURE_TEST=1, tylko DEBUG).
//
// Obu rzeczy nie da się sprawdzić zza biurka „na oko": odcinki wymagają jazdy,
// a deszcz na trasie — deszczu. Dlatego logika jest napisana tak, żeby dało się
// ją nakarmić spreparowanymi danymi (czas i pozycja wchodzą parametrem), a ten
// plik odgrywa przejazdy i prognozy, po czym zapisuje wynik do
// Documents/featuretest/result.txt. Na końcu jedno PRAWDZIWE zapytanie do
// Open-Meteo (net.txt) — sprawdza, że format odpowiedzi nadal się zgadza.

#if DEBUG
import Foundation
import CoreLocation
import Combine
import SwiftUI

enum FeatureSelfTest {

    private static var lines: [String] = []
    private static var failed = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failed += 1 }
        lines.append("\(ok ? "OK  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    }

    static func run() {
        lines = []; failed = 0
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("featuretest")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        testSegments(tmp: dir.appendingPathComponent("segments_test.json"))
        testWeatherLogic()
        testBikeLink(tmp: dir)
        testThemeCombo()
        testVideoFrames()
        testRouteCloud()
        testObd()
        testAppList()
        testSkippedTracks()
        testSnake()
        testNotifications()
        testOverlay()

        lines.append("")
        lines.append(failed == 0 ? "WYNIK: wszystko OK" : "WYNIK: \(failed) błędów")
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("result.txt"),
                                                 atomically: true, encoding: .utf8)
        testWeatherNetwork(out: dir.appendingPathComponent("net.txt"))
    }

    /// Dane pokazowe do obejrzenia ekranu „Odcinki" w symulatorze (env SEGMENTS_UI=1).
    static func seed(_ m: SegmentManager) {
        var t = Date().addingTimeInterval(-3 * 86_400)
        m.startRecording()
        t = ride(m, from: 20, to: 2000, speed: 20, start: t, lean: 34)
        m.finishRecording(name: "Przełęcz Salmopolska")
        t = ride(m, from: -150, to: 2150, speed: 23, start: t.addingTimeInterval(86_400), phase: 4, lean: 41)
        _ = ride(m, from: -150, to: 2150, speed: 21, start: t.addingTimeInterval(86_400), phase: 9, lean: 38)
    }

    // MARK: — Odcinki

    /// Droga testowa: łagodnie wijąca się, opisana dystansem (ujemny = dojazd przed startem).
    private static func road(_ d: Double) -> CLLocationCoordinate2D {
        // całkujemy kurs co 1 m — wystarczająco dokładnie na test
        var x = 0.0, y = 0.0
        let n = Int(abs(d).rounded()), step = d >= 0 ? 1.0 : -1.0
        var s = 0.0
        for _ in 0..<n {
            let h = (60 + 40 * sin(s / 300)) * .pi / 180
            x += step * sin(h); y += step * cos(h); s += step
        }
        return CLLocationCoordinate2D(latitude: 50.0 + y / 110_540,
                                      longitude: 20.0 + x / (111_320 * cos(50.0 * .pi / 180)))
    }

    /// Przejazd ze stałą prędkością od `from` do `to` (metry drogi), próbki co 1 s.
    /// `phase` przesuwa próbki względem bramek, żeby przecięcia wypadały MIĘDZY próbkami.
    private static func ride(_ m: SegmentManager, from: Double, to: Double, speed: Double,
                             start: Date, phase: Double = 0, lean: Double = 20,
                             detour: ((Double) -> CLLocationCoordinate2D?)? = nil) -> Date {
        var t = start
        var d = from + phase
        let dir = to >= from ? 1.0 : -1.0
        while (dir > 0 && d <= to) || (dir < 0 && d >= to) {
            let c = detour?(d) ?? road(d)
            m.ingest(coord: c, speedKmh: speed * 3.6, leanDeg: lean * sin(d / 120),
                     accuracy: 5, time: t)
            d += dir * speed; t = t.addingTimeInterval(1)
        }
        return t
    }

    private static func testSegments(tmp: URL) {
        lines.append("── ODCINKI ──")
        let m = SegmentManager(storeURL: tmp)
        var t = Date(timeIntervalSince1970: 1_760_000_000)

        // 1. Nagranie: 5 s postoju, 2 km jazdy 72 km/h, 4 s postoju
        m.startRecording()
        for _ in 0..<5 { m.ingest(coord: road(0), speedKmh: 0, leanDeg: 0, accuracy: 5, time: t); t += 1 }
        t = ride(m, from: 20, to: 2000, speed: 20, start: t)
        for _ in 0..<4 { m.ingest(coord: road(2000), speedKmh: 0, leanDeg: 0, accuracy: 5, time: t); t += 1 }
        let err = m.finishRecording(name: "Test")
        check("nagranie zapisane", err == nil && m.segments.count == 1, err ?? "")
        guard let seg0 = m.segments.first else { return }
        let len = seg0.lengthM
        check("postój przycięty, długość ≈ 1980 m", abs(len - 1980) < 15, String(format: "%.1f m", len))
        check("czas nagrania ≈ 99 s", abs((seg0.best?.timeSec ?? 0) - 99) < 1.0,
              String(format: "%.2f s", seg0.best?.timeSec ?? 0))

        // 2. Za krótki odcinek odrzucony
        m.startRecording()
        t = ride(m, from: 0, to: 80, speed: 20, start: t.addingTimeInterval(60))
        check("za krótki odcinek odrzucony", m.finishRecording(name: "x") != nil && m.segments.count == 1)

        // 3. Szybszy przejazd (90 km/h) — próbki przesunięte względem bramek
        t = t.addingTimeInterval(600)
        var sawNegative = false, sawActive = false
        let obs = m.$liveText.sink { txt in
            if txt.contains("⏱") { sawActive = true; if txt.contains("−") { sawNegative = true } }
        }
        t = ride(m, from: -150, to: 2150, speed: 25, start: t, phase: 7.3)
        obs.cancel()
        let runs1 = m.segments[0].runs
        // Prawda fizyczna: bramki stoją na 20. i 2000. metrze drogi → 1980 m / prędkość.
        // (`len` jest o ~0.3% dłuższe, bo CLLocation liczy po elipsoidzie, a droga
        // testowa jest zbudowana na płaskim przeliczniku — do czasu się nie nadaje.)
        let expect1 = 1980.0 / 25
        check("przejazd wykryty i zapisany", runs1.count == 2, "przejazdów: \(runs1.count)")
        check("na żywo pokazywał przewagę (−)", sawActive && sawNegative)
        check("czas szybszego ≈ \(String(format: "%.1f", expect1)) s (interpolacja bramek)",
              abs((runs1.first?.timeSec ?? 0) - expect1) < 0.1,
              String(format: "zmierzono %.2f s", runs1.first?.timeSec ?? 0))
        check("nowy rekord przejął profil odniesienia",
              abs((m.segments[0].best?.timeSec ?? 0) - (runs1.first?.timeSec ?? -1)) < 0.001
              && abs((m.segments[0].points.last?.t ?? 0) - (runs1.first?.timeSec ?? -1)) < 0.001)
        check("wynik z napisem REKORD", m.chipSnapshot()?.text.contains("REKORD") == true,
              m.chipSnapshot()?.text ?? "brak")

        // 4. Wolniejszy przejazd (58 km/h) — nie jest rekordem, delta dodatnia
        t = t.addingTimeInterval(600)
        var sawPositive = false
        let obs2 = m.$liveText.sink { if $0.contains("⏱") && $0.contains("+") { sawPositive = true } }
        t = ride(m, from: -150, to: 2150, speed: 16, start: t, phase: 3.1)
        obs2.cancel()
        let runs2 = m.segments[0].runs
        let expect2 = 1980.0 / 16
        check("wolniejszy przejazd zapisany, rekord bez zmian",
              runs2.count == 3 && abs((m.segments[0].best?.timeSec ?? 0) - (runs1.first?.timeSec ?? -1)) < 0.001)
        check("na żywo pokazywał stratę (+)", sawPositive)
        check("czas wolniejszego ≈ \(String(format: "%.1f", expect2)) s",
              abs((runs2.first?.timeSec ?? 0) - expect2) < 0.1,
              String(format: "zmierzono %.2f s", runs2.first?.timeSec ?? 0))

        // 5. Przejazd w PRZECIWNĄ stronę nie może się załapać
        t = t.addingTimeInterval(600)
        t = ride(m, from: 2150, to: -150, speed: 22, start: t)
        check("jazda pod prąd odcinka nie liczy się", m.segments[0].runs.count == 3 && !m.liveActive)

        // 6. Zjazd z odcinka w połowie → przerwany, bez zapisu
        t = t.addingTimeInterval(600)
        t = ride(m, from: -150, to: 2150, speed: 22, start: t, detour: { d in
            guard d > 700 else { return nil }
            let base = road(700)                       // odbijamy prostopadle w bok
            return CLLocationCoordinate2D(latitude: base.latitude + (d - 700) / 110_540,
                                          longitude: base.longitude - (d - 700) / 71_000)
        })
        check("zjazd z trasy przerywa odcinek bez zapisu", m.segments[0].runs.count == 3 && !m.liveActive)

        // 7. Trwałość: nowy menedżer czyta to samo z pliku
        let again = SegmentManager(storeURL: tmp)
        check("zapis na dysk i odczyt", again.segments.count == 1 && again.segments[0].runs.count == 3)

        // 8. Po wczytaniu z dysku bramki nadal działają
        t = t.addingTimeInterval(600)
        _ = ride(again, from: -150, to: 2150, speed: 24, start: t, phase: 1.9)
        check("po restarcie apki przejazd dalej się liczy", again.segments[0].runs.count == 4)
        check("meta nie odpłynęła po rekordach (czas ≈ 82.5 s)",
              abs((again.segments[0].runs.first?.timeSec ?? 0) - 1980.0 / 24) < 0.1,
              String(format: "zmierzono %.2f s", again.segments[0].runs.first?.timeSec ?? 0))
    }

    // MARK: — Pogoda: logika na spreparowanej prognozie

    private static func testWeatherLogic() {
        lines.append("")
        lines.append("── POGODA NA TRASIE ──")
        let now = Date(timeIntervalSince1970: 1_760_000_000)     // początek kwadransu? nieistotne
        let t0 = floor(now.timeIntervalSince1970 / 900) * 900
        let times = (0..<24).map { t0 + Double($0) * 900 }
        func pts(_ km: [Double]) -> [RoutePoint] {
            km.map { RoutePoint(coord: CLLocationCoordinate2D(latitude: 50, longitude: 20), distM: $0 * 1000) }
        }
        func dry() -> [Double] { Array(repeating: 0, count: 24) }
        func build(_ p: [RoutePoint], _ s: [[Double]], route: Bool = true, remaining: Double = 60_000) -> WeatherAhead {
            WeatherAhead.build(points: p, series: s, times: times, now: now, speedMS: 20,
                               onRoute: route, navRemaining: remaining, reachesDestination: true,
                               windKmh: 10, gustKmh: 15, windFromDeg: 0)
        }
        func text(_ a: WeatherAhead, remaining: Double = 60_000, heading: Double = -1) -> String {
            a.chips(now: now, navRemaining: remaining, headingDeg: heading).map { $0.text }.joined(separator: " | ")
        }

        // Punkty co 20 km przy 72 km/h → dojazd po 0 / 16.7 / 33.3 / 50 min → kwadranse 0,1,2,3
        let p = pts([0, 20, 40, 60])

        // 1. Deszcz na 40. km dokładnie wtedy, gdy tam będziemy
        var s = [dry(), dry(), dry(), dry()]; s[2][slot(now, t0, 2000)] = 0.5
        let a1 = build(p, s)
        check("deszcz w miejscu i czasie dojazdu", a1.rainDistM == 40_000 && !a1.rainingNow, text(a1))

        // 2. Pada tam TERAZ, ale zanim dojedziemy — przestanie → sucho
        s = [dry(), dry(), dry(), dry()]; s[2][0] = 2.0
        let a2 = build(p, s)
        check("deszcz, który minie przed dojazdem, nie straszy", a2.rainAt == nil, text(a2))
        check("sucho do celu", text(a2) == "sucho do celu", text(a2))

        // 3. Kilometry maleją w trakcie jazdy (bez nowego zapytania)
        let t3 = text(a1, remaining: 45_000)     // przejechane 15 km
        check("dystans do deszczu maleje na żywo: 40 → 25 km", t3.contains("25 km"), t3)

        // 4. Pada teraz, sucho od 20. km
        s = [dry(), dry(), dry(), dry()]; s[0][0] = 0.3
        let a4 = build(p, s)
        check("pada teraz + gdzie przestanie", a4.rainingNow && a4.dryDistM == 20_000, text(a4))

        // 5. Bez nawigacji: deszcz w tym miejscu za 3 kwadranse
        var one = dry(); let k0 = slot(now, t0, 0); one[k0 + 3] = 1.5
        let a5 = build(pts([0]), [one], route: false)
        let m5 = a5.rainAt.map { Int($0.timeIntervalSince(now) / 60) } ?? -1
        check("bez trasy: deszcz tutaj za ~45 min, ulewa", a5.rainAt != nil && (30...45).contains(m5)
              && text(a5).contains("ulewa"), text(a5))

        // 6. Bez nawigacji i bez deszczu
        let a6 = build(pts([0]), [dry()], route: false)
        check("bez trasy: sucho przez kilka godzin", text(a6).hasPrefix("sucho przez"), text(a6))

        // 7. Wiatr boczny: poryw 50 km/h z kierunku 90° przy kursie 0° → pełny bok z prawej
        var a7 = a6; a7.gustKmh = 50; a7.windFromDeg = 90
        let t7 = text(a7, heading: 0)
        check("wiatr boczny z prawej", t7.contains("💨 50 km/h z prawej"), t7)
        // ten sam wiatr w plecy/twarz → bez ostrzeżenia
        let t8 = text(a7, heading: 90)
        check("wiatr w twarz nie jest boczny", !t8.contains("💨"), t8)
        var a9 = a7; a9.windFromDeg = 270
        check("wiatr boczny z lewej", text(a9, heading: 0).contains("z lewej"), text(a9, heading: 0))

        // 8. Zły rozmiar danych nie wywraca
        let a10 = WeatherAhead.build(points: p, series: [dry()], times: times, now: now, speedMS: 20,
                                     onRoute: true, navRemaining: 0, reachesDestination: false,
                                     windKmh: 0, gustKmh: 0, windFromDeg: 0)
        check("niespójna odpowiedź → brak pigułek zamiast błędu", text(a10).isEmpty)
    }

    private static func slot(_ now: Date, _ t0: Double, _ etaSec: Double) -> Int {
        Int(floor((now.timeIntervalSince1970 + etaSec - t0) / 900))
    }

    // MARK: — Mostek CAN: pakiety w formacie firmware + plik logu

    /// Dekodowanie kodów błędów (te same bajty co w logu z 2026-10-25, ramka 0x441).
    private static func testNotifications() {
        func le(_ uid: UInt32) -> [UInt8] { [UInt8(uid & 0xFF), UInt8((uid >> 8) & 0xFF), UInt8((uid >> 16) & 0xFF), UInt8(uid >> 24)] }
        func source(_ event: UInt8, flags: UInt8 = 0, category: UInt8 = 4, uid: UInt32) -> [UInt8] { [event, flags, category, 1] + le(uid) }
        func attr(_ id: UInt8, _ text: String) -> [UInt8] { let b = Array(text.utf8); return [id, UInt8(b.count & 0xFF), UInt8(b.count >> 8)] + b }
        func answer(_ uid: UInt32, app: String, title: String, sub: String = "", msg: String) -> [UInt8] {
            [0] + le(uid) + attr(0, app) + attr(1, title) + attr(2, sub) + attr(3, msg)
        }
        func posts(_ o: [AncsClient.Output]) -> [DashNotification] { o.compactMap { if case .post(let n) = $0 { return n }; return nil } }
        func writes(_ o: [AncsClient.Output]) -> [[UInt8]] { o.compactMap { if case .write(let w) = $0 { return w }; return nil } }

        var c = AncsClient()
        var o = c.source(source(0, uid: 7), now: 0)
        check("ancs: nowe powiadomienie → pytanie o szczegóły", writes(o) == [AncsClient.attributesCommand(7)] && posts(o).isEmpty)
        check("ancs: komenda = aplikacja, tytuł, podtytuł, treść", AncsClient.attributesCommand(0x01020304)
              == [0, 4, 3, 2, 1, 0, 1, 64, 0, 2, 64, 0, 3, 0x90, 0x01])
        let full = answer(7, app: "com.apple.MobileSMS", title: "Kasia", msg: "Będę za 10 minut")
        check("ancs: połowa odpowiedzi to jeszcze nic", c.data(Array(full.prefix(20)), now: 0.1).isEmpty)
        o = c.data(Array(full.dropFirst(20)), now: 0.2)
        check("ancs: odpowiedź w kawałkach złożona", posts(o).first?.title == "Kasia" && posts(o).first?.message == "Będę za 10 minut"
              && posts(o).first?.appName == AncsClient.builtInName("com.apple.MobileSMS") && posts(o).first?.category == 4)

        // Unknown app: asks for its name, remembers it for the next time.
        o = c.source(source(0, uid: 8), now: 1)
        o = c.data(answer(8, app: "net.whatsapp.WhatsApp", title: "Tomek", msg: "Jedziemy?"), now: 1.1)
        check("ancs: nieznana aplikacja → pytanie o nazwę", writes(o) == [[1] + Array("net.whatsapp.WhatsApp".utf8) + [0, 0]] && posts(o).isEmpty)
        o = c.data([1] + Array("net.whatsapp.WhatsApp".utf8) + [0] + attr(0, "WhatsApp"), now: 1.2)
        check("ancs: nazwa aplikacji z telefonu", posts(o).first?.appName == "WhatsApp" && posts(o).first?.title == "Tomek")
        o = c.source(source(0, uid: 9), now: 2)
        o = c.data(answer(9, app: "net.whatsapp.WhatsApp", title: "Tomek", msg: "Halo"), now: 2.1)
        check("ancs: nazwa zapamiętana — bez drugiego pytania", posts(o).first?.appName == "WhatsApp" && writes(o).isEmpty)

        // One question at a time; a removed notification is not shown.
        o = c.source(source(0, uid: 10), now: 3)
        let second = c.source(source(0, uid: 11), now: 3)
        check("ancs: jedno pytanie naraz", writes(o).count == 1 && writes(second).isEmpty)
        let gone = c.source(source(2, uid: 10), now: 3.05)
        check("ancs: usunięcie przekazane dalej", gone == [.remove(10)])
        o = c.data(answer(10, app: "com.apple.MobileSMS", title: "X", msg: "Y"), now: 3.1)
        check("ancs: usunięte w trakcie nie trafia na deskę, kolejka idzie dalej", posts(o).isEmpty && writes(o) == [AncsClient.attributesCommand(11)])
        check("ancs: przed czasem nic", c.tick(now: 5).isEmpty)
        o = c.tick(now: 3.1 + AncsClient.timeout + 0.1)
        check("ancs: brak odpowiedzi nie blokuje", posts(o).isEmpty && writes(o).isEmpty)
        o = c.source(source(0, uid: 12), now: 20)
        check("ancs: po przerwie działa dalej", writes(o) == [AncsClient.attributesCommand(12)])
        o = c.data(answer(12, app: "com.example.Unknown", title: "A", msg: "B"), now: 20.1)
        o = c.tick(now: 20.1 + AncsClient.timeout + 0.1)
        check("ancs: brak nazwy aplikacji → nazwa z identyfikatora", posts(o).first?.appName == "Unknown" && posts(o).first?.message == "B")

        // What is not news for the rider
        c = AncsClient()
        check("ancs: ciche pominięte", c.source(source(0, flags: 0x01, uid: 20), now: 30).isEmpty)
        check("ancs: zastane przy połączeniu pominięte", c.source(source(0, flags: 0x04, uid: 21), now: 30).isEmpty)
        check("ancs: mail pominięty przy „tylko wiadomości”", c.source(source(0, category: 6, uid: 22), now: 30).isEmpty)
        check("ancs: połączenie przechodzi", writes(c.source(source(0, category: 1, uid: 23), now: 30)).count == 1)
        c = AncsClient(); c.messagesOnly = false
        check("ancs: mail przechodzi przy wszystkich", writes(c.source(source(0, category: 6, uid: 24), now: 30)).count == 1)
        check("ancs: za krótki pakiet", c.source([0, 0, 4], now: 30).isEmpty)
        check("ancs: dane bez pytania wyrzucone", c.data([9, 9, 9], now: 31).isEmpty)
        check("ancs: stan płytki", NotifLinkState(board: 3, reason: 0) == .ready && NotifLinkState(board: 4, reason: 2) == .failed(2)
              && NotifLinkState.failed(2).isProblem && !NotifLinkState.ready.isProblem)
    }

    private static func testOverlay() {
        let ok = DashOverlay.keyOK, left = DashOverlay.keyLeft, right = DashOverlay.keyRight, up = DashOverlay.keyUp
        var muted = false
        func make() -> DashOverlay { let o = DashOverlay(); o.isMuted = { muted }; return o }
        func note(_ uid: UInt32, _ title: String = "Kasia", _ msg: String = "Hej", category: UInt8 = 4) -> DashNotification {
            DashNotification(uid: uid, category: category, appId: "sms", appName: "Wiadomości", title: title, message: msg)
        }

        var o = make()
        check("deska: pusto na starcie, klawisze idą do ekranu", o.snapshot(at: 0).isEmpty && o.key(ok, itemCount: 5, at: 0) == .pass)
        o.post(note(1), at: 10)
        check("deska: baner wjeżdża od góry", o.snapshot(at: 10).banner?.slide == 0 && (o.snapshot(at: 10.1).banner?.slide ?? 0) > 0
              && o.snapshot(at: 10.5).banner?.slide == 1 && o.snapshot(at: 10.5).banner?.expand == 0)
        check("deska: inne klawisze nie są zabierane", o.key(right, itemCount: 5, at: 11) == .pass && o.key(up, itemCount: 5, at: 11) == .pass)
        check("deska: OK rozwija", o.key(ok, itemCount: 5, at: 12) == .consumed && o.snapshot(at: 12.5).banner?.expand == 1)
        check("deska: rozwinięte zostaje dłużej", o.snapshot(at: 12 + DashOverlay.compactTime + 2).banner != nil)
        check("deska: OK zwija", o.key(ok, itemCount: 5, at: 20) == .consumed && o.snapshot(at: 20.5).banner?.expand == 0)
        check("deska: ◀ zamyka", o.key(left, itemCount: 5, at: 21) == .consumed && (o.snapshot(at: 21.1).banner?.slide ?? 1) < 1
              && o.snapshot(at: 21.3).isEmpty)
        check("deska: po zamknięciu ◀ wraca do ekranu", o.key(left, itemCount: 5, at: 22) == .pass)

        o = make()
        o.post(note(1), at: 0)
        check("deska: nietknięty baner znika sam", o.snapshot(at: DashOverlay.compactTime - 0.5).banner != nil
              && o.snapshot(at: DashOverlay.compactTime + DashOverlay.slideOut + 0.1).isEmpty)
        o.post(note(2, "Kasia", "Pierwsza"), at: 100)
        o.post(note(3, "Kasia", "Druga"), at: 101)
        o.post(note(4, "Tomek", "Inna"), at: 102)
        var b = o.snapshot(at: 103).banner
        check("deska: najnowsze na wierzchu, reszta policzona", b?.notification.title == "Tomek" && b?.more == 2 && b?.messages == ["Inna"])
        o.remove(uid: 4, at: 103)
        b = o.snapshot(at: 103.1).banner
        check("deska: przeczytane na telefonie znika, wiadomości od jednej osoby razem", b?.notification.title == "Kasia"
              && b?.messages == ["Pierwsza", "Druga"] && b?.more == 0)
        o.post(note(3, "Kasia", "Druga (zmieniona)"), at: 104)
        check("deska: zmienione powiadomienie podmienia treść", o.snapshot(at: 104.1).banner?.messages == ["Pierwsza", "Druga (zmieniona)"])
        o.remove(uid: 2, at: 105); o.remove(uid: 3, at: 105)
        check("deska: ostatnie usunięte → baner odjeżdża", o.snapshot(at: 105 + DashOverlay.slideOut + 0.1).isEmpty)

        o = make()
        o.post(note(9, "Marek", "", category: 1), at: 0)
        check("deska: połączenie zostaje dłużej niż wiadomość", o.snapshot(at: DashOverlay.compactTime + 5).banner != nil
              && o.snapshot(at: DashOverlay.callTime + 1).isEmpty)
        muted = true
        o.post(note(10), at: 200)
        check("deska: wyciszone nie pokazuje", o.snapshot(at: 200.5).isEmpty)
        muted = false

        // Incoming call: OK answers, ◀ rejects — only when the phone offers it
        var call = note(30, "Marek", "", category: 1); call.canAccept = true; call.canDecline = true
        o = make(); o.post(call, at: 0)
        check("połączenie: OK odbiera i baner znika", o.key(ok, itemCount: 5, at: 1) == .call(30, accept: true)
              && o.snapshot(at: 1 + DashOverlay.slideOut + 0.1).isEmpty)
        o = make(); o.post(call, at: 0)
        check("połączenie: ◀ odrzuca", o.key(left, itemCount: 5, at: 1) == .call(30, accept: false))
        call.canAccept = false; call.canDecline = false
        o = make(); o.post(call, at: 0)
        check("połączenie: bez akcji z telefonu ◀ tylko zamyka baner", o.key(left, itemCount: 5, at: 1) == .consumed
              && o.key(ok, itemCount: 5, at: 5) == .pass)
        o = make(); o.post(note(31), at: 0)
        check("połączenie: wiadomość nie daje akcji połączenia", o.key(ok, itemCount: 5, at: 1) == .consumed)
        check("połączenie: komendy odbierz / odrzuć", AncsClient.actionCommand(0x01020304, accept: true) == [2, 4, 3, 2, 1, 0]
              && AncsClient.actionCommand(7, accept: false) == [2, 7, 0, 0, 0, 1])
        var ac = AncsClient()
        _ = ac.source([0, 0x18, 1, 1, 40, 0, 0, 0], now: 0)
        let callPost = ac.data([0, 40, 0, 0, 0, 0, 21, 0] + Array("com.apple.mobilephone".utf8) + [1, 5, 0] + Array("Marek".utf8) + [2, 0, 0, 3, 0, 0], now: 0.1)
        check("połączenie: akcje z flag powiadomienia", callPost.contains { if case .post(let n) = $0 { return n.isCall && n.canAccept && n.canDecline && n.title == "Marek" }; return false })

        // Quick menu
        o = make()
        o.openMenu(at: 0)
        check("menu: otwarte na pierwszej pozycji", o.menuIsOpen && o.snapshot(at: 0.5).menu == DashOverlay.Menu(index: 0, slide: 1))
        check("menu: ▶ następna, ◀ z pierwszej na ostatnią", o.key(right, itemCount: 5, at: 1) == .consumed && o.snapshot(at: 1).menu?.index == 1
              && o.key(left, itemCount: 5, at: 1.1) == .consumed && o.key(left, itemCount: 5, at: 1.2) == .consumed && o.snapshot(at: 1.2).menu?.index == 4)
        check("menu: OK wybiera pozycję", o.key(ok, itemCount: 5, at: 2) == .activate(4))
        check("menu: mniej pozycji niż indeks → ostatnia", o.key(ok, itemCount: 3, at: 2.1) == .activate(2))
        check("menu: klawisz przedłuża otwarcie", o.snapshot(at: 2.1 + DashOverlay.menuIdle - 0.5).menu != nil)
        check("menu: ▲ zamyka", o.key(up, itemCount: 5, at: 3) == .consumed && !o.menuIsOpen && o.snapshot(at: 3.5).isEmpty)
        o.openMenu(at: 10)
        check("menu: zamyka się samo", o.snapshot(at: 10 + DashOverlay.menuIdle + DashOverlay.slideOut + 0.2).isEmpty)
        o.openMenu(at: 30); o.post(note(1), at: 31)
        check("menu + baner: OK i ◀ dla banera, ▶ dla menu", o.key(ok, itemCount: 5, at: 32) == .consumed && o.snapshot(at: 32.5).banner?.expand == 1
              && o.key(right, itemCount: 5, at: 32.6) == .consumed && o.snapshot(at: 32.6).menu?.index == 1
              && o.key(left, itemCount: 5, at: 33) == .consumed && o.snapshot(at: 33.5).banner == nil && o.snapshot(at: 33.5).menu?.index == 1)

        func ids(_ c: QuickContext) -> [QuickItem.ID] { QuickMenu.items(c).map(\.id) }
        check("menu: zwykły ekran", ids(QuickContext()) == [.theme, .font, .ambient, .calibrate])
        check("menu: wyciszanie tylko przy włączonych powiadomieniach", ids(QuickContext(notifications: true)) == [.theme, .font, .mute, .ambient, .calibrate])
        check("menu: wideo, gra i nawigacja mają swoje pozycje na początku", ids(QuickContext(screen: .video)).first == .nextVideo
              && ids(QuickContext(screen: .snake)).first == .exitGame && ids(QuickContext(navigating: true)).first == .endNavigation)
        let items = QuickMenu.items(QuickContext(dark: false, font: .pixel, notifications: true, muted: true))
        check("menu: pokazuje bieżące ustawienia", items.first { $0.id == .font }?.value == DashFont.pixel.title
              && items.first { $0.id == .theme }?.value != QuickMenu.items(QuickContext()).first { $0.id == .theme }?.value)
        check("menu: akcja zamyka menu, ustawienie nie", items.first { $0.id == .calibrate }?.closes == true && items.first { $0.id == .theme }?.closes == false)
        let d = UserDefaults(suiteName: "quicktest")!
        d.removePersistentDomain(forName: "quicktest")
        check("menu: domyślne ustawienia", QuickContext.current(screen: 0, navigating: false, defaults: d) == QuickContext())
        d.set(false, forKey: "dashboardDark"); d.set("pixel", forKey: "dashFont"); d.set(true, forKey: "notifEnabled")
        check("menu: ustawienia z pamięci", QuickContext.current(screen: 6, navigating: true, defaults: d)
              == QuickContext(screen: .video, dark: false, font: .pixel, notifications: true, navigating: true))
        d.removePersistentDomain(forName: "quicktest")
    }

    private static func testSnake() {
        let d = UserDefaults(suiteName: "snaketest")!
        d.removePersistentDomain(forName: "snaketest")
        let up = (0, -1), down = (0, 1), left = (-1, 0), right = (1, 0)
        func game() -> SnakeGame { let g = SnakeGame(defaults: d); g.setFood((40, 0)); return g }
        func head(_ g: SnakeGame) -> (Int, Int) { g.snapshot().snake[0] }

        var g = game()                                   // head (6,8), moving right
        g.step()
        check("snake: stoi do pierwszego kierunku", head(g) == (6, 8) && !g.snapshot().started)
        g.turn(up); g.turn(left)                         // quick U-turn inside one step
        g.step(); g.step()
        check("snake: szybki zawrót ▲◀ nie ginie", head(g) == (5, 7) && !g.snapshot().gameOver)

        g = game()
        g.turn(left)                                     // straight back into the body
        g.step()
        check("snake: zawrót o 180° ignorowany", head(g) == (7, 8) && !g.snapshot().gameOver)

        g = game()
        g.setFood((7, 8)); g.turn(right); g.step()
        check("snake: jedzenie wydłuża i daje punkt", g.snapshot().snake.count == 4 && g.snapshot().score == 1)
        g.setFood((40, 0))
        g.turn(down); g.step(); g.turn(left); g.step(); g.turn(up); g.step()   // 2×2 loop: head chases the tail
        check("snake: wejście w pole zwalniane przez ogon to nie kolizja", !g.snapshot().gameOver && head(g) == (6, 8))
        g.setFood((6, 7)); g.step(); g.setFood((40, 0))                        // 5 segments, score 2
        g.turn(right); g.step(); g.turn(down); g.step(); g.turn(left); g.step()
        check("snake: wjazd w siebie kończy grę", g.snapshot().gameOver && g.snapshot().score == 2)
        check("snake: rekord zapisany", g.snapshot().newRecord && d.integer(forKey: SnakeGame.bestKey) == 2
              && SnakeGame(defaults: d).snapshot().best == 2)
        g.turn(left); g.okPressed()
        check("snake: OK zaczyna od nowa", !g.snapshot().gameOver && g.snapshot().score == 0 && g.snapshot().snake.count == 3)

        g = game()
        g.turn(up)
        for _ in 0..<9 { g.step() }
        check("snake: ściana kończy grę, bez rekordu przy 0", g.snapshot().gameOver && !g.snapshot().newRecord && head(g) == (6, 0))
        check("snake: przyspiesza z punktami, ale nie bez końca", SnakeGame.interval(score: 0) == SnakeGame.baseInterval
              && SnakeGame.interval(score: 10) < SnakeGame.baseInterval && SnakeGame.interval(score: 500) == SnakeGame.minInterval)
        d.removePersistentDomain(forName: "snaketest")
    }

    private static func testSkippedTracks() {
        lines.append(""); lines.append("── Pominięte utwory ──")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func tr(_ s: Double, _ title: String) -> SessionTrack { SessionTrack(time: t0 + s, title: title, artist: "X") }
        // A 60 s, B skipped after 3 s, A again 100 s, C 9 s at the very end
        let raw = [tr(0, "A"), tr(60, "B"), tr(63, "A"), tr(163, "C")]
        let p = SessionTrack.played(raw, until: t0 + 172)
        check("utwory: pominięty (<10 s) nie liczy się, A+A scalone", p.map(\.title) == ["A"], "\(p.map(\.title))")
        let q = SessionTrack.played([tr(0, "A"), tr(10, "B")], until: t0 + 25)
        check("utwory: dokładnie 10 s się liczy", q.map(\.title) == ["A", "B"], "\(q.map(\.title))")
        check("utwory: pusta lista", SessionTrack.played([], until: t0).isEmpty)
    }

    private static func testAppList() {
        lines.append(""); lines.append("── AppList ──")
        // Hand-built expected bytes for one entry: u32 count, str pkg, str name, u32 0, str vendor, 13 flag bytes
        let e = MySpinPacketBuilder.AppListEntry(packageId: "a.b", name: "N", vendor: "V", kind: 2)
        let expected: [UInt8] = [1, 0, 0, 0,
                                 1, 3, 0, 0x61, 0x2E, 0x62,
                                 1, 1, 0, 0x4E,
                                 0, 0, 0, 0,
                                 1, 1, 0, 0x56,
                                 1, 0, 0, 1, 1, 0, 0, 0, 2, 1, 0x65, 0x6E, 0x67]
        check("AppList: koder = format z handshake'u", [UInt8](MySpinPacketBuilder.encodeAppList([e])) == expected)
        let own = [UInt8](MySpinPacketBuilder.encodeAppList(MySpinPacketBuilder.ownAppList))
        check("AppList: własna lista = 1 wpis SpinMyCan",
              own[0] == 1 && String(decoding: own, as: UTF8.self).contains("SpinMyCan"))
        check("AppList: pakiet = typ 70 + własna lista",
              MySpinPacketBuilder.appList().suffix(own.count) == Data(own))
    }

    private static func testObd() {
        check("obd: C155 → U0155", Obd.dtc(0xC1, 0x55) == "U0155")
        check("obd: C073 → U0073", Obd.dtc(0xC0, 0x73) == "U0073")
        check("obd: 1640 → P1640", Obd.dtc(0x16, 0x40) == "P1640")
        check("obd: 4123 → C0123", Obd.dtc(0x41, 0x23) == "C0123")
        let r = Obd.codes([0x43, 0x05, 0xC1, 0x55, 0xC1, 0x23, 0xC1, 0x32, 0xC0, 0x73, 0x16, 0x40])
        check("obd: 5 kodów z odpowiedzi 43", r == ["U0155", "U0123", "U0132", "U0073", "P1640"])
        check("obd: brak kodów", Obd.codes([0x43, 0x00]) == [])
        check("obd: nie odpowiedź 43", Obd.codes([0x44]) == nil)
        check("obd: kasowanie OK", Obd.summary(.clear, DiagReply(ecu: 0x7E8, bytes: [0x44])) == "kody skasowane")
        check("obd: odmowa 22", Obd.summary(.clear, DiagReply(ecu: 0x7E8, bytes: [0x7F, 0x04, 0x22])).contains("warunki"))
        check("obd: 7E8 = silnik", Obd.ecuName(0x7E8).hasPrefix("silnik"))
        check("obd: 29-bit 18DAF110 to odpowiedź OBD", DiagReply(ecu: 0x18DAF110, ext: true, bytes: [0x43, 0]).isObd)
        check("obd: 0x7A1 to nie odpowiedź OBD", !DiagReply(ecu: 0x7A1, bytes: [1]).isObd)
        check("obd: surowa ramka pokazana w hex", Obd.summary(.probe, DiagReply(ecu: 0x7A1, bytes: [0xAB, 0x01])) == "ramka: AB 01")
        // List of stored codes from frame 0x441
        func f441(_ code: (UInt8, UInt8), count: UInt8, pos: UInt8, counter: UInt8 = 0) -> [UInt8] {
            [0, code.0, code.1, count, pos, 0, counter, 0]
        }
        var col = StoredCodeCollector()
        check("441: bez ramek brak wyniku", col.result == nil && col.partial == nil)
        col.ingest(f441((0, 0), count: 0, pos: 0, counter: 9))
        check("441: jedna pusta ramka to jeszcze nie pewność", col.result == nil && col.partial == StoredCodes())
        col.ingest(f441((0, 0), count: 0, pos: 0, counter: 10))
        check("441: dwie puste ramki = brak kodów", col.result == StoredCodes())
        col = StoredCodeCollector()
        col.ingest(f441((0xC1, 0x55), count: 3, pos: 1))
        col.ingest(f441((0x16, 0x40), count: 3, pos: 3))
        col.ingest(f441((0xC1, 0x55), count: 3, pos: 1))
        check("441: niepełna lista czeka", col.result == nil && col.partial == StoredCodes(total: 3, codes: ["U0155", "P1640"]))
        col.ingest(f441((0xC0, 0x73), count: 3, pos: 2))
        check("441: pełna lista w kolejności pozycji", col.result == StoredCodes(total: 3, codes: ["U0155", "U0073", "P1640"]))
        col.ingest(f441((0, 0), count: 0, pos: 0)); col.ingest(f441((0, 0), count: 0, pos: 0))
        check("441: po skasowaniu lista pusta", col.result == StoredCodes())
        col = StoredCodeCollector()
        col.ingest(f441((0xC1, 0x55), count: 2, pos: 1)); col.ingest(f441((0xC1, 0x23), count: 1, pos: 1))
        check("441: zmiana liczby kodów zaczyna od nowa", col.result == StoredCodes(total: 1, codes: ["U0123"]))
        col.ingest([1, 2, 3]); col.ingest(f441((0xC1, 0x23), count: 1, pos: 5))
        check("441: krótka ramka i pozycja spoza listy pominięte", col.result == StoredCodes(total: 1, codes: ["U0123"]))

        // Outcome of a clear request
        let e = DiagReply(ecu: 0x7E8, bytes: [0x44])
        check("kasowanie: 44 = potwierdzone", Obd.clearOutcome([DiagReply(ecu: 0x7A1, bytes: [0x44]), e]) == .confirmed)
        check("kasowanie: surowa ramka 44 to nie potwierdzenie", Obd.clearOutcome([DiagReply(ecu: 0x7A1, bytes: [0x44])]) == .silent)
        check("kasowanie: odmowa 22", Obd.clearOutcome([DiagReply(ecu: 0x7E8, bytes: [0x7F, 0x04, 0x22])]) == .refused(0x22))
        check("kasowanie: samo „przetwarzam” to cisza", Obd.clearOutcome([DiagReply(ecu: 0x7E8, bytes: [0x7F, 0x04, 0x78])]) == .silent)
        check("kasowanie: brak odpowiedzi", Obd.clearOutcome([]) == .silent)
        check("kasowanie: odmowa 22 kończy próby, 11 nie", Obd.refusalIsFinal(0x22) && !Obd.refusalIsFinal(0x11))
        check("kasowanie: najpierw adres bezpośredni 7E0", Obd.clearOrder == [.phys11, .func11, .func29])

        // Verdicts
        let two = StoredCodes(total: 2, codes: ["U0155", "U0073"])
        func clear(_ before: StoredCodes?, _ after: StoredCodes?, confirmed: Bool = false, refusal: UInt8? = nil, sent: Int = 1) -> (text: String, ok: Bool) {
            Obd.verdict(DiagReport(kind: .clear, before: before, after: after, confirmed: confirmed, refusal: refusal, tx: DiagTx(sent: sent)))
        }
        check("werdykt: odczyt bez ramki 441", !Obd.verdict(DiagReport(kind: .read)).ok)
        check("werdykt: odczyt bez kodów", Obd.verdict(DiagReport(kind: .read, before: StoredCodes())).ok)
        check("werdykt: odczyt z kodami", !Obd.verdict(DiagReport(kind: .read, before: two)).ok)
        check("werdykt: skasowane i lista pusta", clear(two, StoredCodes(), confirmed: true).ok)
        check("werdykt: potwierdzone, ale kody wróciły", !clear(two, two, confirmed: true).ok)
        check("werdykt: potwierdzone bez listy", clear(two, nil, confirmed: true).ok)
        check("werdykt: lista pusta bez potwierdzenia", clear(two, StoredCodes()).ok)
        check("werdykt: odmowa", !clear(two, two, refusal: 0x22).ok && clear(two, two, refusal: 0x22).text.contains("warunki"))
        check("werdykt: nic nie wyszło na szynę", !clear(two, two, sent: 0).ok && clear(two, two, sent: 0).text != clear(two, two).text)
        check("werdykt: cisza przy pustej liście to nie sukces", !clear(StoredCodes(), StoredCodes()).ok)
    }

    /// Trasa pokazowa (pętla pod Krakowem, 20 min): silnik z mostka CAN i 4 piosenki — do zrzutów plakatu.
    static func demoRide() -> SessionSummary {
        let start = Date(timeIntervalSince1970: 1_792_400_000)
        var pts: [SessionPoint] = []
        for i in 0..<1200 {
            let a = Double(i) / 1200 * 2 * .pi
            let kmh = 70 + 45 * sin(a * 5)
            let gear = kmh < 50 ? 3 : (kmh < 80 ? 4 : (kmh < 100 ? 5 : 6))
            pts.append(SessionPoint(id: i, timestamp: start.addingTimeInterval(Double(i)), speedKmh: kmh,
                                    leanDeg: 38 * sin(a * 9), gForce: 0.3 + 0.2 * abs(sin(a * 7)),
                                    latitude: 50.06 + 0.045 * sin(a), longitude: 19.94 + 0.07 * cos(a) + 0.02 * sin(a * 3),
                                    altitudeM: 240, headingDeg: 0, isMoving: true,
                                    rpm: Int(kmh * 72), gear: gear, throttle: 300))
        }
        let tr = [("Midnight City", "M83", 0.0), ("Blinding Lights", "The Weeknd", 210),
                  ("Bohemian Rhapsody", "Queen", 420), ("Thunderstruck", "AC/DC", 780)]
            .map { SessionTrack(time: start.addingTimeInterval($0.2), title: $0.0, artist: $0.1) }
        return SessionSummary(id: UUID(), startTime: start, endTime: start.addingTimeInterval(1200),
                              totalDistKm: 23.4, maxSpeedKmh: 115, avgSpeedKmh: 70, maxLeanLeft: 38,
                              maxLeanRight: 37, maxGforce: 0.52, points: pts, tracks: tr)
    }

    /// Trasy w folderze iCloud Drive: kopia, odczyt, usuwanie; folder spoza iCloud nigdy
    /// nie zwalnia tras z telefonu (brak potwierdzenia wysłania na serwer).
    private static func testRouteCloud() {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("cloudtest")
        let local = base.appendingPathComponent("local"), cloud = base.appendingPathComponent("cloud")
        try? fm.removeItem(at: base)
        try? fm.createDirectory(at: local, withIntermediateDirectories: true)
        try? fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "cloudtest")!
        defaults.removePersistentDomain(forName: "cloudtest")
        let id = UUID()
        let meta = """
        {"id":"\(id.uuidString)","startTime":"2026-01-01T10:00:00Z","endTime":"2026-01-01T11:00:00Z",
         "totalDistKm":50,"maxSpeedKmh":120,"maxLeanLeft":30,"maxLeanRight":31,"pointCount":3,"isMerged":false}
        """
        let body = Data(String(repeating: "x", count: 5000).utf8)
        try? Data(meta.utf8).write(to: local.appendingPathComponent("\(id.uuidString).meta"))
        try? body.write(to: local.appendingPathComponent("\(id.uuidString).json"))

        let c = RouteCloudSync(localDir: local, defaults: defaults)
        c.setFolder(cloud)
        c.q.sync {}
        let cj = cloud.appendingPathComponent("\(id.uuidString).json")
        check("chmura: trasa skopiowana (json + meta)",
              (try? Data(contentsOf: cj)) == body && fm.fileExists(atPath: cloud.appendingPathComponent("\(id.uuidString).meta").path))
        check("chmura: folder spoza iCloud nie zwalnia starej trasy z telefonu",
              fm.fileExists(atPath: local.appendingPathComponent("\(id.uuidString).json").path))
        check("chmura: odczyt z folderu", c.cloudData("\(id.uuidString).json") == body)
        c.deleteFromCloud(id)
        c.q.sync {}
        check("chmura: usunięcie trasy usuwa kopię", !fm.fileExists(atPath: cj.path))
        defaults.removePersistentDomain(forName: "cloudtest")
        try? fm.removeItem(at: base)
    }

    /// Ekran „Wideo TT”: klatki z pliku według zegara (bez dekodera, działa w tle).
    private static func testVideoFrames() {
        let v = VideoFrameProvider()
        check("wideo: przed start() brak klatki", v.currentFrame() == nil)
        v.start()
        guard let a = v.currentFrame() else { check("wideo: jest plik video_tt.mjpg i klatka", false); return }
        let jpeg = a.count > 4 && a[a.startIndex] == 0xFF && a[a.startIndex + 1] == 0xD8
            && a[a.endIndex - 2] == 0xFF && a[a.endIndex - 1] == 0xD9
        check("wideo: klatka to cały JPEG", jpeg, "\(a.count) B")
        Thread.sleep(forTimeInterval: 0.3)
        let b = v.currentFrame()
        check("wideo: po 0,3 s inna klatka", b != nil && b != a)
        v.stop()
        check("wideo: po stop() brak klatki", v.currentFrame() == nil)
        Thread.sleep(forTimeInterval: 0.3)
        v.start()
        let c = v.currentFrame()
        check("wideo: wznowienie od miejsca pauzy (nie przeskakuje)", c == b, "pauza 0,3 s")
        v.togglePause()
        let p1 = v.currentFrame()
        Thread.sleep(forTimeInterval: 0.3)
        let p2 = v.currentFrame()
        check("wideo: pauza stoi na klatce z paskiem czasu", p1 != nil && p1 == p2 && p1 != c)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? p1?.write(to: docs.appendingPathComponent("featuretest/video_osd.jpg"))
        v.togglePause()
        v.seek(by: 60)
        let s = v.currentFrame()
        check("wideo: +60 s to inna klatka", s != nil && s != p1)
        v.stop()
    }

    /// Skrót ▲▼▲▼ zmiany motywu: tylko dokładna kolejność i tylko w oknie czasu.
    private static func testThemeCombo() {
        let up: UInt8 = 0x1E, down: UInt8 = 0x1F, ok: UInt8 = 0x0C
        func feed(_ keys: [UInt8], dt: Double) -> [Bool] {
            let j = JoystickState()
            return keys.enumerated().map { j.noteComboKey($0.element, at: 100 + Double($0.offset) * dt) }
        }
        // Sprzątanie skrótów: bez „Przejdź do”, ▲▼ = ekrany (poza grami)
        let kd = UserDefaults(suiteName: "keystest")!
        kd.removePersistentDomain(forName: "keystest")
        kd.set(0x1E, forKey: "goto.0.0.key"); kd.set(5, forKey: "goto.0.0.target")
        kd.set(0x21, forKey: "bind.classic.screenNext")      // ekran przypięty do ▶
        kd.set(0x1F, forKey: "bind.classic.next")            // utwór przypięty do ▼
        kd.set(0x20, forKey: "bind.snake.up")                // gra — bez zmian
        KeyBindings.clearShortcutsOnce(defaults: kd)
        let cl = DashboardScreen.classic.actions
        check("skróty: „Przejdź do” wyczyszczone", kd.object(forKey: "goto.0.0.key") == nil && kd.object(forKey: "goto.0.0.target") == nil)
        check("skróty: ▼ znów następny ekran, utwór na ▶", KeyBindings.key(for: cl.first { $0.id == "classic.screenNext" }!, defaults: kd) == 0x1F
              && KeyBindings.key(for: cl.first { $0.id == "classic.next" }!, defaults: kd) == 0x21)
        check("skróty: gry nietknięte", kd.integer(forKey: "bind.snake.up") == 0x20)
        kd.removePersistentDomain(forName: "keystest")
        let order = ContentView.orderedScreens("4,3,0,7").map(\.rawValue)
        check("ekrany: kolejność z apki + reszta na końcu", Array(order.prefix(3)) == [4, 0, 7] && order.count == DashboardScreen.allCases.count)
        check("ekrany: ▼ idzie po kolejności z apki", JoystickState.cycled(from: 4, delta: 1, order: order) == 0
              && JoystickState.cycled(from: 0, delta: 1, order: order) == 7)
        check("ekrany: ▲ z pierwszego na ostatni", JoystickState.cycled(from: 4, delta: -1, order: order) == order.last)
        check("motyw: ▲▼▲▼ szybko przełącza", feed([up, down, up, down], dt: 0.3) == [false, false, false, true])
        check("motyw: ▲▼▲▼ za wolno nic nie robi", !feed([up, down, up, down], dt: 0.6).contains(true))
        check("motyw: inna kolejność nic nie robi", !feed([up, up, down, down, down, up, ok, down], dt: 0.2).contains(true))
        check("motyw: skrót po innych przyciskach działa", feed([ok, down, up, down, up, down], dt: 0.2).last == true)
        check("motyw: ▲▼▲▼▲▼ przełącza raz", feed([up, down, up, down, up, down], dt: 0.2).filter { $0 }.count == 1)
    }

    private static func testBikeLink(tmp: URL) {
        lines.append("")
        lines.append("── Mostek CAN ──")

        // Telemetria wg firmware: 5400 obr/min, gaz 40, b3 = 0x54 (bieg 4 + bity gazu),
        // przechył 29922 (zrzut z nóżki bocznej: 15,63° w lewo), przyspieszenia z tego samego zrzutu
        let tele = Data([2, 0x07, 0x18, 0x15, 40, 0x54, 0xE2, 0x74,
                         0x48, 0x80, 0x3F, 0x6D, 0x6C, 0x85, 0x84, 0x03, 7, 3])
        let t = BikeTelemetry.parse(tele)
        check("telemetria: obroty", t?.rpm == 5400, "\(t?.rpm ?? -1)")
        check("telemetria: bieg bez bitów gazu", t?.gear == 4, "\(t?.gear ?? -1)")
        var mid = [UInt8](tele); mid[5] = 0x4E   // dźwignia w połowie zmiany: szyna podaje 14
        let tm = BikeTelemetry.parse(Data(mid))
        check("telemetria: bieg pośredni (14) nie jest biegiem", tm?.gearInTransit == true && tm?.gear == 0 && tm?.throttle10 == 161,
              "\(tm?.gear ?? -1)")
        check("telemetria: stary pakiet (18 B) nie ma części rozszerzonej",
              t?.ext == false && t?.coolantC == nil && t?.airC == nil && t?.rideMode == nil && t?.traction == nil)

        // Pakiet z programu płytki v4 (48 B): podstawa + surowe bajty prawdziwych ramek
        // z testów na postoju 2026-10-10. Identyczne bajty jak w tools/can/fw_core_test.cpp.
        let teleExt = Data([2, 0x0F, 0x08, 0x07, 0x56, 0x82, 0x46, 0x75,
                            0x00, 0x80, 0x00, 0x80, 0x00, 0x80, 0x84, 0x03, 1, 4,
                            0xFF, 0xBE, 0x04, 0x51, 0xC0, 0x2E, 0xE0, 0x2F, 0xA8, 0x01, 0x28,
                            0x04, 0x5F, 0x01, 0xCA, 0x0A, 0x05, 0x9C, 0x40, 0x3E, 0x30,
                            0x61, 0x74, 0x40, 0x08, 0x99, 0x44, 0x37, 0x43, 0x10])
        let x = BikeTelemetry.parse(teleExt)
        check("rozszerzony: podstawa bez zmian (1800 obr/min, bieg 2)", x?.rpm == 1800 && x?.gear == 2 && x?.ext == true)
        check("rozszerzony: płyn 88,75 °C (ekran motocykla pokazywał 88)", abs((x?.coolantC ?? 0) - 88.75) < 0.01,
              "\(x?.coolantC ?? -1)")
        check("rozszerzony: powietrze 32 °C", x?.airC == 32, "\(x?.airC ?? -1)")
        check("rozszerzony: przebieg 22980 km", x?.odometerKm == 22980, "\(x?.odometerKm ?? -1)")
        check("rozszerzony: tryb jazdy C, trakcja 4", x?.rideMode == "C" && x?.traction == 4,
              "\(x?.rideMode ?? "?") \(x?.traction ?? -1)")
        check("rozszerzony: sprzęgło wciśnięte, tempomat włączony", x?.clutchPulled == true && x?.cruiseOn == true)
        check("rozszerzony: koła 12000 / 12200, licznik 296",
              x?.wheelFrontRaw == 12000 && x?.wheelRearRaw == 12200 && x?.pulseCount == 296)
        check("rozszerzony: zawieszenie 1119 / 458, nastawa 10",
              x?.suspFrontRaw == 1119 && x?.suspRearRaw == 458 && x?.dampCmd == 10)
        check("rozszerzony: tłumienie U, przód +2, tył −3, SOLO",
              x?.dampMode == 3 && x?.dampUserFront == 2 && x?.dampUserRear == -3 && x?.preloadMode == 3)
        check("rozszerzony: przepustnica 327, gaz 50%", x?.tpsRaw == 327 && abs((x?.throttlePct ?? 0) - 50.1) < 0.2,
              "\(x?.tpsRaw ?? -1) \(x?.throttlePct ?? -1)")
        check("rozszerzony: 48 B nie ma odstępu Bluetooth", x?.connIntervalMs == nil)
        var withItvl = [UInt8](teleExt); withItvl.append(12)
        check("rozszerzony: bajt 48 = odstęp Bluetooth 15 ms", BikeTelemetry.parse(Data(withItvl))?.connIntervalMs == 15)
        var cut = [UInt8](teleExt); cut.removeLast(28)      // telefon bez większego MTU: 20 bajtów
        check("rozszerzony ucięty do 20 B czyta się jak stary", BikeTelemetry.parse(Data(cut))?.ext == false)
        var stale = [UInt8](teleExt); stale[18] = 0
        let xs = BikeTelemetry.parse(Data(stale))
        check("rozszerzony bez świeżych ramek: brak trybu, trakcji i powietrza",
              xs?.rideMode == nil && xs?.traction == nil && xs?.airC == nil && xs?.coolantC != nil)

        // Aktualizacja płytki: nadajnik kontra udawana płytka (te same reguły co ota_core.h).
        do {
            let img = FirmwareImage(version: 6, data: Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 9) }),
                                    tag: Data(repeating: 0xAB, count: 32))
            var tx = FirmwareSender(image: img, now: 0)
            let begin = tx.beginMessage()
            check("aktualizacja: BEGIN ma rozmiar, wersję i podpis",
                  begin.count == 38 && begin[0] == 1 && begin[1] == 0x40 && begin[2] == 0x0D && begin[3] == 0x03 && begin[5] == 6 && begin[6] == 0xAB)
            func reply(_ st: UInt8, _ off: Int) -> Data { Data([st, UInt8(off & 255), UInt8(off >> 8 & 255), UInt8(off >> 16 & 255), UInt8(off >> 24), 5]) }
            // udawana płytka: przyjmuje po kolei, potwierdza co 2048 B, jedną paczkę gubi
            var got = Data(), lastAck = 0, nakFor = -1, dropped = false, maxPending = 0, naks = 0
            var step = tx.handle(reply(0x10, 0), now: 0)
            var guardLoop = 0
            while step == .pump, guardLoop < 5000 {
                guardLoop += 1
                var replies: [Data] = []
                while let c = tx.nextChunk(maxWrite: 244) {
                    maxPending = max(maxPending, tx.sent - tx.acked)
                    let off = Int(c[1]) | Int(c[2]) << 8 | Int(c[3]) << 16 | Int(c[4]) << 24
                    if !dropped, off >= 50_000 { dropped = true; continue }
                    if off != got.count {
                        if nakFor != got.count { nakFor = got.count; naks += 1; replies.append(reply(0x23, got.count)) }
                        continue
                    }
                    got.append(c.dropFirst(5)); nakFor = -1
                    if got.count - lastAck >= 2048 || got.count == img.data.count { lastAck = got.count; replies.append(reply(0x11, got.count)) }
                }
                if replies.isEmpty { break }
                for r in replies { step = tx.handle(r, now: Double(guardLoop)) }
            }
            check("aktualizacja: cały program dociera mimo zgubionej paczki", step == .end && got == img.data && naks == 1,
                  "krok \(step), \(got.count) B, próśb o powtórkę \(naks)")
            check("aktualizacja: nigdy więcej niż okno niepotwierdzonych danych", maxPending <= FirmwareSender.window, "\(maxPending)")
            check("aktualizacja: DONE → czekamy na restart", tx.handle(reply(0x12, img.data.count), now: 1) == .restarting)
            var e = FirmwareSender(image: img, now: 0)
            if case .failed(let why) = e.handle(reply(0x24, 0), now: 0) {
                check("aktualizacja: zły podpis kończy się czytelnym komunikatem", why.contains("podpis"))
            } else { check("aktualizacja: zły podpis kończy się czytelnym komunikatem", false) }
            if case .failed(let why) = e.handle(reply(0x20, 0), now: 0) {
                check("aktualizacja: odmowa w ruchu mówi o silniku", why.contains("silnik"))
            } else { check("aktualizacja: odmowa w ruchu mówi o silniku", false) }
            var st = FirmwareSender(image: img, now: 0)
            _ = st.handle(reply(0x10, 0), now: 0)
            while st.nextChunk(maxWrite: 244) != nil {}
            check("aktualizacja: okno pełne → czekamy na potwierdzenie", st.sent == FirmwareSender.window && st.stalled(now: 2) == .wait)
            check("aktualizacja: brak potwierdzeń → powrót do ostatniej potwierdzonej pozycji",
                  st.stalled(now: 4) == .pump && st.sent == 0)
            var failed = false
            for i in 1...6 { if case .failed = st.stalled(now: 4 + Double(i) * 4) { failed = true } }
            check("aktualizacja: po kilku nieudanych powrotach koniec z błędem", failed)
        }

        // Prędkość z koła: przelicznik pojawia się dopiero po potwierdzeniu z GPS.
        var cal = WheelSpeedCalibration()
        check("koło: bez GPS nie ma przelicznika", cal.factor == nil && cal.kmh(8000) == nil)
        var changed = false
        for i in 0..<40 {      // 80 km/h, koło podaje 8000 ± szum, GPS równy
            if cal.add(wheelRaw: 8000 + (i % 3) - 1, gpsKmh: 80, gpsAccuracy: 5) { changed = true }
        }
        check("koło: po równej jeździe przelicznik ≈ 0,01", changed && abs((cal.factor ?? 0) - 0.01) < 0.00002,
              "\(cal.factor ?? -1)")
        check("koło: 12000 jednostek = 120 km/h", abs((cal.kmh(12000) ?? 0) - 120) < 0.2)
        var bad = WheelSpeedCalibration()
        for _ in 0..<60 { _ = bad.add(wheelRaw: 5000, gpsKmh: 80, gpsAccuracy: 5) }     // skala 0,016 — nie wierzymy
        check("koło: przelicznik daleki od założenia jest odrzucany", bad.factor == nil)
        var slow = WheelSpeedCalibration()
        for _ in 0..<60 { _ = slow.add(wheelRaw: 2000, gpsKmh: 20, gpsAccuracy: 5) }    // za wolno
        for _ in 0..<60 { _ = slow.add(wheelRaw: 8000, gpsKmh: 80, gpsAccuracy: 40) }   // słaby GPS
        for i in 0..<60 { _ = slow.add(wheelRaw: 8000 + i * 100, gpsKmh: 80 + Double(i) * 3, gpsAccuracy: 5) } // przyspieszanie
        check("koło: wolna jazda, słaby GPS i przyspieszanie nie uczą", slow.factor == nil)
        check("koło: zapisany przelicznik spoza ±25% jest ignorowany",
              WheelSpeedCalibration(stored: 0.02).factor == nil && WheelSpeedCalibration(stored: 0.0101).factor == 0.0101)

        // Zakres zawieszenia uczy się skrajnych wartości.
        var fr = SuspensionRange.front
        check("zawieszenie: z kierowcą w pionie ok. 78% zakresu startowego", abs(fr.travel(1119) - 0.776) < 0.01,
              "\(fr.travel(1119))")
        check("zawieszenie: głębsze ugięcie poszerza zakres", fr.include(900) && fr.travel(900) == 1 && fr.travel(1532) == 0)
        check("zawieszenie: wartość w zakresie niczego nie zmienia, zero jest ignorowane", !fr.include(1200) && !fr.include(0))

        // Ruch zawieszenia względem położenia w równej jeździe.
        var sm = SuspensionMotion()
        sm.update(raw: 1000, now: 0, moving: true)
        check("zawieszenie: pierwsza próbka jest odniesieniem", sm.value(raw: 1000, span: 450) == 0)
        check("zawieszenie: nurkowanie przodu = dodatnie, rozciągnięcie = ujemne",
              abs(sm.value(raw: 700, span: 450) - 0.667) < 0.01 && abs(sm.value(raw: 1244, span: 450) + 0.542) < 0.01)
        check("zawieszenie: wychylenie obcięte do ±1", sm.value(raw: 100, span: 450) == 1 && sm.value(raw: 1900, span: 450) == -1)
        for i in 1...600 { sm.update(raw: 900, now: Double(i) * 0.1, moving: true) }      // minuta jazdy niżej
        check("zawieszenie: odniesienie dochodzi do nowego położenia w jeździe", abs((sm.base ?? 0) - 900) < 8, "\(sm.base ?? -1)")
        for i in 1...600 { sm.update(raw: 1200, now: 60 + Double(i) * 0.1, moving: false) } // postój
        check("zawieszenie: na postoju odniesienie stoi", abs((sm.base ?? 0) - 900) < 8, "\(sm.base ?? -1)")

        check("telemetria: gaz 8- i 10-bitowy", t?.throttleRaw == 40 && t?.throttle10 == 161, "\(t?.throttle10 ?? -1)")
        check("telemetria: przechył z nóżki = 15,63° w lewo (ujemny)",
              abs((t?.leanDeg ?? 0) + 15.63) < 0.01, String(format: "%.3f", t?.leanDeg ?? 0))
        check("telemetria: przyspieszenia", t?.accelWords == [32840, 27967, 34156], "\(t?.accelWords ?? [])")
        check("telemetria: pion ≈ −1 g, bok ≈ +0,28 g",
              abs((t?.accelG[1] ?? 0) + 0.96) < 0.01 && abs((t?.accelG[2] ?? 0) - 0.278) < 0.01)
        check("telemetria: flagi świeżości", t?.engineFresh == true && t?.leanFresh == true && t?.accelFresh == true)
        check("telemetria: prawdziwa szyna, program płytki v3", t?.simulated == false && t?.fwVersion == 3)
        check("telemetria: ramki/s", t?.busFps == 900, "\(t?.busFps ?? -1)")
        var upright = tele; upright[6] = 0x00; upright[7] = 0x80
        check("telemetria: pion = 0°", BikeTelemetry.parse(upright)?.leanDeg == 0)
        var right = tele; right[6] = 0xFE; right[7] = 0x82   // 33534: zrzut z pochylenia w prawo
        check("telemetria: prawo = +4,21°", abs((BikeTelemetry.parse(right)?.leanDeg ?? 0) - 4.21) < 0.01)
        var noLean = tele; noLean[1] = 0x01
        check("telemetria: przechył nieświeży", BikeTelemetry.parse(noLean)?.leanFresh == false)
        var fake = tele; fake[1] = 0x87
        check("telemetria: program symulacyjny rozpoznany", BikeTelemetry.parse(fake)?.simulated == true)
        var oldFw = tele; oldFw[17] = 0
        check("telemetria: stary program płytki (bez numeru) nadal czytany", BikeTelemetry.parse(oldFw)?.fwVersion == 0)
        check("telemetria: za krótki pakiet odrzucony", BikeTelemetry.parse(tele.prefix(17)) == nil)
        var wrongVer = tele; wrongVer[0] = 1
        check("telemetria: stara wersja odrzucona", BikeTelemetry.parse(wrongVer) == nil)

        // Strumień surowy: nagłówek + rekord 0x1A1 (8 B, 5 ramek) + rekord 0x7E8 (3 B, 1 ramka)
        var raw = Data([2, 41, 0x10, 0x27, 0x00, 0x00])
        raw.append(contentsOf: [0xA1, 0x01, 8, 5, 0x15, 0x18, 40, 0x54, 1, 2, 3, 4])
        raw.append(contentsOf: [0xE8, 0x07, 3, 1, 0xAA, 0xBB, 0xCC])
        let r = CanRawPacket.parse(raw)
        check("surowe: nagłówek", r?.seq == 41 && r?.boardMs == 10_000)
        check("surowe: dwa rekordy", r?.records.count == 2)
        check("surowe: ID i dane", r?.records.first?.id == 0x1A1 && r?.records.first?.count == 5
              && r?.records.first?.data == [0x15, 0x18, 40, 0x54, 1, 2, 3, 4]
              && r?.records.last?.id == 0x7E8 && r?.records.last?.data == [0xAA, 0xBB, 0xCC])
        check("surowe: ucięty rekord odrzucony", CanRawPacket.parse(raw.dropLast(2)) == nil)
        check("surowe: sam nagłówek = zero rekordów", CanRawPacket.parse(raw.prefix(6))?.records.isEmpty == true)

        // Plik logu
        let dir = tmp.appendingPathComponent("canlog_test")
        guard let w = CanLogWriter(dir: dir), let pkt = r else {
            check("log: plik utworzony", false); return
        }
        w.can(pkt)
        w.phone(PhoneSample(speedKmh: 87.4, leanDeg: -18.2, gForce: 0.41, lat: 49.678912, lon: 18.912345,
                            altitudeM: 612, headingDeg: 52, gpsAccuracy: 5, temperatureC: 17.5))
        w.phone(PhoneSample())
        var song = PhoneSample(); song.track = "M83 — Midnight City"
        w.phone(song); w.phone(song)                    // ten sam utwór drugi raz = bez nowej linii
        w.close()
        let text = (try? String(contentsOf: w.url, encoding: .utf8)) ?? ""
        let rows = text.split(separator: "\n").map(String.init)
        let c = rows.filter { $0.hasPrefix("C,") }, ph = rows.filter { $0.hasPrefix("P,") }
        check("log: dwie linie ramek", c.count == 2, "\(c.count)")
        check("log: ramka 0x1A1", c.first?.hasSuffix(",10000,1A1,5,151828540102030" + "4") == true, c.first ?? "")
        check("log: ramka 0x7E8", c.last?.hasSuffix(",10000,7E8,1,AABBCC") == true, c.last ?? "")
        check("log: linia telefonu", ph.first?.hasSuffix(",87.4,-18.2,0.41,49.678912,18.912345,612,52,5,17.5") == true, ph.first ?? "")
        check("log: brak GPS = puste pola", ph.dropLast(2).last?.hasSuffix(",0.0,0.0,0.00,,,0,-1,-1,") == true, ph.last ?? "")
        check("log: licznik bajtów zgadza się z plikiem", w.bytes == text.utf8.count, "\(w.bytes) vs \(text.utf8.count)")
        let sl = rows.filter { $0.hasPrefix("S,") }
        check("log: piosenka raz, przy zmianie utworu", sl.count == 1 && sl[0].hasSuffix(",M83 — Midnight City"), "\(sl)")

        // Znacznik: jedna linia, przecinki zostają (parser tnie tylko dwa pierwsze)
        if let w2 = CanLogWriter(dir: dir, now: Date(timeIntervalSince1970: 1_760_100_000)) {
            w2.mark("temp 92, paliwo 3 kreski\nodo 1234")
            w2.close()
            let m = ((try? String(contentsOf: w2.url, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init).filter { $0.hasPrefix("M,") }
            check("log: znacznik w jednej linii", m.count == 1 && m[0].hasSuffix(",temp 92, paliwo 3 kreski odo 1234"), m.first ?? "")
        }

        // Limit miejsca: najstarsze pliki znikają, otwarty zostaje
        let qdir = tmp.appendingPathComponent("quota_test")
        try? FileManager.default.createDirectory(at: qdir, withIntermediateDirectories: true)
        let names = ["can_20261001_100000.csv", "can_20261002_100000.csv", "can_20261003_100000.csv", "can_20261004_100000.csv"]
        for n in names { try? Data(count: 1000).write(to: qdir.appendingPathComponent(n)) }
        let removed = BikeLinkManager.pruneLogs(in: qdir, quota: 2500, keep: qdir.appendingPathComponent(names[3]), maxAge: nil)
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: qdir.path)) ?? []).sorted()
        check("limit: usunięte dwa najstarsze", removed == 2 && left == [names[2], names[3]], "\(removed) \(left)")
        let removed2 = BikeLinkManager.pruneLogs(in: qdir, quota: 500, keep: qdir.appendingPathComponent(names[3]), maxAge: nil)
        let left2 = ((try? FileManager.default.contentsOfDirectory(atPath: qdir.path)) ?? []).sorted()
        check("limit: otwarty plik nietykalny nawet ponad limit", removed2 == 1 && left2 == [names[3]], "\(removed2) \(left2)")
        check("limit: w normie nic nie znika", BikeLinkManager.pruneLogs(in: qdir, quota: 5000, maxAge: nil) == 0)
        // Wiek z nazwy: starsze niż 14 dni znikają, otwarty zostaje
        let adir = tmp.appendingPathComponent("age_test")
        try? FileManager.default.removeItem(at: adir)
        try? FileManager.default.createDirectory(at: adir, withIntermediateDirectories: true)
        let aged = ["can_20261001_100000.csv", "link_20261002_100000.csv", "can_20261020_100000.csv", "can_20261003_100000.csv", "notatki.csv"]
        for n in aged { try? Data(count: 10).write(to: adir.appendingPathComponent(n)) }
        let now = BikeLinkManager.logDate("can_20261028_120000.csv") ?? Date()
        let removedOld = BikeLinkManager.pruneLogs(in: adir, keep: adir.appendingPathComponent(aged[3]), now: now)
        let leftAge = ((try? FileManager.default.contentsOfDirectory(atPath: adir.path)) ?? []).sorted()
        check("wiek: starsze niż 14 dni znikają (otwarty i bez daty zostają)",
              removedOld == 2 && leftAge == ["can_20261003_100000.csv", "can_20261020_100000.csv", "notatki.csv"],
              "\(removedOld) \(leftAge)")

        check("znaczek: mostek wyłączony = brak", ContentView.leanSource(enabled: false, fromBike: true, simulated: false) == nil)
        check("znaczek: telefon", ContentView.leanSource(enabled: true, fromBike: false, simulated: true) == .phone)
        check("znaczek: motocykl", ContentView.leanSource(enabled: true, fromBike: true, simulated: false) == .bike)
        check("znaczek: symulacja", ContentView.leanSource(enabled: true, fromBike: true, simulated: true) == .simulated)

        testBusTable()
        testEngineInRoutes()
    }

    /// Podgląd magistrali: uczenie tła, różnice, tempo ramek i licznik koła.
    private static func testBusTable() {
        let bus = BusTable()
        var now = 100.0
        var counter: UInt8 = 0
        func packet(brake: UInt8, wheel: UInt8) -> CanRawPacket {
            counter &+= 1
            return CanRawPacket(seq: counter, boardMs: UInt32(now * 1000), records: [
                .init(id: 0x1A9, count: 10, data: [0, 0, brake, 0x4C, 0, 0, counter & 15, counter &* 91]),
                .init(id: 0x221, count: 5, data: [0, wheel, 0x07, 0x65, 0x80, 0, counter & 15, 0]),
            ])
        }
        var wheel: UInt8 = 250
        func feed(_ n: Int, brake: UInt8, wheelStep: UInt8 = 0) {
            for _ in 0..<n { wheel &+= wheelStep; bus.ingest(packet(brake: brake, wheel: wheel), at: now); now += 0.1 }
        }
        feed(10, brake: 0x7D)
        check("szyna: dwa ID", bus.count == 2)
        let r0 = bus.rows(at: now).first { $0.id == 0x1A9 }
        check("szyna: tempo ramek ≈ 100/s", abs((r0?.rate ?? 0) - 100) < 5, "\(r0?.rate ?? -1)")
        check("szyna: licznik i suma świeżo zmienione, reszta nie", r0?.recent == 0b1100_0000, "\(r0?.recent ?? 0)")
        check("szyna: bez zapamiętanego stanu nie ma różnic", r0?.diff == 0 && r0?.baseline == nil)

        bus.startLearning(at: now, duration: 1.0)
        check("szyna: uczenie trwa", bus.isLearning)
        feed(12, brake: 0x7D)
        check("szyna: uczenie skończone po czasie", !bus.isLearning)
        let r1 = bus.rows(at: now).first { $0.id == 0x1A9 }
        check("szyna: szum = licznik + suma", r1?.noisy == 0b1100_0000, "\(r1?.noisy ?? 0)")
        check("szyna: w spoczynku brak różnic", r1?.diff == 0)

        feed(5, brake: 0x95)
        let r2 = bus.rows(at: now).first { $0.id == 0x1A9 }
        check("szyna: wciśnięty hamulec = dokładnie bajt 2", r2?.diff == 0b0000_0100, "\(r2?.diff ?? 0)")
        check("szyna: stan zapamiętany 0x7D, bieżący 0x95", r2?.baseline?[2] == 0x7D && r2?.data[2] == 0x95)
        feed(5, brake: 0x7D)
        check("szyna: po puszczeniu różnica znika", bus.rows(at: now).first { $0.id == 0x1A9 }?.diff == 0)
        bus.clearBaseline()
        check("szyna: wyczyszczenie stanu", bus.rows(at: now).allSatisfy { $0.baseline == nil && $0.noisy == 0 })

        check("szyna: koło stoi = 0 impulsów/s", abs(bus.wheelPulsesPerSec ?? -1) < 0.01, "\(bus.wheelPulsesPerSec ?? -1)")
        feed(30, brake: 0x7D, wheelStep: 4)      // 4 impulsy co 0,1 s, z przewinięciem przez 255
        check("szyna: 40 impulsów/s mimo przewinięcia licznika", abs((bus.wheelPulsesPerSec ?? 0) - 40) < 1,
              "\(bus.wheelPulsesPerSec ?? -1)")
        bus.reset()
        check("szyna: reset", bus.count == 0 && bus.wheelPulsesPerSec == nil)
    }

    /// Trasy: stare pliki bez pól silnika nadal się wczytują, nowe niosą obroty/bieg/gaz.
    private static func testEngineInRoutes() {
        let old = """
        {"id":0,"timestamp":781000000,"speedKmh":87.5,"leanDeg":-12.5,"gForce":0.3,"latitude":49.7,"longitude":18.9,"altitudeM":400,"headingDeg":90,"isMoving":true}
        """
        let p = try? JSONDecoder().decode(SessionPoint.self, from: Data(old.utf8))
        check("trasa: stary punkt bez pól silnika się wczytuje", p != nil && p?.rpm == nil && p?.gear == nil && p?.speedKmh == 87.5)

        let pt = SessionPoint(id: 0, timestamp: Date(timeIntervalSince1970: 1_760_000_000), speedKmh: 87.5,
                              leanDeg: -12.5, gForce: 0.3, latitude: 49.7, longitude: 18.9, altitudeM: 400,
                              headingDeg: 90, isMoving: true, rpm: 5400, gear: 4, throttle: 161)
        let back = (try? JSONEncoder().encode(pt)).flatMap { try? JSONDecoder().decode(SessionPoint.self, from: $0) }
        check("trasa: pola silnika przeżywają zapis i odczyt", back?.rpm == 5400 && back?.gear == 4 && back?.throttle == 161)

        let plain = SessionPoint(id: 1, timestamp: Date(timeIntervalSince1970: 1_760_000_001), speedKmh: 0,
                                 leanDeg: 0, gForce: 0, latitude: 0, longitude: 0, altitudeM: 0,
                                 headingDeg: -1, isMoving: false)
        let sum = SessionSummary(id: UUID(), startTime: pt.timestamp, endTime: plain.timestamp, totalDistKm: 0,
                                 maxSpeedKmh: 87.5, avgSpeedKmh: 87.5, maxLeanLeft: 12.5, maxLeanRight: 0,
                                 maxGforce: 0.3, points: [pt, plain])
        let rows = sum.csvString().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        check("trasa: CSV ma kolumny silnika i piosenki", rows.first?.hasSuffix(",is_moving,rpm,gear,throttle_raw,song") == true, rows.first ?? "")
        check("trasa: CSV z danymi silnika", rows.count == 3 && rows[1].hasSuffix(",1,5400,4,161,"), rows.count > 1 ? rows[1] : "")
        check("trasa: CSV bez danych silnika = puste pola", rows.count == 3 && rows[2].hasSuffix(",0,,,,"), rows.count > 2 ? rows[2] : "")
        // Piosenki: utwór w punkcie = ostatni rozpoczęty; przecinek w tytule w cudzysłowie
        var withSongs = sum
        withSongs.tracks = [SessionTrack(time: pt.timestamp.addingTimeInterval(-5), title: "Hey, Jude", artist: "The Beatles")]
        let srows = withSongs.csvString().split(separator: "\n").map(String.init)
        check("trasa: CSV z piosenką (cudzysłów przy przecinku)", srows.count == 3 && srows[1].hasSuffix(",\"The Beatles — Hey, Jude\""), srows.count > 1 ? srows[1] : "")
        let demo = demoRide()
        check("trasa: utwór trasy = grał najdłużej", demo.favoriteTrack?.title == "Thunderstruck", demo.favoriteTrack?.title ?? "nil")
        check("trasa: utwór w chwili = ostatni rozpoczęty", demo.track(at: demo.startTime.addingTimeInterval(300))?.title == "Blinding Lights")

        // Statystyki silnika: 10 s na luzie (postój), 20 s na 1., 30 s na 2., 40 s na 3., potem 5 s bez danych
        var pts: [SessionPoint] = []
        func add(_ n: Int, gear: Int?, rpm: Int?, moving: Bool) {
            for _ in 0..<n {
                pts.append(SessionPoint(id: pts.count, timestamp: Date(timeIntervalSince1970: 1_760_000_000 + Double(pts.count)),
                                        speedKmh: moving ? 60 : 0, leanDeg: 0, gForce: 0, latitude: 0, longitude: 0,
                                        altitudeM: 0, headingDeg: -1, isMoving: moving, rpm: rpm, gear: gear, throttle: rpm == nil ? nil : 100))
            }
        }
        add(10, gear: 0, rpm: 1300, moving: false)
        add(20, gear: 1, rpm: 4000, moving: true)
        add(30, gear: 2, rpm: 6000, moving: true)
        add(40, gear: 3, rpm: 9000, moving: true)
        add(5, gear: nil, rpm: nil, moving: true)
        let e = EngineStats.compute(pts)
        check("silnik: maks. obroty", e?.maxRPM == 9000)
        check("silnik: średnia tylko z jazdy", e?.avgRPM == (20 * 4000 + 30 * 6000 + 40 * 9000) / 90, "\(e?.avgRPM ?? -1)")
        check("silnik: czas na biegach", e?.gearSeconds == [10, 20, 30, 40, 0, 0, 0], "\(e?.gearSeconds ?? [])")
        check("silnik: udział biegów bez luzu", abs((e?.gearShare[2] ?? 0) - 40.0 / 90) < 1e-9 && abs((e?.gearShare.reduce(0, +) ?? 0) - 1) < 1e-9)
        check("silnik: dwie zmiany biegu (ruszenie z luzu się nie liczy)", e?.shifts == 2, "\(e?.shifts ?? -1)")
        check("silnik: pokrycie danych 100 ze 105 punktów", abs((e?.coverage ?? 0) - 100.0 / 105) < 1e-9)
        check("silnik: trasa bez mostka = brak sekcji", EngineStats.compute([plain]) == nil)
    }

    // MARK: — Pogoda: prawdziwe zapytanie

    private static let netWeather = WeatherManager()

    private static func testWeatherNetwork(out: URL) {
        // Kraków → Zakopane w linii prostej, punkty co ~10 km
        let pts = (0...8).map { i -> RoutePoint in
            let f = Double(i) / 8
            return RoutePoint(coord: CLLocationCoordinate2D(latitude: 50.06 - f * 0.77,
                                                            longitude: 19.94 + f * 0.01),
                              distM: f * 86_000)
        }
        netWeather.fetchAhead(here: pts[0].coord, points: pts, speedMS: 20,
                              navRemaining: 86_000, reachesDestination: true) { res in
            var o: [String] = []
            if let r = res {
                o.append("OK   odpowiedź Open-Meteo sparsowana (9 punktów trasy)")
                o.append("     horyzont: \(r.horizonMin) min / \(String(format: "%.0f", r.horizonKm)) km, do celu: \(r.reachesDestination)")
                o.append("     wiatr: \(r.windKmh) km/h, porywy \(r.gustKmh), z kierunku \(r.windFromDeg)°")
                o.append("     pigułki: " + r.chips(now: Date(), navRemaining: 86_000, headingDeg: 180)
                    .map { $0.text }.joined(separator: " | "))
            } else {
                o.append("FAIL brak / zły format odpowiedzi Open-Meteo")
            }
            // Drugie zapytanie: tryb bez nawigacji (pojedynczy punkt = inny kształt JSON-a)
            netWeather.fetchAhead(here: pts[0].coord, points: [], speedMS: 0,
                                  navRemaining: 0, reachesDestination: false) { one in
                if let r = one {
                    o.append("OK   tryb bez trasy (odpowiedź-obiekt zamiast listy)")
                    o.append("     pigułki: " + r.chips(now: Date(), navRemaining: 0, headingDeg: 180)
                        .map { $0.text }.joined(separator: " | "))
                } else {
                    o.append("FAIL tryb bez trasy")
                }
                try? o.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
            }
        }
    }
}
#endif
