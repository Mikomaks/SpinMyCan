// RecoveryPreviewView.swift
// Shown at start when the previous ride was interrupted (crash, the app was closed):
// what the ride was — when, how long, how far, the track on a map — so it is easy to decide
// whether to save it or throw it away. Nothing is saved until "Recover and save".

import SwiftUI
import MapKit

struct RecoveryPreviewView: View {
    let summary: SessionSummary
    let onRecover: () -> Void
    let onDiscard: () -> Void
    @State private var confirmDiscard = false

    /// GPS points of the ride (0,0 = no fix).
    private var coords: [CLLocationCoordinate2D] {
        summary.points.filter { $0.latitude != 0 || $0.longitude != 0 }
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    static func durationText(_ s: TimeInterval) -> String {
        let m = max(0, Int(s.rounded())) / 60
        return m >= 60 ? String(format: "%d h %02d min", m / 60, m % 60) : "\(m) min"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Poprzednia trasa została przerwana (awaria albo zamknięcie apki). Zapisać ją do biblioteki?")
                        .font(.subheadline).foregroundColor(.secondary)

                    map
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.startTime.formatted(date: .complete, time: .omitted)).font(.headline)
                        Text("\(summary.startTime.formatted(date: .omitted, time: .shortened)) – \(summary.endTime.formatted(date: .omitted, time: .shortened))")
                            .font(.subheadline).foregroundColor(.secondary)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        stat(String(format: "%.1f km", summary.totalDistKm), String(localized: "Dystans"))
                        stat(Self.durationText(summary.endTime.timeIntervalSince(summary.startTime)), String(localized: "Czas"))
                        stat(String(format: "%.0f km/h", summary.maxSpeedKmh), String(localized: "Maks."))
                        stat(String(format: "%.0f km/h", summary.avgSpeedKmh), String(localized: "Średnia"))
                        stat(String(format: "%.0f° / %.0f°", summary.maxLeanLeft, summary.maxLeanRight), String(localized: "Przechył L / P"))
                        stat("\(summary.tracks?.count ?? 0)", String(localized: "Piosenki"))
                    }
                }
                .padding()
            }
            .navigationTitle("Przerwana trasa")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button(action: onRecover) {
                        Label("Odzyskaj i zapisz", systemImage: "square.and.arrow.down")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(AppStyle.accent)
                    Button(role: .destructive) { confirmDiscard = true } label: {
                        Text("Usuń").frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .background(.bar)
            }
            .confirmationDialog("Usunąć tę trasę na zawsze?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Usuń trasę", role: .destructive, action: onDiscard)
                Button("Anuluj", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled()     // a choice must be made — swiping down would leave it undecided
    }

    @ViewBuilder private var map: some View {
        let c = coords
        if c.count >= 2 {
            Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
                MapPolyline(coordinates: c).stroke(AppStyle.accent, lineWidth: 4)
                Annotation("", coordinate: c[0]) { dot(.green) }
                Annotation("", coordinate: c[c.count - 1]) { dot(.red) }
            }
        } else {
            ZStack {
                Color(.secondarySystemBackground)
                Label("Brak śladu GPS", systemImage: "location.slash").foregroundColor(.secondary)
            }
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 12, height: 12).overlay(Circle().stroke(.white, lineWidth: 2))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.headline, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}
