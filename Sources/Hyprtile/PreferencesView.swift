import SwiftUI

struct PreferencesView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Managed windows", value: "\(controller.managedWindowCount)")
                LabeledContent("State", value: controller.runState.title)
                LabeledContent("Layout", value: controller.mode.title)
                LabeledContent("Launch at Login", value: controller.launchAtLoginStatusText)
                LabeledContent("Version", value: controller.appVersionDisplayString)
                LabeledContent("Updates", value: controller.updateStatusText)
            }

            Section("Permissions") {
                PermissionRow(
                    title: "Accessibility",
                    isGranted: controller.permissionState.accessibilityGranted,
                    actionTitle: "Open Accessibility Settings",
                    action: controller.permissionMonitor.openAccessibilitySettings
                )

                Text("Middle-button drag uses global mouse monitoring in this build, so no separate Input Monitoring grant is required.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button("Request Accessibility Permission") {
                    controller.requestMissingPermissions()
                }
            }

            Section("Behavior") {
                Button(controller.pauseButtonTitle) {
                    controller.setPaused(!controller.isPaused)
                }

                ModeButtons(controller: controller)
                    .disabled(!controller.canTile)
            }

            Section("Actions") {
                Button("About Hyprtile") {
                    controller.openAboutWindow()
                }

                Button(controller.isCheckingForUpdates ? "Checking for Updates..." : "Check for Updates...") {
                    controller.checkForUpdates()
                }
                .disabled(controller.isCheckingForUpdates)

                Button("Retile Now") {
                    controller.retileNow()
                }
                .disabled(!controller.canTile)

                Button("Quit Hyprtile") {
                    controller.quit()
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 500)
    }
}

private struct ModeButtons: View {
    @ObservedObject var controller: AppController

    var body: some View {
        HStack {
            ForEach(AppMode.allCases, id: \.rawValue) { mode in
                Button(mode.title) {
                    controller.setMode(mode)
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.mode == mode ? .accentColor : .gray.opacity(0.5))
            }
        }
        .accessibilityLabel("Layout mode")
    }
}

private struct PermissionRow: View {
    let title: String
    let isGranted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack {
            Label(
                title,
                systemImage: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .foregroundStyle(isGranted ? .green : .red)

            Spacer()

            Button(actionTitle, action: action)
        }
    }
}
