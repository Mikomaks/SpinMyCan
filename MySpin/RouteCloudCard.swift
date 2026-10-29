// RouteCloudCard.swift
// Karta w ustawieniach (sekcja „Jazda”): folder tras w iCloud Drive — RouteCloudSync.

import SwiftUI
import UniformTypeIdentifiers

struct RouteCloudCard: View {
    @ObservedObject var cloud = RouteCloudSync.shared
    @State private var pickFolder = false
    @State private var confirmDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader("Trasy w iCloud Drive", icon: "icloud.fill", tint: .blue) {
                if cloud.busy { ProgressView() }
            }

            if let name = cloud.folderName {
                Text("Folder: \(name) · tras w chmurze: \(cloud.cloudCount)"
                     + (cloud.cloudOnlyCount > 0 ? " · tylko w chmurze: \(cloud.cloudOnlyCount)" : ""))
                    .font(.subheadline)
                Text("Każda trasa trafia do folderu zaraz po zapisaniu. Trasy starsze niż \(RouteCloudSync.keepLocalDays) dni znikają z telefonu, gdy iCloud potwierdzi kopię — dalej są w bibliotece, otwarcie ściąga je z chmury.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Synchronizuj") { cloud.sync() }
                    Button("Zmień folder") { pickFolder = true }
                    Button("Odłącz", role: .destructive) { confirmDisconnect = true }
                }
                .buttonStyle(.bordered)
                .disabled(cloud.busy)
            } else {
                Text("Wskaż folder na iCloud Drive (np. utwórz „MySpin”), a apka będzie tam kopiować trasy i zwalniać miejsce w telefonie.")
                    .font(.caption).foregroundStyle(.secondary)
                Button { pickFolder = true } label: {
                    Label("Wybierz folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if !cloud.status.isEmpty {
                Text(cloud.status).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .card()
        .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { cloud.setFolder(url) }
        }
        .confirmationDialog("Odłączyć folder?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Odłącz", role: .destructive) { cloud.disconnect() }
        } message: {
            Text("Trasy, których nie ma w telefonie, najpierw zostaną ściągnięte z chmury. Kopie w folderze zostają.")
        }
    }
}
