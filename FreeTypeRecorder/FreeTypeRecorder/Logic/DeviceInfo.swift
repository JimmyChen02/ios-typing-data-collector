import Foundation
import UIKit

/// Auto-detected phone identity for session metadata. `marketingName(for:)`
/// is pure and unit-tested; the device reads (`hardwareIdentifier`,
/// `systemVersion`, `appVersion`) run on-device/simulator.
enum DeviceInfo {
    /// e.g. "iPhone16,1". In the Simulator, reports the simulated device via
    /// SIMULATOR_MODEL_IDENTIFIER; on device, via uname().
    static var hardwareIdentifier: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return sim
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { bytes in
            bytes.compactMap { $0 == 0 ? nil : Character(UnicodeScalar($0)) }
                 .map(String.init).joined()
        }
    }

    /// Marketing name for a hardware id. Unknown ids fall back to
    /// "iPhone (<id>)" so nothing is fabricated.
    static func marketingName(for id: String) -> String {
        modelMap[id] ?? "iPhone (\(id))"
    }

    static var modelName: String { marketingName(for: hardwareIdentifier) }
    static var systemVersion: String { UIDevice.current.systemVersion }
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private static let modelMap: [String: String] = [
        "iPhone8,4":  "iPhone SE (1st gen)",
        "iPhone12,8": "iPhone SE (2nd gen)",
        "iPhone14,6": "iPhone SE (3rd gen)",
        "iPhone12,1": "iPhone 11",
        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16",
        "iPhone17,2": "iPhone 16 Plus",
        "iPhone17,3": "iPhone 16 Pro",
        "iPhone17,4": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e",
        "arm64":      "Simulator (arm64)",
        "x86_64":     "Simulator (x86_64)",
    ]
}
