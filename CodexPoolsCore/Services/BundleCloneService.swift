import AppKit
import Darwin
import Foundation

public struct BundleCloneService {
    public struct BundleDetails {
        public let status: CodexInstance.BundleStatus
        public let cloneShortVersion: String?
        public let cloneBuildVersion: String?
        public let sourceShortVersion: String?
        public let sourceBuildVersion: String?
    }

    private let sourceAppURL = URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true)
    private let fileManager: FileManager
    private let appsRootURL: URL

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let home = fileManager.homeDirectoryForCurrentUser
        self.appsRootURL = home
            .appendingPathComponent("Applications")
            .appendingPathComponent("Codex Pools")
    }

    public func prepareBundle(for instance: CodexInstance) throws -> URL {
        try preflightRootUser()
        try preflightSourceApp()
        try preflightTools(iconPath: instance.iconPath)

        let sourceFingerprint = try sourceFingerprint()
        let iconFingerprint = iconFingerprint(for: instance.iconPath)
        let signingIdentity = signingIdentity()
        let destinationURL = bundleURL(for: instance)

        guard needsRebuild(
            instance: instance,
            destinationURL: destinationURL,
            sourceFingerprint: sourceFingerprint,
            iconFingerprint: iconFingerprint,
            signingIdentity: signingIdentity
        ) else {
            return destinationURL
        }

        if isRunning(bundleIdentifier: instance.managedBundleIdentifier) {
            throw BundleCloneError.instanceMustQuitBeforeRebuild(instance.managedAppName)
        }

        try preflightWritableDirectory(appsRootURL)

        let stagingDirectoryURL = stagingDirectoryURL(for: instance)
        let stagingBundleURL = stagingDirectoryURL.appendingPathComponent(
            instance.managedAppBundleName,
            isDirectory: true
        )
        var shouldCleanStaging = true
        defer {
            if shouldCleanStaging {
                try? removeItemIfPresent(at: stagingDirectoryURL)
            }
        }

        try removeItemIfPresent(at: stagingDirectoryURL)
        try fileManager.createDirectory(
            at: stagingDirectoryURL,
            withIntermediateDirectories: true
        )

        try fileManager.copyItem(at: sourceAppURL, to: stagingBundleURL)
        try patchMainInfoPlist(
            for: instance,
            appURL: stagingBundleURL,
            sourceFingerprint: sourceFingerprint,
            iconFingerprint: iconFingerprint,
            signingIdentity: signingIdentity
        )
        try patchHelperBundleIdentifiers(appURL: stagingBundleURL, bundleIdentifier: instance.managedBundleIdentifier)
        try disableDockTilePlugin(appURL: stagingBundleURL)
        stripExtendedAttributes(at: stagingBundleURL)
        try signBundle(at: stagingBundleURL, signingIdentity: signingIdentity)
        try verifyBundle(at: stagingBundleURL)
        try replacePreparedBundle(at: stagingDirectoryURL, for: instance)
        refreshLaunchServicesRegistration(at: destinationURL)
        shouldCleanStaging = false

        return destinationURL
    }

    public func bundleDetails(for instance: CodexInstance) -> BundleDetails {
        let destinationURL = bundleURL(for: instance)
        let cloneVersion = versionInfo(for: destinationURL)

        guard fileManager.fileExists(atPath: sourceAppURL.path) else {
            return BundleDetails(
                status: .missingSourceApp,
                cloneShortVersion: cloneVersion.shortVersion,
                cloneBuildVersion: cloneVersion.buildVersion,
                sourceShortVersion: nil,
                sourceBuildVersion: nil
            )
        }

        do {
            try preflightSourceApp()

            let sourceFingerprint = try sourceFingerprint()
            let iconFingerprint = iconFingerprint(for: instance.iconPath)
            let signingIdentity = signingIdentity()
            let status: CodexInstance.BundleStatus = needsRebuild(
                instance: instance,
                destinationURL: destinationURL,
                sourceFingerprint: sourceFingerprint,
                iconFingerprint: iconFingerprint,
                signingIdentity: signingIdentity
            ) ? .needsRebuild : .ready

            return BundleDetails(
                status: status,
                cloneShortVersion: cloneVersion.shortVersion,
                cloneBuildVersion: cloneVersion.buildVersion,
                sourceShortVersion: sourceFingerprint.shortVersion,
                sourceBuildVersion: sourceFingerprint.buildVersion
            )
        } catch {
            return BundleDetails(
                status: .needsRebuild,
                cloneShortVersion: cloneVersion.shortVersion,
                cloneBuildVersion: cloneVersion.buildVersion,
                sourceShortVersion: nil,
                sourceBuildVersion: nil
            )
        }
    }

    public func removeBundle(for instance: CodexInstance) throws {
        try removeItemIfPresent(at: instanceDirectoryURL(for: instance))
        try removeItemIfPresent(at: legacyInstanceDirectoryURL(for: instance))
    }

    public func bundleURL(for instance: CodexInstance) -> URL {
        instanceDirectoryURL(for: instance)
            .appendingPathComponent(instance.managedAppBundleName, isDirectory: true)
    }

    public func rebuildBundle(for instance: CodexInstance) throws -> URL {
        if isRunning(bundleIdentifier: instance.managedBundleIdentifier) {
            throw BundleCloneError.instanceMustQuitBeforeRebuild(instance.managedAppName)
        }

        try removeItemIfPresent(at: instanceDirectoryURL(for: instance))
        return try prepareBundle(for: instance)
    }

    private func needsRebuild(
        instance: CodexInstance,
        destinationURL: URL,
        sourceFingerprint: SourceFingerprint,
        iconFingerprint: String,
        signingIdentity: String
    ) -> Bool {
        guard fileManager.fileExists(atPath: destinationURL.path),
              let info = NSMutableDictionary(contentsOf: infoPlistURL(for: destinationURL))
        else {
            return true
        }

        return info[MetadataKey.schemaVersion] as? String != CloneMetadata.schemaVersion ||
            info[MetadataKey.instanceID] as? String != instance.id.uuidString ||
            info[MetadataKey.sourceBundleIdentifier] as? String != sourceFingerprint.bundleIdentifier ||
            info[MetadataKey.sourceShortVersion] as? String != sourceFingerprint.shortVersion ||
            info[MetadataKey.sourceBuildVersion] as? String != sourceFingerprint.buildVersion ||
            info[MetadataKey.sourceExecutableModifiedAt] as? String != sourceFingerprint.executableModifiedAt ||
            info[MetadataKey.iconFingerprint] as? String != iconFingerprint ||
            info[MetadataKey.signingIdentity] as? String != signingIdentity ||
            info[MetadataKey.managedClone] as? Bool != true ||
            managedLaunchEnvironment(in: info)["CODEX_SPARKLE_ENABLED"] as? String != "false" ||
            info["CFBundleIdentifier"] as? String != instance.managedBundleIdentifier ||
            info["CFBundleDisplayName"] as? String != instance.managedAppName
    }

    private func patchMainInfoPlist(
        for instance: CodexInstance,
        appURL: URL,
        sourceFingerprint: SourceFingerprint,
        iconFingerprint: String,
        signingIdentity: String
    ) throws {
        let infoURL = infoPlistURL(for: appURL)
        guard let info = NSMutableDictionary(contentsOf: infoURL) else {
            throw BundleCloneError.invalidInfoPlist(infoURL.path)
        }

        info["CFBundleIdentifier"] = instance.managedBundleIdentifier
        info["CFBundleName"] = instance.managedAppName
        info["CFBundleDisplayName"] = instance.managedAppName
        info["BundleSigningBaseName"] = instance.managedAppName
        info["CrProductDirName"] = instance.managedBundleIdentifier
        info["SUEnableAutomaticChecks"] = false
        info["SUAllowsAutomaticUpdates"] = false
        info.removeObject(forKey: "SUFeedURL")
        info.removeObject(forKey: "NSDockTilePlugIn")
        let launchEnvironment = managedLaunchEnvironment(in: info)
        launchEnvironment["CODEX_SPARKLE_ENABLED"] = "false"
        info["LSEnvironment"] = launchEnvironment

        if let iconFile = try installIcon(
            from: instance.iconPath,
            iconFingerprint: iconFingerprint,
            into: appURL
        ) {
            info["CFBundleIconFile"] = iconFile
            info["CFBundleIconName"] = URL(fileURLWithPath: iconFile).deletingPathExtension().lastPathComponent
        }

        info[MetadataKey.schemaVersion] = CloneMetadata.schemaVersion
        info[MetadataKey.instanceID] = instance.id.uuidString
        info[MetadataKey.sourceBundleIdentifier] = sourceFingerprint.bundleIdentifier
        info[MetadataKey.sourceShortVersion] = sourceFingerprint.shortVersion
        info[MetadataKey.sourceBuildVersion] = sourceFingerprint.buildVersion
        info[MetadataKey.sourceExecutableModifiedAt] = sourceFingerprint.executableModifiedAt
        info[MetadataKey.iconFingerprint] = iconFingerprint
        info[MetadataKey.signingIdentity] = signingIdentity
        info[MetadataKey.managedClone] = true

        guard info.write(to: infoURL, atomically: true) else {
            throw BundleCloneError.couldNotWriteInfoPlist(infoURL.path)
        }
    }

    private func managedLaunchEnvironment(in info: NSDictionary) -> NSMutableDictionary {
        (info["LSEnvironment"] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary ?? NSMutableDictionary()
    }

    private func patchHelperBundleIdentifiers(appURL: URL, bundleIdentifier: String) throws {
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: contentsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let infoURL as URL in enumerator where infoURL.lastPathComponent == "Info.plist" {
            guard infoURL != infoPlistURL(for: appURL),
                  let info = NSMutableDictionary(contentsOf: infoURL),
                  let existingIdentifier = info["CFBundleIdentifier"] as? String,
                  existingIdentifier.hasPrefix(CloneMetadata.sourceBundleIdentifierPrefix)
            else {
                continue
            }

            let suffix = String(existingIdentifier.dropFirst(CloneMetadata.sourceBundleIdentifierPrefix.count))
            info["CFBundleIdentifier"] = "\(bundleIdentifier)\(suffix)"

            guard info.write(to: infoURL, atomically: true) else {
                throw BundleCloneError.couldNotWriteInfoPlist(infoURL.path)
            }
        }
    }

    private func disableDockTilePlugin(appURL: URL) throws {
        let pluginURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("PlugIns", isDirectory: true)
            .appendingPathComponent("CodexDockTilePlugin.plugin", isDirectory: true)

        try removeItemIfPresent(at: pluginURL)
    }

    private func installIcon(
        from iconPath: String?,
        iconFingerprint: String,
        into appURL: URL
    ) throws -> String? {
        guard let iconPath else { return nil }

        let sourceURL = URL(fileURLWithPath: NSString(string: iconPath).expandingTildeInPath)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }

        let image = try iconImage(at: sourceURL)
        let resourcesURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let iconFileName = "\(IconResource.managedIconPrefix)-\(stableHash(iconFingerprint)).icns"
        let destinationURL = resourcesURL.appendingPathComponent(iconFileName)

        try removeItemIfPresent(at: destinationURL)

        if sourceURL.pathExtension.lowercased() == "icns" {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } else {
            try createICNS(from: image, at: destinationURL)
        }

        try installRuntimeIcons(from: image, icnsURL: destinationURL, resourcesURL: resourcesURL)

        return iconFileName
    }

    private func createICNS(from image: NSImage, at destinationURL: URL) throws {
        let iconsetURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("iconset")

        try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: iconsetURL) }

        let iconEntries = [
            (16, 1), (16, 2),
            (32, 1), (32, 2),
            (128, 1), (128, 2),
            (256, 1), (256, 2),
            (512, 1), (512, 2)
        ]

        for (baseSize, scale) in iconEntries {
            let pixelSize = baseSize * scale
            let suffix = scale == 2 ? "@2x" : ""
            let fileName = "icon_\(baseSize)x\(baseSize)\(suffix).png"
            let pngURL = iconsetURL.appendingPathComponent(fileName)
            let pngData = try pngRepresentation(of: image, pixelSize: pixelSize)
            try pngData.write(to: pngURL, options: .atomic)
        }

        try run("/usr/bin/iconutil", arguments: ["-c", "icns", iconsetURL.path, "-o", destinationURL.path])
    }

    private func installRuntimeIcons(from image: NSImage, icnsURL: URL, resourcesURL: URL) throws {
        for fileName in IconResource.icnsFileNames {
            let destinationURL = resourcesURL.appendingPathComponent(fileName)
            try removeItemIfPresent(at: destinationURL)
            try fileManager.copyItem(at: icnsURL, to: destinationURL)
        }

        let pngData = try pngRepresentation(of: image, pixelSize: 1024)
        for relativePath in IconResource.pngRelativePaths {
            let destinationURL = resourcesURL.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: destinationURL.deletingLastPathComponent().path) else {
                continue
            }
            try pngData.write(to: destinationURL, options: .atomic)
        }
    }

    private func iconImage(at sourceURL: URL) throws -> NSImage {
        if let image = NSImage(contentsOf: sourceURL) {
            return image
        }

        throw BundleCloneError.invalidIcon(sourceURL.path)
    }

    private func pngRepresentation(of image: NSImage, pixelSize: Int) throws -> Data {
        let size = NSSize(width: pixelSize, height: pixelSize)
        let resizedImage = NSImage(size: size)

        resizedImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        resizedImage.unlockFocus()

        guard let tiffData = resizedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            throw BundleCloneError.invalidIcon("Could not render icon")
        }

        return pngData
    }

    private func signBundle(at appURL: URL, signingIdentity: String) throws {
        try removeItemIfPresent(at: appURL.appendingPathComponent("Contents/_CodeSignature", isDirectory: true))
        try run("/usr/bin/codesign", arguments: ["--force", "--deep", "--sign", signingIdentity, appURL.path])
    }

    private func verifyBundle(at appURL: URL) throws {
        try run(
            "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", "--verbose=1", appURL.path]
        )
    }

    private func stripExtendedAttributes(at appURL: URL) {
        try? run("/usr/bin/xattr", arguments: ["-cr", appURL.path])
    }

    private func sourceFingerprint() throws -> SourceFingerprint {
        let infoURL = infoPlistURL(for: sourceAppURL)
        guard let info = NSDictionary(contentsOf: infoURL),
              let executableName = info["CFBundleExecutable"] as? String
        else {
            throw BundleCloneError.invalidInfoPlist(infoURL.path)
        }

        let executableURL = sourceAppURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
        let attributes = try fileManager.attributesOfItem(atPath: executableURL.path)
        let modifiedAt = attributes[.modificationDate] as? Date ?? Date.distantPast

        return SourceFingerprint(
            bundleIdentifier: info["CFBundleIdentifier"] as? String ?? "",
            shortVersion: info["CFBundleShortVersionString"] as? String ?? "",
            buildVersion: info["CFBundleVersion"] as? String ?? "",
            executableModifiedAt: String(Int(modifiedAt.timeIntervalSince1970))
        )
    }

    private func versionInfo(for appURL: URL) -> VersionInfo {
        let infoURL = infoPlistURL(for: appURL)
        guard let info = NSDictionary(contentsOf: infoURL) else {
            return VersionInfo(shortVersion: nil, buildVersion: nil)
        }

        return VersionInfo(
            shortVersion: cleanVersion(info["CFBundleShortVersionString"] as? String),
            buildVersion: cleanVersion(info["CFBundleVersion"] as? String)
        )
    }

    private func cleanVersion(_ version: String?) -> String? {
        let trimmed = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func iconFingerprint(for iconPath: String?) -> String {
        guard let iconPath else { return "" }

        let expandedPath = NSString(string: iconPath).expandingTildeInPath
        let attributes = try? fileManager.attributesOfItem(atPath: expandedPath)
        let modifiedAt = attributes?[.modificationDate] as? Date
        let timestamp = modifiedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "missing"
        return "\(expandedPath)|\(timestamp)"
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func signingIdentity() -> String {
        guard let candidate = signingIdentityCandidate(),
              canUseSigningIdentity(candidate)
        else {
            return "-"
        }

        return candidate
    }

    private func signingIdentityCandidate() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-identity", "-p", "codesigning", "-v"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2,
                  fields[0].hasSuffix(")"),
                  fields[1].count >= 40
            else {
                continue
            }

            return String(fields[1])
        }

        return nil
    }

    private func canUseSigningIdentity(_ identity: String) -> Bool {
        let testURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? removeItemIfPresent(at: testURL) }

        do {
            try fileManager.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: testURL)
            try run("/usr/bin/codesign", arguments: ["--force", "--sign", identity, testURL.path])
            return true
        } catch {
            return false
        }
    }

    private func preflightRootUser() throws {
        guard getuid() != 0 else {
            throw BundleCloneError.runningAsRoot
        }
    }

    private func preflightSourceApp() throws {
        guard fileManager.fileExists(atPath: sourceAppURL.path) else {
            throw BundleCloneError.sourceAppMissing(sourceAppURL.path)
        }

        let infoURL = infoPlistURL(for: sourceAppURL)
        guard fileManager.isReadableFile(atPath: infoURL.path),
              let info = NSDictionary(contentsOf: infoURL),
              let executableName = info["CFBundleExecutable"] as? String
        else {
            throw BundleCloneError.cannotReadSource(infoURL.path)
        }

        let executableURL = sourceAppURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
        guard fileManager.isReadableFile(atPath: executableURL.path) else {
            throw BundleCloneError.cannotReadSource(executableURL.path)
        }
    }

    private func preflightTools(iconPath: String?) throws {
        try requireExecutableTool("/usr/bin/codesign")

        guard let iconPath,
              URL(fileURLWithPath: iconPath).pathExtension.lowercased() != "icns"
        else {
            return
        }

        try requireExecutableTool("/usr/bin/iconutil")
    }

    private func requireExecutableTool(_ path: String) throws {
        guard fileManager.isExecutableFile(atPath: path) else {
            throw BundleCloneError.missingTool(path)
        }
    }

    private func preflightWritableDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            let probeURL = url.appendingPathComponent(".codex-pools-write-probe-\(UUID().uuidString)")
            guard fileManager.createFile(atPath: probeURL.path, contents: Data()) else {
                throw BundleCloneError.cannotWriteDirectory(url.path, "Could not create write probe.")
            }
            try removeItemIfPresent(at: probeURL)
        } catch let error as BundleCloneError {
            throw error
        } catch {
            throw BundleCloneError.cannotWriteDirectory(url.path, error.localizedDescription)
        }
    }

    private func replacePreparedBundle(at stagingDirectoryURL: URL, for instance: CodexInstance) throws {
        let finalDirectoryURL = instanceDirectoryURL(for: instance)
        let backupDirectoryURL = appsRootURL.appendingPathComponent(
            ".backup-\(instance.id.uuidString)-\(UUID().uuidString)",
            isDirectory: true
        )
        var movedExistingBundle = false

        do {
            try removeItemIfPresent(at: backupDirectoryURL)

            if fileManager.fileExists(atPath: finalDirectoryURL.path) {
                try fileManager.moveItem(at: finalDirectoryURL, to: backupDirectoryURL)
                movedExistingBundle = true
            }

            try fileManager.moveItem(at: stagingDirectoryURL, to: finalDirectoryURL)

            if movedExistingBundle {
                try? removeItemIfPresent(at: backupDirectoryURL)
            }
        } catch {
            if movedExistingBundle,
               fileManager.fileExists(atPath: backupDirectoryURL.path),
               !fileManager.fileExists(atPath: finalDirectoryURL.path) {
                try? fileManager.moveItem(at: backupDirectoryURL, to: finalDirectoryURL)
            }

            throw BundleCloneError.replaceFailed(instance.managedAppName, error.localizedDescription)
        }
    }

    private func refreshLaunchServicesRegistration(at appURL: URL) {
        let lsregisterURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: appURL.path)
        try? run(lsregisterURL.path, arguments: ["-u", appURL.path])
        try? run(lsregisterURL.path, arguments: ["-f", appURL.path])
        NSWorkspace.shared.noteFileSystemChanged(appURL.path)
    }

    private func run(_ executablePath: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            throw BundleCloneError.commandFailed(executablePath, output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func isRunning(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == bundleIdentifier
        }
    }

    private func removeItemIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func instanceDirectoryURL(for instance: CodexInstance) -> URL {
        appsRootURL.appendingPathComponent(instance.id.uuidString, isDirectory: true)
    }

    private func legacyInstanceDirectoryURL(for instance: CodexInstance) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Codex Pools")
            .appendingPathComponent("Apps", isDirectory: true)
            .appendingPathComponent(instance.id.uuidString, isDirectory: true)
    }

    private func stagingDirectoryURL(for instance: CodexInstance) -> URL {
        appsRootURL
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent("\(instance.id.uuidString)-\(UUID().uuidString)", isDirectory: true)
    }

    private func infoPlistURL(for appURL: URL) -> URL {
        appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
    }
}

