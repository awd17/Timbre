import AppKit
import CoreGraphics
import SwiftUI

struct DictationIndicatorPlacement: Codable, Equatable {
    let displayIdentifier: String
    let relativeX: Double
    let relativeY: Double
    let absoluteCenterX: Double
    let absoluteCenterY: Double
}

final class DictationIndicatorPlacementStore {
    static let key = "timbre.dictationIndicatorPlacement"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> DictationIndicatorPlacement? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(DictationIndicatorPlacement.self, from: data)
    }

    func reset() {
        defaults.removeObject(forKey: Self.key)
    }

    func save(frame: NSRect, on screen: NSScreen) {
        let visibleFrame = screen.visibleFrame
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return }
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let placement = DictationIndicatorPlacement(
            displayIdentifier: screen.timbreDisplayIdentifier,
            relativeX: (center.x - visibleFrame.minX) / visibleFrame.width,
            relativeY: (center.y - visibleFrame.minY) / visibleFrame.height,
            absoluteCenterX: center.x,
            absoluteCenterY: center.y
        )
        guard let data = try? JSONEncoder().encode(placement) else { return }
        defaults.set(data, forKey: Self.key)
    }

    static func restoredFrame(
        size: NSSize,
        placement: DictationIndicatorPlacement?,
        screens: [NSScreen],
        pointerLocation: NSPoint
    ) -> NSRect? {
        guard !screens.isEmpty else { return nil }

        if let placement,
           let storedScreen = screens.first(where: {
               $0.timbreDisplayIdentifier == placement.displayIdentifier
           })
        {
            let visible = storedScreen.visibleFrame
            let center = NSPoint(
                x: visible.minX + visible.width * min(max(placement.relativeX, 0), 1),
                y: visible.minY + visible.height * min(max(placement.relativeY, 0), 1)
            )
            return clampedFrame(centeredAt: center, size: size, in: visible)
        }

        if let placement {
            let savedCenter = NSPoint(
                x: placement.absoluteCenterX,
                y: placement.absoluteCenterY
            )
            let nearest = screens.min {
                distance(from: savedCenter, to: $0.visibleFrame)
                    < distance(from: savedCenter, to: $1.visibleFrame)
            } ?? screens[0]
            return clampedFrame(centeredAt: savedCenter, size: size, in: nearest.visibleFrame)
        }

        let pointerScreen = screens.first { NSMouseInRect(pointerLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? screens[0]
        let visible = pointerScreen.visibleFrame
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.minY + 48,
            width: size.width,
            height: size.height
        )
    }

    static func clampedFrame(
        centeredAt center: NSPoint,
        size: NSSize,
        in visibleFrame: NSRect
    ) -> NSRect {
        let margin: CGFloat = 8
        let usable = visibleFrame.insetBy(dx: margin, dy: margin)
        let originX = min(
            max(center.x - size.width / 2, usable.minX),
            max(usable.minX, usable.maxX - size.width)
        )
        let originY = min(
            max(center.y - size.height / 2, usable.minY),
            max(usable.minY, usable.maxY - size.height)
        )
        return NSRect(origin: NSPoint(x: originX, y: originY), size: size)
    }

    private static func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let x = min(max(point.x, rect.minX), rect.maxX)
        let y = min(max(point.y, rect.minY), rect.maxY)
        return hypot(point.x - x, point.y - y)
    }
}

@MainActor
final class DictationIndicatorWindowController: NSObject, NSWindowDelegate {
    private static let panelSize = NSSize(width: 84, height: 40)
    private static let minimumPreparingNanoseconds: UInt64 = 250_000_000

    private let controller: AssistantController
    private let placementStore: DictationIndicatorPlacementStore
    private let viewModel = DictationIndicatorViewModel()
    private var panel: DictationIndicatorPanel?
    private var dismissalTask: Task<Void, Never>?
    private var phaseTransitionTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var isSessionVisible = false
    private var isApplyingFrame = false
    private var isObserving = false
    private var preparingPresentedAt: UInt64?

    init(
        controller: AssistantController,
        placementStore: DictationIndicatorPlacementStore
    ) {
        self.controller = controller
        self.placementStore = placementStore
        super.init()
    }

