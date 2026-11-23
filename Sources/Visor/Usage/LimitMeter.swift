import SwiftUI
import VisorCore

/// One limit: what's left as the headline, a bar of what's used, then when it resets.
struct LimitMeter: View {
    let title: String
    let used: Double
    var caption: String?
    var unlimited = false
    /// At this pace: when it runs out, or what's left at the reset. Replaces the caption.
    var forecast: BurnForecast? = nil
    var resetsAt: Date? = nil
    /// Appended to the forecast ("83 of 300").
    var detail: String? = nil

    var body: some View {
        let fill = used >= 90 ? Theme.critical : used >= 75 ? Theme.warning : Theme.accent
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(DS.font(.base, .medium)).foregroundStyle(Theme.textSecondary)
                if used >= 75 {
                    Image(systemName: "exclamationmark.triangle.fill").font(DS.font(.xs)).foregroundStyle(fill)
                }
                Spacer()
                if unlimited {
                    Text("Unlimited").font(DS.font(.md, .semibold)).foregroundStyle(Theme.textPrimary)
                } else {
                    (Text("\(Int((100 - used).rounded()))%").font(DS.font(.lg, .semibold)).foregroundColor(Theme.textPrimary)
                     + Text(" left").font(DS.font(.base)).foregroundColor(Theme.textSecondary))
                        .monospacedDigit()
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.accentTrack)
                    Capsule().fill(fill).frame(width: max(4, geo.size.width * min(used, 100) / 100))
                }
            }
            .frame(height: Theme.barHeight)
            if let forecast, let resetsAt {
                forecastText(forecast, resetsAt: resetsAt).font(DS.font(.sm)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            } else if let caption, !caption.isEmpty {
                Text(caption).font(DS.font(.sm)).foregroundStyle(Theme.textMuted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Runs out in ~1h 15m · resets in 2h 10m", "On pace · ~5% left when it resets Fri 09:00".
    private func forecastText(_ forecast: BurnForecast, resetsAt: Date) -> Text {
        let now = Date()
        var head: Text, tail: String
        switch forecast {
        case .runsOut(let at):
            let seconds = at.timeIntervalSince(now)
            let when = BurnForecast.duration(seconds).map { "in ~" + $0 }
                ?? "~" + at.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            head = Text("Runs out " + when).foregroundColor(seconds < 15 * 60 ? Theme.critical : Theme.warning)
            let days = Int(resetsAt.timeIntervalSince(at) / 86_400)
            tail = resetsAt.timeIntervalSince(now) < 86_400 || days < 1
                ? "resets " + Self.resetPhrase(resetsAt)
                : "\(days) day\(days == 1 ? "" : "s") before reset"
        case .lasts(let left):
            head = Text("On pace").foregroundColor(Theme.onPace)
            tail = "~\(Int(left.rounded()))% left when it resets " + Self.resetPhrase(resetsAt)
        }
        if let detail { tail += " · " + detail }
        return head + Text(" · " + tail).foregroundColor(Theme.textMuted)
    }

    /// "in 2h 10m", "Fri 09:00", or "1 Dec" a week or more away.
    static func resetPhrase(_ date: Date) -> String {
        date.timeIntervalSinceNow < 7 * 86_400 ? SessionText.reset(date) : date.formatted(.dateTime.day().month(.abbreviated))
    }
}
