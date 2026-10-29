// MapSnapshotManager.swift
// Żywa mapa CarPlay-style przez MKMapSnapshotter (Apple Maps).
// Renderuje snapshot co 1.5s wyśrodkowany na GPS, obrócony w kierunku jazdy (heading-up).
// Kafelki cache'owane przez MapKit; ruch sieciowy idzie przez LTE gdy WiFi moto bez internetu.

import MapKit
import UIKit
import Combine

final class MapSnapshotManager: ObservableObject {

    /// Ostatni wyrenderowany obraz mapy (rozmiar = mapSize).
    @Published private(set) var mapImage: UIImage?

    /// Rozmiar snapshotu — musi pasować do panelu centralnego w FrameRenderer.
    static let mapSize = CGSize(width: 494, height: 320)

    weak var motion: MotionManager?
    weak var nav:    NavManager?
    var dark: Bool = true

    private var timer: DispatchSourceTimer?
    private var rendering = false

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.2, repeating: 1.5, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        tick()
    }

    func stop() {
        timer?.cancel(); timer = nil
    }

    private func tick() {
        guard !rendering, let coord = motion?.lastLocationCoord else { return }
        rendering = true
        let heading = motion?.headingDeg ?? -1

        let opts = MKMapSnapshotter.Options()
        opts.size  = Self.mapSize
        opts.scale = 1
        opts.mapType = .mutedStandard
        opts.pointOfInterestFilter = .excludingAll
        opts.camera = MKMapCamera(lookingAtCenter: coord,
                                  fromDistance: 450, pitch: 0,
                                  heading: heading >= 0 ? heading : 0)
        opts.traitCollection = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)

        let routeCoords = nav?.routeCoords ?? []

        let snap = MKMapSnapshotter(options: opts)
        snap.start(with: DispatchQueue.global(qos: .userInitiated)) { [weak self] snapshot, _ in
            var img = snapshot?.image
            // Narysuj trasę nawigacji na mapie (jeśli aktywna)
            if let snapshot, routeCoords.count > 1 {
                img = UIGraphicsImageRenderer(size: Self.mapSize).image { _ in
                    snapshot.image.draw(at: .zero)
                    let path = UIBezierPath()
                    var started = false
                    for c in routeCoords {
                        let pt = snapshot.point(for: c)
                        if !started { path.move(to: pt); started = true }
                        else        { path.addLine(to: pt) }
                    }
                    path.lineWidth = 6; path.lineJoinStyle = .round; path.lineCapStyle = .round
                    UIColor.white.withAlphaComponent(0.6).setStroke(); path.lineWidth = 8; path.stroke()
                    UIColor.systemBlue.setStroke(); path.lineWidth = 5; path.stroke()
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.rendering = false
                if let img { self.mapImage = img }
            }
        }
    }
}
