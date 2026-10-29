// CrashReporter.swift
// Trwała diagnostyka crashy „w terenie" (bez podłączonego Xcode/kabla).
//
// Co robi:
//  1. Łapie niewyłapane wyjątki (NSException) i sygnały (SIGABRT/SEGV/BUS/ILL/FPE/TRAP)
//     → zapisuje powód + stack + zużycie pamięci do Documents/last_crash.log
//  2. „Heartbeat" co 5 s zapisuje żywy timestamp + footprint pamięci do Documents/last_alive.log.
//     Jeśli iOS ubije apkę przez Jetsam (OOM) — TO NIE jest crash, brak sygnału —
//     ale last_alive.log pokaże ostatni footprint tuż przed śmiercią (rosnący = przeciek).
//  3. Na starcie przenosi raport z poprzedniego uruchomienia do Documents/crashes/
//     (bez pokazywania w apce — od v1.18.3 tylko do zgrania kablem, ostatnie 30).
//
// Diagnoza po fakcie:
//  • jest last_crash.log      → prawdziwy crash, powód w pliku
//  • brak crash.log, a apka wstała po nagłej śmierci, last_alive mem rósł → Jetsam/OOM
//
// Pull z urządzenia:
//  xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
//    --domain-identifier wassup.MySpin --source Documents/crashes --destination .

import Foundation
import Darwin

enum CrashReporter {

    private static var docs: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private static var crashURL: URL { docs.appendingPathComponent("last_crash.log") }
    private static var aliveURL: URL { docs.appendingPathComponent("last_alive.log") }

    private static var archiveDir: URL { docs.appendingPathComponent("crashes", isDirectory: true) }

    private static var heartbeat: DispatchSourceTimer?

    // MARK: — Instalacja (woła się raz, na starcie apki)

    static func install() {
        loadPreviousRunReport()

        NSSetUncaughtExceptionHandler { exc in
            let stack = exc.callStackSymbols.joined(separator: "\n")
            CrashReporter.write("""
            ⚠️ NSException: \(exc.name.rawValue)
            reason: \(exc.reason ?? "—")
            mem: \(CrashReporter.footprintMB()) MB
            \(stack)
            """)
        }

        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { s in
                // Best-effort (I/O w handlerze sygnału nie jest w 100% async-safe,
                // ale dla logu crashowego to standard). Zapisujemy powód + backtrace.
                let stack = Thread.callStackSymbols.joined(separator: "\n")
                CrashReporter.write("""
                💥 signal \(s) (\(CrashReporter.signalName(s)))
                mem: \(CrashReporter.footprintMB()) MB
                \(stack)
                """)
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    /// Start heartbeatu pamięci (woła się z ContentView.setup, na main).
    static func startHeartbeat() {
        guard heartbeat == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler {
            let line = "alive \(ISO8601DateFormatter().string(from: Date()))  mem=\(footprintMB())MB"
            try? line.write(to: aliveURL, atomically: true, encoding: .utf8)
        }
        t.resume()
        heartbeat = t
    }

    // MARK: — Zapis / odczyt

    private static func write(_ text: String) {
        let full = "=== MySpin crash @ \(ISO8601DateFormatter().string(from: Date())) ===\n\(text)\n"
        try? full.write(to: crashURL, atomically: true, encoding: .utf8)
    }

    private static func loadPreviousRunReport() {
        if let crash = try? String(contentsOf: crashURL, encoding: .utf8), !crash.isEmpty {
            archive(crash, kind: "crash")
            try? FileManager.default.removeItem(at: crashURL)
        } else if let alive = try? String(contentsOf: aliveURL, encoding: .utf8), !alive.isEmpty {
            // Brak crash logu, a był heartbeat: nagłe zakończenie — Jetsam/watchdog, ale też
            // zwykłe ubicie przez iOS w tle albo zamknięcie apki przez użytkownika.
            archive("Poprzednie uruchomienie skończyło się bez crash-logu (Jetsam/watchdog albo "
                    + "zwykłe zamknięcie).\nOstatni ślad życia:\n\(alive)", kind: "end")
        }
        try? FileManager.default.removeItem(at: aliveURL)
    }

    /// Raport do Documents/crashes/<kind>_<data>.log; zostaje 30 najnowszych.
    private static func archive(_ text: String, kind: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        try? text.write(to: archiveDir.appendingPathComponent("\(kind)_\(f.string(from: Date())).log"),
                        atomically: true, encoding: .utf8)
        let all = ((try? fm.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .sorted { $0.lastPathComponent.split(separator: "_").dropFirst().joined() > $1.lastPathComponent.split(separator: "_").dropFirst().joined() }
        for old in all.dropFirst(30) { try? fm.removeItem(at: old) }
    }

    // MARK: — Pamięć

    /// Fizyczny footprint procesu w MB (to samo, po czym Jetsam decyduje o ubiciu).
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / (1024 * 1024))
    }

    private static func signalName(_ s: Int32) -> String {
        switch s {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS:  return "SIGBUS"
        case SIGILL:  return "SIGILL"
        case SIGFPE:  return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        default:      return "sig\(s)"
        }
    }
}
