import SwiftUI
import VisorCore

/// Colours for plugin states, the same family as the rest of the notch.
enum PluginStyle {
    static func color(_ state: PluginState) -> Color {
        switch state {
        case .good: return Theme.good
        case .warn: return Theme.warning
        case .bad: return Theme.critical
        case .info: return Theme.accent
        case .idle: return Theme.textMuted
        }
    }
}

/// A plugin's badge on the closed notch: its symbol in the state's colour, and a count.
struct PluginBadgeView: View {
    let badge: PluginBadge

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: badge.icon).font(.system(size: 11, weight: .semibold))
            if let count = badge.count {
                Text("\(count)").font(.system(size: 10, weight: .semibold).monospacedDigit()).fixedSize()
            }
        }
        .foregroundStyle(PluginStyle.color(badge.state))
        .help(badge.help)
    }
}

/// The Plugins tab: each plugin's custom view or rows. Visor shows loading
/// itself: placeholders before the first view, a spinner by the name while a
/// call runs, and "couldn't refresh" over the last view when one fails.
struct PluginsView: View {
    let model: AppModel

    static let footer: CGFloat = 26
    static let gap: CGFloat = 16

    /// A first guess at the content height, before it's measured.
    static func estimate(_ plugins: [PluginInfo]) -> CGFloat {
        CGFloat(plugins.count) * 90 + footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Self.gap) {
                    if model.plugins.isEmpty {
                        EmptyState(symbol: "puzzlepiece.extension", title: "No plugins yet",
                                   detail: "Put a plugin's folder in the Plugins folder, or see how to write one.")
                            .frame(height: 110)
                    }
                    ForEach(model.plugins) { info in block(info) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The panel sizes to what's drawn (up to its limit, then this scrolls).
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if abs(height - model.pluginsContentHeight) > 0.5 { model.pluginsContentHeight = height }
                }
            }
            HStack(spacing: 14) {
                Button("Plugins folder") { model.pluginActions?.openFolder() }
                Button("How to write one") { model.pluginActions?.openDocs() }
                Spacer()
                Button("Reload") { model.pluginActions?.reload() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.textMuted)
            .frame(height: Self.footer, alignment: .bottom)
        }
    }

    private func block(_ info: PluginInfo) -> some View {
        let off = model.disabledPlugins.contains(info.id)
        let accent = info.accent.map { Color(nsColor: NSColor(hex: UInt32($0))) } ?? Theme.accent
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: info.icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text(info.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                if info.busy && !off { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12) }
                Spacer(minLength: 8)
                if off {
                    Text("Off").font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                } else if let error = info.error, info.hasOutput {
                    // The last view stays; say it's old and why on hover.
                    (info.updated.map { Text("Updated ") + Text($0, style: .relative) + Text(" ago · ") } ?? Text(""))
                        .font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                        + Text("couldn't refresh").font(.system(size: 10.5)).foregroundStyle(Theme.warning)
                    Color.clear.frame(width: 0, height: 0).help(error)
                } else if let updated = info.updated {
                    (Text(updated, style: .relative) + Text(" ago")).font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                }
                Menu {
                    Button(off ? "Turn On" : "Turn Off") { model.pluginActions?.setEnabled(info.id, off) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([info.folder]) }
                    Button("Show Log") { model.pluginActions?.openLog(info.id) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textMuted)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .frame(height: 22)
            .help(info.error ?? "")
            if !off {
                if let error = info.error, !info.hasOutput {
                    Text(error).font(.system(size: 10.5)).foregroundStyle(Theme.critical).lineLimit(2).truncationMode(.tail).help(error)
                } else if !info.hasOutput {
                    PluginPlaceholder()
                } else if let view = info.output.view {
                    PluginNodeView(node: view, plugin: info, model: model, accent: accent)
                } else {
                    ForEach(Array(info.output.sections.enumerated()), id: \.offset) { _, section in
                        PluginNodeView.sectionTitle(section.title)
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { index, row in
                            PluginRowView(model: model, row: row, key: "\(info.id)/\(section.title)/\(index)")
                        }
                    }
                }
            }
        }
        .opacity(off ? 0.5 : 1)
    }
}

