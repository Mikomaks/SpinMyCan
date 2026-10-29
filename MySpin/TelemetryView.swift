// TelemetryView.swift
// Dashboard telemetrii motocykla — ciemny motyw, aktualizacje w czasie rzeczywistym.

import SwiftUI
import Combine

// MARK: — Główny widok

struct TelemetryView: View {
    @ObservedObject var telemetry: TelemetryStore
    @State private var showRaw = true   // domyślnie rozwinięte — pełna diagnostyka
    // TelemetryStore nie jest @Published (wydajność) → odświeżamy widok timerem 0.5s
    @State private var refreshTick = 0

    var body: some View {
        ZStack {
            // Tło
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.04, blue: 0.10),
                         Color(red: 0.06, green: 0.07, blue: 0.15)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    // ── Pasek statusu ──
                    statusBar

                    // ── Prędkość + RPM (duże) ──
                    HStack(spacing: 12) {
                        SpeedGauge(speed: telemetry.speed, fraction: telemetry.speedFraction)
                        RPMGauge(rpm: telemetry.rpm, fraction: telemetry.rpmFraction)
                    }
                    .padding(.horizontal, 16)

                    // ── Bieg + Tryb + Temp + Paliwo ──
                    HStack(spacing: 10) {
                        GearIndicator(label: telemetry.gearLabel)
                        RideModeCard(mode: telemetry.rideModeLabel)
                        TempCard(temp: telemetry.ambientTemp)
                        FuelGauge(pct: telemetry.fuelPct,
                                  fraction: telemetry.fuelKnown ? telemetry.fuelFraction : 0,
                                  warning: telemetry.fuelWarning,
                                  known: telemetry.fuelKnown)
                    }
                    .padding(.horizontal, 16)

                    // ── Przepustnica + Przechył + Yaw ──
                    HStack(spacing: 10) {
                        ThrottleBar(pct: telemetry.throttle)
                        TiltCard(angle: telemetry.tiltAngle)
                        YawCard(rate: telemetry.yawRate)
                    }
                    .padding(.horizontal, 16)

                    // ── Flagi stanu ──
                    HStack(spacing: 10) {
                        StatusFlag(icon: "engine.combustion.fill",
                                   label: "Silnik",
                                   on: telemetry.engineOn,
                                   onColor: .green)
                        StatusFlag(icon: "moon.fill",
                                   label: "Noc",
                                   on: telemetry.isNight,
                                   onColor: .blue)
                        Spacer()
                    }
                    .padding(.horizontal, 16)

                    // ── Live channels — diagnostyka identyfikacji kanałów ──
                    liveChannelsPanel
                        .padding(.horizontal, 16)

                    // ── Wszystkie kanały (pełna diagnostyka) ──
                    allChannelsSection
                        .padding(.horizontal, 16)
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("Telemetria")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            refreshTick &+= 1   // wymusza re-render — czyta świeże wartości ze store
        }
    }

    // MARK: — Status bar

    var statusBar: some View {
        HStack(spacing: 8) {
            // Pulsujący wskaźnik
            Circle()
                .fill(statusDotColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusDotColor, radius: telemetry.isLive ? 4 : 0)

            Text(telemetry.statusLabel)
                .font(.caption.bold())
                .foregroundColor(telemetry.hasData ? .primary : .secondary)

            Spacer()

            if telemetry.hasData {
                Text("\(telemetry.rawChannels.count) kanałów")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04))
    }

    var statusDotColor: Color {
        if !telemetry.hasData { return .gray }
        if telemetry.isLive   { return .green }
        if telemetry.engineOn { return .green }
        return .orange   // dane statyczne (silnik wyłączony)
    }

    // MARK: — Live channels panel (kanały z niezerowymi wartościami)

    var liveChannelsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(telemetry.receivedChannels.isEmpty ? Color.red : Color.green)
                    .frame(width: 7, height: 7)
                // Pokazuj oba: otrzymane (z wartością) i niezerowe
                Text("Odebrane: \(telemetry.receivedChannels.count)  |  Niezerowe: \(telemetry.liveChannels.count)")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                Spacer()
                Text("← odebrane = nie 'not supported'")
                    .font(.system(size: 9))
                    .foregroundColor(Color.yellow.opacity(0.7))
            }

            if telemetry.receivedChannels.isEmpty {
                Text(telemetry.hasData
                    ? "Wszystkie kanały = 'not supported' — niekompatybilny motocykl?"
                    : "Brak danych — połącz TCP")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 2) {
                    ForEach(telemetry.receivedChannels, id: \.id) { ch in
                        let isNonZero = ch.value != "0" && ch.value != "false"
                            && ch.value != "0.000" && ch.value != "notset"
                        HStack(spacing: 6) {
                            Text(String(format: "0x%08X", ch.id))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(isNonZero ? .yellow : Color.white.opacity(0.5))
                                .frame(width: 90, alignment: .leading)
                            Text(ch.name)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(ch.name == "???" ? Color.orange : Color.cyan)
                                .frame(width: 90, alignment: .leading)
                            Spacer()
                            Text(ch.value)
                                .font(.system(size: 12, weight: .black, design: .monospaced))
                                .foregroundColor(isNonZero ? .green : Color.white.opacity(0.4))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isNonZero ? Color.green.opacity(0.10) : Color.white.opacity(0.02))
                        .cornerRadius(5)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(telemetry.receivedChannels.isEmpty ? Color.red.opacity(0.4) : Color.green.opacity(0.2), lineWidth: 1))
    }

    // MARK: — All channels section (pełna lista 80 kanałów)

    var allChannelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showRaw.toggle() }
            } label: {
                HStack {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.caption)
                    Text("Wszystkie kanały (\(telemetry.rawChannels.count))")
                        .font(.caption.bold())
                    Spacer()
                    Image(systemName: showRaw ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
                .padding(.vertical, 4)
            }

            if showRaw {
                VStack(spacing: 2) {
                    ForEach(telemetry.allChannelsSorted, id: \.id) { ch in
                        let isNotSupported = ch.value.hasPrefix("[")
                        let isLive = !isNotSupported && ch.value != "0"
                            && ch.value != "false" && ch.value != "0.000"

                        HStack(spacing: 4) {
                            Text(String(format: "0x%08X", ch.id))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(isLive ? .yellow : Color.white.opacity(0.3))
                                .frame(width: 82, alignment: .leading)
                            Text(ch.name)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(ch.name == "???" ? Color.white.opacity(0.3) : .cyan)
                                .frame(width: 70, alignment: .leading)
                            Spacer()
                            Text(ch.value)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(
                                    isNotSupported ? Color.white.opacity(0.2) :
                                    isLive         ? .white : Color.white.opacity(0.5)
                                )
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(isLive ? Color.green.opacity(0.07) : Color.clear)
                        .cornerRadius(4)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .cornerRadius(12)
    }
}

// MARK: — SpeedGauge

struct SpeedGauge: View {
    let speed: Double
    let fraction: Double

    var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "%.0f", speed))
                .font(.system(size: 68, weight: .black, design: .rounded))
                .foregroundColor(.white)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.3), value: speed)

            Text("km/h")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.cyan)
                .tracking(3)
                .textCase(.uppercase)

            ThinBar(fraction: fraction, color: .cyan)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.06))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.cyan.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: — RPMGauge

