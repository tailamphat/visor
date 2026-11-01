import AppKit
import SwiftUI

/// A borderless panel over the notch that never takes focus from your work.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar + 1
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Places the panel on the notched screen and expands it while the pointer is
/// over the notch. Hover is tracked with event monitors instead of the window,
/// so the collapsed notch never blocks a click.
@MainActor
final class NotchController {
    private let model: AppModel
    private let panel = NotchPanel()
    private var layout = NotchLayout(notch: CGSize(width: 185, height: 32))
    private var hosting: NSHostingView<NotchView>?
    private var monitors: [Any] = []
    private var collapseWork: DispatchWorkItem?
    /// While the mouse button is down: is something (a file, a link) being dragged?
    private var dragWatch: Timer?
    private var dragBase = 0
    private(set) var dragging = false
    /// Opened from the keyboard (⌘⇧V): stays open until Esc, a paste, or a click elsewhere.
    private(set) var keyboardOpen = false
    private var expandWork: DispatchWorkItem?

    var onExpand: ((Tab) -> Void)?

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        place()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
        // Dragging a file or link over the closed notch opens the Bar tab, ready for the drop.
        if let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.watchForDrag() }
        }) {
            monitors.append(down)
        }
        observe()
    }

    /// Runs only while the mouse button is held, 20 times a second.
    private func watchForDrag() {
        dragBase = NSPasteboard(name: .drag).changeCount
        dragging = false
        dragWatch?.invalidate()
        dragWatch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragTick() }
        }
    }

    private func dragTick() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            dragWatch?.invalidate()
            dragWatch = nil
            dragging = false
            return
        }
        guard NSPasteboard(name: .drag).changeCount != dragBase else { return }
        dragging = true
        guard !model.expanded else { return }
        var zone = notchRect().insetBy(dx: -10, dy: 0)
        zone.size.height += 6
        if zone.contains(NSEvent.mouseLocation) {
            model.tab = .bar
            expand()
        }
    }

    /// Re-applies window state whenever `expanded` changes, wherever it changed.
    private func observe() {
        withObservationTracking {
            _ = model.expanded
            _ = layout.size(for: model)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.panel.ignoresMouseEvents = !self.model.expanded
                    self.fitWindow()
                    self.observe()
                }
            }
        }
    }

    private var shrinkWork: DispatchWorkItem?
    private var shrinkTarget: CGFloat?

    /// Keeps the window just tall enough for the panel (plus its shadow), so the
    /// see-through part under a short panel never blocks clicks. It grows at
    /// once and shrinks after the panel's closing animation.
    private func fitWindow() {
        let wanted = min(NotchLayout.windowSize.height, layout.size(for: model).height + 28)
        let frame = panel.frame
        guard abs(frame.height - wanted) > 0.5 else { return }
        let apply = { [weak self] in
            guard let self else { return }
            let f = self.panel.frame
            self.panel.setFrame(NSRect(x: f.minX, y: f.maxY - wanted, width: f.width, height: wanted), display: true)
        }
        if wanted > frame.height {
            shrinkWork?.cancel()
            shrinkTarget = nil
            apply()
        } else if shrinkTarget != wanted {
            // Don't restart a pending shrink to the same height (agent activity
            // changes the model often while the notch closes).
            shrinkWork?.cancel()
            shrinkTarget = wanted
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.shrinkTarget = nil
                    apply()
                }
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    /// The screen with a notch, else the main screen with a notch-sized pill.
    private func place() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        var notch = CGSize(width: 185, height: max(24, screen.frame.maxY - screen.visibleFrame.maxY))
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        layout = NotchLayout(notch: notch)
        let size = CGSize(width: NotchLayout.windowSize.width, height: min(NotchLayout.windowSize.height, layout.size(for: model).height + 28))
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: false)
        let view = NotchView(model: model, layout: layout)
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            // The window has a fixed size; SwiftUI must never resize it.
            hosting.sizingOptions = []
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.autoresizingMask = [.width, .height]
            panel.contentView = hosting
            self.hosting = hosting
        }
    }

    /// The notch's current outline in screen coordinates.
    private func notchRect() -> NSRect {
        let size = layout.size(for: model)
        let frame = panel.frame
        return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
    }

    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        if model.expanded {
            if notchRect().insetBy(dx: -6, dy: -6).contains(point) {
                collapseWork?.cancel()
                collapseWork = nil
            } else if collapseWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.collapseWork = nil
                        // An approval stays open until it's answered.
                        guard self.model.approvals.isEmpty, !self.model.pinned, !self.dragging, !self.keyboardOpen else { return }
                        self.model.expanded = false
                    }
                }
                collapseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            }
        } else {
            // Extend the hot zone above the screen edge so slamming the pointer up works.
            var zone = notchRect().insetBy(dx: -4, dy: 0)
            zone.size.height += 4
            if zone.contains(point) {
                guard expandWork == nil else { return }
                // A short dwell so sweeping across the menu bar doesn't pop it open.
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.expandWork = nil
                        var zone = self.notchRect().insetBy(dx: -4, dy: 0)
                        zone.size.height += 4
                        guard zone.contains(NSEvent.mouseLocation) else { return }
                        self.expand()
                    }
                }
                expandWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
            } else {
                expandWork?.cancel()
                expandWork = nil
            }
        }
    }

    /// Opens on a tab and takes the keyboard, without taking focus from your app
    /// (the panel is non-activating, so paste still lands where you were).
    func openWithKeyboard(_ tab: Tab) {
        model.tab = tab
        expand()
        keyboardOpen = true
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        keyboardOpen = false
        panel.resignKey()
        model.expanded = false
    }

    /// A click outside closes a keyboard-opened panel.
    func clickedAt(_ point: NSPoint) {
        guard keyboardOpen, !notchRect().insetBy(dx: -6, dy: -6).contains(point) else { return }
        close()
    }

    func expand() {
        guard !model.expanded else { return }
        model.expanded = true
        panel.ignoresMouseEvents = false
        onExpand?(model.tab)
    }

    /// Collapses unless the pointer is still over the panel.
    func collapseIfAway() {
        guard model.expanded, model.approvals.isEmpty else { return }
        if !notchRect().insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) { model.expanded = false }
    }
}
