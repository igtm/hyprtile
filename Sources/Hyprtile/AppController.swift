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

    let settingsStore: SettingsStore
    let permissionMonitor: PermissionMonitor

    private let windowController = WindowController()
    private let layoutEngine = LayoutEngine()
    private let inputRouter = InputRouter()

    private var didStart = false
    private var refreshWorkItem: DispatchWorkItem?
    private var visibleWindowsByID: [WindowID: ManagedWindow] = [:]
    private var expectedFramesByID: [WindowID: CGRect] = [:]
    private var lastAppliedAt = Date.distantPast
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var applicationObservers: [pid_t: AXObserver] = [:]
    private var externalChangeTimer: Timer?
    private var settingsWindow: NSWindow?

    private var activeMove: MoveOperation?
    private var activeResize: ResizeOperation?
    private var externalMove: ExternalMoveOperation?

    var isEnabled: Bool {
        settingsStore.isEnabled
    }

    var mode: AppMode {
        settingsStore.mode
    }

    var canTile: Bool {
        permissionState.accessibilityGranted && isEnabled
    }

    var statusItemImageName: String {
        guard permissionState.accessibilityGranted else {
            return "exclamationmark.triangle"
        }

        guard isEnabled else {
            return "pause.circle"
        }

        switch mode {
        case .tiling:
            return "rectangle.split.3x1"
        case .pause:
            return "pause.rectangle"
        case .monocle:
            return "square.on.square"
        }
    }

    var permissionStatusText: String {
        switch permissionState.accessibilityGranted {
        case true:
            return "Accessibility granted. Middle-button drag enabled in this build."
        case false:
            return "Accessibility permission required"
        }
    }

    var launchAtLoginStatusText: String {
        launchAtLoginEnabled ? "Enabled" : "Not active"
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

                if newState.accessibilityGranted, isEnabled {
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

    func setEnabled(_ enabled: Bool) {
        settingsStore.isEnabled = enabled
        logger.info("Set enabled=\(enabled, privacy: .public)")

        if !enabled {
            inputRouter.uninstall()
        } else if permissionState.accessibilityGranted {
            inputRouter.install()
        }

        scheduleRefresh(reason: "toggle enabled", immediate: true)
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
        let window: NSWindow

        if let settingsWindow {
            window = settingsWindow
            if let hostingController = window.contentViewController as? NSHostingController<PreferencesView> {
                hostingController.rootView = PreferencesView(controller: self)
            }
        } else {
            let hostingController = NSHostingController(rootView: PreferencesView(controller: self))
            let settingsWindow = NSWindow(contentViewController: hostingController)
            settingsWindow.title = "Hyprtile Preferences"
            settingsWindow.styleMask = [.titled, .closable, .miniaturizable]
            settingsWindow.setContentSize(NSSize(width: 520, height: 420))
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.center()
            settingsWindow.collectionBehavior = [.moveToActiveSpace]
            self.settingsWindow = settingsWindow
            window = settingsWindow
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func retileNow() {
        let manualMode: AppMode = switch mode {
        case .pause:
            .tiling
        case .tiling:
            .tiling
        case .monocle:
            .monocle
        }

        scheduleRefresh(
            reason: "manual retile",
            immediate: true,
            rebuildTree: true,
            manualMode: manualMode
        )
    }

    func quit() {
        NSApp.terminate(nil)
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

        guard isEnabled else {
            inputRouter.uninstall()
            logger.debug("Skipping apply because tiling is disabled")
            return
        }

        if permissionState.accessibilityGranted {
            inputRouter.install()
        } else {
            inputRouter.uninstall()
        }

        let effectiveMode = manualMode ?? mode
        switch effectiveMode {
        case .pause where manualMode == nil:
            return
        case .pause:
            applyFrames(layoutEngine.frames(for: .tiling, displays: displays, windowsByID: windowsByID), windowsByID: windowsByID, mode: .tiling)
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

            window.frame = frame
            updatedWindowsByID[windowID] = window
            windowController.setFrame(frame, for: window, animated: animated)
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
              isEnabled,
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
        guard let movedWindow = liveWindowsByID[operation.windowID] else {
            externalMove = nil
            scheduleRefresh(reason: "external move lost", immediate: true, rebuildTree: true)
            return
        }

        let now = Date()
        let frameChanged = frameOriginDiffers(movedWindow.frame, operation.lastObservedFrame, tolerance: 8)
            || frameSizeDiffers(movedWindow.frame, operation.lastObservedFrame, tolerance: 8)

        if frameChanged {
            externalMove = ExternalMoveOperation(
                windowID: movedWindow.id,
                lastObservedFrame: movedWindow.frame,
                lastMovementAt: now,
                preferredSplitAxis: operation.preferredSplitAxis ?? preferredExternalMoveSplitAxis()
            )
        }

        let displays = windowController.displays()
        let stationaryWindows = liveWindows.filter { $0.id != movedWindow.id }
        let stationaryWindowsByID = Dictionary(uniqueKeysWithValues: stationaryWindows.map { ($0.id, $0) })

        visibleWindowsByID = liveWindowsByID
        layoutEngine.rebuildSessions(with: stationaryWindows, displays: displays)
        let stationaryFrames = layoutEngine.frames(for: .tiling, displays: displays, windowsByID: liveWindowsByID)
        applyFrames(stationaryFrames, windowsByID: liveWindowsByID, mode: .tiling, animated: true)

        guard !isPrimaryMouseButtonDown else {
            return
        }

        externalMove = nil
        visibleWindowsByID = liveWindowsByID
        layoutEngine.rebuildSessions(with: stationaryWindows, displays: displays)
        layoutEngine.insertWindow(
            movedWindow.id,
            at: frameCenter(movedWindow.frame),
            on: movedWindow.displayID,
            displays: displays,
            preferredSplitAxis: operation.preferredSplitAxis ?? preferredExternalMoveSplitAxis()
        )
        persistLayoutSnapshots()

        let mergedWindowsByID = stationaryWindowsByID.merging([movedWindow.id: movedWindow]) { _, rhs in rhs }
        let finalFrames = layoutEngine.frames(for: .tiling, displays: displays, windowsByID: mergedWindowsByID)
        applyFrames(finalFrames, windowsByID: mergedWindowsByID, mode: .tiling, animated: true)
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

    func preferredExternalMoveSplitAxis() -> SplitAxis? {
        let modifierFlags = NSEvent.ModifierFlags(
            rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue)
        )
        return modifierFlags.contains(NSEvent.ModifierFlags.option) ? .horizontal : nil
    }

    func automaticExternalMoveOperation(from liveWindows: [ManagedWindow]) -> ExternalMoveOperation? {
        guard mode == .tiling,
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
            lastObservedFrame: movedWindow.frame,
            lastMovementAt: Date(),
            preferredSplitAxis: preferredExternalMoveSplitAxis()
        )
    }

    func shouldDeferAutomaticRefreshWhileDragging(liveWindows: [ManagedWindow]) -> Bool {
        guard mode == .tiling,
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
        guard permissionState.accessibilityGranted, isEnabled else {
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
