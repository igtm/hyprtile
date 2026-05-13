import AppKit
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    private enum Keys {
        static let isEnabled = "settings.enabled"
        static let mode = "settings.mode"
        static let hasShownPermissionSetup = "settings.hasShownPermissionSetup"
        static let attemptedLaunchAtLogin = "settings.attemptedLaunchAtLogin"
        static let layoutSnapshots = "settings.layoutSnapshots"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var storedLayoutSnapshots: [String: PersistedLayoutNode]

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.isEnabled)
        }
    }

    @Published var mode: AppMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Keys.mode)
        }
    }

    @Published var hasShownPermissionSetup: Bool {
        didSet {
            defaults.set(hasShownPermissionSetup, forKey: Keys.hasShownPermissionSetup)
        }
    }

    @Published var attemptedLaunchAtLogin: Bool {
        didSet {
            defaults.set(attemptedLaunchAtLogin, forKey: Keys.attemptedLaunchAtLogin)
        }
    }

    var layoutSnapshots: [CGDirectDisplayID: PersistedLayoutNode] {
        Dictionary(uniqueKeysWithValues: storedLayoutSnapshots.compactMap { key, value in
            guard let displayID = UInt32(key) else {
                return nil
            }
            return (CGDirectDisplayID(displayID), value)
        })
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.object(forKey: Keys.isEnabled) as? Bool ?? true

        if let rawMode = defaults.string(forKey: Keys.mode), let mode = AppMode(rawValue: rawMode) {
            self.mode = mode
        } else {
            self.mode = .tiling
        }

        self.hasShownPermissionSetup = defaults.bool(forKey: Keys.hasShownPermissionSetup)
        self.attemptedLaunchAtLogin = defaults.bool(forKey: Keys.attemptedLaunchAtLogin)
        if let data = defaults.data(forKey: Keys.layoutSnapshots),
           let snapshots = try? decoder.decode([String: PersistedLayoutNode].self, from: data) {
            self.storedLayoutSnapshots = snapshots
        } else {
            self.storedLayoutSnapshots = [:]
        }
    }

    func persistLayoutSnapshots(_ snapshots: [CGDirectDisplayID: PersistedLayoutNode]) {
        let serialized = Dictionary(uniqueKeysWithValues: snapshots.map { (String($0.key), $0.value) })
        guard serialized != storedLayoutSnapshots else {
            return
        }

        storedLayoutSnapshots = serialized

        if serialized.isEmpty {
            defaults.removeObject(forKey: Keys.layoutSnapshots)
            return
        }

        guard let data = try? encoder.encode(serialized) else {
            return
        }

        defaults.set(data, forKey: Keys.layoutSnapshots)
    }
}
