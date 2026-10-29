// SnakeGame.swift
// Ekrany dashboardu + gra Snake sterowana joystickiem motocykla.

import Foundation
import Combine

// MARK: — Ekrany dashboardu

enum DashboardScreen: Int, CaseIterable {
    case classic     = 0
    case lean        = 1
    case snake       = 2
    case sudoku      = 3
    case navigation  = 4
    case performance = 5
    case video       = 6
    case navClassic  = 7    // klasyk z mapą nawigacji na środku (zamiast prędkości)
    case disco       = 8    // tryb disco: duża okładka, RGB paski, motyw z albumu, karaoke lyrics
    case memories    = 9    // wspomnienia: slideshow zdjęć (tego dnia + ulubione + losowe) z przenikaniem
    case hacker      = 10   // terminal: surowe ramki CAN na żywo w stylu „hakera” (HackerScreen.swift)

    var title: String {
        switch self {
        case .classic:     return "Klasyczny"
        case .lean:        return "Lean — przechył"
        case .snake:       return "Snake 🐍"
        case .sudoku:      return "Sudoku 🔢"
        case .navigation:  return "Nawigacja 🗺️"
        case .performance: return "Pomiary 🏁"
        case .video:       return "Wideo 🎬"
        case .navClassic:  return "Nawigacja + deska 🧭"
        case .disco:       return "Disco 🪩"
        case .memories:    return "Wspomnienia 📸"
        case .hacker:      return "Terminal CAN 💻"
        }
    }
    var icon: String {
        switch self {
        case .classic:     return "gauge.with.dots.needle.bottom.50percent"
        case .lean:        return "motorcycle"
        case .snake:       return "gamecontroller"
        case .sudoku:      return "square.grid.3x3"
        case .navigation:  return "map.fill"
        case .performance: return "stopwatch"
        case .video:       return "play.rectangle.fill"
        case .navClassic:  return "location.north.line.fill"
        case .disco:       return "music.note"
        case .memories:    return "photo.stack"
        case .hacker:      return "terminal"
        }
    }
}

// MARK: — Snapshot stanu gry (czytany przez renderer na innym wątku)

struct SnakeSnapshot {
    let cols: Int
    let rows: Int
    let snake: [(Int, Int)]
    let food: (Int, Int)
    let score: Int
    let gameOver: Bool
    let started: Bool
}

// MARK: — Silnik gry Snake

final class SnakeGame: ObservableObject {

    let cols = 50
    let rows = 16

    private var snake: [(Int, Int)] = []
    private var food: (Int, Int) = (0, 0)
    private var dir: (Int, Int) = (1, 0)
    private var pendingDir: (Int, Int) = (1, 0)
    private(set) var score = 0
    private var gameOver = false
    private var started = false

    private var timer: DispatchSourceTimer?
    private let stepInterval = 0.16   // ~6 kroków/s

    // MARK: — Sterowanie cyklem życia

    /// Uruchamia grę od nowa (wywoływane gdy ekran Snake staje się aktywny).
    func start() {
        reset()
        runTimer()
    }

    func stop() {
        timer?.cancel(); timer = nil
    }

    private func reset() {
        let cy = rows / 2
        snake = [(6, cy), (5, cy), (4, cy)]
        dir = (1, 0); pendingDir = (1, 0)
        score = 0
        gameOver = false
        started = false
        placeFood()
    }

    // MARK: — Wejście z joysticka

    /// Zmiana kierunku (ignoruje zawrót o 180°). Pierwsza zmiana startuje ruch.
    func turn(_ d: (Int, Int)) {
        started = true
        if d.0 == -dir.0 && d.1 == -dir.1 { return }   // zakaz cofania w siebie
        pendingDir = d
    }

    /// OK — restart po przegranej.
    func okPressed() {
        if gameOver { reset() }
    }

    // MARK: — Pętla gry

    private func runTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + stepInterval, repeating: stepInterval, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.step() }
        t.resume()
        timer = t
    }

    private func step() {
        guard started, !gameOver else { return }
        dir = pendingDir
        let head = (snake[0].0 + dir.0, snake[0].1 + dir.1)

        // Kolizja ze ścianą
        if head.0 < 0 || head.0 >= cols || head.1 < 0 || head.1 >= rows {
            gameOver = true; return
        }
        // Kolizja z samym sobą
        if snake.contains(where: { $0 == head }) {
            gameOver = true; return
        }
        snake.insert(head, at: 0)
        if head == food {
            score += 1
            placeFood()
        } else {
            snake.removeLast()
        }
    }

    private func placeFood() {
        var f: (Int, Int)
        repeat {
            f = (Int.random(in: 0..<cols), Int.random(in: 0..<rows))
        } while snake.contains(where: { $0 == f })
        food = f
    }

    // MARK: — Snapshot dla renderera

    func snapshot() -> SnakeSnapshot {
        SnakeSnapshot(cols: cols, rows: rows, snake: snake, food: food,
                      score: score, gameOver: gameOver, started: started)
    }
}
