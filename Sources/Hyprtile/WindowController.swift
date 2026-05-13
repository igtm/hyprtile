import AppKit
import ApplicationServices

@MainActor
final class WindowController {
    private struct FrameAnimation {
        let element: AXUIElement
        let minimumSize: CGSize
        let from: CGRect
        let to: CGRect
        let startedAt: Date
        let duration: TimeInterval
    }

    @MainActor
    private enum AXAttribute {
        static let role = kAXRoleAttribute as CFString
        static let subrole = kAXSubroleAttribute as CFString
        static let windows = kAXWindowsAttribute as CFString
        static let focusedWindow = kAXFocusedWindowAttribute as CFString
        static let minimized = kAXMinimizedAttribute as CFString
        static let modal = kAXModalAttribute as CFString
        static let position = kAXPositionAttribute as CFString
        static let size = kAXSizeAttribute as CFString
        static let title = kAXTitleAttribute as CFString
        static let fullScreen = "AXFullScreen" as CFString
        static let resizable = "AXResizable" as CFString
        static let minSize = "AXMinSize" as CFString
    }

    private struct OnScreenWindowDescriptor {
        let windowID: CGWindowID
        let applicationPID: pid_t
        let bounds: CGRect
        let zIndex: Int
    }

    private struct DesktopCoordinateSpace {
        let referenceMaxY: CGFloat

        init(screens: [NSScreen]) {
            let referenceScreen = screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main ?? screens.first
            referenceMaxY = referenceScreen?.frame.maxY ?? 0
        }

        func cocoaToAccessibility(_ rect: CGRect) -> CGRect {
            CGRect(
                x: rect.minX,
                y: referenceMaxY - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        }
    }

    private var frameAnimations: [WindowID: FrameAnimation] = [:]
    private var animationTimer: Timer?

    var isAnimatingFrames: Bool {
        !frameAnimations.isEmpty
    }

    func displays() -> [DisplayDescriptor] {
        let screens = NSScreen.screens
        let coordinateSpace = DesktopCoordinateSpace(screens: screens)

        return screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            return DisplayDescriptor(
                displayID: CGDirectDisplayID(number.uint32Value),
                name: screen.localizedName,
                frame: coordinateSpace.cocoaToAccessibility(screen.frame),
                visibleFrame: coordinateSpace.cocoaToAccessibility(screen.visibleFrame)
            )
        }
    }

    func enumerateManagedWindows() -> [ManagedWindow] {
        let descriptors = onScreenWindowDescriptors()
        let descriptorsByPID = Dictionary(grouping: descriptors, by: \.applicationPID)
        let visibleDisplays = Dictionary(uniqueKeysWithValues: displays().map { ($0.displayID, $0) })
        let ownPID = ProcessInfo.processInfo.processIdentifier

        var windowsByID: [WindowID: ManagedWindow] = [:]

        for application in NSWorkspace.shared.runningApplications {
            let pid = application.processIdentifier

            guard pid != ownPID, !application.isTerminated else {
                continue
            }

            guard !isExcludedApplication(application) else {
                continue
            }

            let applicationElement = AXUIElementCreateApplication(pid)
            let focusedWindow = copyElement(applicationElement, attribute: AXAttribute.focusedWindow)
            let applicationWindows = copyElements(applicationElement, attribute: AXAttribute.windows)

            for windowElement in applicationWindows {
                guard let window = buildManagedWindow(
                    from: windowElement,
                    in: application,
                    focusedWindow: focusedWindow,
                    visibleDescriptors: descriptorsByPID[pid] ?? [],
                    visibleDisplays: visibleDisplays
                ) else {
                    continue
                }

                if let existing = windowsByID[window.id] {
                    windowsByID[window.id] = preferredWindow(existing, window)
                } else {
                    windowsByID[window.id] = window
                }
            }
        }

        return windowsByID.values.sorted { lhs, rhs in
            if lhs.zIndex != rhs.zIndex {
                return lhs.zIndex < rhs.zIndex
            }
            return lhs.id < rhs.id
        }
    }

