import AppKit
import ApplicationServices
import Combine
import OSLog
import ServiceManagement
import SwiftUI

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()
    private let logger = Logger(subsystem: "io.github.igtm.hyprtile", category: "AppController")

    @Published private(set) var permissionState: PermissionState
    @Published private(set) var managedWindowCount = 0
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var updateStatusText = "Update status: not checked yet."
    @Published private(set) var uninstallPhase: UninstallPhase = .idle

    let settingsStore: SettingsStore
    let permissionMonitor: PermissionMonitor

    private let windowController = WindowController()
    private let layoutEngine = LayoutEngine()
    private let inputRouter = InputRouter()
    private let updateManager = AppUpdateManager()

    private var didStart = false
    private var refreshWorkItem: DispatchWorkItem?
    private var visibleWindowsByID: [WindowID: ManagedWindow] = [:]
    private var expectedFramesByID: [WindowID: CGRect] = [:]
    private var lastAppliedAt = Date.distantPast
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var applicationObservers: [pid_t: AXObserver] = [:]
    private var externalChangeTimer: Timer?
    private var settingsWindowController: NSWindowController?
    private var aboutWindowController: NSWindowController?
    private var uninstallerWindowController: NSWindowController?

    private var activeMove: MoveOperation?
    private var activeResize: ResizeOperation?
    private var externalMove: ExternalMoveOperation?

    var runState: AppRunState {
        settingsStore.runState
    }

    var isPaused: Bool {
        runState == .paused
    }

    var mode: AppMode {
        settingsStore.mode
    }

    var canTile: Bool {
        permissionState.accessibilityGranted
    }

    var statusItemImageName: String {
        guard permissionState.accessibilityGranted else {
            return "exclamationmark.triangle"
        }

        guard !isPaused else {
            return "pause.circle"
        }

        switch mode {
        case .tiling:
            return "rectangle.split.3x1"
        case .monocle:
            return "square.on.square"
        }
    }

    var permissionStatusText: String {
        switch permissionState.accessibilityGranted {
        case true:
            return isPaused
                ? "Accessibility granted. Hyprtile is paused."
                : "Accessibility granted. Hyprtile is active."
        case false:
            return "Accessibility permission required"
        }
    }

    var launchAtLoginStatusText: String {
        launchAtLoginEnabled ? "Enabled" : "Not active"
    }

    var appVersionDisplayString: String {
        AppMetadata.versionDisplayString
    }

    var appBundleIdentifier: String {
        AppMetadata.bundleIdentifier
    }

    var pauseButtonTitle: String {
        runState.actionTitle
    }

    private var isInteracting: Bool {
        activeMove != nil || activeResize != nil || externalMove != nil
    }

    private init() {
        let settingsStore = SettingsStore()
        let permissionMonitor = PermissionMonitor()

        self.settingsStore = settingsStore
        self.permissionMonitor = permissionMonitor
        permissionState = permissionMonitor.state

        inputRouter.delegate = self

        settingsStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        permissionMonitor.$state
            .sink { [weak self] newState in
                guard let self else {
                    return
                }

                let previousState = permissionState
                permissionState = newState
                logger.info(
                    "Permission update accessibility=\(newState.accessibilityGranted, privacy: .public) inputMonitoring=\(newState.inputMonitoringGranted, privacy: .public)"
                )

                if newState.accessibilityGranted, !isPaused {
                    inputRouter.install()
                } else {
                    inputRouter.uninstall()
                }

                if newState.accessibilityGranted {
                    if !settingsStore.hasShownPermissionSetup {
                        settingsStore.hasShownPermissionSetup = true
                    }

                    if didStart,
                       previousState.accessibilityGranted != newState.accessibilityGranted {
                        scheduleRefresh(reason: "permission update", immediate: true)
                    }
                } else {
                    if didStart {
                        visibleWindowsByID = [:]
                        managedWindowCount = 0
                        clearApplicationObservers()
                    }
                }
            }
            .store(in: &cancellables)
    }

    func startIfNeeded() {
        guard !didStart else {
            return
        }

        didStart = true
        logger.info("Starting Hyprtile")
        permissionMonitor.start()
        startExternalChangeMonitor()
        registerWorkspaceObservers()
        registerLaunchAtLogin()
        scheduleRefresh(reason: "startup", immediate: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            Task { @MainActor in
                self?.presentOnboardingIfNeeded()
            }
        }
    }

    func setPaused(_ paused: Bool) {
        settingsStore.runState = paused ? .paused : .active
        logger.info("Set paused=\(paused, privacy: .public)")

        if paused {
            inputRouter.uninstall()
        } else if permissionState.accessibilityGranted {
            inputRouter.install()
        }

        scheduleRefresh(reason: paused ? "pause" : "resume", immediate: true)
    }

    func setMode(_ mode: AppMode) {
        settingsStore.mode = mode
        logger.info("Set mode=\(mode.rawValue, privacy: .public)")
        scheduleRefresh(reason: "mode change", immediate: true)
    }

    func requestMissingPermissions() {
        permissionMonitor.requestMissingPermissions()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            Task { @MainActor in
                self?.scheduleRefresh(reason: "permissions request", immediate: true)
            }
        }
    }

    func openSettings() {
        let settingsWindowController = configuredSettingsWindowController()
        guard let window = settingsWindowController.window else {
            return
        }

        logger.info("Opening preferences window")
        DispatchQueue.main.async {
            if let hostingController = window.contentViewController as? NSHostingController<PreferencesView> {
                hostingController.rootView = PreferencesView(controller: self)
            }

            if window.isMiniaturized {
                window.deminiaturize(nil)
            }

            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeMain()
            window.makeKey()
        }
    }

    func openAboutWindow() {
        let aboutWindowController = configuredAboutWindowController()
        guard let window = aboutWindowController.window else {
            return
        }

        logger.info("Opening about window")
        DispatchQueue.main.async {
            if let hostingController = window.contentViewController as? NSHostingController<AboutView> {
                hostingController.rootView = AboutView(controller: self)
            }

            if window.isMiniaturized {
                window.deminiaturize(nil)
            }

            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeMain()
            window.makeKey()
        }
    }

    func closeAboutWindow() {
        aboutWindowController?.close()
    }

    func checkForUpdates() {
        guard !isCheckingForUpdates else {
            return
        }

        isCheckingForUpdates = true
        updateStatusText = "Update status: checking GitHub Releases..."

        Task { @MainActor in
            do {
                let availability = try await updateManager.checkForUpdates()
                isCheckingForUpdates = false

                switch availability {
                case let .upToDate(release):
                    updateStatusText = "Update status: \(AppMetadata.shortVersion) is current."
                    presentInformationalAlert(
                        title: "Hyprtile Is Up to Date",
                        message: "Installed version \(AppMetadata.versionDisplayString) matches the latest release \(release.tagName)."
                    )
                case let .updateAvailable(release, asset):
                    updateStatusText = "Update status: \(release.tagName) is available."
                    presentUpdateAlert(release: release, asset: asset)
                }
            } catch {
                isCheckingForUpdates = false
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                updateStatusText = "Update status: check failed."
                presentInformationalAlert(
                    title: "Update Check Failed",
                    message: message
                )
            }
        }
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(AppMetadata.releasesPageURL)
    }

    func retileNow() {
        scheduleRefresh(
            reason: "manual retile",
            immediate: true,
            rebuildTree: true,
            manualMode: mode
        )
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func openUninstaller() {
        uninstallPhase = .idle
        let wc = configuredUninstallerWindowController()
        guard let window = wc.window else { return }

        logger.info("Opening uninstaller window")
        DispatchQueue.main.async {
            if let hc = window.contentViewController as? NSHostingController<UninstallerView> {
                hc.rootView = UninstallerView(controller: self)
            }
            if window.isMiniaturized { window.deminiaturize(nil) }
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeMain()
            window.makeKey()
        }
    }

    func closeUninstallerWindow() {
        uninstallerWindowController?.close()
    }

    func openPrivacyAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func startUninstall() {
        Task { @MainActor in
            let fm = FileManager.default
            let bundleID = AppMetadata.bundleIdentifier

            uninstallPhase = .running(step: "Unregistering Launch at Login…")
            try? await SMAppService.mainApp.unregister()
            try? await Task.sleep(nanoseconds: 200_000_000)

            uninstallPhase = .running(step: "Removing preferences…")
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            UserDefaults.standard.synchronize()
            try? await Task.sleep(nanoseconds: 200_000_000)

            uninstallPhase = .running(step: "Removing application data…")
            if let libraryURL = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
                let candidates = [
                    libraryURL.appendingPathComponent("Application Support/\(bundleID)"),
                    libraryURL.appendingPathComponent("Caches/\(bundleID)"),
                    libraryURL.appendingPathComponent("Preferences/\(bundleID).plist"),
                ]
                candidates.forEach { try? fm.removeItem(at: $0) }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)

            uninstallPhase = .running(step: "Moving Hyprtile to Trash…")
            let appURL = Bundle.main.bundleURL
            if appURL.pathExtension == "app" {
                try? fm.trashItem(at: appURL, resultingItemURL: nil)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)

            uninstallPhase = .needsAccessibilityCleanup
        }
    }

    private func presentOnboardingIfNeeded() {
        guard !permissionState.isReady, !settingsStore.hasShownPermissionSetup else {
            return
        }

        settingsStore.hasShownPermissionSetup = true
        permissionMonitor.requestMissingPermissions()
        openSettings()
    }

    private func registerLaunchAtLogin() {
        guard !settingsStore.attemptedLaunchAtLogin else {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            return
        }

        do {
            try SMAppService.mainApp.register()
        } catch {
            // Best effort only when running from a packaged app bundle.
        }

        settingsStore.attemptedLaunchAtLogin = true
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    private func configuredSettingsWindowController() -> NSWindowController {
        if let settingsWindowController {
            return settingsWindowController
        }

        let hostingController = NSHostingController(rootView: PreferencesView(controller: self))
        let settingsWindow = NSWindow(contentViewController: hostingController)
        settingsWindow.title = "Hyprtile Preferences"
        settingsWindow.styleMask = [.titled, .closable, .miniaturizable]
        settingsWindow.setContentSize(NSSize(width: 520, height: 420))
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.hidesOnDeactivate = false
        settingsWindow.isExcludedFromWindowsMenu = false
        settingsWindow.tabbingMode = .disallowed
        settingsWindow.center()
        settingsWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let settingsWindowController = NSWindowController(window: settingsWindow)
        self.settingsWindowController = settingsWindowController
        return settingsWindowController
    }

    private func configuredUninstallerWindowController() -> NSWindowController {
        if let uninstallerWindowController { return uninstallerWindowController }

        let hostingController = NSHostingController(rootView: UninstallerView(controller: self))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Uninstall Hyprtile"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = false
        window.tabbingMode = .disallowed
        window.center()
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let wc = NSWindowController(window: window)
        self.uninstallerWindowController = wc
        return wc
    }

    private func configuredAboutWindowController() -> NSWindowController {
        if let aboutWindowController {
            return aboutWindowController
        }

        let hostingController = NSHostingController(rootView: AboutView(controller: self))
        let aboutWindow = NSWindow(contentViewController: hostingController)
        aboutWindow.title = "About \(AppMetadata.appName)"
        aboutWindow.styleMask = [.titled, .closable, .miniaturizable]
        aboutWindow.setContentSize(NSSize(width: 420, height: 240))
        aboutWindow.isReleasedWhenClosed = false
        aboutWindow.hidesOnDeactivate = false
        aboutWindow.isExcludedFromWindowsMenu = false
        aboutWindow.tabbingMode = .disallowed
        aboutWindow.center()
        aboutWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let aboutWindowController = NSWindowController(window: aboutWindow)
        self.aboutWindowController = aboutWindowController
        return aboutWindowController
    }

    private func presentUpdateAlert(release: GitHubRelease, asset: GitHubReleaseAsset) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Update Available"
        alert.informativeText = """
        \(release.tagName) is available for this Mac.

        Hyprtile will download \(asset.name), replace the current app, and relaunch itself.

        Until Hyprtile is signed with a stable Developer ID certificate, macOS may ask you to re-enable Accessibility after an update.
        """
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Open Release Page")

        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            installUpdate(release: release, asset: asset)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(release.htmlURL)
        default:
            return
        }
    }

    private func installUpdate(release: GitHubRelease, asset: GitHubReleaseAsset) {
        guard !isCheckingForUpdates else {
            return
        }

        isCheckingForUpdates = true
        updateStatusText = "Update status: downloading \(release.tagName)..."

        Task { @MainActor in
            do {
                try await updateManager.installUpdate(release: release, asset: asset)
            } catch {
                isCheckingForUpdates = false
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                updateStatusText = "Update status: install failed."
                presentInformationalAlert(
                    title: "Update Install Failed",
                    message: message
                )
            }
        }
    }

    private func presentInformationalAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func registerWorkspaceObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default

        workspaceObserverTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRefresh(reason: "app launch")
                }
            }
        )

        workspaceObserverTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRefresh(reason: "app terminate")
                }
            }
        )

        workspaceObserverTokens.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRefresh(reason: "app activate")
                }
            }
        )

        workspaceObserverTokens.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleRefresh(reason: "screen change", immediate: true)
                }
            }
        )
    }

    private func scheduleRefresh(
        reason: String,
        immediate: Bool = false,
        rebuildTree: Bool = true,
        manualMode: AppMode? = nil
    ) {
        guard didStart else {
            return
        }

        guard !isInteracting || immediate else {
            return
        }

        refreshWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refreshNow(reason: reason, rebuildTree: rebuildTree, manualMode: manualMode)
            }
        }

        refreshWorkItem = workItem

        if immediate {
            DispatchQueue.main.async(execute: workItem)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
        }
    }

    private func refreshNow(
        reason: String,
        rebuildTree: Bool,
        manualMode: AppMode?
    ) {
        guard didStart else {
            return
        }

        // Guard against stale delayed refreshes that were queued before a drag started.
        // manualMode (Retile Now) is always allowed through.
        guard !isInteracting || manualMode != nil else {
            logger.debug("Skipping stale refresh during interaction reason=\(reason, privacy: .public)")
            return
        }

        _ = reason
        logger.debug(
            "Refreshing reason=\(reason, privacy: .public) rebuildTree=\(rebuildTree, privacy: .public) mode=\((manualMode ?? mode).rawValue, privacy: .public)"
        )

        guard permissionState.accessibilityGranted else {
            visibleWindowsByID = [:]
            expectedFramesByID = [:]
            managedWindowCount = 0
            clearApplicationObservers()
            inputRouter.uninstall()
            logger.notice("Skipping refresh because Accessibility is not granted")
            return
        }

        let displays = windowController.displays()
        let windows = deduplicatedWindows(windowController.enumerateManagedWindows(), context: "refresh")
        let windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })

        managedWindowCount = windows.count
        visibleWindowsByID = windowsByID
        logger.info("Enumerated managed windows count=\(windows.count, privacy: .public)")

        if manualMode == nil,
           let operation = automaticExternalMoveOperation(from: windows) {
            externalMove = operation
            handleExternalMove(operation, liveWindows: windows, liveWindowsByID: windowsByID)
            return
        }

        if manualMode == nil,
           shouldDeferAutomaticRefreshWhileDragging(liveWindows: windows) {
            return
        }

        refreshApplicationObservers(for: Set(windows.map(\.applicationPID)))

        if rebuildTree {
            layoutEngine.rebuildSessions(
                with: windows,
                displays: displays,
                persistedSnapshots: settingsStore.layoutSnapshots
            )
        }

        persistLayoutSnapshots()

        guard !isPaused || manualMode != nil else {
            inputRouter.uninstall()
            logger.debug("Skipping apply because Hyprtile is paused")
            return
        }

        if permissionState.accessibilityGranted, !isPaused {
            inputRouter.install()
        } else {
            inputRouter.uninstall()
        }

        let effectiveMode = manualMode ?? mode
        switch effectiveMode {
        case .tiling:
            applyFrames(layoutEngine.frames(for: .tiling, displays: displays, windowsByID: windowsByID), windowsByID: windowsByID, mode: .tiling)
        case .monocle:
            applyFrames(layoutEngine.frames(for: .monocle, displays: displays, windowsByID: windowsByID), windowsByID: windowsByID, mode: .monocle)
        }
    }

    private func applyFrames(
        _ frames: [WindowID: CGRect],
        windowsByID: [WindowID: ManagedWindow],
        mode: AppMode,
        animated: Bool = true
    ) {
        logger.info("Applying frames count=\(frames.count, privacy: .public) mode=\(mode.rawValue, privacy: .public)")
        var updatedWindowsByID = windowsByID
        expectedFramesByID = frames
        lastAppliedAt = Date()

        for (windowID, frame) in frames {
            guard var window = updatedWindowsByID[windowID] else {
                continue
            }

            // Call setFrame before updating window.frame so the animation starts
            // from the window's actual current position, not the target.
            windowController.setFrame(frame, for: window, animated: animated)
            window.frame = frame
            updatedWindowsByID[windowID] = window
        }

        visibleWindowsByID = updatedWindowsByID

        guard mode == .monocle else {
            return
        }

        for windowID in layoutEngine.focusedWindowIDs() {
            guard let window = windowsByID[windowID] else {
                continue
            }
            windowController.focus(window)
        }
    }

    private func refreshApplicationObservers(for pids: Set<pid_t>) {
        let knownPIDs = Set(applicationObservers.keys)

        for pid in knownPIDs.subtracting(pids) {
            removeObserver(for: pid)
        }

        for pid in pids.subtracting(knownPIDs) {
            installObserver(for: pid)
        }
    }

    private func installObserver(for pid: pid_t) {
        var observer: AXObserver?
        let result = AXObserverCreate(pid, applicationObserverCallback, &observer)
        guard result == .success, let observer else {
            logger.debug("Failed to create AXObserver for pid=\(pid, privacy: .public) result=\(result.rawValue, privacy: .public)")
            return
        }

        let applicationElement = AXUIElementCreateApplication(pid)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let notifications: [CFString] = [
            kAXWindowCreatedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString,
            kAXMainWindowChangedNotification as CFString,
        ]

        var didRegisterAnyNotification = false

        for notification in notifications {
            let error = AXObserverAddNotification(observer, applicationElement, notification, userInfo)
            if error == .success {
                didRegisterAnyNotification = true
            }
        }

        guard didRegisterAnyNotification else {
            logger.debug("No AX notifications registered for pid=\(pid, privacy: .public)")
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        applicationObservers[pid] = observer
        logger.debug("Installed AXObserver for pid=\(pid, privacy: .public)")
    }

    private func removeObserver(for pid: pid_t) {
        guard let observer = applicationObservers.removeValue(forKey: pid) else {
            return
        }

        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func clearApplicationObservers() {
        applicationObservers.keys.forEach(removeObserver(for:))
    }

    private func startExternalChangeMonitor() {
        guard externalChangeTimer == nil else {
            return
        }

        externalChangeTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reconcileExternalWindowChanges()
            }
        }
    }

    private func reconcileExternalWindowChanges() {
        guard didStart,
              permissionState.accessibilityGranted,
              !isPaused,
              mode == .tiling,
              !visibleWindowsByID.isEmpty else {
            return
        }

        let liveWindows = deduplicatedWindows(windowController.enumerateManagedWindows(), context: "reconcile")
        let liveWindowsByID = Dictionary(uniqueKeysWithValues: liveWindows.map { ($0.id, $0) })

        guard !liveWindowsByID.isEmpty else {
            return
        }

        guard !windowController.isAnimatingFrames || externalMove != nil else {
            return
        }

        if let externalMove {
            handleExternalMove(externalMove, liveWindows: liveWindows, liveWindowsByID: liveWindowsByID)
            return
        }

        guard activeMove == nil, activeResize == nil else {
            return
        }

        if isPrimaryMouseButtonDown {
            if let operation = automaticExternalMoveOperation(from: liveWindows) {
                externalMove = operation
                handleExternalMove(operation, liveWindows: liveWindows, liveWindowsByID: liveWindowsByID)
            }
            return
        }

        let autoDragActive = isPrimaryMouseButtonDown
        let refreshCooldown: TimeInterval = autoDragActive ? 0.05 : 0.15
        guard Date().timeIntervalSince(lastAppliedAt) > refreshCooldown else {
            return
        }

        let knownIDs = Set(visibleWindowsByID.keys)
        let liveIDs = Set(liveWindowsByID.keys)
        guard knownIDs == liveIDs else {
            scheduleRefresh(reason: "window set drift", immediate: true, rebuildTree: true)
            return
        }

        if liveWindows.contains(where: { liveWindowsByID[$0.id]?.displayID != visibleWindowsByID[$0.id]?.displayID }) {
            scheduleRefresh(reason: "window display drift", immediate: true, rebuildTree: true)
            return
        }

        let externalMoveDelay: TimeInterval = autoDragActive ? 0.05 : 0.5
        let canStartExternalMove = Date().timeIntervalSince(lastAppliedAt) > externalMoveDelay
        let movedWindows = canStartExternalMove ? liveWindows.filter { window in
            guard let expectedFrame = expectedFramesByID[window.id] else {
                return false
            }

            return window.isFocused
                && frameOriginDiffers(window.frame, expectedFrame, tolerance: autoDragActive ? 10 : 32)
                && !frameSizeDiffers(window.frame, expectedFrame, tolerance: autoDragActive ? 18 : 24)
        } : []

        let resizedWindows = liveWindows.filter { window in
            guard let expectedFrame = expectedFramesByID[window.id] else {
                return false
            }
            return frameSizeDiffers(window.frame, expectedFrame, tolerance: 24)
        }
        let preferredResizedWindowID = preferredResizeWindowID(from: resizedWindows)
        let hasResizeDrift = resizedWindows.contains(where: \.isFocused) || resizedWindows.count == 1

        if movedWindows.count == 1, let movedWindow = movedWindows.first {
            let operation = ExternalMoveOperation(
                windowID: movedWindow.id,
                element: movedWindow.element,
                lastObservedFrame: movedWindow.frame,
                lastMovementAt: Date(),
                preferredSplitAxis: preferredExternalMoveSplitAxis()
            )
            externalMove = operation
            handleExternalMove(operation, liveWindows: liveWindows, liveWindowsByID: liveWindowsByID)
            return
        }

        guard hasResizeDrift || !movedWindows.isEmpty else {
            return
        }

        let displays = windowController.displays()
        visibleWindowsByID = liveWindowsByID

        if hasResizeDrift {
            layoutEngine.syncRatios(with: liveWindowsByID, preferredWindowID: preferredResizedWindowID)
            persistLayoutSnapshots()
        }

        let frames = layoutEngine.frames(for: .tiling, displays: displays, windowsByID: liveWindowsByID)
        applyFrames(frames, windowsByID: liveWindowsByID, mode: .tiling, animated: true)
    }

    private func handleExternalMove(
        _ operation: ExternalMoveOperation,
        liveWindows: [ManagedWindow],
        liveWindowsByID: [WindowID: ManagedWindow]
    ) {
        var movedWindow = liveWindowsByID[operation.windowID]
        if movedWindow == nil {
            // ID may have changed between stable (cgWindowID) and synthetic (AXElement hash).
            // Fall back to element identity so we don't lose the drag mid-flight.
            if let found = liveWindows.first(where: { CFEqual($0.element, operation.element) }) {
                logger.info("externalMove windowID changed \(operation.windowID, privacy: .public) → \(found.id, privacy: .public)")
                externalMove = ExternalMoveOperation(
                    windowID: found.id,
                    element: found.element,
                    lastObservedFrame: operation.lastObservedFrame,
                    lastMovementAt: operation.lastMovementAt,
                    preferredSplitAxis: operation.preferredSplitAxis
                )
                movedWindow = found
            }
        }
        guard let movedWindow else {
            externalMove = nil
            scheduleRefresh(reason: "external move lost", immediate: true, rebuildTree: true)
            return
        }

        // Cancel any in-flight animation for the dragged window (keyed by element to handle ID changes).
        windowController.cancelAnimation(for: movedWindow.element)

        let now = Date()
        let frameChanged = frameOriginDiffers(movedWindow.frame, operation.lastObservedFrame, tolerance: 8)
            || frameSizeDiffers(movedWindow.frame, operation.lastObservedFrame, tolerance: 8)

        if frameChanged {
            externalMove = ExternalMoveOperation(
                windowID: movedWindow.id,
                element: movedWindow.element,
                lastObservedFrame: movedWindow.frame,
                lastMovementAt: now,
                preferredSplitAxis: operation.preferredSplitAxis ?? preferredExternalMoveSplitAxis()
            )
        }

        // While the mouse is held, leave all stationary windows untouched (no resize, no move).
        // Only apply frames at drop time.
        guard !isPrimaryMouseButtonDown else {
            return
        }

        // --- Drop ---
        externalMove = nil
        visibleWindowsByID = liveWindowsByID

        let displays = windowController.displays()
        let dropPoint = currentMouseLocationInAccessibilityCoords
        // Use mouse position to determine the target display so that cross-display drags
        // land on the correct display even when the window's reported displayID still
        // reflects the source display at the moment of enumeration.
        let targetDisplayID = windowController.nearestDisplay(to: dropPoint)?.displayID ?? movedWindow.displayID
        var windowIDsOnDisplay = liveWindowsByID.values.filter { $0.displayID == targetDisplayID }.map(\.id)
        if !windowIDsOnDisplay.contains(movedWindow.id) {
            windowIDsOnDisplay.append(movedWindow.id)
        }
        layoutEngine.dropWindow(
            movedWindow.id,
            at: dropPoint,
            on: targetDisplayID,
            displays: displays,
            allWindowIDsOnDisplay: windowIDsOnDisplay,
            preferredSplitAxis: operation.preferredSplitAxis ?? preferredExternalMoveSplitAxis()
        )
        persistLayoutSnapshots()

        let finalFrames = layoutEngine.frames(for: .tiling, displays: displays, windowsByID: liveWindowsByID)
        logger.info("drop movedWindow=\(movedWindow.id, privacy: .public) display=\(targetDisplayID, privacy: .public) frames=\(finalFrames.count, privacy: .public)")
        applyFrames(finalFrames, windowsByID: liveWindowsByID, mode: .tiling, animated: true)
    }
}

