import UIKit

/// Draws a small, precise gray dot at each tap location — showing exactly
/// where a finger touched, not a stylized effect. `isUserInteractionEnabled`
/// is false so it never intercepts touches; it only sits visually on top.
final class TouchDotOverlayView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func addDot(at point: CGPoint) {
        let diameter: CGFloat = 16
        let dot = UIView(frame: CGRect(
            x: point.x - diameter / 2,
            y: point.y - diameter / 2,
            width: diameter,
            height: diameter
        ))
        dot.backgroundColor = .darkGray
        dot.layer.cornerRadius = diameter / 2
        // A white border keeps the dot visible against dark backgrounds too,
        // since a plain dark-gray fill can disappear against dark UI.
        dot.layer.borderWidth = 1.5
        dot.layer.borderColor = UIColor.white.cgColor
        addSubview(dot)

        // Held briefly at full opacity so it's clearly visible frame-by-frame
        // in the recording, then fades — no animated scaling/motion, since
        // the point is marking the exact tap location, not an effect.
        UIView.animate(
            withDuration: 0.3,
            delay: 0.25,
            options: [],
            animations: {
                dot.alpha = 0
            },
            completion: { _ in
                dot.removeFromSuperview()
            }
        )
    }
}
