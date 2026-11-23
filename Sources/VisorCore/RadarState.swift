import Foundation

/// What identifies an installed binary, so its `--version` runs again only
/// when the file changed (an update replaces it).
public struct BinaryStamp: Codable, Equatable, Sendable {
    public var path: String
    public var size: Int64
    public var modified: Double

    public init(path: String, size: Int64, modified: Double) {
        (self.path, self.size, self.modified) = (path, size, modified)
    }

    /// The stamp of the file at `path` (already resolved), or nil when it's gone.
    public init?(path: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        self.init(path: path, size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                  modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    }
}

/// One tool the radar will check: found on this Mac with a method it has a feed for.
public struct RadarCheck: Equatable, Sendable {
    public var toolID: String
    public var method: InstallMethod
    /// The binary's resolved path.
    public var path: String
}

/// What a merge changed: the update to peek, if any, and whether the cards differ.
public struct RadarMerge: Equatable, Sendable {
    public var peek: ReleaseUpdate?
    public var visibleChanged: Bool
}

/// The release radar's memory, saved between launches: the updates on offer,
/// which were dismissed and which already peeked (both per tool and version),
/// when it last checked, and each binary's version by its stamp.
public struct RadarState: Codable, Equatable, Sendable {
    public struct CachedVersion: Codable, Equatable, Sendable {
        public var stamp: BinaryStamp
        public var version: ToolVersion
    }

    /// Every 6 hours: "a few times a day".
    public static let interval: TimeInterval = 6 * 3600
    /// The first check after launch waits this long, so it never adds to startup.
    public static let launchDelay: TimeInterval = 120
    /// "Updating…" clears by itself after this long if the binary never changes
    /// (the update failed or the window was closed).
    public static let updatingFallback: TimeInterval = 900

    public var offers: [ReleaseUpdate] = []
    public var dismissed: Set<String> = []
    public var announced: Set<String> = []
    public var lastCheck: Date?
    public var versions: [String: CachedVersion] = [:]

    public init() {}

    static func key(_ update: ReleaseUpdate) -> String { "\(update.toolID)@\(update.latest)" }

    /// The cards Usage shows, in catalog order.
    public var visibleOffers: [ReleaseUpdate] {
        offers.filter { !dismissed.contains(Self.key($0)) }
    }

    /// The tools to check, from where each binary resolved (tool id -> path):
    /// skipped tools, installs with no known method and formulae from a tap
    /// other than Homebrew core (`formulaTap` reads the receipt) are left out.
    public static func plan(located: [String: String], home: String,
                            formulaTap: (String) -> String? = { _ in nil }) -> [RadarCheck] {
        ReleaseTool.all.compactMap { tool in
            guard !tool.isSkipped, let path = located[tool.id],
                  let method = tool.installMethod(path: path, home: home),
                  tool.versionURL(for: method) != nil,
                  !isThirdPartyFormula(tool, path: path, formulaTap: formulaTap) else { return nil }
            return RadarCheck(toolID: tool.id, method: method, path: path)
        }
    }

    static func isThirdPartyFormula(_ tool: ReleaseTool, path: String, formulaTap: (String) -> String?) -> Bool {
        guard case .formula(let name)? = tool.brew, path.contains("/Cellar/\(name)/") else { return false }
        return !BrewReceipt.isCore(formulaTap(path))
    }

    /// Drops saved offers for formulae now known to come from another tap, so
    /// they go at launch rather than at the next check. True when one went.
    public mutating func dropThirdPartyTaps(located: [String: String], formulaTap: (String) -> String?) -> Bool {
        let count = offers.count
        offers.removeAll { offer in
            guard let tool = ReleaseTool.all.first(where: { $0.id == offer.toolID }), let path = located[offer.toolID] else { return false }
            return Self.isThirdPartyFormula(tool, path: path, formulaTap: formulaTap)
        }
        return offers.count != count
    }

    /// A tool's binary changed and printed `installed`. Caught up with the
    /// offer: the offer goes and comes back marked `updated` for the card to
    /// confirm. Still behind: the card's "from" version follows. nil unless
    /// the offer went.
    public mutating func confirm(_ toolID: String, installed: ToolVersion) -> ReleaseUpdate? {
        guard let index = offers.firstIndex(where: { $0.toolID == toolID }) else { return nil }
        guard installed >= offers[index].latest else {
            offers[index].installed = installed
            return nil
        }
        var done = offers.remove(at: index)
        done.installed = installed
        done.updated = true
        return done
    }

