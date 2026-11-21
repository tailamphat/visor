import SwiftUI
import VisorCore

/// API-equivalent value of Claude Code usage, from local transcripts.
struct SpendView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("Claude spend").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("API value").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
            }
            .help("What your Claude Code usage would cost at API prices, from local transcripts")
            if let spend = model.spend {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Figure(label: "Today", value: spend.today, large: true)
                    Figure(label: "7 days", value: spend.last7Days)
                    Figure(label: "30 days", value: spend.last30Days)
                }
                SpendChart(model: model, values: spend.daily)
            } else {
                Text("Reading transcripts…").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

struct Figure: View {
    let label: String
    let value: Double
    var large = false
    var format: (Double) -> String = Figure.compact

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(format(value)).font(.system(size: large ? 18 : 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.textMuted)
        }
    }

    static func compact(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "$%.1fK", v / 1000) }
        if v >= 100 { return String(format: "$%.0f", v) }
        return String(format: "$%.2f", v)
    }
}

/// Spend per day as an area, oldest first, ending today, with dates underneath.
/// Hovering picks a day and names it with its value; otherwise today is marked.
struct SpendChart: View {
    let model: AppModel
    let values: [Double]
    var hover: ReferenceWritableKeyPath<AppModel, Int?> = \.spendHover
    var format: (Double) -> String = Figure.compact

    /// Room at each end so the first and last date labels fit under their points.
    private static let inset: CGFloat = 14

    var body: some View {
        let focus = model[keyPath: hover].flatMap { values.indices.contains($0) ? $0 : nil }
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                let size = geo.size
                ZStack(alignment: .topLeading) {
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: size.height - 0.5))
                        p.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                    }
                    .stroke(Theme.deemphasis, lineWidth: 1)
                    area(size).fill(LinearGradient(colors: [Theme.accent.opacity(0.5), Theme.accent.opacity(0.06)],
                                                   startPoint: .top, endPoint: .bottom))
                    line(size).stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    if let focus {
                        Path { p in
                            p.move(to: CGPoint(x: point(focus, size).x, y: 0))
                            p.addLine(to: CGPoint(x: point(focus, size).x, y: size.height))
                        }
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    }
                    if !values.isEmpty {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5)
                            .position(point(focus ?? values.count - 1, size))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    var index: Int?
                    if case .active(let location) = phase, values.count > 1 {
                        let step = (size.width - 2 * Self.inset) / CGFloat(values.count - 1)
                        index = min(max(Int(((location.x - Self.inset) / step).rounded()), 0), values.count - 1)
                    }
                    if model[keyPath: hover] != index { model[keyPath: hover] = index }
                }
            }
            .frame(height: 26)

            GeometryReader { geo in
                ForEach(DayAxis.labels(days: values.count, every: 3), id: \.index) { label in
                    Text(label.text)
                        .font(.system(size: 9, weight: label.index == values.count - 1 ? .semibold : .regular))
                        .foregroundStyle(label.index == values.count - 1 ? Theme.textSecondary : Theme.textMuted)
                        .fixedSize()
                        .position(x: point(label.index, geo.size).x, y: geo.size.height / 2)
                }
            }
            .frame(height: 11)

            Group {
                if let focus {
                    Text(DayAxis.name(focus, of: values.count)).foregroundStyle(Theme.textSecondary)
                        + Text(" · \(format(values[focus]))").foregroundStyle(Theme.textPrimary)
                } else {
                    Text("Last \(values.count) days").foregroundStyle(Theme.textMuted)
                }
            }
            .font(.system(size: 10).monospacedDigit())
        }
    }

    private func point(_ index: Int, _ size: CGSize) -> CGPoint {
        let peak = max(values.max() ?? 0, 0.01)
        let step = values.count > 1 ? (size.width - 2 * Self.inset) / CGFloat(values.count - 1) : 0
        let value = values.indices.contains(index) ? values[index] : 0
        return CGPoint(x: Self.inset + CGFloat(index) * step, y: size.height - 1 - (size.height - 5) * value / peak)
    }

    private func line(_ size: CGSize) -> Path {
        Path { p in
            for i in values.indices {
                i == 0 ? p.move(to: point(i, size)) : p.addLine(to: point(i, size))
            }
        }
    }

    private func area(_ size: CGSize) -> Path {
        Path { p in
            guard !values.isEmpty else { return }
            p.move(to: CGPoint(x: point(0, size).x, y: size.height))
            for i in values.indices { p.addLine(to: point(i, size)) }
            p.addLine(to: CGPoint(x: point(values.count - 1, size).x, y: size.height))
            p.closeSubpath()
        }
    }
}
