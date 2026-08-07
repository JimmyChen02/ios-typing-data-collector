import XCTest

final class DeviceInfoTests: XCTestCase {
    func test_marketingName_knownIdentifier() {
        XCTAssertEqual(DeviceInfo.marketingName(for: "iPhone16,1"), "iPhone 15 Pro")
        XCTAssertEqual(DeviceInfo.marketingName(for: "iPhone17,3"), "iPhone 16 Pro")
        XCTAssertEqual(DeviceInfo.marketingName(for: "iPhone18,1"), "iPhone 17 Pro")
        XCTAssertEqual(DeviceInfo.marketingName(for: "iPhone18,4"), "iPhone Air")
    }

    func test_marketingName_unknownIdentifierFallsBack() {
        XCTAssertEqual(DeviceInfo.marketingName(for: "iPhone99,9"), "iPhone (iPhone99,9)")
    }
}