    func start() {
        guard !isObserving else { return }
        isObserving = true
        controller.setSessionStateHandler { [weak self] state in
            self?.reconcile(state)
        }
        reconcile(controller.sessionState)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.restoreOrClampPanelPosition()
            }
        }
    }

    func stop() {
        isObserving = false
        controller.setSessionStateHandler(nil)
        dismissalTask?.cancel()
        dismissalTask = nil
        phaseTransitionTask?.cancel()
        phaseTransitionTask = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        panel?.orderOut(nil)
    }

    func resetPlacement() {
        placementStore.reset()
        guard let panel else { return }
        let frame = DictationIndicatorPlacementStore.restoredFrame(
            size: Self.panelSize,
            placement: nil,
            screens: NSScreen.screens,
            pointerLocation: NSEvent.mouseLocation
        )
        guard let frame else { return }
        isApplyingFrame = true
        panel.setFrame(frame, display: panel.isVisible)
        isApplyingFrame = false
    }

    private func reconcile(_ state: SessionState) {
        dismissalTask?.cancel()
        dismissalTask = nil
        phaseTransitionTask?.cancel()
        phaseTransitionTask = nil

        let presentation = DictationIndicatorPresentation.presentation(for: state)
        switch state {
        case .idle:
            hide()
        case .preparing:
            isSessionVisible = true
            preparingPresentedAt = DispatchTime.now().uptimeNanoseconds
            present(presentation)
        case .listening:
            isSessionVisible = true
            presentListeningAfterPreparingDwell()
        case .finishing:
            guard isSessionVisible else { return }
            preparingPresentedAt = nil
            present(presentation)
        case .completed:
            guard isSessionVisible else { return }
            guard presentation != .hidden else {
                hide()
                return
            }
            let duration: Duration =
                presentation == .copied
                ? .milliseconds(450)
                : .milliseconds(1500)
            presentResult(presentation, duration: duration)
        case .failed:
            guard isSessionVisible else { return }
            guard presentation != .hidden else {
                hide()
                return
            }
            presentResult(presentation, duration: .milliseconds(1500))
        }
    }

    private func present(_ presentation: DictationIndicatorPresentation) {
        // Set the state before creating or revealing the hosting surface. In
        // particular, the first-ever panel must be born with preparing content
        // rather than rendering one frame of the default hidden state.
        viewModel.presentation = presentation
        let panel = makePanelIfNeeded()
        if !panel.isVisible {
            restoreOrClampPanelPosition()
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()
        panel.orderFrontRegardless()
        announce(presentation.accessibilityLabel)
    }

    private func presentListeningAfterPreparingDwell() {
        guard let preparingPresentedAt else {
            present(.listening)
            return
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - preparingPresentedAt
        guard elapsed < Self.minimumPreparingNanoseconds else {
            self.preparingPresentedAt = nil
            present(.listening)
            return
        }

        let remaining = Self.minimumPreparingNanoseconds - elapsed
        phaseTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: remaining)
            guard !Task.isCancelled, let self else { return }
            guard case .listening = self.controller.sessionState else { return }
            self.preparingPresentedAt = nil
            self.present(.listening)
        }
    }

    private func presentResult(
        _ presentation: DictationIndicatorPresentation,
        duration: Duration
    ) {
        present(presentation)
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        dismissalTask?.cancel()
        dismissalTask = nil
        isSessionVisible = false
        preparingPresentedAt = nil
        phaseTransitionTask?.cancel()
        phaseTransitionTask = nil
        viewModel.presentation = .hidden
        panel?.orderOut(nil)
    }

    private func makePanelIfNeeded() -> DictationIndicatorPanel {
        if let panel { return panel }

        let panel = DictationIndicatorPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let hostingView = DraggableHostingView(
            rootView: DictationIndicatorView(
                controller: controller,
                model: viewModel
            )
        )
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView
        panel.setAccessibilityIdentifier("dictationIndicatorPanel")
        self.panel = panel
        return panel
    }

    private func restoreOrClampPanelPosition() {
        guard let panel else { return }
        let frame = DictationIndicatorPlacementStore.restoredFrame(
            size: Self.panelSize,
            placement: placementStore.load(),
            screens: NSScreen.screens,
            pointerLocation: NSEvent.mouseLocation
        )
        guard let frame else { return }
        isApplyingFrame = true
        panel.setFrame(frame, display: false)
        isApplyingFrame = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingFrame, let panel else { return }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(center, $0.frame, false)
        }) ?? panel.screen else {
            return
        }
        placementStore.save(frame: panel.frame, on: screen)
    }

    private func announce(_ message: String) {
        guard !message.isEmpty else { return }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

private final class DictationIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
}

private extension NSScreen {
    var timbreDisplayIdentifier: String {
        guard
            let number = deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else {
            return localizedName
        }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
