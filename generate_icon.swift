#!/usr/bin/env swift
// generate_icon.swift — ikona MySpin: tachometr
// Uruchom: swift generate_icon.swift

import CoreGraphics
import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: — Kolory

let bgColor    = CGColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)
let ringColor  = CGColor(red: 0.25, green: 0.25, blue: 0.28, alpha: 1)
let tickMajor  = CGColor(red: 0.85, green: 0.85, blue: 0.88, alpha: 1)
let tickMinor  = CGColor(red: 0.38, green: 0.38, blue: 0.42, alpha: 1)
let zoneGreen  = CGColor(red: 0.18, green: 0.82, blue: 0.38, alpha: 1)
let zoneYellow = CGColor(red: 1.00, green: 0.76, blue: 0.00, alpha: 1)
let zoneRed    = CGColor(red: 0.94, green: 0.18, blue: 0.18, alpha: 1)
let needleFill = CGColor(red: 1.00, green: 0.42, blue: 0.00, alpha: 1)
let hubOuter   = CGColor(red: 0.80, green: 0.80, blue: 0.84, alpha: 1)
let hubInner   = CGColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
let textLight  = CGColor(red: 0.88, green: 0.88, blue: 0.92, alpha: 1)
let textDim    = CGColor(red: 0.42, green: 0.42, blue: 0.48, alpha: 1)

func deg2rad(_ d: CGFloat) -> CGFloat { d * .pi / 180 }

// MARK: — Rysunek (CG natural coords: origin = lewy-DÓŁ, Y rośnie w GÓRĘ)

