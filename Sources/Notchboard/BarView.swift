import NotchboardCore
import SwiftUI
import UniformTypeIdentifiers

/// The user's own bar: apps, files, folders, links, Shortcuts and widgets.
/// Drop things on it to add them; drag tiles to reorder; right-click to remove.
struct BarView: View {
    let model: AppModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(model.bar.items.enumerated()), id: \.element.id) { index, item in
                BarTile(model: model, item: item, index: index)
            }
            AddTile(model: model)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(model.barTargeted ? Theme.accent.opacity(0.14) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(model.barTargeted ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5)
        )
        .overlay(alignment: .bottom) {
            if model.bar.items.isEmpty {
                Text("Drag apps, files, folders or links here")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted).padding(.bottom, 30)
            }
        }
        // Dropping on empty space adds to the end.
        .onDrop(of: [.fileURL, .url, .text], isTargeted: Binding(get: { model.barTargeted }, set: { model.barTargeted = $0 })) { providers in
            BarDrop.handle(providers, model: model, onto: nil, index: nil)
        }
    }
}

struct BarTile: View {
    let model: AppModel
    let item: BarItem
    let index: Int

    private var targeted: Bool { model.barTargetTile == item.id }

    var body: some View {
        Button { model.barActions?.open(item) } label: {
            VStack(spacing: 5) {
                content.frame(height: 34)
                Text(item.name).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(targeted ? Theme.good.opacity(0.22) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(targeted ? Theme.good : .clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onDrag { NSItemProvider(object: "notchboard-bar:\(item.id.uuidString)" as NSString) }
        // Drop on a tile: reorder before it, open files with an app, or insert here.
        .onDrop(of: [.fileURL, .url, .text], isTargeted: Binding(
            get: { model.barTargetTile == item.id },
            set: { model.barTargetTile = $0 ? item.id : (model.barTargetTile == item.id ? nil : model.barTargetTile) }
        )) { providers in
            BarDrop.handle(providers, model: model, onto: item, index: index)
        }
        .contextMenu {
            if item.kind == .app || item.kind == .file || item.kind == .folder {
                Button("Show in Finder") { model.barActions?.revealInFinder(item) }
            }
            if item.widget == .timer {
                Button("Reset Timer") { model.barActions?.resetTimer() }
            }
            Divider()
            Button("Remove from Bar") { model.barActions?.remove(item.id) }
        }
    }

    private var help: String {
        switch item.kind {
        case .app: return "Open \(item.name) · drop a file here to open it with \(item.name)"
        case .file, .folder: return "Open \(item.name)"
        case .link: return "Open \(item.target)"
        case .shortcut: return "Run the \(item.name) shortcut"
        case .widget:
            switch item.widget {
            case .timer: return "Start or pause the timer · right-click to reset"
            case .cpu: return "Open Activity Monitor"
            case .battery: return "Open Battery settings"
            default: return item.name
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .app, .file, .folder:
            Image(nsImage: BarIcons.icon(for: item.target)).resizable().interpolation(.high).frame(width: 34, height: 34)
        case .link:
            symbol("globe", fill: Color(hex: 0x2B2B30))
        case .shortcut:
            symbol("command", fill: Color(hex: 0x7A5AF8))
        case .widget:
            widget
        }
    }

    private func symbol(_ name: String, fill: Color) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill)
            .frame(width: 34, height: 34)
            .overlay(Image(systemName: name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
    }

    @ViewBuilder private var widget: some View {
        switch item.widget {
        case .clock:
            // Redraws once a minute, not every frame.
            TimelineView(.everyMinute) { context in
                Text(context.date.formatted(date: .omitted, time: .shortened)).modifier(WidgetValue())
            }
        case .cpu:
            VStack(spacing: 4) {
                Text(model.cpuUsage.map { "\(Int(($0 * 100).rounded()))%" } ?? "–").modifier(WidgetValue())
                Meter(value: model.cpuUsage ?? 0)
            }
        case .battery:
            VStack(spacing: 4) {
                HStack(spacing: 3) {
                    Text(model.battery.map { "\($0.percent)%" } ?? "–").modifier(WidgetValue())
                    if model.battery?.charging == true {
                        Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(Theme.warning)
                    }
                }
                Meter(value: Double(model.battery?.percent ?? 0) / 100, lowIsBad: true)
            }
        case .timer:
            if let end = model.timerEnds {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.clock(max(0, end.timeIntervalSince(context.date)))).modifier(WidgetValue())
                        .foregroundStyle(Theme.good)
                }
            } else {
                Text(Self.clock(model.timerPaused ?? 25 * 60)).modifier(WidgetValue())
            }
        case .none:
            EmptyView()
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct WidgetValue: ViewModifier {
    func body(content: Content) -> some View {
        content.font(.system(size: 15, weight: .bold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
    }
}

struct Meter: View {
    var value: Double
    /// CPU: high is bad. Battery: low is bad.
    var lowIsBad = false

    private var color: Color {
        lowIsBad ? (value < 0.2 ? Theme.critical : Theme.good) : (value > 0.85 ? Theme.critical : Theme.good)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(color).frame(width: geo.size.width * min(1, max(0, value)))
            }
        }
        .frame(width: 44, height: 4)
    }
}

/// The + tile: widgets and the user's Shortcuts, in a normal macOS menu.
struct AddTile: View {
    let model: AppModel

    var body: some View {
        Button { AddMenu.show(model: model) } label: {
            VStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.textMuted).frame(height: 34)
                Text("Add").font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Add a widget or a Shortcut")
    }
}

@MainActor
enum AddMenu {
    /// Menu items that run a closure.
    final class Item: NSMenuItem {
        var run: (() -> Void)?
        convenience init(_ title: String, run: @escaping () -> Void) {
            self.init(title: title, action: #selector(fire), keyEquivalent: "")
            self.run = run
            target = self
        }
        @objc func fire() { run?() }
    }

    static func show(model: AppModel) {
        let menu = NSMenu()
        if let browser = model.barActions?.currentBrowser() {
            menu.addItem(Item("Add current \(browser.name) tab") { model.barActions?.addCurrentTab() })
            menu.addItem(.separator())
        }
        let have = Set(model.bar.items.compactMap(\.widget))
        let widgets = BarItem.Widget.allCases.filter { !have.contains($0) }
        if !widgets.isEmpty {
            menu.addItem(.sectionHeader(title: "Widgets"))
            for widget in widgets { menu.addItem(Item(widget.title) { model.barActions?.add(.widget(widget)) }) }
        }
        let shortcuts = model.shortcutNames.filter { name in !model.bar.items.contains { $0.kind == .shortcut && $0.target == name } }
        if !shortcuts.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Shortcuts"))
            for name in shortcuts { menu.addItem(Item(name) { model.barActions?.add(.shortcut(name)) }) }
        }
        menu.addItem(.separator())
        let hint = NSMenuItem(title: "Drag apps, files, folders, links or a browser\u{2019}s address onto the notch", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// Turns a drop into the right action.
@MainActor
enum BarDrop {
    /// Plain text from a provider, or the text of rich text.
    nonisolated static func loadText(_ provider: NSItemProvider, done: @escaping @Sendable (String?) -> Void) {
        if provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in done(object as? String) }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.rtf.identifier) { data, _ in
                done(data.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil)?.string })
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                done(data.map { String(decoding: $0, as: UTF8.self) })
            }
        } else {
            done(nil)
        }
    }

    nonisolated static let reorderPrefix = "notchboard-bar:"

    static func handle(_ providers: [NSItemProvider], model: AppModel, onto tile: BarItem?, index: Int?) -> Bool {
        model.barTargeted = false
        model.barTargetTile = nil
        // Text: a tile dragged within the bar, or an address dragged as text
        // (Dia's address bar drags plain and rich text, not a link).
        let isLink = { (p: NSItemProvider) in
            p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || p.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        if let provider = providers.first, !isLink(provider) {
            loadText(provider) { text in
                guard let text else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if text.hasPrefix(reorderPrefix), let id = UUID(uuidString: String(text.dropFirst(reorderPrefix.count))) {
                            model.barActions?.move(id, to: index ?? model.bar.items.count)
                        } else if let link = BarItem.link(fromText: text) {
                            model.barActions?.add(link, at: index)
                        }
                    }
                }
            }
            return true
        }
        // Files and links from outside.
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            let type = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? UTType.fileURL : UTType.url
            guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { continue }
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                guard !urls.isEmpty else { return }
                // Files dropped on an app tile open with that app.
                if let tile, tile.kind == .app {
                    let files = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() != "app" }
                    if !files.isEmpty {
                        model.barActions?.open(files, with: tile)
                        return
                    }
                }
                model.barActions?.add(urls: urls, at: index)
            }
        }
        return true
    }
}
