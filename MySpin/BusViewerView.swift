// BusViewerView.swift
// Podgląd magistrali CAN na żywo: znane sygnały, każde ID z bieżącymi bajtami
// i prosta metoda różnicowa do samodzielnego szukania nowych sygnałów —
// zapamiętaj stan spoczynkowy, rusz dźwignią albo przełącznikiem i zobacz,
// który bajt zareagował. Cała logika siedzi w BusTable (BikeLinkManager.swift).

import SwiftUI

struct BusViewerView: View {
    @ObservedObject var link: BikeLinkManager
    /// Czy zapis logu jest włączony — znaczniki mają sens tylko wtedy.
    var loggingOn: Bool
    /// Przechył liczony przez telefon — do porównania z czujnikiem motocykla na żywo.
    var phoneLean: Double = 0
    @Environment(\.dismiss) private var dismiss

    @State private var marker = ""
    @State private var files: [URL] = []
    @State private var confirmDelete = false

    private var changed: [BusRow] { link.busRows.filter { $0.diff != 0 } }

    var body: some View {
        NavigationView {
            List {
                if let t = link.live {
                    Section("Znane sygnały") { knownSignals(t) }
                }

                Section {
                    HStack(spacing: 10) {
                        Button {
                            link.learnBaseline()
                        } label: {
                            Label(link.busLearning ? "Uczę się tła…" : "Zapamiętaj stan (3 s)",
                                  systemImage: "scope")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(link.busLearning || link.busRows.isEmpty)

                        if link.busRows.contains(where: { $0.baseline != nil }) {
                            Button("Wyczyść") { link.clearBaseline() }
                                .buttonStyle(.bordered)
                        }
                    }
                    if link.busLearning {
                        Text("Nie ruszaj niczego przez 3 sekundy — sprawdzam, które bajty zmieniają się same.")
                            .font(.caption).foregroundColor(.secondary)
                    } else if link.busRows.contains(where: { $0.baseline != nil }) {
                        if changed.isEmpty {
                            Text("Teraz wciśnij hamulec, sprzęgło, przełącznik… Tu pojawi się bajt, który zareagował.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        ForEach(changed) { row in
                            ForEach(0..<row.data.count, id: \.self) { i in
                                if row.diff & (1 << i) != 0, let base = row.baseline, i < base.count {
                                    HStack {
                                        Text(String(format: "%03X  bajt %d", row.id, i))
                                            .font(.system(.body, design: .monospaced).weight(.semibold))
                                        Spacer()
                                        Text(String(format: "%d → %d", base[i], row.data[i]))
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundColor(.red)
                                        Text(String(format: "(%02X → %02X)", base[i], row.data[i]))
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    } else {
                        Text("Zapamiętaj stan spoczynkowy, a potem rusz jedną rzeczą naraz — zobaczysz, który bajt na nią reaguje.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                } header: {
                    Text("Szukanie sygnału")
                }

                Section {
                    if link.busRows.isEmpty {
                        Text(link.state == .connected
                             ? "Płytka połączona, ale magistrala milczy (zapłon wyłączony albo płytka nie jest wpięta)."
                             : link.state.label)
                            .font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(link.busRows) { BusRowLine(row: $0) }
                } header: {
                    Text("Magistrala · \(link.busRows.count) ID")
                } footer: {
                    Text("Pomarańczowy = zmienił się w ostatniej sekundzie, szary = szum tła, czerwony = różni się od zapamiętanego stanu.")
                }

                Section("Znacznik w logu") {
                    if loggingOn, !link.logName.isEmpty {
                        HStack {
                            TextField("np. temperatura na zegarach 92", text: $marker)
                                .submitLabel(.done)
                                .onSubmit(addMarker)
                            Button("Dodaj", action: addMarker)
                                .disabled(marker.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if link.markerCount > 0 {
                            Text("Znaczników w tym logu: \(link.markerCount)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    } else {
                        Text("Znaczniki trafiają do pliku logu — włącz „Zapis ramek” i poczekaj na pierwsze ramki.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                Section {
                    if files.isEmpty {
                        Text("Brak zapisanych logów.").font(.caption).foregroundColor(.secondary)
                    }
                    ForEach(files, id: \.self) { f in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.lastPathComponent)
                                    .font(.system(.footnote, design: .monospaced))
                                Text(String(format: "%.1f MB", Double(BikeLinkManager.fileSize(f)) / 1_048_576)
                                     + (f.lastPathComponent == link.logName && loggingOn ? " · nagrywany" : ""))
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button { share([f]) } label: { Image(systemName: "square.and.arrow.up") }
                                .buttonStyle(.borderless)
                        }
                    }
                    if !files.isEmpty {
                        Button("Usuń wszystkie logi", role: .destructive) { confirmDelete = true }
                    }
                } header: {
                    Text(String(format: "Logi · %.0f MB", Double(link.logTotalBytes) / 1_048_576))
                } footer: {
                    Text(String(format: "Limit %.0f MB — po przekroczeniu znikają najstarsze pliki.",
                                Double(BikeLinkManager.logQuotaBytes) / 1_048_576))
                }
            }
            .navigationTitle("Magistrala CAN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BackButton { dismiss() }
                }
            }
            .confirmationDialog("Usunąć wszystkie zapisane logi magistrali?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Usuń", role: .destructive) {
                    link.deleteAllLogs()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { files = BikeLinkManager.logFiles() }
                }
                Button("Anuluj", role: .cancel) { }
            }
        }
        .onAppear {
            link.setViewerActive(true)
            files = BikeLinkManager.logFiles()
        }
        .onDisappear { link.setViewerActive(false) }
    }

    @ViewBuilder
    private func knownSignals(_ t: BikeTelemetry) -> some View {
        if t.simulated {
            Label("Płytka nadaje dane testowe (program symulacyjny) — nie wpinaj jej tak w motocykl.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundColor(.orange)
        }
        signal("Obroty", t.engineFresh ? "\(t.rpm) obr/min" : "—")
        signal("Bieg", t.engineFresh ? (t.gear == 0 ? "N" : "\(t.gear)") : "—")
        signal("Gaz", t.engineFresh ? String(format: "%d (ok. %.0f%%)", t.throttle10,
                                             min(100, Double(t.throttle10) / 6.9)) : "—")
        signal("Przechył", t.leanFresh ? String(format: "%.1f° %@", abs(t.leanDeg),
                                                t.leanDeg < -0.5 ? "w lewo" : (t.leanDeg > 0.5 ? "w prawo" : "")) : "—")
        if t.leanFresh {
            signal("Przechył wg telefonu", String(format: "%.1f° %@ · różnica %.1f°", abs(phoneLean),
                                                  phoneLean < -0.5 ? "w lewo" : (phoneLean > 0.5 ? "w prawo" : ""),
                                                  abs(t.leanDeg - phoneLean)))
        }
        signal("Przyspieszenia", t.accelFresh ? String(format: "wzdł. %+.2f g · pion %+.2f g · bok %+.2f g",
                                                       t.accelG[0], t.accelG[1], t.accelG[2]) : "—")
        signal("Licznik koła (próbnie)", link.wheelRate.map { String(format: "%.1f impulsów/s", $0) } ?? "—")
        signal("Magistrala", "\(t.busFps) ramek/s")
        signal("Program płytki", t.fwVersion == 0 ? "wersja sprzed numeracji"
               : "v\(t.fwVersion)" + (t.fwVersion < BikeLinkManager.currentFirmware ? " (jest nowszy: v\(BikeLinkManager.currentFirmware))" : ""))
    }

    private func signal(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).font(.subheadline)
            Spacer()
            Text(value).font(.system(.subheadline, design: .monospaced)).foregroundColor(.secondary)
        }
    }

    private func addMarker() {
        link.addMarker(marker)
        marker = ""
    }

    private func share(_ items: [URL]) {
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root  = scene.windows.first?.rootViewController {
            var vc = root
            while let pres = vc.presentedViewController { vc = pres }
            vc.present(av, animated: true)
        }
    }
}

/// Jeden wiersz: ID, częstość i bajty pokolorowane wg tego, co się z nimi dzieje.
private struct BusRowLine: View {
    let row: BusRow

    var body: some View {
        HStack(spacing: 8) {
            Text(String(format: "%03X", row.id))
                .font(.system(.footnote, design: .monospaced).weight(.bold))
                .frame(width: 34, alignment: .leading)
            Text(String(format: "%.0f/s", row.rate))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
            HStack(spacing: 5) {
                ForEach(0..<row.data.count, id: \.self) { i in
                    Text(String(format: "%02X", row.data[i]))
                        .font(.system(.footnote, design: .monospaced)
                            .weight(row.diff & (1 << i) != 0 ? .heavy : .regular))
                        .foregroundColor(color(i))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    private func color(_ i: Int) -> Color {
        let bit = UInt8(1) << i
        if row.diff & bit != 0 { return .red }
        if row.noisy & bit != 0 { return Color(.tertiaryLabel) }
        if row.recent & bit != 0 { return .orange }
        return .primary
    }
}
