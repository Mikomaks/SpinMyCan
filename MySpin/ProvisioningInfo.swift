// ProvisioningInfo.swift
// Ile dni zostało do wygaśnięcia podpisu aplikacji.
//
// PO CO: darmowe konto Apple Developer wystawia profil ważny tylko 7 DNI.
// Po tym czasie iOS odmawia uruchomienia apki („aplikacja niedostępna") —
// co potrafi zaskoczyć w środku wyjazdu. Czytamy datę wygaśnięcia wprost
// z profilu wbudowanego w bundle i pokazujemy licznik w apce, żeby było
// widać ile zostało ZANIM wyruszysz.
//
// Odświeżenie na pełne 7 dni:  make refresh   (kasuje cache profili)

import Foundation

enum ProvisioningInfo {

    /// Data wygaśnięcia podpisu. nil = brak profilu (np. build na symulator).
    static let expiryDate: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        // Plik to CMS (podpisany) — plist siedzi w środku jako zwykły XML.
        // Wycinamy fragment między <?xml a </plist> i parsujemy.
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end   = data.range(of: Data("</plist>".utf8)) else { return nil }
        let xml = data[start.lowerBound ..< end.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()

    /// Pełnych dni do wygaśnięcia. nil = nie dotyczy (symulator/App Store).
    static var daysLeft: Int? {
        guard let expiryDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiryDate).day
    }

    /// Krótki tekst do paska: „7 dni". nil gdy nie dotyczy.
    static var shortLabel: String? {
        guard let d = daysLeft else { return nil }
        return d < 0 ? "wygasł" : "\(d) dni"
    }

    /// Czy warto ostrzec użytkownika (≤ 2 dni albo już po terminie).
    static var isExpiringSoon: Bool {
        guard let d = daysLeft else { return false }
        return d <= 2
    }
}