private struct SourceFingerprint {
    let bundleIdentifier: String
    let shortVersion: String
    let buildVersion: String
    let executableModifiedAt: String
}

private struct VersionInfo {
    let shortVersion: String?
    let buildVersion: String?
}

private enum CloneMetadata {
    static let schemaVersion = "5"
    static let sourceBundleIdentifierPrefix = "com.openai.codex"
}

private enum IconResource {
    static let managedIconPrefix = "codex-pools-instance"
    static let icnsFileNames = ["app.icns", "electron.icns", "icon.icns"]
    static let pngRelativePaths = [
        "icon.png",
        "default_app/icon.png",
        "icon-codex-dark.png",
        "icon-codex-light.png"
    ]
}

private enum MetadataKey {
    static let schemaVersion = "CodexPoolsCloneSchemaVersion"
    static let instanceID = "CodexPoolsInstanceID"
    static let sourceBundleIdentifier = "CodexPoolsSourceBundleIdentifier"
    static let sourceShortVersion = "CodexPoolsSourceShortVersion"
    static let sourceBuildVersion = "CodexPoolsSourceBuildVersion"
    static let sourceExecutableModifiedAt = "CodexPoolsSourceExecutableModifiedAt"
    static let iconFingerprint = "CodexPoolsIconFingerprint"
    static let signingIdentity = "CodexPoolsSigningIdentity"
    static let managedClone = "CodexPoolsManagedClone"
}

