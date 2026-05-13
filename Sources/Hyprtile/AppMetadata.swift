import Darwin
import Foundation

enum AppMetadata {
    static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? "Hyprtile"

    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "io.github.igtm.hyprtile"

    static let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "0.0.0"

    static let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        ?? shortVersion

    static let repository = "igtm/hyprtile"
    static let releasesAPIURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let releasesPageURL = URL(string: "https://github.com/\(repository)/releases/latest")!

    static let releaseAssetTarget: String = {
        #if arch(arm64)
        return "aarch64-apple-darwin"
        #elseif arch(x86_64)
        return "x86_64-apple-darwin"
        #else
        return "\(ProcessInfo.processInfo.machineHardwareName)-apple-darwin"
        #endif
    }()

    static var versionDisplayString: String {
        shortVersion == bundleVersion ? shortVersion : "\(shortVersion) (\(bundleVersion))"
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
