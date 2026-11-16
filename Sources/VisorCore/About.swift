import Foundation

/// What the About Visor panel links to, under the version.
public enum About {
    public struct Link: Sendable {
        public let title: String
        public let url: URL
    }

    public static let links = [
        Link(title: "Website", url: URL(string: "https://tailamphat.github.io/visor/")!),
        Link(title: "GitHub", url: URL(string: "https://github.com/tailamphat/visor")!),
        Link(title: "Report an issue", url: URL(string: "https://github.com/tailamphat/visor/issues/new")!),
    ]
}
