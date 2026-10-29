// ShareViewController.swift  —  Share Extension „MySpin Nawiguj"
// Odbiera miejsce udostępnione z Apple Maps (share sheet) i zapisuje cel
// do App Group. Główna apka czyta go przy starcie / powrocie na 1. plan
// i startuje nawigację 1:1 (ten sam silnik MapKit = identyczna trasa).
//
// Kolejność prób:
//  1. MKMapItem  — Apple Maps dołącza go do udostępnienia → dokładne współrzędne + nazwa, zero sieci
//  2. URL        — maps.apple.com/?ll=…  → parsujemy lokalnie;
//                  krótki maps.apple/p/… → zapisujemy surowy link, apka rozwiąże go przez sieć
//  3. Tekst      — wyłuskujemy link z udostępnionego tekstu
//
// UI: przezroczysty kontroler ze storyboardu + mały toast potwierdzenia, auto-zamknięcie.

import UIKit
import MapKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    private let appGroup = "group.com.mikomaks.myspin"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        extract()
    }

    // MARK: — Ekstrakcja celu

    private var allProviders: [NSItemProvider] {
        ((extensionContext?.inputItems as? [NSExtensionItem]) ?? [])
            .compactMap(\.attachments)
            .flatMap { $0 }
    }

    private func extract() {
        let providers = allProviders
        guard !providers.isEmpty else { return done(ok: false) }

        // 1) MKMapItem — najpewniejsze źródło (współrzędne + nazwa miejsca)
        if let p = providers.first(where: { $0.canLoadObject(ofClass: MKMapItem.self) }) {
            _ = p.loadObject(ofClass: MKMapItem.self) { [weak self] obj, _ in
                DispatchQueue.main.async {
                    if let item = obj as? MKMapItem {
                        let c = item.placemark.coordinate
                        self?.save(lat: c.latitude, lon: c.longitude, name: item.name, link: nil)
                        self?.done(ok: true)
                    } else {
                        self?.extractURL(providers)
                    }
                }
            }
            return
        }
        extractURL(providers)
    }

    private func extractURL(_ providers: [NSItemProvider]) {
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            p.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] data, _ in
                DispatchQueue.main.async {
                    let link = (data as? URL)?.absoluteString
                        ?? (data as? Data).flatMap { String(data: $0, encoding: .utf8) }
                        ?? (data as? String) ?? ""
                    self?.saveLink(link)
                }
            }
            return
        }
        if let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            p.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] data, _ in
                DispatchQueue.main.async {
                    let text = (data as? String)
                        ?? (data as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    self?.saveLink(text)
                }
            }
            return
        }
        done(ok: false)
    }

    private func saveLink(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return done(ok: false) }
        // Udostępniony tekst bywa „Nazwa miejsca https://maps.apple/p/…" — wyłuskaj sam URL
        let url = trimmed.components(separatedBy: .whitespacesAndNewlines)
            .first(where: { $0.contains("maps.apple") })
            ?? trimmed.components(separatedBy: .whitespacesAndNewlines)
                .first(where: { $0.hasPrefix("http") })
            ?? trimmed
        if let c = Self.parseCoordinate(from: url) {
            save(lat: c.latitude, lon: c.longitude, name: nil, link: nil)
        } else if url.hasPrefix("http") {
            // Krótki link bez współrzędnych — apka rozwiąże go przez sieć
            save(lat: nil, lon: nil, name: nil, link: url)
        } else {
            return done(ok: false)
        }
        done(ok: true)
    }

    // MARK: — Zapis do App Group

    private func save(lat: Double?, lon: Double?, name: String?, link: String?) {
        guard let d = UserDefaults(suiteName: appGroup) else { return }
        // Wyczyść stare wartości, żeby nie mieszać poprzedniego celu z nowym
        ["pendingDestLat", "pendingDestLon", "pendingDestName", "pendingDestLink", "pendingDestTime"]
            .forEach { d.removeObject(forKey: $0) }
        if let lat, let lon {
            d.set(lat, forKey: "pendingDestLat")
            d.set(lon, forKey: "pendingDestLon")
        }
        if let name { d.set(name, forKey: "pendingDestName") }
        if let link { d.set(link, forKey: "pendingDestLink") }
        d.set(Date().timeIntervalSince1970, forKey: "pendingDestTime")
    }

    // MARK: — Toast + zamknięcie

    private func done(ok: Bool) {
        showToast(ok ? "✓ Cel zapisany — otwórz MySpin" : "✗ Brak lokalizacji w udostępnieniu")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func showToast(_ text: String) {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        label.layer.cornerRadius = 14
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40)
        ])
    }

    // MARK: — Parsowanie współrzędnych z linku

    /// Wyciąga „lat,lon" z parametrów linku Apple Maps (ll/daddr/coordinate/sll/center/q).
    static func parseCoordinate(from link: String) -> CLLocationCoordinate2D? {
        guard let comps = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let items = comps.queryItems ?? []
        for key in ["ll", "coordinate", "sll", "center", "daddr", "q"] {
            guard let v = items.first(where: { $0.name.lowercased() == key })?.value else { continue }
            let p = v.split(separator: ",")
            if p.count >= 2,
               let lat = Double(p[0].trimmingCharacters(in: .whitespaces)),
               let lon = Double(p[1].trimmingCharacters(in: .whitespaces)),
               abs(lat) <= 90, abs(lon) <= 180 {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        return nil
    }
}
