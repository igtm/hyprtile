import AppKit
import SwiftUI

@main
struct HyprtileApp: App {
    @StateObject private var controller = AppController.shared

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        AppController.shared.startIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra("Hyprtile", systemImage: controller.statusItemImageName) {
            MenuBarContent(controller: controller)
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Button("About Hyprtile") {
            controller.openAboutWindow()
        }

        Button(controller.isCheckingForUpdates ? "Checking for Updates..." : "Check for Updates...") {
            controller.checkForUpdates()
        }
        .disabled(controller.isCheckingForUpdates)

        Divider()

        Button(controller.pauseButtonTitle) {
            controller.setPaused(!controller.isPaused)
        }

        Text("Layout")
            .font(.caption)
            .foregroundStyle(.secondary)

        ForEach(AppMode.allCases, id: \.rawValue) { mode in
            Button {
                controller.setMode(mode)
            } label: {
                HStack {
                    if controller.mode == mode {
                        Image(systemName: "checkmark")
                    }
                    Text(mode.title)
                }
            }
        }

        Button("Retile Now") {
            controller.retileNow()
        }
        .disabled(!controller.canTile)

        Divider()

        Text(controller.permissionStatusText)
            .font(.caption)
            .foregroundStyle(controller.permissionState.accessibilityGranted ? .secondary : .primary)

        if !controller.permissionState.accessibilityGranted {
            Button("Request Accessibility") {
                controller.requestMissingPermissions()
            }
        }

        Divider()

        Text("\(controller.managedWindowCount) managed windows")
            .font(.caption)
            .foregroundStyle(.secondary)

        Text("State: \(controller.runState.title)")
            .font(.caption)
            .foregroundStyle(.secondary)

        Text("Launch at Login: \(controller.launchAtLoginStatusText)")
            .font(.caption)
            .foregroundStyle(.secondary)

        Divider()

        Button("Preferences") {
            controller.openSettings()
        }

        Divider()

        Button("Uninstall Hyprtile...") {
            controller.openUninstaller()
        }

        Button("Quit") {
            controller.quit()
        }
    }
}
