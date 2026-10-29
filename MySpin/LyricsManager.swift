// LyricsManager.swift
// Synchronizowane teksty (karaoke) z LRCLIB — darmowe, bez klucza API.
// Spotify NIE udostępnia tekstów, więc bierzemy je z lrclib.net po
// tytule + artyście + długości utworu. Zwraca LRC z timestampami →
// renderer podświetla bieżącą linijkę wg postępu odtwarzania (npElapsed).
//
// Endpoint:  GET https://lrclib.net/api/get?artist_name=..&track_name=..&duration=..
// Fallback:  GET https://lrclib.net/api/search?q=..  (bierze 1. z syncedLyrics)

import Foundation
import Combine

/// Jedna linijka tekstu z czasem startu (sekundy).
struct LyricLine {
    let time: Double
    let text: String
}

final class LyricsManager: ObservableObject {

    // Stan chroniony zamkiem — czytany z wątku renderującego (tło), pisany z sieci/main.
    // Bez zamka cross-thread odczyt tablicy = ryzyko wyścigu (jak w MotionManager).
    private let lock = NSLock()
    private var _lines:  [LyricLine] = []
    private var _status: String      = ""

    /// Bezpieczny snapshot dla renderera (wołany z wątku tła).
    func snapshot() -> (lines: [LyricLine], status: String) {
        lock.lock(); defer { lock.unlock() }
        return (_lines, _status)
    }
    private func setState(lines: [LyricLine], status: String) {
        lock.lock(); _lines = lines; _status = status; lock.unlock()
    }

    private var lastKey: String = ""          // "artist|title" — nie pobieraj tego samego dwa razy
    private let keyLock = NSLock()            // update() bywa wołane z wątku tła (frameProvider)
    private var task: URLSessionDataTask?

    /// Woła się przy zmianie utworu (z frameProvider). Debounce po kluczu, thread-safe.
    func update(title: String, artist: String, duration: Double) {
        guard !title.isEmpty else { clear(); return }
        let key = "\(artist)|\(title)".lowercased()
        keyLock.lock()
        let changed = key != lastKey
        if changed { lastKey = key }
        keyLock.unlock()
        guard changed else { return }          // ten sam utwór — już mamy (albo w toku)
        DispatchQueue.main.async { self.fetch(title: title, artist: artist, duration: duration) }
    }

    private func clear() {
        keyLock.lock(); lastKey = ""; keyLock.unlock()
        setState(lines: [], status: "")
    }

    // MARK: — Fetch

    private func fetch(title: String, artist: String, duration: Double) {
        task?.cancel()
        setState(lines: [], status: "szukam tekstu…")

        // 1) dokładne dopasowanie po /get (artysta+tytuł+czas)
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name",  value: title),
            URLQueryItem(name: "duration",    value: String(Int(duration.rounded()))),
        ]
        request(c.url) { [weak self] obj in
            guard let self else { return }
            if let obj, let parsed = self.parse(obj), !parsed.isEmpty {
                self.publish(parsed)
            } else {
                // 2) fallback: /search po samym „artysta tytuł"
                self.search(title: title, artist: artist)
            }
        }
    }

    private func search(title: String, artist: String) {
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [URLQueryItem(name: "q", value: "\(artist) \(title)")]
        request(c.url) { [weak self] obj in
            guard let self else { return }
            // /search zwraca tablicę — weź pierwszy wpis z syncedLyrics
            if let arr = obj as? [[String: Any]],
               let first = arr.first(where: { ($0["syncedLyrics"] as? String)?.isEmpty == false }),
               let parsed = self.parse(first), !parsed.isEmpty {
                self.publish(parsed)
            } else {
                self.setState(lines: [], status: "brak tekstu")
            }
        }
    }

    private func request(_ url: URL?, done: @escaping (Any?) -> Void) {
        guard let url else { done(nil); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        // LRCLIB prosi o identyfikujący User-Agent.
        req.setValue("MySpin/1.0 (motorcycle dashboard; github.com/mikomaks)", forHTTPHeaderField: "User-Agent")
        task = URLSession.shared.dataTask(with: req) { data, _, _ in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            DispatchQueue.main.async { done(obj) }
        }
        task?.resume()
    }

    // MARK: — Parsowanie odpowiedzi

    private func parse(_ obj: Any) -> [LyricLine]? {
        guard let dict = obj as? [String: Any] else { return nil }
        if (dict["instrumental"] as? Bool) == true {
            setState(lines: [], status: "instrumental 🎸")
            return []
        }
        guard let lrc = dict["syncedLyrics"] as? String, !lrc.isEmpty else { return nil }
        return Self.parseLRC(lrc)
    }

    private func publish(_ parsed: [LyricLine]) {
        setState(lines: parsed, status: parsed.isEmpty ? "brak tekstu" : "")
    }

    /// Parsuje format LRC: "[mm:ss.xx] tekst" (linia może mieć kilka znaczników czasu).
    static func parseLRC(_ lrc: String) -> [LyricLine] {
        var out: [LyricLine] = []
        let tag = try! NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#)
        for raw in lrc.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let range = NSRange(line.startIndex..., in: line)
            let matches = tag.matches(in: line, range: range)
            guard !matches.isEmpty else { continue }
            // Tekst = wszystko po ostatnim znaczniku czasu
            let text = line[Range(matches.last!.range, in: line)!.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            for m in matches {
                guard let mmR = Range(m.range(at: 1), in: line),
                      let ssR = Range(m.range(at: 2), in: line),
                      let mm = Double(line[mmR]), let ss = Double(line[ssR]) else { continue }
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound, let fR = Range(m.range(at: 3), in: line) {
                    let fs = String(line[fR]); frac = (Double(fs) ?? 0) / pow(10, Double(fs.count))
                }
                out.append(LyricLine(time: mm * 60 + ss + frac, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }
}
