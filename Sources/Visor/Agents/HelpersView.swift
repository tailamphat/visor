import AppKit
import SwiftUI
import VisorCore

/// The ⑂ button on an agent card with subagents: how many, and a click opens
/// `HelpersList` under the cards. "9+" past nine; the card never grows.
struct HelpersButton: View {
    let session: AgentSession
    let model: AppModel

    var body: some View {
        let open = model.helpersOpen == session.id
        let count = session.helpers.count
        Button { model.helpersOpen = open ? nil : session.id } label: {
            HStack(spacing: 1) {
                Image(systemName: "arrow.triangle.branch").font(DS.font(.xs, .semibold))
                Text(count > 9 ? "9+" : "\(count)").font(DS.font(.xs, .bold).monospacedDigit())
            }
            .foregroundStyle(open ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 5).frame(height: 17)
            .background(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).fill(open ? Theme.accent : DS.Fill.subtle))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(session.runningHelpers) of \(count) helper\(count == 1 ? "" : "s") working. Click to see them.")
    }
}

/// A session's helpers as a trace waterfall (`HelperGraph`): who started whom on the
/// left, when and how long on one time axis, cost on the right, the critical path
/// outlined. Bars are `TraceBars` layers; running ones grow by Core Animation, so this
/// view renders only when the board publishes (it never reads the list's 1 s clock).
struct HelpersList: View {
    let session: AgentSession
    let model: AppModel
    private typealias W = HelperWaterfall

    /// The waterfall's height for a session, for the panel's size.
    static func height(for session: AgentSession, model: AppModel) -> CGFloat {
        let rows = 1 + min(session.helpers.count, AgentSession.maxHelpers)
        return CGFloat(HelperWaterfall.height(rows: rows, detail: detail(for: session, model: model)))
    }

    /// The selected row's card, if a helper row is selected in this turn.
    static func detail(for session: AgentSession, model: AppModel) -> HelperDetail? {
        let ids = [session.helpers.map(\.id), ["main"]].flatMap { $0 }
        guard let id = HelperWaterfall.selected(model.helperSelected, turn: model.helperSelectedTurn,
                                                current: session.turnStart, rows: ids) else { return nil }
        return HelperDetail(session: session, rowID: id)
    }