struct RPMGauge: View {
    let rpm: Double
    let fraction: Double

    var rpmColor: Color {
        switch rpm {
        case ..<7000:  return Color(red: 0.2, green: 0.8, blue: 0.4)
        case ..<10500: return .yellow
        default:       return .red
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "%.0f", rpm))
                .font(.system(size: 52, weight: .black, design: .rounded))
                .foregroundColor(.white)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.2), value: rpm)

            Text("RPM")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(rpmColor)
                .tracking(3)

            ThinBar(fraction: fraction, color: rpmColor)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.06))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(rpmColor.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: — GearIndicator

struct GearIndicator: View {
    let label: String

    var color: Color { label == "N" ? .green : .white }

    var body: some View {
        VStack(spacing: 4) {
            Text("BIEG")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.secondary)
                .tracking(2)
            Text(label)
                .font(.system(size: 56, weight: .black, design: .rounded))
                .foregroundColor(color)
                .shadow(color: color.opacity(0.6), radius: label == "N" ? 6 : 0)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.15), value: label)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }
}

// MARK: — RideModeCard

struct RideModeCard: View {
    let mode: String

    var modeColor: Color {
        switch mode {
        case "A": return Color(red: 1, green: 0.45, blue: 0.1)  // Sport
        case "B": return Color(red: 0.2, green: 0.6, blue: 1)   // Tour
        case "C": return Color(red: 0.3, green: 0.9, blue: 0.5) // Rain
        default:  return .purple
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "dial.high.fill")
                .font(.system(size: 16))
                .foregroundColor(modeColor)
            Text(mode)
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundColor(.white)
            Text("TRYB")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.secondary)
                .tracking(2)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }
}

