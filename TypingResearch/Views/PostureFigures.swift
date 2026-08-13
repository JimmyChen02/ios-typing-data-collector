import SwiftUI

/// Do/don't posture line art from FreeTypeRecorder on main.
/// Drawn in a 210×231 space and scaled to fit.
struct PostureFigure: View {
    enum Kind { case doSit, dontSit }
    let kind: Kind

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / 210, size.height / 231)
            let ox = (size.width - 210 * s) / 2
            let oy = (size.height - 231 * s) / 2
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
            func poly(_ pts: [(CGFloat, CGFloat)], _ shading: GraphicsContext.Shading, width: CGFloat = 5, dash: [CGFloat] = []) {
                var path = Path()
                path.move(to: p(pts[0].0, pts[0].1))
                for pt in pts.dropFirst() { path.addLine(to: p(pt.0, pt.1)) }
                ctx.stroke(path, with: shading, style: StrokeStyle(lineWidth: width * s, lineCap: .round, lineJoin: .round, dash: dash.map { $0 * s }))
            }
            func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ shading: GraphicsContext.Shading) {
                let rect = CGRect(x: p(cx, cy).x - r * s, y: p(cx, cy).y - r * s, width: 2 * r * s, height: 2 * r * s)
                ctx.stroke(Path(ellipseIn: rect), with: shading, style: StrokeStyle(lineWidth: 5 * s))
            }
            func phone(center: CGPoint, w: CGFloat, h: CGFloat, degrees: Double, _ shading: GraphicsContext.Shading) {
                ctx.drawLayer { layer in
                    layer.translateBy(x: center.x, y: center.y)
                    layer.rotate(by: .degrees(degrees))
                    let r = CGRect(x: -w * s / 2, y: -h * s / 2, width: w * s, height: h * s)
                    layer.fill(Path(roundedRect: r, cornerRadius: 3 * s), with: shading)
                }
            }

            let body: GraphicsContext.Shading = .color(.white)
            let furn: GraphicsContext.Shading = .color(.gray)

            poly([(14, 204), (196, 204)], furn)
            poly([(120, 158), (120, 100)], furn)
            poly([(84, 158), (130, 158)], furn)
            poly([(88, 158), (88, 203)], furn)
            poly([(124, 158), (124, 203)], furn)

            switch kind {
            case .doSit:
                poly([(18, 138), (78, 138)], furn)
                poly([(26, 138), (26, 203)], furn)
                poly([(102, 66), (112, 152)], .color(.green), width: 3, dash: [3, 6])
                circle(100, 52, 15, body)
                poly([(101, 67), (112, 152)], body)
                poly([(112, 152), (78, 152)], body)
                poly([(78, 152), (74, 202)], body)
                poly([(62, 202), (86, 202)], body)
                poly([(103, 80), (100, 118)], body)
                poly([(100, 118), (74, 96)], body)
                phone(center: p(62, 92), w: 15, h: 24, degrees: -22, body)
            case .dontSit:
                poly([(18, 140), (82, 140)], furn)
                poly([(26, 140), (26, 203)], furn)
                circle(84, 70, 15, body)
                var spine = Path()
                spine.move(to: p(92, 84))
                spine.addCurve(to: p(112, 154), control1: p(80, 104), control2: p(92, 138))
                ctx.stroke(spine, with: body, style: StrokeStyle(lineWidth: 5 * s, lineCap: .round, lineJoin: .round))
                poly([(112, 154), (78, 153)], body)
                poly([(78, 153), (74, 202)], body)
                poly([(62, 202), (86, 202)], body)
                poly([(95, 92), (92, 128)], body)
                poly([(92, 128), (42, 133)], body)
                phone(center: p(41, 128), w: 22, h: 12, degrees: -6, body)
                poly([(40, 141), (46, 146)], .color(.red))
                poly([(50, 141), (56, 146)], .color(.red))
            }
        }
        .accessibilityLabel(kind == .doSit
            ? "Sitting upright, phone held up, arm off the desk"
            : "Slouching, forearm resting on the desk")
    }
}

struct HowToSitDiagrams: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            figurePanel(
                kind: .doSit,
                badge: "checkmark.circle.fill",
                tint: .green,
                label: "Do this",
                caption: "Back straight, phone up, arm free."
            )
            figurePanel(
                kind: .dontSit,
                badge: "xmark.circle.fill",
                tint: .red,
                label: "Not this",
                caption: "Slouched, arm on the desk."
            )
        }
    }

    private func figurePanel(
        kind: PostureFigure.Kind,
        badge: String,
        tint: Color,
        label: String,
        caption: String
    ) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                PostureFigure(kind: kind)
                    .frame(height: 180)
                    .frame(maxWidth: .infinity)
                    .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 14))
                Image(systemName: badge)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .padding(8)
            }
            Text(label)
                .font(.subheadline)
                .bold()
                .foregroundStyle(tint)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
