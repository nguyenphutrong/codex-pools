import AppKit
import Foundation

struct BundleCloneService {
    private let sourceAppURL = URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true)
    private let fileManager: FileManager
    private let appsRootURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let home = fileManager.homeDirectoryForCurrentUser
        self.appsRootURL = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Codex Instance Manager")
            .appendingPathComponent("Apps", isDirectory: true)
    }

    func prepareBundle(for instance: CodexInstance) throws -> URL {
        guard fileManager.fileExists(atPath: sourceAppURL.path) else {
            throw BundleCloneError.sourceAppMissing(sourceAppURL.path)
        }

        let sourceFingerprint = try sourceFingerprint()
        let destinationURL = bundleURL(for: instance)

        guard needsRebuild(
            instance: instance,
            destinationURL: destinationURL,
            sourceFingerprint: sourceFingerprint
        ) else {
            return destinationURL
        }

        if isRunning(bundleIdentifier: instance.managedBundleIdentifier) {
            throw BundleCloneError.instanceMustQuitBeforeRebuild(instance.managedAppName)
        }

        let instanceDirectoryURL = instanceDirectoryURL(for: instance)
        try removeItemIfPresent(at: instanceDirectoryURL)
        try fileManager.createDirectory(
            at: instanceDirectoryURL,
            withIntermediateDirectories: true
        )

        try fileManager.copyItem(at: sourceAppURL, to: destinationURL)
        try patchMainInfoPlist(
            for: instance,
            appURL: destinationURL,
            sourceFingerprint: sourceFingerprint
        )
        try patchHelperBundleIdentifiers(appURL: destinationURL, bundleIdentifier: instance.managedBundleIdentifier)
        try signBundle(at: destinationURL)

        return destinationURL
    }

    func removeBundle(for instance: CodexInstance) throws {
        try removeItemIfPresent(at: instanceDirectoryURL(for: instance))
    }

    func bundleURL(for instance: CodexInstance) -> URL {
        instanceDirectoryURL(for: instance)
            .appendingPathComponent(instance.managedAppBundleName, isDirectory: true)
    }

    private func needsRebuild(
        instance: CodexInstance,
        destinationURL: URL,
        sourceFingerprint: SourceFingerprint
    ) -> Bool {
        guard fileManager.fileExists(atPath: destinationURL.path),
              let info = NSMutableDictionary(contentsOf: infoPlistURL(for: destinationURL))
        else {
            return true
        }

        return info[MetadataKey.schemaVersion] as? String != "1" ||
            info[MetadataKey.instanceID] as? String != instance.id.uuidString ||
            info[MetadataKey.sourceBundleIdentifier] as? String != sourceFingerprint.bundleIdentifier ||
            info[MetadataKey.sourceShortVersion] as? String != sourceFingerprint.shortVersion ||
            info[MetadataKey.sourceBuildVersion] as? String != sourceFingerprint.buildVersion ||
            info[MetadataKey.sourceExecutableModifiedAt] as? String != sourceFingerprint.executableModifiedAt ||
            info[MetadataKey.iconFingerprint] as? String != iconFingerprint(for: instance.iconPath) ||
            info["CFBundleIdentifier"] as? String != instance.managedBundleIdentifier ||
            info["CFBundleDisplayName"] as? String != instance.managedAppName
    }

    private func patchMainInfoPlist(
        for instance: CodexInstance,
        appURL: URL,
        sourceFingerprint: SourceFingerprint
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

        if let iconFile = try installIcon(from: instance.iconPath, into: appURL) {
            info["CFBundleIconFile"] = iconFile
            info["CFBundleIconName"] = URL(fileURLWithPath: iconFile).deletingPathExtension().lastPathComponent
        }

        info[MetadataKey.schemaVersion] = "1"
        info[MetadataKey.instanceID] = instance.id.uuidString
        info[MetadataKey.sourceBundleIdentifier] = sourceFingerprint.bundleIdentifier
        info[MetadataKey.sourceShortVersion] = sourceFingerprint.shortVersion
        info[MetadataKey.sourceBuildVersion] = sourceFingerprint.buildVersion
        info[MetadataKey.sourceExecutableModifiedAt] = sourceFingerprint.executableModifiedAt
        info[MetadataKey.iconFingerprint] = iconFingerprint(for: instance.iconPath)

        guard info.write(to: infoURL, atomically: true) else {
            throw BundleCloneError.couldNotWriteInfoPlist(infoURL.path)
        }
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
                  existingIdentifier.hasPrefix("com.openai.codex")
            else {
                continue
            }

            let suffix = String(existingIdentifier.dropFirst("com.openai.codex".count))
            info["CFBundleIdentifier"] = "\(bundleIdentifier)\(suffix)"

            guard info.write(to: infoURL, atomically: true) else {
                throw BundleCloneError.couldNotWriteInfoPlist(infoURL.path)
            }
        }
    }

    private func installIcon(from iconPath: String?, into appURL: URL) throws -> String? {
        guard let iconPath else { return nil }

        let sourceURL = URL(fileURLWithPath: NSString(string: iconPath).expandingTildeInPath)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }

        let iconFileName = "codex-manager-instance.icns"
        let destinationURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(iconFileName)

        try removeItemIfPresent(at: destinationURL)

        if sourceURL.pathExtension.lowercased() == "icns" {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } else {
            try createICNS(from: sourceURL, at: destinationURL)
        }

        return iconFileName
    }

    private func createICNS(from sourceURL: URL, at destinationURL: URL) throws {
        guard let image = NSImage(contentsOf: sourceURL) else {
            throw BundleCloneError.invalidIcon(sourceURL.path)
        }

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

    private func signBundle(at appURL: URL) throws {
        try removeItemIfPresent(at: appURL.appendingPathComponent("Contents/_CodeSignature", isDirectory: true))
        try run("/usr/bin/codesign", arguments: ["--force", "--deep", "--sign", "-", appURL.path])
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

    private func iconFingerprint(for iconPath: String?) -> String {
        guard let iconPath else { return "" }

        let expandedPath = NSString(string: iconPath).expandingTildeInPath
        let attributes = try? fileManager.attributesOfItem(atPath: expandedPath)
        let modifiedAt = attributes?[.modificationDate] as? Date
        let timestamp = modifiedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "missing"
        return "\(expandedPath)|\(timestamp)"
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

private enum MetadataKey {
    static let schemaVersion = "CodexManagerCloneSchemaVersion"
    static let instanceID = "CodexManagerInstanceID"
    static let sourceBundleIdentifier = "CodexManagerSourceBundleIdentifier"
    static let sourceShortVersion = "CodexManagerSourceShortVersion"
    static let sourceBuildVersion = "CodexManagerSourceBuildVersion"
    static let sourceExecutableModifiedAt = "CodexManagerSourceExecutableModifiedAt"
    static let iconFingerprint = "CodexManagerIconFingerprint"
}

private enum BundleCloneError: LocalizedError {
    case sourceAppMissing(String)
    case invalidInfoPlist(String)
    case couldNotWriteInfoPlist(String)
    case invalidIcon(String)
    case commandFailed(String, String)
    case instanceMustQuitBeforeRebuild(String)

    var errorDescription: String? {
        switch self {
        case .sourceAppMissing(let path):
            return "Codex source app was not found at \(path)."
        case .invalidInfoPlist(let path):
            return "Could not read Info.plist at \(path)."
        case .couldNotWriteInfoPlist(let path):
            return "Could not write Info.plist at \(path)."
        case .invalidIcon(let path):
            return "Could not convert icon at \(path)."
        case .commandFailed(let command, let output):
            return "\(command) failed. \(output)"
        case .instanceMustQuitBeforeRebuild(let name):
            return "\(name) is running. Quit it before rebuilding its managed app bundle."
        }
    }
}