private extension AppController {
    struct MoveOperation {
        let windowID: WindowID
        let initialFrame: CGRect
    }

    struct ResizeOperation {
        let windowID: WindowID
        let resizeSession: LayoutEngine.ResizeSession
    }

    struct ExternalMoveOperation {
        let windowID: WindowID
        let element: AXUIElement
        let lastObservedFrame: CGRect
        let lastMovementAt: Date
        let preferredSplitAxis: SplitAxis?
    }

    func frameOriginDiffers(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 6) -> Bool {
        abs(lhs.minX - rhs.minX) > tolerance || abs(lhs.minY - rhs.minY) > tolerance
    }

    func frameSizeDiffers(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 6) -> Bool {
        abs(lhs.width - rhs.width) > tolerance || abs(lhs.height - rhs.height) > tolerance
    }

    func frameCenter(_ frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }

    func persistLayoutSnapshots() {
        let snapshots = layoutEngine.persistedLayoutSnapshots()
        guard !snapshots.isEmpty else {
            return
        }
        settingsStore.persistLayoutSnapshots(snapshots)
    }

    var isPrimaryMouseButtonDown: Bool {
        (NSEvent.pressedMouseButtons & 1) == 1
    }

    var currentMouseLocationInAccessibilityCoords: CGPoint {
        let cocoaLocation = NSEvent.mouseLocation
        let referenceMaxY = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0
        return CGPoint(x: cocoaLocation.x, y: referenceMaxY - cocoaLocation.y)
    }

