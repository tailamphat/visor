import Foundation

/// API list prices in US dollars per million tokens.
public struct ModelPrice: Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var cacheRead: Double

    /// Standard cache pricing: 5-minute writes 1.25x input, 1-hour writes 2x, reads 0.1x.
    public init(input: Double, output: Double, cacheRead: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheWrite5m = input * 1.25
        self.cacheWrite1h = input * 2
        self.cacheRead = cacheRead ?? input * 0.1
    }
}

public enum Pricing {
    /// Model id prefixes, most specific first. Prices as of 2026-09.
    static let table: [(prefix: String, price: ModelPrice)] = [
        ("claude-fable-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", ModelPrice(input: 10, output: 50, cacheRead: 1)),
        ("claude-mythos-5", ModelPrice(input: 10, output: 50, cacheRead: 1)),
        ("claude-opus-5-5", ModelPrice(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4-8", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4-7", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4-6", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4-5", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4", ModelPrice(input: 15, output: 75)),
        ("claude-sonnet-5-5", ModelPrice(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-5", ModelPrice(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-4", ModelPrice(input: 3, output: 15)),
        ("claude-3-7-sonnet", ModelPrice(input: 3, output: 15)),
        ("claude-haiku-4-5", ModelPrice(input: 1, output: 5)),
        ("claude-3-5-haiku", ModelPrice(input: 0.8, output: 4)),
    ]

    public static func price(for model: String) -> ModelPrice? {
        table.first { model.hasPrefix($0.prefix) }?.price
    }

    /// What one response would have cost on the API. Fast mode bills 2x.
    public static func cost(of usage: TokenUsage) -> Double {
        guard let p = price(for: usage.model) else { return 0 }
        let dollars = Double(usage.input) * p.input
            + Double(usage.output) * p.output
            + Double(usage.cacheWrite5m) * p.cacheWrite5m
            + Double(usage.cacheWrite1h) * p.cacheWrite1h
            + Double(usage.cacheRead) * p.cacheRead
        return dollars / 1_000_000 * (usage.fast ? 2 : 1)
    }
}

/// Token counts of one assistant response, read from a Claude Code transcript.
public struct TokenUsage: Equatable, Sendable {
    public var model: String
    public var timestamp: Date
    public var input = 0
    public var output = 0
    public var cacheWrite5m = 0
    public var cacheWrite1h = 0
    public var cacheRead = 0
    public var fast = false

    public init(model: String, timestamp: Date, input: Int = 0, output: Int = 0,
                cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0, fast: Bool = false) {
        self.model = model
        self.timestamp = timestamp
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.fast = fast
    }

    public var cost: Double { Pricing.cost(of: self) }
}
