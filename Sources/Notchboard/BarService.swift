import AppKit
import IOKit.ps
import NotchboardCore

/// Keeps the user's bar: saves it, opens what's in it, and reads the live
/// widgets. Widgets are only sampled while the Bar tab is on screen.
@MainActor
final class BarService {
    private let model: AppModel
    private let work = DispatchQueue(label: "notchboard.bar", qos: .userInitiated)
    private var sampler: Timer?
    private var lastCPU: host_cpu_load_info?

    nonisolated static var fileURL: URL { HookServer.directory.appendingPathComponent("bar.json") }

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        if let data = try? Data(contentsOf: Self.fileURL), let saved = try? JSONDecoder().decode(BarLayout.self, from: data) {
            model.bar = saved
        } else {
            model.bar = .starter
        }
        loadShortcuts()
    }

    private func save() {
        let bar = model.bar
        work.async {
            guard let data = try? JSONEncoder().encode(bar) else { return }
            try? FileManager.default.createDirectory(at: HookServer.directory, withIntermediateDirectories: true)
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    // MARK: Editing

    /// Adds dropped files or links, starting at `index`.
    func add(urls: [URL], at index: Int?) {
        var at = index
        var added: [String] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            if url.isFileURL { FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) }
            // An .app bundle is a directory, but it's an app.
            guard let item = BarItem.dropped(url, isDirectory: isDirectory.boolValue) else { continue }
            if model.bar.add(item, at: at) {
                added.append(item.name)
                at = at.map { $0 + 1 }
            }
        }
        if !added.isEmpty { save() }
    }

    func add(_ item: BarItem, at index: Int? = nil) {
        if model.bar.add(item, at: index) { save() }
    }

    /// The browser to take "the current tab" from: the frontmost app when it's
    /// a browser (clicking the notch doesn't change it), else any running one.
    func currentBrowser() -> (id: String, name: String)? {
        let browsers = MusicService.chromium + [MusicService.safari]
        let front = NSWorkspace.shared.frontmostApplication
        let app = front.flatMap { f in browsers.contains(f.bundleIdentifier ?? "") ? f : nil }
            ?? NSWorkspace.shared.runningApplications.first { browsers.contains($0.bundleIdentifier ?? "") }
        guard let app, let id = app.bundleIdentifier else { return nil }
        return (id, app.localizedName ?? "Browser")
    }

    /// Adds the tab that's open in the browser, named by its page title.
    func addCurrentTab() {
        guard let browser = currentBrowser() else { return }
        let tab = browser.id == MusicService.safari ? "current tab of front window" : "active tab of front window"
        let title = browser.id == MusicService.safari ? "name" : "title"
        let source = "tell application id \"\(browser.id)\" to return {URL of \(tab), \(title) of \(tab)}"
        work.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard error == nil, let list = result, list.numberOfItems >= 1,
                  let address = list.atIndex(1)?.stringValue, let url = URL(string: address),
                  var item = BarItem.dropped(url, isDirectory: false) else { return }
            if let pageTitle = list.atIndex(2)?.stringValue, !pageTitle.isEmpty {
                item.name = pageTitle.count > 40 ? String(pageTitle.prefix(39)) + "…" : pageTitle
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.add(item) } }
        }
    }

    func move(_ id: UUID, to index: Int) {
        model.bar.move(id, to: index)
        save()
    }

    func remove(_ id: UUID) {
        model.bar.remove(id)
        save()
    }

    // MARK: Using

    func open(_ item: BarItem) {
        switch item.kind {
        case .app, .file, .folder:
            NSWorkspace.shared.open(URL(fileURLWithPath: item.target))
        case .link:
            if let url = URL(string: item.target) { NSWorkspace.shared.open(url) }
        case .shortcut:
            runShortcut(item.target)
        case .widget:
            switch item.widget {
            case .timer:
                if let end = model.timerEnds {
                    model.timerPaused = end.timeIntervalSinceNow
                    model.timerEnds = nil
                } else {
                    model.timerEnds = Date().addingTimeInterval(model.timerPaused ?? 25 * 60)
                    model.timerPaused = nil
                }
            case .cpu:
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            case .battery:
                if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(url) }
            case .clock, .none:
                break
            }
        }
    }

    /// A file dropped on an app tile opens with that app.
    func open(_ files: [URL], with app: BarItem) {
        NSWorkspace.shared.open(files, withApplicationAt: URL(fileURLWithPath: app.target),
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    func revealInFinder(_ item: BarItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.target)])
    }

    func resetTimer() {
        model.timerEnds = nil
        model.timerPaused = nil
    }

    private func runShortcut(_ name: String) {
        work.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]
            try? process.run()
        }
    }

    /// The user's Shortcuts, for the + menu.
    private func loadShortcuts() {
        work.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.model.shortcutNames = names.sorted() } }
        }
    }

    // MARK: Live widgets

    /// Samples CPU and battery every 2 s, only while the bar is showing.
    func setVisible(_ visible: Bool) {
        if visible {
            guard sampler == nil else { return }
            sample()
            sampler = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            sampler?.tolerance = 0.5
        } else {
            sampler?.invalidate()
            sampler = nil
            lastCPU = nil
        }
    }

    private func sample() {
        let widgets = Set(model.bar.items.compactMap(\.widget))
        if widgets.contains(.cpu), let load = Self.cpuLoad() {
            if let last = lastCPU {
                let user = Double(load.cpu_ticks.0 &- last.cpu_ticks.0)
                let system = Double(load.cpu_ticks.1 &- last.cpu_ticks.1)
                let idle = Double(load.cpu_ticks.2 &- last.cpu_ticks.2)
                let nice = Double(load.cpu_ticks.3 &- last.cpu_ticks.3)
                let total = user + system + idle + nice
                if total > 0 { model.cpuUsage = (user + system + nice) / total }
            }
            lastCPU = load
        }
        if widgets.contains(.battery) { model.battery = Self.battery() }
    }

    private static func cpuLoad() -> host_cpu_load_info? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    private static func battery() -> (percent: Int, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            return (current * 100 / max, charging)
        }
        return nil
    }
}

/// App, file and folder icons, loaded once each.
@MainActor
enum BarIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let image = cache[path] { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 64, height: 64)
        cache[path] = image
        return image
    }
}
