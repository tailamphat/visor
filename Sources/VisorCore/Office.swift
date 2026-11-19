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

/// One tool's table: two seats per column, facing each other across it.
public struct OfficeIsland: Equatable, Sendable {
    public var agent: String
    /// Top-left corner, room pixels.
    public var x: Double
    public var y: Double
    public var columns: Int
    /// Sessions at this table, and the tool's sessions in the whole office.
    public var seats: Int
    public var total: Int

    public var width: Double { Double(columns) * OfficeLayout.cell + 8 }
}

/// The office, in room pixels; the view draws each one 2 points wide. Tables
/// for each tool flow left to right in up to two rows, with aisles between
/// the rows and walkways down both sides; below them a corridor where agents
/// wait at your desk, and a fixed row of stations.
public struct OfficeLayout: Equatable, Sendable {
    public static let width = 242.0
    public static let cell = 22.0
    public static let islandHeight = 52.0
    static let rowPitch = 58.0
    static let firstRow = 10.0
    static let margin = 8.0
    static let gap = 8.0
    public static let maxRows = 2
    /// The most columns a table can have: the room's width.
    static let maxColumns = Int((width - 2 * margin - 8) / cell)

    // The bottom row's stations, and the gaps between them to walk through.
    public static let terminalX = 21.0
    public static let docsX = 58.0
    public static let youX = 121.0
    public static let webX = 172.0
    public static let sofaX = 212.0
    static let lanes = [37.0, 88.0, 150.0, 187.0]
    static let walkway = 4.0
    /// Seats on the sofa; whoever else is done stays at their desk.
    public static let sofaSeats = 3
    /// How wide a crowd at a station may spread before it packs closer.
    static func span(_ spot: OfficeSpot) -> Double { spot == .you ? 80 : 28 }

    public let islands: [OfficeIsland]
    public let rows: Int

    /// Tables for each tool's sessions, in order. A tool with more sessions
    /// than a table holds gets another; tables past the second row are left out.
    public init(groups: [(agent: String, count: Int)]) {
        var islands: [OfficeIsland] = []
        var x = Self.margin, row = 0
        placing: for (agent, count) in groups {
            var left = count
            while left > 0 {
                let seats = min(left, Self.maxColumns * 2)
                var island = OfficeIsland(agent: agent, x: x, y: 0, columns: (seats + 1) / 2, seats: seats, total: count)
                if x > Self.margin && x + island.width > Self.width - Self.margin {
                    row += 1
                    x = Self.margin
                    island.x = x
                }
                guard row < Self.maxRows else { break placing }
                island.y = Self.firstRow + Double(row) * Self.rowPitch
                islands.append(island)
                x += island.width + Self.gap
                left -= seats
            }
        }
        self.islands = islands
        rows = max(1, (islands.last.map { Int(($0.y - Self.firstRow) / Self.rowPitch) } ?? 0) + 1)
    }

    public var capacity: Int { islands.reduce(0) { $0 + $1.seats } }
    public var deskBottom: Double { Self.firstRow + Double(rows) * Self.rowPitch - (Self.rowPitch - Self.islandHeight) }
    /// The line agents stand on when they wait at your desk.
    public var corridor: Double { deskBottom + 14 }
    public var stationTop: Double { corridor + 8 }
    /// The line agents stand on at the terminal, the docs and the web.
    public var stationLine: Double { stationTop + 32 }
    public var height: Double { stationLine + 4 }

    /// A seat at a table: where the agent sits, which way it faces, the aisle
    /// it reaches it from, and the top-left of its screen.
    public func seat(_ island: OfficeIsland, _ index: Int) -> (feet: OfficePoint, facesUp: Bool, access: Double, screen: OfficePoint) {
        let x = island.x + 4 + Double(index / 2) * Self.cell + Self.cell / 2
        if index % 2 == 0 {
            return (OfficePoint(x: x, y: island.y + 14), false, island.y - 3, OfficePoint(x: x - 3, y: island.y + 20))
        }
        return (OfficePoint(x: x, y: island.y + 50), true, island.y + Self.islandHeight + 3, OfficePoint(x: x - 3, y: island.y + 27))
    }

