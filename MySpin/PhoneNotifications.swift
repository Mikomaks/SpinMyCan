// PhoneNotifications.swift
// Phone notifications on the dash and the quick menu — logic only (no drawing, no Bluetooth).
// Description for people: docs/NOTIFICATIONS.md. Everything here is covered by FeatureSelfTest.
//
//   AncsClient   — talks the Apple Notification Center Service protocol through the CAN board
//                  (firmware v12+, phone_notif.h): turns the raw bytes into notifications.
//   DashOverlay  — what is on top of the dashboard right now: the notification banner and
//                  the quick menu, their timing and what the joystick does to them.
//   QuickMenu    — the settings offered in the quick menu.

import Foundation
import CoreGraphics

// MARK: — Notification

struct DashNotification: Equatable {
    var uid: UInt32
    var category: UInt8 = 0     // ANCS category: 1 incoming call, 2 missed call, 4 social (messages) …
    var appId = ""
    var appName = ""
    var title = ""              // usually the sender
    var subtitle = ""
    var message = ""

    var isCall: Bool { category == 1 }

    /// Sample notifications for the "show a test notification" button and for screenshots.
    static func demo(_ n: Int) -> DashNotification {
        let samples: [(UInt8, String, String, String)] = [
            (4, String(localized: "Wiadomości"), "Kasia", String(localized: "Będę za 10 minut. Kupić coś po drodze? Mogę wziąć pieczywo i coś na kolację.")),
            (1, String(localized: "Telefon"), "Marek", String(localized: "Połączenie przychodzące")),
            (4, "WhatsApp", String(localized: "Ekipa na niedzielę"), String(localized: "Tomek: Wyjazd o 9:00 spod stacji, trasa na Zakopane przez Nowy Targ. Kto jedzie?")),
        ]
        let s = samples[((n % samples.count) + samples.count) % samples.count]
        return DashNotification(uid: 0xD000_0000 &+ UInt32(truncatingIfNeeded: n), category: s.0,
                                appId: "demo", appName: s.1, title: s.2, message: s.3)
    }
}

// MARK: — State of the relay in the board

enum NotifLinkState: Equatable {
    case unsupported        // board not connected or its firmware is older than v12
    case off
    case pairing            // waiting for the pairing request to be accepted on the phone
    case discovering
    case ready
    case failed(UInt8)      // reason from phone_notif.h

    init(board state: UInt8, reason: UInt8) {
        switch state {
        case 0: self = .off
        case 1: self = .pairing
        case 2: self = .discovering
        case 3: self = .ready
        default: self = .failed(reason)
        }
    }

    var text: String {
        switch self {
        case .unsupported: return String(localized: "Płytka niepołączona albo ma za stary program (potrzebny v12).")
        case .off:         return String(localized: "Wyłączone.")
        case .pairing:     return String(localized: "Zaakceptuj prośbę o parowanie na telefonie…")
        case .discovering: return String(localized: "Łączę z powiadomieniami telefonu…")
        case .ready:       return String(localized: "Działa — powiadomienia trafiają na deskę.")
        case .failed(1):   return String(localized: "Parowanie odrzucone albo nieudane. Wyłącz i włącz przełącznik; jeśli to nie pomoże, usuń płytkę w Ustawienia → Bluetooth i spróbuj ponownie.")
        case .failed(2), .failed(3), .failed(4):
            return String(localized: "Telefon nie udostępnia płytce powiadomień. W Ustawienia → Bluetooth → MySpin-CAN (i) włącz „Udostępniaj powiadomienia systemowe”.")
        case .failed(5):   return String(localized: "Nikt nie zaakceptował parowania. Wyłącz i włącz przełącznik, potem potwierdź na telefonie.")
        case .failed:      return String(localized: "Nie udało się włączyć powiadomień.")
        }
    }
    var isProblem: Bool { if case .failed = self { return true }; return self == .unsupported }
}

// MARK: — ANCS client

/// One side of the ANCS conversation. Bytes in (`source`, `data`), commands and finished
/// notifications out. Asks for the details of one notification at a time and gives up on
/// an answer that does not come.
struct AncsClient {
    enum Output: Equatable {
        case write([UInt8])             // command for the ANCS control point
        case post(DashNotification)
        case remove(UInt32)             // the notification is gone from the phone
    }

