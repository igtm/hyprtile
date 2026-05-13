import SwiftUI

struct AboutView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(AppMetadata.appName)
                    .font(.system(size: 26, weight: .semibold))

                Text("Version \(controller.appVersionDisplayString)")
                    .foregroundStyle(.secondary)

                Text(controller.appBundleIdentifier)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Built for macOS 15+ as a menu bar tiling utility.")
                Text(controller.updateStatusText)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button(controller.isCheckingForUpdates ? "Checking..." : "Check for Updates...") {
                    controller.checkForUpdates()
                }
                .disabled(controller.isCheckingForUpdates)

                Button("Open Releases") {
                    controller.openReleasesPage()
                }

                Spacer()

                Button("Close") {
                    controller.closeAboutWindow()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}
