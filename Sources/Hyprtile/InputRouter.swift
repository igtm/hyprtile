import AppKit
import OSLog

@MainActor
protocol InputRouterDelegate: AnyObject {
    func inputRouter(_ router: InputRouter, windowAt point: CGPoint) -> ManagedWindow?
    func inputRouter(_ router: InputRouter, beganMoveFor window: ManagedWindow)
    func inputRouter(_ router: InputRouter, updateMoveFor window: ManagedWindow, translation: CGVector, currentPoint: CGPoint)
    func inputRouter(_ router: InputRouter, endedMoveFor window: ManagedWindow, currentPoint: CGPoint)
    func inputRouter(_ router: InputRouter, beganResizeFor window: ManagedWindow, edge: ResizeEdge)
    func inputRouter(_ router: InputRouter, updateResizeFor window: ManagedWindow, edge: ResizeEdge, translation: CGVector, currentPoint: CGPoint)
    func inputRouter(_ router: InputRouter, endedResizeFor window: ManagedWindow, edge: ResizeEdge, currentPoint: CGPoint)
}

@MainActor
final class InputRouter {
    private let logger = Logger(subsystem: "io.github.igtm.hyprtile", category: "InputRouter")

    private enum DragKind {
        case move
        case resize(ResizeEdge)
    }

    private struct DragContext {
        let window: ManagedWindow
        let startPoint: CGPoint
        let kind: DragKind
    }

    weak var delegate: InputRouterDelegate?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var dragContext: DragContext?

    var isInstalled: Bool {
        globalMonitor != nil || localMonitor != nil
    }

    func install() {
        guard !isInstalled else {
            return
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.otherMouseDown, .otherMouseDragged, .otherMouseUp]) { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .otherMouseDragged, .otherMouseUp]) { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
            return event
        }

        logger.info("Installed mouse monitors")
    }

    func uninstall() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        dragContext = nil
        globalMonitor = nil
        localMonitor = nil
        logger.info("Uninstalled mouse monitors")
    }

    private func handle(event: NSEvent) {
        switch event.type {
        case .otherMouseDown:
            handleMouseDown(event)
        case .otherMouseDragged:
            handleMouseDragged(event)
        case .otherMouseUp:
            handleMouseUp(event)
        default:
            break
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard event.buttonNumber == 2 else {
            return
        }

        let point = point(for: event)
        guard let window = delegate?.inputRouter(self, windowAt: point) else {
            return
        }

        if event.modifierFlags.contains(.option) {
            dragContext = DragContext(window: window, startPoint: point, kind: .move)
            delegate?.inputRouter(self, beganMoveFor: window)
        } else {
            let edge = resizeEdge(for: point, in: window.frame)
            dragContext = DragContext(window: window, startPoint: point, kind: .resize(edge))
            delegate?.inputRouter(self, beganResizeFor: window, edge: edge)
        }
    }

    private func handleMouseDragged(_ event: NSEvent) {
        guard let dragContext else {
            return
        }

        let point = point(for: event)
        let translation = CGVector(
            dx: point.x - dragContext.startPoint.x,
            dy: point.y - dragContext.startPoint.y
        )

        switch dragContext.kind {
        case .move:
            delegate?.inputRouter(self, updateMoveFor: dragContext.window, translation: translation, currentPoint: point)
        case let .resize(edge):
            delegate?.inputRouter(self, updateResizeFor: dragContext.window, edge: edge, translation: translation, currentPoint: point)
        }
    }

    private func handleMouseUp(_ event: NSEvent) {
        guard let dragContext else {
            return
        }

        let point = point(for: event)

        switch dragContext.kind {
        case .move:
            delegate?.inputRouter(self, endedMoveFor: dragContext.window, currentPoint: point)
        case let .resize(edge):
            delegate?.inputRouter(self, endedResizeFor: dragContext.window, edge: edge, currentPoint: point)
        }

        self.dragContext = nil
    }

    private func point(for event: NSEvent) -> CGPoint {
        event.cgEvent?.location ?? NSEvent.mouseLocation
    }

    private func resizeEdge(for point: CGPoint, in frame: CGRect) -> ResizeEdge {
        let distances: [(ResizeEdge, CGFloat)] = [
            (.left, abs(point.x - frame.minX)),
            (.right, abs(point.x - frame.maxX)),
            (.bottom, abs(point.y - frame.minY)),
            (.top, abs(point.y - frame.maxY)),
        ]

        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .right
    }
}
