import SwiftUI
import VisorCore

/// Big artwork on the left over a blurred copy of itself; title, progress and
/// controls on the right, with the play button in the artwork's colour.
struct MusicView: View {
    let model: AppModel

    var body: some View {
        if let now = model.nowPlaying {
            let tint = model.artworkTint ?? NSColor(Theme.textSecondary)
            HStack(alignment: .center, spacing: 18) {
                Artwork(image: model.artwork, size: 96, corner: 12)
                    .dsShadow(.artwork)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(now.title).font(DS.font(.xl, .semibold)).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1).help(now.title)
                        EqualizerBars(color: tint, active: now.surelyPlaying)
                        Spacer(minLength: 8)
                        volume(tint: tint)
                    }
                    Text([now.artist, now.sourceName].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(DS.font(.md)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if now.duration > 0 {
                        Progress(now: now)
                    } else if now.usesMediaKeys && !model.mediaKeysAllowed {
                        AccessibilityHint()
                            .padding(.bottom, 10)
                    } else if let browser = model.exactControlBrowser {
                        ExactControlHint(model: model, browser: browser)
                            .padding(.bottom, 10)
                    }
                    // Centred in the text column, under the progress bar.
                    HStack(spacing: 18) {
                        control("backward.fill", .previous)
                        Button { model.musicCommand?(.playPause) } label: {
                            Image(systemName: now.playPauseSymbol)
                                .font(DS.font(.xl)).foregroundStyle(Theme.surface)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(Color(nsColor: tint)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(now.stateKnown ? "" : "\(now.sourceName.components(separatedBy: " · ")[0]) is using the microphone, so Visor can't tell whether this is playing")
                        control("forward.fill", .next)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 100)
            }
            // Fill the panel below the tabs so the artwork sits in its vertical centre.
            .frame(maxHeight: .infinity)
        } else {
            EmptyState(symbol: "music.note", title: "Nothing playing",
                       detail: "Play something in Spotify, Apple Music, or YouTube in your browser.")
        }
    }

    /// System volume, beside the title so the controls have their row to themselves.
    @ViewBuilder private func volume(tint: NSColor) -> some View {
        if let volume = model.volume {
            HStack(spacing: 5) {
                Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(DS.font(.sm)).foregroundStyle(Theme.textSecondary)
                Slider(value: Binding(get: { model.volume ?? volume }, set: { model.setVolume?($0) }), in: 0...1)
                    .controlSize(.mini)
                    .tint(Color(nsColor: tint))
                    .frame(width: 70)
            }
        }
    }

    private func control(_ symbol: String, _ command: MusicCommand) -> some View {
        Button { model.musicCommand?(command) } label: {
            Image(systemName: symbol).font(DS.font(.xl)).foregroundStyle(Theme.textPrimary)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Now Playing in a panel not much wider than the notch: small artwork, title
/// and artist, the controls underneath. No volume or progress.
struct CompactMusicView: View {
    let model: AppModel

    var body: some View {
        if let now = model.nowPlaying {
            let tint = model.artworkTint ?? NSColor(Theme.textSecondary)
            HStack(alignment: .center, spacing: 12) {
                Artwork(image: model.artwork, size: 64, corner: 10)
                    .dsShadow(.panel)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(now.title).font(DS.font(.lg, .semibold)).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1).help(now.title)
                        EqualizerBars(color: tint, active: now.surelyPlaying)
                    }
                    Text([now.artist, now.sourceName].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(DS.font(.base)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer(minLength: 2)
                    HStack(spacing: 14) {
                        control("backward.fill", .previous)
                        Button { model.musicCommand?(.playPause) } label: {
                            Image(systemName: now.playPauseSymbol)
                                .font(DS.font(.lg)).foregroundStyle(Theme.surface)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color(nsColor: tint)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(now.stateKnown ? "" : "\(now.sourceName.components(separatedBy: " · ")[0]) is using the microphone, so Visor can't tell whether this is playing")
                        control("forward.fill", .next)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 70)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func control(_ symbol: String, _ command: MusicCommand) -> some View {
        Button { model.musicCommand?(command) } label: {
            Image(systemName: symbol).font(DS.font(.md)).foregroundStyle(Theme.textPrimary)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Shown while the media keys can't be pressed: a soft amber box that opens
/// the Accessibility page of System Settings. Gone once permission is given.
struct AccessibilityHint: View {
    var body: some View {
        Button {
            MediaKeys.requestPermission()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "lock.fill").font(DS.font(.sm, .semibold))
                Text("Allow Accessibility to use the controls").lineLimit(1)
                Spacer(minLength: 6)
                Text("Open Settings \u{203A}").fontWeight(.semibold).foregroundStyle(Theme.warning)
            }
            .font(DS.font(.base))
            .foregroundStyle(Theme.warning)
            .compactBanner(tint: Theme.warning)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Visor presses the media keys to control the browser, which needs Accessibility permission.")
    }
}

/// Shown while a browser keeps Visor out of its pages (Dia without its launch
/// flag): play and pause go through the media keys, which can reach the wrong
/// tab. One click reopens the browser with page access; the x hides the offer.
struct ExactControlHint: View {
    let model: AppModel
    let browser: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "dot.radiowaves.left.and.right").font(DS.font(.sm, .semibold))
            Text(model.exactControlBusy ? "Reopening \(browser)…" : "Controls may miss the tab").lineLimit(1)
            Spacer(minLength: 6)
            if !model.exactControlBusy {
                Button { model.enableExactControl?() } label: {
                    Text("Reopen \(browser) \u{203A}").fontWeight(.semibold).foregroundStyle(Theme.question)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Quits \(browser) and opens it again with page access, so play, pause and skip reach the right tab. \(browser) restores your tabs.")
                DismissButton(help: "Don't offer this again") { model.exactControlDismissed = true }
            }
        }
        .font(DS.font(.base))
        .foregroundStyle(Theme.question)
        .compactBanner(tint: Theme.question)
    }
}

/// Progress runs locally between player updates, ticking once a second.
struct Progress: View {
    let now: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = now.position(at: context.date)
            HStack(spacing: 8) {
                Text(Self.time(position))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.Fill.strong)
                        Capsule().fill(Theme.textPrimary)
                            .frame(width: now.duration > 0 ? geo.size.width * min(1, position / now.duration) : 0)
                    }
                    .frame(height: Theme.barHeight)
                    .frame(maxHeight: .infinity)
                }
                Text(Self.time(now.duration))
            }
            .frame(height: 14)
            .font(DS.font(.sm).monospacedDigit())
            .foregroundStyle(Theme.textMuted)
        }
    }

    static func time(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