/// Before a plugin's first view: still grey lines, no shimmer (no CPU).
struct PluginPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach([0.62, 0.8, 0.45], id: \.self) { width in
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.07)).frame(width: geo.size.width * width, height: 8)
                }
                .frame(height: 8)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Draws one piece of a plugin's view with Visor's own styles.
struct PluginNodeView: View {
    let node: PluginNode
    let plugin: PluginInfo
    let model: AppModel
    let accent: Color

    static func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.6)
            .foregroundStyle(Theme.textMuted).frame(height: 14, alignment: .bottomLeading)
    }

    private func color(_ state: PluginState?) -> Color { state.map(PluginStyle.color) ?? Theme.textPrimary }
    private func tint(_ state: PluginState?) -> Color { state.map(PluginStyle.color) ?? accent }

    var body: some View {
        switch node {
        case .stack(let children):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    PluginNodeView(node: child, plugin: plugin, model: model, accent: accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .columns(let children):
            HStack(alignment: .top, spacing: 18) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    PluginNodeView(node: child, plugin: plugin, model: model, accent: accent).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .divider:
            ToolDivider().padding(.vertical, -12)
        case .text(let text, let style, let state):
            switch style {
            case .title: Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(color(state))
            case .body: Text(text).font(.system(size: 12)).foregroundStyle(state.map(PluginStyle.color) ?? Theme.textSecondary)
            case .caption: Text(text).font(.system(size: 10.5)).foregroundStyle(state.map(PluginStyle.color) ?? Theme.textMuted)
            case .mono: Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(state.map(PluginStyle.color) ?? Theme.textSecondary)
            }
        case .stats(let stats):
            HStack(alignment: .lastTextBaseline, spacing: 22) {
                ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                    PluginNodeView(node: stat, plugin: plugin, model: model, accent: accent)
                }
            }
        case .stat(let value, let label, let state, let large, let pending):
            VStack(alignment: .leading, spacing: 1) {
                Text(pending ? "—" : value)
                    .font(.system(size: large ? 24 : 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(pending ? Theme.textMuted : color(state)).lineLimit(1)
                Text(label).font(.system(size: 10.5)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
        case .meter(let title, let value, let text, let caption, let state, let pending):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(pending ? "—" : text).font(.system(size: 11.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.09))
                        if !pending { Capsule().fill(tint(state)).frame(width: max(3, geo.size.width * value)) }
                    }
                }
                .frame(height: Theme.barHeight)
                if !caption.isEmpty { Text(caption).font(.system(size: 10.5)).foregroundStyle(Theme.textMuted) }
            }
        case .bars(let values, let states, let labels, let pending):
            VStack(alignment: .leading, spacing: 3) {
                let top = max(values.max() ?? 1, 0.0001)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        // An empty bar is a faint stub, so a quiet day still has a place.
                        RoundedRectangle(cornerRadius: 2)
                            .fill(pending || value == 0 ? Color.white.opacity(0.08)
                                  : tint(states.indices.contains(index) ? states[index] : nil).opacity(0.85))
                            .frame(height: pending ? 6 : max(2, 44 * value / top))
                            .frame(maxWidth: 22)
                    }
                }
                .frame(height: 44, alignment: .bottom)
                if labels.count == 2 {
                    HStack { Text(labels[0]); Spacer(); Text(labels[1]) }.font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                }
            }
            // A few bars stay bar-shaped and sit at the right with the latest, labels under them.
            .frame(maxWidth: max(80, CGFloat(values.count) * 25), alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .chips(let chips):
            HStack(spacing: 6) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    HStack(spacing: 5) {
                        if let state = chip.state { Circle().fill(PluginStyle.color(state)).frame(width: 6, height: 6) }
                        Text(chip.text).lineLimit(1)
                    }
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                }
            }
        case .list(let rows):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    PluginRowView(model: model, row: row, key: "\(plugin.id)/list/\(index)/\(row.title)")
                }
            }
        case .table(let columns, let rows):
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 3) {
                GridRow {
                    ForEach(Array(columns.enumerated()), id: \.offset) { index, title in
                        Text(title.uppercased()).gridColumnAlignment(index == 0 ? .leading : .trailing)
                            .frame(maxWidth: index == 0 ? nil : .infinity, alignment: index == 0 ? .leading : .trailing)
                    }
                }
                .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.textMuted)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(cell).lineLimit(1) } }
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
        case .clock(let until, let since, let large):
            // SwiftUI ticks timer text itself, with no plugin calls.
            Group {
                if let until { Text(timerInterval: Date()...max(Date(), until), countsDown: true) }
                else if let since { Text(since, style: .timer) }
                else { Text("—") }
            }
            .font(.system(size: large ? 34 : 15, weight: .bold).monospacedDigit())
            .foregroundStyle(Theme.textPrimary)
        case .progress(let value):
            if let value {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.09))
                        Capsule().fill(accent).frame(width: max(3, geo.size.width * value))
                    }
                }
                .frame(height: Theme.barHeight)
            } else {
                ProgressView().progressViewStyle(.linear).tint(accent)
            }
        case .buttons(let buttons):
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                    let spinning = button.action != nil && plugin.pendingAction == button.action
                    Button {
                        if let url = button.url { NSWorkspace.shared.open(url) }
                        else if let action = button.action { model.pluginActions?.act(plugin.id, action, value: nil) }
                    } label: {
                        HStack(spacing: 5) {
                            if spinning { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10) }
                            Text(button.title)
                            if button.url != nil { Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .bold)) }
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(button.primary ? Color.black : Theme.textPrimary)
                        .padding(.horizontal, 11).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(button.primary ? accent : Color.white.opacity(0.1)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(spinning)
                    .help(button.url?.absoluteString ?? "")
                }
            }
        case .picker(let options, let selected, let action):
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { option in
                    let on = option == (model.pluginChoices["\(plugin.id)/\(action)"] ?? selected)
                    Button {
                        // Shows the choice at once; the plugin's next view has the last word.
                        model.pluginChoices["\(plugin.id)/\(action)"] = option
                        model.pluginActions?.act(plugin.id, action, value: option)
                    } label: {
                        Text(option).font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                            .padding(.horizontal, 9).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.white.opacity(0.16) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
        case .toggle(let label, let on, let action):
            HStack {
                Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button { model.pluginActions?.act(plugin.id, action, value: !on) } label: {
                    Capsule().fill(on ? Theme.good : Theme.deemphasis).frame(width: 28, height: 16)
                        .overlay(alignment: on ? .trailing : .leading) { Circle().fill(.white).frame(width: 12, height: 12).padding(2) }
                }
                .buttonStyle(.plain)
            }
        case .unsupported(let kind):
            Text("\"\(kind)\" needs a newer Visor").font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
        }
    }
}

struct PluginRowView: View {
    let model: AppModel
    let row: PluginRow
    let key: String

    var body: some View {
        let hovered = model.pluginHover == key
        HStack(spacing: 8) {
            Circle().fill(PluginStyle.color(row.status)).frame(width: 7, height: 7)
            Text(row.title).font(.system(size: 12)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text([row.detail, row.time.map(Self.ago)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.textMuted).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovered && row.url != nil ? Color.white.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.pluginHover = key } else if model.pluginHover == key { model.pluginHover = nil }
        }
        .onTapGesture { if let url = row.url { NSWorkspace.shared.open(url) } }
        .help(row.url?.absoluteString ?? "")
    }

    /// "now", "4m", "3h", "2d".
    static func ago(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }
}
