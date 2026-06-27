import Foundation
import XCTest
@testable import CodexPoolsCore

final class BundleCloneServiceTests: XCTestCase {
    func testBundleURLUsesUserApplicationsCodexPoolsRoot() {
        let instance = CodexInstance(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Review Pool",
            codexHome: "/tmp/home"
        )
        let expectedPrefix = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications")
            .appendingPathComponent("Codex Pools")
            .appendingPathComponent(instance.id.uuidString)
            .path

        XCTAssertEqual(
            BundleCloneService().bundleURL(for: instance).path,
            "\(expectedPrefix)/Review Pool.app"
        )
    }
}
