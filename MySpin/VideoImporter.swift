// VideoImporter.swift
// Dodawanie filmów na ekran „Wideo” prosto w telefonie: film z Galerii albo Plików
// przerabiany jest RAZ na gotowe klatki JPEG deski — ten sam format co video_tt.mjpg
// z tools/video_frames.py (864×320 wypełnienie z przycięciem, 15 klatek/s).
// Potem odtwarzanie nie dekoduje niczego i działa w tle (VideoFrameProvider).
//
// AVAssetReader + kompozycja wideo: obrót z nagrania, skalowanie i przycięcie robi
// Core Image, a kompozycja sama podaje klatki co 1/15 s. Przeróbka idzie na GPU,
// więc apka musi być na wierzchu (iOS nie daje GPU w tle).
// Bez dźwięku — deska go nie odtwarza.

import AVFoundation
import CoreImage
import UIKit

nonisolated enum VideoImporter {

    static let width = 864, height = 320, fps: Int32 = 15
    static let jpegQuality = 0.5   // ~20–30 kB na klatkę; mniejsza klatka = płynniej na desce

    enum Failure: LocalizedError {
        case noVideo, readFailed(String), tooLong
        var errorDescription: String? {
            switch self {
            case .noVideo: return String(localized: "w pliku nie ma obrazu")
            case .readFailed(let why): return String(localized: "nie da się odczytać filmu (\(why))")
            case .tooLong: return String(localized: "film za długi (limit 3 h)")
            }
        }
    }

    /// Przerabia film `src` na plik klatek `dst`. Zwraca liczbę klatek.
    @discardableResult
    static func convert(_ src: URL, to dst: URL, progress: @escaping (Double) -> Void) async throws -> Int {
        let asset = AVURLAsset(url: src)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        guard duration < 3 * 3600 else { throw Failure.tooLong }

        let W = CGFloat(width), H = CGFloat(height)
        let comp = try await AVMutableVideoComposition.videoComposition(with: asset) { req in
            // Obraz już obrócony jak w nagraniu. Wypełnienie 864×320 z przycięciem środka.
            let img = req.sourceImage
            let e = img.extent
            let s = max(W / e.width, H / e.height)
            let out = img
                .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
                .transformed(by: CGAffineTransform(translationX: (W - e.width * s) / 2, y: (H - e.height * s) / 2))
                .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
            req.finish(with: out, context: nil)
        }
        comp.renderSize = CGSize(width: W, height: H)
        comp.frameDuration = CMTime(value: 1, timescale: fps)

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw Failure.readFailed(error.localizedDescription) }
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = comp
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw Failure.readFailed(reader.error?.localizedDescription ?? "start")
        }

        // Klatki najpierw do pliku tymczasowego; nagłówek z przesunięciami na końcu.
        let fm = FileManager.default
        let framesURL = dst.appendingPathExtension("frames")
        fm.createFile(atPath: framesURL.path, contents: nil)
        defer { try? fm.removeItem(at: framesURL) }
        let frames = try FileHandle(forWritingTo: framesURL)
        var offsets: [UInt32] = []
        var pos: UInt32 = 0

        let ctx = CIContext()
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let opts = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): jpegQuality]
        // Czytnik podaje KAŻDĄ klatkę źródła (frameDuration kompozycji go nie obchodzi),
        // więc klatka k pliku = ostatnia klatka źródła z czasem ≤ k/15 s: przy 30/60 kl./s
        // nadmiar odpada, przy wolniejszym źródle klatka się powtarza. Kodowana raz.
        let step = 1 / Double(fps)
        var k = 0
        var pending: CMSampleBuffer?
        var pendingJPEG: Data?
        func emit() throws {
            if pendingJPEG == nil {
                pendingJPEG = autoreleasepool {
                    pending.flatMap(CMSampleBufferGetImageBuffer).flatMap {
                        ctx.jpegRepresentation(of: CIImage(cvPixelBuffer: $0), colorSpace: cs, options: opts)
                    }
                }
            }
            guard let jpeg = pendingJPEG else { pending = nil; return }
            try frames.write(contentsOf: jpeg)
            offsets.append(pos)
            pos += UInt32(jpeg.count)
            k += 1
        }
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard t.isFinite else { continue }
            while pending != nil, Double(k) * step < t - 0.001 { try emit() }
            pending = sample
            pendingJPEG = nil
            if duration > 0 { progress(min(1, t / duration)) }
        }
        while pending != nil, Double(k) * step < max(duration, step) - 0.001 { try emit() }
        try frames.close()
        if reader.status == .failed {
            throw Failure.readFailed(reader.error?.localizedDescription ?? String(localized: "przerwane — apka zeszła w tło?"))
        }
        guard !offsets.isEmpty else { throw Failure.readFailed(String(localized: "brak klatek")) }
        offsets.append(pos)

        // "MSV1" u16 fps u16 0 u32 liczba (liczba+1)×u32 przesunięcia, potem klatki.
        var header = Data("MSV1".utf8)
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        le(UInt16(fps)); le(UInt16(0)); le(UInt32(offsets.count - 1))
        offsets.forEach { le($0) }

        let part = dst.appendingPathExtension("part")
        fm.createFile(atPath: part.path, contents: header)
        let out = try FileHandle(forWritingTo: part)
        try out.seekToEnd()
        let input = try FileHandle(forReadingFrom: framesURL)
        while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try input.close()
        try out.close()
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.moveItem(at: part, to: dst)
        progress(1)
        return offsets.count - 1
    }
}
