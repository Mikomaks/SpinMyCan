// VideoPlaylistCard.swift
// Karta ekranu „Wideo” na ekranie głównym: playlista, dodawanie filmów z Galerii
// i Plików (przeróbka w telefonie — VideoImporter), wybór i usuwanie.
// Osobny widok, żeby obserwował tylko VideoFrameProvider, a nie całą apkę.

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct VideoPlaylistCard: View {
    @ObservedObject var video: VideoFrameProvider

    @State private var photoPick: PhotosPickerItem?
    @State private var showFiles = false
    @State private var toDelete: VideoFrameProvider.Item?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader("Wideo — playlista", icon: "play.rectangle.fill", tint: .red) {
                Button { video.togglePause() } label: {
                    Image(systemName: video.paused ? "play.fill" : "pause.fill")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
            }

            ForEach(video.items) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.id == video.currentID ? "play.fill" : "film")
                        .foregroundStyle(item.id == video.currentID ? .red : .secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).lineLimit(1)
                        Text(Self.clock(item.seconds) + (item.builtin ? " · wbudowany" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !item.builtin {
                        Button { toDelete = item } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .tint(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { video.select(item.id) }
            }

            if let p = video.importProgress {
                ProgressView(value: p) {
                    Text(video.importStatus ?? "Przerabiam…").font(.caption)
                }
                Text("Trzymaj apkę na wierzchu do końca przeróbki.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if loading {
                ProgressView { Text("Pobieram film z Galerii…").font(.caption) }
            } else {
                if let status = video.importStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    PhotosPicker(selection: $photoPick, matching: .videos) {
                        Label("Z Galerii", systemImage: "photo.on.rectangle")
                    }
                    Button { showFiles = true } label: {
                        Label("Z Plików", systemImage: "folder")
                    }
                }
                .buttonStyle(.bordered)
            }

            Text("Joystick: ◀ ▶ 10 s, OK pauza, 2× OK następny film.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
        .onChange(of: photoPick) { _, item in
            guard let item else { return }
            photoPick = nil
            loading = true
            Task {
                let movie = try? await item.loadTransferable(type: PickedMovie.self)
                loading = false
                if let movie { video.importVideo(from: movie.url, title: movie.title) }
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .video]) { result in
            guard case .success(let url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            if let copy = try? PickedMovie.copyToTemp(url) {
                video.importVideo(from: copy, title: url.deletingPathExtension().lastPathComponent)
            }
        }
        .confirmationDialog("Usunąć „\(toDelete?.title ?? "")” z playlisty?",
                            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Usuń", role: .destructive) {
                if let id = toDelete?.id { video.delete(id) }
                toDelete = nil
            }
        }
    }

    private static func clock(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Film z Galerii skopiowany do katalogu tymczasowego (VideoImporter usuwa go po przeróbce).
nonisolated struct PickedMovie: Transferable {
    let url: URL
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            PickedMovie(url: try copyToTemp(received.file),
                        title: received.file.deletingPathExtension().lastPathComponent)
        }
    }

    static func copyToTemp(_ src: URL) throws -> URL {
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(src.pathExtension)
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }
}