    static let timeout: TimeInterval = 4
    static let maxTitle: UInt16 = 64
    static let maxMessage: UInt16 = 400

    /// true = only calls and messages; false = every notification that makes the phone alert.
    var messagesOnly = true

    private enum Waiting {
        case attributes(uid: UInt32, category: UInt8)
        case appName(DashNotification)
    }
    private var queue: [(uid: UInt32, category: UInt8)] = []
    private var waiting: Waiting?
    private var waitingSince: TimeInterval = 0
    private var stream: [UInt8] = []
    private var cancelled = Set<UInt32>()
    private var appNames: [String: String] = [:]

    mutating func reset() {
        queue = []; waiting = nil; stream = []; cancelled = []
    }

    static func wanted(category: UInt8, messagesOnly: Bool) -> Bool {
        !messagesOnly || category == 1 || category == 2 || category == 4
    }

    /// Notification Source packet (8 bytes): event, flags, category, count, UID.
    mutating func source(_ p: [UInt8], now: TimeInterval) -> [Output] {
        guard p.count >= 8 else { return [] }
        let event = p[0], flags = p[1], category = p[2]
        let uid = UInt32(p[4]) | UInt32(p[5]) << 8 | UInt32(p[6]) << 16 | UInt32(p[7]) << 24
        if event == 2 {                                    // removed
            queue.removeAll { $0.uid == uid }
            if case .attributes(let u, _)? = waiting, u == uid { cancelled.insert(uid) }
            if case .appName(let n)? = waiting, n.uid == uid { cancelled.insert(uid) }
            return [.remove(uid)]
        }
        // Silent (0x01) = the phone itself does not alert; pre-existing (0x04) = it was there
        // before we connected. Neither is news for the rider.
        guard event <= 1, flags & 0x05 == 0, Self.wanted(category: category, messagesOnly: messagesOnly) else { return [] }
        if !queue.contains(where: { $0.uid == uid }) { queue.append((uid, category)) }
        return next(now)
    }

    /// Next piece of the Data Source stream (answers to our commands, possibly in fragments).
    mutating func data(_ p: [UInt8], now: TimeInterval) -> [Output] {
        guard let w = waiting else { stream = []; return [] }
        stream += p
        switch w {
        case .attributes(let uid, let category):
            guard let a = Self.parseAttributes(stream, uid: uid, count: 4) else {
                // Not ours at all (wrong command or UID) — throw the bytes away and wait for the timeout.
                if let h = Self.header(stream), h.0 != 0 || h.1 != uid { stream = [] }
                return []
            }
            stream = []; waiting = nil
            if cancelled.remove(uid) != nil { return next(now) }
            var n = DashNotification(uid: uid, category: category,
                                     appId: a[0] ?? "", title: a[1] ?? "", subtitle: a[2] ?? "", message: a[3] ?? "")
            if let name = appNames[n.appId] ?? Self.builtInName(n.appId) {
                n.appName = name
                return [.post(n)] + next(now)
            }
            waiting = .appName(n); waitingSince = now
            return [.write([0x01] + Array(n.appId.utf8) + [0x00, 0x00])]       // Get App Attributes: display name
        case .appName(var n):
            guard let name = Self.parseAppName(stream, appId: n.appId) else { return [] }
            stream = []; waiting = nil
            n.appName = name.isEmpty ? Self.fallbackName(n.appId) : name
            appNames[n.appId] = n.appName
            if cancelled.remove(n.uid) != nil { return next(now) }
            return [.post(n)] + next(now)
        }
    }

    /// Call regularly: gives up on an answer that did not come and moves on.
    mutating func tick(now: TimeInterval) -> [Output] {
        guard let w = waiting, now - waitingSince > Self.timeout else { return [] }
        waiting = nil; stream = []
        var out: [Output] = []
        if case .appName(var n) = w, cancelled.remove(n.uid) == nil {
            n.appName = Self.fallbackName(n.appId)          // the notification itself is complete
            out.append(.post(n))
        }
        return out + next(now)
    }

    private mutating func next(_ now: TimeInterval) -> [Output] {
        guard waiting == nil, !queue.isEmpty else { return [] }
        let (uid, category) = queue.removeFirst()
        waiting = .attributes(uid: uid, category: category); waitingSince = now
        stream = []
        return [.write(Self.attributesCommand(uid))]
    }

