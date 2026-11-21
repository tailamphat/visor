import SwiftUI
import VisorCore

/// A provider's mark and name, with a muted note on the right.
struct ProviderHeader<Note: View>: View {
    let agent: String
    let title: String
    /// The note right after the title (an account's host) instead of at the far right ("Updated … ago").
    var inlineNote = false
    @ViewBuilder var note: Note
    @Environment(\.providerIncidents) private var incidents

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading
            // An incident on this tool's status page: what's wrong, since when, the link.
            if let incident = incidents[agent] { IncidentLine(incident: incident) }
        }
    }

    private var heading: some View {
        HStack(spacing: 7) {
            AgentMark(agent: agent, size: 18)
            if inlineNote {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).fixedSize()
                    note.font(.system(size: 10.5)).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
            } else {
                // The title never wraps; the note beside it gives way.
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                note.font(.system(size: 10)).foregroundStyle(Theme.textMuted)
            }
        }
    }
}

/// The provider's open incidents, for the Usage headings.
private struct ProviderIncidentsKey: EnvironmentKey {
    static let defaultValue: [String: ProviderIncident] = [:]
}

extension EnvironmentValues {
    var providerIncidents: [String: ProviderIncident] {
        get { self[ProviderIncidentsKey.self] }
        set { self[ProviderIncidentsKey.self] = newValue }
    }
}

/// Under a tool's heading in Usage while its provider has an incident: red for
/// major, amber for minor, the title, since when, and the status page.
struct IncidentLine: View {
    let incident: ProviderIncident
    static let height: CGFloat = 44

    static func color(_ incident: ProviderIncident) -> Color {
        incident.severity == .major ? Color(hex: 0xF06A5A) : Theme.warning
    }

    /// "Claude", "Copilot": how the peek names a tool.
    static func name(_ agent: String) -> String {
        switch agent {
        case "Copilot CLI": return "Copilot"
        case "Claude Code": return "Claude"
        default: return agent
        }
    }

    var body: some View {
        let color = Self.color(incident)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(incident.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 6)
                if let since = incident.since {
                    Text("since \(since.formatted(date: .omitted, time: .shortened))").font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                        .lineLimit(1).fixedSize()
                }
            }
            HStack(spacing: 4) {
                Text("Your agents may be slow or fail.").foregroundStyle(Theme.textSecondary)
                if let url = URL(string: incident.link) {
                    Link(destination: url) { Text("\(url.host ?? "Status page") ↗").foregroundStyle(Color(hex: 0x5AA2F0)) }
                }
            }
            .font(.system(size: 11)).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(color.opacity(0.3), lineWidth: 1))
    }
}

/// Copilot's premium requests for one account.
struct CopilotBlock: View {
    let usage: CopilotUsage
    var forecast: BurnForecast?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProviderHeader(agent: "Copilot CLI", title: usage.title, inlineNote: true) { Text(usage.host) }
            if !usage.isTracked {
                // No premium requests on this plan (Copilot Free): its chat and completions allowances instead.
                if usage.chatEntitlement > 0 {
                    LimitMeter(title: "Chat messages", used: Self.used(usage.chatRemaining, of: usage.chatEntitlement),
                               caption: allowance(usage.chatRemaining, of: usage.chatEntitlement))
                }
                if usage.completionsEntitlement > 0 {
                    LimitMeter(title: "Code completions", used: Self.used(usage.completionsRemaining, of: usage.completionsEntitlement),
                               caption: allowance(usage.completionsRemaining, of: usage.completionsEntitlement))
                }
                if usage.chatEntitlement == 0 && usage.completionsEntitlement == 0 {
                    Text("No premium requests on this plan").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            } else if usage.premiumUnlimited {
                LimitMeter(title: "Premium requests", used: 0, caption: caption, unlimited: true)
            } else {
                LimitMeter(title: "Premium requests", used: 100 - usage.percentLeft, caption: caption,
                           forecast: forecast, resetsAt: usage.resetsAt,
                           detail: "\(usage.premiumUsed.formatted()) of \(usage.premiumEntitlement.formatted())")
            }
            if usage.completionsUnlimited || usage.chatUnlimited || usage.overagePermitted {
                // The overage chip goes first when the row is too narrow for all three,
                // then "unlimited" (the ∞ says it already; hover keeps the full text).
                ViewThatFits(in: .horizontal) {
                    chips(overage: usage.overagePermitted)
                    chips(overage: false)
                    chips(overage: false, short: true)
                }
            }
        }
    }

    private func chips(overage: Bool, short: Bool = false) -> some View {
        HStack(spacing: 6) {
            if usage.completionsUnlimited { chip("infinity", "Completions unlimited", short: "Completions", if: short) }
            if usage.chatUnlimited { chip("infinity", "Chat unlimited", short: "Chat", if: short) }
            if overage { chip("plus.circle", "Overage") }
        }
    }

    /// A small fact about the plan: "∞ Chat unlimited".
    private func chip(_ symbol: String, _ text: String, short: String? = nil, if useShort: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color(nsColor: AgentStyle.mark("Copilot CLI")))
            Text(useShort ? short ?? text : text).font(.system(size: 10)).foregroundStyle(Theme.textSecondary).fixedSize()
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .help(symbol == "infinity" ? text : "Overage allowed: requests past the limit are billed instead of refused")
    }

    static func used(_ remaining: Int, of entitlement: Int) -> Double {
        entitlement > 0 ? Double(entitlement - remaining) / Double(entitlement) * 100 : 0
    }

    /// "30 of 50 · Resets 1 Dec"
    private func allowance(_ remaining: Int, of entitlement: Int) -> String {
        var parts = ["\(max(0, entitlement - remaining).formatted()) of \(entitlement.formatted())"]
        if let reset = usage.resetsAt { parts.append("Resets " + reset.formatted(.dateTime.day().month(.abbreviated))) }
        return parts.joined(separator: " · ")
    }

    /// "83 of 15,000 · Resets 1 Dec · ~552 a day to last"
    private var caption: String {
        var parts: [String] = []
        if !usage.premiumUnlimited { parts.append("\(usage.premiumUsed.formatted()) of \(usage.premiumEntitlement.formatted())") }
        if let reset = usage.resetsAt { parts.append("Resets " + reset.formatted(.dateTime.day().month(.abbreviated))) }
        if let perDay = usage.perDayToLast() { parts.append("~\(perDay.formatted()) a day to last") }
        if usage.overageUsed > 0 { parts.append("\(usage.overageUsed) over") }
        return parts.joined(separator: " · ")
    }
}