// MARK: — TempCard

struct TempCard: View {
    let temp: Double

    var tempColor: Color {
        switch temp {
        case ..<0:   return Color(red: 0.5, green: 0.8, blue: 1)
        case ..<10:  return .cyan
        case ..<30:  return .white
        case ..<40:  return .yellow
        default:     return .orange
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 16))
                .foregroundColor(tempColor)
            Text(String(format: "%.0f°", temp))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(.numericText())
            Text("°C")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.secondary)
                .tracking(2)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }
}

// MARK: — FuelGauge

struct FuelGauge: View {
    let pct: Double
    let fraction: Double
    let warning: Bool
    var known: Bool = true   // false = "not supported" / brak danych

    var fuelColor: Color {
        guard known else { return Color(white: 0.4) }
        switch pct {
        case ..<15: return .red
        case ..<30: return .orange
        default:    return Color(red: 0.2, green: 0.85, blue: 0.4)
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: known && warning ? "fuelpump.exclamationmark.fill" : "fuelpump.fill")
                .font(.system(size: 16))
                .foregroundColor(fuelColor)
                .symbolEffect(.bounce, value: warning)

            Text(known ? String(format: "%.0f%%", pct) : "—%")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(fuelColor)
                .contentTransition(.numericText())

            // Pionowy pasek paliwa
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 16)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(fuelColor)
                        .frame(width: 16, height: geo.size.height * CGFloat(fraction))
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 28)

            Text("PALIWO")
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(.secondary)
                .tracking(1)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }
}

// MARK: — ThrottleBar

struct ThrottleBar: View {
    let pct: Double

    var throttleColor: Color {
        switch pct {
        case ..<40: return Color(red: 0.2, green: 0.8, blue: 0.4)
        case ..<75: return .yellow
        default:    return .orange
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "%.0f%%", pct))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .contentTransition(.numericText())
            ThinBar(fraction: pct / 100, color: throttleColor)
            Text("GAZ")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.secondary)
                .tracking(2)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }
}

// MARK: — TiltCard

struct TiltCard: View {
    let angle: Double

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "rotate.3d")
                .font(.system(size: 16))
                .foregroundColor(.purple)
                .rotationEffect(.degrees(angle * 3))
                .animation(.easeOut(duration: 0.2), value: angle)
            Text(String(format: "%.1f°", angle))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .contentTransition(.numericText())
            Text("PRZECHYŁ")
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(.secondary)
                .tracking(1)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }
}

// MARK: — YawCard

struct YawCard: View {
    let rate: Double

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 16))
                .foregroundColor(Color(red: 0.6, green: 0.4, blue: 1))
            Text(String(format: "%.0f", rate))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .contentTransition(.numericText())
            Text("YAW °/s")
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(.secondary)
                .tracking(1)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }
}

// MARK: — StatusFlag

struct StatusFlag: View {
    let icon: String
    let label: String
    let on: Bool
    let onColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(on ? onColor : Color.white.opacity(0.25))
                .shadow(color: on ? onColor : .clear, radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(on ? .white : .secondary)
                Text(on ? "AKTYWNY" : "NIEAKTYWNY")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(on ? onColor : Color.white.opacity(0.2))
                    .tracking(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(on ? 0.08 : 0.04))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(on ? onColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }
}

// MARK: — ThinBar (pasek postępu)

struct ThinBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 5)
                Capsule()
                    .fill(color)
                    .frame(width: max(5, geo.size.width * CGFloat(max(0, min(1, fraction)))),
                           height: 5)
                    .shadow(color: color.opacity(0.5), radius: 3)
                    .animation(.easeOut(duration: 0.3), value: fraction)
            }
        }
        .frame(height: 5)
    }
}

#Preview {
    NavigationView {
        TelemetryView(telemetry: {
            let t = TelemetryStore()
            t.speed = 124; t.rpm = 6800; t.gear = 4
            t.fuelPct = 65; t.rideMode = 0; t.ambientTemp = 22
            t.throttle = 45; t.tiltAngle = -3.5
            t.engineOn = true; t.isMoving = true
            return t
        }())
    }
}
