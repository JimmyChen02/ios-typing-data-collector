import XCTest

final class SessionMetaTests: XCTestCase {
    private func sample() -> SessionMeta {
        SessionMeta(
            participant: "Alex", hand: "left", startedAt: "2026-08-01T10:00:00Z",
            age: 21, sex: "female", dominantHand: "right",
            deviceModel: "iPhone 15 Pro", deviceModelIdentifier: "iPhone16,1",
            systemVersion: "17.5", appVersion: "1.0",
            sessionNumber: 3, prompt: "What did you eat today, and did you like it?"
        )
    }

    func test_roundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(sample())
        let decoded = try JSONDecoder().decode(SessionMeta.self, from: data)
        XCTAssertEqual(decoded, sample())
    }

    func test_jsonContainsNewFields() throws {
        let data = try JSONEncoder().encode(sample())
        let json = String(data: data, encoding: .utf8) ?? ""
        for key in ["sessionNumber", "prompt", "dominantHand", "sex", "age", "deviceModel"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "missing key \(key)")
        }
    }

    func testNativeCaptureMetadataAndLegacyCompatibility() throws {
        let legacy = try JSONDecoder().decode(SessionMeta.self, from: JSONEncoder().encode(sample()))
        XCTAssertNil(legacy.tapCaptureMethod)
        XCTAssertNil(legacy.measuredTapCount)
        var recorded = sample()
        recorded.keyboardMode = "system"
        recorded.tapCaptureMethod = "uiapplication_send_event"
        recorded.measuredTapCount = 3
        XCTAssertEqual(try JSONDecoder().decode(SessionMeta.self, from: JSONEncoder().encode(recorded)), recorded)
    }
}
