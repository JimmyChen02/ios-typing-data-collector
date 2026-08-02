import XCTest

final class SessionNamingTests: XCTestCase {
    func test_folderName_zeroPaddedNumberAndHand() {
        XCTAssertEqual(SessionNaming.folderName(number: 3, hand: .left), "03_left")
        XCTAssertEqual(SessionNaming.folderName(number: 10, hand: .both), "10_both")
        XCTAssertEqual(SessionNaming.folderName(number: 7, hand: .right), "07_right")
    }

    func test_uniqueFolderName_noCollisionReturnsBase() {
        let name = SessionNaming.uniqueFolderName(
            number: 3, hand: .left, exists: { _ in false }, suffix: { "120000" }
        )
        XCTAssertEqual(name, "03_left")
    }

    func test_uniqueFolderName_collisionAppendsSuffix() {
        let name = SessionNaming.uniqueFolderName(
            number: 3, hand: .left, exists: { $0 == "03_left" }, suffix: { "120000" }
        )
        XCTAssertEqual(name, "03_left_120000")
    }
}
