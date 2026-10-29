// ReplayManager.swift
// Odtwarzanie nagranej sesji jazdy — feed danych do FrameRenderera w czasie rzeczywistym.
//
// Architektura:
//   - Sesja ma punkty co ~1s (timestamps).
//   - Replay robi interpolację liniową między sąsiednimi punktami → płynna animacja przy 10fps.
//   - Speed multiplier (0.5x – 10x) skaluje upływ czasu replay'a względem oryginału.
//
// Render: ContentView.previewTimer wciąż chodzi z 1Hz; gdy ReplayManager.isPlaying,
// renderer dostaje wartości z replay'a zamiast z motion managera.

import Foundation
import Combine

final class ReplayManager: ObservableObject {

    // MARK: — Stan publiczny

    @Published private(set) var summary:    SessionSummary?
    @Published var            isPlaying:    Bool   = false
    /// 0.0–1.0 — procent przebytej trasy (do progress bar / seekowania)
    @Published var            progress:     Double = 0
    /// Mnożnik prędkości odtwarzania
    @Published var            speedMult:    Double = 1.0

    // MARK: — Aktualne wartości (czytane przez ContentView dla rendera)

    @Published private(set) var curSpeedKmh:  Double = 0
    @Published private(set) var curLeanDeg:   Double = 0
    @Published private(set) var curGforce:    Double = 0
    @Published private(set) var curHeading:   Double = -1
    @Published private(set) var curAltitude:  Double = 0
    @Published private(set) var curLatitude:  Double = 0
    @Published private(set) var curLongitude: Double = 0
    @Published private(set) var curTimestamp: Date   = .distantPast
    /// Indeks aktualnego punktu w summary.points (do mini-mapy: rysujemy points[0..idx])
    @Published private(set) var curIndex:     Int    = 0

    // MARK: — Stan wewnętrzny

    /// Czas (sek) w obrębie sesji, 0 = startTime, durationSec = endTime.
    private var elapsed:    TimeInterval = 0
    private var lastTick:   Date         = .distantPast
    private var tickTimer:  DispatchSourceTimer?

    // MARK: — API

    /// Załaduj sesję — zatrzymuje obecne odtwarzanie.
    func load(_ summary: SessionSummary) {
        pause()
        self.summary  = summary
        self.elapsed  = 0
        self.progress = 0
        self.curIndex = 0
        applyPointAtElapsed()
    }

    /// Zwolnij sesję — wracamy do trybu live.
    func unload() {
        pause()
        summary  = nil
        elapsed  = 0
        progress = 0
    }

    func play() {
        guard summary != nil, !isPlaying else { return }
        isPlaying = true
        lastTick  = Date()

        // 5Hz tick — wystarcza dla płynnej animacji UI; więcej zabiło performance
        // bo SwiftUI Charts rebuilduje LineMarks przy każdym tick'u
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.2, repeating: 0.2, leeway: .milliseconds(40))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        tickTimer = t
    }

    func pause() {
        isPlaying = false
        tickTimer?.cancel(); tickTimer = nil
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Skok do procentu trasy (0–1).
    func seek(to p: Double) {
        guard let s = summary else { return }
        let pp = min(max(p.isFinite ? p : 0, 0), 1)
        progress = pp
        elapsed  = pp * Double(s.durationSec)
        applyPointAtElapsed()
    }

    /// Przełącza między dostępnymi prędkościami w pętli.
    func cycleSpeed() {
        let speeds: [Double] = [0.5, 1.0, 2.0, 5.0, 10.0]
        let idx = speeds.firstIndex(of: speedMult) ?? 1
        speedMult = speeds[(idx + 1) % speeds.count]
    }

    // MARK: — Tick + interpolacja

    private func tick() {
        guard let s = summary, isPlaying else { return }
        let now = Date()
        let dt  = now.timeIntervalSince(lastTick) * speedMult
        lastTick = now
        elapsed += dt

        // Min 0.5s — chroni przed div/0 dla absurdalnie krótkich sesji.
        let total = max(Double(s.durationSec), 0.5)
        if elapsed >= total {
            elapsed   = total
            progress  = 1.0
            applyPointAtElapsed()
            pause()                 // koniec — zatrzymaj
            return
        }
        progress = elapsed / total
        applyPointAtElapsed()
    }

    /// Znajduje 2 sąsiednie punkty wokół `elapsed` i robi interpolację liniową.
    private func applyPointAtElapsed() {
        guard let s = summary, !s.points.isEmpty else { return }
        let target = s.startTime.addingTimeInterval(elapsed)

        // Binary search po timestamp
        let pts = s.points
        var lo = 0, hi = pts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if pts[mid].timestamp <= target { lo = mid } else { hi = mid - 1 }
        }
        let idx = lo

        let p0 = pts[idx]
        if idx + 1 < pts.count {
            let p1 = pts[idx + 1]
            let span = p1.timestamp.timeIntervalSince(p0.timestamp)
            let t = span > 0
                ? min(max(target.timeIntervalSince(p0.timestamp) / span, 0), 1)
                : 0
            curSpeedKmh  = lerp(p0.speedKmh,  p1.speedKmh,  t)
            curLeanDeg   = lerp(p0.leanDeg,   p1.leanDeg,   t)
            curGforce    = lerp(p0.gForce,    p1.gForce,    t)
            curAltitude  = lerp(p0.altitudeM, p1.altitudeM, t)
            // Heading: interpolacja kątowa (handluje wrap 360→0)
            curHeading   = lerpAngle(p0.headingDeg, p1.headingDeg, t)
            // GPS: interpolacja liniowa (na małych dt jest to OK)
            curLatitude  = p0.latitude  != 0 && p1.latitude  != 0 ? lerp(p0.latitude,  p1.latitude,  t) : (p0.latitude  != 0 ? p0.latitude  : p1.latitude)
            curLongitude = p0.longitude != 0 && p1.longitude != 0 ? lerp(p0.longitude, p1.longitude, t) : (p0.longitude != 0 ? p0.longitude : p1.longitude)
        } else {
            // Ostatni punkt — bez interpolacji
            curSpeedKmh  = p0.speedKmh
            curLeanDeg   = p0.leanDeg
            curGforce    = p0.gForce
            curAltitude  = p0.altitudeM
            curHeading   = p0.headingDeg
            curLatitude  = p0.latitude
            curLongitude = p0.longitude
        }
        curTimestamp = target
        curIndex     = idx
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    /// Interpolacja kątowa — krótszą drogą wokół 360°.
    private func lerpAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        guard a >= 0, b >= 0 else { return a >= 0 ? a : b }
        var diff = b - a
        if diff > 180  { diff -= 360 }
        if diff < -180 { diff += 360 }
        var result = a + diff * t
        if result < 0    { result += 360 }
        if result >= 360 { result -= 360 }
        return result
    }
}
