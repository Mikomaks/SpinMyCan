// SnakeGame.swift
// Dashboard screens + the Snake game driven by the motorcycle joystick.

import Foundation
import Combine

// MARK: — Ekrany dashboardu

enum DashboardScreen: Int, CaseIterable {
    case classic     = 0
    case lean        = 1
    case snake       = 2
    // 3 was Sudoku (removed in 1.23.0); raw values are saved on the phone, so the gap stays.
    case navigation  = 4
    case performance = 5
    case video       = 6
    case navClassic  = 7    // klasyk z mapą nawigacji na środku (zamiast prędkości)
    case disco       = 8    // tryb disco: duża okładka, RGB paski, motyw z albumu, karaoke lyrics
    case memories    = 9    // wspomnienia: slideshow zdjęć (tego dnia + ulubione + losowe) z przenikaniem
    case hacker      = 10   // terminal: surowe ramki CAN na żywo w stylu „hakera” (HackerScreen.swift)

    var title: String {
        switch self {
        case .classic:     return String(localized: "Klasyczny")
        case .lean:        return String(localized: "Lean — przechył")
        case .snake:       return String(localized: "Snake 🐍")
        case .navigation:  return String(localized: "Nawigacja 🗺️")
        case .performance: return String(localized: "Pomiary 🏁")
        case .video:       return String(localized: "Wideo 🎬")
        case .navClassic:  return String(localized: "Nawigacja + deska 🧭")
        case .disco:       return String(localized: "Disco 🪩")
        case .memories:    return String(localized: "Wspomnienia 📸")
        case .hacker:      return String(localized: "Terminal CAN 💻")
        }
    }
    var icon: String {
        switch self {
        case .classic:     return "gauge.with.dots.needle.bottom.50percent"
        case .lean:        return "motorcycle"
        case .snake:       return "gamecontroller"
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

// MARK: — Game state snapshot (read by the renderer on another thread)

struct SnakeSnapshot {
    let cols: Int
    let rows: Int
    let snake: [(Int, Int)]
    let food: (Int, Int)
    let score: Int
    let gameOver: Bool
    let started: Bool
    var best = 0            // best score ever (saved on the phone)
    var won = false         // the whole board is filled
    var newRecord = false   // this game beat the previous best
}

// MARK: — Snake engine

/// The timer steps the game on the main queue, the joystick and the renderer call in from
/// other threads — every access to the state goes through `lock`.
final class SnakeGame: ObservableObject {

    let cols = 50
    let rows = 16

    static let bestKey = "snake.best"
    /// Step interval: starts slow, gets a little faster with every point, down to `minInterval`.
    static let baseInterval = 0.16
    static let minInterval = 0.09
    static func interval(score: Int) -> Double {
        max(minInterval, baseInterval - 0.002 * Double(score))
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var snake: [(Int, Int)] = []
    private var food: (Int, Int) = (0, 0)
    private var dir: (Int, Int) = (1, 0)
    /// Turns waiting for the next steps (at most two), so a quick ▲◀ U-turn is not lost.
    private var queued: [(Int, Int)] = []
    private var score = 0
    private var best = 0
    private var gameOver = false
    private var won = false
    private var newRecord = false
    private var started = false

    private var timer: DispatchSourceTimer?
    private var timerInterval = 0.0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        best = defaults.integer(forKey: Self.bestKey)
        reset()
    }

    // MARK: — Lifecycle

    /// Starts a fresh game (called when the Snake screen becomes active).
    func start() {
        reset()
        runTimer(Self.baseInterval)
    }

    func stop() {
        timer?.cancel(); timer = nil
    }

    private func reset() {
        lock.lock(); defer { lock.unlock() }
        let cy = rows / 2
        snake = [(6, cy), (5, cy), (4, cy)]
        dir = (1, 0); queued = []
        score = 0
        gameOver = false; won = false; newRecord = false
        started = false
        placeFood()
    }

    // MARK: — Joystick input

    /// Change of direction. The first press starts the game. A turn back into the snake and
    /// a repeat of the direction already taken are ignored.
    func turn(_ d: (Int, Int)) {
        lock.lock(); defer { lock.unlock() }
        guard !gameOver else { return }
        started = true
        let last = queued.last ?? dir
        if d == last || (d.0 == -last.0 && d.1 == -last.1) { return }
        if queued.count < 2 { queued.append(d) }
    }

    /// OK — play again after a lost (or won) game.
    func okPressed() {
        lock.lock(); let over = gameOver; lock.unlock()
        if over { reset() }      // the timer keeps running and picks the start speed up itself
    }

    // MARK: — Game loop

    private func runTimer(_ interval: Double) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(10))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.step()
            let next = Self.interval(score: self.snapshot().score)
            if next != self.timerInterval, self.timer != nil { self.runTimer(next) }
        }
        t.resume()
        timer = t
        timerInterval = interval
    }

    /// One move. Internal (not private) so the self-test can drive the game without a timer.
    func step() {
        lock.lock(); defer { lock.unlock() }
        guard started, !gameOver else { return }
        if !queued.isEmpty { dir = queued.removeFirst() }
        let head = (snake[0].0 + dir.0, snake[0].1 + dir.1)

        // Wall
        if head.0 < 0 || head.0 >= cols || head.1 < 0 || head.1 >= rows {
            finish(); return
        }
        let grows = head == food
        // Own body. The tail cell is free unless the snake grows — the tail moves away this step.
        let body = grows ? snake[...] : snake.dropLast()
        if body.contains(where: { $0 == head }) {
            finish(); return
        }
        snake.insert(head, at: 0)
        if grows {
            score += 1
            if snake.count == cols * rows { won = true; finish(); return }
            placeFood()
        } else {
            snake.removeLast()
        }
    }

    /// Ends the game and saves a new record. Call with `lock` held.
    private func finish() {
        gameOver = true
        if score > best {
            best = score
            newRecord = true
            defaults.set(best, forKey: Self.bestKey)
        }
    }

    /// Call with `lock` held; the board must have a free cell.
    private func placeFood() {
        var f: (Int, Int)
        repeat {
            f = (Int.random(in: 0..<cols), Int.random(in: 0..<rows))
        } while snake.contains(where: { $0 == f })
        food = f
    }

    /// Self-test only: puts the food in a known cell.
    func setFood(_ f: (Int, Int)) {
        lock.lock(); food = f; lock.unlock()
    }

    // MARK: — Snapshot for the renderer

    func snapshot() -> SnakeSnapshot {
        lock.lock(); defer { lock.unlock() }
        return SnakeSnapshot(cols: cols, rows: rows, snake: snake, food: food,
                             score: score, gameOver: gameOver, started: started, best: best, won: won, newRecord: newRecord)
    }
}
