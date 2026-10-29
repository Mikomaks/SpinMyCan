// AppStyle.swift
// Wspólny wygląd interfejsu apki (nie deski na motocyklu): karty, nagłówki,
// pigułki stanu, kafelki liczb. Jedno miejsce, żeby każdy ekran wyglądał tak samo.

import SwiftUI

enum AppStyle {
    /// Kolor przewodni — czerwień motocykla, ta sama co w widoku na kierownicę.
    static let accent = Color(red: 0.90, green: 0.12, blue: 0.16)
    static let cardRadius: CGFloat = 20
    static let pageBackground = Color(.systemGroupedBackground)
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    /// Tło pól wewnątrz karty (wiersze, kafelki).
    static let inset = Color(.tertiarySystemGroupedBackground)
    /// Animowane cyfry w kafelkach — wyłączone. Włącza je tylko próba obciążenia
    /// (env LEGACY_UI_RATE), żeby dało się zmierzyć, ile kosztowały.
    static let animateNumbers: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LEGACY_UI_RATE"] != nil
        #else
        return false
        #endif
    }()
}

// MARK: — Karta

private struct CardStyle: ViewModifier {
    var padding: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppStyle.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppStyle.cardRadius, style: .continuous))
            // Cień tylko w jasnym motywie — w ciemnym karty odcina sama jasność tła.
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 10, y: 4)
    }
}

/// Strzałka powrotu w lewym górnym rogu — wszystkie ekrany apki są pełnoekranowe (bez wysuwanych kart).
struct BackButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left").font(.body.weight(.semibold))
        }
        .accessibilityLabel("Wróć")
    }
}

extension View {
    /// Standardowa karta: zaokrąglone tło z odstępem w środku.
    func card(padding: CGFloat = 16) -> some View { modifier(CardStyle(padding: padding)) }
}

// MARK: — Nagłówek karty

/// Ikona w kolorowym kwadracie + tytuł; po prawej dowolny dodatek (licznik, przełącznik…).
struct CardHeader<Trailing: View>: View {
    let title: String
    let icon: String
    var tint: Color = AppStyle.accent
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, icon: String, tint: Color = AppStyle.accent,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title; self.icon = icon; self.tint = tint; self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title)
                .font(.system(.headline, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(_ title: String, icon: String, tint: Color = AppStyle.accent) {
        self.init(title, icon: icon, tint: tint) { EmptyView() }
    }
}

// MARK: — Tytuł sekcji (nad grupą kart)

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.top, 10)
    }
}

// MARK: — Pigułka stanu

/// Mały kafelek „co jest podłączone": kropka w kolorze stanu, nazwa i krótki opis.
struct StatusPill: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 22, height: 22)
                    .background(color.opacity(0.15), in: Circle())
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppStyle.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: — Kafelek liczby

/// Duża liczba z podpisem — prędkość, przechył, rekordy.
struct StatTile: View {
    let label: String
    let value: String
    var unit: String = ""
    var color: Color = .primary
    var big: Bool = false

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: big ? 40 : 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    // Bez animacji przeskakujących cyfr: przechył i prędkość zmieniają się kilka
                    // razy na sekundę, więc animacja trwała bez przerwy i sama zjadała większość
                    // czasu procesora (patrz AppStyle.animateNumbers).
                    .contentTransition(AppStyle.animateNumbers ? .numericText() : .identity)
                    .animation(AppStyle.animateNumbers ? .easeOut(duration: 0.25) : nil, value: value)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: big ? 13 : 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: — Wiersz-odnośnik

/// Wiersz „ikona · tekst · strzałka" otwierający kolejny ekran.
struct LinkRow: View {
    let title: String
    let icon: String
    var tint: Color = AppStyle.accent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(AppStyle.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
