import Foundation
import CoreGraphics

// MARK: - Gaussian2D
//
// Per-key 2D Gaussian fitted on CENTERED tap offsets in POINT space:
//     offsetX = tapLocalX - keyWidth  / 2
//     offsetY = tapLocalY - keyHeight / 2
//
// `muX`, `muY` are the mean offsets from the key's geometric center.
// `sxx`, `syy`, `sxy` are the entries of the 2x2 covariance Sigma.
// `pxx`, `pyy`, `pxy` cache Sigma^-1 (the precision matrix) so the inner
// Mahalanobis score is ~6 multiplies per pixel per key.
//
// Mahalanobis distance squared:
//     D^2 = [dx dy] * Sigma^-1 * [dx dy]^T
//         = pxx*dx*dx + 2*pxy*dx*dy + pyy*dy*dy
// Log-density (up to the -log(2 pi) constant that cancels under argmax):
//     log N(dx, dy | 0, Sigma) = -0.5 * (D^2 + log|Sigma|)

struct Gaussian2D: Codable {
    let muX:    Double
    let muY:    Double
    let sxx:    Double
    let syy:    Double
    let sxy:    Double
    let pxx:    Double
    let pyy:    Double
    let pxy:    Double
    let logDet: Double
    let count:  Int

    /// Mahalanobis log-density of (dx, dy) under this Gaussian, where
    /// (dx, dy) is the query point expressed as an offset from the key's
    /// geometric center (same reference frame as muX, muY).
    @inlinable
    func logScore(dx: Double, dy: Double) -> Double {
        let ux = dx - muX
        let uy = dy - muY
        let m2 = pxx * ux * ux + 2.0 * pxy * ux * uy + pyy * uy * uy
        return -0.5 * (m2 + logDet)
    }
}

// MARK: - GaussianKeyModel
//
// Fits one Gaussian per key from CORRECT taps and exposes a competitive
// argmax scorer over a set of keys-with-frames. Only correct taps are fit
// because a mistap (landed j, meant h) is recorded in the LANDED key's
// reference frame — it cannot be trusted to describe the expected key's
// distribution without knowing both keys' positions.

final class GaussianKeyModel {

    // Minimum correct taps required to fit a key. Below this we fall back
    // to an isotropic Gaussian sized from the key's frame (see
    // fallbackGaussian) so every key still claims territory in the raster.
    static let minSamples: Int = 5

    // Ridge added to Sigma's diagonal before inversion, expressed as a
    // fraction of the mean key width. Prevents singular covariance when
    // all taps land on a near-line (common for tall/narrow keys).
    static let ridgeFrac: Double = 0.05

    // Anchor protection: any query point within this fraction of the key's
    // smaller side (from the key's geometric center) is forced to that key
    // regardless of Gaussian scores. Stops a skewed Gaussian from stealing
    // its neighbor's center.
    static let anchorFrac: Double = 0.20

    // Spatial prior: soft quadratic log-penalty on a key's score for query
    // points outside that key's own rect. Expressed as the Gaussian
    // "sigma" (in key-dimension units) of the falloff beyond the rect
    // edge. Zero inside the rect, grows quadratically outside. Keeps a
    // wide fallback or a shifted-mean Gaussian from claiming territory
    // that belongs to a neighbor's geometric area.
    static let spatialPriorFrac: Double = 0.40

    var gaussians: [String: Gaussian2D] = [:]

    init(gaussians: [String: Gaussian2D] = [:]) {
        self.gaussians = gaussians
    }

    /// log prior = -0.5 * ((out_x / sigma_x)^2 + (out_y / sigma_y)^2)
    /// where out_{x,y} is the signed distance *outside* the key's rect
    /// edge (0 inside). sigma_{x,y} = spatialPriorFrac * keyWidth/Height
    /// so the penalty scales with key size.
    @inlinable
    static func spatialPrior(
        dx: Double, dy: Double,
        kw: Double, kh: Double
    ) -> Double {
        let hx = kw / 2.0
        let hy = kh / 2.0
        let ox = max(0.0, abs(dx) - hx)
        let oy = max(0.0, abs(dy) - hy)
        let sx = spatialPriorFrac * kw
        let sy = spatialPriorFrac * kh
        let rx = ox / sx
        let ry = oy / sy
        return -0.5 * (rx * rx + ry * ry)
    }

    // MARK: - Fitting

    /// Fits one Gaussian per key from the CORRECT taps in `events`. A tap
    /// is correct when the landed keyLabel matches expectedChar (or is
    /// "space" for a space character). Mistaps are dropped — they live in
    /// the wrong reference frame to inform the expected key's Gaussian.
    static func fit(
        events: [InputEventData],
        keys: [String]
    ) -> GaussianKeyModel {
        let correct = events.filter {
            $0.isCorrect &&
            !$0.keyLabel.isEmpty &&
            $0.keyWidth > 0 && $0.keyHeight > 0
        }
        let byKey: [String: [InputEventData]] = Dictionary(grouping: correct, by: \.keyLabel)

        var result: [String: Gaussian2D] = [:]
        for key in keys {
            let samples = byKey[key] ?? []
            if samples.count >= minSamples,
               let g = fitSingle(samples: samples) {
                result[key] = g
            }
        }
        return GaussianKeyModel(gaussians: result)
    }

