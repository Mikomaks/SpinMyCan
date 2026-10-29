// KeyBindings.swift
// Konfigurowalne mapowanie joysticka per ekran + 2 sloty „Przejdź do".
// Domyślne keyId = fizyczny layout joysticka odkryty z pcapng (type 67).
// Wszystko zapisywane w UserDefaults — przeżywa restart.

import Foundation

// MARK: — Akcja ekranu

struct ScreenAction: Identifiable {
    let id: String          // stabilny klucz, np. "snake.up"
    let label: String
    let defaultKey: UInt8   // domyślny keyId (fizyczny przycisk)
}

extension DashboardScreen {
    /// Akcje istotne dla tego ekranu (bindowalne do przycisków).
    var actions: [ScreenAction] {
        switch self {
        // Uwaga: Back (0x0E) jest martwy — motocykl używa go do wyjścia z mySPIN.
        // Akcje „wyjście/kalibracja" odpalamy przez DŁUGIE przytrzymanie OK.
        case .classic: return [
            .init(id: "classic.prev",       label: "⏮ Poprzedni utwór", defaultKey: 0x20),
            .init(id: "classic.next",       label: "⏭ Następny utwór",  defaultKey: 0x21),
            .init(id: "classic.playpause",  label: "⏯ Play / Pause (OK)", defaultKey: 0x0C),
            .init(id: "classic.screenPrev", label: "▲ Poprzedni ekran", defaultKey: 0x1E),
            .init(id: "classic.screenNext", label: "▼ Następny ekran",  defaultKey: 0x1F),
        ]
        case .lean: return [
            .init(id: "lean.screenPrev", label: "▲ Poprzedni ekran",   defaultKey: 0x1E),
            .init(id: "lean.screenNext", label: "▼ Następny ekran",    defaultKey: 0x1F),
            .init(id: "lean.calibrate",  label: "⊙ Kalibracja (OK)",   defaultKey: 0x0C),
        ]
        case .snake: return [
            .init(id: "snake.up",      label: "Wąż: góra",         defaultKey: 0x1E),
            .init(id: "snake.down",    label: "Wąż: dół",          defaultKey: 0x1F),
            .init(id: "snake.left",    label: "Wąż: lewo",         defaultKey: 0x20),
            .init(id: "snake.right",   label: "Wąż: prawo",        defaultKey: 0x21),
            .init(id: "snake.restart", label: "Zagraj ponownie (OK)", defaultKey: 0x0C),
        ]
        case .sudoku: return [
            .init(id: "sudoku.up",    label: "Kursor góra / cyfra +",  defaultKey: 0x1E),
            .init(id: "sudoku.down",  label: "Kursor dół / cyfra −",   defaultKey: 0x1F),
            .init(id: "sudoku.left",  label: "Kursor lewo",            defaultKey: 0x20),
            .init(id: "sudoku.right", label: "Kursor prawo",           defaultKey: 0x21),
            .init(id: "sudoku.ok",    label: "Edytuj / zatwierdź (OK)", defaultKey: 0x0C),
        ]
        case .navigation: return [
            .init(id: "nav.screenPrev", label: "▲ Poprzedni ekran", defaultKey: 0x1E),
            .init(id: "nav.screenNext", label: "▼ Następny ekran",  defaultKey: 0x1F),
        ]
        case .performance: return [
            .init(id: "perf.screenPrev", label: "▲ Poprzedni ekran", defaultKey: 0x1E),
            .init(id: "perf.screenNext", label: "▼ Następny ekran",  defaultKey: 0x1F),
            .init(id: "perf.reset",      label: "Reset pomiaru",     defaultKey: 0x0C),
        ]
        case .video: return [
            .init(id: "video.back",       label: "◀ 10 s do tyłu",       defaultKey: 0x20),
            .init(id: "video.forward",    label: "▶ 10 s do przodu",     defaultKey: 0x21),
            .init(id: "video.playpause",  label: "⏯ Pauza / dalej (OK)", defaultKey: 0x0C),
            .init(id: "video.screenPrev", label: "▲ Poprzedni ekran",    defaultKey: 0x1E),
            .init(id: "video.screenNext", label: "▼ Następny ekran",     defaultKey: 0x1F),
        ]
        case .navClassic: return [
            .init(id: "navc.screenPrev", label: "▲ Poprzedni ekran", defaultKey: 0x1E),
            .init(id: "navc.screenNext", label: "▼ Następny ekran",  defaultKey: 0x1F),
        ]
        case .disco: return [
            .init(id: "disco.prev",       label: "⏮ Poprzedni utwór", defaultKey: 0x20),
            .init(id: "disco.next",       label: "⏭ Następny utwór",  defaultKey: 0x21),
            .init(id: "disco.playpause",  label: "⏯ Play / Pause (OK)", defaultKey: 0x0C),
            .init(id: "disco.screenPrev", label: "▲ Poprzedni ekran", defaultKey: 0x1E),
            .init(id: "disco.screenNext", label: "▼ Następny ekran",  defaultKey: 0x1F),
        ]
        case .hacker: return [
            .init(id: "hack.screenPrev", label: "▲ Poprzedni ekran", defaultKey: 0x1E),
            .init(id: "hack.screenNext", label: "▼ Następny ekran",  defaultKey: 0x1F),
        ]
        case .memories: return [
            .init(id: "mem.prev",       label: "⏮ Poprzednie zdjęcie", defaultKey: 0x20),
            .init(id: "mem.next",       label: "⏭ Następne zdjęcie",   defaultKey: 0x21),
            .init(id: "mem.screenPrev", label: "▲ Poprzedni ekran",    defaultKey: 0x1E),
            .init(id: "mem.screenNext", label: "▼ Następny ekran",     defaultKey: 0x1F),
        ]
        }
    }
}

