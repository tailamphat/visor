import SwiftUI
import VisorCore

/// One row per tool (Claude, OpenCode, Copilot, Antigravity): its limits on the
/// left and, when it has one, what it used on the right.
struct UsageView: View {
    let model: AppModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: UsageView.toolGap) {
                // In the order chosen under Connected accounts. Space alone separates tools:
                // each starts with its coloured mark and name, which reads as a heading.
                ForEach(model.usageSections, id: \.self) { provider in
                    section(provider)
                }
                if !ConnectionProvider.allCases.contains(where: model.shows) {
                    Text(ConnectionProvider.allCases.contains(where: model.installed)
                         ? "Every tool is switched off. Turn one on under Connected accounts (the gear)."
                         : "No AI tools on this Mac yet. Usage shows up once Claude Code, Copilot CLI, Antigravity or OpenCode is installed.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func section(_ provider: ConnectionProvider) -> some View {
        switch provider {
        case .claude: claudeRow
        case .openCode: OpenCodeBlock(model: model)
        case .copilot:
            VStack(alignment: .leading, spacing: 20) {
                ForEach(model.copilot, id: \.host) { usage in
                    CopilotBlock(usage: usage, forecast: usage.premiumUnlimited ? nil
                        : model.forecast(UsageKey.copilot(usage.host), used: 100 - usage.percentLeft, resetsAt: usage.resetsAt,
                                         window: usage.resetsAt.flatMap { BurnForecast.monthWindow(endingAt: $0) }))
                }
            }
        // No chart: the limits take the full width (the heading starts the section).
        case .antigravity: AntigravityBlock(model: model)
        }
    }


    private var claudeRow: some View {
        // The heading spans the panel and starts the section; limits and spend sit below it.
        VStack(alignment: .leading, spacing: 10) {
            ProviderHeader(agent: "Claude Code", title: model.planName ?? "Claude") {
                if let updated = model.planUpdated {
                    // Short ("1m ago") and on one line beside the title; "Updated" goes when it's tight.
                    // Ticks every 15 s, only while the panel is open.
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        let ago = SessionText.ago(updated, now: context.date)
                        ViewThatFits(in: .horizontal) {
                            Text("Updated \(ago)").lineLimit(1).fixedSize()
                            Text(ago).lineLimit(1).fixedSize()
                        }
                    }
                }
            }
            UsageRow {
                VStack(alignment: .leading, spacing: 10) {
                    if let plan = model.plan {
                        ForEach(plan.limits.prefix(3)) { limit in
                            LimitMeter(title: limit.title, used: limit.percentUsed,
                                       caption: limit.resetsAt.map { "Resets \(SessionText.reset($0))" },
                                       forecast: model.forecast(UsageKey.claude(limit.kind), used: limit.percentUsed, resetsAt: limit.resetsAt,
                                                                window: BurnForecast.window(claude: limit.kind)),
                                       resetsAt: limit.resetsAt)
                        }
                        if let extra = plan.extra {
                            Text(String(format: "Extra usage: %@ of %@", money(extra.used), extra.limit.map(money) ?? "no limit"))
                                .font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                        }
                    } else {
                        Text(model.planError ?? "Loading…").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    }
                    if let error = model.planError, model.plan != nil {
                        Text(error).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                    }
                }
            } usage: {
                SpendView(model: model)
            }
        }
    }

    private func money(_ value: Double) -> String { String(format: "$%.2f", value) }
}

extension UsageView {
    /// Between tools in Usage.
    static let toolGap: CGFloat = 28
    /// Height that gap adds over the 20pt tools used to have.
    static let toolGapExtra: CGFloat = toolGap - 20
}

enum UsageColumns {
    /// About 40% of the panel's content; the limits take the rest.
    static let usageWidth: CGFloat = 170
    static let spacing: CGFloat = 24
}

/// A tool's limits on the left and its usage in a fixed column on the right.
struct UsageRow<Limits: View, Usage: View>: View {
    @ViewBuilder let limits: Limits
    @ViewBuilder let usage: Usage

    var body: some View {
        HStack(alignment: .top, spacing: UsageColumns.spacing) {
            limits.frame(maxWidth: .infinity, alignment: .leading)
            usage.frame(width: UsageColumns.usageWidth, alignment: .leading)
        }
    }
}
