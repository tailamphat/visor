import SwiftUI
import VisorCore

private typealias Piece = PluginPieces

/// Colours for plugin states and palette names, the same family as the rest of the notch.
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

    /// A palette name a plugin picked; `accent` is the plugin's own.
    static func color(_ name: PluginColor, accent: Color) -> Color {
        switch name {
        case .accent: return accent
        case .good: return Theme.good
        case .warning: return Theme.warning
        case .critical: return Theme.critical
        case .question: return Theme.question
        case .stuck: return DS.Palette.stuck
        case .clash: return Theme.clash
        case .claude: return Theme.claude
        case .onPace: return Theme.onPace
        case .textPrimary: return Theme.textPrimary
        case .textSecondary: return Theme.textSecondary
        case .textMuted: return Theme.textMuted
        }
    }

    static func step(_ step: PluginTypeStep) -> DS.TypeStep {
        switch step {
        case .xs: return .xs
        case .sm: return .sm
        case .base: return .base
        case .md: return .md
        case .lg: return .lg
        case .xl: return .xl
        case .display: return .display
        }
    }

    static func weight(_ weight: PluginWeight) -> Font.Weight {
        switch weight {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}

/// A plugin's badge on the closed notch: its symbol in the state's colour, and a count.
struct PluginBadgeView: View {
    let badge: PluginBadge

    var body: some View {
        HStack(spacing: DS.Space.xxs) {
            Image(systemName: badge.icon).font(DS.font(.base, .semibold))
            if let count = badge.count {
                Text("\(count)").font(DS.font(.sm, .semibold).monospacedDigit()).fixedSize()
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

    static let footer = CGFloat(Piece.footer)
    static let gap = CGFloat(Piece.blockGap)

    /// A first guess at the content height, before it's measured.
    static func estimate(_ plugins: [PluginInfo]) -> CGFloat {
        CGFloat(plugins.count) * 90 + footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.none) {
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
            HStack(spacing: DS.Space.xl) {
                Button("Plugins folder") { model.pluginActions?.openFolder() }
                Button("How to write one") { model.pluginActions?.openDocs() }
                Spacer()
                Button("Reload") { model.pluginActions?.reload() }
            }
            .buttonStyle(.plain)
            .font(DS.font(.sm))
            .foregroundStyle(Theme.textMuted)
            .frame(height: Self.footer, alignment: .bottom)
        }
    }

    private func block(_ info: PluginInfo) -> some View {
        let off = model.disabledPlugins.contains(info.id)
        // The manifest's own colour: data from plugin.json, not a literal.
        let accent = info.accent.map { Color(nsColor: NSColor(hex: UInt32($0))) } ?? Theme.accent
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: info.icon).font(DS.font(.base, .semibold)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text(info.name).font(DS.font(.md, .semibold)).foregroundStyle(Theme.textPrimary)
                if info.busy && !off { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12) }
                Spacer(minLength: DS.Space.md)
                if off {
                    Text("Off").font(DS.font(.sm)).foregroundStyle(Theme.textMuted)
                } else if let error = info.error, info.hasOutput {
                    // The last view stays; say it's old and why on hover.
                    (info.updated.map { Text("Updated ") + Text($0, style: .relative) + Text(" ago · ") } ?? Text(""))
                        .font(DS.font(.sm)).foregroundStyle(Theme.textMuted)
                        + Text("couldn't refresh").font(DS.font(.sm)).foregroundStyle(Theme.warning)
                    Color.clear.frame(width: 0, height: 0).help(error)
                } else if let updated = info.updated {
                    (Text(updated, style: .relative) + Text(" ago")).font(DS.font(.sm)).foregroundStyle(Theme.textMuted)
                }
                Menu {
                    Button(off ? "Turn On" : "Turn Off") { model.pluginActions?.setEnabled(info.id, off) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([info.folder]) }
                    Button("Show Log") { model.pluginActions?.openLog(info.id) }
                } label: {
                    Image(systemName: "ellipsis").font(DS.font(.sm, .bold)).foregroundStyle(Theme.textMuted)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .frame(height: CGFloat(Piece.headerHeight))
            .help(info.error ?? "")
            if !off {
                if let error = info.error, !info.hasOutput {
                    Text(error).font(DS.font(.sm)).foregroundStyle(Theme.critical).lineLimit(2).truncationMode(.tail).help(error)
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
        VStack(alignment: .leading, spacing: DS.Space.md) {
            ForEach([0.62, 0.8, 0.45], id: \.self) { width in
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: DS.Radius.xs).fill(Color.white.opacity(Piece.trackFill))
                        .frame(width: geo.size.width * width, height: CGFloat(Piece.placeholderLine))
                }
                .frame(height: CGFloat(Piece.placeholderLine))
            }
        }
        .padding(.vertical, DS.Space.xs)
    }
}

/// Draws one piece of a plugin's view with Visor's design system: DS tokens
/// and the shared components, never a size or colour of its own.
struct PluginNodeView: View {
    let node: PluginNode
    let plugin: PluginInfo
    let model: AppModel
    let accent: Color

    /// A value still to come: a long dash, as before.
    static let pendingMark = "\u{2014}"

    static func sectionTitle(_ title: String) -> some View {
        SectionHeader(title).frame(height: 14, alignment: .bottomLeading)
    }

    /// A palette name first, then the state, then the piece's default.
    private func color(_ state: PluginState?, _ name: PluginColor? = nil, default fallback: Color = Theme.textPrimary) -> Color {
        if let name { return PluginStyle.color(name, accent: accent) }
        return state.map(PluginStyle.color) ?? fallback
    }
    private func tint(_ state: PluginState?, _ name: PluginColor? = nil) -> Color { color(state, name, default: accent) }

    private func child(_ node: PluginNode) -> PluginNodeView {
        PluginNodeView(node: node, plugin: plugin, model: model, accent: accent)
    }

    private func act(_ action: String, _ value: Any? = nil) {
        model.pluginActions?.act(plugin.id, action, value: value)
    }

    var body: some View {
        switch node {
        case .stack(let children):
            VStack(alignment: .leading, spacing: CGFloat(Piece.stackGap)) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, node in child(node) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .columns(let children):
            HStack(alignment: .top, spacing: CGFloat(Piece.columnsGap)) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, node in
                    child(node).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .divider:
            ToolDivider().padding(.vertical, -DS.Space.xl)
        case .text(let text, let style, let state, let name, let size, let weight):
            Text(text).font(Self.font(style, size: size, weight: weight)).foregroundStyle(color(state, name, default: Self.textColor(style)))
        case .stats(let stats):
            HStack(alignment: .lastTextBaseline, spacing: CGFloat(Piece.statsGap)) {
                ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in child(stat) }
            }
        case .stat(let value, let label, let state, let large, let pending, let name):
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(pending ? Self.pendingMark : value)
                    .font(DS.font(large ? .display : .xl, .bold).monospacedDigit())
                    .foregroundStyle(pending ? Theme.textMuted : color(state, name)).lineLimit(1)
                Text(label).font(DS.font(.sm)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
        case .meter(let title, let value, let text, let caption, let state, let pending, let name):
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack {
                    Text(title).font(DS.font(.base)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(pending ? Self.pendingMark : text).font(DS.font(.base, .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                }
                track(value: pending ? nil : value, fill: tint(state, name))
                if !caption.isEmpty { Text(caption).font(DS.font(.sm)).foregroundStyle(Theme.textMuted) }
            }
        case .bars(let values, let states, let labels, let pending, let names):
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                let top = max(values.max() ?? 1, 0.0001)
                let height = CGFloat(Piece.barsHeight)
                HStack(alignment: .bottom, spacing: DS.Space.xxs) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        // An empty bar is a faint stub, so a quiet day still has a place.
                        RoundedRectangle(cornerRadius: CGFloat(Piece.barRadius))
                            .fill(pending || value == 0 ? Color.white.opacity(Piece.trackFill)
                                  : tint(states.indices.contains(index) ? states[index] : nil,
                                         names.indices.contains(index) ? names[index] : nil).opacity(Piece.barOpacity))
                            .frame(height: pending ? DS.Space.sm : max(DS.Space.xxs, height * value / top))
                            .frame(maxWidth: 22)
                    }
                }
                .frame(height: height, alignment: .bottom)
                if labels.count == 2 {
                    HStack { Text(labels[0]); Spacer(); Text(labels[1]) }.font(DS.font(.sm)).foregroundStyle(Theme.textMuted)
                }
            }
            // A few bars stay bar-shaped and sit at the right with the latest, labels under them.
            .frame(maxWidth: max(80, CGFloat(values.count) * 25), alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .chips(let chips):
            HStack(spacing: DS.Space.sm) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    HStack(spacing: DS.Space.xs) {
                        if chip.state != nil || chip.color != nil {
                            Circle().fill(color(chip.state, chip.color)).frame(width: DS.Space.sm, height: DS.Space.sm)
                        }
                        Text(chip.text).lineLimit(1)
                    }
                    .font(DS.font(.sm)).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.xxs)
                    .background(Capsule().fill(Color.white.opacity(Piece.trackFill)))
                }
            }
        case .list(let rows):
            VStack(alignment: .leading, spacing: DS.Space.none) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    PluginRowView(model: model, row: row, key: "\(plugin.id)/list/\(index)/\(row.title)")
                }
            }
        case .table(let columns, let rows):
            Grid(alignment: .trailing, horizontalSpacing: DS.Space.xl, verticalSpacing: DS.Space.xxs) {
                GridRow {
                    ForEach(Array(columns.enumerated()), id: \.offset) { index, title in
                        SectionHeader(title).gridColumnAlignment(index == 0 ? .leading : .trailing)
                            .frame(maxWidth: index == 0 ? nil : .infinity, alignment: index == 0 ? .leading : .trailing)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(cell).lineLimit(1) } }
                        .font(DS.font(.base).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
        case .clock(let until, let since, let large):
            // SwiftUI ticks timer text itself, with no plugin calls.
            Group {
                if let until { Text(timerInterval: Date()...max(Date(), until), countsDown: true) }
                else if let since { Text(since, style: .timer) }
                else { Text(Self.pendingMark) }
            }
            .font(DS.font(large ? .display : .xl, .bold).monospacedDigit())
            .foregroundStyle(Theme.textPrimary)
        case .progress(let value):
            if let value {
                track(value: value, fill: accent)
            } else {
                ProgressView().progressViewStyle(.linear).tint(accent)
            }
        case .buttons(let buttons):
            HStack(spacing: DS.Space.md) {
                Spacer(minLength: DS.Space.none)
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                    let spinning = button.action != nil && plugin.pendingAction == button.action
                    Button {
                        if let url = button.url { NSWorkspace.shared.open(url) }
                        else if let action = button.action { act(action) }
                    } label: {
                        HStack(spacing: DS.Space.xs) {
                            if spinning { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10) }
                            Text(button.title)
                            if button.url != nil { Image(systemName: "arrow.up.right").font(DS.font(.xs, .bold)) }
                        }
                    }
                    .buttonStyle(CardButton(button.primary ? .primary : .secondary, tint: accent))
                    .disabled(spinning)
                    .help(button.url?.absoluteString ?? "")
                }
            }
        case .picker(let options, let selected, let action):
            HStack(spacing: DS.Space.xxs) {
                ForEach(options, id: \.self) { option in
                    let on = option == (model.pluginChoices["\(plugin.id)/\(action)"] ?? selected)
                    Button {
                        // Shows the choice at once; the plugin's next view has the last word.
                        model.pluginChoices["\(plugin.id)/\(action)"] = option
                        act(action, option)
                    } label: {
                        Text(option).font(DS.font(.sm, .medium))
                            .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                            .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.xxs)
                            .background(RoundedRectangle(cornerRadius: CGFloat(Piece.rowRadius))
                                .fill(on ? Color.white.opacity(Piece.pickerOnFill) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DS.Space.xxs)
            .background(RoundedRectangle(cornerRadius: CGFloat(Piece.rowRadius)).fill(Color.white.opacity(Piece.pickerFill)))
        case .toggle(let label, let on, let action):
            HStack {
                Text(label).font(DS.font(.base)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button { act(action, !on) } label: {
                    let height = CGFloat(Piece.toggleHeight)
                    let knob = height - 2 * DS.Space.xxs
                    Capsule().fill(on ? Theme.good : Theme.deemphasis).frame(width: CGFloat(Piece.toggleWidth), height: height)
                        .overlay(alignment: on ? .trailing : .leading) {
                            Circle().fill(Theme.textPrimary).frame(width: knob, height: knob).padding(DS.Space.xxs)
                        }
                }
                .buttonStyle(.plain)
            }
        case .banner(let banner):
            let bannerTint = tint(nil, banner.tint)
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                if banner.badge != nil || !banner.title.isEmpty || banner.dismiss != nil {
                    HStack(spacing: DS.Space.sm) {
                        if let badge = banner.badge { Badge(badge, .solid(bannerTint)) }
                        Text(banner.title).font(DS.font(.base, .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer(minLength: DS.Space.none)
                        if let dismiss = banner.dismiss { DismissButton { act(dismiss) } }
                    }
                }
                if !banner.text.isEmpty {
                    Text(banner.text).font(DS.font(.base)).foregroundStyle(Theme.textSecondary)
                }
                ForEach(Array(banner.children.enumerated()), id: \.offset) { _, node in child(node) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .bannerCard(tint: bannerTint)
        case .badge(let title, let tint):
            Badge(title, tint.map { .solid(PluginStyle.color($0, accent: accent)) } ?? .neutral)
        case .header(let title, let badge):
            HStack(spacing: DS.Space.sm) {
                SectionHeader(title)
                if let badge { Badge(badge) }
            }
        case .unsupported(let kind):
            Text("\"\(kind)\" needs a newer Visor").font(DS.font(.sm)).foregroundStyle(Theme.textMuted)
        }
    }

    /// A meter or progress track; a nil value is a pending meter (track only).
    private func track(value: Double?, fill: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(Piece.trackFill))
                if let value { Capsule().fill(fill).frame(width: max(DS.Size.bar, geo.size.width * value)) }
            }
        }
        .frame(height: DS.Size.bar)
    }

    /// Text styles on the type scale; `size` and `weight` override the style's.
    static func font(_ style: PluginNode.TextStyle, size: PluginTypeStep?, weight: PluginWeight?) -> Font {
        let base: (step: DS.TypeStep, weight: Font.Weight)
        switch style {
        case .headline: base = (.xl, .semibold)
        case .title: base = (.lg, .semibold)
        case .body: base = (.md, .regular)
        case .caption: base = (.sm, .regular)
        case .footnote: base = (.xs, .regular)
        case .mono: base = (.base, .regular)
        }
        return DS.font(size.map(PluginStyle.step) ?? base.step, weight.map(PluginStyle.weight) ?? base.weight,
                       design: style == .mono ? .monospaced : .default)
    }

    static func textColor(_ style: PluginNode.TextStyle) -> Color {
        switch style {
        case .headline, .title: return Theme.textPrimary
        case .body, .mono: return Theme.textSecondary
        case .caption, .footnote: return Theme.textMuted
        }
    }
}

struct PluginRowView: View {
    let model: AppModel
    let row: PluginRow
    let key: String

    var body: some View {
        let hovered = model.pluginHover == key
        HStack(spacing: DS.Space.md) {
            Circle().fill(PluginStyle.color(row.status)).frame(width: CGFloat(Piece.dot), height: CGFloat(Piece.dot))
            Text(row.title).font(DS.font(.md)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: DS.Space.md)
            Text([row.detail, row.time.map(Self.ago)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(DS.font(.sm).monospacedDigit()).foregroundStyle(Theme.textMuted).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, CGFloat(Piece.rowPadding))
        .frame(height: CGFloat(Piece.rowHeight))
        .background(RoundedRectangle(cornerRadius: CGFloat(Piece.rowRadius), style: .continuous)
            .fill(hovered && row.url != nil ? Color.white.opacity(Piece.hoverFill) : .clear))
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