func drawIcon(size: CGFloat) -> CGImage? {
    let s = Int(size)
    guard let ctx = CGContext(
        data: nil, width: s, height: s,
        bitsPerComponent: 8, bytesPerRow: s * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let cx = size / 2
    let cy = size / 2   // środek = (size/2, size/2) — tak samo w obu układach

    // ── Zaokrąglone tło ──
    let cr = size * 0.225
    let bgPath = CGMutablePath()
    bgPath.addRoundedRect(in: CGRect(x:0, y:0, width:size, height:size),
                          cornerWidth: cr, cornerHeight: cr)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    ctx.addPath(bgPath)
    ctx.setFillColor(bgColor)
    ctx.fillPath()

    // Subtelny glow
    if let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red:0.18, green:0.18, blue:0.24, alpha:0.7),
                 CGColor(red:0.08, green:0.08, blue:0.10, alpha:0.0)] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawRadialGradient(glow,
            startCenter: CGPoint(x: cx, y: cy + size*0.05), startRadius: 0,
            endCenter:   CGPoint(x: cx, y: cy + size*0.05), endRadius: size*0.58,
            options: [])
    }

    // ── Parametry tarczy ──
    let pad: CGFloat  = size * 0.055
    let outerR        = size / 2 - pad
    let trackR        = outerR * 0.715
    let trackW        = size  * 0.048
    let arcR          = outerR * 0.83

    // Tachometr: 225° (lewy-dół) → 315° (-45°, prawy-dół), zakres 270°
    // W CG natural (Y-góra, CCW-dodatni) to jest standard matematyczny — DZIAŁA
    let startDeg:  CGFloat = 225
    let spanDeg:   CGFloat = 270
    let needlePct: CGFloat = 0.72

    // ── Pierścień zewnętrzny ──
    ctx.addArc(center: CGPoint(x:cx, y:cy), radius: outerR,
               startAngle: 0, endAngle: .pi*2, clockwise: false)
    ctx.setStrokeColor(ringColor)
    ctx.setLineWidth(size * 0.009)
    ctx.strokePath()

    // ── Kolorowe strefy ──
    ctx.setLineWidth(trackW)
    ctx.setLineCap(.butt)
    struct Zone { let f: CGFloat; let t: CGFloat; let c: CGColor }
    for z in [Zone(f:0.00, t:0.60, c:zoneGreen),
               Zone(f:0.60, t:0.80, c:zoneYellow),
               Zone(f:0.80, t:1.00, c:zoneRed)] {
        ctx.addArc(center: CGPoint(x:cx, y:cy), radius: trackR,
                   startAngle: deg2rad(startDeg - spanDeg * z.f),
                   endAngle:   deg2rad(startDeg - spanDeg * z.t),
                   clockwise: true)
        ctx.setStrokeColor(z.c)
        ctx.strokePath()
    }

    // ── Kreski podziałki ──
    let majorCount = 9
    let minorDiv   = 4
    let totalSeg   = (majorCount - 1) * (minorDiv + 1)
    ctx.setLineCap(.round)
    for i in 0...totalSeg {
        let frac    = CGFloat(i) / CGFloat(totalSeg)
        let angle   = deg2rad(startDeg - spanDeg * frac)
        let isMajor = i % (minorDiv + 1) == 0
        let r1 = arcR * (isMajor ? 0.80 : 0.87)
        let r2 = arcR * 0.98
        ctx.setStrokeColor(isMajor ? tickMajor : tickMinor)
        ctx.setLineWidth(size * (isMajor ? 0.013 : 0.005))
        ctx.move(to:    CGPoint(x: cx + cos(angle)*r1, y: cy + sin(angle)*r1))
        ctx.addLine(to: CGPoint(x: cx + cos(angle)*r2, y: cy + sin(angle)*r2))
        ctx.strokePath()
    }

    // ── Igła ──
    let needleAngle = deg2rad(startDeg - spanDeg * needlePct)
    let nLen  = arcR * 0.76
    let nBack = arcR * 0.20
    let perpA = needleAngle + .pi / 2
    let bW = size * 0.020
    let tW = size * 0.004
    let tipX  = cx + cos(needleAngle) * nLen
    let tipY  = cy + sin(needleAngle) * nLen
    let tailX = cx - cos(needleAngle) * nBack
    let tailY = cy - sin(needleAngle) * nBack

    let np = CGMutablePath()
    np.move(to:    CGPoint(x: tipX  + cos(perpA)*tW, y: tipY  + sin(perpA)*tW))
    np.addLine(to: CGPoint(x: tipX  - cos(perpA)*tW, y: tipY  - sin(perpA)*tW))
    np.addLine(to: CGPoint(x: tailX - cos(perpA)*bW, y: tailY - sin(perpA)*bW))
    np.addLine(to: CGPoint(x: tailX + cos(perpA)*bW, y: tailY + sin(perpA)*bW))
    np.closeSubpath()

    ctx.setShadow(offset: CGSize(width:1, height:-3), blur: size*0.015,
                  color: CGColor(red:0, green:0, blue:0, alpha:0.7))
    ctx.addPath(np)
    ctx.setFillColor(needleFill)
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Blask na igle
    ctx.addPath(np)
    ctx.setFillColor(CGColor(red:1.0, green:0.65, blue:0.2, alpha:0.30))
    ctx.fillPath()

    // ── Hub ──
    func fillCircle(_ r: CGFloat, color: CGColor) {
        ctx.addArc(center: CGPoint(x:cx, y:cy), radius:r,
                   startAngle:0, endAngle:.pi*2, clockwise:false)
        ctx.setFillColor(color)
        ctx.fillPath()
    }
    fillCircle(size*0.060, color: CGColor(red:0.55, green:0.55, blue:0.60, alpha:1))
    fillCircle(size*0.048, color: hubOuter)
    fillCircle(size*0.030, color: hubInner)
    fillCircle(size*0.011, color: CGColor(red:0.45, green:0.45, blue:0.50, alpha:1))

    // ── Tekst ──
    // WAŻNE: CTLineDraw rysuje tekst "Y-up" (baseline na Y=0, litery w górę).
    // W CG natural coords (Y-up) to działa normalnie — BEZ flipowania.
    //
    // Pozycje podane jako Y od DOŁU obrazka (CG natural):
    //   "RPM"    → cy + size*0.085   (trochę powyżej centrum)
    //   "mySPIN" → size * 0.17       (dolna część, z marginesem)

    func drawLabel(_ text: String, fontName: String, ptSize: CGFloat,
                   color: CGColor, centerX: CGFloat, baselineFromBottom: CGFloat) {
        let font  = CTFontCreateWithName(fontName as CFString, ptSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color
        ]
        let aStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(aStr)
        let b    = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.saveGState()
        ctx.translateBy(x: centerX - b.width/2, y: baselineFromBottom)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    drawLabel("RPM",
              fontName: "Helvetica Neue",
              ptSize: size * 0.052,
              color: textDim,
              centerX: cx,
              baselineFromBottom: cy + size * 0.085)

    drawLabel("mySPIN",
              fontName: "Helvetica Neue Bold",
              ptSize: size * 0.072,
              color: textLight,
              centerX: cx,
              baselineFromBottom: size * 0.165)

    ctx.restoreGState()  // end clip
    return ctx.makeImage()
}

// MARK: — Zapis

func savePNG(_ img: CGImage, to url: URL) {
    let type = UTType.png.identifier as CFString
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
        print("❌ \(url.lastPathComponent)"); return
    }
    CGImageDestinationAddImage(dest, img, nil)
    print(CGImageDestinationFinalize(dest) ? "✅ \(url.lastPathComponent)" : "❌ \(url.lastPathComponent)")
}

// MARK: — Main

let project = URL(fileURLWithPath: #file).deletingLastPathComponent()
let iconDir  = project.appendingPathComponent("MySpin/Assets.xcassets/AppIcon.appiconset")

let sizes: [(CGFloat, String)] = [
    (1024, "icon_1024.png"),
    ( 180, "icon_180.png"),
    ( 167, "icon_167.png"),
    ( 152, "icon_152.png"),
    ( 120, "icon_120.png"),
    (  87, "icon_87.png"),
    (  80, "icon_80.png"),
    (  76, "icon_76.png"),
    (  60, "icon_60.png"),
    (  58, "icon_58.png"),
    (  40, "icon_40.png"),
    (  29, "icon_29.png"),
    (  20, "icon_20.png"),
]

print("\n🎨 Generuję ikonę MySpin...\n")
for (sz, nm) in sizes {
    if let img = drawIcon(size: sz) { savePNG(img, to: iconDir.appendingPathComponent(nm)) }
    else { print("⚠️  Błąd: \(nm)") }
}
print("\n🏁 Gotowe → \(iconDir.path)\n")
