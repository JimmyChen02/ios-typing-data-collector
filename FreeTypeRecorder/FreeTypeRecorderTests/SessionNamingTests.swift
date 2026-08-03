import XCTest

final class SessionNamingTests: XCTestCase {
    func test_folderName_nameTrialHand() {
        XCTAssertEqual(SessionNaming.folderName(name: "Alex", number: 3, hand: .left), "Alex,3,left")
        XCTAssertEqual(SessionNaming.folderName(name: "Alex", number: 10, hand: .both), "Alex,10,both")
        XCTAssertEqual(SessionNaming.folderName(name: "Sam", number: 7, hand: .right), "Sam,7,right")
    }

    func test_folderName_sanitizesSlashesAndCommas() {
        XCTAssertEqual(SessionNaming.folderName(name: "A/l,ex", number: 2, hand: .right), "Alex,2,right")
        XCTAssertEqual(SessionNaming.folderName(name: "  Jo  ", number: 1, hand: .left), "Jo,1,left")
    }

    func test_uniqueFolderName_noCollisionReturnsBase() {
        let name = SessionNaming.uniqueFolderName(
            name: "Alex", number: 3, hand: .left, exists: { _ in false }, suffix: { "120000" }
        )
        XCTAssertEqual(name, "Alex,3,left")
    }

    func test_uniqueFolderName_collisionAppendsSuffix() {
        let name = SessionNaming.uniqueFolderName(
            name: "Alex", number: 3, hand: .left, exists: { $0 == "Alex,3,left" }, suffix: { "120000" }
        )
        XCTAssertEqual(name, "Alex,3,left_120000")
    }
}
