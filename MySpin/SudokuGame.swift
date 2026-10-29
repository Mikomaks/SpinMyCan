// SudokuGame.swift
// Ekran Sudoku sterowany joystickiem motocykla.
// • Generowanie lokalne (offline) z gwarantowanym unikalnym rozwiązaniem
// • Persistance na każdy ruch (plik JSON) — wraca dokładnie tam gdzie skończyłeś
//
// Sterowanie:
//   Nawigacja: d-pad rusza kursorem, OK = edycja komórki, Back = wyjście z ekranu
//   Edycja:    Góra/Dół zmienia cyfrę (0 = puste), OK = zatwierdź, Back = anuluj

import Foundation
import Combine

// MARK: — Trudność

enum SudokuDifficulty: Int, CaseIterable, Codable {
    case easy = 0, medium = 1, hard = 2, expert = 3
    var givens: Int { [45, 35, 30, 26][rawValue] }
    var title: String { ["Łatwy", "Średni", "Trudny", "Ekspert"][rawValue] }
}

// MARK: — Snapshot dla renderera (czytany na innym wątku)

struct SudokuSnapshot {
    let givens:     [Int]      // 0 = nie-podpowiedź (edytowalne)
    let entries:    [Int]      // bieżący stan 0..9
    let cursor:     Int
    let editing:    Bool
    let conflicts:  Set<Int>
    let completed:  Set<Int>    // komórki należące do w pełni poprawnego wiersza/kolumny/boxa
    let solved:     Bool
    let generating: Bool
    let difficulty: String
    let filled:     Int
    let source:     String      // "Losowa" / "Dnia" / "Online"
}

// MARK: — Seedowalny RNG (SplitMix64) — deterministyczna „plansza dnia"

struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: — Generator (backtracking + usuwanie z kontrolą unikalności)

enum SudokuGenerator {

    static func valid(_ g: [Int], _ idx: Int, _ n: Int) -> Bool {
        let r = idx / 9, c = idx % 9
        for i in 0..<9 {
            if g[r*9 + i] == n { return false }
            if g[i*9 + c] == n { return false }
        }
        let br = (r/3)*3, bc = (c/3)*3
        for dr in 0..<3 { for dc in 0..<3 {
            if g[(br+dr)*9 + (bc+dc)] == n { return false }
        }}
        return true
    }

    /// Wypełnia pełną poprawną siatkę (losowo, sterowane RNG).
    private static func fill<R: RandomNumberGenerator>(_ g: inout [Int], using rng: inout R) -> Bool {
        guard let idx = g.firstIndex(of: 0) else { return true }
        for n in [1,2,3,4,5,6,7,8,9].shuffled(using: &rng) where valid(g, idx, n) {
            g[idx] = n
            if fill(&g, using: &rng) { return true }
            g[idx] = 0
        }
        return false
    }

    /// Liczy rozwiązania do `limit` (MRV — szybkie nawet dla rzadkich siatek).
    private static func countSolutions(_ grid: [Int], limit: Int) -> Int {
        var g = grid
        var count = 0
        func solve() -> Bool {   // true = osiągnięto limit
            var best = -1
            var bestCands: [Int] = []
            for idx in 0..<81 where g[idx] == 0 {
                var cands: [Int] = []
                for n in 1...9 where valid(g, idx, n) { cands.append(n) }
                if cands.isEmpty { return false }
                if best == -1 || cands.count < bestCands.count {
                    best = idx; bestCands = cands
                    if cands.count == 1 { break }
                }
            }
            if best == -1 { count += 1; return count >= limit }
            for n in bestCands {
                g[best] = n
                if solve() { g[best] = 0; return true }
                g[best] = 0
            }
            return false
        }
        _ = solve()
        return count
    }

    /// Zwraca (plansza z podpowiedziami, pełne rozwiązanie) — sterowane RNG.
    static func generate<R: RandomNumberGenerator>(givens targetGivens: Int, using rng: inout R) -> (puzzle: [Int], solution: [Int]) {
        var grid = [Int](repeating: 0, count: 81)
        _ = fill(&grid, using: &rng)
        let solution = grid

        var puzzle = grid
        let toRemove = 81 - targetGivens
        var removed = 0
        for c in Array(0..<81).shuffled(using: &rng) {
            if removed >= toRemove { break }
            let backup = puzzle[c]
            puzzle[c] = 0
            if countSolutions(puzzle, limit: 2) != 1 {
                puzzle[c] = backup       // usunięcie złamałoby unikalność
            } else {
                removed += 1
            }
        }
        return (puzzle, solution)
    }

    /// Wariant losowy (systemowy RNG).
    static func generate(givens targetGivens: Int) -> (puzzle: [Int], solution: [Int]) {
        var rng = SystemRandomNumberGenerator()
        return generate(givens: targetGivens, using: &rng)
    }
}