    /// Get Notification Attributes: app identifier, title, subtitle, message (with length limits).
    static func attributesCommand(_ uid: UInt32) -> [UInt8] {
        func le(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        return [0x00, UInt8(uid & 0xFF), UInt8((uid >> 8) & 0xFF), UInt8((uid >> 16) & 0xFF), UInt8(uid >> 24), 0x00]
            + [0x01] + le(maxTitle) + [0x02] + le(maxTitle) + [0x03] + le(maxMessage)
    }

    private static func header(_ b: [UInt8]) -> (UInt8, UInt32)? {
        guard b.count >= 5 else { return nil }
        return (b[0], UInt32(b[1]) | UInt32(b[2]) << 8 | UInt32(b[3]) << 16 | UInt32(b[4]) << 24)
    }

    /// [0][UID] then `count` tuples: attribute id, length (2 B), text. nil = incomplete or not this answer.
    static func parseAttributes(_ b: [UInt8], uid: UInt32, count: Int) -> [UInt8: String]? {
        guard let h = header(b), h == (0, uid) else { return nil }
        var out: [UInt8: String] = [:]
        var i = 5
        for _ in 0..<count {
            guard i + 3 <= b.count else { return nil }
            let len = Int(b[i + 1]) | Int(b[i + 2]) << 8
            guard i + 3 + len <= b.count else { return nil }
            out[b[i]] = clean(String(decoding: b[(i + 3)..<(i + 3 + len)], as: UTF8.self))
            i += 3 + len
        }
        return out
    }

    /// [1][app identifier, NUL-terminated][attribute 0][length][display name].
    static func parseAppName(_ b: [UInt8], appId: String) -> String? {
        let id = Array(appId.utf8)
        guard b.count >= 1 + id.count + 1, b[0] == 1, Array(b[1..<(1 + id.count)]) == id, b[1 + id.count] == 0 else { return nil }
        let i = 2 + id.count
        guard i + 3 <= b.count else { return nil }
        let len = Int(b[i + 1]) | Int(b[i + 2]) << 8
        guard i + 3 + len <= b.count else { return nil }
        return clean(String(decoding: b[(i + 3)..<(i + 3 + len)], as: UTF8.self))
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{0}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func builtInName(_ appId: String) -> String? {
        switch appId {
        case "com.apple.MobileSMS":   return String(localized: "Wiadomości")
        case "com.apple.mobilephone": return String(localized: "Telefon")
        case "com.apple.facetime":    return "FaceTime"
        default: return nil
        }
    }

    /// "net.whatsapp.WhatsApp" → "WhatsApp" — when the phone does not tell the app's name.
    static func fallbackName(_ appId: String) -> String {
        appId.split(separator: ".").last.map(String.init) ?? appId
    }
}

// MARK: — Overlay state (banner + quick menu)

/// What lies on top of the dashboard. Written from the main thread (joystick, buttons) and
/// from the Bluetooth queue (notifications), read by the render thread — hence the lock.
/// All times are seconds of `ProcessInfo.systemUptime`, passed in so the tests can run the clock.
final class DashOverlay {
    static let keyOK: UInt8 = 0x0C, keyUp: UInt8 = 0x1E, keyDown: UInt8 = 0x1F, keyLeft: UInt8 = 0x20, keyRight: UInt8 = 0x21

    static let compactTime: TimeInterval = 8        // a banner nobody touched
    static let expandedTime: TimeInterval = 25      // an opened message
    static let callTime: TimeInterval = 40          // an incoming call (normally removed by the phone earlier)
    static let slideIn: TimeInterval = 0.35, slideOut: TimeInterval = 0.25, expandAnim: TimeInterval = 0.28
    static let menuIdle: TimeInterval = 6

    struct Banner: Equatable {
        var notification: DashNotification
        var messages: [String]      // texts shown when expanded: the last few from the same sender
        var more: Int               // other notifications waiting behind this one
        var slide: CGFloat          // 0 = hidden above the screen … 1 = in place
        var expand: CGFloat         // 0 = compact … 1 = expanded
    }
    struct Menu: Equatable {
        var index: Int
        var slide: CGFloat
    }
    struct Snapshot: Equatable {
        var banner: Banner?
        var menu: Menu?
        var isEmpty: Bool { banner == nil && menu == nil }
    }
    enum KeyResult: Equatable {
        case pass               // not ours — the screen handles the key
        case consumed
        case activate(Int)      // the quick menu item with this index was pressed
    }

    /// "Do not disturb" from the quick menu. A closure, so the switch lives in one place (UserDefaults).
    var isMuted: () -> Bool = { UserDefaults.standard.bool(forKey: "notifMuted") }

    private let lock = NSLock()
    private var queue: [DashNotification] = []      // newest last; the last one is on screen
    private var shownAt: TimeInterval = 0
    private var touchedAt: TimeInterval = 0
    private var hidingAt: TimeInterval?
    private var expanded = false
    private var expandChangedAt: TimeInterval = -100
    private var menuOpen = false
    private var menuIndex = 0
    private var menuShownAt: TimeInterval = 0
    private var menuTouchedAt: TimeInterval = 0
    private var menuHidingAt: TimeInterval?

    // Notifications

    func post(_ n: DashNotification, at t: TimeInterval) {
        guard !isMuted() else { return }
        lock.lock(); defer { lock.unlock() }
        expire(t)
        if let i = queue.firstIndex(where: { $0.uid == n.uid }) {
            queue[i] = n                                     // the phone updated it — no new animation
            return
        }
        let fresh = queue.isEmpty || hidingAt != nil
        if hidingAt != nil { queue = [] }
        let sameSender = queue.last.map { $0.appId == n.appId && $0.title == n.title } ?? false
        queue.append(n)
        if queue.count > 8 { queue.removeFirst(queue.count - 8) }
        touchedAt = t
        if fresh {
            shownAt = t; hidingAt = nil
            expanded = false; expandChangedAt = -100
        } else if !sameSender, expanded {
            expanded = false; expandChangedAt = t           // someone else — back to the short form
        }
    }

    func remove(uid: UInt32, at t: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard hidingAt == nil, queue.contains(where: { $0.uid == uid }) else { return }
        if queue.count == 1 { hidingAt = t } else { queue.removeAll { $0.uid == uid } }
    }

    // Quick menu

    func openMenu(at t: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        menuOpen = true; menuIndex = 0
        menuShownAt = t; menuTouchedAt = t; menuHidingAt = nil
    }

    func closeMenu(at t: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if menuOpen, menuHidingAt == nil { menuHidingAt = t }
    }

    var menuIsOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return menuOpen && menuHidingAt == nil
    }

    // Joystick

    /// A pressed key. The banner takes OK (open / fold) and ◀ (close); the quick menu takes
    /// ◀ ▶ (choose), OK (change) and ▲ ▼ (close). `itemCount` = number of quick menu items.
    func key(_ key: UInt8, itemCount: Int, at t: TimeInterval) -> KeyResult {
        lock.lock(); defer { lock.unlock() }
        expire(t)
        if !queue.isEmpty, hidingAt == nil {
            if key == Self.keyOK {
                expanded.toggle(); expandChangedAt = t; touchedAt = t
                return .consumed
            }
            if key == Self.keyLeft {
                hidingAt = t
                return .consumed
            }
        }
        guard menuOpen, menuHidingAt == nil else { return .pass }
        menuTouchedAt = t
        switch key {
        case Self.keyLeft, Self.keyRight:
            guard itemCount > 0 else { return .consumed }
            menuIndex = ((menuIndex + (key == Self.keyRight ? 1 : -1)) % itemCount + itemCount) % itemCount
            return .consumed
        case Self.keyOK:
            return itemCount > 0 ? .activate(min(menuIndex, itemCount - 1)) : .consumed
        case Self.keyUp, Self.keyDown:
            menuHidingAt = t
            return .consumed
        default:
            return .pass
        }
    }

    // For the renderer

    func snapshot(at t: TimeInterval) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        expire(t)
        var s = Snapshot()
        if let n = queue.last {
            let group = queue.filter { $0.appId == n.appId && $0.title == n.title }
            let slide = hidingAt.map { 1 - Self.progress(t - $0, Self.slideOut) } ?? Self.easeOut(Self.progress(t - shownAt, Self.slideIn))
            let p = Self.easeOut(Self.progress(t - expandChangedAt, Self.expandAnim))
            s.banner = Banner(notification: n,
                              messages: group.suffix(3).map(\.message).filter { !$0.isEmpty },
                              more: queue.count - group.count,
                              slide: slide, expand: expanded ? p : 1 - p)
        }
        if menuOpen {
            let slide = menuHidingAt.map { 1 - Self.progress(t - $0, Self.slideOut) } ?? Self.easeOut(Self.progress(t - menuShownAt, Self.slideIn))
            s.menu = Menu(index: menuIndex, slide: slide)
        }
        return s
    }

