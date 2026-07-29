import Foundation
import CoreMotion

/// Records 50Hz device-motion IMU samples for a session, writing them to
/// `imu.csv` inside that session's folder. Ported from TypingResearch's
/// MotionRecorder — same column order/format, so this data stays loadable
/// by the same offline analysis/training scripts.
@MainActor
final class IMURecorder {
    static let shared = IMURecorder()

    struct MotionFrame {
        let tMs: Double
        let roll, pitch, yaw: Double
        let gravX, gravY, gravZ: Double
        let accX, accY, accZ: Double
        let rotX, rotY, rotZ: Double
    }

    /// Live fan-out for every frame, independent of buffering — lets
    /// PosturePredictor run inference without a second CMMotionManager.
    var onFrame: ((MotionFrame) -> Void)?

    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private var frames: [MotionFrame] = []
    private var startDate: Date?
    private(set) var isRecording = false

    private init() {}

    func start() {
        guard !isRecording, manager.isDeviceMotionAvailable else { return }
        isRecording = true
        frames.removeAll(keepingCapacity: true)
        startDate = Date()

        manager.deviceMotionUpdateInterval = 1.0 / 50.0
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let motion else { return }
            let now = Date()
            Task { @MainActor in
                guard let self, let startDate = self.startDate else { return }
                let frame = MotionFrame(
                    tMs: now.timeIntervalSince(startDate) * 1000.0,
                    roll: motion.attitude.roll, pitch: motion.attitude.pitch, yaw: motion.attitude.yaw,
                    gravX: motion.gravity.x, gravY: motion.gravity.y, gravZ: motion.gravity.z,
                    accX: motion.userAcceleration.x, accY: motion.userAcceleration.y, accZ: motion.userAcceleration.z,
                    rotX: motion.rotationRate.x, rotY: motion.rotationRate.y, rotZ: motion.rotationRate.z
                )
                self.frames.append(frame)
                self.onFrame?(frame)
            }
        }
    }

    /// Stops sampling and writes the buffered frames to `outputURL`
    /// (typically `<sessionDirectory>/imu.csv`). Returns the URL on
    /// success, nil if nothing was recorded or the write failed.
    func stop(writingTo outputURL: URL) -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        manager.stopDeviceMotionUpdates()

        guard !frames.isEmpty else { return nil }

        var csv = "t_ms,attitude_roll,attitude_pitch,attitude_yaw,grav_x,grav_y,grav_z,acc_x,acc_y,acc_z,rot_x,rot_y,rot_z\n"
        for frame in frames {
            csv += String(
                format: "%.3f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
                frame.tMs, frame.roll, frame.pitch, frame.yaw,
                frame.gravX, frame.gravY, frame.gravZ,
                frame.accX, frame.accY, frame.accZ,
                frame.rotX, frame.rotY, frame.rotZ
            )
        }

        do {
            try csv.write(to: outputURL, atomically: true, encoding: .utf8)
            return outputURL
        } catch {
            print("IMURecorder: failed to write CSV: \(error)")
            return nil
        }
    }
}
