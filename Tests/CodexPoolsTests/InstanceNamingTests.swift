import XCTest
@testable import CodexPools

final class InstanceNamingTests: XCTestCase {
    func testNextAvailableNameReturnsPrefixWhenUnused() {
        XCTAssertEqual(
            InstanceNaming.nextAvailableName(prefix: "Codex", existingNames: []),
            "Codex"
        )
    }

    func testNextAvailableNameUsesSecondNameForFirstConflict() {
        XCTAssertEqual(
            InstanceNaming.nextAvailableName(prefix: "Codex", existingNames: ["Codex"]),
            "Codex 2"
        )
    }

    func testNextAvailableNameSkipsOccupiedSuffixes() {
        XCTAssertEqual(
            InstanceNaming.nextAvailableName(
                prefix: "Codex",
                existingNames: ["Codex", "Codex 2", "Codex 3"]
            ),
            "Codex 4"
        )
    }

    func testNextAvailableNameReusesGaps() {
        XCTAssertEqual(
            InstanceNaming.nextAvailableName(prefix: "Codex", existingNames: ["Codex", "Codex 3"]),
            "Codex 2"
        )
    }

    func testNextAvailableNameWorksForTemplatePrefixes() {
        XCTAssertEqual(
            InstanceNaming.nextAvailableName(prefix: "Review", existingNames: ["Review", "Review 2"]),
            "Review 3"
        )
    }
}
