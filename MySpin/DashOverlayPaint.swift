// DashOverlayPaint.swift
// Drawing of what lies on top of the dashboard: the notification banner and the quick menu
// (state and timing: DashOverlay in PhoneNotifications.swift). Both are "glass": a blurred
// copy of the dashboard underneath, a tint, a sheen at the top and a bright rim.

import UIKit

extension FrameRenderer {

    /// Last step of `paint`: banner and quick menu, if any.
    func paintOverlay(_ l: Layout) {
        guard let o = overlay, !o.isEmpty else { return }
        if let m = o.menu, !quickItems.isEmpty { paintQuickMenu(m, l) }
        if let b = o.banner { paintBanner(b, l) }
    }

    private var overlayText: UIColor { isDarkMode ? .white : UIColor(white: 0.08, alpha: 1) }
    private var overlayDim: UIColor { isDarkMode ? UIColor(white: 1, alpha: 0.62) : UIColor(white: 0, alpha: 0.58) }
    /// Text sizes that suit the chosen font (the pixel font is sharp only in multiples of 9).
    private var small: CGFloat { dashFont == .pixel ? 9 : 12 }
    private var big: CGFloat { dashFont == .pixel ? 18 : 19 }

    // MARK: Glass

    /// A frosted glass panel. Call before drawing its content.
    func glassPanel(_ rect: CGRect, radius: CGFloat, tint: UIColor? = nil) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        let backdrop = blurredBackdrop(ctx, rect)       // before the shadow: the glass shows what is under it

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 5), blur: 16, color: UIColor.black.withAlphaComponent(0.5).cgColor)
        (isDarkMode ? UIColor(white: 0.07, alpha: 1) : UIColor(white: 0.97, alpha: 1)).setFill()
        path.fill()
        ctx.restoreGState()

        ctx.saveGState()
        path.addClip()
        ctx.interpolationQuality = .high                // smooth stretch = the blur
        backdrop?.draw(in: rect.insetBy(dx: -6, dy: -6))
        (tint ?? (isDarkMode ? UIColor(white: 0.09, alpha: 0.58) : UIColor(white: 1, alpha: 0.62))).setFill()
        UIRectFillUsingBlendMode(rect, .normal)
        // Sheen: light falling on the upper edge of the glass.
        let sheen = [UIColor(white: 1, alpha: isDarkMode ? 0.20 : 0.55).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sheen, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.minY),
                                   end: CGPoint(x: rect.midX, y: rect.minY + min(rect.height * 0.6, 36)), options: [])
        }
        ctx.restoreGState()

        UIColor(white: 1, alpha: isDarkMode ? 0.34 : 0.9).setStroke()
        let rim = UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius)
        rim.lineWidth = 1
        rim.stroke()
    }

    /// The part of the frame drawn so far that lies under `rect`, blurred (shrunk eight times
    /// and stretched back). nil = the context cannot be read — the panel is then just tinted.
    private func blurredBackdrop(_ ctx: CGContext, _ rect: CGRect) -> UIImage? {
        guard let whole = ctx.makeImage(), width > 0 else { return nil }
        let k = CGFloat(whole.width) / CGFloat(width)                     // pixels per point
        let around = rect.insetBy(dx: -6, dy: -6)
        let pixels = CGRect(x: around.minX * k, y: around.minY * k, width: around.width * k, height: around.height * k)
            .integral.intersection(CGRect(x: 0, y: 0, width: whole.width, height: whole.height))
        guard !pixels.isEmpty, let part = whole.cropping(to: pixels) else { return nil }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1; fmt.opaque = true
        // Two steps down (÷4, then ÷3): each one averages, so the result has no hard blocks.
        func shrink(_ img: UIImage, by f: CGFloat) -> UIImage {
            let size = CGSize(width: max(3, (img.size.width / f).rounded()), height: max(3, (img.size.height / f).rounded()))
            return UIGraphicsImageRenderer(size: size, format: fmt).image { c in
                c.cgContext.interpolationQuality = .high
                img.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        return shrink(shrink(UIImage(cgImage: part, scale: k, orientation: .up), by: 4), by: 3)
    }

    // MARK: Text helpers

    /// One line, cut with "…" when it does not fit.
    private func line(_ text: String, in rect: CGRect, size: CGFloat, color: UIColor, bold: Bool = false, align: NSTextAlignment = .left) {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        p.alignment = align
        let font = mono(size, bold: bold)
        let h = ceil(font.lineHeight)
        (text as NSString).draw(in: px(CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h)),
                                withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    }

    private func textWidth(_ text: String, size: CGFloat, bold: Bool = false) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: mono(size, bold: bold)]).width)
    }

    private func wrappedAttributes(size: CGFloat, color: UIColor) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = 3
        return [.font: mono(size), .foregroundColor: color, .paragraphStyle: p]
    }

    // MARK: Notification banner

    static func categoryLook(_ category: UInt8) -> (symbol: String, color: UIColor) {
        switch category {
        case 1:  return ("phone.fill", UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1))
        case 2:  return ("phone.arrow.down.left", UIColor(red: 1.00, green: 0.27, blue: 0.23, alpha: 1))
        case 4:  return ("message.fill", UIColor(red: 0.04, green: 0.52, blue: 1.00, alpha: 1))
        case 6:  return ("envelope.fill", UIColor(red: 0.35, green: 0.34, blue: 0.84, alpha: 1))
        case 5:  return ("calendar", UIColor(red: 1.00, green: 0.58, blue: 0.00, alpha: 1))
        default: return ("bell.fill", UIColor(red: 1.00, green: 0.62, blue: 0.04, alpha: 1))
        }
    }

    private func paintBanner(_ b: DashOverlay.Banner, _ l: Layout) {
        let n = b.notification
        let e = b.expand
        let text = b.messages.joined(separator: "\n")
        let headH: CGFloat = 56

        // Size: compact pill → wide card with the message.
        let wideW = min(l.W - 40, 780)
        let w = 500 + (wideW - 500) * e
        let msgAttrs = wrappedAttributes(size: dashFont == .pixel ? 18 : 22, color: overlayText)
        let msgMaxH = l.H - 16 - headH - 34
        let msgH = text.isEmpty ? 0 : min(msgMaxH, ceil((text as NSString).boundingRect(
            with: CGSize(width: wideW - 40, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: msgAttrs, context: nil).height))
        let fullH = headH + (text.isEmpty ? 0 : msgH + 8) + 26
        let h = headH + (fullH - headH) * e
        let y = 8 - (1 - b.slide) * (h + 28)
        let rect = CGRect(x: (l.W - w) / 2, y: y, width: w, height: h)
        glassPanel(rect, radius: min(22, headH / 2 + 4 * e))

        // Icon in a coloured disc.
        let look = Self.categoryLook(n.category)
        let disc = CGRect(x: rect.minX + 10, y: rect.minY + 9, width: 38, height: 38)
        look.color.setFill()
        UIBezierPath(ovalIn: disc).fill()
        if let icon = UIImage(systemName: look.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal) {
            icon.draw(at: CGPoint(x: (disc.midX - icon.size.width / 2).rounded(), y: (disc.midY - icon.size.height / 2).rounded()))
        }

        // Right side: how many more wait, and what OK does.
        var right = rect.maxX - 14
        let hint = n.isCall ? "" : (e > 0.5 ? String(localized: "OK zwiń") : String(localized: "OK pokaż"))
        if !hint.isEmpty, !text.isEmpty {
            let hw = textWidth(hint, size: small, bold: true) + 16
            let chip = CGRect(x: right - hw, y: rect.minY + 17, width: hw, height: 22)
            UIColor(white: isDarkMode ? 1 : 0, alpha: 0.14).setFill()
            UIBezierPath(roundedRect: chip, cornerRadius: 11).fill()
            line(hint, in: chip, size: small, color: overlayText, bold: true, align: .center)
            right = chip.minX - 8
        }
        if b.more > 0 {
            let more = "+\(b.more)"
            let mw = textWidth(more, size: small, bold: true) + 14
            let chip = CGRect(x: right - mw, y: rect.minY + 17, width: mw, height: 22)
            look.color.setFill()
            UIBezierPath(roundedRect: chip, cornerRadius: 11).fill()
            line(more, in: chip, size: small, color: .white, bold: true, align: .center)
            right = chip.minX - 8
        }

        // Who, and from which app.
        let tx = disc.maxX + 10
        let app = n.subtitle.isEmpty ? n.appName : "\(n.appName) · \(n.subtitle)"
        line(app.uppercased(), in: CGRect(x: tx, y: rect.minY + 8, width: right - tx, height: 16), size: small, color: overlayDim, bold: true)
        line(n.title.isEmpty ? n.appName : n.title, in: CGRect(x: tx, y: rect.minY + 25, width: right - tx, height: 24),
             size: big, color: overlayText, bold: true)

        // Expanded: the message and the keys.
        guard e > 0.02, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setAlpha(e)
        if !text.isEmpty {
            (text as NSString).draw(with: CGRect(x: rect.minX + 20, y: rect.minY + headH + 2, width: wideW - 40, height: msgH),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
                                    attributes: msgAttrs, context: nil)
        }
        line(String(localized: "◀ zamknij"), in: CGRect(x: rect.minX + 20, y: rect.maxY - 24, width: rect.width - 40, height: 16),
             size: small, color: overlayDim, bold: true, align: .right)
        ctx.restoreGState()
    }

    // MARK: Quick menu

    /// A bar in place of the top strip: the chosen item in the middle, its neighbours beside it.
    private func paintQuickMenu(_ m: DashOverlay.Menu, _ l: Layout) {
        let items = quickItems
        let i = min(max(0, m.index), items.count - 1)
        let h: CGFloat = 44
        let rect = CGRect(x: 6, y: 4 - (1 - m.slide) * (h + 24), width: l.W - 12, height: h)
        glassPanel(rect, radius: 16)

        func title(_ it: QuickItem) -> String { it.value.isEmpty ? it.label : "\(it.label): \(it.value)" }

        // The chosen item: a bright capsule in the middle.
        let cur = items[i]
        let cw = min(360, max(190, textWidth(title(cur), size: big, bold: true) + 44))
        let capsule = CGRect(x: rect.midX - cw / 2, y: rect.minY + 6, width: cw, height: h - 12)
        RED.setFill()
        UIBezierPath(roundedRect: capsule, cornerRadius: capsule.height / 2).fill()
        line(title(cur), in: capsule.insetBy(dx: 14, dy: 0), size: big, color: .white, bold: true, align: .center)

        // Neighbours, dimmed, with the arrows that lead to them.
        if items.count > 1 {
            let prev = items[(i - 1 + items.count) % items.count], next = items[(i + 1) % items.count]
            let side = capsule.minX - rect.minX - 70
            line("◀  " + title(prev), in: CGRect(x: capsule.minX - 12 - side, y: rect.minY, width: side, height: h),
                 size: small + 1, color: overlayDim, bold: true, align: .right)
            line(title(next) + "  ▶", in: CGRect(x: capsule.maxX + 12, y: rect.minY, width: side, height: h),
                 size: small + 1, color: overlayDim, bold: true, align: .left)
        }
        // Position and the keys.
        line("\(i + 1)/\(items.count)", in: CGRect(x: rect.minX + 12, y: rect.minY, width: 44, height: h),
             size: small, color: overlayDim, bold: true)
        line(String(localized: "OK ✓  ▲▼ ✕"), in: CGRect(x: rect.maxX - 104, y: rect.minY, width: 92, height: h),
             size: small, color: overlayDim, bold: true, align: .right)
    }
}