    func preferredExternalMoveSplitAxis() -> SplitAxis? {
        let modifierFlags = NSEvent.ModifierFlags(
            rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue)
        )
        return modifierFlags.contains(NSEvent.ModifierFlags.shift) ? .horizontal : nil
    }

    func automaticExternalMoveOperation(from liveWindows: [ManagedWindow]) -> ExternalMoveOperation? {
        guard mode == .tiling,
              !isPaused,
              activeMove == nil,
              activeResize == nil,
              externalMove == nil,
              isPrimaryMouseButtonDown else {
            return nil
        }

        guard let movedWindow = liveWindows.first(where: { window in
            guard window.isFocused,
                  let expectedFrame = expectedFramesByID[window.id] else {
                return false
            }

            return frameOriginDiffers(window.frame, expectedFrame, tolerance: 10)
                && !frameSizeDiffers(window.frame, expectedFrame, tolerance: 18)
        }) else {
            return nil
        }

        return ExternalMoveOperation(
            windowID: movedWindow.id,
            element: movedWindow.element,
            lastObservedFrame: movedWindow.frame,
            lastMovementAt: Date(),
            preferredSplitAxis: preferredExternalMoveSplitAxis()
        )
    }

    func shouldDeferAutomaticRefreshWhileDragging(liveWindows: [ManagedWindow]) -> Bool {
        guard mode == .tiling,
              !isPaused,
              activeMove == nil,
              activeResize == nil,
              externalMove == nil,
              isPrimaryMouseButtonDown else {
            return false
        }

        return liveWindows.contains(where: \.isFocused)
    }

    func deduplicatedWindows(_ windows: [ManagedWindow], context: String) -> [ManagedWindow] {
        var uniqueWindows: [WindowID: ManagedWindow] = [:]
        uniqueWindows.reserveCapacity(windows.count)

        for window in windows {
            if let existing = uniqueWindows[window.id] {
                uniqueWindows[window.id] = preferredWindow(existing, window)
            } else {
                uniqueWindows[window.id] = window
            }
        }

        let duplicateCount = windows.count - uniqueWindows.count
        if duplicateCount > 0 {
            logger.warning(
                "Dropped duplicate windows context=\(context, privacy: .public) duplicates=\(duplicateCount, privacy: .public)"
            )
        }

        return uniqueWindows.values.sorted { lhs, rhs in
            if lhs.zIndex != rhs.zIndex {
                return lhs.zIndex < rhs.zIndex
            }
            return lhs.id < rhs.id
        }
    }

    func preferredWindow(_ lhs: ManagedWindow, _ rhs: ManagedWindow) -> ManagedWindow {
        if lhs.isFocused != rhs.isFocused {
            return lhs.isFocused ? lhs : rhs
        }

        if (lhs.cgWindowID != 0) != (rhs.cgWindowID != 0) {
            return lhs.cgWindowID != 0 ? lhs : rhs
        }

        if lhs.zIndex != rhs.zIndex {
            return lhs.zIndex < rhs.zIndex ? lhs : rhs
        }

        let lhsArea = max(0, lhs.frame.width) * max(0, lhs.frame.height)
        let rhsArea = max(0, rhs.frame.width) * max(0, rhs.frame.height)
        if lhsArea != rhsArea {
            return lhsArea > rhsArea ? lhs : rhs
        }

        return lhs
    }

    func preferredResizeWindowID(from resizedWindows: [ManagedWindow]) -> WindowID? {
        if let focusedWindowID = resizedWindows.first(where: \.isFocused)?.id {
            return focusedWindowID
        }

        return resizedWindows.max { lhs, rhs in
            resizeDriftMagnitude(for: lhs) < resizeDriftMagnitude(for: rhs)
        }?.id
    }

    func resizeDriftMagnitude(for window: ManagedWindow) -> CGFloat {
        guard let expectedFrame = expectedFramesByID[window.id] else {
            return 0
        }

        return abs(window.frame.width - expectedFrame.width) + abs(window.frame.height - expectedFrame.height)
    }
}