    /// What Usage shows: the visible offers plus the updates being confirmed
    /// (never one whose card was dismissed), in catalog order.
    public func cards(updated: [ReleaseUpdate]) -> [ReleaseUpdate] {
        let order = ReleaseTool.all.map(\.id)
        let pending = visibleOffers.filter { offer in !updated.contains { $0.toolID == offer.toolID } }
        let confirming = updated.filter { !dismissed.contains(Self.key($0)) }
        return (pending + confirming).sorted { (order.firstIndex(of: $0.toolID) ?? 0) < (order.firstIndex(of: $1.toolID) ?? 0) }
    }

    /// The version read for this exact binary before, if it hasn't changed.
    public func cachedVersion(_ toolID: String, stamp: BinaryStamp) -> ToolVersion? {
        guard let cached = versions[toolID], cached.stamp == stamp else { return nil }
        return cached.version
    }

    public mutating func remember(_ toolID: String, stamp: BinaryStamp, version: ToolVersion) {
        versions[toolID] = CachedVersion(stamp: stamp, version: version)
    }

    /// Folds in one check. `checked` has an entry for each tool that was read:
    /// an update, or nil when it's up to date. Tools missing from it (the feed
    /// didn't answer) keep their card. Tools no longer `installed` lose theirs.
    /// Each tool and version peeks once, ever; several at once peek the first.
    public mutating func merge(checked: [String: ReleaseUpdate?], installed: Set<String>) -> RadarMerge {
        let before = visibleOffers
        var fresh: [ReleaseUpdate] = []
        offers.removeAll { !installed.contains($0.toolID) }
        for tool in ReleaseTool.all {
            guard let outcome = checked[tool.id] else { continue }
            offers.removeAll { $0.toolID == tool.id }
            guard let update = outcome else { continue }
            offers.append(update)
            let key = Self.key(update)
            if !announced.contains(key) {
                announced.insert(key)
                if !dismissed.contains(key) { fresh.append(update) }
            }
        }
        let order = ReleaseTool.all.map(\.id)
        offers.sort { (order.firstIndex(of: $0.toolID) ?? 0) < (order.firstIndex(of: $1.toolID) ?? 0) }
        return RadarMerge(peek: fresh.first, visibleChanged: visibleOffers != before)
    }

    /// The card's x: that tool's offered version stays hidden for good.
    @discardableResult
    public mutating func dismiss(_ toolID: String) -> Bool {
        guard let offer = offers.first(where: { $0.toolID == toolID }) else { return false }
        return dismissed.insert(Self.key(offer)).inserted
    }

    /// When the next check is due: 6 hours after the last one, but never
    /// sooner than `launchDelay` after launch.
    public func nextCheck(now: Date, launch: Date) -> Date {
        let soonest = launch.addingTimeInterval(Self.launchDelay)
        guard let lastCheck else { return soonest }
        return max(lastCheck.addingTimeInterval(Self.interval), soonest)
    }
}

/// What the notch opens on.
public enum NotchOpen {
    /// Why it opened: the pointer over the notch, the clipboard hotkey, a card
    /// that opens it by itself (approval, limit back), or anything else asked for.
    public enum Reason: Sendable { case pointer, keyboard, card, request }

    public struct Choice<Tab: Equatable>: Equatable {
        public var tab: Tab
        /// For this open only: Usage shows plans (where the card is), even if Tokens was picked.
        public var showsPlans: Bool
        public var closesAccounts: Bool

        public init(tab: Tab, showsPlans: Bool, closesAccounts: Bool) {
            (self.tab, self.showsPlans, self.closesAccounts) = (tab, showsPlans, closesAccounts)
        }
    }

    /// Opening with the pointer during a release peek goes to its card in
    /// Usage; every other open keeps the tab it asked for.
    public static func choice<Tab: Equatable>(reason: Reason, peekIsRelease: Bool, current: Tab, usage: Tab) -> Choice<Tab> {
        guard reason == .pointer, peekIsRelease else { return Choice(tab: current, showsPlans: false, closesAccounts: false) }
        return Choice(tab: usage, showsPlans: true, closesAccounts: true)
    }
}
