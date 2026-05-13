import AppKit
import ApplicationServices

@MainActor
final class PermissionMonitor: ObservableObject {
    @Published private(set) var state: PermissionState

    private var timer: Timer?

    init() {
        state = Self.readState()
    }

    func start() {
        refresh()
        guard timer == nil else {
            return
        }

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        state = Self.readState()
    }

    func requestMissingPermissions() {
        if !state.accessibilityGranted {
            requestAccessibilityPermission()
        }
        refresh()
    }

    func requestAccessibilityPermission() {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    func requestInputMonitoringPermission() {
        _ = CGRequestListenEventAccess()
        refresh()
    }

    func openAccessibilitySettings() {
        openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private func openSystemSettingsPane(_ rawURL: String) {
        guard let url = URL(string: rawURL) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func readState() -> PermissionState {
        let trusted = AXIsProcessTrusted()
        let probeSucceeded = canProbeAccessibility()

        return PermissionState(
            accessibilityGranted: trusted || probeSucceeded,
            inputMonitoringGranted: true
        )
    }

    private static func canProbeAccessibility() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value)

        switch error {
        case .success:
            return value != nil
        case .noValue:
            return true
        case .apiDisabled:
            return false
        default:
            return false
        }
    }
}
