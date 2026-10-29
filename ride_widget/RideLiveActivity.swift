// RideLiveActivity.swift
// Wygląd Live Activity jazdy: Dynamic Island (zwinięta, rozwinięta, minimalna)
// i baner na ekranie blokady. Dane przychodzą z apki (RideLiveActivityManager).

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RideWidgetBundle: WidgetBundle {
    var body: some Widget {
        RideLiveActivity()
    }
}

// MARK: — Kolory jak w ikonie apki (obrotomierz)

private enum Tacho {
    static let green  = Color(red: 0.18, green: 0.82, blue: 0.38)
    static let yellow = Color(red: 1.00, green: 0.76, blue: 0.00)
    static let red    = Color(red: 0.94, green: 0.18, blue: 0.18)
    static let needle = Color(red: 1.00, green: 0.42, blue: 0.00)
    static let hub    = Color(red: 0.80, green: 0.80, blue: 0.84)
    static let bg     = Color(red: 0.08, green: 0.08, blue: 0.10)
    static let maxRpm = 11_000.0
}

/// Logo apki: łuk obrotomierza (zielony → żółty → czerwony) z pomarańczową wskazówką.
/// Wskazówka pokazuje obroty z CAN, a bez nich stoi tam, gdzie na ikonie.
struct TachoLogo: View {
    var rpm: Int?

    private var fraction: Double {
        guard let rpm else { return 0.62 }
        return min(1, max(0, Double(rpm) / Tacho.maxRpm))
    }

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height)
            let lw = max(1.5, s * 0.12)
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(AngularGradient(colors: [Tacho.green, Tacho.green, Tacho.yellow, Tacho.red],
                                            center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .padding(lw / 2)
                Capsule()
                    .fill(Tacho.needle)
                    .frame(width: max(1.5, s * 0.09), height: s * 0.40)
                    .offset(y: -s * 0.18)
                    .rotationEffect(.degrees(-135 + 270 * fraction))
                Circle()
                    .fill(Tacho.hub)
                    .frame(width: s * 0.2, height: s * 0.2)
            }
            .frame(width: s, height: s)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: — Pomocnicze teksty

private extension RideActivityAttributes.ContentState {
    var gearText: String {
        guard let gear else { return "–" }
        return gear == 0 ? "N" : "\(gear)"
    }
    var gearColor: Color { gear == 0 ? Tacho.green : .white }
    var leanText: String {
        leanDeg == 0 ? "0°" : "\(abs(leanDeg))° \(leanDeg < 0 ? "L" : "P")"
    }
    var coolantColor: Color {
        guard let c = coolantC else { return .secondary }
        return c >= 115 ? Tacho.red : (c < 50 ? .cyan : .white)
    }
}

private struct StatusDot: View {
    let on: Bool
    let label: String
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(on ? Tacho.green : Color.gray.opacity(0.6)).frame(width: 6, height: 6)
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(on ? .white : .secondary)
        }
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var color: Color = .white
    var body: some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(.body, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: — Live Activity

struct RideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Tacho.bg)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        TachoLogo(rpm: s.rpm).frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(s.gearText)
                                .font(.system(size: 26, weight: .heavy, design: .rounded))
                                .foregroundStyle(s.gearColor)
                            Text("BIEG").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(s.speedKmh)")
                            .font(.system(size: 30, weight: .heavy, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                        Text("km/h").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Stat(value: s.rpm.map { "\($0)" } ?? "–", label: "OBR/MIN")
                        Stat(value: s.coolantC.map { "\($0)°C" } ?? "–", label: "PŁYN", color: s.coolantColor)
                        Stat(value: s.leanText, label: "PRZECHYŁ")
                        Stat(value: "\(s.maxLeft)° / \(s.maxRight)°", label: "MAX L / P")
                    }
                    HStack(spacing: 12) {
                        StatusDot(on: s.dashConnected, label: "DESKA")
                        StatusDot(on: s.canConnected, label: "CAN")
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                TachoLogo(rpm: s.rpm).frame(width: 22, height: 22)
            } compactTrailing: {
                Text("\(s.speedKmh)")
                    .font(.system(.body, design: .rounded).weight(.bold).monospacedDigit())
                    .foregroundStyle(Tacho.needle)
                    .contentTransition(.numericText())
            } minimal: {
                TachoLogo(rpm: s.rpm).frame(width: 20, height: 20)
            }
            .keylineTint(Tacho.needle)
        }
    }
}

private struct LockScreenView: View {
    let state: RideActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            TachoLogo(rpm: state.rpm).frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(state.speedKmh)")
                        .font(.system(size: 34, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("km/h").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    StatusDot(on: state.dashConnected, label: "DESKA")
                    StatusDot(on: state.canConnected, label: "CAN")
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                Stat(value: state.gearText, label: "BIEG", color: state.gearColor)
                Stat(value: state.coolantC.map { "\($0)°" } ?? "–", label: "PŁYN", color: state.coolantColor)
                Stat(value: "\(state.maxLeft)/\(state.maxRight)", label: "MAX °")
            }
            .frame(maxWidth: 170)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
