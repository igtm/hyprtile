import SwiftUI

struct UninstallerView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        switch controller.uninstallPhase {
        case .idle:
            confirmView
        case .running(let step):
            progressView(step: step)
        case .needsAccessibilityCleanup:
            accessibilityView
        }
    }

    private var confirmView: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "trash.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uninstall Hyprtile")
                        .font(.title2.bold())
                    Text("This cannot be undone.")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("The following will be removed:")
                    .font(.callout.bold())
                bulletItem("Hyprtile.app (moved to Trash)")
                bulletItem("Launch at Login registration")
                bulletItem("Preferences and application data")
                bulletItem("Layout snapshots")
            }
            .font(.callout)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                Text("Accessibility permission must be removed manually in **System Settings → Privacy & Security → Accessibility**.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Open Privacy Settings") {
                    controller.openPrivacyAccessibilitySettings()
                }
                .buttonStyle(.link)
                .font(.callout)

                Spacer()

                Button("Cancel") {
                    controller.closeUninstallerWindow()
                }
                .keyboardShortcut(.cancelAction)

                Button("Uninstall") {
                    controller.startUninstall()
                }
                .keyboardShortcut(.defaultAction)
                .foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func progressView(step: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(step)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(width: 460, height: 140)
    }

    private var accessibilityView: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Almost done")
                        .font(.title2.bold())
                    Text("Hyprtile has been moved to Trash.")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("To remove the Accessibility permission:")
                    .font(.callout.bold())
                Text("1. Open System Settings")
                Text("2. Go to Privacy & Security → Accessibility")
                Text("3. Remove Hyprtile from the list")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Open Privacy Settings") {
                    controller.openPrivacyAccessibilitySettings()
                }
                Button("Quit Hyprtile") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func bulletItem(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text)
        }
    }
}
