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
    static func height(for session: AgentSession) -> CGFloat {
        CGFloat(HelperWaterfall.height(rows: 1 + min(session.helpers.count, AgentSession.maxHelpers)))
    }

    var body: some View {
        let graph = HelperGraph(session: session, now: Date())
        let costs = W.costs(session: session)
        let rowHeight = CGFloat(W.rowHeight)
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
            HStack(alignment: .top, spacing: CGFloat(W.gap)) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(graph.rows) { name($0).frame(height: rowHeight) }
                }
                .frame(width: CGFloat(W.nameWidth), alignment: .leading)
                TraceBars(graph: graph, rowHeight: rowHeight)
                    .frame(height: rowHeight * CGFloat(graph.rows.count))
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(graph.rows) { row in
                        Text(costs[row.id] ?? "").font(DS.font(.sm).monospacedDigit()).foregroundStyle(Theme.textMuted)
                            .lineLimit(1).frame(height: rowHeight)
                    }
                }
                .frame(width: CGFloat(W.costWidth), alignment: .trailing)
            }
            .background(alignment: .top) {
                VStack(spacing: 0) {
                    ForEach(graph.rows) { row in
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .fill(selected == row.id ? DS.Fill.subtle : Color.clear)
                            .frame(height: rowHeight)
                    }
                }
                .padding(.horizontal, -DS.Space.xs)
            }
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    ForEach(graph.rows) { row in
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
            caption(graph)
        }
        .padding(CGFloat(W.padding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).strokeBorder(DS.Fill.subtle, lineWidth: 1))
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
