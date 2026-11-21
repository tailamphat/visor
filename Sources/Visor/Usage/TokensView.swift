import SwiftUI
import VisorCore

/// Limits or Tokens: two small buttons on the Usage tab, like the Agents tab's list/office switch.
struct UsageViewSwitch: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            option("gauge.with.dots.needle.50percent", tokens: false, help: "Plans and limits")
            option("chart.bar.fill", tokens: true, help: "Tokens used")
        }
        .padding(1)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private func option(_ symbol: String, tokens: Bool, help: String) -> some View {
        let on = model.usageTokens == tokens
        return Button { model.usageTokens = tokens } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(on ? Theme.textPrimary : Theme.textMuted)
                .frame(width: 24, height: 15)
                .background(Capsule().fill(on ? Color.white.opacity(0.16) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The bar above plan limits: what it is, and the switch to Tokens.
struct UsageBar: View {
    let model: AppModel
    static let height: CGFloat = 18
    static let gap: CGFloat = 6

    var body: some View {
        HStack(spacing: 0) {
            Text("Plans & limits").font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).tracking(0.6)
                .foregroundStyle(Theme.textMuted)
            Spacer(minLength: 8)
            // Connected accounts, beside the switch (the header's slots are the same on every tab).
            Button {
                model.showAccounts = true
                model.refreshPlan?()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 24, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Connected accounts")
            .padding(.trailing, 6)
            UsageViewSwitch(model: model)
        }
        .frame(height: Self.height)
    }
}

/// Every token used across tools and models, like tokscale: a headline, a
/// stacked chart by model, and the biggest models, days and tools.
struct TokensView: View {
    let model: AppModel
    static let height: CGFloat = 396

    private static let palette: [UInt32] = [0xD97757, 0xA78BFA, 0x7EE0A0, 0x5AA2F0, 0xF2C14E, 0xF29A9A, 0x4FB8A8, 0xC9B8FF]

    var body: some View {
        let summary = model.tokenLedger.summary(days: model.tokensRange)
        let colors = Self.colors(summary)
        VStack(alignment: .leading, spacing: 10) {
            bar
            if model.tokenLedger.days.isEmpty {
                EmptyState(symbol: "chart.bar", title: "No tokens yet",
                           detail: "Visor counts the tokens Claude Code, Copilot CLI and OpenCode use on this Mac.")
            } else {
                hero(summary)
                switch model.tokensPage {
                case .overview:
                    TokensChart(model: model, summary: summary, colors: colors)
                    section("Top models")
                    rows(summary.models.prefix(3).map { ($0.model, $0.tool, $0.count, colors[$0.model] ?? Theme.textMuted) }, of: summary.total.total)
                case .models:
                    section("All models")
                    ScrollView(.vertical, showsIndicators: false) {
                        rows(summary.models.map { ($0.model, $0.tool, $0.count, colors[$0.model] ?? Theme.textMuted) }, of: summary.total.total)
                    }
                case .daily:
                    TokensChart(model: model, summary: summary, colors: colors)
                    daily(summary)
                case .tools:
                    section("By tool")
                    rows(summary.tools.map { ($0.tool, nil, $0.count, Color(nsColor: AgentStyle.mark($0.tool))) }, of: summary.total.total)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// A colour per model, biggest first, so the same model keeps its colour in the chart and the list.
    static func colors(_ summary: TokenSummary) -> [String: Color] {
        var out: [String: Color] = [:]
        for model in summary.models where out[model.model] == nil {
            out[model.model] = Color(hex: palette[out.count % palette.count])
        }
        return out
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: 2) {
            ForEach(TokensPage.allCases, id: \.self) { page in
                Button { model.tokensPage = page } label: {
                    Text(page.rawValue.capitalized)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.tokensPage == page ? Theme.textPrimary : Theme.textMuted)
                        .padding(.horizontal, 6)
                        .frame(height: UsageBar.height)
                        .overlay(alignment: .bottom) {
                            if model.tokensPage == page { Capsule().fill(Theme.textPrimary).frame(height: 1.5) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                range("7D", 7)
                range("30D", 30)
                range("All", nil)
            }
            .padding(1)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .padding(.trailing, 6)
            UsageViewSwitch(model: model)
        }
        .frame(height: UsageBar.height)
    }

    private func range(_ title: String, _ days: Int?) -> some View {
        let on = model.tokensRange == days
        return Button { model.tokensRange = days } label: {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(on ? Theme.textPrimary : Theme.textMuted)
                .frame(width: 30, height: 15)
                .background(Capsule().fill(on ? Color.white.opacity(0.16) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Headline

    /// All tokens, then the ones that were new work (without cache reads), active days and the busiest day.
    private func hero(_ summary: TokenSummary) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 18) {
            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text(Self.headline(summary.total.total))
                    .font(.system(size: 26, weight: .bold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                Text("tokens").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
            fact(TokenCount.compact(summary.total.withoutCacheRead), "without cache reads")
            fact("\(summary.activeDays)", summary.activeDays == 1 ? "active day" : "active days")
            if let peak = summary.peak { fact(TokenCount.compact(peak.total), "peak · \(Self.dayName(peak.day, weekday: false))") }
        }
        .help("Cache reads are the conversation re-read from cache on every reply: cheap, and most of the total.")
    }

    /// Billions with two decimals (2.96B, not 3B); smaller counts as usual.
    static func headline(_ value: Int) -> String {
        value >= 1_000_000_000 ? String(format: "%.2fB", Double(value) / 1_000_000_000) : TokenCount.compact(value)
    }

    private func fact(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 12.5, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textSecondary)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.textMuted).lineLimit(1)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).tracking(0.6)
            .foregroundStyle(Theme.textMuted)
    }

    // MARK: Lists

    /// A row per model or tool: its total and share, a bar, and the four kinds of tokens.
    private func rows(_ items: [(name: String, tool: String?, count: TokenCount, color: Color)], of total: Int) -> some View {
        VStack(spacing: 4) {
            ForEach(items, id: \.name) { item in
                let share = total > 0 ? Double(item.count.total) / Double(total) : 0
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 8, height: 8)
                        Text(item.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        if let tool = item.tool { Text(tool).font(.system(size: 10.5)).foregroundStyle(Theme.textMuted).lineLimit(1) }
                        Spacer(minLength: 8)
                        Text(TokenCount.compact(item.count.total)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                        Text(String(format: "%.1f%%", share * 100)).font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(Theme.textMuted).frame(width: 40, alignment: .trailing)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.07))
                            Capsule().fill(item.color).frame(width: max(2, geo.size.width * share))
                        }
                    }
                    .frame(height: Theme.barHeight)
                    Text("In \(TokenCount.compact(item.count.input)) · Out \(TokenCount.compact(item.count.output)) · Cache read \(TokenCount.compact(item.count.cacheRead)) · Cache write \(TokenCount.compact(item.count.cacheWrite))")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.raised))
            }
        }
    }

    /// A row per day with tokens, newest first, across the full width: the
    /// number columns share the room left of the day.
    private func daily(_ summary: TokenSummary) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("DAY").gridColumnAlignment(.leading)
                    ForEach(["IN", "OUT", "CACHE R", "CACHE W", "TOTAL"], id: \.self) { Text($0).frame(maxWidth: .infinity, alignment: .trailing) }
                }
                .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.textMuted)
                ForEach(summary.daily) { day in
                    GridRow {
                        Text(Self.dayName(day.day, weekday: true)).foregroundStyle(Theme.textSecondary)
                        Text(TokenCount.compact(day.count.input))
                        Text(TokenCount.compact(day.count.output))
                        Text(TokenCount.compact(day.count.cacheRead))
                        Text(TokenCount.compact(day.count.cacheWrite))
                        Text(TokenCount.compact(day.count.total)).fontWeight(.semibold).foregroundStyle(Theme.textPrimary)
                    }
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayName(_ key: String, weekday: Bool) -> String {
        guard let date = parser.date(from: key) else { return key }
        return date.formatted(weekday ? .dateTime.weekday(.abbreviated).month(.abbreviated).day() : .dateTime.month(.abbreviated).day())
    }
}

/// A stacked bar per day, by model; hover a day for its models. Its own view,
/// so hovering redraws only the chart, not the summary and lists around it.
struct TokensChart: View {
    let model: AppModel
    let summary: TokenSummary
    let colors: [String: Color]

    var body: some View {
        let series = summary.series
        let peak = max(1, series.map(\.total).max() ?? 1)
        let order = summary.models.map(\.model)
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width / CGFloat(max(series.count, 1))
                Canvas { context, size in
                    for (i, day) in series.enumerated() {
                        var y = size.height
                        for name in order.reversed() {
                            guard let value = day.byModel[name], value > 0 else { continue }
                            let h = CGFloat(value) / CGFloat(peak) * size.height
                            y -= h
                            let rect = CGRect(x: CGFloat(i) * width + 0.5, y: y, width: max(1, width - 1), height: h)
                            context.fill(Path(rect), with: .color(colors[name] ?? .gray))
                        }
                        if day.day == model.tokensHover {
                            context.fill(Path(CGRect(x: CGFloat(i) * width, y: 0, width: width, height: size.height)),
                                         with: .color(.white.opacity(0.06)))
                        }
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let at):
                        let i = min(max(Int(at.x / width), 0), series.count - 1)
                        let day = series.isEmpty ? nil : series[i].day
                        if model.tokensHover != day { model.tokensHover = day }
                    case .ended:
                        model.tokensHover = nil
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let hover = model.tokensHover, let i = series.firstIndex(where: { $0.day == hover }) {
                        tooltip(series[i], colors, order)
                            .offset(x: min(max(CGFloat(i) * width - 70, 0), geo.size.width - 170), y: -4)
                    }
                }
            }
            .frame(height: 96)
            HStack {
                if let first = series.first { Text(TokensView.dayName(first.day, weekday: false)) }
                Spacer()
                if let last = series.last, series.count > 1 { Text(TokensView.dayName(last.day, weekday: false)) }
            }
            .font(.system(size: 9).monospacedDigit()).foregroundStyle(Theme.textMuted)
            // The biggest four, so names fit; the tooltip names every model.
            legend(order.prefix(4), colors)
        }
    }

    private func tooltip(_ day: TokenSummary.Day, _ colors: [String: Color], _ order: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(TokensView.dayName(day.day, weekday: true)) · \(TokenCount.compact(day.total))")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            ForEach(order.filter { (day.byModel[$0] ?? 0) > 0 }, id: \.self) { name in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(colors[name] ?? .gray).frame(width: 7, height: 7)
                    Text(name).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(TokenCount.compact(day.byModel[name] ?? 0)).monospacedDigit()
                }
                .font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
            }
            if day.total == 0 { Text("No tokens").font(.system(size: 10.5)).foregroundStyle(Theme.textMuted) }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(width: 170, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: 0x1A1A19)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(hex: 0x2E2D2B)))
        .allowsHitTesting(false)
    }

    private func legend(_ names: ArraySlice<String>, _ colors: [String: Color]) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(names), id: \.self) { name in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(colors[name] ?? .gray).frame(width: 7, height: 7)
                    Text(name).lineLimit(1)
                }
            }
        }
        .font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
    }
}
