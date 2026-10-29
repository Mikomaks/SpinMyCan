// SessionLibraryView.swift
// Biblioteka nagranych sesji + odtwarzacz tras (mapa + timeline charts).
//
//   SessionLibraryView    → lista sesji (sheet)
//     ↓ tap
//   SessionPlayerView     → mapa z polyline, timeline prędkości i lean,
//                           transport controls, eksport CSV i screenshot share.

import SwiftUI
import MapKit
import Charts
import UIKit

// MARK: — Lista sesji

struct SessionLibraryView: View {
    @ObservedObject var storage: SessionStorage
    /// Callback do startu replay'a — ContentView przekazuje SessionSummary do ReplayManager.
    let onPlay: (SessionSummary) -> Void
    @Environment(\.dismiss) var dismiss

    /// Tryb wielokrotnego wyboru do scalania tras
    @State private var selectMode: Bool = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var concatBusy: Bool = false
    @State private var concatStatus: String? = nil

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy  HH:mm"
        return f
    }()

    private func fmtDur(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, ss = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss)
                     : String(format: "%02d:%02d", m, ss)
    }

    var body: some View {
        NavigationView {
            Group {
                if storage.library.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(storage.library) { meta in
                            sessionRowView(meta)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(selectMode ? String(localized: "Wybierz trasy") : String(localized: "Biblioteka tras"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if storage.library.count >= 2 {
                        Button(selectMode ? String(localized: "Anuluj") : String(localized: "Wybierz")) {
                            selectMode.toggle()
                            if !selectMode { selectedIDs.removeAll() }
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    BackButton { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selectMode {
                    concatBar
                } else if let status = concatStatus {
                    Text(status)
                        .font(.caption)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Color.green.opacity(0.15))
                }
            }
        }
    }

    // ── Pasek "Połącz X tras" gdy multi-select ──
    private var concatBar: some View {
        HStack {
            Text(selectedIDs.isEmpty
                 ? String(localized: "Zaznacz 2+ trasy do połączenia")
                 : String(localized: "Wybrano: \(selectedIDs.count)"))
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Button {
                concatenateSelected()
            } label: {
                if concatBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Label(String(localized: "session.merge", defaultValue: "Połącz", comment: "Łączenie kilku tras w jedną"), systemImage: "rectangle.stack.badge.plus")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(selectedIDs.count < 2 || concatBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // ── Pojedynczy wiersz: zachowuje się różnie w trybie wyboru ──
    @ViewBuilder
    private func sessionRowView(_ meta: SessionMeta) -> some View {
        if selectMode {
            Button {
                if selectedIDs.contains(meta.id) { selectedIDs.remove(meta.id) }
                else                              { selectedIDs.insert(meta.id) }
            } label: {
                HStack {
                    Image(systemName: selectedIDs.contains(meta.id)
                          ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selectedIDs.contains(meta.id) ? .purple : .secondary)
                        .font(.title3)
                    row(meta)
                }
            }
            .buttonStyle(.plain)
        } else {
            Button {
                if let s = storage.load(id: meta.id) {
                    onPlay(s)
                    dismiss()
                }
            } label: { row(meta) }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { storage.delete(id: meta.id) }
                    label: { Label("Usuń", systemImage: "trash") }
                Button {
                    if let s = storage.load(id: meta.id) { SessionShareHelper.exportCSV(s) }
                } label: { Label("CSV", systemImage: "doc.text") }.tint(.blue)
                Button {
                    if let s = storage.load(id: meta.id) { SessionShareHelper.shareScreenshot(s) }
                } label: { Label("Udostępnij", systemImage: "square.and.arrow.up") }.tint(.purple)
                if meta.isMerged {
                    Button {
                        if let s = storage.load(id: meta.id) {
                            storage.split(s)
                        }
                    } label: { Label("Rozdziel", systemImage: "rectangle.split.2x1") }.tint(.indigo)
                }
            }
        }
    }

    private func concatenateSelected() {
        concatBusy = true
        let ids = Array(selectedIDs)
        DispatchQueue.global(qos: .userInitiated).async {
            let summaries = ids.compactMap { storage.load(id: $0) }
            let merged = storage.concatenate(summaries)
            DispatchQueue.main.async {
                concatBusy = false
                if let m = merged {
                    concatStatus = String(localized: "✅ Połączono \(summaries.count) tras → \(String(format: "%.1f km", m.totalDistKm))")
                    selectMode = false
                    selectedIDs.removeAll()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                        concatStatus = nil
                    }
                } else {
                    concatStatus = String(localized: "❌ Błąd łączenia")
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("Brak nagranych tras")
                .font(.headline)
            Text("Nagraj sesję jazdy z karty 'Sesja jazdy'. Po zatrzymaniu trasa zostanie zapisana automatycznie i pojawi się tutaj.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(_ m: SessionMeta) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Self.dateFmt.string(from: m.startTime))
                    .font(.subheadline.bold())
                Spacer()
                Text(fmtDur(m.durationSec))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 14) {
                Label(String(format: "%.1f km", m.totalDistKm),
                      systemImage: "arrow.right.circle")
                    .foregroundColor(.green)
                Label("\(Int(m.maxSpeedKmh)) km/h",
                      systemImage: "speedometer")
                    .foregroundColor(.cyan)
                Label(String(format: "%.0f°/%.0f°", m.maxLeanLeft, m.maxLeanRight),
                      systemImage: "scope")
                    .foregroundColor(.orange)
            }
            .font(.system(size: 11, design: .monospaced))
        }
        .padding(.vertical, 4)
    }
}

// MARK: — Odtwarzacz: mapa + charts

struct SessionPlayerView: View {
    @ObservedObject var replay: ReplayManager
    @Environment(\.dismiss) var dismiss

    /// Cache downsampled samples — obliczane RAZ w onAppear żeby Charts
    /// nie rebuildował tysięcy LineMarków przy każdym ticku replay'a.
    @State private var speedSamples: [(time: Double, value: Double)] = []
    @State private var leanSamples:  [(time: Double, value: Double)] = []
    @State private var sessionLoadedID: UUID? = nil

    /// Max liczba punktów dla chart'a — powyżej tego downsamplujemy.
    private let chartMaxSamples = 250

    private func fmtTime(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, ss = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss)
                     : String(format: "%02d:%02d", m, ss)
    }

    /// Czas (s) bieżącej pozycji w obrębie sesji.
    private var currentTime: Double {
        replay.progress * Double(replay.summary?.durationSec ?? 0)
    }

    /// Uniform-stride downsampling. Dla 3600 punktów → 250 = co 14-ty punkt.
    /// Lossy ale wizualnie OK (wystarcza do trendline'a w 130px chart'cie).
    private static func downsample(_ values: [(time: Double, value: Double)],
                                    target: Int) -> [(time: Double, value: Double)] {
        guard values.count > target, target > 0 else { return values }
        let stride = Double(values.count - 1) / Double(target - 1)
        var out: [(Double, Double)] = []
        out.reserveCapacity(target)
        for i in 0..<target {
            let idx = Int((Double(i) * stride).rounded())
            out.append(values[min(idx, values.count - 1)])
        }
        return out
    }

    /// Załaduj samples z aktualnej sesji — wywoływane raz przy onAppear / zmianie summary
    private func reloadSamples() {
        guard let s = replay.summary else { return }
        // Skip jeśli już załadowane dla tej sesji
        if sessionLoadedID == s.id { return }

        let raw = s.points.map {
            ($0.timestamp.timeIntervalSince(s.startTime), $0.speedKmh, $0.leanDeg)
        }
        speedSamples = Self.downsample(raw.map { ($0.0, $0.1) }, target: chartMaxSamples)
        leanSamples  = Self.downsample(raw.map { ($0.0, $0.2) }, target: chartMaxSamples)
        sessionLoadedID = s.id
    }

    var body: some View {
        NavigationView {
            ScrollView {
                if let s = replay.summary {
                    VStack(spacing: 14) {
                        // ── Mapa trasy ──
                        RouteMapView(points: s.points, currentIndex: replay.curIndex,
                                     maxLeanLeft: s.maxLeanLeft, maxLeanRight: s.maxLeanRight)
                            .frame(height: 280)
                            .cornerRadius(12)
                            .padding(.horizontal)

                        // ── Hero stats ──
                        statsBar(s)

                        // ── Speed chart ──
                        TimelineChartView(
                            title: String(localized: "Prędkość"),
                            unit:  "km/h",
                            color: .cyan,
                            values: speedSamples,
                            currentTime: currentTime,
                            duration:    Double(s.durationSec),
                            valueFormatter: { String(format: "%.0f", $0) },
                            includeAreaFill: true
                        ) { t in
                            replay.seek(to: min(max(t / Double(s.durationSec), 0), 1))
                        }
                        .frame(height: 130)
                        .padding(.horizontal)

                        // ── Lean chart ──
                        TimelineChartView(
                            title: "Lean",
                            unit:  "°",
                            color: .orange,
                            values: leanSamples,
                            currentTime: currentTime,
                            duration:    Double(s.durationSec),
                            valueFormatter: { String(format: "%.1f", $0) },
                            includeAreaFill: false,
                            showZeroLine: true
                        ) { t in
                            replay.seek(to: min(max(t / Double(s.durationSec), 0), 1))
                        }
                        .frame(height: 130)
                        .padding(.horizontal)

                        // ── Eksport / Share ──
                        HStack(spacing: 10) {
                            Button {
                                SessionShareHelper.exportCSV(s)
                            } label: {
                                Label("CSV", systemImage: "doc.text")
                                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue)

                            Button {
                                SessionShareHelper.shareScreenshot(s)
                            } label: {
                                Label("Udostępnij", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                        }
                        .padding(.horizontal)

                        // ── Czas, przeciążenie, silnik, piosenki ──
                        RideExtrasView(summary: s, seek: { t in
                            replay.seek(to: min(max(t / Double(max(1, s.durationSec)), 0), 1))
                        }, onDeleted: {
                            replay.pause()
                            replay.unload()
                            dismiss()
                        })

                        Spacer(minLength: 20)
                    }
                    .padding(.top, 8)
                } else {
                    Text("Brak załadowanej sesji").foregroundColor(.secondary).padding()
                }
            }
            .safeAreaInset(edge: .bottom) {
                transportBar
            }
            .navigationTitle(playerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BackButton {
                        replay.pause()
                        replay.unload()
                        dismiss()
                    }
                }
            }
        }
        .onAppear { reloadSamples() }
        .onChange(of: replay.summary?.id) { _, _ in reloadSamples() }
        .onDisappear {
            replay.pause()
        }
    }

    // ── Tytuł nawigacji ──
    private var playerTitle: String {
        guard let s = replay.summary else { return String(localized: "Odtwarzanie") }
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm"
        return f.string(from: s.startTime)
    }

    // ── Stats bar ──
    @ViewBuilder
    private func statsBar(_ s: SessionSummary) -> some View {
        HStack(spacing: 0) {
            statBox(String(localized: "DYSTANS"), String(format: "%.1f", s.totalDistKm), "km", .green)
            Divider().frame(height: 32)
            statBox("MAX",     "\(Int(s.maxSpeedKmh))",                "km/h", .cyan)
            Divider().frame(height: 32)
            statBox(String(localized: "ŚREDNIA"), "\(Int(s.avgSpeedKmh))",                "km/h", .blue)
            Divider().frame(height: 32)
            statBox("LEAN",    String(format: "%.0f°/%.0f°",
                                       min(s.maxLeanLeft, 65),
                                       min(s.maxLeanRight, 65)),       "L/R", .orange)
        }
        .padding(.vertical, 10)
        .background(Color(.systemGray6))
        .cornerRadius(10)
        .padding(.horizontal)
    }

    @ViewBuilder
    private func statBox(_ label: String, _ value: String, _ unit: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundColor(color)
                Text(unit).font(.system(size: 9, weight: .bold)).foregroundColor(.secondary)
            }
            Text(label).font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary).tracking(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    // ── Transport: scrubber + play/pause/speed ──
    private var transportBar: some View {
        VStack(spacing: 8) {
            // Scrubber
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.systemGray5)).frame(height: 5)
                    Capsule().fill(Color.purple)
                        .frame(width: max(geo.size.width * CGFloat(replay.progress), 0), height: 5)
                    Circle().fill(Color.white)
                        .overlay(Circle().stroke(Color.purple, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .offset(x: max(geo.size.width * CGFloat(replay.progress) - 7, -7))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let p = max(0, min(1, v.location.x / geo.size.width))
                            replay.seek(to: Double(p))
                        }
                )
            }
            .frame(height: 20)
            .padding(.horizontal, 16)

            HStack {
                Text(fmtTime(Int(currentTime)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text(fmtTime(replay.summary?.durationSec ?? 0))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)

            // Transport
            HStack(spacing: 30) {
                Button { replay.seek(to: 0) } label: {
                    Image(systemName: "backward.end.fill").font(.title2)
                }
                Button { replay.togglePlayPause() } label: {
                    Image(systemName: replay.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.purple)
                }
                Button { replay.cycleSpeed() } label: {
                    Text(String(format: "%.1fx", replay.speedMult))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .frame(width: 50, height: 32)
                        .background(Color.purple.opacity(0.15))
                        .cornerRadius(8)
                        .foregroundColor(.purple)
                }
            }
            .padding(.bottom, 8)
        }
        .padding(.top, 6)
        .background(.ultraThinMaterial)
    }
}

// MARK: — Speed color helper (shared: live map + screenshot)

/// Gradient 4-strefowy prędkości:
///  0–50 km/h   →  zielony
///  50–100 km/h →  amber
///  100–150 km/h→  czerwony
///  150–200 km/h→  fioletowy
private func speedColor(_ kmh: Double) -> UIColor {
    struct Anchor { let kmh: Double; let r, g, b: CGFloat }
    let anchors: [Anchor] = [
        Anchor(kmh:   0, r: 0.13, g: 0.73, b: 0.34),   // zielony
        Anchor(kmh:  50, r: 0.13, g: 0.73, b: 0.34),   // zielony (utrzymaj do 50)
        Anchor(kmh: 100, r: 0.96, g: 0.65, b: 0.14),   // amber
        Anchor(kmh: 150, r: 1.00, g: 0.27, b: 0.27),   // czerwony
        Anchor(kmh: 200, r: 0.76, g: 0.00, b: 0.96),   // fioletowy
    ]
    let v = max(0, min(kmh, 200))
    for i in 1..<anchors.count {
        if v <= anchors[i].kmh {
            let t  = CGFloat((v - anchors[i-1].kmh) / (anchors[i].kmh - anchors[i-1].kmh))
            let lo = anchors[i-1], hi = anchors[i]
            return UIColor(red:   lo.r + (hi.r - lo.r) * t,
                           green: lo.g + (hi.g - lo.g) * t,
                           blue:  lo.b + (hi.b - lo.b) * t, alpha: 1)
        }
    }
    return UIColor(red: 0.76, green: 0.00, blue: 0.96, alpha: 1)
}

// MARK: — SpeedGradientPolyline + Renderer (live MKMapView)

/// Nakładka będąca kontenerem punktów sesji — renderer sam koloruje segmenty.
final class SpeedGradientPolyline: NSObject, MKOverlay {
    let sessionPoints: [SessionPoint]
    let coordinate:    CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    init(points: [SessionPoint]) {
        sessionPoints = points
        let gps = points.filter { $0.latitude != 0 && $0.longitude != 0 }
        coordinate = gps.first.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        } ?? CLLocationCoordinate2D()
        var rect = MKMapRect.null
        for p in gps {
            let mp = MKMapPoint(CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude))
            rect = rect.union(MKMapRect(x: mp.x - 1, y: mp.y - 1, width: 2, height: 2))
        }
        boundingMapRect = rect.isNull ? .world : rect
        super.init()
    }
}

/// Rysuje trasę segment po segmencie, każdy w kolorze odpowiadającym prędkości.
final class SpeedGradientRenderer: MKOverlayRenderer {

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        guard let poly = overlay as? SpeedGradientPolyline else { return }
        let pts     = poly.sessionPoints
        let lineW   = max(3.5 / CGFloat(zoomScale), 1.0)

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setShouldAntialias(true)

        // ── Cień (pass 1) ──
        ctx.setLineWidth(lineW + 4)
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.22).cgColor)
        var prev: CGPoint? = nil
        for p in pts {
            guard p.latitude != 0, p.longitude != 0 else { prev = nil; continue }
            let cp = self.point(for: MKMapPoint(CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)))
            if let pv = prev { ctx.move(to: pv); ctx.addLine(to: cp); ctx.strokePath() }
            prev = cp
        }

        // ── Kolor wg prędkości (pass 2) ──
        ctx.setLineWidth(lineW)
        prev = nil
        for i in pts.indices {
            let p = pts[i]
            guard p.latitude != 0, p.longitude != 0 else { prev = nil; continue }
            let cp = self.point(for: MKMapPoint(CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)))
            if let pv = prev {
                let avgKmh = i > 0 ? (pts[i-1].speedKmh + p.speedKmh) / 2 : p.speedKmh
                ctx.setStrokeColor(speedColor(avgKmh).cgColor)
                ctx.move(to: pv); ctx.addLine(to: cp); ctx.strokePath()
            }
            prev = cp
        }
    }
}