    /// Ends what has run out of time. Call with `lock` held.
    private func expire(_ t: TimeInterval) {
        if let n = queue.last, hidingAt == nil {
            let life = n.isCall ? Self.callTime : expanded ? Self.expandedTime : Self.compactTime
            if t - touchedAt > life { hidingAt = touchedAt + life }
        }
        if let h = hidingAt, t - h >= Self.slideOut {
            queue = []; hidingAt = nil; expanded = false; expandChangedAt = -100
        }
        if menuOpen, menuHidingAt == nil, t - menuTouchedAt > Self.menuIdle { menuHidingAt = menuTouchedAt + Self.menuIdle }
        if let h = menuHidingAt, t - h >= Self.slideOut { menuOpen = false; menuHidingAt = nil }
    }

    private static func progress(_ dt: TimeInterval, _ duration: TimeInterval) -> CGFloat {
        CGFloat(max(0, min(1, dt / duration)))
    }
    private static func easeOut(_ p: CGFloat) -> CGFloat { 1 - (1 - p) * (1 - p) * (1 - p) }
}

// MARK: — Quick menu

/// Everything the quick menu needs to know to list its items.
struct QuickContext: Equatable {
    var screen: DashboardScreen = .classic
    var dark = true
    var font: DashFont = .rounded
    var ambient = true
    var notifications = false       // the notifications feature is switched on in the app
    var muted = false
    var navigating = false

