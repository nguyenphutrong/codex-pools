import Foundation
import XCTest
@testable import CodexPools

final class CodexInstanceTests: XCTestCase {
    func testDefaultHomePathBuildsSlugUnderProvidedHomeDirectory() {
        let home = URL(fileURLWithPath: "/tmp/test-home", isDirectory: true)

        XCTAssertEqual(
            InstanceNaming.defaultHomePath(for: "My Codex Pool", homeDirectory: home),
            "/tmp/test-home/.codex/my-codex-pool"
        )
        XCTAssertEqual(
            InstanceNaming.defaultHomePath(for: "  Foo / Bar: Baz  ", homeDirectory: home),
            "/tmp/test-home/.codex/foo-bar-baz"
        )
        XCTAssertEqual(
            InstanceNaming.defaultHomePath(for: " /: \n ", homeDirectory: home),
            "/tmp/test-home/.codex/codex-instance"
        )
    }

    func testOriginalInstanceUsesStableReadonlyDefaults() {
        let home = URL(fileURLWithPath: "/tmp/test-home", isDirectory: true)
        let instance = CodexInstance.original(homeDirectory: home)

        XCTAssertEqual(instance.id, CodexInstance.originalID)
        XCTAssertEqual(instance.kind, .original)
        XCTAssertEqual(instance.name, "Codex Original")
        XCTAssertEqual(instance.codexHome, "/tmp/test-home/.codex")
        XCTAssertTrue(instance.isOriginal)
        XCTAssertFalse(instance.isEditable)
        XCTAssertEqual(instance.managedBundleIdentifier, "com.openai.codex")
    }

    func testManagedAppNameFallsBackForBlankNames() {
        let instance = CodexInstance(name: " \n\t ", codexHome: "/tmp/home")

        XCTAssertEqual(instance.managedAppName, "Codex Pool")
    }

    func testManagedAppNameTrimsNonBlankNames() {
        let instance = CodexInstance(name: "  Review Pool  ", codexHome: "/tmp/home")

        XCTAssertEqual(instance.managedAppName, "Review Pool")
    }

    func testManagedAppBundleNameSanitizesInvalidCharacters() {
        let instance = CodexInstance(name: "Foo/Bar:Baz\nQux\u{0007}", codexHome: "/tmp/home")

        XCTAssertEqual(instance.managedAppBundleName, "Foo-Bar-Baz-Qux-.app")
    }

    func testManagedAppBundleNameFallsBackForBlankNames() {
        let instance = CodexInstance(name: " \n\t ", codexHome: "/tmp/home")

        XCTAssertEqual(instance.managedAppBundleName, "Codex Pool.app")
    }

    func testManagedAppBundleNameAppendsExtensionToValidName() {
        let instance = CodexInstance(name: "Review Pool", codexHome: "/tmp/home")

        XCTAssertEqual(instance.managedAppBundleName, "Review Pool.app")
    }
}
