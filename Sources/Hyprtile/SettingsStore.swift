import AppKit
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    private enum Keys {
        static let runState = "settings.runState"
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

    @Published var runState: AppRunState {
        didSet {
            defaults.set(runState.rawValue, forKey: Keys.runState)
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

    var layoutSnapshots: [LayoutSnapshotKey: PersistedLayoutNode] {
        Dictionary(uniqueKeysWithValues: storedLayoutSnapshots.compactMap { key, value in
            guard let snapshotKey = LayoutSnapshotKey(storageKey: key) else {
                return nil
            }
            return (snapshotKey, value)
        })
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let legacyEnabled = defaults.object(forKey: Keys.isEnabled) as? Bool
        let legacyMode = defaults.string(forKey: Keys.mode)
        let migratedRunState: AppRunState
        let migratedMode: AppMode

        if let rawRunState = defaults.string(forKey: Keys.runState),
           let runState = AppRunState(rawValue: rawRunState) {
            migratedRunState = runState
        } else if legacyMode == "pause" {
            migratedRunState = .paused
        } else if legacyEnabled == false {
            migratedRunState = .paused
        } else {
            migratedRunState = .active
        }

        if let rawMode = legacyMode, let mode = AppMode(rawValue: rawMode) {
            migratedMode = mode
        } else {
            migratedMode = .tiling
        }
        self.runState = migratedRunState
        self.mode = migratedMode

        self.hasShownPermissionSetup = defaults.bool(forKey: Keys.hasShownPermissionSetup)
        self.attemptedLaunchAtLogin = defaults.bool(forKey: Keys.attemptedLaunchAtLogin)
        if let data = defaults.data(forKey: Keys.layoutSnapshots),
           let snapshots = try? decoder.decode([String: PersistedLayoutNode].self, from: data) {
            self.storedLayoutSnapshots = Self.normalizedSnapshotStorage(from: snapshots)
        } else {
            self.storedLayoutSnapshots = [:]
        }

        defaults.set(migratedRunState.rawValue, forKey: Keys.runState)
        if defaults.string(forKey: Keys.mode) == "pause" {
            defaults.set(AppMode.tiling.rawValue, forKey: Keys.mode)
        }
    }

    func persistLayoutSnapshots(_ snapshots: [LayoutSnapshotKey: PersistedLayoutNode]) {
        let serialized = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.storageKey, $0.value) })
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

    private static func normalizedSnapshotStorage(from rawSnapshots: [String: PersistedLayoutNode]) -> [String: PersistedLayoutNode] {
        var normalized: [String: PersistedLayoutNode] = [:]
        normalized.reserveCapacity(rawSnapshots.count)

        for (rawKey, snapshot) in rawSnapshots {
            if let snapshotKey = LayoutSnapshotKey(storageKey: rawKey) {
                normalized[snapshotKey.storageKey] = snapshot
                continue
            }

            guard let displayID = UInt32(rawKey) else {
                continue
            }

            let snapshotKey = LayoutSnapshotKey(
                displayID: CGDirectDisplayID(displayID),
                windowIDs: snapshot.orderedLeafIDs()
            )
            normalized[snapshotKey.storageKey] = snapshot
        }

        return normalized
    }
}