    /// The current state, straight from the settings (safe from any thread).
    static func current(screen: Int, navigating: Bool, defaults d: UserDefaults = .standard) -> QuickContext {
        QuickContext(screen: DashboardScreen(rawValue: screen) ?? .classic,
                     dark: d.object(forKey: "dashboardDark") as? Bool ?? true,
                     font: DashFont(rawValue: d.string(forKey: "dashFont") ?? "") ?? .rounded,
                     ambient: d.object(forKey: "ambientBG") as? Bool ?? true,
                     notifications: d.bool(forKey: "notifEnabled"),
                     muted: d.bool(forKey: "notifMuted"),
                     navigating: navigating)
    }
}

struct QuickItem: Equatable {
    enum ID: Equatable { case nextVideo, exitGame, theme, font, mute, ambient, calibrate, endNavigation }
    var id: ID
    var label: String
    var value: String       // current setting; empty for an action
    /// The menu closes after an action; a setting stays, so it can be flipped back at once.
    var closes: Bool { value.isEmpty }
}

enum QuickMenu {
    /// Items in the order shown. What concerns the current screen comes first.
    static func items(_ c: QuickContext) -> [QuickItem] {
        let on = String(localized: "Wł."), off = String(localized: "Wył.")
        var out: [QuickItem] = []
        if c.screen == .video { out.append(QuickItem(id: .nextVideo, label: String(localized: "Następny film"), value: "")) }
        if c.screen == .snake { out.append(QuickItem(id: .exitGame, label: String(localized: "Wyjdź z gry"), value: "")) }
        if c.navigating { out.append(QuickItem(id: .endNavigation, label: String(localized: "Zakończ nawigację"), value: "")) }
        out.append(QuickItem(id: .theme, label: String(localized: "Motyw"),
                             value: c.dark ? String(localized: "Ciemny") : String(localized: "Jasny")))
        out.append(QuickItem(id: .font, label: String(localized: "Czcionka"), value: c.font.title))
        if c.notifications {
            out.append(QuickItem(id: .mute, label: String(localized: "Powiadomienia"),
                                 value: c.muted ? String(localized: "Wyciszone") : on))
        }
        out.append(QuickItem(id: .ambient, label: String(localized: "Żywe tło"), value: c.ambient ? on : off))
        out.append(QuickItem(id: .calibrate, label: String(localized: "Kalibracja przechyłu"), value: ""))
        return out
    }
}