// MARK: — RouteMapView (UIViewRepresentable wrapping MKMapView)

struct RouteMapView: UIViewRepresentable {
    let points: [SessionPoint]
    let currentIndex: Int
    var maxLeanLeft:  Double = 0   // z SessionSummary (30Hz) — do tytułu plakietki
    var maxLeanRight: Double = 0

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate                  = context.coordinator
        map.isUserInteractionEnabled  = true
        map.showsCompass              = false
        map.showsScale                = false
        map.pointOfInterestFilter     = .excludingAll
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Cache coords w coordinator — nie filtruj N punktów na każdy update
        if context.coordinator.coords.isEmpty {
            context.coordinator.coords = points.compactMap { p -> CLLocationCoordinate2D? in
                guard p.latitude != 0, p.longitude != 0,
                      p.latitude.isFinite, p.longitude.isFinite,
                      abs(p.latitude) <= 89.9, abs(p.longitude) <= 180 else { return nil }
                return CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)
            }
        }
        let coords = context.coordinator.coords
        guard !coords.isEmpty else { return }

        // First-time: dodaj polyline + endpoints + stat-piny + current marker, ustaw region
        if context.coordinator.routeLine == nil {
            // Gradient overlay zamiast standardowego MKPolyline
            let gradPoly = SpeedGradientPolyline(points: points)
            map.addOverlay(gradPoly, level: .aboveRoads)
            context.coordinator.routeLine = MKPolyline(coordinates: coords, count: 0) // placeholder

            if coords.count >= 2 {
                let start = TaggedAnnotation(kind: .start)
                start.coordinate = coords.first!
                map.addAnnotation(start)
                context.coordinator.startPin = start

                let end = TaggedAnnotation(kind: .end)
                end.coordinate = coords.last!
                map.addAnnotation(end)
                context.coordinator.endPin = end
            }

            // Stat-piny: max speed, max lean L, max lean R
            let movPts = points.filter { $0.isMoving && $0.latitude != 0 && $0.longitude != 0 }
            if let ms = movPts.max(by: { $0.speedKmh < $1.speedKmh }) {
                let ann = TaggedAnnotation(kind: .maxSpeed,
                                           title: "\(Int(ms.speedKmh)) km/h")
                ann.coordinate = CLLocationCoordinate2D(latitude: ms.latitude, longitude: ms.longitude)
                map.addAnnotation(ann)
            }
            // MAX LEAN — wartość bierzemy z PODSUMOWANIA (maxLeanLeft/Right), nie ze
            // skanu surowych punktów. Wcześniej plakietki skanowały punkty własnym,
            // luźniejszym filtrem (±75°) i łapały spike'i, które podsumowanie już
            // odrzuciło — przez to podgląd pokazywał inny lean niż eksport do JPEG
            // i pasek statystyk. Teraz jedno źródło prawdy; punkt służy tylko do
            // umiejscowienia plakietki (szukamy najbliższego tej wartości).
            func placeLeanPin(kind: TaggedAnnotation.Kind, value: Double, isLeft: Bool) {
                guard value > 2 else { return }
                let candidates = movPts.filter { isLeft ? $0.leanDeg < 0 : $0.leanDeg > 0 }
                guard let best = candidates.min(by: {
                    abs(abs($0.leanDeg) - value) < abs(abs($1.leanDeg) - value)
                }) else { return }
                let ann = TaggedAnnotation(kind: kind, title: String(format: "%.1f°", value))
                ann.coordinate = CLLocationCoordinate2D(latitude: best.latitude, longitude: best.longitude)
                map.addAnnotation(ann)
            }
            placeLeanPin(kind: .maxLeanL, value: min(maxLeanLeft, 65), isLeft: true)
            placeLeanPin(kind: .maxLeanR, value: min(maxLeanRight, 65), isLeft: false)

            let cur = TaggedAnnotation(kind: .current)
            cur.coordinate = coords.first!
            map.addAnnotation(cur)
            context.coordinator.currentPin = cur

            // Fit region
            var rect = MKMapRect.null
            for c in coords {
                let p = MKMapPoint(c)
                rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 1, height: 1))
            }
            map.setVisibleMapRect(rect,
                edgePadding: UIEdgeInsets(top: 30, left: 30, bottom: 30, right: 30),
                animated: false)
        }

        // Update current marker position
        if let cur = context.coordinator.currentPin {
            let idx = max(0, min(currentIndex, coords.count - 1))
            let target = coords[idx]
            // Tylko gdy się zmieniła pozycja — zapobiega niepotrzebnym redraw'om
            if cur.coordinate.latitude != target.latitude
                || cur.coordinate.longitude != target.longitude {
                cur.coordinate = target
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MKMapViewDelegate {
        var routeLine:  MKPolyline?
        var startPin:   MKPointAnnotation?
        var endPin:     MKPointAnnotation?
        var currentPin: MKPointAnnotation?
        var coords:     [CLLocationCoordinate2D] = []

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let grad = overlay as? SpeedGradientPolyline {
                return SpeedGradientRenderer(overlay: grad)
            }
            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = .systemPurple; r.lineWidth = 4; r.lineCap = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let tagged = annotation as? TaggedAnnotation else { return nil }
            let id = "ann.\(tagged.kind.rawValue)"

            switch tagged.kind {

            // ── Stat-plakietki: własny image (box + stem) zamiast MKMarkerAnnotationView ──
            case .maxSpeed, .maxLeanL, .maxLeanR:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: tagged, reuseIdentifier: id)
                view.annotation     = tagged
                view.canShowCallout = false
                let l1: String; let l2: String; let col: UIColor
                switch tagged.kind {
                case .maxSpeed: l1 = "MAX SPEED";  l2 = tagged.title ?? ""; col = .systemCyan
                case .maxLeanL: l1 = "MAX LEAN L"; l2 = tagged.title ?? ""; col = .systemBlue
                default:        l1 = "MAX LEAN R"; l2 = tagged.title ?? ""; col = .systemOrange
                }
                let img = Self.calloutImage(line1: l1, line2: l2, color: col)
                view.image = img
                // dot leży 12px od dołu obrazka → przesuwamy view w górę tak żeby dot = coordinate
                view.centerOffset = CGPoint(x: 0, y: -(img.size.height / 2 - 12))
                return view

            // ── Start / End / Current: kółka jak poprzednio ──
            default:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: tagged, reuseIdentifier: id)
                view.annotation     = tagged
                view.canShowCallout = false
                view.image          = Self.markerImage(kind: tagged.kind)
                return view
            }
        }

        /// Renderuje callout identyczny jak eksport (box kwadratowy + linia + grot + dot)
        /// jako UIImage pionowe: box na górze, dot na dole = punkt trasy.
        static func calloutImage(line1: String, line2: String, color: UIColor) -> UIImage {
            let f1 = UIFont.systemFont(ofSize: 10, weight: .semibold)
            let f2 = UIFont.systemFont(ofSize: 14, weight: .bold)
            let a1: [NSAttributedString.Key: Any] = [.font: f1,
                .foregroundColor: UIColor.white.withAlphaComponent(0.80)]
            let a2: [NSAttributedString.Key: Any] = [.font: f2, .foregroundColor: UIColor.white]
            let sz1 = (line1 as NSString).size(withAttributes: a1)
            let sz2 = (line2 as NSString).size(withAttributes: a2)
            let pW: CGFloat = 10, pH: CGFloat = 7, gap: CGFloat = 3
            let boxW = max(sz1.width, sz2.width) + pW * 2
            let boxH = sz1.height + gap + sz2.height + pH * 2
            let pad: CGFloat = 4
            let dotR: CGFloat = 6
            let arrowLen: CGFloat = 34   // odległość między dolną krawędzią boxu a centrum dota

            let totalW = boxW + pad * 2
            // dot leży (dotR+2)px od dołu canvas (ring), arrowLen od boxu
            let dotFromBottom: CGFloat = dotR + 2 + pad
            let totalH = pad + boxH + arrowLen + dotFromBottom * 2

            return UIGraphicsImageRenderer(size: CGSize(width: totalW, height: totalH)).image { _ in
                let cx = totalW / 2
                let boxRect  = CGRect(x: pad, y: pad, width: boxW, height: boxH)
                let dotY     = totalH - dotFromBottom
                let dotPt    = CGPoint(x: cx, y: dotY)
                let arrowTip = CGPoint(x: cx, y: dotY - (dotR + 3))
                let lineFrom = CGPoint(x: cx, y: boxRect.maxY)   // dolna krawędź boxu

                // Linia od boxu do grota
                let ln = UIBezierPath()
                ln.move(to: lineFrom); ln.addLine(to: arrowTip)
                ln.lineWidth = 1.5
                color.withAlphaComponent(0.90).setStroke(); ln.stroke()

                // Grot strzałki (trójkąt wskazujący w dół)
                let aS: CGFloat = 7
                let ah = UIBezierPath()
                ah.move(to: arrowTip)
                ah.addLine(to: CGPoint(x: arrowTip.x - aS*0.45, y: arrowTip.y - aS))
                ah.addLine(to: CGPoint(x: arrowTip.x + aS*0.45, y: arrowTip.y - aS))
                ah.close(); color.withAlphaComponent(0.90).setFill(); ah.fill()

                // Dot (biały ring + kolor) — identyczny jak w drawCallout
                UIColor.white.setFill()
                UIBezierPath(ovalIn: CGRect(x: dotPt.x-(dotR+2), y: dotPt.y-(dotR+2),
                                             width: (dotR+2)*2, height: (dotR+2)*2)).fill()
                color.setFill()
                UIBezierPath(ovalIn: CGRect(x: dotPt.x-dotR, y: dotPt.y-dotR,
                                             width: dotR*2, height: dotR*2)).fill()

                // Cień boxu
                UIColor.black.withAlphaComponent(0.25).setFill()
                UIBezierPath(roundedRect: boxRect.insetBy(dx: -2, dy: -2), cornerRadius: 6).fill()
                // Box kwadratowy (cornerRadius: 4 — identyczny jak eksport)
                color.setFill()
                UIBezierPath(roundedRect: boxRect, cornerRadius: 4).fill()

                // Linia 1 (kategoria)
                let r1 = CGRect(x: cx - sz1.width/2, y: boxRect.minY + pH,
                                width: sz1.width, height: sz1.height)
                (line1 as NSString).draw(in: r1, withAttributes: a1)
                // Linia 2 (wartość)
                let r2 = CGRect(x: cx - sz2.width/2, y: r1.maxY + gap,
                                width: sz2.width, height: sz2.height)
                (line2 as NSString).draw(in: r2, withAttributes: a2)
            }
        }

        private static func markerImage(kind: TaggedAnnotation.Kind) -> UIImage {
            let size: CGFloat
            let color: UIColor
            switch kind {
            case .start:    size = 14; color = .systemGreen
            case .end:      size = 14; color = .systemGray
            case .current:  size = 22; color = .systemPurple
            default:        size = 14; color = .systemGray
            }
            return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
                let rect = CGRect(x: 1, y: 1, width: size - 2, height: size - 2)
                color.setFill()
                UIBezierPath(ovalIn: rect).fill()
                if kind == .current {
                    UIColor.white.setFill()
                    let inner = CGRect(x: size/2 - 3, y: size/2 - 3, width: 6, height: 6)
                    UIBezierPath(ovalIn: inner).fill()
                }
                UIColor.white.setStroke()
                let border = UIBezierPath(ovalIn: rect)
                border.lineWidth = 1.5; border.stroke()
            }
        }
    }

    final class TaggedAnnotation: MKPointAnnotation {
        enum Kind: String { case start, end, current, maxSpeed, maxLeanL, maxLeanR }
        let kind: Kind
        init(kind: Kind, title: String? = nil) {
            self.kind = kind
            super.init()
            self.title = title
        }
    }
}

