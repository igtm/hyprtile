import AppKit

@MainActor
final class LayoutEngine {
    struct ResizeSession {
        let node: LayoutNode
        let axis: SplitAxis
        let initialRatio: CGFloat
        let ancestorFrame: CGRect
        let lowerBound: CGFloat
        let upperBound: CGFloat
    }

    private enum ChildSide {
        case first
        case second
    }

    private(set) var sessions: [CGDirectDisplayID: DisplayLayoutState] = [:]
    private var cachedRoots: [LayoutSnapshotKey: LayoutNode] = [:]
    private var currentSnapshotKeys: [CGDirectDisplayID: LayoutSnapshotKey] = [:]

    func rebuildSessions(
        with windows: [ManagedWindow],
        displays: [DisplayDescriptor],
        persistedSnapshots: [LayoutSnapshotKey: PersistedLayoutNode] = [:]
    ) {
        let displaysByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.displayID, $0) })
        let validDisplayIDs = Set(displaysByID.keys)

        sessions = sessions.filter { validDisplayIDs.contains($0.key) }
        currentSnapshotKeys = currentSnapshotKeys.filter { validDisplayIDs.contains($0.key) }
        cachedRoots = cachedRoots.filter { validDisplayIDs.contains($0.key.displayID) }

        for display in displays {
            if let session = sessions[display.displayID] {
                session.visibleFrame = display.visibleFrame
            } else {
                sessions[display.displayID] = DisplayLayoutState(
                    displayID: display.displayID,
                    visibleFrame: display.visibleFrame
                )
            }
        }

        let windowsByDisplay = Dictionary(grouping: windows, by: \.displayID)

        for display in displays {
            let sessionWindows = windowsByDisplay[display.displayID] ?? []
            let focusedWindowID = sessionWindows.first(where: \.isFocused)?.id
            let orderedWindows = prioritizedWindows(sessionWindows)
            let snapshotKey = LayoutSnapshotKey(
                displayID: display.displayID,
                windowIDs: orderedWindows.map(\.id)
            )

            guard let session = sessions[display.displayID] else {
                continue
            }

            session.visibleFrame = display.visibleFrame
            session.focusedWindowID = focusedWindowID

            if let previousKey = currentSnapshotKeys[display.displayID],
               previousKey != snapshotKey,
               let currentRoot = session.root {
                cachedRoots[previousKey] = currentRoot
            }

            guard !orderedWindows.isEmpty else {
                session.root = nil
                currentSnapshotKeys.removeValue(forKey: display.displayID)
                continue
            }

            let restoredRoot: LayoutNode?
            if currentSnapshotKeys[display.displayID] == snapshotKey {
                restoredRoot = session.root
            } else if let cachedRoot = cachedRoots[snapshotKey] {
                restoredRoot = cachedRoot
            } else {
                restoredRoot = persistedSnapshots[snapshotKey].flatMap(LayoutNode.restore(from:))
            }

            let syncedRoot = syncTree(
                existingRoot: restoredRoot,
                windows: orderedWindows,
                visibleFrame: display.visibleFrame,
                focusedWindowID: focusedWindowID
            )
            session.root = syncedRoot
            currentSnapshotKeys[display.displayID] = snapshotKey

            if let syncedRoot {
                cachedRoots[snapshotKey] = syncedRoot
            }
        }
    }

    func frames(
        for mode: AppMode,
        displays: [DisplayDescriptor],
        windowsByID: [WindowID: ManagedWindow]
    ) -> [WindowID: CGRect] {
        var results: [WindowID: CGRect] = [:]
        let visibleFramesByDisplay = Dictionary(uniqueKeysWithValues: displays.map { ($0.displayID, $0.visibleFrame) })

        for (displayID, session) in sessions {
            guard let visibleFrame = visibleFramesByDisplay[displayID], let root = session.root else {
                continue
            }

            switch mode {
            case .tiling:
                assignFrames(node: root, rect: visibleFrame, windowsByID: windowsByID, storage: &results)
            case .monocle:
                for windowID in root.orderedLeafIDs() {
                    results[windowID] = visibleFrame
                }
            }
        }

        return results
    }

    func focusedWindowIDs() -> [WindowID] {
        sessions.values.compactMap(\.focusedWindowID)
    }

    func persistedLayoutSnapshots() -> [LayoutSnapshotKey: PersistedLayoutNode] {
        var snapshots = Dictionary(uniqueKeysWithValues: cachedRoots.map { ($0.key, $0.value.snapshot()) })

        for (displayID, session) in sessions {
            guard let snapshotKey = currentSnapshotKeys[displayID],
                  let root = session.root else {
                continue
            }
            snapshots[snapshotKey] = root.snapshot()
        }

        return snapshots
    }

    func beginResize(
        windowID: WindowID,
        edge: ResizeEdge,
        windowsByID: [WindowID: ManagedWindow]
    ) -> ResizeSession? {
        guard let session = sessions.values.first(where: { $0.root?.leafNode(for: windowID) != nil }),
              let root = session.root,
              let leaf = root.leafNode(for: windowID) else {
            return nil
        }

        let desiredSide: ChildSide = switch edge {
        case .left, .top:
            .second
        case .right, .bottom:
            .first
        }

        let nodeFrames = nodeFrames(root: root, rect: session.visibleFrame)
        var ancestor = leaf.parent

        while let current = ancestor {
            guard current.axis == edge.axis else {
                ancestor = current.parent
                continue
            }

            let sideMatches: Bool
            switch desiredSide {
            case .first:
                sideMatches = current.first?.subtreeContains(leaf) == true
            case .second:
                sideMatches = current.second?.subtreeContains(leaf) == true
            }

            guard sideMatches, let ancestorFrame = nodeFrames[ObjectIdentifier(current)] else {
                ancestor = current.parent
                continue
            }

            let bounds = ratioBounds(for: current, ancestorFrame: ancestorFrame, windowsByID: windowsByID)
            return ResizeSession(
                node: current,
                axis: edge.axis,
                initialRatio: current.ratio,
                ancestorFrame: ancestorFrame,
                lowerBound: bounds.lower,
                upperBound: bounds.upper
            )
        }

        return nil
    }

    func updateResize(_ session: ResizeSession, translation: CGVector) {
        let delta: CGFloat
        switch session.axis {
        case .vertical:
            delta = translation.dx / max(session.ancestorFrame.width, 1)
        case .horizontal:
            delta = -translation.dy / max(session.ancestorFrame.height, 1)
        }

        let unclampedRatio = session.initialRatio + delta
        session.node.ratio = min(session.upperBound, max(session.lowerBound, unclampedRatio))
    }

    func syncRatios(with windowsByID: [WindowID: ManagedWindow], preferredWindowID: WindowID? = nil) {
        for session in sessions.values {
            guard let root = session.root else {
                continue
            }

            let ancestorFrames = nodeFrames(root: root, rect: session.visibleFrame)
            _ = syncRatios(
                node: root,
                ancestorFrames: ancestorFrames,
                windowsByID: windowsByID,
                preferredWindowID: preferredWindowID
            )
        }
    }

    func insertWindow(
        _ windowID: WindowID,
        at point: CGPoint,
        on displayID: CGDirectDisplayID,
        displays: [DisplayDescriptor],
        preferredSplitAxis: SplitAxis? = nil
    ) {
        guard let display = displays.first(where: { $0.displayID == displayID }) else {
            return
        }

        let session = sessions[displayID] ?? DisplayLayoutState(
            displayID: display.displayID,
            visibleFrame: display.visibleFrame
        )

        session.visibleFrame = display.visibleFrame
        var root = session.root
        insertWindow(
            windowID,
            into: &root,
            preferredFocusWindowID: nil,
            preferredPoint: point,
            visibleFrame: display.visibleFrame,
            preferredSplitAxis: preferredSplitAxis
        )
        session.root = root
        session.focusedWindowID = windowID
        sessions[displayID] = session
    }

    private func prioritizedWindows(_ windows: [ManagedWindow]) -> [ManagedWindow] {
        windows.sorted { lhs, rhs in
            if lhs.isFocused != rhs.isFocused {
                return lhs.isFocused && !rhs.isFocused
            }
            return lhs.zIndex < rhs.zIndex
        }
    }

    private func syncTree(
        existingRoot: LayoutNode?,
        windows: [ManagedWindow],
        visibleFrame: CGRect,
        focusedWindowID: WindowID?
    ) -> LayoutNode? {
        let orderedWindowIDs = windows.map(\.id)
        guard !orderedWindowIDs.isEmpty else {
            return nil
        }

        var root = pruneTree(existingRoot, validWindowIDs: Set(orderedWindowIDs))

        if root == nil {
            return buildTree(from: orderedWindowIDs, visibleFrame: visibleFrame)
        }

        let existingIDs = Set(root?.orderedLeafIDs() ?? [])
        let newWindowIDs = orderedWindowIDs.filter { !existingIDs.contains($0) }

        for newWindowID in newWindowIDs {
            insertWindow(
                newWindowID,
                into: &root,
                preferredFocusWindowID: focusedWindowID,
                visibleFrame: visibleFrame
            )
        }

        return root
    }

    private func buildTree(from windowIDs: [WindowID], visibleFrame: CGRect) -> LayoutNode? {
        guard let firstWindowID = windowIDs.first else {
            return nil
        }

        var root: LayoutNode? = LayoutNode(windowID: firstWindowID)
        var focusWindowID = firstWindowID

        for windowID in windowIDs.dropFirst() {
            insertWindow(
                windowID,
                into: &root,
                preferredFocusWindowID: focusWindowID,
                visibleFrame: visibleFrame
            )
            focusWindowID = windowID
        }

        return root
    }

    @discardableResult
    private func syncRatios(
        node: LayoutNode,
        ancestorFrames: [ObjectIdentifier: CGRect],
        windowsByID: [WindowID: ManagedWindow],
        preferredWindowID: WindowID?
    ) -> CGRect? {
        if let windowID = node.windowID {
            return windowsByID[windowID]?.frame
        }

        guard let first = node.first,
              let second = node.second,
              let axis = node.axis,
              let firstRect = syncRatios(
                node: first,
                ancestorFrames: ancestorFrames,
                windowsByID: windowsByID,
                preferredWindowID: preferredWindowID
              ),
              let secondRect = syncRatios(
                node: second,
                ancestorFrames: ancestorFrames,
                windowsByID: windowsByID,
                preferredWindowID: preferredWindowID
              ) else {
            return nil
        }

        let combinedRect = firstRect.union(secondRect)
        guard let ancestorFrame = ancestorFrames[ObjectIdentifier(node)] else {
            return combinedRect
        }

        switch axis {
        case .vertical:
            let dividerX: CGFloat
            let firstContainsFocused = subtreeContainsPriorityWindow(
                node: first,
                windowsByID: windowsByID,
                preferredWindowID: preferredWindowID
            )
            let secondContainsFocused = subtreeContainsPriorityWindow(
                node: second,
                windowsByID: windowsByID,
                preferredWindowID: preferredWindowID
            )
            let overlappingChildren = firstRect.maxX > secondRect.minX + 1
            let firstPinnedToMinimum = abs(firstRect.width - minimumWidth(node: first, windowsByID: windowsByID)) <= 4

            if firstContainsFocused, !secondContainsFocused {
                dividerX = overlappingChildren && firstPinnedToMinimum ? secondRect.minX : firstRect.maxX
            } else if secondContainsFocused {
                dividerX = secondRect.minX
            } else {
                dividerX = secondRect.minX
            }

            let rawRatio = (dividerX - ancestorFrame.minX) / max(ancestorFrame.width, 1)
            let bounds = ratioBounds(for: node, ancestorFrame: ancestorFrame, windowsByID: windowsByID)
            node.ratio = min(bounds.upper, max(bounds.lower, rawRatio))
        case .horizontal:
            let dividerY: CGFloat
            let firstContainsFocused = subtreeContainsPriorityWindow(
                node: first,
                windowsByID: windowsByID,
                preferredWindowID: preferredWindowID
            )
            let secondContainsFocused = subtreeContainsPriorityWindow(
                node: second,
                windowsByID: windowsByID,
                preferredWindowID: preferredWindowID
            )
            let overlappingChildren = secondRect.maxY > firstRect.minY + 1
            let secondPinnedToMinimum = abs(secondRect.height - minimumHeight(node: second, windowsByID: windowsByID)) <= 4

            if firstContainsFocused {
                dividerY = firstRect.minY
            } else if secondContainsFocused, !firstContainsFocused {
                dividerY = overlappingChildren && secondPinnedToMinimum ? firstRect.minY : secondRect.maxY
            } else {
                dividerY = firstRect.minY
            }

            let rawRatio = (ancestorFrame.maxY - dividerY) / max(ancestorFrame.height, 1)
            let bounds = ratioBounds(for: node, ancestorFrame: ancestorFrame, windowsByID: windowsByID)
            node.ratio = min(bounds.upper, max(bounds.lower, rawRatio))
        }

        return combinedRect
    }

    private func subtreeContainsPriorityWindow(
        node: LayoutNode,
        windowsByID: [WindowID: ManagedWindow],
        preferredWindowID: WindowID?
    ) -> Bool {
        if let windowID = node.windowID {
            if let preferredWindowID {
                return preferredWindowID == windowID
            }
            return windowsByID[windowID]?.isFocused == true
        }

        return (node.first.map {
            subtreeContainsPriorityWindow(
                node: $0,
                windowsByID: windowsByID,
                preferredWindowID: preferredWindowID
            )
        } ?? false)
            || (node.second.map {
                subtreeContainsPriorityWindow(
                    node: $0,
                    windowsByID: windowsByID,
                    preferredWindowID: preferredWindowID
                )
            } ?? false)
    }

    private func insertWindow(
        _ windowID: WindowID,
        into root: inout LayoutNode?,
        preferredFocusWindowID: WindowID?,
        preferredPoint: CGPoint? = nil,
        visibleFrame: CGRect,
        preferredSplitAxis: SplitAxis? = nil
    ) {
        guard let existingRoot = root else {
            root = LayoutNode(windowID: windowID)
            return
        }

        let currentFrames = leafFrames(root: existingRoot, rect: visibleFrame)
        let preferredLeaf = preferredFocusWindowID.flatMap { existingRoot.leafNode(for: $0) }
        let targetLeaf = leafForInsertion(
            root: existingRoot,
            frames: currentFrames,
            preferredLeaf: preferredLeaf,
            preferredPoint: preferredPoint
        )
        guard let leaf = targetLeaf else {
            root = LayoutNode(windowID: windowID)
            return
        }

        let targetFrame = leaf.windowID.flatMap { currentFrames[$0] } ?? visibleFrame
        let splitAxis = preferredSplitAxis ?? (targetFrame.width >= targetFrame.height ? .vertical : .horizontal)
        let previousParent = leaf.parent
        let leafWasFirstChild = previousParent?.first === leaf
        let dropBeforeTarget = insertionPrefersLeadingHalf(
            point: preferredPoint,
            axis: splitAxis,
            frame: targetFrame
        )
        let firstNode: LayoutNode
        let secondNode: LayoutNode

        if dropBeforeTarget {
            firstNode = LayoutNode(windowID: windowID)
            secondNode = leaf
        } else {
            firstNode = leaf
            secondNode = LayoutNode(windowID: windowID)
        }

        let replacement = LayoutNode(
            axis: splitAxis,
            ratio: 0.5,
            first: firstNode,
            second: secondNode
        )

        replace(
            with: replacement,
            previousParent: previousParent,
            leafWasFirstChild: leafWasFirstChild,
            root: &root
        )
    }

    private func replace(
        with replacement: LayoutNode,
        previousParent: LayoutNode?,
        leafWasFirstChild: Bool,
        root: inout LayoutNode?
    ) {
        replacement.parent = previousParent

        if let previousParent {
            if leafWasFirstChild {
                previousParent.first = replacement
            } else {
                previousParent.second = replacement
            }
        } else {
            root = replacement
        }
    }

    private func leafForInsertion(
        root: LayoutNode,
        frames: [WindowID: CGRect],
        preferredLeaf: LayoutNode?,
        preferredPoint: CGPoint?
    ) -> LayoutNode? {
        if let preferredLeaf {
            return preferredLeaf
        }

        guard let preferredPoint else {
            return root.trailingLeaf() ?? root.firstLeaf()
        }

        let containingLeaf = frames.first { _, frame in
            frame.insetBy(dx: -8, dy: -8).contains(preferredPoint)
        }.flatMap { root.leafNode(for: $0.key) }

        if let containingLeaf {
            return containingLeaf
        }

        return frames.min { lhs, rhs in
            lhs.value.center.distanceSquared(to: preferredPoint) < rhs.value.center.distanceSquared(to: preferredPoint)
        }.flatMap { root.leafNode(for: $0.key) }
    }

    private func insertionPrefersLeadingHalf(
        point: CGPoint?,
        axis: SplitAxis,
        frame: CGRect
    ) -> Bool {
        guard let point else {
            return false
        }

        switch axis {
        case .vertical:
            return point.x < frame.midX
        case .horizontal:
            return point.y > frame.midY
        }
    }

    private func pruneTree(_ node: LayoutNode?, validWindowIDs: Set<WindowID>) -> LayoutNode? {
        guard let node else {
            return nil
        }

        if let windowID = node.windowID {
            return validWindowIDs.contains(windowID) ? node : nil
        }

        let first = pruneTree(node.first, validWindowIDs: validWindowIDs)
        let second = pruneTree(node.second, validWindowIDs: validWindowIDs)

        switch (first, second) {
        case let (first?, second?):
            node.first = first
            node.second = second
            first.parent = node
            second.parent = node
            return node
        case let (first?, nil):
            first.parent = node.parent
            return first
        case let (nil, second?):
            second.parent = node.parent
            return second
        case (nil, nil):
            return nil
        }
    }

    private func assignFrames(
        node: LayoutNode,
        rect: CGRect,
        windowsByID: [WindowID: ManagedWindow] = [:],
        storage: inout [WindowID: CGRect]
    ) {
        if let windowID = node.windowID {
            storage[windowID] = rect.standardizedFrame
            return
        }

        guard let axis = node.axis,
              let first = node.first,
              let second = node.second else {
            return
        }

        switch axis {
        case .vertical:
            let firstWidth = max(1, round(rect.width * node.ratio))
            let secondWidth = max(1, rect.width - firstWidth)
            let firstTargetWidth = windowsByID.isEmpty ? firstWidth : max(firstWidth, minimumWidth(node: first, windowsByID: windowsByID))
            let secondTargetWidth = windowsByID.isEmpty ? secondWidth : max(secondWidth, minimumWidth(node: second, windowsByID: windowsByID))
            let firstRect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: firstTargetWidth,
                height: rect.height
            )
            let secondRect = CGRect(
                x: rect.minX + firstWidth,
                y: rect.minY,
                width: secondTargetWidth,
                height: rect.height
            )
            assignFrames(node: first, rect: firstRect, windowsByID: windowsByID, storage: &storage)
            assignFrames(node: second, rect: secondRect, windowsByID: windowsByID, storage: &storage)
        case .horizontal:
            let firstHeight = max(1, round(rect.height * node.ratio))
            let secondHeight = max(1, rect.height - firstHeight)
            let firstTargetHeight = windowsByID.isEmpty ? firstHeight : max(firstHeight, minimumHeight(node: first, windowsByID: windowsByID))
            let secondTargetHeight = windowsByID.isEmpty ? secondHeight : max(secondHeight, minimumHeight(node: second, windowsByID: windowsByID))
            let secondRect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: secondTargetHeight
            )
            let firstRect = CGRect(
                x: rect.minX,
                y: rect.minY + secondHeight,
                width: rect.width,
                height: firstTargetHeight
            )
            assignFrames(node: first, rect: firstRect, windowsByID: windowsByID, storage: &storage)
            assignFrames(node: second, rect: secondRect, windowsByID: windowsByID, storage: &storage)
        }
    }

    private func leafFrames(root: LayoutNode, rect: CGRect) -> [WindowID: CGRect] {
        var results: [WindowID: CGRect] = [:]
        assignFrames(node: root, rect: rect, storage: &results)
        return results
    }

    private func nodeFrames(root: LayoutNode, rect: CGRect) -> [ObjectIdentifier: CGRect] {
        var results: [ObjectIdentifier: CGRect] = [:]
        collectNodeFrames(node: root, rect: rect, storage: &results)
        return results
    }

    private func collectNodeFrames(node: LayoutNode, rect: CGRect, storage: inout [ObjectIdentifier: CGRect]) {
        storage[ObjectIdentifier(node)] = rect

        guard let axis = node.axis,
              let first = node.first,
              let second = node.second else {
            return
        }

        switch axis {
        case .vertical:
            let firstWidth = max(1, round(rect.width * node.ratio))
            let secondWidth = max(1, rect.width - firstWidth)
            collectNodeFrames(
                node: first,
                rect: CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height),
                storage: &storage
            )
            collectNodeFrames(
                node: second,
                rect: CGRect(x: rect.minX + firstWidth, y: rect.minY, width: secondWidth, height: rect.height),
                storage: &storage
            )
        case .horizontal:
            let firstHeight = max(1, round(rect.height * node.ratio))
            let secondHeight = max(1, rect.height - firstHeight)
            collectNodeFrames(
                node: first,
                rect: CGRect(x: rect.minX, y: rect.minY + secondHeight, width: rect.width, height: firstHeight),
                storage: &storage
            )
            collectNodeFrames(
                node: second,
                rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: secondHeight),
                storage: &storage
            )
        }
    }

    private func ratioBounds(
        for node: LayoutNode,
        ancestorFrame: CGRect,
        windowsByID: [WindowID: ManagedWindow]
    ) -> (lower: CGFloat, upper: CGFloat) {
        guard let axis = node.axis,
              let first = node.first,
              let second = node.second else {
            return (0.15, 0.85)
        }

        switch axis {
        case .vertical:
            let firstMin = minimumWidth(node: first, windowsByID: windowsByID)
            let secondMin = minimumWidth(node: second, windowsByID: windowsByID)
            return clampedRatioBounds(
                lower: firstMin / max(ancestorFrame.width, 1),
                upper: 1 - (secondMin / max(ancestorFrame.width, 1))
            )
        case .horizontal:
            let firstMin = minimumHeight(node: first, windowsByID: windowsByID)
            let secondMin = minimumHeight(node: second, windowsByID: windowsByID)
            return clampedRatioBounds(
                lower: firstMin / max(ancestorFrame.height, 1),
                upper: 1 - (secondMin / max(ancestorFrame.height, 1))
            )
        }
    }

    private func clampedRatioBounds(lower: CGFloat, upper: CGFloat) -> (lower: CGFloat, upper: CGFloat) {
        let lowerBound = max(0.1, min(0.9, lower))
        let upperBound = min(0.9, max(0.1, upper))

        if lowerBound >= upperBound {
            return (0.1, 0.9)
        }
        return (lowerBound, upperBound)
    }

    private func minimumWidth(node: LayoutNode, windowsByID: [WindowID: ManagedWindow]) -> CGFloat {
        if let windowID = node.windowID {
            return windowsByID[windowID]?.minimumSize.width ?? 240
        }

        guard let axis = node.axis,
              let first = node.first,
              let second = node.second else {
            return 240
        }

        switch axis {
        case .vertical:
            return minimumWidth(node: first, windowsByID: windowsByID) + minimumWidth(node: second, windowsByID: windowsByID)
        case .horizontal:
            return max(minimumWidth(node: first, windowsByID: windowsByID), minimumWidth(node: second, windowsByID: windowsByID))
        }
    }

    private func minimumHeight(node: LayoutNode, windowsByID: [WindowID: ManagedWindow]) -> CGFloat {
        if let windowID = node.windowID {
            return windowsByID[windowID]?.minimumSize.height ?? 160
        }

        guard let axis = node.axis,
              let first = node.first,
              let second = node.second else {
            return 160
        }

        switch axis {
        case .vertical:
            return max(minimumHeight(node: first, windowsByID: windowsByID), minimumHeight(node: second, windowsByID: windowsByID))
        case .horizontal:
            return minimumHeight(node: first, windowsByID: windowsByID) + minimumHeight(node: second, windowsByID: windowsByID)
        }
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    var standardizedFrame: CGRect {
        CGRect(
            x: origin.x.rounded(.down),
            y: origin.y.rounded(.down),
            width: max(1, size.width.rounded(.down)),
            height: max(1, size.height.rounded(.down))
        )
    }
}

private extension CGPoint {
    func distanceSquared(to other: CGPoint) -> CGFloat {
        let deltaX = x - other.x
        let deltaY = y - other.y
        return (deltaX * deltaX) + (deltaY * deltaY)
    }
}
