import SwiftUI
import VisorCore

/// The Harness line under the MCP line: "Harness · 41k before your first word · figma
/// unused". A click opens `HarnessList` under it. Same shape as `MCPLine`.
struct HarnessLine: View {
    let model: AppModel
    let summary: HarnessSummary
    static let height: CGFloat = MCPLine.height

    var body: some View {
        Button { model.harnessOpen.toggle() } label: {
            HStack(spacing: DS.Space.sm) {
                Text("Harness").fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                Text("·").foregroundStyle(Theme.textMuted)
                Text(summary.detail).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: DS.Space.sm)
                Image(systemName: model.harnessOpen ? "chevron.down" : "chevron.right")
                    .font(DS.font(.xs, .semibold)).foregroundStyle(Theme.textMuted)
            }
            .font(DS.font(.base))
            .padding(.horizontal, DS.Space.lg)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(DS.Fill.faint))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.harnessOpen ? "Hide the harness X-ray"
                                : "What each Claude Code session carried before your first prompt")
    }
}

/// One row per Claude Code session: project, a bar of its harness split into parts
/// (one scale for all rows), the exact total; then the key and the MCP advice.
struct HarnessList: View {
    let summary: HarnessSummary
    private static let nameWidth: CGFloat = 96
    private static let totalWidth: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.none) {
            SectionHeader("Before your first word · parts about")
                .frame(height: CGFloat(HarnessSummary.headerHeight))
            ForEach(summary.rows) { row in
                HStack(spacing: DS.Space.md) {
                    Text(row.project).font(DS.font(.base, .semibold)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(width: Self.nameWidth, alignment: .leading)
                    GeometryReader { box in bar(row).frame(width: box.size.width * row.scale, alignment: .leading) }
                        .frame(height: DS.Size.bar)
                    Text(HarnessSummary.short(row.total)).font(DS.font(.base, .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: Self.totalWidth, alignment: .trailing)
                }
                .frame(height: CGFloat(HarnessSummary.rowHeight))
                .contentShape(Rectangle())
                .help(row.help)
            }
            if summary.more > 0 {
                Text("+\(summary.more) more").font(DS.font(.sm)).foregroundStyle(Theme.textMuted)
                    .frame(height: CGFloat(HarnessSummary.moreHeight))
            }
            key.frame(height: CGFloat(HarnessSummary.keyHeight))
            if let advice = summary.advice {
                VStack(alignment: .leading, spacing: CGFloat(HarnessSummary.adviceSpacing)) {
                    Text(advice.title).font(DS.font(.base, .semibold)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).frame(height: CGFloat(HarnessSummary.adviceRow))
                    Text(advice.detail).font(DS.font(.base)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle).frame(height: CGFloat(HarnessSummary.adviceRow))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .bannerCard(tint: DS.Palette.violet, height: CGFloat(HarnessSummary.adviceHeight))
                .padding(.top, CGFloat(HarnessSummary.adviceGap))
                .help("Its tools are loaded into every \(advice.project) session. Visor only shows this; it changes no settings.")
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(Theme.raised))
    }

    /// The parts side by side, each as wide as its share of the total.
    private func bar(_ row: HarnessRow) -> some View {
        GeometryReader { box in
            let gaps = CGFloat(max(0, row.parts.count - 1)) * DS.Space.hair
            let width = max(0, box.size.width - gaps)
            HStack(spacing: DS.Space.hair) {
                ForEach(row.parts, id: \.kind) { part in
                    Rectangle().fill(Self.color(part.kind))
                        .frame(width: width * CGFloat(part.share))
                }
            }
        }
        .clipShape(Capsule())
    }

    private var key: some View {
        HStack(spacing: DS.Space.lg) {
            ForEach(Self.keyItems, id: \.1) { kind, title in
                HStack(spacing: DS.Space.xs) {
                    RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous).fill(Self.color(kind))
                        .frame(width: 7, height: 7)
                    Text(title)
                }
            }
        }
        .font(DS.font(.sm)).foregroundStyle(Theme.textMuted).lineLimit(1)
    }

    private static let keyItems: [(HarnessPart.Kind, String)] = [
        (.systemAndTools, "system + tools"), (.mcp, "MCP"), (.instructions, "CLAUDE.md + memory"),
        (.skills, "skills"), (.prompt, "your prompt"),
    ]

    static func color(_ kind: HarnessPart.Kind) -> Color {
        switch kind {
        case .systemAndTools: return Theme.question
        case .mcp: return DS.Palette.violet
        case .instructions: return Theme.claude
        case .skills: return DS.Palette.mint
        case .prompt: return Theme.deemphasis
        }
    }
}

/// The line and, when open, the list: under the MCP line at the end of the Agents list.
struct HarnessSection: View {
    let model: AppModel

    var body: some View {
        if let summary = model.harness {
            HarnessLine(model: model, summary: summary)
            if model.harnessOpen { HarnessList(summary: summary) }
        }
    }

    /// The height it adds to the Agents panel, gaps included.
    static func height(_ model: AppModel) -> CGFloat {
        guard let summary = model.harness else { return 0 }
        return 6 + HarnessLine.height + (model.harnessOpen ? 6 + CGFloat(summary.listHeight) : 0)
    }
}
