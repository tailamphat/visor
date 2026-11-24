import SwiftUI
import VisorCore

/// Clipboard history: a search line, then everything copied, newest first,
/// one line each. Hover a row for ✕; right-click for more.

struct ClipboardView: View {
    let model: AppModel

    var body: some View {
        let shown = model.clips.search(model.clipQuery)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(DS.font(.base)).foregroundStyle(Theme.textMuted)
                // Like a text field: the caret sits before the placeholder, after typed text.
                HStack(spacing: 1) {
                    if model.clipTyping && model.clipQuery.isEmpty { BlinkingCaret() }
                    Text(model.clipQuery.isEmpty ? "Search" : model.clipQuery)
                        .font(DS.font(.md)).foregroundStyle(model.clipQuery.isEmpty ? Theme.textMuted : Theme.textPrimary)
                        .lineLimit(1)
                    if model.clipTyping && !model.clipQuery.isEmpty { BlinkingCaret() }
                }
                Spacer()
                Text("\(shown.count) item\(shown.count == 1 ? "" : "s")").font(DS.font(.sm)).foregroundStyle(Theme.textMuted)
                if !model.clips.items.isEmpty {
                    Button("Clear all…") { model.clipboardActions?.clearAll() }
                        .buttonStyle(.plain).font(DS.font(.sm)).foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(DS.Fill.subtle))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .stroke(model.clipTyping ? Theme.accent : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { model.focusClipSearch?() }

            if model.clips.items.isEmpty {
                Text("Nothing copied yet. Copy something and it shows up here.")
                    .font(DS.font(.md)).foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        // Lazy: only rows on screen are built, so long histories stay fast.
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(ClipHistory.days(shown, now: Date()), id: \.title) { day in
                                SectionHeader(day.title)
                                    .padding(.horizontal, DS.Space.md).padding(.top, DS.Space.sm).padding(.bottom, DS.Space.hair)
                                ForEach(day.items) { item in
                                    ClipRow(model: model, item: item).id(item.id)
                                }
                            }
                        }
                    }
                    .onChange(of: model.clipSelection) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.88),
                                             .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            }
        }
        .overlay(alignment: .bottom) {
            if let message = model.clipUndo {
                HStack(spacing: 10) {
                    Text(message).font(DS.font(.md)).foregroundStyle(Theme.textPrimary)
                    Button("Undo") { model.clipboardActions?.undo() }
                        .buttonStyle(.plain).font(DS.font(.md, .semibold)).foregroundStyle(DS.Palette.mint)
                }
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(Theme.raised))
                .dsShadow(.toast)
            }
        }
    }
}

struct ClipRow: View {
    let model: AppModel
    let item: ClipItem

    private var selected: Bool { model.clipSelection == item.id }
    private var hovered: Bool { model.clipHover == item.id }

    var body: some View {
        HStack(spacing: 8) {
            if let rgb = item.colorRGB {
                RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                    .fill(Color(.sRGB, red: Double(rgb[0]) / 255, green: Double(rgb[1]) / 255, blue: Double(rgb[2]) / 255))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous).strokeBorder(DS.Fill.heavy, lineWidth: 1))
                    .frame(width: 12, height: 12)
            } else {
                Color.clear.frame(width: 12, height: 12)
            }
            Text(label)
                .font(item.looksLikeCode ? DS.font(.base, design: .monospaced) : DS.font(.md))
                .foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
            if model.clipboardActions?.isOnClipboard(item.id) == true {
                Text("on clipboard").font(DS.font(.xs)).foregroundStyle(DS.Palette.mint)
                    .padding(.horizontal, DS.Space.xs).overlay(Capsule().strokeBorder(DS.Palette.mint.opacity(DS.Fill.Opacity.heavy), lineWidth: 1))
            }
            Spacer(minLength: 6)
            // Hover only fades: the buttons are always laid out over the app name,
            // so moving between rows changes no layout and the highlight keeps up.
            ZStack(alignment: .trailing) {
                HStack(spacing: 4) {
                    if item.pinned {
                        Image(systemName: "pin.fill").font(DS.font(.xs, .semibold)).foregroundStyle(DS.Palette.mint)
                    }
                    Text(item.app).font(DS.font(.sm)).foregroundStyle(Theme.textMuted).lineLimit(1)
                }
                .opacity(hovered ? 0 : 1)
                HStack(spacing: 4) {
                    // Pinned items stay through Clear and the 200-item / 30-day cleanup.
                    Button { model.clipboardActions?.togglePin(item.id) } label: {
                        Image(systemName: item.pinned ? "pin.fill" : "pin").font(DS.font(.xs, .bold))
                            .foregroundStyle(item.pinned ? DS.Palette.mint : Theme.textSecondary)
                            .frame(width: 18, height: 18)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).fill(DS.Fill.subtle))
                    }
                    .buttonStyle(.plain).help(item.pinned ? "Unpin" : "Pin: keep it through Clear and cleanup")
                    Button { model.clipboardActions?.delete(item.id) } label: {
                        Image(systemName: "xmark").font(DS.font(.xs, .bold)).foregroundStyle(DS.Palette.denyText)
                            .frame(width: 18, height: 18)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).fill(DS.Palette.rose.opacity(DS.Fill.Opacity.medium)))
                    }
                    .buttonStyle(.plain).help("Delete")
                }
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
            }
            .transaction { $0.animation = nil }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
            .fill(selected ? DS.Palette.mint.opacity(DS.Fill.Opacity.medium) : hovered ? DS.Fill.faint : .clear))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.clipHover = item.id } else if model.clipHover == item.id { model.clipHover = nil }
        }
        .onTapGesture { model.pasteClip?(item, false) }
        .contextMenu {
            Button("Copy") { model.clipboardActions?.copy(item) }
            Button(item.pinned ? "Unpin" : "Pin") { model.clipboardActions?.togglePin(item.id) }
            Divider()
            Button("Delete") { model.clipboardActions?.delete(item.id) }
        }
        .help(item.content.count > 80 ? String(item.content.prefix(400)) : "")
    }

    private var label: String {
        switch item.kind {
        case .image: return "Image"
        case .file:
            let names = item.content.split(separator: "\n").map { ($0 as NSString).lastPathComponent }
            return names.count == 1 ? names[0] : "\(names[0]) and \(names.count - 1) more"
        default: return item.title
        }
    }
}