    private static func fitSingle(samples: [InputEventData]) -> Gaussian2D? {
        let n = Double(samples.count)
        guard n >= Double(minSamples) else { return nil }

        // Centered offsets in point space.
        var ox = [Double](); ox.reserveCapacity(samples.count)
        var oy = [Double](); oy.reserveCapacity(samples.count)
        var meanKw = 0.0
        for e in samples {
            ox.append(e.tapLocalX - e.keyWidth  / 2.0)
            oy.append(e.tapLocalY - e.keyHeight / 2.0)
            meanKw += e.keyWidth
        }
        meanKw /= n

        let muX = ox.reduce(0, +) / n
        let muY = oy.reduce(0, +) / n

        // Sample covariance (n-1 denominator).
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for i in 0..<samples.count {
            let dx = ox[i] - muX
            let dy = oy[i] - muY
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        let denom = max(1.0, n - 1.0)
        sxx /= denom; syy /= denom; sxy /= denom

        // Ridge regularization — stabilises inversion when cov is near-rank-1.
        let ridge = (ridgeFrac * meanKw) * (ridgeFrac * meanKw)
        sxx += ridge
        syy += ridge

        let det = sxx * syy - sxy * sxy
        guard det > 0 else { return nil }
        let inv = 1.0 / det
        return Gaussian2D(
            muX: muX, muY: muY,
            sxx: sxx, syy: syy, sxy: sxy,
            pxx:  syy * inv,
            pyy:  sxx * inv,
            pxy: -sxy * inv,
            logDet: log(det),
            count: samples.count
        )
    }

    /// Isotropic Gaussian sized to a key's frame. Used for keys with too
    /// few correct taps — so the raster still paints territory for them
    /// instead of leaving a hole.
    static func fallbackGaussian(for frame: CGRect) -> Gaussian2D {
        let sigma = Double(min(frame.width, frame.height)) / 3.0
        let s = sigma * sigma
        return Gaussian2D(
            muX: 0, muY: 0,
            sxx: s, syy: s, sxy: 0,
            pxx: 1.0 / s, pyy: 1.0 / s, pxy: 0,
            logDet: log(s * s),
            count: 0
        )
    }

    // MARK: - Competitive argmax
    //
    // Per-pixel winner combines three things:
    //   1. Anchor override — radial disc around each key's center. A pixel
    //      inside any key's anchor is forced to that key immediately.
    //   2. Mahalanobis log-density under the fitted (or fallback) Gaussian.
    //   3. Spatial prior — quadratic log-penalty outside the key's rect.
    // Argmax over (log-density + prior) gives the winner.

    func winner(
        at p: CGPoint,
        frames: [(key: String, rect: CGRect)]
    ) -> String? {
        // 1. Anchor override.
        for (key, rect) in frames {
            let anchorR = Self.anchorFrac * Double(min(rect.width, rect.height)) / 2.0
            let dx = Double(p.x) - Double(rect.midX)
            let dy = Double(p.y) - Double(rect.midY)
            if dx * dx + dy * dy <= anchorR * anchorR {
                return key
            }
        }

        // 2. Argmax of (Gaussian log-density + spatial prior).
        var bestKey: String? = nil
        var bestScore = -Double.greatestFiniteMagnitude
        for (key, rect) in frames {
            let g = gaussians[key] ?? Self.fallbackGaussian(for: rect)
            let dx = Double(p.x) - Double(rect.midX)
            let dy = Double(p.y) - Double(rect.midY)
            let prior = Self.spatialPrior(
                dx: dx, dy: dy,
                kw: Double(rect.width), kh: Double(rect.height)
            )
            let s = g.logScore(dx: dx, dy: dy) + prior
            if s > bestScore {
                bestScore = s
                bestKey = key
            }
        }
        return bestKey
    }

    // MARK: - Ellipse geometry (for overlay rendering)

    /// Returns the 1-sigma ellipse in screen coordinates: center (canvas
    /// point), semi-axes (semiA >= semiB), and rotation (radians).
    /// Computed as the eigendecomposition of the 2x2 covariance.
    static func ellipse(
        for g: Gaussian2D,
        keyFrame: CGRect
    ) -> (center: CGPoint, semiA: Double, semiB: Double, angle: Double) {
        let cx = Double(keyFrame.midX) + g.muX
        let cy = Double(keyFrame.midY) + g.muY

        let tr   = g.sxx + g.syy
        let det  = g.sxx * g.syy - g.sxy * g.sxy
        let disc = max(0.0, (tr * tr) / 4.0 - det)
        let root = disc.squareRoot()
        let l1   = tr / 2.0 + root
        let l2   = max(0.0, tr / 2.0 - root)

        let angle: Double
        if abs(g.sxy) > 1e-12 {
            angle = atan2(l1 - g.sxx, g.sxy)
        } else {
            angle = g.sxx >= g.syy ? 0 : .pi / 2
        }

        return (
            center: CGPoint(x: cx, y: cy),
            semiA:  l1.squareRoot(),
            semiB:  l2.squareRoot(),
            angle:  angle
        )
    }
}
