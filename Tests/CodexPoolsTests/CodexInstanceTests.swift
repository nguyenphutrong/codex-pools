import Foundation
import XCTest
@testable import CodexPoolsCore

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

    func testBundleVersionSummaryShowsReadyCloneVersion() {
        let instance = CodexInstance(
            name: "Review Pool",
            codexHome: "/tmp/home",
            bundleStatus: .ready,
            bundleShortVersion: "26.623.31921",
            bundleBuildVersion: "31921",
            sourceShortVersion: "26.623.31921",
            sourceBuildVersion: "31921"
        )

        XCTAssertEqual(instance.bundleVersionSummary, "v26.623.31921")
        XCTAssertEqual(instance.detailedBundleVersionSummary, "v26.623.31921 (31921)")
    }

    func testBundleVersionSummaryShowsStaleCloneAndSourceVersion() {
        let instance = CodexInstance(
            name: "Review Pool",
            codexHome: "/tmp/home",
            bundleStatus: .needsRebuild,
            bundleShortVersion: "26.623.31921",
            bundleBuildVersion: "31921",
            sourceShortVersion: "26.624.10000",
            sourceBuildVersion: "10000"
        )

        XCTAssertEqual(instance.bundleVersionSummary, "v26.623.31921 -> v26.624.10000")
        XCTAssertEqual(instance.detailedBundleVersionSummary, "v26.623.31921 (31921) -> v26.624.10000 (10000)")
    }

    func testBundleVersionSummaryHandlesMissingCloneVersion() {
        let instance = CodexInstance(
            name: "Review Pool",
            codexHome: "/tmp/home",
            bundleStatus: .needsRebuild,
            sourceShortVersion: "26.624.10000",
            sourceBuildVersion: "10000"
        )

        XCTAssertEqual(instance.bundleVersionSummary, "Not built yet")
        XCTAssertEqual(instance.detailedBundleVersionSummary, "Not built yet (source v26.624.10000 (10000))")
    }

    func testBundleVersionSummaryHandlesMissingSourceAndCloneVersion() {
        let instance = CodexInstance(
            name: "Review Pool",
            codexHome: "/tmp/home",
            bundleStatus: .missingSourceApp
        )

        XCTAssertEqual(instance.bundleVersionSummary, "Version unknown")
        XCTAssertEqual(instance.detailedBundleVersionSummary, "Version unknown")
    }
}