// MARK: — TimelineChartView (Swift Charts + scrub gesture)

struct TimelineChartView: View {
    let title: String
    let unit:  String
    let color: Color
    let values: [(time: Double, value: Double)]
    let currentTime: Double
    let duration:    Double
    let valueFormatter: (Double) -> String
    var includeAreaFill: Bool = false
    var showZeroLine: Bool = false
    let onSeek: (Double) -> Void

    /// Aktualna wartość interpolowana w czasie currentTime — do nagłówka.
    private var currentValue: Double {
        guard !values.isEmpty else { return 0 }
        if currentTime <= values[0].time { return values[0].value }
        if currentTime >= values.last!.time { return values.last!.value }
        for i in 1..<values.count {
            if values[i].time >= currentTime {
                let p0 = values[i - 1], p1 = values[i]
                let span = max(p1.time - p0.time, 0.001)
                let t    = (currentTime - p0.time) / span
                return p0.value + (p1.value - p0.value) * t
            }
        }
        return values.last!.value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.bold())
                Spacer()
                Text("\(valueFormatter(currentValue)) \(unit)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(color)
                    .monospacedDigit()
            }

            Chart {
                if showZeroLine {
                    RuleMark(y: .value("0", 0))
                        .foregroundStyle(.gray.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                }

                ForEach(values.indices, id: \.self) { i in
                    LineMark(
                        x: .value("t", values[i].time),
                        y: .value("v", values[i].value)
                    )
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
                }

                if includeAreaFill {
                    ForEach(values.indices, id: \.self) { i in
                        AreaMark(
                            x: .value("t", values[i].time),
                            y: .value("v", values[i].value)
                        )
                        .foregroundStyle(LinearGradient(
                            colors: [color.opacity(0.4), color.opacity(0.0)],
                            startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    }
                }

                RuleMark(x: .value("now", currentTime))
                    .foregroundStyle(.purple)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { v in
                    if let t = v.as(Double.self) {
                        AxisValueLabel { Text(fmtMM(t)).font(.system(size: 9)) }
                        AxisGridLine().foregroundStyle(.gray.opacity(0.15))
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisValueLabel().font(.system(size: 9))
                    AxisGridLine().foregroundStyle(.gray.opacity(0.15))
                }
            }
            .chartXScale(domain: 0...max(duration, 1))
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    let xPos = v.location.x
                                    if let frame = proxy.plotFrame.flatMap({ geo[$0] }) {
                                        let local = xPos - frame.minX
                                        if let t: Double = proxy.value(atX: local) {
                                            onSeek(max(0, min(duration, t)))
                                        }
                                    }
                                }
                        )
                }
            }
        }
    }

    private func fmtMM(_ t: Double) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: — SessionShareHelper: CSV export + screenshot share z watermarkiem

