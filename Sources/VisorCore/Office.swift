import Foundation

/// A point in the office, in room pixels: x right, y down, at an agent's feet.
public struct OfficePoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Where in the office an agent goes for what it's doing.
public enum OfficeSpot: Equatable, Sendable {
    case desk, terminal, docs, web, you, sofa
}

/// How an agent looks while there.
public enum OfficeActivity: Equatable, Sendable {
    case typing, thinking, reading, running, browsing, approval, question, done, idle
}

/// The office's size, from the number of sessions. Room pixels; the view
/// draws each one 2 points wide. A wall, rows of desks, a corridor where
/// agents wait at your desk, and a fixed bottom row of stations.
public struct OfficeLayout: Equatable, Sendable {
    public static let width = 242.0
    public static let maxRows = 3
    public static let rowHeight = 36.0
    public static let firstRow = 16.0

    // The bottom row's stations, and the gaps between them to walk through.
    public static let terminalX = 21.0
    public static let docsX = 58.0
    public static let youX = 121.0
    public static let webX = 172.0
    public static let sofaX = 212.0
    static let lanes = [37.0, 88.0, 150.0, 187.0]
    /// Seats on the sofa; whoever else is done stays at their desk.
    public static let sofaSeats = 3
    /// How wide a crowd at a station may spread before it packs closer.
    static func span(_ spot: OfficeSpot) -> Double { spot == .you ? 80 : 28 }
    static let walkway = 4.0

    public let perRow: Int
    public let cellWidth: Double
    public let rows: Int

    public init(sessions: Int) {
        perRow = sessions > 16 ? 10 : 8
        cellWidth = perRow == 10 ? 22 : 28
        rows = max(1, min(Self.maxRows, Int((Double(sessions) / Double(perRow)).rounded(.up))))
    }

    public var capacity: Int { perRow * Self.maxRows }
    /// Where the first desk starts, centring the rows.
    public var left: Double { (Self.width - Double(perRow) * cellWidth) / 2 }
    public var deskBottom: Double { Self.firstRow + Double(rows) * Self.rowHeight }
    /// The line agents stand on when they wait at your desk.
    public var corridor: Double { deskBottom + 14 }
    public var stationTop: Double { corridor + 8 }
    /// The line agents stand on at the terminal, the docs and the web.
    public var stationLine: Double { stationTop + 32 }
    public var height: Double { stationLine + 4 }

    /// A desk's centre and the top of its row.
    public func desk(_ index: Int) -> OfficePoint {
        let row = index / perRow, column = index % perRow
        return OfficePoint(x: left + Double(column) * cellWidth + cellWidth / 2, y: Self.firstRow + Double(row) * Self.rowHeight)
    }

    /// The way from one place to another: along the line it's on to a
    /// walkway at the side (or a gap between stations), then along the
    /// target's line. Rows of desks are open at both ends.
    public func route(from: OfficePoint, to: OfficePoint) -> [OfficePoint] {
        if abs(from.y - to.y) < 2 { return [to] }
        let middle = (from.x + to.x) / 2
        let x: Double
        if from.y >= corridor - 1 && to.y >= corridor - 1 {
            x = Self.lanes.min { abs($0 - middle) < abs($1 - middle) } ?? middle
        } else {
            x = middle < Self.width / 2 ? Self.walkway : Self.width - Self.walkway
        }
        return [OfficePoint(x: x, y: from.y), OfficePoint(x: x, y: to.y), to]
    }
}

/// One agent placed in the office.
public struct OfficeAgent: Equatable, Sendable, Identifiable {
    public var id: String
    public var agent: String
    public var project: String
    public var spot: OfficeSpot
    public var activity: OfficeActivity
    /// Where it stands (or sits).
    public var feet: OfficePoint
    public var facesUp: Bool
    public var sits: Bool
    /// Its own desk, kept while it's away: the desk's centre and its row's top.
    public var desk: OfficePoint
}

/// A run of one tool's desks in a row, drawn as one rug with the tool's name.
public struct OfficeSegment: Equatable, Sendable {
    public var agent: String
    public var row: Int
    public var column: Int
    public var length: Int
    /// The tool's sessions in the whole office.
    public var count: Int

    public init(agent: String, row: Int, column: Int, length: Int, count: Int) {
        self.agent = agent
        self.row = row
        self.column = column
        self.length = length
        self.count = count
    }
}