private enum BundleCloneError: LocalizedError {
    case sourceAppMissing(String)
    case cannotReadSource(String)
    case invalidInfoPlist(String)
    case couldNotWriteInfoPlist(String)
    case invalidIcon(String)
    case missingTool(String)
    case cannotWriteDirectory(String, String)
    case replaceFailed(String, String)
    case commandFailed(String, String)
    case instanceMustQuitBeforeRebuild(String)
    case runningAsRoot

    var errorDescription: String? {
        switch self {
        case .sourceAppMissing(let path):
            return "Codex source app was not found at \(path)."
        case .cannotReadSource(let path):
            return "Codex source app is not readable at \(path)."
        case .invalidInfoPlist(let path):
            return "Could not read Info.plist at \(path)."
        case .couldNotWriteInfoPlist(let path):
            return "Could not write Info.plist at \(path)."
        case .invalidIcon(let path):
            return "Could not convert icon at \(path)."
        case .missingTool(let path):
            return "Required macOS tool is missing or not executable at \(path)."
        case .cannotWriteDirectory(let path, let reason):
            return "Cannot write managed app bundles under \(path). \(reason)"
        case .replaceFailed(let name, let reason):
            return "Could not replace the managed app bundle for \(name). \(reason)"
        case .commandFailed(let command, let output):
            return "\(command) failed. \(output)"
        case .instanceMustQuitBeforeRebuild(let name):
            return "\(name) is running. Quit it before rebuilding its managed app bundle."
        case .runningAsRoot:
            return "Do not run Codex Pools as root. Launch it as your normal macOS user so instances stay under your user profile."
        }
    }
}
