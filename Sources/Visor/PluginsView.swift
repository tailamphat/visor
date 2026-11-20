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

/// The Plugins tab: each plugin's sections, one row per item. Click a row to open it.
struct PluginsView: View {
    let model: AppModel

    static let headerHeight: CGFloat = 22
    static let sectionHeight: CGFloat = 18
    static let rowHeight: CGFloat = 24
    static let gap: CGFloat = 14
    static let footer: CGFloat = 26

    /// The content height for these plugins, for the panel's size.
    static func height(_ plugins: [PluginInfo]) -> CGFloat {
        let blocks = plugins.map { info -> CGFloat in
            let sections = info.output.sections
            let rows = sections.reduce(0) { $0 + $1.rows.count }
            return headerHeight + CGFloat(sections.count) * sectionHeight + CGFloat(rows) * rowHeight
                + (info.error != nil && info.error != "Off" ? 16 : 0)
        }
        return blocks.reduce(0, +) + CGFloat(max(0, plugins.count - 1)) * gap + footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Self.gap) {
                    ForEach(model.plugins) { info in block(info) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: info.icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text(info.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                if off {
                    Text("Off").font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
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
            .frame(height: Self.headerHeight)
            if let error = info.error, !off {
                Text(error).font(.system(size: 10.5)).foregroundStyle(Theme.critical).lineLimit(1).truncationMode(.tail)
                    .frame(height: 16).help(error)
            }
            ForEach(Array(info.output.sections.enumerated()), id: \.offset) { _, section in
                Text(section.title.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Theme.textMuted).frame(height: Self.sectionHeight, alignment: .bottomLeading)
                ForEach(Array(section.rows.enumerated()), id: \.offset) { index, row in
                    PluginRowView(model: model, row: row, key: "\(info.id)/\(section.title)/\(index)")
                }
            }
        }
        .opacity(off ? 0.5 : 1)
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
        .frame(height: PluginsView.rowHeight)
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
