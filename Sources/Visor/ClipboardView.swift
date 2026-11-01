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
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                Text(model.clipQuery.isEmpty ? "Search" : model.clipQuery)
                    .font(.system(size: 12)).foregroundStyle(model.clipQuery.isEmpty ? Theme.textMuted : Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text("\(shown.count) item\(shown.count == 1 ? "" : "s")").font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                if !model.clips.items.isEmpty {
                    Button("Clear all…") { model.clipboardActions?.clearAll() }
                        .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))

            if model.clips.items.isEmpty {
                Text("Nothing copied yet. Copy something and it shows up here.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        // Lazy: only rows on screen are built, so long histories stay fast.
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(ClipHistory.days(shown, now: Date()), id: \.title) { day in
                                Text(day.title).font(.system(size: 9.5, weight: .semibold)).textCase(.uppercase).tracking(0.6)
                                    .foregroundStyle(Theme.textMuted).padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 1)
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
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                    Button("Undo") { model.clipboardActions?.undo() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(ConsentButton.mint)
                }
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(Color(hex: 0x1E1E20)))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
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
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(.sRGB, red: Double(rgb[0]) / 255, green: Double(rgb[1]) / 255, blue: Double(rgb[2]) / 255))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                    .frame(width: 12, height: 12)
            } else {
                Color.clear.frame(width: 12, height: 12)
            }
            Text(label)
                .font(item.looksLikeCode ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                .foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
            if model.clipboardActions?.isOnClipboard(item.id) == true {
                Text("on clipboard").font(.system(size: 9.5)).foregroundStyle(ConsentButton.mint)
                    .padding(.horizontal, 5).overlay(Capsule().strokeBorder(ConsentButton.mint.opacity(0.35), lineWidth: 1))
            }
            Spacer(minLength: 6)
            if item.pinned { Circle().fill(ConsentButton.mint).frame(width: 5, height: 5) }
            if hovered {
                Button { model.clipboardActions?.delete(item.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(hex: 0xFF9D95))
                        .frame(width: 18, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(hex: 0xFF8F86).opacity(0.14)))
                }
                .buttonStyle(.plain).help("Delete")
            } else {
                Text(item.app).font(.system(size: 10.5)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? ConsentButton.mint.opacity(0.12) : hovered ? Color.white.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.clipHover = item.id } else if model.clipHover == item.id { model.clipHover = nil }
        }
        .onTapGesture { model.pasteClip?(item, false) }
        .contextMenu {
            Button("Paste") { model.pasteClip?(item, false) }
            Button("Paste as Plain Text") { model.pasteClip?(item, true) }
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