/// Antigravity's weekly quotas, read from its CLI only while this tab is open.
struct AntigravityBlock: View {
    let model: AppModel

    var body: some View {
        if model.hasContent(.antigravity) {
            VStack(alignment: .leading, spacing: 10) {
                ProviderHeader(agent: "Antigravity", title: "Antigravity") {
                    if model.antigravityLoading {
                        Text("Checking…")
                    } else if let updated = model.antigravityUpdated {
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            Text("Updated \(SessionText.ago(updated, now: context.date))").lineLimit(1).fixedSize()
                        }
                    }
                }
                if let usage = model.antigravity {
                    ForEach(usage.limits) { limit in
                        LimitMeter(title: limit.title, used: limit.percentUsed,
                                   caption: limit.resetsAt.map { "Resets " + $0.formatted(.dateTime.day().month(.abbreviated)) },
                                   forecast: model.forecast(UsageKey.antigravity(limit.id), used: limit.percentUsed,
                                                            resetsAt: limit.resetsAt, window: nil),
                                   resetsAt: limit.resetsAt)
                    }
                    if let error = model.antigravityError {
                        Text(error).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                    }
                } else if let error = model.antigravityError {
                    Text(error).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                } else {
                    Text("Checking…").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

/// OpenCode Go limits (when signed in) and today's breakdown on the left; the
/// tokens OpenCode used on this Mac, from its local database, on the right.
struct OpenCodeBlock: View {
    let model: AppModel

    var body: some View {
        if model.hasContent(.openCode) {
            // The heading spans the panel and starts the section; limits and tokens sit below it.
            VStack(alignment: .leading, spacing: 10) {
            ProviderHeader(agent: "OpenCode", title: "OpenCode") {
                if let updated = model.openCodeUpdated {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text("Updated \(SessionText.ago(updated, now: context.date))").lineLimit(1).fixedSize()
                    }
                }
            }
            UsageRow {
                VStack(alignment: .leading, spacing: 10) {
                    if let go = model.openCodeGo {
                        ForEach(go.limits) { limit in
                            LimitMeter(title: limit.title, used: limit.percentUsed,
                                       caption: limit.resetsAt.map { "Resets " + SessionText.reset($0) },
                                       forecast: model.forecast(UsageKey.openCode(limit.id), used: limit.percentUsed, resetsAt: limit.resetsAt,
                                                                window: BurnForecast.window(openCode: limit.id, resetsAt: limit.resetsAt)),
                                       resetsAt: limit.resetsAt)
                        }
                    }
                    if let usage = model.openCode {
                        Text(Self.caption(usage.today)).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                    }
                    if let error = model.openCodeError {
                        Text(error).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                    }
                }
            } usage: {
                if let usage = model.openCode {
                    OpenCodeTokensView(model: model, usage: usage)
                }
            }
            }
        }
    }

    /// "Today: 303K in · 26K out · 7.8M cache · $0.00"
    static func caption(_ today: OpenCodeTotals) -> String {
        var parts: [String] = []
        if today.input > 0 { parts.append("\(TokenCount.compact(today.input)) in") }
        // Reasoning is billed as output.
        let output = today.output + today.reasoning
        if output > 0 { parts.append("\(TokenCount.compact(output)) out") }
        if today.cacheRead + today.cacheWrite > 0 {
            parts.append("\(TokenCount.compact(today.cacheRead + today.cacheWrite)) cache")
        }
        parts.append(String(format: "$%.2f", today.cost))
        return "Today: " + parts.joined(separator: " · ")
    }
}

/// Tokens per period and per day, laid out like Claude spend.
struct OpenCodeTokensView: View {
    let model: AppModel
    let usage: OpenCodeUsage

    var body: some View {
        let tokens = { (value: Double) in TokenCount.compact(Int(value)) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("OpenCode tokens").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("this Mac").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
            }
            .help("Tokens OpenCode recorded in its local database")
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Figure(label: "Today", value: Double(usage.today.tokens), large: true, format: tokens)
                Figure(label: "7 days", value: Double(usage.last7.tokens), format: tokens)
                Figure(label: "30 days", value: Double(usage.last30.tokens), format: tokens)
            }
            SpendChart(model: model, values: usage.daily.map(Double.init),
                       hover: \.openCodeHover, format: tokens)
        }
    }
}