enum SessionShareHelper {

    /// CSV: zapisuje do tmp + wywołuje share sheet.
    static func exportCSV(_ s: SessionSummary) {
        let csv = s.csvString()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("myspin_\(Int(s.startTime.timeIntervalSince1970)).csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[CSV export] write error: \(error)")
            return
        }
        present(items: [url])
    }

    /// Screenshot 1080×1920 — async: najpierw MKMapSnapshotter (prawdziwa mapa),
    /// potem renderowanie całości, na końcu share sheet.
    #if DEBUG
    /// Debug: zrzuca plakat do Documents zamiast otwierać share sheet (podgląd bez telefonu).
    static func debugRenderShare(_ s: SessionSummary, name: String, options: ShareOptions = .saved) {
        buildMapSnapshot(for: s, options: options) { mapImage in
            let img = renderScreenshot(s, mapImage: mapImage, options: options)
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(name)
            try? img.pngData()?.write(to: url)
            NSLog("[SHARE_SHOT] zapisano \(url.lastPathComponent)  data=\(dateRangeText(s))  ruch=\(s.movingSec)s / total=\(s.durationSec)s")
        }
    }
    #endif

    /// „Udostępnij” → konfigurator (podgląd plakatu + co na nim ma być), z niego share sheet.
    static func shareScreenshot(_ s: SessionSummary) {
        // Pełny ekran (nie wysuwana karta) — powrót strzałką w lewym górnym rogu.
        let vc = UIHostingController(rootView: ShareConfigView(summary: s))
        vc.modalPresentationStyle = .fullScreen
        presentController(vc)
    }

    /// Gotowy plakat → PNG w tmp → share sheet (wołane z konfiguratora).
    static func sharePoster(_ img: UIImage, for s: SessionSummary) {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HH-mm"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MySpin_\(df.string(from: s.startTime)).png")
        if let data = img.pngData() {
            try? data.write(to: url)
            present(items: [url])
        } else {
            present(items: [img])
        }
    }

    /// Mapa z trasą dla plakatu (async, MKMapSnapshotter) — publiczne dla konfiguratora.
    static func mapSnapshot(for s: SessionSummary, options: ShareOptions, completion: @escaping (UIImage?) -> Void) {
        buildMapSnapshot(for: s, options: options, completion: completion)
    }

    static func poster(_ s: SessionSummary, mapImage: UIImage?, options: ShareOptions) -> UIImage {
        renderScreenshot(s, mapImage: mapImage, options: options)
    }

    // MARK: — MKMapSnapshotter → trasa na prawdziwej mapie

    /// Asynchronicznie renderuje trasę na kafelkach mapy (MKMapSnapshotter).
    /// Wywołuje completion na main thread z gotowym UIImage lub nil gdy brak GPS.
    private static func buildMapSnapshot(for s: SessionSummary, options: ShareOptions,
                                          completion: @escaping (UIImage?) -> Void) {
        let coords = s.points.compactMap { p -> CLLocationCoordinate2D? in
            guard p.latitude != 0, p.longitude != 0,
                  abs(p.latitude) <= 89.9, abs(p.longitude) <= 180 else { return nil }
            return CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)
        }
        guard coords.count >= 2 else { DispatchQueue.main.async { completion(nil) }; return }

        var minLat =  90.0, maxLat = -90.0
        var minLon = 180.0, maxLon = -180.0
        for c in coords {
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude:  (minLat + maxLat) / 2,
                                             longitude: (minLon + maxLon) / 2)
        // 30% padding wokół trasy
        var latDelta = max((maxLat - minLat) * 1.65, 0.003)
        var lonDelta = max((maxLon - minLon) * 1.40, 0.003)
        // Wycinek w proporcjach mapy na plakacie (szeroka panorama) — inaczej snapshotter
        // ucina górę i dół trasy razem z plakietkami. Stopień długości jest krótszy o cos(szer.).
        let size = posterLayout(s, options).map
        let aspect = Double(size.width / size.height)
        let k = cos(center.latitude * .pi / 180)
        if lonDelta * k / latDelta < aspect { lonDelta = latDelta * aspect / k } else { latDelta = lonDelta * k / aspect }

        let opts     = MKMapSnapshotter.Options()
        opts.region  = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
        // scale=1 → snap.image jest @1x, snap.point(for:) zwraca piksele 1:1 z rozmiarem
        // Użycie scale>1 rozjezdza koordynaty polyline vs wymiar obrazu w rendererze
        opts.size    = size
        opts.scale   = 1
        opts.mapType = .standard

        // KLUCZOWE: uchwycenie snapper w closurze — bez tego ARC zwalnia obiekt
        // natychmiast po wywołaniu .start() i snapshotter nigdy nie wraca z wynikiem
        let snapper = MKMapSnapshotter(options: opts)
        snapper.start { [snapper] snapshot, error in
            _ = snapper   // trzymamy silną referencję do końca callbacku
            guard let snap = snapshot else {
                print("[MapSnapshot] error: \(error?.localizedDescription ?? "nil snapshot")")
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Nałóż trasę na zdjęcie kafelków — wszystko w @1x (snap.point daje @1x)
            UIGraphicsBeginImageContextWithOptions(opts.size, true, 1.0)
            defer { UIGraphicsEndImageContext() }

            snap.image.draw(at: .zero)

            // ── Pass 1: cień pod całą trasą ──
            let shadowPath = UIBezierPath()
            shadowPath.move(to: snap.point(for: coords[0]))
            for c in coords.dropFirst() { shadowPath.addLine(to: snap.point(for: c)) }
            shadowPath.lineWidth     = 10
            shadowPath.lineCapStyle  = .round
            shadowPath.lineJoinStyle = .round
            UIColor.black.withAlphaComponent(0.28).setStroke()
            shadowPath.stroke()

            // ── Pass 2: segmenty kolorowane prędkością ──
            let gpsFiltered = s.points.filter {
                $0.latitude != 0 && $0.longitude != 0 &&
                abs($0.latitude) <= 89.9 && abs($0.longitude) <= 180
            }
            if gpsFiltered.count >= 2 {
                for i in 1..<gpsFiltered.count {
                    let p0 = gpsFiltered[i-1], p1 = gpsFiltered[i]
                    let c0 = CLLocationCoordinate2D(latitude: p0.latitude, longitude: p0.longitude)
                    let c1 = CLLocationCoordinate2D(latitude: p1.latitude, longitude: p1.longitude)
                    let avgKmh = (p0.speedKmh + p1.speedKmh) / 2
                    let seg = UIBezierPath()
                    seg.move(to: snap.point(for: c0))
                    seg.addLine(to: snap.point(for: c1))
                    seg.lineWidth     = 6
                    seg.lineCapStyle  = .round
                    seg.lineJoinStyle = .round
                    speedColor(avgKmh).setStroke()
                    seg.stroke()
                }
            }

            // ── Pass 3: callout-plakietki max speed / lean ──
            let movPts = s.points.filter {
                $0.isMoving && $0.latitude != 0 && $0.longitude != 0 &&
                abs($0.latitude) <= 89.9 && abs($0.longitude) <= 180
            }

            // Canvas-pozycje trasy (co 5. punkt — wystarczy do kolizji, nie ciągniemy 10k iteracji)
            let routeCanvas: [CGPoint] = stride(from: 0, to: gpsFiltered.count, by: 5).map {
                snap.point(for: CLLocationCoordinate2D(latitude:  gpsFiltered[$0].latitude,
                                                        longitude: gpsFiltered[$0].longitude))
            }

            /// Wybiera offset spośród kandydatów z najmniejszą kolizją z trasą.
            /// boxW/boxH — szacowany rozmiar plakietki (do sprawdzenia czy trasa wchodzi w pole).
            func smartOffset(for pt: CGPoint, boxW: CGFloat, boxH: CGFloat,
                              candidates: [CGPoint]) -> CGPoint {
                let margin: CGFloat = 14
                return candidates.min { a, b in
                    func score(_ off: CGPoint) -> Int {
                        let r = CGRect(x: pt.x + off.x - boxW/2 - margin,
                                       y: pt.y + off.y - boxH/2 - margin,
                                       width: boxW + margin*2, height: boxH + margin*2)
                        return routeCanvas.filter { r.contains($0) }.count
                    }
                    return score(a) < score(b)
                } ?? candidates[0]
            }

            // 8 kierunków — preferujemy górę (pierwsze w liście = wygra przy remisie)
            let d: CGFloat = 68
            let dirs: [CGPoint] = [
                CGPoint(x:  0,  y: -d),   // góra
                CGPoint(x: -d,  y: -d),   // lewo-góra
                CGPoint(x:  d,  y: -d),   // prawo-góra
                CGPoint(x: -d,  y:  0),   // lewo
                CGPoint(x:  d,  y:  0),   // prawo
                CGPoint(x:  0,  y:  d),   // dół
                CGPoint(x: -d,  y:  d),   // lewo-dół
                CGPoint(x:  d,  y:  d),   // prawo-dół
            ]

            if options.mapLabels, let ms = movPts.max(by: { $0.speedKmh < $1.speedKmh }) {
                let routePt = snap.point(for: CLLocationCoordinate2D(latitude: ms.latitude, longitude: ms.longitude))
                let off = smartOffset(for: routePt, boxW: 110, boxH: 50, candidates: dirs)
                drawCallout(routePt: routePt,
                            line1: "MAX SPEED",
                            line2: "\(Int(ms.speedKmh)) km/h",
                            color: UIColor(red: 0.00, green: 0.80, blue: 0.95, alpha: 1),
                            offset: off)
            }
            // min(by: { $0.leanDeg < $1.leanDeg }) = punkt z najbardziej ujemnym leanDeg (max lewo)
            if options.mapLabels, let ml = movPts.filter({ $0.leanDeg < -2 }).min(by: { $0.leanDeg < $1.leanDeg }) {
                let routePt = snap.point(for: CLLocationCoordinate2D(latitude: ml.latitude, longitude: ml.longitude))
                let off = smartOffset(for: routePt, boxW: 110, boxH: 50, candidates: dirs)
                // Wartość z SessionSummary (30Hz MotionManager) — spójna z wyświetlaczem
                let displayVal = s.maxLeanLeft > 0 ? s.maxLeanLeft : abs(ml.leanDeg)
                drawCallout(routePt: routePt,
                            line1: "MAX LEAN L",
                            line2: String(format: "%.1f°", displayVal),
                            color: UIColor.systemBlue,
                            offset: off)
            }
            if options.mapLabels, let mr = movPts.filter({ $0.leanDeg > 2 }).max(by: { $0.leanDeg < $1.leanDeg }) {
                let routePt = snap.point(for: CLLocationCoordinate2D(latitude: mr.latitude, longitude: mr.longitude))
                let off = smartOffset(for: routePt, boxW: 110, boxH: 50, candidates: dirs)
                let displayVal = s.maxLeanRight > 0 ? s.maxLeanRight : mr.leanDeg
                drawCallout(routePt: routePt,
                            line1: "MAX LEAN R",
                            line2: String(format: "%.1f°", displayVal),
                            color: UIColor.systemOrange,
                            offset: off)
            }

            // ── Piosenki: numerowane kółka w miejscu, gdzie utwór zaczął grać (numery = lista na plakacie) ──
            if options.songsOnMap {
                for (i, t) in (s.tracks ?? []).enumerated() {
                    guard let p = gpsFiltered.first(where: { $0.timestamp >= t.time }) else { continue }
                    let pt = snap.point(for: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude))
                    snapDot(at: pt, radius: 15, fill: UIColor(red: 0.11, green: 0.73, blue: 0.33, alpha: 1), stroke: .white)
                    let n = "\(i + 1)" as NSString
                    let a: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 15, weight: .heavy),
                                                            .foregroundColor: UIColor.white]
                    let sz = n.size(withAttributes: a)
                    n.draw(at: CGPoint(x: pt.x - sz.width / 2, y: pt.y - sz.height / 2), withAttributes: a)
                }
            }

            // ── Marker START / STOP ──
            snapDot(at: snap.point(for: coords.first!),
                    radius: 11, fill: .systemGreen, stroke: .white)
            snapDot(at: snap.point(for: coords.last!),
                    radius: 11, fill: .systemRed,   stroke: .white)

            let img = UIGraphicsGetImageFromCurrentImageContext()
            DispatchQueue.main.async { completion(img) }
        }
    }

    /// Kółko z obramowaniem — helper dla markerów na mapie.
    private static func snapDot(at pt: CGPoint, radius: CGFloat,
                                  fill: UIColor, stroke: UIColor) {
        let r = CGRect(x: pt.x - radius, y: pt.y - radius,
                       width: radius * 2,  height: radius * 2)
        stroke.setStroke()
        let halo = UIBezierPath(ovalIn: r.insetBy(dx: -2, dy: -2))
        halo.lineWidth = 4; halo.stroke()
        fill.setFill()
        UIBezierPath(ovalIn: r).fill()
    }

    /// Callout-plakietka: kropka na trasie + strzałka + kwadratowy box (kategoria + wartość).
    /// `line1` — mała etykieta (np. "MAX SPEED"), `line2` — główna wartość (np. "127 km/h").
    private static func drawCallout(routePt: CGPoint,
                                     line1: String, line2: String,
                                     color: UIColor, offset: CGPoint) {
        let labelCenter = CGPoint(x: routePt.x + offset.x, y: routePt.y + offset.y)

        // ── Pomiar boxu ──
        let font1 = UIFont.systemFont(ofSize: 10, weight: .semibold)
        let font2 = UIFont.systemFont(ofSize: 14, weight: .bold)
        let attrs1: [NSAttributedString.Key: Any] = [.font: font1,
            .foregroundColor: UIColor.white.withAlphaComponent(0.80)]
        let attrs2: [NSAttributedString.Key: Any] = [.font: font2,
            .foregroundColor: UIColor.white]
        let sz1 = (line1 as NSString).size(withAttributes: attrs1)
        let sz2 = (line2 as NSString).size(withAttributes: attrs2)
        let pW: CGFloat = 10, pH: CGFloat = 7, gap: CGFloat = 3
        let boxW = max(sz1.width, sz2.width) + pW * 2
        let boxH = sz1.height + gap + sz2.height + pH * 2
        let boxRect = CGRect(x: labelCenter.x - boxW / 2,
                              y: labelCenter.y - boxH / 2,
                              width: boxW, height: boxH)

        // ── Strzałka od krawędzi boxu do kropki ──
        let dx = routePt.x - labelCenter.x
        let dy = routePt.y - labelCenter.y
        let len = sqrt(dx * dx + dy * dy)
        if len > 4 {
            let ux = dx / len, uy = dy / len
            // Punkt na krawędzi prostokąta w kierunku routePt
            let tX = (boxW / 2) / max(abs(ux), 1e-6)
            let tY = (boxH / 2) / max(abs(uy), 1e-6)
            let t  = min(tX, tY)
            let edgePt   = CGPoint(x: labelCenter.x + ux * t, y: labelCenter.y + uy * t)
            let dotR: CGFloat = 6
            let arrowTip = CGPoint(x: routePt.x - ux * (dotR + 3),
                                    y: routePt.y - uy * (dotR + 3))

            // Linia
            let ln = UIBezierPath()
            ln.move(to: edgePt); ln.addLine(to: arrowTip)
            ln.lineWidth = 1.5
            color.withAlphaComponent(0.90).setStroke(); ln.stroke()

            // Grot strzałki
            let aS: CGFloat = 7
            let px = -uy, py = ux   // prostopadle do kierunku
            let arrowPath = UIBezierPath()
            arrowPath.move(to: arrowTip)
            arrowPath.addLine(to: CGPoint(x: arrowTip.x - ux*aS + px*aS*0.45,
                                           y: arrowTip.y - uy*aS + py*aS*0.45))
            arrowPath.addLine(to: CGPoint(x: arrowTip.x - ux*aS - px*aS*0.45,
                                           y: arrowTip.y - uy*aS - py*aS*0.45))
            arrowPath.close()
            color.withAlphaComponent(0.90).setFill(); arrowPath.fill()

            // Kropka na trasie
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: routePt.x-(dotR+2), y: routePt.y-(dotR+2),
                                         width: (dotR+2)*2, height: (dotR+2)*2)).fill()
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: routePt.x-dotR, y: routePt.y-dotR,
                                         width: dotR*2, height: dotR*2)).fill()
        }

        // ── Kwadratowy box ──
        UIColor.black.withAlphaComponent(0.28).setFill()
        UIBezierPath(roundedRect: boxRect.insetBy(dx: -2, dy: -2), cornerRadius: 6).fill()
        color.setFill()
        UIBezierPath(roundedRect: boxRect, cornerRadius: 4).fill()

        // Linia 1 (kategoria)
        let r1 = CGRect(x: labelCenter.x - sz1.width / 2, y: boxRect.minY + pH,
                         width: sz1.width, height: sz1.height)
        (line1 as NSString).draw(in: r1, withAttributes: attrs1)

        // Linia 2 (wartość)
        let r2 = CGRect(x: labelCenter.x - sz2.width / 2, y: r1.maxY + gap,
                         width: sz2.width, height: sz2.height)
        (line2 as NSString).draw(in: r2, withAttributes: attrs2)
    }

    // MARK: — Internal: present share sheet
    private static func present(items: [Any]) {
        presentController(UIActivityViewController(activityItems: items, applicationActivities: nil))
    }

    private static func presentController(_ av: UIViewController) {
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
            else { return }
            var top = root
            while let pres = top.presentedViewController { top = pres }
            // iPad popover anchor
            if let pop = av.popoverPresentationController {
                pop.sourceView = top.view
                pop.sourceRect = CGRect(x: top.view.bounds.midX,
                                        y: top.view.bounds.midY, width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
            top.present(av, animated: true)
        }
    }

    // MARK: — Screenshot renderer

    /// Candy Daring Red — lakier GSX-S1000GX. Główny akcent całego plakatu.
    private static let gsxRed      = UIColor(red: 0.84, green: 0.04, blue: 0.13, alpha: 1)
    private static let gsxRedLight = UIColor(red: 1.00, green: 0.22, blue: 0.22, alpha: 1)
    private static let gsxRedDeep  = UIColor(red: 0.42, green: 0.01, blue: 0.06, alpha: 1)

    /// Data trasy: jeden dzień → „sobota, 16 sierpnia 2026",
    /// wiele dni → „14–16 sierpnia 2026" (trasa potrafi trwać kilka dni).
    private static func dateRangeText(_ s: SessionSummary) -> String {
        let cal = Calendar.current
        let pl  = Locale.current
        let sameDay = cal.isDate(s.startTime, inSameDayAs: s.endTime)
        if sameDay {
            let f = DateFormatter(); f.locale = pl; f.dateFormat = "EEEE, d MMMM yyyy"
            return f.string(from: s.startTime).uppercased()
        }
        let sameMonth = cal.component(.month, from: s.startTime) == cal.component(.month, from: s.endTime)
            && cal.component(.year, from: s.startTime) == cal.component(.year, from: s.endTime)
        let dFrom = DateFormatter(); dFrom.locale = pl
        dFrom.dateFormat = sameMonth ? "d" : "d MMMM"
        let dTo = DateFormatter(); dTo.locale = pl; dTo.dateFormat = "d MMMM yyyy"
        return "\(dFrom.string(from: s.startTime))–\(dTo.string(from: s.endTime))".uppercased()
    }

    /// Bloki plakatu pod mapą, w kolejności od góry (wysokości w px plakatu 1080 szer.).
    private enum PosterBlock {
        case hero, stats, lean, engine(EngineStats), gears(EngineStats, pie: Bool), fav(SessionTrack), songs([SessionTrack]), time

        var height: CGFloat {
            switch self {
            case .hero: return 160
            case .stats, .lean, .engine: return 150
            case .gears(_, let pie): return pie ? 300 : 180
            case .fav: return 150
            case .songs(let t): return 60 + 44 * CGFloat(min(t.count, ShareOptions.maxListedSongs))
            case .time: return 70
            }
        }
    }

    /// Bloki plakatu dla danych trasy i opcji (tylko te, do których trasa ma dane).
    private static func posterBlocks(_ s: SessionSummary, _ o: ShareOptions) -> [PosterBlock] {
        var blocks: [PosterBlock] = [.hero]
        if o.stats { blocks.append(.stats) }
        if o.lean { blocks.append(.lean) }
        if let e = s.engineStats {
            if o.engine { blocks.append(.engine(e)) }
            if o.gears { blocks.append(.gears(e, pie: o.gearsPie)) }
        }
        if o.favSong, let f = s.favoriteTrack { blocks.append(.fav(f)) }
        if o.songList, let t = s.tracks, !t.isEmpty { blocks.append(.songs(t)) }
        if o.time { blocks.append(.time) }
        return blocks
    }

    private static let posterW: CGFloat = 1080, headerH: CGFloat = 220, posterGap: CGFloat = 30

    /// Wysokość plakatu i rozmiar mapy. Format relacji 1080×1920; mapa (szeroka, 960 px)
    /// zabiera to, co zostaje po blokach — od 420 do 760 px wysokości. Dopiero gdy bloków
    /// jest za dużo nawet na 420, plakat robi się dłuższy.
    static func posterLayout(_ s: SessionSummary, _ o: ShareOptions) -> (height: CGFloat, map: CGSize) {
        let blocksH = posterBlocks(s, o).reduce(0) { $0 + $1.height }
        let bottomH: CGFloat = o.watermark ? 130 : 50
        let mapH = min(760, max(420, 1920 - headerH - posterGap - blocksH - bottomH))
        let H = max(1920, headerH + mapH + posterGap + blocksH + bottomH)
        return (H, CGSize(width: 960, height: mapH))
    }

    /// Plakat w wybranym formacie: relacja 9:16 / post 4:5 — gdy treść jest wyższa, cały plakat
    /// jest zmniejszany i wyśrodkowany na tle (nic nie jest ucinane); „dowolna” = naturalna długość.
    private static func renderScreenshot(_ s: SessionSummary, mapImage: UIImage?, options o: ShareOptions) -> UIImage {
        guard let targetH = o.format.height else { return renderNatural(s, mapImage: mapImage, options: o) }
        // Tło na całe płótno formatu, na nim treść plakatu (pomniejszona, gdy się nie mieści).
        let natural = renderNatural(s, mapImage: mapImage, options: o, withBackground: false)
        let W = posterW, H = natural.size.height
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: W, height: targetH), format: fmt).image { ctx in
            drawBackground(ctx.cgContext, cs: CGColorSpaceCreateDeviceRGB(), W: W, H: targetH)
            let k = min(1, targetH / H)
            let w = W * k, h = H * k
            natural.draw(in: CGRect(x: (W - w) / 2, y: (targetH - h) / 2, width: w, height: h))
        }
    }

    /// Tło plakatu: głęboka czerń z candy-red poświatą i ukośnymi smugami.
    private static func drawBackground(_ cg: CGContext, cs: CGColorSpace, W: CGFloat, H: CGFloat) {
        // ── Tło: głęboka czerń z candy-red poświatą (zamiast fioletu) ──
        let bgColors = [
            UIColor(red: 0.09, green: 0.02, blue: 0.03, alpha: 1).cgColor,
            UIColor(red: 0.03, green: 0.02, blue: 0.02, alpha: 1).cgColor
        ] as CFArray
        if let grad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0, 1]) {
            cg.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: H), options: [])
        }
        // Radialna łuna w kolorze lakieru — „candy" głębia
        if let glow = CGGradient(colorsSpace: cs,
            colors: [gsxRed.withAlphaComponent(0.34).cgColor,
                     gsxRedDeep.withAlphaComponent(0.10).cgColor,
                     UIColor.clear.cgColor] as CFArray, locations: [0, 0.45, 1]) {
            cg.drawRadialGradient(glow,
                startCenter: CGPoint(x: W/2, y: H * 0.59), startRadius: 0,
                endCenter:   CGPoint(x: W/2, y: H * 0.59), endRadius: 720,
                options: [])
        }
        // Ukośne smugi światła — subtelny „lakier"
        cg.saveGState()
        for i in 0..<3 {
            let x = CGFloat(120 + i * 360)
            let p = UIBezierPath()
            p.move(to: CGPoint(x: x, y: -100))
            p.addLine(to: CGPoint(x: x + 150, y: -100))
            p.addLine(to: CGPoint(x: x - 250, y: H + 100))
            p.addLine(to: CGPoint(x: x - 400, y: H + 100))
            p.close()
            gsxRedLight.withAlphaComponent(0.028).setFill(); p.fill()
        }
        cg.restoreGState()
    }

    private static func renderNatural(_ s: SessionSummary, mapImage: UIImage?, options o: ShareOptions,
                                      withBackground: Bool = true) -> UIImage {
        let W = posterW
        let blocks = posterBlocks(s, o)
        let layout = posterLayout(s, o)
        let H = layout.height, gap = posterGap
        // 1 px = 1 px plakatu (domyślnie renderer bierze skalę ekranu, a z nią PNG 3240 px / 15 MB)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = withBackground      // bez tła: przezroczyste, do nałożenia na tło formatu
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: W, height: H), format: fmt)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let cs = CGColorSpaceCreateDeviceRGB()

            if withBackground { drawBackground(cg, cs: cs, W: W, H: H) }

            // ── Górny pasek brand ──
            drawText("MOTO SESSION",
                     at: CGPoint(x: W / 2, y: 70),
                     size: 26, weight: .heavy, color: .white,
                     alignment: .center, tracking: 6)
            // Czerwona kreska akcentu pod tytułem
            let lineW: CGFloat = 180
            if let g2 = CGGradient(colorsSpace: cs,
                colors: [UIColor.clear.cgColor, gsxRed.cgColor, UIColor.clear.cgColor] as CFArray,
                locations: [0, 0.5, 1]) {
                cg.saveGState()
                cg.addRect(CGRect(x: W/2 - lineW, y: 104, width: lineW * 2, height: 3))
                cg.clip()
                cg.drawLinearGradient(g2, start: CGPoint(x: W/2 - lineW, y: 0),
                                      end: CGPoint(x: W/2 + lineW, y: 0), options: [])
                cg.restoreGState()
            }

            // ── Data (zakres, gdy trasa trwała kilka dni) ──
            drawText(dateRangeText(s),
                     at: CGPoint(x: W / 2, y: 150),
                     size: 28, weight: .semibold,
                     color: UIColor(white: 0.82, alpha: 1),
                     alignment: .center, tracking: 2)

            // ── Mapa trasy ──
            let mapRect = CGRect(x: (W - layout.map.width) / 2, y: headerH, width: layout.map.width, height: layout.map.height)
            if let img = mapImage {
                // Prawdziwe kafelki mapy z trasą nałożoną przez MKMapSnapshotter
                cg.saveGState()
                let clip = UIBezierPath(roundedRect: mapRect, cornerRadius: 32)
                clip.addClip()
                // Wypełnienie z przycięciem — w konfiguratorze podgląd rysuje się od razu ze
                // starą mapą (inny rozmiar), zanim dojdzie nowa z MKMapSnapshotter.
                let k = max(mapRect.width / img.size.width, mapRect.height / img.size.height)
                let dw = img.size.width * k, dh = img.size.height * k
                img.draw(in: CGRect(x: mapRect.midX - dw / 2, y: mapRect.midY - dh / 2, width: dw, height: dh))
                cg.restoreGState()
                UIColor(white: 1, alpha: 0.18).setStroke()
                let border = UIBezierPath(roundedRect: mapRect, cornerRadius: 32)
                border.lineWidth = 2; border.stroke()
            } else {
                // Fallback: własny rendering gdy brak GPS lub snapshotter zawiódł
                drawMiniMap(s, in: mapRect, ctx: cg)
            }

            var y = mapRect.maxY + gap
            for b in blocks {
                drawBlock(b, s, top: y, W: W, cg: cg, cs: cs)
                y += b.height
            }

            // ── Watermark ──
            if o.watermark {
                drawText("SpinMyCan @mikomaks_",
                         at: CGPoint(x: W / 2, y: H - 70),
                         size: 30, weight: .black,
                         color: .white,
                         alignment: .center, tracking: 4)
            }
        }
    }

    private static func drawBlock(_ b: PosterBlock, _ s: SessionSummary, top: CGFloat, W: CGFloat,
                                  cg: CGContext, cs: CGColorSpace) {
        let grayLabel = UIColor(white: 0.65, alpha: 1)
        switch b {
        case .hero:
            // Dystans z poświatą w kolorze lakieru
            let heroStr = String(format: "%.1f", s.totalDistKm)
            cg.saveGState()
            cg.setShadow(offset: .zero, blur: 60, color: gsxRed.withAlphaComponent(0.85).cgColor)
            drawText(heroStr, at: CGPoint(x: W / 2, y: top + 60),
                     size: 110, weight: .heavy, color: .white, alignment: .center)
            cg.restoreGState()
            drawText(String(localized: "KILOMETRÓW"), at: CGPoint(x: W / 2, y: top + 138),
                     size: 28, weight: .heavy, color: gsxRedLight, alignment: .center, tracking: 8)

        case .stats:
            drawStat(label: "MAX KM/H", value: "\(Int(s.maxSpeedKmh))",
                     at: CGPoint(x: W * 0.20, y: top + 45), accent: gsxRedLight)
            drawStat(label: String(localized: "ŚREDNIA"), value: "\(Int(s.avgSpeedKmh)) km/h",
                     at: CGPoint(x: W * 0.50, y: top + 45), accent: .white)
            drawStat(label: "MAX G", value: String(format: "%.2f", s.maxGforce),
                     at: CGPoint(x: W * 0.80, y: top + 45), accent: gsxRedLight)

        case .lean:
            // Sanity-clamp do ±65° (telefon zdjęty z uchwytu może dać 180°)
            drawStat(label: "MAX LEAN L", value: String(format: "%.1f°", min(s.maxLeanLeft, 65)),
                     at: CGPoint(x: W * 0.30, y: top + 45), accent: .white)
            drawStat(label: "MAX LEAN R", value: String(format: "%.1f°", min(s.maxLeanRight, 65)),
                     at: CGPoint(x: W * 0.70, y: top + 45), accent: .white)

        case .engine(let e):
            drawStat(label: "MAX RPM", value: "\(e.maxRPM)",
                     at: CGPoint(x: W * 0.20, y: top + 45), accent: gsxRedLight)
            drawStat(label: String(localized: "ŚR. RPM"), value: "\(e.avgRPM)",
                     at: CGPoint(x: W * 0.50, y: top + 45), accent: .white)
            drawStat(label: String(localized: "ZMIANY BIEGÓW"), value: "\(e.shifts)",
                     at: CGPoint(x: W * 0.80, y: top + 45), accent: .white)

        case .gears(let e, let pie):
            drawText(String(localized: "CZAS NA BIEGACH"), at: CGPoint(x: W / 2, y: top + 18),
                     size: 22, weight: .heavy, color: grayLabel, alignment: .center, tracking: 4)
            let share = e.gearShare
            let secs = Array(e.gearSeconds[1...])
            func mmss(_ t: Double) -> String {
                let v = Int(t.rounded())
                return v >= 3600 ? String(format: "%d:%02d:%02d", v / 3600, v / 60 % 60, v % 60)
                                 : String(format: "%d:%02d", v / 60, v % 60)
            }
            if pie {
                // Wykres kołowy z legendą: bieg, procent, czas.
                let palette: [UIColor] = [UIColor(white: 0.45, alpha: 1), UIColor(white: 0.62, alpha: 1),
                                          UIColor(red: 1.0, green: 0.55, blue: 0.20, alpha: 1), gsxRedLight,
                                          gsxRed, gsxRedDeep.withAlphaComponent(1)]
                let c = CGPoint(x: 330, y: top + 165), r: CGFloat = 115
                var a0 = -CGFloat.pi / 2
                for (i, v) in share.enumerated() where v > 0 {
                    let a1 = a0 + CGFloat(v) * 2 * .pi
                    let p = UIBezierPath()
                    p.move(to: c)
                    p.addArc(withCenter: c, radius: r, startAngle: a0, endAngle: a1, clockwise: true)
                    p.close()
                    palette[i].setFill(); p.fill()
                    UIColor(red: 0.06, green: 0.02, blue: 0.03, alpha: 1).setStroke(); p.lineWidth = 3; p.stroke()
                    if v >= 0.07 {
                        let mid = (a0 + a1) / 2
                        drawText("\(i + 1)", at: CGPoint(x: c.x + cos(mid) * r * 0.62, y: c.y + sin(mid) * r * 0.62),
                                 size: 30, weight: .heavy, color: .white, alignment: .center)
                    }
                    a0 = a1
                }
                let used = share.indices.filter { share[$0] > 0 }
                for (row, i) in used.enumerated() {
                    let y = top + 165 - CGFloat(used.count - 1) * 19 + CGFloat(row) * 38
                    palette[i].setFill()
                    UIBezierPath(roundedRect: CGRect(x: 540, y: y - 11, width: 22, height: 22), cornerRadius: 5).fill()
                    drawText(String(localized: "\(i + 1). bieg"), at: CGPoint(x: 580, y: y), size: 26, weight: .heavy, color: .white)
                    drawText("\(Int((share[i] * 100).rounded()))%", at: CGPoint(x: 800, y: y), size: 26, weight: .bold,
                             color: UIColor(white: 0.85, alpha: 1), alignment: .right)
                    drawText(mmss(secs[i]), at: CGPoint(x: 940, y: y), size: 26, weight: .semibold,
                             color: UIColor(white: 0.65, alpha: 1), alignment: .right)
                }
            } else {
                // Słupki: procent nad słupkiem, pod spodem bieg i czas.
                let peak = max(share.max() ?? 0, 0.01)
                let left: CGFloat = 130, slot = (W - 2 * left) / 6, barW: CGFloat = slot * 0.55
                let base = top + 122, maxH: CGFloat = 50
                for (i, v) in share.enumerated() {
                    let cx = left + slot * (CGFloat(i) + 0.5)
                    let h = max(4, maxH * CGFloat(v / peak))
                    let rr = CGRect(x: cx - barW / 2, y: base - h, width: barW, height: h)
                    (v == share.max() ? gsxRedLight : UIColor(white: 1, alpha: 0.55)).setFill()
                    UIBezierPath(roundedRect: rr, cornerRadius: 6).fill()
                    drawText("\(Int((v * 100).rounded()))%", at: CGPoint(x: cx, y: base - h - 16),
                             size: 20, weight: .bold, color: UIColor(white: 0.85, alpha: 1), alignment: .center)
                    drawText("\(i + 1)", at: CGPoint(x: cx, y: base + 20),
                             size: 26, weight: .heavy, color: .white, alignment: .center)
                    drawText(mmss(secs[i]), at: CGPoint(x: cx, y: base + 50),
                             size: 20, weight: .semibold, color: UIColor(white: 0.6, alpha: 1), alignment: .center)
                }
            }

        case .fav(let t):
            drawText(String(localized: "♪  UTWÓR TRASY"), at: CGPoint(x: W / 2, y: top + 22),
                     size: 22, weight: .heavy, color: UIColor(red: 0.11, green: 0.84, blue: 0.38, alpha: 1),
                     alignment: .center, tracking: 4)
            drawText(clip(t.title, size: 44, weight: .heavy, width: W - 160),
                     at: CGPoint(x: W / 2, y: top + 70), size: 44, weight: .heavy, color: .white, alignment: .center)
            drawText(clip(t.artist, size: 30, weight: .semibold, width: W - 160),
                     at: CGPoint(x: W / 2, y: top + 117), size: 30, weight: .semibold,
                     color: UIColor(white: 0.75, alpha: 1), alignment: .center)

        case .songs(let list):
            drawText("♪  SOUNDTRACK", at: CGPoint(x: W / 2, y: top + 22),
                     size: 22, weight: .heavy, color: UIColor(red: 0.11, green: 0.84, blue: 0.38, alpha: 1),
                     alignment: .center, tracking: 4)
            let shown = list.prefix(ShareOptions.maxListedSongs)
            for (i, t) in shown.enumerated() {
                let yy = top + 62 + 44 * CGFloat(i)
                let more = i == shown.count - 1 && list.count > shown.count ? "  +\(list.count - shown.count)" : ""
                drawText("\(i + 1)", at: CGPoint(x: 110, y: yy), size: 26, weight: .heavy,
                         color: UIColor(red: 0.11, green: 0.84, blue: 0.38, alpha: 1))
                drawText(clip(t.label, size: 28, weight: .semibold, width: W - 280) + more,
                         at: CGPoint(x: 160, y: yy), size: 28, weight: .semibold, color: .white)
            }

        case .time:
            // Czas JAZDY (bez postojów) + całkowity
            func hm(_ sec: Int) -> String {
                let h = sec / 3600, m = (sec % 3600) / 60
                return h > 0 ? String(format: "%dh %02dm", h, m) : String(format: "%d min", m)
            }
            let moving = s.movingSec
            let timeStr = moving > 0
                ? String(localized: "W RUCHU  \(hm(moving))   ·   ŁĄCZNIE  \(hm(s.durationSec))")
                : String(localized: "CZAS  \(hm(s.durationSec))")
            drawText(timeStr, at: CGPoint(x: W / 2, y: top + 35), size: 30, weight: .semibold,
                     color: UIColor(white: 0.78, alpha: 1), alignment: .center, tracking: 2)
        }
    }

    /// Tekst przycięty z „…”, żeby zmieścił się w szerokości.
    private static func clip(_ text: String, size: CGFloat, weight: UIFont.Weight, width: CGFloat) -> String {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        func w(_ t: String) -> CGFloat { (t as NSString).size(withAttributes: [.font: font]).width }
        guard w(text) > width else { return text }
        var t = text
        while !t.isEmpty, w(t + "…") > width { t.removeLast() }
        return t + "…"
    }

    /// Mini-mapa trasy na canvas — własny rendering (nie MKMapView snapshot, dla prostoty).
    private static func drawMiniMap(_ s: SessionSummary, in rect: CGRect, ctx: CGContext) {
        // Zaokrąglone tło
        ctx.saveGState()
        let bgPath = UIBezierPath(roundedRect: rect, cornerRadius: 32)
        UIColor(white: 1, alpha: 0.06).setFill(); bgPath.fill()
        UIColor(white: 1, alpha: 0.12).setStroke(); bgPath.lineWidth = 2; bgPath.stroke()

        bgPath.addClip()

        // Filtruj punkty z poprawnym GPS
        let coords = s.points.compactMap { p -> (lat: Double, lon: Double)? in
            guard p.latitude != 0, p.longitude != 0,
                  abs(p.latitude) <= 89.9, abs(p.longitude) <= 180 else { return nil }
            return (p.latitude, p.longitude)
        }
        guard coords.count >= 2 else {
            UIColor(white: 0.55, alpha: 1).set()
            let para = NSMutableParagraphStyle(); para.alignment = .center
            (String(localized: "brak GPS") as NSString).draw(
                in: CGRect(x: rect.minX, y: rect.midY - 24, width: rect.width, height: 48),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 36, weight: .medium),
                    .foregroundColor: UIColor(white: 0.55, alpha: 1),
                    .paragraphStyle: para
                ])
            ctx.restoreGState()
            return
        }

        // Bbox
        var minLat = 90.0, maxLat = -90.0
        var minLon = 180.0, maxLon = -180.0
        for c in coords {
            minLat = min(minLat, c.lat); maxLat = max(maxLat, c.lat)
            minLon = min(minLon, c.lon); maxLon = max(maxLon, c.lon)
        }
        let latPad = max((maxLat - minLat) * 0.10, 0.0001)
        let lonPad = max((maxLon - minLon) * 0.10, 0.0001)
        minLat -= latPad; maxLat += latPad
        minLon -= lonPad; maxLon += lonPad
        let latRange = maxLat - minLat
        let lonRange = (maxLon - minLon) * cos(((minLat + maxLat) / 2) * .pi / 180)
        guard latRange > 0.0001, lonRange > 0.0001 else { ctx.restoreGState(); return }

        let pad: CGFloat = 50
        let mw = rect.width  - pad * 2
        let mh = rect.height - pad * 2
        let scale = min(mw / CGFloat(lonRange), mh / CGFloat(latRange))
        let offX  = rect.minX + (rect.width  - CGFloat(lonRange) * scale) / 2
        let offY  = rect.minY + (rect.height - CGFloat(latRange) * scale) / 2

        func proj(_ lat: Double, _ lon: Double) -> CGPoint {
            let nlon = (lon - minLon) * cos(((minLat + maxLat) / 2) * .pi / 180)
            return CGPoint(x: offX + CGFloat(nlon) * scale,
                           y: offY + CGFloat(maxLat - lat) * scale)
        }

        // Polyline
        let path = UIBezierPath()
        path.move(to: proj(coords[0].lat, coords[0].lon))
        for c in coords.dropFirst() {
            path.addLine(to: proj(c.lat, c.lon))
        }
        UIColor.systemPurple.setStroke()
        path.lineWidth = 8
        path.lineCapStyle  = .round
        path.lineJoinStyle = .round
        path.stroke()

        // Start (zielony) + Stop (szary)
        let startPt = proj(coords.first!.lat, coords.first!.lon)
        UIColor.systemGreen.setFill()
        UIBezierPath(ovalIn: CGRect(x: startPt.x - 12, y: startPt.y - 12, width: 24, height: 24)).fill()
        UIColor.white.setStroke()
        let sp = UIBezierPath(ovalIn: CGRect(x: startPt.x - 12, y: startPt.y - 12, width: 24, height: 24))
        sp.lineWidth = 3; sp.stroke()

        let endPt = proj(coords.last!.lat, coords.last!.lon)
        UIColor.systemRed.setFill()
        UIBezierPath(ovalIn: CGRect(x: endPt.x - 12, y: endPt.y - 12, width: 24, height: 24)).fill()
        UIColor.white.setStroke()
        let ep = UIBezierPath(ovalIn: CGRect(x: endPt.x - 12, y: endPt.y - 12, width: 24, height: 24))
        ep.lineWidth = 3; ep.stroke()

        ctx.restoreGState()
    }

    // MARK: — Text helpers

    private static func drawText(_ text: String,
                                  at point: CGPoint,
                                  size: CGFloat,
                                  weight: UIFont.Weight,
                                  color: UIColor,
                                  alignment: NSTextAlignment = .left,
                                  tracking: CGFloat = 0) {
        let font  = UIFont.systemFont(ofSize: size, weight: weight)
        let para  = NSMutableParagraphStyle(); para.alignment = alignment
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color,
            .paragraphStyle: para,
            .kern: tracking
        ]
        let ns = text as NSString
        let sz = ns.size(withAttributes: attrs)
        let rect: CGRect
        switch alignment {
        case .center:
            rect = CGRect(x: point.x - 600, y: point.y - sz.height / 2, width: 1200, height: sz.height)
        case .right:
            rect = CGRect(x: point.x - sz.width, y: point.y - sz.height / 2, width: sz.width, height: sz.height)
        default:
            rect = CGRect(x: point.x, y: point.y - sz.height / 2, width: sz.width + 50, height: sz.height)
        }
        ns.draw(in: rect, withAttributes: attrs)
    }

    private static func drawStat(label: String, value: String,
                                  at center: CGPoint, accent: UIColor) {
        drawText(value, at: CGPoint(x: center.x, y: center.y),
                 size: 64, weight: .heavy, color: accent,
                 alignment: .center)
        drawText(label, at: CGPoint(x: center.x, y: center.y + 70),
                 size: 22, weight: .heavy,
                 color: UIColor(white: 0.65, alpha: 1),
                 alignment: .center, tracking: 4)
    }
}