// MARK: — Magazyn bindów (UserDefaults)

enum KeyBindings {

    // ── Akcje ──
    static func key(for action: ScreenAction, defaults: UserDefaults = .standard) -> UInt8 {
        if let v = defaults.object(forKey: "bind.\(action.id)") as? Int,
           let k = UInt8(exactly: v) { return k }
        return action.defaultKey
    }
    static func setActionKey(_ keyId: UInt8, actionId: String) {
        UserDefaults.standard.set(Int(keyId), forKey: "bind.\(actionId)")
    }
    /// Znajduje akcję przypisaną do danego keyId na danym ekranie.
    static func actionId(forKey keyId: UInt8, screen: DashboardScreen) -> String? {
        screen.actions.first { key(for: $0) == keyId }?.id
    }

    // ── Sloty „Przejdź do" (2 na ekran) ──
    static func gotoKey(screen: Int, slot: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "goto.\(screen).\(slot).key"))
    }
    static func setGotoKey(_ keyId: UInt8, screen: Int, slot: Int) {
        UserDefaults.standard.set(Int(keyId), forKey: "goto.\(screen).\(slot).key")
    }
    static func gotoTarget(screen: Int, slot: Int) -> Int {
        UserDefaults.standard.object(forKey: "goto.\(screen).\(slot).target") as? Int
            ?? DashboardScreen.classic.rawValue
    }
    static func setGotoTarget(_ target: Int, screen: Int, slot: Int) {
        UserDefaults.standard.set(target, forKey: "goto.\(screen).\(slot).target")
    }
    /// Cel „przejdź do" jeśli keyId pasuje do któregoś slotu (i jest przypisany). nil = brak.
    static func gotoTarget(forKey keyId: UInt8, screen: Int) -> Int? {
        for slot in 0..<2 {
            let k = gotoKey(screen: screen, slot: slot)
            if k != 0 && k == keyId { return gotoTarget(screen: screen, slot: slot) }
        }
        return nil
    }

    // ── Guzik podwójnego kliknięcia (akcja specjalna: kalibracja / wyjście) ──
    /// Domyślnie OK (0x0C). Per ekran — user wybiera który guzik.
    static func doubleKey(screen: Int) -> UInt8 {
        if let v = UserDefaults.standard.object(forKey: "dbl.\(screen)") as? Int,
           let k = UInt8(exactly: v) { return k }
        return 0x0C   // OK
    }
    static func setDoubleKey(_ keyId: UInt8, screen: Int) {
        UserDefaults.standard.set(Int(keyId), forKey: "dbl.\(screen)")
    }

    // ── Reset ──
    /// Jednorazowo (v1.18.1, prośba użytkownika): bez skrótów „Przejdź do ekranu” i ▲▼ =
    /// poprzedni / następny ekran wszędzie poza grami (w wężu i sudoku ▲▼ sterują grą).
    /// Inne akcje przypięte do ▲▼ wracają na swój domyślny przycisk.
    static func clearShortcutsOnce(defaults d: UserDefaults = .standard) {
        let flag = "migr.clearShortcuts.v1"
        guard !d.bool(forKey: flag) else { return }
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("goto.") { d.removeObject(forKey: k) }
        for screen in DashboardScreen.allCases where screen != .snake && screen != .sudoku {
            for a in screen.actions {
                let screenKey = a.id.hasSuffix(".screenPrev") || a.id.hasSuffix(".screenNext")
                if screenKey || [0x1E, 0x1F].contains(key(for: a, defaults: d)) {
                    d.removeObject(forKey: "bind.\(a.id)")
                }
            }
        }
        d.set(true, forKey: flag)
    }

    static func resetAll() {
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys
        where k.hasPrefix("bind.") || k.hasPrefix("goto.") || k.hasPrefix("dbl.") {
            d.removeObject(forKey: k)
        }
    }
}
