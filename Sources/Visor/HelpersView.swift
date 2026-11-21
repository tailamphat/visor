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
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5, weight: .semibold))
                Text(count > 9 ? "9+" : "\(count)").font(.system(size: 8.5, weight: .bold).monospacedDigit())
            }
            .foregroundStyle(open ? Color.white : Theme.textSecondary)
            .padding(.horizontal, 5).frame(height: 17)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(open ? Theme.accent : Color.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(session.runningHelpers) of \(count) helper\(count == 1 ? "" : "s") working. Click to see them.")
    }
}

/// What each of a session's subagents is doing: running ones first, at most
/// `rows`, then "+n more". Fixed ceiling, so many helpers never stretch the panel.
struct HelpersList: View {
    let session: AgentSession
    static let rows = 6
    static let rowHeight: CGFloat = 28
    static let lineHeight: CGFloat = 16

    /// The list's height for a session, for the panel's size.
    static func height(for session: AgentSession) -> CGFloat {
        let shown = session.helperRows(limit: rows)
        return 12 + lineHeight + CGFloat(shown.rows.count) * rowHeight + (shown.more > 0 ? lineHeight : 0)
    }

    var body: some View {
        let shown = session.helperRows(limit: Self.rows)
        let running = session.runningHelpers
        VStack(alignment: .leading, spacing: 0) {
            header("\(session.project) · \(session.helpers.count) helper\(session.helpers.count == 1 ? "" : "s")" + (running > 0 ? " · \(running) working" : ""))
            ForEach(shown.rows) { helper in
                HStack(spacing: 9) {
                    if helper.done {
                        Circle().fill(ConsentButton.mint).frame(width: 9, height: 9)
                    } else {
                        HelperSpinner().frame(width: 10, height: 10)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(helper.task).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text([helper.type, helper.done ? "Done" : helper.activity ?? "Thinking"].joined(separator: " · "))
                            .font(.system(size: 10.5)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(height: Self.rowHeight)
            }
            if shown.more > 0 {
                let rest = session.helpers.count - shown.rows.count
                let restRunning = running - shown.rows.filter { !$0.done }.count
                header("+\(rest) more" + (restRunning > 0 ? " · \(restRunning) working, \(rest - restRunning) done" : " · done"))
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: 0x0B0B0D)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.system(size: 9.5, weight: .semibold)).textCase(.uppercase).tracking(0.6)
            .foregroundStyle(Theme.textMuted).lineLimit(1)
            .padding(.horizontal, 6).frame(height: Self.lineHeight, alignment: .center)
    }
}

/// A small arc that turns while a helper works: a Core Animation layer, so it
/// costs nothing on the main thread.
struct HelperSpinner: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let track = CAShapeLayer(), arc = CAShapeLayer()
        let rect = CGRect(x: 1, y: 1, width: 8, height: 8)
        for (layer, color, end) in [(track, NSColor.white.withAlphaComponent(0.15), 1.0), (arc, NSColor(hex: 0x3987E5), 0.3)] {
            layer.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
            layer.path = CGPath(ellipseIn: rect, transform: nil)
            layer.fillColor = nil
            layer.strokeColor = color.cgColor
            layer.lineWidth = 1.8
            layer.lineCap = .round
            layer.strokeEnd = end
            view.layer?.addSublayer(layer)
        }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 1
        spin.repeatCount = .infinity
        spin.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 24)
        arc.add(spin, forKey: "spin")
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? { CGSize(width: 10, height: 10) }
}
