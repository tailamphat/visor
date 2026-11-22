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
    /// The global pointer monitor, kept apart so it can pause while the menu bar menu is open.
    private var moveMonitor: Any?
    private var collapseWork: DispatchWorkItem?
    /// While the mouse button is down: is something (a file, a link) being dragged?
    private var dragWatch: Timer?
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragBase = 0
    /// The panel's outline, kept current by `observe()` so mouse moves don't re-run the layout.
    private var size = CGSize.zero
    private var shift: CGFloat = 0
    private(set) var dragging = false
    /// Opened from the keyboard (⌘⇧V): stays open until Esc, a paste, or a click elsewhere.
    private(set) var keyboardOpen = false
    private var expandWork: DispatchWorkItem?
    /// Holding the keyboard because the pointer is over an approval card, so
    /// Return, A and Esc answer it. Given back when the pointer leaves.
    private var cardKeys = false

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
        watchPointer(true)
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
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

    /// Follows the pointer everywhere, for hovering the notch open. Paused while
    /// Visor's menu bar menu is open: while an app watches every mouse move,
    /// macOS skips most of the highlight updates in that app's own menus, so the
    /// highlight trails the pointer.
    func watchPointer(_ on: Bool) {
        if on, moveMonitor == nil {
            moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved() }
            }
        } else if !on, let monitor = moveMonitor {
            NSEvent.removeMonitor(monitor)
            moveMonitor = nil
        }
    }

    /// Runs only while the mouse button is held over an open panel, 20 times a second.
    private func watchForDrag() {
        guard model.expanded else { return }
        dragBase = dragPasteboard.changeCount
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
        guard dragPasteboard.changeCount != dragBase else { return }
        // Keeps the panel open while something is dragged out of it.
        dragging = true
    }

    /// Re-applies window state whenever `expanded` changes, wherever it changed.
    private func observe() {
        withObservationTracking {
            _ = model.expanded
            _ = model.showsCard
            size = layout.size(for: model)
            shift = layout.shift(model)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateClickThrough()
                    self.updateCardKeys()
                    self.observe()
                }
            }
        }
    }

    /// The window keeps one size: resizing it while the panel animates drew
    /// frames where the contents and the outline were out of step. Clicks pass
    /// through everywhere except over the open panel.
    private func updateClickThrough() {
        let over = model.expanded && notchRect().insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
    }

    /// The screen with a notch, else the main screen with a notch-sized pill.
    private func place() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        var notch = CGSize(width: 185, height: max(24, screen.frame.maxY - screen.visibleFrame.maxY))
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        layout = NotchLayout(notch: notch)
        size = layout.size(for: model)
        shift = layout.shift(model)
        let windowSize = NotchLayout.windowSize
        panel.setFrame(NSRect(x: screen.frame.midX - windowSize.width / 2, y: screen.frame.maxY - windowSize.height,
                              width: windowSize.width, height: windowSize.height), display: false)
        let view = NotchView(model: model, layout: layout)
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            // The window has a fixed size; SwiftUI must never resize it.
            hosting.sizingOptions = []
            hosting.frame = NSRect(origin: .zero, size: windowSize)
            hosting.autoresizingMask = [.width, .height]
            panel.contentView = hosting
            self.hosting = hosting
        }
    }

    /// The notch's current outline in screen coordinates.
    private func notchRect() -> NSRect {
        let frame = panel.frame
        return NSRect(x: frame.midX - size.width / 2 + shift, y: frame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Takes the keyboard while the pointer is over an open approval card,
    /// and gives it back to your app as soon as it leaves or the card goes.
    private func updateCardKeys() {
        let want = model.expanded && model.showsCard && !keyboardOpen
            && notchRect().insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation)
        guard want != cardKeys else { return }
        cardKeys = want
        if want { panel.makeKey() } else if !keyboardOpen { panel.resignKey() }
    }

    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        // Most moves are nowhere near the closed notch.
        if !model.expanded, expandWork == nil, point.y < panel.frame.maxY - size.height - 40 { return }
        updateClickThrough()
        updateCardKeys()
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
                        guard !self.model.showsCard, self.model.limitBack == nil, !self.model.pinned, !self.dragging, !self.keyboardOpen else { return }
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
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
        model.clipTyping = tab == .clipboard
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        keyboardOpen = false
        model.clipTyping = false
        panel.resignKey()
        // An approval stays open until it's answered.
        guard !model.showsCard else { return }
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
        updateClickThrough()
        onExpand?(model.tab)
    }

    /// Collapses unless the pointer is still over the panel.
    func collapseIfAway() {
        guard model.expanded, !model.showsCard else { return }
        if !notchRect().insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) { model.expanded = false }
    }
}