@MainActor
extension AppController: InputRouterDelegate {
    func inputRouter(_ router: InputRouter, windowAt point: CGPoint) -> ManagedWindow? {
        guard permissionState.accessibilityGranted, !isPaused else {
            return nil
        }

        return windowController.window(at: point, from: Array(visibleWindowsByID.values))
    }

    func inputRouter(_ router: InputRouter, beganMoveFor window: ManagedWindow) {
        activeResize = nil
        activeMove = MoveOperation(windowID: window.id, initialFrame: visibleWindowsByID[window.id]?.frame ?? window.frame)
    }

    func inputRouter(_ router: InputRouter, updateMoveFor window: ManagedWindow, translation: CGVector, currentPoint: CGPoint) {
        guard let activeMove, activeMove.windowID == window.id,
              let liveWindow = visibleWindowsByID[window.id] else {
            return
        }

        _ = currentPoint

        let nextFrame = activeMove.initialFrame.offsetBy(dx: translation.dx, dy: translation.dy)
        windowController.setFrame(nextFrame, for: liveWindow)
    }

    func inputRouter(_ router: InputRouter, endedMoveFor window: ManagedWindow, currentPoint: CGPoint) {
        _ = currentPoint
        activeMove = nil
        scheduleRefresh(reason: "move end", immediate: true, rebuildTree: true)
    }

