import AppKit
import Foundation
import OSLog

struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let body: String
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case assets
    }

    var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }
}

enum UpdateAvailability {
    case upToDate(GitHubRelease)
    case updateAvailable(GitHubRelease, GitHubReleaseAsset)
}

enum AppUpdateError: LocalizedError {
    case unsupportedCurrentBundle
    case unsupportedArchitecture(String)
    case noMatchingAsset(String)
    case invalidResponse
    case unwritableInstallLocation(URL)
    case expandedAppMissing
    case failedToStartInstaller

    var errorDescription: String? {
        switch self {
        case .unsupportedCurrentBundle:
            return "The current app bundle could not be determined."
        case let .unsupportedArchitecture(architecture):
            return "No update asset is configured for this Mac architecture: \(architecture)."
        case let .noMatchingAsset(target):
            return "No release asset matched \(target)."
        case .invalidResponse:
            return "GitHub returned an unexpected response."
        case let .unwritableInstallLocation(url):
            return "Hyprtile cannot replace itself at \(url.path). Move it to a writable location such as ~/Applications."
        case .expandedAppMissing:
            return "The downloaded update did not contain Hyprtile.app."
        case .failedToStartInstaller:
            return "Hyprtile downloaded the update, but could not start the installer."
        }
    }
}

@MainActor
final class AppUpdateManager {
    private let logger = Logger(subsystem: "io.github.igtm.hyprtile", category: "AppUpdateManager")
    private let decoder = JSONDecoder()

    init() {
        decoder.dateDecodingStrategy = .iso8601
    }

    func checkForUpdates() async throws -> UpdateAvailability {
        let release = try await fetchLatestRelease()
        if compareVersions(release.version, AppMetadata.shortVersion) == .orderedDescending {
            let asset = try matchingAsset(in: release)
            return .updateAvailable(release, asset)
        }
        return .upToDate(release)
    }

    func installUpdate(release: GitHubRelease, asset: GitHubReleaseAsset) async throws {
        let appBundleURL = Bundle.main.bundleURL.standardizedFileURL
        guard appBundleURL.pathExtension == "app" else {
            throw AppUpdateError.unsupportedCurrentBundle
        }

        let installParentURL = appBundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: installParentURL.path) else {
            throw AppUpdateError.unwritableInstallLocation(installParentURL)
        }

        logger.info("Downloading update \(release.tagName, privacy: .public) from \(asset.browserDownloadURL.absoluteString, privacy: .public)")

        let stagingRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Hyprtile-Update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRootURL, withIntermediateDirectories: true)

        let archiveURL = stagingRootURL.appendingPathComponent(asset.name)
        let expandedURL = stagingRootURL.appendingPathComponent("expanded", isDirectory: true)

        let request = updateRequest(for: asset.browserDownloadURL)
        let (downloadedURL, response) = try await URLSession.shared.download(for: request)
        try validateHTTPResponse(response)
        try FileManager.default.moveItem(at: downloadedURL, to: archiveURL)

        try runProcess(executable: "/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, expandedURL.path])

        let replacementAppURL = try resolvedExpandedApp(in: expandedURL)
        let installerScriptURL = try writeInstallerScript(
            stagingRootURL: stagingRootURL,
            replacementAppURL: replacementAppURL,
            targetAppURL: appBundleURL
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [installerScriptURL.path]
        process.standardOutput = nil
        process.standardError = nil

        do {
            try process.run()
        } catch {
            throw AppUpdateError.failedToStartInstaller
        }

        logger.info("Installer started for \(release.tagName, privacy: .public)")
        NSApp.terminate(nil)
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        let request = updateRequest(for: AppMetadata.releasesAPIURL)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response)
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    private func matchingAsset(in release: GitHubRelease) throws -> GitHubReleaseAsset {
        let target = AppMetadata.releaseAssetTarget
        guard target.contains("apple-darwin") else {
            throw AppUpdateError.unsupportedArchitecture(target)
        }

        guard let asset = release.assets.first(where: { $0.name.hasSuffix("_\(target).zip") }) else {
            throw AppUpdateError.noMatchingAsset(target)
        }

        return asset
    }

    private func updateRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Hyprtile/\(AppMetadata.shortVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        return request
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw AppUpdateError.invalidResponse
        }
    }

    private func resolvedExpandedApp(in directoryURL: URL) throws -> URL {
        let directURL = directoryURL.appendingPathComponent("\(AppMetadata.appName).app")
        if FileManager.default.fileExists(atPath: directURL.path) {
            return directURL
        }

        let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.pathExtension == "app" {
                return fileURL
            }
        }

        throw AppUpdateError.expandedAppMissing
    }

    private func writeInstallerScript(
        stagingRootURL: URL,
        replacementAppURL: URL,
        targetAppURL: URL
    ) throws -> URL {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyprtile-updater-\(UUID().uuidString).sh")

        let escapedPID = String(ProcessInfo.processInfo.processIdentifier)
        let escapedTarget = shellEscaped(targetAppURL.path)
        let escapedReplacement = shellEscaped(replacementAppURL.path)
        let escapedStaging = shellEscaped(stagingRootURL.path)
        let escapedScript = shellEscaped(scriptURL.path)

        let script = """
        #!/bin/zsh
        set -euo pipefail
        current_pid=\(escapedPID)
        target_app=\(escapedTarget)
        replacement_app=\(escapedReplacement)
        staging_root=\(escapedStaging)
        script_path=\(escapedScript)

        while kill -0 "$current_pid" 2>/dev/null; do
          sleep 1
        done
        
        rm -rf "${target_app}.new"
        rm -rf "${target_app}.previous"
        /usr/bin/ditto "$replacement_app" "${target_app}.new"
        if [ -d "$target_app" ]; then
          mv "$target_app" "${target_app}.previous"
        fi
        mv "${target_app}.new" "$target_app"
        xattr -dr com.apple.quarantine "$target_app" >/dev/null 2>&1 || true
        rm -rf "${target_app}.previous"
        open "$target_app"
        rm -rf "$staging_root"
        rm -f "$script_path"
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func runProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw AppUpdateError.invalidResponse
        }
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: [.numeric])
    }

    private func shellEscaped(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
