// SegmentsView.swift
// Sekcja „Odcinki": nagrywanie nowego odcinka dwoma tapnięciami (start → koniec),
// lista zapisanych, historia przejazdów. Logika siedzi w SegmentManager — tu
// jest tylko interfejs.

import SwiftUI

// MARK: — Sterowanie nagrywaniem (wspólne dla karty na ekranie głównym i arkusza)

struct SegmentRecorderControl: View {
    @ObservedObject var manager: SegmentManager
    /// Nagrywanie potrzebuje GPS — rodzic włącza czujniki, jeśli jeszcze nie działają.
    var ensureGPS: () -> Void = {}

    @State private var askName = false
    @State private var name = ""
    @State private var problem: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if manager.isRecording {
                HStack(spacing: 14) {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text(String(format: "%.2f km", manager.recDistM / 1000))
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                    Text(SegmentManager.fmt(manager.recSec))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                HStack(spacing: 10) {
                    Button {
                        name = ""
                        askName = true
                    } label: {
                        Label("Zakończ i zapisz", systemImage: "flag.checkered")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Button("Anuluj", role: .cancel) { manager.cancelRecording() }
                        .buttonStyle(.bordered)
                }
            } else {
                Button {
                    ensureGPS()
                    manager.startRecording()
                } label: {
                    Label("Nagraj nowy odcinek", systemImage: "record.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
                .tint(AppStyle.accent)

                Text("Tapnij na początku odcinka, przejedź go i tapnij „Zakończ”. Postój na starcie i mecie sam się przytnie.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let problem {
                Text(problem).font(.caption).foregroundColor(.orange)
            }
        }
        .alert("Nazwa odcinka", isPresented: $askName) {
            TextField("np. Przełęcz Salmopolska", text: $name)
            Button("Zapisz") { problem = manager.finishRecording(name: name) }
            Button("Jeszcze jadę", role: .cancel) { }
        } message: {
            Text(String(format: "%.2f km · %@", manager.recDistM / 1000, SegmentManager.fmt(manager.recSec)))
        }
    }
}

// MARK: — Lista odcinków

struct SegmentsView: View {
    @ObservedObject var manager: SegmentManager
    var ensureGPS: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    SegmentRecorderControl(manager: manager, ensureGPS: ensureGPS)
                        .padding(.vertical, 4)
                }
                if !manager.liveText.isEmpty {
                    Section("Teraz") {
                        Text(manager.liveText)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                    }
                }
                Section(manager.segments.isEmpty ? "" : String(localized: "Twoje odcinki")) {
                    if manager.segments.isEmpty {
                        Text("Nie masz jeszcze żadnego odcinka. Gdy go nagrasz, apka sama rozpozna każdy kolejny przejazd i pokaże na desce, ile jesteś przed albo za rekordem.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    ForEach(manager.segments) { seg in
                        NavigationLink {
                            SegmentDetailView(manager: manager, segmentID: seg.id)
                        } label: {
                            SegmentRow(seg: seg)
                        }
                    }
                    .onDelete { idx in
                        idx.map { manager.segments[$0].id }.forEach(manager.delete)
                    }
                }
            }
            .navigationTitle("Odcinki")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BackButton { dismiss() }
                }
            }
        }
    }
}

