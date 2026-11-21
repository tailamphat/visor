import AppKit
import SwiftUI
import VisorCore

/// The Agents tab as an office: each tool a table, each session a little
/// person who walks to where its work happens. A bar above the room sums it up
/// and switches back to the list.
struct OfficeView: View {
    let model: AppModel
    /// Points per room pixel.
    static let scale = 2.0
    static let barHeight: CGFloat = 18
    static let barGap: CGFloat = 6

    /// The bar and the room, for the panel's height.
    static func height(for sessions: [AgentSession]) -> CGFloat {
        barHeight + barGap + CGFloat(Office.place(sessions).layout.height * scale)
    }

    var body: some View {
        let scene = Office.place(model.board.sessions)
        VStack(spacing: Self.barGap) {
            HStack(spacing: 0) {
                summary(scene)
                Spacer(minLength: 8)
                worldMenu
                AwakeCup(model: model).padding(.trailing, 6)
                AgentsViewSwitch(model: model)
            }
            .frame(height: Self.barHeight)
            .padding(.horizontal, NotchLayout.inset)
            OfficeCanvas(model: model)
                .frame(width: CGFloat(OfficeLayout.width * Self.scale), height: CGFloat(scene.layout.height * Self.scale))
                .overlay(alignment: .top) {
                    if model.officePicker { OfficeWorldPicker(model: model).transition(.opacity) }
                }
                .animation(.easeOut(duration: 0.12), value: model.officePicker)
        }
    }

    /// Opens the world setting over the room.
    private var worldMenu: some View {
        Button { model.officePicker.toggle() } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.officePicker ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
        .help("Office world: \(model.officeWorld.title)")
    }

    private func summary(_ scene: OfficeScene) -> some View {
        let sessions = model.board.sessions
        let tools = Set(sessions.map(\.agent)).count
        var text = Text("\(sessions.count) \(sessions.count == 1 ? "agent" : "agents") · \(tools) \(tools == 1 ? "tool" : "tools")")
            .foregroundColor(Theme.textMuted)
        if scene.waiting > 0 { text = text + Text(" · \(scene.waiting) waiting").foregroundColor(Theme.warning) }
        if scene.hidden > 0 { text = text + Text(" · \(scene.hidden) not shown").foregroundColor(Theme.textMuted) }
        return text.font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).tracking(0.6).lineLimit(1)
    }
}

/// The room itself, as Core Animation layers like the notch's pulse: walking,
/// typing and waving loop in the window server at a low frame rate, and the app
/// only does work when a session changes.
struct OfficeCanvas: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> OfficeLayerView { OfficeLayerView() }

    func updateNSView(_ view: OfficeLayerView, context: Context) {
        view.focus = model.focusAgent
        view.show(Office.place(model.board.sessions), sessions: model.board.sessions, world: model.officeWorld)
    }
}
