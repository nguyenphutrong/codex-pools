import Foundation
import XCTest
@testable import CodexPoolsCore

final class InstanceResolverTests: XCTestCase {
    private let firstID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let secondID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!

    func testResolvesExactUUIDBeforeName() throws {
        let instances = [
            CodexInstance(id: firstID, name: secondID.uuidString, codexHome: "/tmp/name"),
            CodexInstance(id: secondID, name: "Review", codexHome: "/tmp/review")
        ]

        let resolved = try InstanceResolver.resolve(secondID.uuidString, in: instances)

        XCTAssertEqual(resolved.id, secondID)
    }

    func testResolvesCaseInsensitiveExactName() throws {
        let instance = CodexInstance(id: firstID, name: "Review Pool", codexHome: "/tmp/review")

        let resolved = try InstanceResolver.resolve("review pool", in: [instance])

        XCTAssertEqual(resolved.id, firstID)
    }

    func testAmbiguousNameThrows() {
        let instances = [
            CodexInstance(id: firstID, name: "Review", codexHome: "/tmp/one"),
            CodexInstance(id: secondID, name: "review", codexHome: "/tmp/two")
        ]

        XCTAssertThrowsError(try InstanceResolver.resolve("Review", in: instances)) { error in
            XCTAssertEqual(error as? InstanceResolveError, .ambiguous("Review", instances))
        }
    }

    func testMissingInstanceThrows() {
        XCTAssertThrowsError(try InstanceResolver.resolve("Missing", in: [])) { error in
            XCTAssertEqual(error as? InstanceResolveError, .notFound("Missing"))
        }
    }
}
