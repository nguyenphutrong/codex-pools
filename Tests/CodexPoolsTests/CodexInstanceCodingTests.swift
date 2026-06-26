import Foundation
import XCTest
@testable import CodexPools

final class CodexInstanceCodingTests: XCTestCase {
    func testRoundTripsFullyPopulatedInstance() throws {
        let instance = CodexInstance(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Review Pool",
            iconPath: "/tmp/icon.png",
            codexHome: "/tmp/home",
            bundleStatus: .ready,
            extraEnvVars: ["CODEX_HOME": "/tmp/home", "MODE": "review"],
            launchArgs: ["--sandbox", "workspace-write"],
            createdAt: Date(timeIntervalSince1970: 1_704_067_200),
            lastLaunchedAt: Date(timeIntervalSince1970: 1_704_070_800)
        )

        let data = try JSONEncoder.instanceEncoder.encode(instance)
        let decoded = try JSONDecoder.instanceDecoder.decode(CodexInstance.self, from: data)

        XCTAssertEqual(decoded, instance)
    }

    func testDecodesMissingOptionalAndDefaultedFields() throws {
        let json = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "Legacy Pool",
          "codexHome": "/tmp/legacy",
          "createdAt": "2024-01-01T00:00:00Z"
        }
        """

        let data = Data(json.utf8)
        let decoded = try JSONDecoder.instanceDecoder.decode(CodexInstance.self, from: data)

        XCTAssertEqual(decoded.id, UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        XCTAssertEqual(decoded.kind, .managed)
        XCTAssertEqual(decoded.name, "Legacy Pool")
        XCTAssertNil(decoded.iconPath)
        XCTAssertEqual(decoded.codexHome, "/tmp/legacy")
        XCTAssertEqual(decoded.bundleStatus, .missingSourceApp)
        XCTAssertEqual(decoded.extraEnvVars, [:])
        XCTAssertEqual(decoded.launchArgs, [])
        XCTAssertEqual(decoded.createdAt, Date(timeIntervalSince1970: 1_704_067_200))
        XCTAssertNil(decoded.lastLaunchedAt)
    }

    func testUsesISO8601DateCoding() throws {
        let instance = CodexInstance(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Date Pool",
            codexHome: "/tmp/date",
            createdAt: Date(timeIntervalSince1970: 1_704_067_200)
        )

        let data = try JSONEncoder.instanceEncoder.encode(instance)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(json.contains(#""createdAt" : "2024-01-01T00:00:00Z""#))
    }
}