    func window(at point: CGPoint, from windows: [ManagedWindow]) -> ManagedWindow? {
        windows.sorted { $0.zIndex < $1.zIndex }.first { window in
            window.frame.contains(point)
        }
    }

    func setFrame(
        _ frame: CGRect,
        for window: ManagedWindow,
        animated: Bool = false,
        duration: TimeInterval = 0.10
    ) {
        let clampedFrame = clampedFrame(frame, minimumSize: window.minimumSize)

        guard animated else {
            cancelAnimation(for: window.id)
            applyFrame(clampedFrame, to: window.element)
            return
        }

        let now = Date()
        let fromFrame = currentAnimatedFrame(for: window.id, at: now) ?? window.frame
        guard frameDelta(fromFrame, clampedFrame) > 8 else {
            cancelAnimation(for: window.id)
            applyFrame(clampedFrame, to: window.element)
            return
        }

        frameAnimations[window.id] = FrameAnimation(
            element: window.element,
            minimumSize: window.minimumSize,
            from: fromFrame,
            to: clampedFrame,
            startedAt: now,
            duration: duration
        )
        ensureAnimationTimer()
    }

    func raise(_ window: ManagedWindow) {
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    }

    func focus(_ window: ManagedWindow) {
        raise(window)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    func nearestDisplay(to point: CGPoint) -> DisplayDescriptor? {
        let displays = displays()

        if let containing = displays.first(where: { $0.frame.contains(point) }) {
            return containing
        }

        return displays.min { lhs, rhs in
            lhs.frame.center.distanceSquared(to: point) < rhs.frame.center.distanceSquared(to: point)
        }
    }

    private func buildManagedWindow(
        from element: AXUIElement,
        in application: NSRunningApplication,
        focusedWindow: AXUIElement?,
        visibleDescriptors: [OnScreenWindowDescriptor],
        visibleDisplays: [CGDirectDisplayID: DisplayDescriptor]
    ) -> ManagedWindow? {
        guard copyString(element, attribute: AXAttribute.role) == kAXWindowRole as String else {
            return nil
        }

        if let subrole = copyString(element, attribute: AXAttribute.subrole),
           subrole != kAXStandardWindowSubrole as String {
            return nil
        }

        guard !copyBool(element, attribute: AXAttribute.minimized),
              !copyBool(element, attribute: AXAttribute.fullScreen),
              !copyBool(element, attribute: AXAttribute.modal) else {
            return nil
        }

        guard copyBool(element, attribute: AXAttribute.resizable, defaultValue: true) else {
            return nil
        }

        guard let origin = copyPoint(element, attribute: AXAttribute.position),
              let size = copySize(element, attribute: AXAttribute.size) else {
            return nil
        }

        let frame = CGRect(origin: origin, size: size)
        guard frame.width >= 120, frame.height >= 80 else {
            return nil
        }

        let descriptor = bestDescriptor(for: application.processIdentifier, frame: frame, descriptors: visibleDescriptors)
        let referenceFrame = descriptor?.bounds ?? frame

        guard let display = bestDisplay(for: referenceFrame, visibleDisplays: visibleDisplays),
              display.visibleFrame.intersectionArea(with: frame) > 0 else {
            return nil
        }

        let minimumSize = copySize(element, attribute: AXAttribute.minSize) ?? CGSize(width: 240, height: 160)
        let isFocused = focusedWindow.map { CFEqual($0, element) } ?? false
        let title = copyString(element, attribute: AXAttribute.title) ?? application.localizedName ?? "Window"
        let fallbackWindowID = syntheticWindowID(
            for: element,
            pid: application.processIdentifier,
            title: title,
            frame: frame
        )
        let windowID = descriptor.map { "\($0.windowID)" } ?? fallbackWindowID
        let zIndex = descriptor?.zIndex ?? Int.max

        return ManagedWindow(
            id: "\(application.processIdentifier)-\(windowID)",
            applicationPID: application.processIdentifier,
            applicationName: application.localizedName ?? "Unknown",
            title: title,
            element: element,
            frame: frame,
            minimumSize: minimumSize,
            isFocused: isFocused,
            canResize: true,
            displayID: display.displayID,
            cgWindowID: descriptor?.windowID ?? 0,
            zIndex: zIndex,
            groupHint: nil,
            workspaceHint: nil
        )
    }

    private func isExcludedApplication(_ application: NSRunningApplication) -> Bool {
        guard let bundleIdentifier = application.bundleIdentifier?.lowercased() else {
            return false
        }

        return bundleIdentifier.contains("inputmethod")
            || bundleIdentifier.contains("textinput")
            || bundleIdentifier.contains("characterpalette")
            || bundleIdentifier.contains("keyboardviewer")
    }

    private func bestDisplay(
        for frame: CGRect,
        visibleDisplays: [CGDirectDisplayID: DisplayDescriptor]
    ) -> DisplayDescriptor? {
        visibleDisplays.values.max { lhs, rhs in
            lhs.visibleFrame.intersectionArea(with: frame) < rhs.visibleFrame.intersectionArea(with: frame)
        }
    }

    private func bestDescriptor(
        for pid: pid_t,
        frame: CGRect,
        descriptors: [OnScreenWindowDescriptor]
    ) -> OnScreenWindowDescriptor? {
        descriptors.max { lhs, rhs in
            descriptorScore(lhs, frame: frame) < descriptorScore(rhs, frame: frame)
        }.flatMap { descriptor in
            descriptorScore(descriptor, frame: frame) > 0.15 ? descriptor : nil
        }
    }

    private func descriptorScore(_ descriptor: OnScreenWindowDescriptor, frame: CGRect) -> CGFloat {
        let intersection = descriptor.bounds.intersectionArea(with: frame)
        let maxArea = max(descriptor.bounds.area, frame.area)
        guard maxArea > 0 else {
            return 0
        }
        return intersection / maxArea
    }

    private func onScreenWindowDescriptors() -> [OnScreenWindowDescriptor] {
        guard let rawWindowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return rawWindowInfo.enumerated().compactMap { index, item in
            guard let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let windowID = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDictionary = item[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else {
                return nil
            }

            return OnScreenWindowDescriptor(
                windowID: CGWindowID(windowID),
                applicationPID: pid_t(pid),
                bounds: bounds,
                zIndex: index
            )
        }
    }

    private func copyElements(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return []
        }

        let array = unsafeBitCast(value, to: CFArray.self)
        let count = CFArrayGetCount(array)
        var elements: [AXUIElement] = []
        elements.reserveCapacity(count)

        for index in 0..<count {
            let pointer = CFArrayGetValueAtIndex(array, index)
            let element = unsafeBitCast(pointer, to: AXUIElement.self)
            elements.append(element)
        }

        return elements
    }

    private func copyElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        guard let value else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyString(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func copyBool(_ element: AXUIElement, attribute: CFString, defaultValue: Bool = false) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let number = value as? NSNumber else {
            return defaultValue
        }
        return number.boolValue
    }

    private func preferredWindow(_ lhs: ManagedWindow, _ rhs: ManagedWindow) -> ManagedWindow {
        if lhs.isFocused != rhs.isFocused {
            return lhs.isFocused ? lhs : rhs
        }

        if (lhs.cgWindowID != 0) != (rhs.cgWindowID != 0) {
            return lhs.cgWindowID != 0 ? lhs : rhs
        }

        if lhs.zIndex != rhs.zIndex {
            return lhs.zIndex < rhs.zIndex ? lhs : rhs
        }

        if lhs.frame.area != rhs.frame.area {
            return lhs.frame.area > rhs.frame.area ? lhs : rhs
        }

        return lhs
    }

    private func syntheticWindowID(for element: AXUIElement, pid: pid_t, title: String, frame: CGRect) -> String {
        let roundedFrame = CGRect(
            x: frame.origin.x.rounded(.towardZero),
            y: frame.origin.y.rounded(.towardZero),
            width: frame.width.rounded(.towardZero),
            height: frame.height.rounded(.towardZero)
        )

        return [
            String(pid),
            title,
            String(Int(roundedFrame.origin.x)),
            String(Int(roundedFrame.origin.y)),
            String(Int(roundedFrame.width)),
            String(Int(roundedFrame.height)),
            String(CFHash(element)),
        ].joined(separator: ":")
    }

    private func copyPoint(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func copySize(_ element: AXUIElement, attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private func clampedFrame(_ frame: CGRect, minimumSize: CGSize) -> CGRect {
        let clampedSize = CGSize(
            width: max(minimumSize.width, frame.width.rounded(.down)),
            height: max(minimumSize.height, frame.height.rounded(.down))
        )
        return CGRect(origin: frame.origin, size: clampedSize)
    }

    private func currentAnimatedFrame(for windowID: WindowID, at date: Date) -> CGRect? {
        guard let animation = frameAnimations[windowID] else {
            return nil
        }

        let progress = min(1, date.timeIntervalSince(animation.startedAt) / max(animation.duration, 0.001))
        return interpolatedFrame(from: animation.from, to: animation.to, progress: easedProgress(progress))
    }

    private func ensureAnimationTimer() {
        guard animationTimer == nil else {
            return
        }

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.stepAnimations()
            }
        }
    }

    private func stepAnimations() {
        guard !frameAnimations.isEmpty else {
            animationTimer?.invalidate()
            animationTimer = nil
            return
        }

        let now = Date()
        var completedWindowIDs: [WindowID] = []

        for (windowID, animation) in frameAnimations {
            let rawProgress = min(1, now.timeIntervalSince(animation.startedAt) / max(animation.duration, 0.001))
            let frame = interpolatedFrame(from: animation.from, to: animation.to, progress: easedProgress(rawProgress))
            applyFrame(clampedFrame(frame, minimumSize: animation.minimumSize), to: animation.element)

            if rawProgress >= 1 {
                completedWindowIDs.append(windowID)
            }
        }

        for windowID in completedWindowIDs {
            frameAnimations.removeValue(forKey: windowID)
        }

        if frameAnimations.isEmpty {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func cancelAnimation(for windowID: WindowID) {
        frameAnimations.removeValue(forKey: windowID)
        if frameAnimations.isEmpty {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func applyFrame(_ frame: CGRect, to element: AXUIElement) {
        set(position: frame.origin, on: element)
        set(size: frame.size, on: element)
    }

    private func interpolatedFrame(from: CGRect, to: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: from.minX + ((to.minX - from.minX) * progress),
            y: from.minY + ((to.minY - from.minY) * progress),
            width: from.width + ((to.width - from.width) * progress),
            height: from.height + ((to.height - from.height) * progress)
        )
    }

    private func easedProgress(_ progress: Double) -> CGFloat {
        let value = CGFloat(progress)
        return 1 - pow(1 - value, 3)
    }

    private func frameDelta(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX)
            + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }

    private func set(position: CGPoint, on element: AXUIElement) {
        var position = position
        guard let value = AXValueCreate(.cgPoint, &position) else {
            return
        }
        AXUIElementSetAttributeValue(element, AXAttribute.position, value)
    }

    private func set(size: CGSize, on element: AXUIElement) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else {
            return
        }
        AXUIElementSetAttributeValue(element, AXAttribute.size, value)
    }
}

private extension CGRect {
    var area: CGFloat {
        max(0, width) * max(0, height)
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    func intersectionArea(with other: CGRect) -> CGFloat {
        intersection(other).area
    }
}

private extension CGPoint {
    func distanceSquared(to other: CGPoint) -> CGFloat {
        let deltaX = x - other.x
        let deltaY = y - other.y
        return (deltaX * deltaX) + (deltaY * deltaY)
    }
}
