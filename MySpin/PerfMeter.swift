// PerfMeter.swift
// Miernik osiągów w stylu Dragy/RaceBox — TYLKO czujniki telefonu (GPS + IMU),
// zero zależności od telemetrii motocykla.
//
// Prędkość z GPS (Doppler, ±0.2 km/h) próbkowana ~1 Hz; moment przekroczenia
// progu (100 km/h) interpolowany liniowo między próbkami → ~0.1–0.2s dokładności.

import Foundation
import Combine

// MARK: — Wynik przejazdu

struct PerfRun: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var zeroTo60:    Double?   // s
    var zeroTo100:   Double?   // s
    var sixtyTo100:  Double?   // s
    var quarterMile: Double?   // s (402 m)
    var quarterTrap: Double?   // km/h na mecie 402 m
    var zeroTo400m:  Double?   // s
    var maxSpeed:    Double    // km/h
}

// MARK: — Snapshot dla renderera

struct PerfSnapshot {
    let stateLabel: String     // "Gotowy" / "POMIAR" / "Stój by zacząć"
    let armed:      Bool
    let running:    Bool
    let speed:      Double
    let elapsed:    Double
    let distance:   Double     // m
    let zeroTo60:   Double?
    let zeroTo100:  Double?
    let quarter:    Double?
    let quarterTrap: Double?
    let zeroTo400m: Double?
    let maxSpeed:   Double
    let lastRun:    PerfRun?
}

// MARK: — Miernik

final class PerfMeter: ObservableObject {

    @Published private(set) var display: PerfSnapshot
    @Published private(set) var runs: [PerfRun] = []

    private enum State { case armed, running }
    private var state: State = .armed

    private var prevSpeed: Double = 0
    private var prevTime:  Date?  = nil
    private var startTime: Date?  = nil

    private var distance: Double = 0
    private var runMax:   Double = 0
    private var z60: Double?, z100: Double?, quarter: Double?, qTrap: Double?, d400: Double?

    private let quarterMileM = 402.336
    private let launchKmh    = 5.0     // próg startu
    private let stopKmh      = 2.0     // próg końca

    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("perf_runs.json")
    }

    init() {
        display = PerfSnapshot(stateLabel: String(localized: "Stój by zacząć"), armed: false, running: false,
                               speed: 0, elapsed: 0, distance: 0, zeroTo60: nil, zeroTo100: nil,
                               quarter: nil, quarterTrap: nil, zeroTo400m: nil, maxSpeed: 0, lastRun: nil)
        loadRuns()
        refresh(speed: 0, elapsed: 0)
    }

    // MARK: — Karmienie próbką prędkości (z GPS, na main)

    func feed(speedKmh v: Double, at t: Date) {
        defer { prevSpeed = v; prevTime = t }
        guard let pt = prevTime else { refresh(speed: v, elapsed: 0); return }
        let dt = t.timeIntervalSince(pt)
        guard dt > 0, dt < 5 else { refresh(speed: v, elapsed: currentElapsed(t)); return }   // pomiń luki GPS

        switch state {
        case .armed:
            // Start gdy ruszamy ze stania
            if prevSpeed < launchKmh, v >= launchKmh {
                state = .running
                startTime = pt            // moment gdy prędkość była ~0
                distance = 0; runMax = v
                z60 = nil; z100 = nil; quarter = nil; qTrap = nil; d400 = nil
            }

        case .running:
            guard let st = startTime else { break }
            let prevDist = distance
            distance += (v + prevSpeed) / 2 / 3.6 * dt   // trapez, metry
            runMax = max(runMax, v)

            // Progi prędkości — interpolacja czasu przekroczenia
            if z60  == nil, prevSpeed < 60,  v >= 60  { z60  = crossElapsed(60,  prevSpeed, v, pt, t, st) }
            if z100 == nil, prevSpeed < 100, v >= 100 { z100 = crossElapsed(100, prevSpeed, v, pt, t, st) }

            // Dystanse — interpolacja w obrębie dt
            if quarter == nil, prevDist < quarterMileM, distance >= quarterMileM {
                let frac = (quarterMileM - prevDist) / (distance - prevDist)
                quarter = pt.addingTimeInterval(dt * frac).timeIntervalSince(st)
                qTrap   = prevSpeed + (v - prevSpeed) * frac
            }
            if d400 == nil, prevDist < 400, distance >= 400 {
                let frac = (400 - prevDist) / (distance - prevDist)
                d400 = pt.addingTimeInterval(dt * frac).timeIntervalSince(st)
            }

            // Koniec: zatrzymanie
            if v < stopKmh {
                finishRun()
            }
        }

        refresh(speed: v, elapsed: currentElapsed(t))
    }

    private func currentElapsed(_ t: Date) -> Double {
        guard state == .running, let st = startTime else { return 0 }
        return t.timeIntervalSince(st)
    }

    private func crossElapsed(_ target: Double, _ vPrev: Double, _ vNow: Double,
                              _ tPrev: Date, _ tNow: Date, _ start: Date) -> Double {
        let frac = (target - vPrev) / (vNow - vPrev)
        return tPrev.addingTimeInterval(tNow.timeIntervalSince(tPrev) * frac).timeIntervalSince(start)
    }

    private func finishRun() {
        state = .armed
        // Zapisz tylko jeśli to był realny przejazd
        if runMax > 20 {
            let run = PerfRun(date: startTime ?? Date(),
                              zeroTo60: z60, zeroTo100: z100,
                              sixtyTo100: (z60 != nil && z100 != nil) ? z100! - z60! : nil,
                              quarterMile: quarter, quarterTrap: qTrap,
                              zeroTo400m: d400, maxSpeed: runMax)
            runs.insert(run, at: 0)
            if runs.count > 20 { runs.removeLast(runs.count - 20) }
            saveRuns()
        }
    }

    /// Ręczny reset bieżącego pomiaru (uzbrojenie od nowa).
    func resetCurrent() {
        state = .armed
        startTime = nil; distance = 0; runMax = 0
        z60 = nil; z100 = nil; quarter = nil; qTrap = nil; d400 = nil
        refresh(speed: prevSpeed, elapsed: 0)
    }

    func clearRuns() {
        runs.removeAll(); saveRuns()
    }

    // MARK: — Snapshot

    private func refresh(speed: Double, elapsed: Double) {
        let armed = state == .armed && speed < launchKmh
        let label: String
        switch state {
        case .running: label = String(localized: "POMIAR")
        case .armed:   label = armed ? String(localized: "NA STARCIE") : "—"
        }
        display = PerfSnapshot(
            stateLabel: label, armed: armed, running: state == .running,
            speed: speed, elapsed: elapsed, distance: distance,
            zeroTo60: z60, zeroTo100: z100, quarter: quarter, quarterTrap: qTrap,
            zeroTo400m: d400, maxSpeed: max(runMax, speed), lastRun: runs.first)
    }

    func snapshot() -> PerfSnapshot { display }

    // MARK: — Persistance

    private func saveRuns() {
        if let data = try? JSONEncoder().encode(runs) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
    private func loadRuns() {
        if let data = try? Data(contentsOf: fileURL),
           let r = try? JSONDecoder().decode([PerfRun].self, from: data) {
            runs = r
        }
    }
}
