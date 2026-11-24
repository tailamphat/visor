import SwiftUI
import VisorCore

/// Connected accounts: whether Visor can read each tool's usage, why not, and
/// one button to fix it. The switch hides a tool from the Usage tab and the notch.
struct AccountsView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { model.showAccounts = false } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(DS.font(.sm, .semibold))
                        Text("Usage").font(DS.font(.md, .medium))
                    }
                    .foregroundStyle(Theme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("Connected accounts").font(DS.font(.lg, .semibold)).foregroundStyle(Theme.textPrimary)
            }
            VStack(spacing: Self.gap) {
                ForEach(model.providerOrder, id: \.self) { provider in
                    let dragged = model.accountsDrag?.provider == provider
                    AccountRow(model: model, provider: provider, grip: grip(provider))
                        .offset(y: offset(provider))
                        .zIndex(dragged ? 1 : 0)
                        .dsShadow(.lifted, shown: dragged)
                }
            }
        }
    }
}

extension AccountsView {
    static let gap: CGFloat = 4
    /// A row (44) and the gap below it.
    static let pitch: CGFloat = 48

    /// Where a row sits while another is dragged: the dragged one follows the
    /// pointer, the ones it passes step aside.
    private func offset(_ provider: ConnectionProvider) -> CGFloat {
        guard let drag = model.accountsDrag, let from = model.providerOrder.firstIndex(of: drag.provider),
              let index = model.providerOrder.firstIndex(of: provider) else { return 0 }
        if provider == drag.provider { return drag.translation }
        let to = ConnectionProvider.dropIndex(from: from, translation: drag.translation, pitch: Self.pitch, count: model.providerOrder.count)
        if from < to, index > from, index <= to { return -Self.pitch }
        if to < from, index >= to, index < from { return Self.pitch }
        return 0
    }

    /// The handle: drag it to reorder the tools in Usage and the closed notch.
    private func grip(_ provider: ConnectionProvider) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(DS.font(.base, .semibold))
            .foregroundStyle(Theme.textMuted)
            .frame(width: 18, height: 26)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in model.accountsDrag = (provider, value.translation.height) }
                .onEnded { value in
                    guard let from = model.providerOrder.firstIndex(of: provider) else { return }
                    let to = ConnectionProvider.dropIndex(from: from, translation: value.translation.height,
                                                          pitch: Self.pitch, count: model.providerOrder.count)
                    withAnimation(.easeOut(duration: 0.18)) {
                        model.providerOrder = ConnectionProvider.move(provider, to: to, in: model.providerOrder)
                        model.accountsDrag = nil
                    }
                })
            .help("Drag to change the order in Usage and the closed notch")
    }
}

struct AccountRow<Grip: View>: View {
    let model: AppModel
    let provider: ConnectionProvider
    let grip: Grip

    var body: some View {
        // The switch is your choice; a tool that isn't installed says so in its row.
        let shown = model.chosen(provider)
        let state = model.connection(provider)
        HStack(spacing: 10) {
            grip.padding(.trailing, -4)
            AgentMark(agent: provider.agent, size: 14)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).fill(AgentStyle.tile))
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.title).font(DS.font(.md, .semibold)).foregroundStyle(Theme.textPrimary)
                HStack(spacing: 5) {
                    Circle().fill(shown ? tone(state.tone) : Theme.textMuted).frame(width: 6, height: 6)
                    Text(shown ? state.text : "Hidden")
                        .font(DS.font(.base)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.tail)
                }
                .help(shown ? state.text : "Hidden")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if shown, let action = state.action {
                Button(label(action)) { model.connectionAction?(provider, action) }
                    .buttonStyle(CardButton(action == .refresh ? .secondary : .primary))
            }
            // Drawn here: a system switch in the notch panel, never the key window, looks switched off.
            Button {
                if shown { model.hiddenProviders.insert(provider) } else {
                    model.hiddenProviders.remove(provider)
                    model.connectionAction?(provider, .refresh)
                }
            } label: {
                Capsule().fill(shown ? Theme.good : Theme.deemphasis)
                    .frame(width: 28, height: 16)
                    .overlay(alignment: shown ? .trailing : .leading) {
                        Circle().fill(Theme.textPrimary).frame(width: 12, height: 12).padding(2)
                    }
                    .animation(.easeOut(duration: 0.15), value: shown)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(shown ? "Hide \(provider.title)" : "Show \(provider.title)")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(DS.Fill.faint))
        .opacity(shown ? 1 : 0.5)
    }

    private func label(_ action: ConnectionState.Action) -> String {
        switch action {
        case .allowAccess: return "Allow access"
        case .signIn: return "Sign in…"
        case .refresh: return "Refresh"
        }
    }

    private func tone(_ tone: ConnectionState.Tone) -> Color {
        switch tone {
        case .good: return Theme.good
        case .warning: return Theme.warning
        case .bad: return Theme.critical
        case .neutral: return Theme.textMuted
        }
    }
}
