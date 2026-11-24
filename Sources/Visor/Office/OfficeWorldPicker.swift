import AppKit
import SwiftUI
import VisorCore

private typealias Spec = DesignComponents

/// The office's world setting: a tile for each world with a thumbnail of its
/// room and cast, over the office. Picking one swaps the room at once.
struct OfficeWorldPicker: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader("Office world")
                Spacer()
                DismissButton(help: "Close") { model.officePicker = false }
            }
            HStack(spacing: 8) {
                ForEach(OfficeWorld.allCases, id: \.self) { world in tile(world) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: CGFloat(Spec.Popover.radius), style: .continuous)
            .fill(Theme.surface.opacity(Spec.Popover.fill)))
        .padding(10)
    }

    private func tile(_ world: OfficeWorld) -> some View {
        let picked = world == model.officeWorld
        return Button {
            model.officeWorld = world
            model.officePicker = false
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                if let image = OfficeThumbnail.image(world) {
                    Image(decorative: image, scale: 1).resizable().interpolation(.none)
                        .aspectRatio(CGFloat(image.width) / CGFloat(image.height), contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                }
                Text(world.title).font(DS.font(.base, .semibold)).foregroundStyle(Theme.textPrimary)
                Text(Self.subtitle(world)).font(DS.font(.sm)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .strokeBorder(picked ? Theme.accent : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    static func subtitle(_ world: OfficeWorld) -> String {
        switch world {
        case .studio: return "cozy, at night"
        case .galaxy: return "Star Wars hangar"
        case .starfleet: return "Star Trek deck"
        }
    }
}

/// A still of each world with a sample team, drawn once: the room, the seat
/// screens and everyone in their first pose.
enum OfficeThumbnail {
    private static var cache: [OfficeWorld: CGImage] = [:]

    static func image(_ world: OfficeWorld) -> CGImage? {
        if let hit = cache[world] { return hit }
        let placed = Office.place(sample)
        let scene = placed.aroundTheTable()
        let layout = scene.layout
        let scale = 2.0
        guard let room = OfficeRoom.image(scene, world: world, props: true),
              let context = CGContext(data: nil, width: Int(OfficeLayout.width * scale), height: Int(layout.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(room, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        let cast = PixelPerson.Figure.cast(world)
        var taken: Set<Int> = []
        for agent in scene.agents.sorted(by: { $0.feet.y < $1.feet.y }) {
            var figure: PixelPerson.Figure?
            if !cast.isEmpty {
                let index = OfficeCast.pick(id: agent.id, count: cast.count, taken: taken)
                taken.insert(index)
                figure = cast[index]
            }
            let look = PixelPerson.look(for: agent, world: world, figure: figure)
            if let screen = PixelPerson.screen(look, activity: agent.spot == .desk ? agent.activity : nil, device: FilmRoom.device(at: agent.screen)).first {
                context.draw(screen, in: CGRect(x: agent.screen.x * scale, y: (layout.height - agent.screen.y - 4) * scale, width: 6 * scale, height: 4 * scale))
            }
            var (pose, _) = PixelPerson.pose(for: agent)
            if agent.spot == .sofa { pose = .playing }
            guard let sprite = PixelPerson.frames(look, pose: pose, front: !agent.facesUp).first else { continue }
            let w = PixelPerson.width * scale, h = PixelPerson.height * scale
            context.draw(sprite, in: CGRect(x: agent.feet.x * scale - w / 2, y: (layout.height - agent.feet.y) * scale, width: w, height: h))
        }
        let image = context.makeImage()
        cache[world] = image
        return image
    }

    /// A small team: three tools, someone at each station, one waiting, one resting.
    private static var sample: [AgentSession] {
        func s(_ id: String, _ agent: String, _ state: AgentState) -> AgentSession {
            AgentSession(id: id, agent: agent, cwd: "/Users/me/\(id)", state: state)
        }
        return [
            s("api", "Claude Code", .working("Bash: npm test")), s("mobile", "Claude Code", .working("Read: App.swift")),
            s("site", "Claude Code", .working("Thinking")), s("shop", "Claude Code", .needsApproval("Bash: git push")),
            s("docs", "Copilot CLI", .working("WebFetch: example.com")), s("cli", "Copilot CLI", .working("Edit: main.go")),
            s("infra", "Antigravity", .done), s("notes", "Antigravity", .done),
        ]
    }
}
