import UIKit

// MARK: - GaussianKeyboardExporter
//
// Renders a learned per-key Gaussian keyboard as a PDF:
//   1. Fits one 2D Gaussian per key from CORRECT taps (GaussianKeyModel).
//   2. Rasterises the canvas — each pixel is coloured by argmax of the
//      competing Mahalanobis log-scores + spatial prior, with a radial
//      anchor override near each key's geometric center.
//   3. Overlays:
//        - key outlines + labels
//        - fitted mean cross + 1-sigma / 2-sigma confidence ellipses
//        - correct tap dots
//   4. Draws a legend + summary banner.
//
// The implicit boundaries are where the winning key changes — no analytic
// boundary equation is solved; we just paint the decision surface.

final class GaussianKeyboardExporter {

    // MARK: - Config
    private let pageW:  CGFloat = 612
    private let pageH:  CGFloat = 792
    private let margin: CGFloat = 36

    // Pixel step for the winner raster. Smaller = crisper boundaries,
    // more compute. 2pt is a good balance on a 540pt canvas.
    private let rasterStep: CGFloat = 2.0

    // Alpha layout — kept in lockstep with KeyboardViewPDFExporter so the
    // two exports overlay cleanly.
    private let row0 = ["q","w","e","r","t","y","u","i","o","p"]
    private let row1 = ["a","s","d","f","g","h","j","k","l"]
    private let row2 = ["z","x","c","v","b","n","m"]

    private let sidePad: CGFloat = 3
    private let keyGap:  CGFloat = 6
    private let rowGap:  CGFloat = 13
    private let topPad:  CGFloat = 11

    private var allKeys: [String] {
        row0 + row1 + row2 + ["space", "delete"]
    }

    // MARK: - Entry point