// MARK: — Gra

final class SudokuGame: ObservableObject {

    @Published private(set) var display: SudokuSnapshot

    private var givens:     [Int] = Array(repeating: 0, count: 81)
    private var entries:    [Int] = Array(repeating: 0, count: 81)
    private var solution:   [Int] = Array(repeating: 0, count: 81)
    private var cursor:     Int = 40
    private var editing:    Bool = false
    private var generating: Bool = false
    private var source: String = "Losowa"
    private(set) var difficulty: SudokuDifficulty = .medium

    /// Komunikat dla UI (np. błąd pobierania) — czyszczony po chwili.
    @Published var note: String = ""

    var isEditing: Bool { editing }

    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("sudoku_state.json")
    }

    init() {
        display = SudokuSnapshot(givens: givens, entries: entries, cursor: cursor,
                                 editing: false, conflicts: [], completed: [], solved: false,
                                 generating: false, difficulty: difficulty.title, filled: 0,
                                 source: source)
        if !load() {
            newGame(.medium)
        } else {
            refresh()
        }
    }

    // MARK: — Nowa gra

    func newGame(_ diff: SudokuDifficulty) {
        difficulty = diff
        source = "Losowa"
        generating = true
        editing = false
        refresh()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let (puzzle, sol) = SudokuGenerator.generate(givens: diff.givens)
            DispatchQueue.main.async {
                self.applyPuzzle(puzzle, solution: sol, difficulty: diff, source: "Losowa")
            }
        }
    }

    /// Plansza dnia — deterministyczna z daty. Ten sam puzzle dla wszystkich danego dnia.
    /// Trudność rośnie w tygodniu (jak w gazetach): pn/wt łatwy → sob/nd ekspert.
    func dailyGame() {
        let cal = Calendar.current
        let now = Date()
        let y = cal.component(.year,  from: now)
        let m = cal.component(.month, from: now)
        let d = cal.component(.day,   from: now)
        let seed = UInt64(y * 10000 + m * 100 + d)
        let weekday = cal.component(.weekday, from: now)   // 1=niedziela ... 7=sobota
        let byDay: [SudokuDifficulty] = [.expert, .easy, .easy, .medium, .medium, .hard, .expert]
        let diff = byDay[weekday - 1]

        difficulty = diff
        source = "Dnia"
        generating = true
        editing = false
        refresh()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var rng = SeededRNG(seed: seed)
            let (puzzle, sol) = SudokuGenerator.generate(givens: diff.givens, using: &rng)
            DispatchQueue.main.async {
                self.applyPuzzle(puzzle, solution: sol, difficulty: diff, source: "Dnia")
            }
        }
    }

    /// Pobiera planszę z internetu (Dosuku API). Fallback na lokalną gdy brak neta.
    func fetchOnline() {
        source = "Online"
        generating = true
        editing = false
        note = ""
        refresh()
        guard let url = URL(string: "https://sudoku-api.vercel.app/api/dosuku") else {
            failOnline(); return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self else { return }
            guard let data, err == nil,
                  let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let nb    = json["newboard"] as? [String: Any],
                  let grids = nb["grids"] as? [[String: Any]],
                  let g0    = grids.first,
                  let value = g0["value"]    as? [[Int]],
                  let sol   = g0["solution"] as? [[Int]],
                  value.count == 9, sol.count == 9
            else {
                DispatchQueue.main.async { self.failOnline() }
                return
            }
            let puzzle   = value.flatMap { $0 }
            let solution = sol.flatMap { $0 }
            let diffStr  = (g0["difficulty"] as? String ?? "").lowercased()
            let diff: SudokuDifficulty = diffStr.contains("hard") ? .hard
                : (diffStr.contains("medium") ? .medium : .easy)
            DispatchQueue.main.async {
                self.applyPuzzle(puzzle, solution: solution, difficulty: diff, source: "Online")
            }
        }.resume()
    }

    private func failOnline() {
        note = "Brak internetu — generuję planszę lokalnie"
        newGame(difficulty)
    }

    private func applyPuzzle(_ puzzle: [Int], solution sol: [Int],
                             difficulty diff: SudokuDifficulty, source src: String) {
        givens     = puzzle
        entries    = puzzle
        solution   = sol
        difficulty = diff
        source     = src
        cursor     = puzzle.firstIndex(of: 0) ?? 40
        editing    = false
        generating = false
        refresh()
    }

    // MARK: — Wejście z joysticka

    func up()   { if editing { changeNumber(+1) } else { moveCursor(-1, 0) } }
    func down() { if editing { changeNumber(-1) } else { moveCursor(+1, 0) } }
    func left()  { moveCursor(0, -1) }     // moveCursor wychodzi z edycji
    func right() { moveCursor(0,  1) }

    /// OK — wejście/wyjście z edycji bieżącej komórki (tylko nie-podpowiedzi).
    func okPressed() {
        guard !generating else { return }
        if editing {
            editing = false
        } else if givens[cursor] == 0 {
            editing = true
        }
        refresh()
    }

    /// Back podczas edycji — wyjście bez ruchu.
    func cancelEdit() {
        if editing { editing = false; refresh() }
    }

    private func moveCursor(_ dRow: Int, _ dCol: Int) {
        guard !generating else { return }
        editing = false
        let r = max(0, min(8, cursor/9 + dRow))
        let c = max(0, min(8, cursor%9 + dCol))
        cursor = r*9 + c
        refresh()
    }

    private func changeNumber(_ delta: Int) {
        guard givens[cursor] == 0 else { return }
        entries[cursor] = (entries[cursor] + delta + 10) % 10
        refresh()
    }

    // MARK: — Obliczenia + snapshot + zapis

    private func conflictSet() -> Set<Int> {
        var conflicts = Set<Int>()
        for idx in 0..<81 {
            let v = entries[idx]
            guard v != 0 else { continue }
            let r = idx/9, c = idx%9
            for i in 0..<9 {
                let rowI = r*9 + i, colI = i*9 + c
                if rowI != idx && entries[rowI] == v { conflicts.insert(idx); conflicts.insert(rowI) }
                if colI != idx && entries[colI] == v { conflicts.insert(idx); conflicts.insert(colI) }
            }
            let br = (r/3)*3, bc = (c/3)*3
            for dr in 0..<3 { for dc in 0..<3 {
                let bi = (br+dr)*9 + (bc+dc)
                if bi != idx && entries[bi] == v { conflicts.insert(idx); conflicts.insert(bi) }
            }}
        }
        return conflicts
    }

    /// Komórki należące do wiersza/kolumny/boxa, który jest w pełni wypełniony
    /// i zgodny z rozwiązaniem (do podświetlenia na zielono).
    private func completedSet() -> Set<Int> {
        guard solution.contains(where: { $0 != 0 }) else { return [] }
        var done = Set<Int>()
        // Wiersze
        for r in 0..<9 {
            if (0..<9).allSatisfy({ c in entries[r*9+c] != 0 && entries[r*9+c] == solution[r*9+c] }) {
                for c in 0..<9 { done.insert(r*9+c) }
            }
        }
        // Kolumny
        for c in 0..<9 {
            if (0..<9).allSatisfy({ r in entries[r*9+c] != 0 && entries[r*9+c] == solution[r*9+c] }) {
                for r in 0..<9 { done.insert(r*9+c) }
            }
        }
        // Boxy 3×3
        for br in 0..<3 { for bc in 0..<3 {
            var ok = true
            for dr in 0..<3 { for dc in 0..<3 {
                let i = (br*3+dr)*9 + (bc*3+dc)
                if entries[i] == 0 || entries[i] != solution[i] { ok = false }
            }}
            if ok { for dr in 0..<3 { for dc in 0..<3 { done.insert((br*3+dr)*9 + (bc*3+dc)) } } }
        }}
        return done
    }

    private func refresh() {
        let conflicts = conflictSet()
        let completed = completedSet()
        let filled = entries.filter { $0 != 0 }.count
        let solved = !generating && entries == solution
        display = SudokuSnapshot(
            givens: givens, entries: entries, cursor: cursor, editing: editing,
            conflicts: conflicts, completed: completed, solved: solved, generating: generating,
            difficulty: difficulty.title, filled: filled, source: source)
        save()
    }

    func snapshot() -> SudokuSnapshot { display }

    // MARK: — Persistance

    private struct SudokuState: Codable {
        var givens: [Int]; var entries: [Int]; var solution: [Int]
        var cursor: Int; var difficulty: Int; var source: String?
    }

    private func save() {
        let st = SudokuState(givens: givens, entries: entries, solution: solution,
                             cursor: cursor, difficulty: difficulty.rawValue, source: source)
        if let data = try? JSONEncoder().encode(st) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    @discardableResult
    private func load() -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let st = try? JSONDecoder().decode(SudokuState.self, from: data),
              st.givens.count == 81, st.entries.count == 81, st.solution.count == 81
        else { return false }
        givens     = st.givens
        entries    = st.entries
        solution   = st.solution
        cursor     = min(80, max(0, st.cursor))
        difficulty = SudokuDifficulty(rawValue: st.difficulty) ?? .medium
        source     = st.source ?? "Losowa"
        editing    = false
        return true
    }
}
