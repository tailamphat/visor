import AppKit
import VisorCore

/// Records what you copy, and copies, pastes, pins and deletes from history.
///
/// macOS doesn't announce clipboard changes, so the clipboard's change counter
/// is read about once a second (a microsecond check) and again whenever you
/// switch apps. Everything stays on this Mac, in Visor's folder.
@MainActor
final class ClipboardService {
    private let model: AppModel
    private let pasteboard = NSPasteboard.general
    private var lastCount: Int
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?
    private var undoWork: DispatchWorkItem?
    /// The history item that is on the macOS clipboard right now.
    private var currentID: UUID?
    private var lastRemoved: (removed: ClipHistory.Removed, clearedClipboard: Bool)?

    static var fileURL: URL { HookServer.directory.appendingPathComponent("clipboard.json") }
    static var imagesURL: URL { HookServer.directory.appendingPathComponent("Clips", isDirectory: true) }

    /// Apps whose copies are never kept (set in Visor's preferences file).
    private var excluded: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "clipboardExcludedApps") ?? [])
    }

    init(model: AppModel) {
        self.model = model
        lastCount = NSPasteboard.general.changeCount
    }

    func start() {
        if let data = try? Data(contentsOf: Self.fileURL), let saved = try? JSONDecoder().decode(ClipHistory.self, from: data) {
            model.clips = saved
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = 0.3
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    // MARK: Recording

    private func check() {
        let count = pasteboard.changeCount
        guard count != lastCount else { return }
        lastCount = count
        let front = NSWorkspace.shared.frontmostApplication
        let types = pasteboard.types?.map(\.rawValue) ?? []
        guard ClipHistory.shouldRecord(types: types, app: front?.bundleIdentifier, excluded: excluded),
              let item = read(app: front?.localizedName ?? "Unknown") else { return }
        var history = model.clips
        history.add(item, now: Date())
        currentID = history.items.first?.id
        model.clips = history
        save()
    }

    /// Files, then text (links and colours included), then images.
    private func read(app: String) -> ClipItem? {
        let now = Date()
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return ClipItem(kind: .file, content: urls.map(\.path).joined(separator: "\n"), app: app, date: now)
        }
        if let text = pasteboard.string(forType: .string) {
            return ClipItem(kind: ClipItem.kind(of: text), content: text, app: app, date: now)
        }
        if let image = NSImage(pasteboard: pasteboard), let png = Self.png(image) {
            let name = "\(UUID().uuidString).png"
            try? FileManager.default.createDirectory(at: Self.imagesURL, withIntermediateDirectories: true)
            guard (try? png.write(to: Self.imagesURL.appendingPathComponent(name))) != nil else { return nil }
            return ClipItem(kind: .image, content: name, app: app, date: now)
        }
        return nil
    }

    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Actions

    /// Puts an item back on the clipboard and at the top of the history.
    func copy(_ item: ClipItem, plain: Bool = false) {
        pasteboard.clearContents()
        switch item.kind {
        case .file where !plain:
            pasteboard.writeObjects(item.content.split(separator: "\n").map { URL(fileURLWithPath: String($0)) as NSURL })
        case .image where !plain:
            if let data = try? Data(contentsOf: Self.imagesURL.appendingPathComponent(item.content)) {
                pasteboard.setData(data, forType: .png)
            }
        default:
            pasteboard.setString(item.content, forType: .string)
        }
        lastCount = pasteboard.changeCount
        var history = model.clips
        var again = item
        again.date = Date()
        history.add(again, now: Date())
        currentID = history.items.first?.id
        model.clips = history
        save()
    }

    /// Copies, then presses ⌘V in the app you were using (Visor never takes
    /// focus from it). Without Accessibility it just copies.
    func paste(_ item: ClipItem, plain: Bool = false, close: () -> Void) {
        copy(item, plain: plain)
        close()
        guard MediaKeys.isAllowed else {
            MediaKeys.requestPermission()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let source = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: down) // V
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    func togglePin(_ id: UUID) {
        var history = model.clips
        history.togglePin(id)
        model.clips = history
        save()
    }

    /// Deletes from history; the item on the clipboard right now is cleared
    /// from the macOS clipboard too. Undo is offered for a few seconds.
    func delete(_ id: UUID) {
        var history = model.clips
        guard let removed = history.delete(id) else { return }
        let cleared = id == currentID
        if cleared {
            pasteboard.clearContents()
            lastCount = pasteboard.changeCount
            currentID = nil
        }
        model.clips = history
        offerUndo(removed, cleared: cleared)
        save()
    }

    func undo() {
        guard let last = lastRemoved else { return }
        var history = model.clips
        history.restore(last.removed)
        model.clips = history
        if last.clearedClipboard {
            // Back on the clipboard, without moving it in the list.
            pasteboard.clearContents()
            pasteboard.setString(last.removed.item.content, forType: .string)
            lastCount = pasteboard.changeCount
            currentID = last.removed.item.id
        }
        lastRemoved = nil
        model.clipUndo = nil
        save()
    }

    /// Empties the history and the macOS clipboard; pinned items stay unless asked.
    func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "This also clears what is on the clipboard now. It can't be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Also remove pinned items"
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var history = model.clips
        history.clear(keepPinned: alert.suppressionButton?.state != .on)
        model.clips = history
        pasteboard.clearContents()
        lastCount = pasteboard.changeCount
        currentID = nil
        save()
    }

    func isOnClipboard(_ id: UUID) -> Bool { id == currentID }

    private func offerUndo(_ removed: ClipHistory.Removed, cleared: Bool) {
        lastRemoved = (removed, cleared)
        model.clipUndo = cleared ? "Deleted · also cleared from the clipboard" : "Deleted"
        undoWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.lastRemoved = nil
                self?.model.clipUndo = nil
                self?.save()
            }
        }
        undoWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    // MARK: Saving

    /// Writes the history a moment after the last change, and removes image
    /// files nothing points to (unless an undo could still need them).
    private func save() {
        saveWork?.cancel()
        let history = model.clips
        let keep = Set(history.items.filter { $0.kind == .image }.map(\.content) + [lastRemoved?.removed.item.content].compactMap { $0 })
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(history) else { return }
            try? FileManager.default.createDirectory(at: HookServer.directory, withIntermediateDirectories: true)
            try? data.write(to: Self.fileURL, options: .atomic)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.imagesURL.path)) ?? []
            for file in files where !keep.contains(file) {
                try? FileManager.default.removeItem(at: Self.imagesURL.appendingPathComponent(file))
            }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
