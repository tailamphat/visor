import SwiftUI
import VisorCore

/// The MCP line under the sessions: "MCP 4 · figma failed 3x in web-shop". A click
/// opens `MCPList` under it. Same shape as the list's other full-width rows.
struct MCPLine: View {
    let model: AppModel
    let summary: MCPSummary
    static let height: CGFloat = 26

    var body: some View {
        Button { model.mcpOpen.toggle() } label: {
            HStack(spacing: 6) {
                Text("MCP \(summary.count)").fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                // "MCP 3 configured" when nothing was seen yet, otherwise "MCP 4 · <detail>".
                if summary.detail != "configured" {
                    Text("·").foregroundStyle(Theme.textMuted)
                    Text(summary.detail).foregroundStyle(summary.failing ? Theme.warning : Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(summary.detail).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 6)
                Image(systemName: model.mcpOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textMuted)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.mcpOpen ? "Hide the MCP servers" : "Show every MCP server your agents use")
    }
}

/// Every MCP server: state dot, name, most-called tools, the agents that use it and its
/// state. At most `MCPSummary.maxRows`, then "+n more".
struct MCPList: View {
    let summary: MCPSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MCP servers · \(summary.count)")
                .font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).tracking(0.6)
                .foregroundStyle(Theme.textMuted)
                .frame(height: MCPSummary.headerHeight)
            ForEach(summary.rows, id: \.server) { row in
                HStack(spacing: 9) {
                    dot(row.state)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.server).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text(row.tools.isEmpty ? "not called yet" : row.tools.joined(separator: " · "))
                            .font(.system(size: 10.5)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 6)
                    HStack(spacing: 3) {
                        ForEach(row.agents, id: \.self) { AgentMark(agent: $0, size: 11) }
                    }
                    Text(row.stateText).font(.system(size: 10.5)).foregroundStyle(color(row.state)).lineLimit(1).fixedSize()
                }
                .frame(height: MCPSummary.rowHeight)
                .help("\(row.server): \(row.stateText). Used by \(row.agents.joined(separator: ", ")).")
            }
            if summary.more > 0 {
                Text("+\(summary.more) more").font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                    .frame(height: MCPSummary.moreHeight)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
    }

    private func color(_ state: MCPServerHealth.State) -> Color {
        switch state {
        case .working: return ConsentButton.mint
        case .failing: return Theme.warning
        case .configured: return Theme.textMuted
        }
    }

    @ViewBuilder private func dot(_ state: MCPServerHealth.State) -> some View {
        if case .configured = state {
            Circle().strokeBorder(Theme.textMuted, lineWidth: 1.5).frame(width: 8, height: 8)
        } else {
            Circle().fill(color(state)).frame(width: 8, height: 8)
        }
    }
}

/// The line and, when open, the list: the end of the Agents list.
struct MCPSection: View {
    let model: AppModel

    var body: some View {
        if let summary = model.mcp {
            MCPLine(model: model, summary: summary)
            if model.mcpOpen { MCPList(summary: summary) }
        }
    }

    /// The height it adds to the Agents panel, gaps included.
    static func height(_ model: AppModel) -> CGFloat {
        guard let summary = model.mcp else { return 0 }
        return 6 + MCPLine.height + (model.mcpOpen ? 6 + CGFloat(summary.listHeight) : 0)
    }
}
