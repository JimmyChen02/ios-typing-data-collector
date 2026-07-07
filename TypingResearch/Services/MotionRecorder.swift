import Foundation
import CoreMotion

// MARK: - MotionRecorder
//
// ON by default (isEnabled = true). While isEnabled = false, start() and
// stop() are no-ops so the class is safe to wire up without activating it.
//
// When enabled: samples CMDeviceMotion at 50 Hz, buffers frames in memory,
// and writes one CSV to `Documents/imu/<sessionId>.csv` on stop().
//
// CSV header:
//   t_ms,attitude_roll,attitude_pitch,attitude_yaw,
//   grav_x,grav_y,grav_z,acc_x,acc_y,acc_z,rot_x,rot_y,rot_z
//
// SessionManager calls start() in startSession(...) and stop() in
// finalizeSession() — see the seam call sites there.

final class MotionRecorder {

    static let shared = MotionRecorder()
    private init() {}

    // Set to true (and set before calling start) to activate recording.
    var isEnabled: Bool = true

    // MARK: - Live-callback hook (D3)
    //
    // Optional, nil by default (guarded — normal runs never set this).
    // Lets PosturePredictor buffer the live 50 Hz motion stream for on-device
    // inference WITHOUT owning a second CMMotionManager (avoids two motion
    // managers sampling the same hardware). Does NOT change the CSV output
    // or the 50 Hz cadence — this is purely an additional fan-out of the
    // same per-frame values already being appended to `frames` below.
    // Called on the same delegate queue as the CSV recording (NOT the main
    // thread); PosturePredictor is responsible for hopping to whatever
    // isolation it needs.
    var onFrame: ((MotionFrame) -> Void)?

    // MARK: - Private State

    private let manager = CMMotionManager()
    private var startDate: Date?
    private var sessionIdForCSV: UUID?
    private var frames: [MotionFrame] = []
    private let queue = OperationQueue()

    struct MotionFrame {
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
            let frame = MotionFrame(
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
            )
            self.frames.append(frame)
            // Live fan-out for PosturePredictor (D3) — does not affect CSV
            // output or the 50 Hz cadence above. nil in normal runs.
            self.onFrame?(frame)
        }
    }

    // MARK: - Monitor-only mode (live posture demo)
    //
    // Fans frames out to `onFrame` WITHOUT buffering or CSV writing — used
    // by the standalone LivePostureDemoView, which needs live IMU for
    // PosturePredictor but is not part of any session. No-op while a
    // session recording is active (onFrame is already fed by start()).

    private var isMonitoring = false

    /// Start 50 Hz device-motion updates that only feed `onFrame`.
    /// Idempotent; no-op during an active session recording.
    func startMonitoring() {
        guard sessionIdForCSV == nil, !isMonitoring else { return }
        guard manager.isDeviceMotionAvailable else {
            print("MotionRecorder: device motion not available (monitoring)")
            return
        }
        isMonitoring = true
        let monitorStart = Date()
        manager.deviceMotionUpdateInterval = 1.0 / 50.0
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let frame = MotionFrame(
                tMs:   Date().timeIntervalSince(monitorStart) * 1000.0,
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
            )
            self.onFrame?(frame)
        }
    }

    /// Stop monitor-only updates. Leaves an active session recording
    /// untouched. Idempotent.
    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        if sessionIdForCSV == nil {
            manager.stopDeviceMotionUpdates()
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
