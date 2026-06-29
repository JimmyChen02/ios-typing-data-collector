import Foundation
import CoreMotion

// MARK: - MotionRecorder
//
// OFF by default (isEnabled = false). Set isEnabled = true before calling
// start() to activate IMU recording. While isEnabled = false, start() and
// stop() are no-ops so the class is safe to wire up without activating it.
//
// When enabled: samples CMDeviceMotion at 50 Hz, buffers frames in memory,
// and writes one CSV to `Documents/imu/<sessionId>.csv` on stop().
//
// CSV header:
//   t_ms,attitude_roll,attitude_pitch,attitude_yaw,
//   grav_x,grav_y,grav_z,acc_x,acc_y,acc_z,rot_x,rot_y,rot_z
//
// IMU fusion with hand images is documented as future work (spec decision 6).
// SessionManager does NOT call start/stop — see the seam comments there.

final class MotionRecorder {

    static let shared = MotionRecorder()
    private init() {}

    // Set to true (and set before calling start) to activate recording.
    var isEnabled: Bool = false

    // MARK: - Private State

    private let manager = CMMotionManager()
    private var startDate: Date?
    private var sessionIdForCSV: UUID?
    private var frames: [MotionFrame] = []
    private let queue = OperationQueue()

    private struct MotionFrame {
        let tMs: Double
        let roll: Double
        let pitch: Double
        let yaw: Double
        let gravX: Double
        let gravY: Double
        let gravZ: Double
        let accX: Double
        let accY: Double
        let accZ: Double
        let rotX: Double
        let rotY: Double
        let rotZ: Double
    }

    // MARK: - Public API

    /// Begin sampling device motion at 50 Hz for the given session.
    /// No-op when isEnabled == false.
    func start(sessionId: UUID, studySessionIndex: Int) {
        guard isEnabled else { return }
        guard manager.isDeviceMotionAvailable else {
            print("MotionRecorder: device motion not available on this device")
            return
        }

        frames.removeAll(keepingCapacity: true)
        startDate = Date()
        sessionIdForCSV = sessionId

        manager.deviceMotionUpdateInterval = 1.0 / 50.0
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            guard let self, let motion else { return }
            let t = Date().timeIntervalSince(self.startDate ?? Date()) * 1000.0
            self.frames.append(MotionFrame(
                tMs:   t,
                roll:  motion.attitude.roll,
                pitch: motion.attitude.pitch,
                yaw:   motion.attitude.yaw,
                gravX: motion.gravity.x,
                gravY: motion.gravity.y,
                gravZ: motion.gravity.z,
                accX:  motion.userAcceleration.x,
                accY:  motion.userAcceleration.y,
                accZ:  motion.userAcceleration.z,
                rotX:  motion.rotationRate.x,
                rotY:  motion.rotationRate.y,
                rotZ:  motion.rotationRate.z
            ))
        }
    }

    /// Stop sampling and write the buffered frames to
    /// `Documents/imu/<sessionId>.csv`. Returns the file URL on success, nil
    /// when disabled or on write failure.
    func stop() -> URL? {
        guard isEnabled else { return nil }
        manager.stopDeviceMotionUpdates()

        guard let sid = sessionIdForCSV else { return nil }
        let captured = frames
        frames.removeAll()
        startDate = nil
        sessionIdForCSV = nil

        return writeCSV(frames: captured, sessionId: sid)
    }

    // MARK: - CSV Writing

    private func writeCSV(frames: [MotionFrame], sessionId: UUID) -> URL? {
        let dir = imuDirectory()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            print("MotionRecorder: could not create imu dir: \(error)")
            return nil
        }

        var rows: [String] = [
            "t_ms,attitude_roll,attitude_pitch,attitude_yaw," +
            "grav_x,grav_y,grav_z,acc_x,acc_y,acc_z,rot_x,rot_y,rot_z"
        ]
        for f in frames {
            rows.append(String(format: "%.3f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f",
                f.tMs, f.roll, f.pitch, f.yaw,
                f.gravX, f.gravY, f.gravZ,
                f.accX, f.accY, f.accZ,
                f.rotX, f.rotY, f.rotZ))
        }

        let content = rows.joined(separator: "\n")
        guard let data = content.data(using: .utf8) else { return nil }

        let url = dir.appendingPathComponent("\(sessionId.uuidString).csv")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("MotionRecorder: write failed: \(error)")
            return nil
        }
    }

    private func imuDirectory() -> URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("imu")
    }
}
