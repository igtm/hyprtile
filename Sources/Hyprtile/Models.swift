import AppKit

enum AppMode: String, CaseIterable {
    case tiling
    case pause
    case monocle

    var title: String {
        switch self {
        case .tiling:
            "Tiling"
        case .pause:
            "Pause"
        case .monocle:
            "Monocle"
        }
    }
}

typealias WindowID = String

struct WindowGroupID: RawRepresentable, Hashable {
    var rawValue: String
}

struct WorkspaceID: RawRepresentable, Hashable {
    var rawValue: String
}

struct PermissionState: Equatable {
    var accessibilityGranted: Bool
    var inputMonitoringGranted: Bool

    var isReady: Bool {
        accessibilityGranted
    }
}

struct ManagedWindow: Identifiable, Hashable {
    let id: WindowID
    let applicationPID: pid_t
    let applicationName: String
    let title: String
    let element: AXUIElement
    var frame: CGRect
    var minimumSize: CGSize
    var isFocused: Bool
    var canResize: Bool
    var displayID: CGDirectDisplayID
    var cgWindowID: CGWindowID
    var zIndex: Int
    var groupHint: WindowGroupID?
    var workspaceHint: WorkspaceID?

    static func == (lhs: ManagedWindow, rhs: ManagedWindow) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct DisplayDescriptor: Identifiable, Hashable {
    let displayID: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect

    var id: CGDirectDisplayID {
        displayID
    }
}

enum SplitAxis: String, Codable {
    case vertical
    case horizontal
}

indirect enum PersistedLayoutNode: Codable, Equatable {
    case leaf(WindowID)
    case split(axis: SplitAxis, ratio: Double, first: PersistedLayoutNode, second: PersistedLayoutNode)

    func orderedLeafIDs() -> [WindowID] {
        switch self {
        case let .leaf(windowID):
            return [windowID]
        case let .split(_, _, first, second):
            return first.orderedLeafIDs() + second.orderedLeafIDs()
        }
    }
}

enum ResizeEdge: String {
    case left
    case right
    case top
    case bottom

    var axis: SplitAxis {
        switch self {
        case .left, .right:
            .vertical
        case .top, .bottom:
            .horizontal
        }
    }
}

final class LayoutNode {
    weak var parent: LayoutNode?
    var windowID: WindowID?
    var axis: SplitAxis?
    var ratio: CGFloat
    var first: LayoutNode?
    var second: LayoutNode?

    init(windowID: WindowID) {
        self.windowID = windowID
        self.ratio = 0.5
    }

    init(axis: SplitAxis, ratio: CGFloat, first: LayoutNode, second: LayoutNode) {
        self.windowID = nil
        self.axis = axis
        self.ratio = ratio
        self.first = first
        self.second = second
        first.parent = self
        second.parent = self
    }

    var isLeaf: Bool {
        windowID != nil
    }

    func orderedLeafIDs() -> [WindowID] {
        if let windowID {
            return [windowID]
        }

        var ids: [WindowID] = []
        if let first {
            ids.append(contentsOf: first.orderedLeafIDs())
        }
        if let second {
            ids.append(contentsOf: second.orderedLeafIDs())
        }
        return ids
    }

    func firstLeaf() -> LayoutNode? {
        if isLeaf {
            return self
        }
        return first?.firstLeaf() ?? second?.firstLeaf()
    }

    func trailingLeaf() -> LayoutNode? {
        if isLeaf {
            return self
        }
        return second?.trailingLeaf() ?? first?.trailingLeaf()
    }

    func leafNode(for targetWindowID: WindowID) -> LayoutNode? {
        if windowID == targetWindowID {
            return self
        }
        return first?.leafNode(for: targetWindowID) ?? second?.leafNode(for: targetWindowID)
    }

    func subtreeContains(_ node: LayoutNode) -> Bool {
        if self === node {
            return true
        }
        return first?.subtreeContains(node) == true || second?.subtreeContains(node) == true
    }

    func snapshot() -> PersistedLayoutNode {
        if let windowID {
            return .leaf(windowID)
        }

        guard let axis,
              let first,
              let second else {
            return first?.snapshot() ?? second?.snapshot() ?? .leaf("missing-window")
        }

        return .split(
            axis: axis,
            ratio: Double(ratio),
            first: first.snapshot(),
            second: second.snapshot()
        )
    }

    static func restore(from snapshot: PersistedLayoutNode) -> LayoutNode? {
        switch snapshot {
        case let .leaf(windowID):
            return LayoutNode(windowID: windowID)
        case let .split(axis, ratio, firstSnapshot, secondSnapshot):
            guard let first = restore(from: firstSnapshot),
                  let second = restore(from: secondSnapshot) else {
                return nil
            }

            return LayoutNode(
                axis: axis,
                ratio: CGFloat(ratio),
                first: first,
                second: second
            )
        }
    }
}

final class DisplayLayoutState {
    let displayID: CGDirectDisplayID
    var visibleFrame: CGRect
    var root: LayoutNode?
    var focusedWindowID: WindowID?

    init(displayID: CGDirectDisplayID, visibleFrame: CGRect, root: LayoutNode? = nil, focusedWindowID: WindowID? = nil) {
        self.displayID = displayID
        self.visibleFrame = visibleFrame
        self.root = root
        self.focusedWindowID = focusedWindowID
    }
}