    func inputRouter(_ router: InputRouter, beganResizeFor window: ManagedWindow, edge: ResizeEdge) {
        activeMove = nil

        guard mode != .monocle,
              let resizeSession = layoutEngine.beginResize(
                windowID: window.id,
                edge: edge,
                windowsByID: visibleWindowsByID
              ) else {
            activeResize = nil
            return
        }

        activeResize = ResizeOperation(windowID: window.id, resizeSession: resizeSession)
    }

    func inputRouter(_ router: InputRouter, updateResizeFor window: ManagedWindow, edge: ResizeEdge, translation: CGVector, currentPoint: CGPoint) {
        guard let activeResize, activeResize.windowID == window.id else {
            return
        }

        _ = edge
        _ = currentPoint

        layoutEngine.updateResize(activeResize.resizeSession, translation: translation)
        let frames = layoutEngine.frames(for: .tiling, displays: windowController.displays(), windowsByID: visibleWindowsByID)
        applyFrames(frames, windowsByID: visibleWindowsByID, mode: .tiling, animated: false)
    }

    func inputRouter(_ router: InputRouter, endedResizeFor window: ManagedWindow, edge: ResizeEdge, currentPoint: CGPoint) {
        _ = window
        _ = edge
        _ = currentPoint

        activeResize = nil
        persistLayoutSnapshots()
        scheduleRefresh(reason: "resize end", immediate: true, rebuildTree: false)
    }
}

private let applicationObserverCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else {
        return
    }

    let controller = Unmanaged<AppController>.fromOpaque(refcon).takeUnretainedValue()
    Task { @MainActor in
        controller.startIfNeeded()
        controller.retileFromObserver()
    }
}

@MainActor
private extension AppController {
    func retileFromObserver() {
        scheduleRefresh(reason: "ax observer")
    }
}