    func exportPDF(
        events: [InputEventData],
        session: Session,
        participant: Participant?
    ) async -> URL? {

        let allowed = Set(allKeys)
        let validEvents = events.filter {
            !$0.keyLabel.isEmpty &&
            allowed.contains($0.keyLabel) &&
            $0.keyWidth > 0 && $0.keyHeight > 0
        }
        guard !validEvents.isEmpty else { return nil }

        let model = GaussianKeyModel.fit(events: validEvents, keys: allKeys)
        let fittedCount = model.gaussians.count

        let first = participant?.firstName ?? "unknown"
        let last  = participant?.lastName  ?? "unknown"
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("gaussian_keyboard_\(first)_\(last).pdf")

        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: pageW, height: pageH)
        )

        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            let headerBottom = drawHeader(
                ctx: ctx,
                session: session,
                participant: participant,
                tapCount: validEvents.count,
                fittedKeys: fittedCount,
                totalKeys: allKeys.count
            )
            let cgCtx = ctx.cgContext

            // Canvas geometry
            let canvasLeft  = margin + sidePad
            let canvasRight = pageW - margin - sidePad
            let canvasTop   = headerBottom + 16
            let canvasW     = canvasRight - canvasLeft
            let kw   = (canvasW - 2 * sidePad - 9 * keyGap) / 10
            let sp   = (canvasW - 2 * sidePad - 7 * kw - 8 * keyGap) / 2
            let keyH = (kw * 1.35).rounded()
            let canvasH = topPad + 4 * keyH + 3 * rowGap + 8
            let canvasRect = CGRect(x: canvasLeft, y: canvasTop, width: canvasW, height: canvasH)

            let frames = buildFrames(ox: canvasLeft, plotTop: canvasTop,
                                     kw: kw, sp: sp, keyH: keyH, plotW: canvasW)
            let framesList: [(key: String, rect: CGRect)] = allKeys.compactMap { k in
                frames[k].map { (k, $0) }
            }

            // 1. Dark canvas background
            cgCtx.setFillColor(UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1).cgColor)
            cgCtx.fill(canvasRect)

            // 2. Winner raster — the decision surface
            drawWinnerRaster(
                cgCtx: cgCtx,
                canvas: canvasRect,
                model: model,
                frames: framesList
            )

            // 3. Key outlines (thin, white-ish so painted territories read through)
            for (_, rect) in frames {
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 5)
                cgCtx.setStrokeColor(UIColor(white: 1, alpha: 0.35).cgColor)
                cgCtx.setLineWidth(0.6)
                cgCtx.addPath(path.cgPath)
                cgCtx.strokePath()
            }

            // 4. Gaussian ellipses (1 sigma solid, 2 sigma dashed) + mean cross
            for (key, rect) in frames {
                guard let g = model.gaussians[key] else { continue }
                drawEllipses(cgCtx: cgCtx, gaussian: g, frame: rect, key: key)
            }

            // 5. Correct tap dots (same per-key colour as the territory)
            drawTapDots(cgCtx: cgCtx, events: validEvents, frames: frames)

            // 6. Key labels on top — drawn last so they sit above raster,
            //    ellipses, and tap dots. Keeps focus on the boundaries.
            for (key, rect) in frames {
                let display = key == "delete" ? "\u{232B}"
                            : key == "space"  ? "\u{23B5}" : key
                let fontSize: CGFloat = key.count > 1 ? 7 : max(6, keyH * 0.22)
                drawText(display,
                         at: CGPoint(x: rect.minX + 3, y: rect.maxY - fontSize - 3),
                         font: .systemFont(ofSize: fontSize, weight: .bold),
                         color: .white)
            }

            // 7. Legend
            drawLegend(cgCtx: cgCtx,
                       y: canvasTop + canvasH + 18,
                       left: canvasLeft,
                       right: canvasRight,
                       model: model)
        }

        do {
            try data.write(to: url)
            return url
        } catch {
            print("GaussianKeyboardExporter: \(error)")
            return nil
        }
    }

    // MARK: - Winner raster
    //
    // Pixel-wise argmax over Mahalanobis log-scores + spatial prior. Uses
    // the precomputed precision matrices for speed. Anchor + fallback +
    // prior are delegated to GaussianKeyModel.winner(at:frames:).

    private func drawWinnerRaster(
        cgCtx: CGContext,
        canvas: CGRect,
        model: GaussianKeyModel,
        frames: [(key: String, rect: CGRect)]
    ) {
        // Precompute colours once.
        var colors: [String: UIColor] = [:]
        for (k, _) in frames { colors[k] = keyUIColor(k).withAlphaComponent(0.55) }

        let step = rasterStep
        var y = canvas.minY
        while y < canvas.maxY {
            var x = canvas.minX
            while x < canvas.maxX {
                let p = CGPoint(x: x + step / 2, y: y + step / 2)
                if let winner = model.winner(at: p, frames: frames),
                   let fill = colors[winner] {
                    cgCtx.setFillColor(fill.cgColor)
                    cgCtx.fill(CGRect(x: x, y: y, width: step, height: step))
                }
                x += step
            }
            y += step
        }
    }

    // MARK: - Ellipses + mean cross

    private func drawEllipses(
        cgCtx: CGContext,
        gaussian: Gaussian2D,
        frame: CGRect,
        key: String
    ) {
        let e = GaussianKeyModel.ellipse(for: gaussian, keyFrame: frame)
        let color = keyUIColor(key)

        // Move to ellipse centre, rotate, draw axis-aligned ellipse.
        cgCtx.saveGState()
        cgCtx.translateBy(x: e.center.x, y: e.center.y)
        cgCtx.rotate(by: CGFloat(e.angle))

        // 2-sigma — dashed, faint
        cgCtx.setStrokeColor(color.withAlphaComponent(0.55).cgColor)
        cgCtx.setLineWidth(0.5)
        cgCtx.setLineDash(phase: 0, lengths: [2, 2])
        cgCtx.strokeEllipse(in: CGRect(
            x: -CGFloat(e.semiA) * 2, y: -CGFloat(e.semiB) * 2,
            width: CGFloat(e.semiA) * 4, height: CGFloat(e.semiB) * 4
        ))

        // 1-sigma — solid
        cgCtx.setLineDash(phase: 0, lengths: [])
        cgCtx.setStrokeColor(color.withAlphaComponent(0.95).cgColor)
        cgCtx.setLineWidth(1.0)
        cgCtx.strokeEllipse(in: CGRect(
            x: -CGFloat(e.semiA), y: -CGFloat(e.semiB),
            width: CGFloat(e.semiA) * 2, height: CGFloat(e.semiB) * 2
        ))
        cgCtx.restoreGState()

        // Mean cross at (center + mu)
        cgCtx.setStrokeColor(UIColor.white.cgColor)
        cgCtx.setLineWidth(0.9)
        cgCtx.move(to: CGPoint(x: e.center.x - 3, y: e.center.y))
        cgCtx.addLine(to: CGPoint(x: e.center.x + 3, y: e.center.y))
        cgCtx.move(to: CGPoint(x: e.center.x, y: e.center.y - 3))
        cgCtx.addLine(to: CGPoint(x: e.center.x, y: e.center.y + 3))
        cgCtx.strokePath()
    }

    // MARK: - Tap dots

    private func drawTapDots(
        cgCtx: CGContext,
        events: [InputEventData],
        frames: [String: CGRect]
    ) {
        let dotR: CGFloat = 2.2
        for e in events where e.isCorrect {
            guard let frame = frames[e.keyLabel] else { continue }
            let nx = e.keyWidth  > 0 ? e.tapLocalX / e.keyWidth  : 0.5
            let ny = e.keyHeight > 0 ? e.tapLocalY / e.keyHeight : 0.5
            let px = frame.minX + CGFloat(nx) * frame.width
            let py = frame.minY + CGFloat(ny) * frame.height
            cgCtx.setFillColor(UIColor.white.withAlphaComponent(0.25).cgColor)
            cgCtx.fillEllipse(in: CGRect(
                x: px - dotR, y: py - dotR, width: dotR * 2, height: dotR * 2
            ))
        }
    }

    // MARK: - Legend

    private func drawLegend(
        cgCtx: CGContext,
        y: CGFloat,
        left: CGFloat,
        right: CGFloat,
        model: GaussianKeyModel
    ) {
        let fitted = allKeys.filter { model.gaussians[$0] != nil }
        var lx = left
        for k in fitted {
            cgCtx.setFillColor(keyUIColor(k).cgColor)
            cgCtx.fillEllipse(in: CGRect(x: lx, y: y + 1, width: 7, height: 7))
            let display = k == "delete" ? "del" : k == "space" ? "sp" : k
            let n = model.gaussians[k]?.count ?? 0
            drawText("\(display) (n=\(n))",
                     at: CGPoint(x: lx + 9, y: y - 1),
                     font: .monospacedSystemFont(ofSize: 7, weight: .medium),
                     color: .secondaryLabel, width: 42)
            lx += 46
            if lx + 46 > right { break }
        }
    }

    // MARK: - Header

    @discardableResult
    private func drawHeader(
        ctx: UIGraphicsPDFRendererContext,
        session: Session,
        participant: Participant?,
        tapCount: Int,
        fittedKeys: Int,
        totalKeys: Int
    ) -> CGFloat {
        let cgCtx = ctx.cgContext
        cgCtx.setFillColor(UIColor.systemTeal.withAlphaComponent(0.90).cgColor)
        cgCtx.fill(CGRect(x: 0, y: 0, width: pageW, height: 40))

        drawText("Gaussian Keyboard \u{2014} Learned Decision Boundaries",
                 at: CGPoint(x: margin, y: 10),
                 font: .systemFont(ofSize: 14, weight: .bold), color: .white, width: 400)
        drawText("\(tapCount) taps  \(fittedKeys)/\(totalKeys) fit",
                 at: CGPoint(x: pageW - margin - 140, y: 12),
                 font: .monospacedSystemFont(ofSize: 11, weight: .medium),
                 color: .white, width: 140)

        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withFullDate]
        let name = participant.map {
            "\($0.firstName) \($0.lastName)".trimmingCharacters(in: .whitespaces)
        } ?? "\u{2014}"
        drawText("Participant: \(name)   Date: \(iso.string(from: session.startedAt))   " +
                 "min-n=\(GaussianKeyModel.minSamples)  anchor=\(GaussianKeyModel.anchorFrac)  " +
                 "spatial=\(GaussianKeyModel.spatialPriorFrac)",
                 at: CGPoint(x: margin, y: 44),
                 font: .systemFont(ofSize: 8), color: .secondaryLabel, width: 540)
        return 56
    }

    // MARK: - Key frames (mirrors KeyboardViewPDFExporter)

    private func buildFrames(
        ox: CGFloat, plotTop: CGFloat, kw: CGFloat,
        sp: CGFloat, keyH: CGFloat, plotW: CGFloat
    ) -> [String: CGRect] {
        var f = [String: CGRect]()
        let y0 = plotTop + topPad
        for (i, k) in row0.enumerated() {
            f[k] = CGRect(x: ox + sidePad + CGFloat(i) * (kw + keyGap), y: y0, width: kw, height: keyH)
        }
        let y1 = y0 + keyH + rowGap
        let row1Start = ox + (plotW - 9 * kw - 8 * keyGap) / 2
        for (i, k) in row1.enumerated() {
            f[k] = CGRect(x: row1Start + CGFloat(i) * (kw + keyGap), y: y1, width: kw, height: keyH)
        }
        let y2 = y1 + keyH + rowGap
        let row2Start = ox + sidePad + sp + keyGap
        for (i, k) in row2.enumerated() {
            f[k] = CGRect(x: row2Start + CGFloat(i) * (kw + keyGap), y: y2, width: kw, height: keyH)
        }
        f["delete"] = CGRect(x: ox + plotW - sidePad - sp, y: y2, width: sp, height: keyH)
        let y3 = y2 + keyH + rowGap
        f["space"] = CGRect(x: ox + sidePad + sp + keyGap, y: y3,
                            width: plotW - 2 * sidePad - 2 * sp - 2 * keyGap, height: keyH)
        return f
    }

    // MARK: - Colour palette (identical hash to KeyboardViewPDFExporter)

    private func keyUIColor(_ key: String) -> UIColor {
        let idx = Double(allKeys.firstIndex(of: key) ?? 0)
        let hue = (idx * 0.618033988749895).truncatingRemainder(dividingBy: 1.0)
        let sat: CGFloat = idx.truncatingRemainder(dividingBy: 2) == 0 ? 0.82 : 0.65
        return UIColor(hue: CGFloat(hue), saturation: sat, brightness: 0.88, alpha: 1.0)
    }

    private func drawText(
        _ text: String, at point: CGPoint,
        font: UIFont, color: UIColor, width: CGFloat = 200
    ) {
        text.draw(in: CGRect(x: point.x, y: point.y, width: width, height: 20),
                  withAttributes: [.font: font, .foregroundColor: color])
    }
}