private struct SegmentRow: View {
    let seg: Segment
    var body: some View {
        HStack(spacing: 12) {
            SegmentShape(points: seg.points)
                .frame(width: 46, height: 46)
                .background(Color(.systemGray6))
                .cornerRadius(8)
            VStack(alignment: .leading, spacing: 3) {
                Text(seg.name).font(.body.weight(.semibold))
                Text(String(format: "%.1f km · %d %@", seg.lengthM / 1000, seg.runs.count,
                            seg.runs.count == 1 ? String(localized: "przejazd") : String(localized: "przejazdów")))
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if let best = seg.best {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(SegmentManager.fmt(best.timeSec))
                        .font(.system(.body, design: .monospaced).weight(.bold))
                    Text("rekord").font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: — Szczegóły odcinka

struct SegmentDetailView: View {
    @ObservedObject var manager: SegmentManager
    let segmentID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    private var seg: Segment? { manager.segments.first { $0.id == segmentID } }

    var body: some View {
        List {
            if let seg {
                Section {
                    SegmentShape(points: seg.points, lineWidth: 3)
                        .frame(height: 190)
                        .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                    HStack {
                        stat(String(format: "%.2f km", seg.lengthM / 1000), String(localized: "DŁUGOŚĆ"))
                        stat(seg.best.map { SegmentManager.fmt($0.timeSec) } ?? "—", String(localized: "REKORD"))
                        stat(seg.best.map { String(format: "%.0f", $0.avgKmh) } ?? "—", String(localized: "ŚR. KM/H"))
                    }
                }
                Section("Przejazdy") {
                    ForEach(seg.runs) { run in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.subheadline)
                                Text(String(format: String(localized: "vmax %.0f · przechył L %.0f° / P %.0f°"),
                                            run.vmax, run.maxLeanL, run.maxLeanR))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(SegmentManager.fmt(run.timeSec))
                                    .font(.system(.body, design: .monospaced).weight(.semibold))
                                if let best = seg.best {
                                    let d = run.timeSec - best.timeSec
                                    Text(d < 0.05 ? String(localized: "rekord") : String(format: "+%.1f s", d))
                                        .font(.caption2)
                                        .foregroundColor(d < 0.05 ? .green : .secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("Zmień nazwę") { newName = seg.name; renaming = true }
                    Button("Usuń odcinek", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(seg?.name ?? String(localized: "Odcinek"))
        .navigationBarTitleDisplayMode(.inline)
        .alert("Nazwa odcinka", isPresented: $renaming) {
            TextField("Nazwa", text: $newName)
            Button("Zapisz") { manager.rename(segmentID, to: newName) }
            Button("Anuluj", role: .cancel) { }
        }
        .confirmationDialog("Usunąć odcinek razem z historią przejazdów?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Usuń", role: .destructive) { manager.delete(segmentID); dismiss() }
            Button("Anuluj", role: .cancel) { }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(.headline, design: .monospaced))
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: — Kształt odcinka (ślad pokolorowany przechyłem)

struct SegmentShape: View {
    let points: [SegPoint]
    var lineWidth: CGFloat = 2

    var body: some View {
        Canvas { ctx, size in
            guard points.count > 1 else { return }
            let lats = points.map { $0.lat }, lons = points.map { $0.lon }
            guard let la0 = lats.min(), let la1 = lats.max(),
                  let lo0 = lons.min(), let lo1 = lons.max() else { return }
            // Korekta zbieżności południków — bez niej ślad byłby rozciągnięty w poziomie.
            let kx = cos((la0 + la1) / 2 * .pi / 180)
            let sx = max((lo1 - lo0) * kx, 1e-6), sy = max(la1 - la0, 1e-6)
            let pad: CGFloat = 8
            let sc = min((size.width - 2 * pad) / sx, (size.height - 2 * pad) / sy)
            let ox = (size.width - sx * sc) / 2, oy = (size.height - sy * sc) / 2
            func pt(_ p: SegPoint) -> CGPoint {
                CGPoint(x: ox + (p.lon - lo0) * kx * sc, y: size.height - oy - (p.lat - la0) * sc)
            }
            for i in 1..<points.count {
                var path = Path()
                path.move(to: pt(points[i - 1])); path.addLine(to: pt(points[i]))
                ctx.stroke(path, with: .color(Self.zone(points[i].lean)),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            let a = pt(points[0]), b = pt(points[points.count - 1])
            ctx.fill(Path(ellipseIn: CGRect(x: a.x - 4, y: a.y - 4, width: 8, height: 8)), with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: b.x - 4, y: b.y - 4, width: 8, height: 8)), with: .color(.red))
        }
    }

    private static func zone(_ deg: Double) -> Color {
        switch abs(deg) {
        case ..<25: return Color(red: 0.18, green: 0.85, blue: 0.48)
        case ..<40: return Color(red: 0.97, green: 0.80, blue: 0.15)
        case ..<52: return Color(red: 1.00, green: 0.50, blue: 0.05)
        default:    return Color(red: 1.00, green: 0.20, blue: 0.12)
        }
    }
}