public struct OfficeScene: Equatable, Sendable {
    public var layout: OfficeLayout
    public var agents: [OfficeAgent]
    public var segments: [OfficeSegment]
    /// Sessions past the last desk.
    public var hidden: Int

    public var waiting: Int { agents.filter { $0.spot == .you }.count }
}

/// Agent sessions as people in an office.
public enum Office {
    /// The tools Visor knows, in the order the notch lists them; others after, by name.
    static let toolRank = ["Claude Code": 0, "Copilot CLI": 1, "Antigravity": 2]

    public static func spot(for state: AgentState) -> (OfficeSpot, OfficeActivity) {
        switch state {
        case .working(let what):
            switch what.split(separator: ":").first.map(String.init) ?? what {
            case "Bash": return (.terminal, .running)
            case "Read", "Grep", "Glob", "LS": return (.docs, .reading)
            case "WebFetch", "WebSearch": return (.web, .browsing)
            case "Thinking": return (.desk, .thinking)
            default: return (.desk, .typing)
            }
        case .needsApproval: return (.you, .approval)
        case .asking, .needsInput: return (.you, .question)
        case .done: return (.sofa, .done)
        case .idle: return (.desk, .idle)
        }
    }

    public static func place(_ sessions: [AgentSession]) -> OfficeScene {
        let ordered = sessions.enumerated().sorted { a, b in
            let ra = (toolRank[a.element.agent] ?? toolRank.count, a.element.agent)
            let rb = (toolRank[b.element.agent] ?? toolRank.count, b.element.agent)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        let layout = OfficeLayout(sessions: ordered.count)
        let shown = Array(ordered.prefix(layout.capacity))

        // Who shares each place, so they can stand side by side.
        var spots = shown.map { spot(for: $0.state) }
        var seated = 0
        for i in spots.indices where spots[i].0 == .sofa {
            if seated < OfficeLayout.sofaSeats { seated += 1 } else { spots[i].0 = .desk }
        }
        var sharing: [OfficeSpot: Int] = [:]
        for (where_, _) in spots where where_ != .desk { sharing[where_, default: 0] += 1 }
        var taken: [OfficeSpot: Int] = [:]

        var agents: [OfficeAgent] = []
        for (index, session) in shown.enumerated() {
            let (where_, activity) = spots[index]
            let desk = layout.desk(index)
            var feet: OfficePoint
            var facesUp = true, sits = false
            switch where_ {
            case .desk: feet = OfficePoint(x: desk.x, y: desk.y + 33)
            case .terminal: feet = OfficePoint(x: OfficeLayout.terminalX, y: layout.stationLine)
            case .docs: feet = OfficePoint(x: OfficeLayout.docsX, y: layout.stationLine)
            case .web: feet = OfficePoint(x: OfficeLayout.webX, y: layout.stationLine)
            case .you: feet = OfficePoint(x: OfficeLayout.youX, y: layout.corridor); facesUp = false
            case .sofa: feet = OfficePoint(x: OfficeLayout.sofaX, y: layout.stationTop + 22); facesUp = false; sits = true
            }
            if where_ != .desk {
                let n = sharing[where_] ?? 1, i = taken[where_, default: 0]
                taken[where_] = i + 1
                let gap = sits ? 12 : min(11, n > 1 ? OfficeLayout.span(where_) / Double(n - 1) : 11)
                feet.x += (Double(i) - Double(n - 1) / 2) * gap
                feet.x = min(max(feet.x, 6), OfficeLayout.width - 6)
            }
            agents.append(OfficeAgent(id: session.id, agent: session.agent, project: session.project, spot: where_,
                                      activity: activity, feet: feet, facesUp: facesUp, sits: sits, desk: desk))
        }

        let counts = Dictionary(grouping: shown, by: \.agent).mapValues(\.count)
        var segments: [OfficeSegment] = []
        for (index, session) in shown.enumerated() {
            let row = index / layout.perRow, column = index % layout.perRow
            if let last = segments.last, last.agent == session.agent, last.row == row {
                segments[segments.count - 1].length += 1
            } else {
                segments.append(OfficeSegment(agent: session.agent, row: row, column: column, length: 1, count: counts[session.agent] ?? 1))
            }
        }
        return OfficeScene(layout: layout, agents: agents, segments: segments, hidden: ordered.count - shown.count)
    }
}