    /// The way from one place to another. Each place is reached from a line
    /// that's open end to end (`access`): an aisle beside its table, the
    /// corridor, or a station's line. Aisles meet at the walkways down the
    /// sides; below the tables, the gaps between the stations join the lines.
    public func route(from: OfficePoint, access fromLine: Double, to: OfficePoint, access toLine: Double) -> [OfficePoint] {
        var path: [OfficePoint] = []
        var at = from
        func go(_ p: OfficePoint) {
            if abs(p.x - at.x) > 0.01 || abs(p.y - at.y) > 0.01 { path.append(p); at = p }
        }
        let middle = (from.x + to.x) / 2
        go(OfficePoint(x: at.x, y: fromLine))
        if abs(fromLine - toLine) > 0.5 {
            let x: Double
            if fromLine >= deskBottom && toLine >= deskBottom {
                x = Self.lanes.min { abs($0 - middle) < abs($1 - middle) } ?? middle
            } else {
                x = middle < Self.width / 2 ? Self.walkway : Self.width - Self.walkway
            }
            go(OfficePoint(x: x, y: fromLine))
            go(OfficePoint(x: x, y: toLine))
        }
        go(OfficePoint(x: to.x, y: toLine))
        go(to)
        return path
    }
}

/// One agent placed in the office.
public struct OfficeAgent: Equatable, Sendable, Identifiable {
    public var id: String
    public var agent: String
    public var project: String
    public var spot: OfficeSpot
    public var activity: OfficeActivity
    /// Where it stands (or sits), and the open line it's reached from.
    public var feet: OfficePoint
    public var access: Double
    public var facesUp: Bool
    public var sits: Bool
    /// Its own screen at its table, kept while it's away: the top-left of 6 x 4 pixels.
    public var screen: OfficePoint
}

public struct OfficeScene: Equatable, Sendable {
    public var layout: OfficeLayout
    public var agents: [OfficeAgent]
    /// Sessions past the last table.
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
        var groups: [(agent: String, count: Int)] = []
        for session in ordered {
            if groups.last?.agent == session.agent { groups[groups.count - 1].count += 1 } else { groups.append((session.agent, 1)) }
        }
        let layout = OfficeLayout(groups: groups)

        // Seat each tool's sessions at its tables, in order.
        var seats: [(session: AgentSession, seat: (feet: OfficePoint, facesUp: Bool, access: Double, screen: OfficePoint))] = []
        var next: [String: Int] = [:]
        let byAgent = Dictionary(grouping: ordered, by: \.agent)
        for island in layout.islands {
            let start = next[island.agent, default: 0]
            let list = byAgent[island.agent] ?? []
            for i in 0..<island.seats where start + i < list.count {
                seats.append((list[start + i], layout.seat(island, i)))
            }
            next[island.agent] = start + island.seats
        }

        // Who goes where; the sofa seats three, the rest stay at their desks.
        var spots = seats.map { spot(for: $0.session.state) }
        var seated = 0
        for i in spots.indices where spots[i].0 == .sofa {
            if seated < OfficeLayout.sofaSeats { seated += 1 } else { spots[i].0 = .desk }
        }
        var sharing: [OfficeSpot: Int] = [:]
        for (where_, _) in spots where where_ != .desk { sharing[where_, default: 0] += 1 }
        var taken: [OfficeSpot: Int] = [:]

        var agents: [OfficeAgent] = []
        for (index, (session, seat)) in seats.enumerated() {
            let (where_, activity) = spots[index]
            var feet: OfficePoint
            var access: Double
            var facesUp = true, sits = false
            switch where_ {
            case .desk: feet = seat.feet; access = seat.access; facesUp = seat.facesUp
            case .terminal: feet = OfficePoint(x: OfficeLayout.terminalX, y: layout.stationLine); access = feet.y
            case .docs: feet = OfficePoint(x: OfficeLayout.docsX, y: layout.stationLine); access = feet.y
            case .web: feet = OfficePoint(x: OfficeLayout.webX, y: layout.stationLine); access = feet.y
            case .you: feet = OfficePoint(x: OfficeLayout.youX, y: layout.corridor); access = feet.y; facesUp = false
            case .sofa: feet = OfficePoint(x: OfficeLayout.sofaX, y: layout.stationTop + 22); access = feet.y; facesUp = false; sits = true
            }
            if where_ != .desk {
                let n = sharing[where_] ?? 1, i = taken[where_, default: 0]
                taken[where_] = i + 1
                let gap = sits ? 12 : min(11, n > 1 ? OfficeLayout.span(where_) / Double(n - 1) : 11)
                feet.x += (Double(i) - Double(n - 1) / 2) * gap
                feet.x = min(max(feet.x, 6), OfficeLayout.width - 6)
            }
            agents.append(OfficeAgent(id: session.id, agent: session.agent, project: session.project, spot: where_,
                                      activity: activity, feet: feet, access: access, facesUp: facesUp, sits: sits,
                                      screen: seat.screen))
        }
        return OfficeScene(layout: layout, agents: agents, hidden: ordered.count - agents.count)
    }
}