    var body: some View {
        let graph = HelperGraph(session: session, now: Date())
        let costs = W.costs(session: session)
        let selected = W.selected(model.helperSelected, turn: model.helperSelectedTurn, current: session.turnStart,
                                  rows: graph.rows.map(\.id))
        VStack(alignment: .leading, spacing: 0) {
            header(graph)
            HStack(spacing: CGFloat(W.gap)) {
                Spacer().frame(width: CGFloat(W.nameWidth))
                axis(graph)
                Spacer().frame(width: CGFloat(W.costWidth))
            }
            .frame(height: CGFloat(W.axisHeight))
            let index = selected.flatMap { id in graph.rows.firstIndex { $0.id == id } }
            if let index, let selected, let detail = HelperDetail(session: session, rowID: selected) {
                rows(graph, Array(graph.rows[...index]), selected: selected, costs: costs)
                HelperDetailCard(detail: detail).padding(.vertical, CGFloat(W.detailGap) / 2)
                if index + 1 < graph.rows.count {
                    rows(graph, Array(graph.rows[(index + 1)...]), selected: selected, costs: costs)
                }
            } else {
                rows(graph, graph.rows, selected: selected, costs: costs)
            }
            caption(graph)
        }
        .padding(CGFloat(W.padding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(DS.Fill.subtle, lineWidth: 1))
    }

    /// Some of the graph's rows: names, bars (the same axis, so a split lines up) and costs,
    /// with the selection highlight and a click area per row.
    private func rows(_ graph: HelperGraph, _ shown: [HelperGraph.Row], selected: String?, costs: [String: String]) -> some View {
        let rowHeight = CGFloat(W.rowHeight)
        var part = graph
        part.rows = shown
        return HStack(alignment: .top, spacing: CGFloat(W.gap)) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { name($0).frame(height: rowHeight) }
            }
            .frame(width: CGFloat(W.nameWidth), alignment: .leading)
            TraceBars(graph: part, rowHeight: rowHeight)
                .frame(height: rowHeight * CGFloat(shown.count))
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(shown) { row in
                    Text(costs[row.id] ?? "").font(DS.font(.sm).monospacedDigit()).foregroundStyle(Theme.textMuted)
                        .lineLimit(1).frame(height: rowHeight)
                }
            }
            .frame(width: CGFloat(W.costWidth), alignment: .trailing)
        }
        .background(alignment: .top) {
            VStack(spacing: 0) {
                ForEach(shown) { row in
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .fill(selected == row.id ? DS.Fill.subtle : Color.clear)
                        .frame(height: rowHeight)
                }
            }
            .padding(.horizontal, -DS.Space.xs)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                ForEach(shown) { row in
                    Button {
                        model.helperSelected = W.toggle(selected: selected, row: row.id)
                        model.helperSelectedTurn = session.turnStart
                    } label: {
                        Color.clear.frame(height: rowHeight).frame(maxWidth: .infinity).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Agent mark, "project · task", and "18m · $2.40" on the right.
    private func header(_ graph: HelperGraph) -> some View {
        HStack(spacing: DS.Space.sm) {
            AgentMark(agent: session.agent, size: 11)
            (Text(session.project).font(DS.font(.base, .semibold)).foregroundColor(Theme.textPrimary)
                + Text(session.task.map { " · \($0)" } ?? "").font(DS.font(.base)).foregroundColor(Theme.textMuted))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: DS.Space.md)
            HelpersTurnTime(session: session, model: model, finished: graph.turnSeconds)
        }
        .frame(height: CGFloat(W.headerHeight))
    }

    /// Tick labels on the track: the first left-aligned, the last right-aligned.
    private func axis(_ graph: HelperGraph) -> some View {
        GeometryReader { geo in
            let label: CGFloat = 32
            ForEach(Array(graph.ticks.enumerated()), id: \.offset) { i, tick in
                let x = CGFloat(tick.x) * geo.size.width
                let first = i == 0, last = i == graph.ticks.count - 1
                Text(tick.label).font(DS.font(.xs).monospacedDigit()).foregroundStyle(Theme.textMuted)
                    .frame(width: label, alignment: first ? .leading : last ? .trailing : .center)
                    .offset(x: first ? 0 : last ? geo.size.width - label : x - label / 2)
            }
        }
    }

    /// "├ builder cart.ts": connectors, the helper's type, its task dimmed.
    private func name(_ row: HelperGraph.Row) -> some View {
        let main = row.id == "main" && row.depth == 0
        return (Text(row.prefix).foregroundColor(Theme.textMuted)
            + Text(main ? "main session" : row.type ?? row.title).foregroundColor(Theme.textPrimary)
            + Text(main ? "" : " \(row.title)").foregroundColor(Theme.textMuted))
            .font(DS.font(.base)).lineLimit(1).truncationMode(.tail)
    }

    /// "Critical path: Plan then builder (14 of 18 min)" and "perf failed".
    private func caption(_ graph: HelperGraph) -> some View {
        HStack(spacing: DS.Space.sm) {
            if let text = W.caption(graph) {
                Circle().strokeBorder(Theme.textPrimary, lineWidth: 1.5).frame(width: 7, height: 7)
                Text(text).font(DS.font(.sm)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: DS.Space.md)
            if let failed = W.failures(graph) {
                Text(failed).font(DS.font(.sm, .medium)).foregroundStyle(Theme.critical).lineLimit(1).fixedSize()
            }
        }
        .frame(height: CGFloat(W.captionHeight))
    }
}

/// The waterfall header's time and cost. Its own view so only it reads the list's
/// 1 s clock while the turn runs; the waterfall itself stays still.
private struct HelpersTurnTime: View {
    let session: AgentSession
    let model: AppModel
    let finished: TimeInterval

    var body: some View {
        let time = session.isActive
            ? SessionText.elapsed(since: session.turnStart ?? session.since, now: model.agentsNow)
            : HelperWaterfall.elapsed(seconds: finished)
        Text([time, session.cost?.label].compactMap { $0 }.joined(separator: " · "))
            .font(DS.font(.sm).monospacedDigit()).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
    }
}

/// The card under a selected helper row: title, type and time; task; what it's doing;
/// tools; context; cost and model; what it started with. Only lines with data show.
private struct HelperDetailCard: View {
    let detail: HelperDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(detail.lines, id: \.self) { line($0).frame(height: CGFloat(HelperDetail.lineHeight)) }
        }
        .font(DS.font(.sm)).lineLimit(1)
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, CGFloat(HelperDetail.padding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).fill(Theme.raised))
    }

    @ViewBuilder private func line(_ line: HelperDetail.Line) -> some View {
        switch line {
        case .title:
            HStack(spacing: DS.Space.sm) {
                Text(detail.title).font(DS.font(.sm, .semibold)).foregroundStyle(Theme.textPrimary)
                if let pill = detail.pill {
                    Text(pill).font(DS.font(.xs)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, DS.Space.xs)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous).fill(DS.Fill.subtle))
                }
                if detail.failed { Text("failed").font(DS.font(.sm, .medium)).foregroundStyle(Theme.critical) }
                Spacer(minLength: DS.Space.md)
                if let duration = detail.duration {
                    Text(duration).monospacedDigit().foregroundStyle(Theme.textSecondary)
                }
            }
        case .task: labeled("Task", detail.task)
        case .now: labeled("Now", detail.now ?? "")
        case .tools: labeled("Tools", detail.tools ?? "")
        case .context:
            HStack(spacing: DS.Space.sm) {
                label("Context")
                GeometryReader { box in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.Fill.subtle)
                        Capsule().fill(Theme.accent).frame(width: box.size.width * CGFloat(detail.contextShare))
                    }
                    .frame(height: 4).frame(maxHeight: .infinity)
                }
                Text("\(detail.contextK ?? 0)k").monospacedDigit().foregroundStyle(Theme.textPrimary)
            }
        case .cost: labeled("Cost", detail.cost ?? "")
        case .started:
            if let started = detail.started {
                HStack(spacing: DS.Space.sm) {
                    label("Started")
                    GeometryReader { box in
                        let gaps = CGFloat(max(0, started.parts.count - 1)) * DS.Space.hair
                        HStack(spacing: DS.Space.hair) {
                            ForEach(Array(started.parts.enumerated()), id: \.offset) { _, part in
                                Rectangle().fill(HarnessList.color(part.kind))
                                    .frame(width: max(0, (box.size.width - gaps) * CGFloat(part.share)))
                            }
                        }
                        .frame(height: 6).clipShape(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
                        .frame(maxHeight: .infinity)
                    }
                    Text("parts about").foregroundStyle(Theme.textMuted).fixedSize()
                    Text(started.total).monospacedDigit().foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text + ":").foregroundStyle(Theme.textMuted).frame(width: 52, alignment: .leading)
    }

    private func labeled(_ name: String, _ value: String) -> some View {
        HStack(spacing: DS.Space.sm) {
            label(name)
            Text(value).foregroundStyle(Theme.textPrimary).truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }
}
