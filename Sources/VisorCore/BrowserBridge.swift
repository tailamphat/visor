import Foundation

/// Chrome's and Firefox's native messaging: each message is its length as 4
/// little-endian bytes, then that much UTF-8 JSON.
public enum NativeMessaging {
    public static func frame(_ message: Data) -> Data {
        var length = UInt32(message.count).littleEndian
        return Data(bytes: &length, count: 4) + message
    }

    /// The largest message a browser sends a host (Chrome's limit).
    public static let maxLength = 64 << 20

    public struct TooLong: Error {}

    /// Takes every whole message off the front of `buffer`, copying what's left once.
    /// Throws on a length past `maxLength`: the stream is corrupt.
    public static func unframe(_ buffer: inout Data) throws -> [Data] {
        var out: [Data] = []
        var start = buffer.startIndex
        while buffer.endIndex - start >= 4 {
            let length = Int(buffer[start]) | Int(buffer[start + 1]) << 8 | Int(buffer[start + 2]) << 16 | Int(buffer[start + 3]) << 24
            guard length <= maxLength else { throw TooLong() }
            guard buffer.endIndex - start >= 4 + length else { break }
            out.append(Data(buffer[(start + 4)..<(start + 4 + length)]))
            start += 4 + length
        }
        if start != buffer.startIndex { buffer = Data(buffer[start...]) }
        return out
    }
}

/// The Visor Media browser extension (Extension/), which works in any Chromium
/// browser and in Firefox and Zen. It reports every media tab and plays, pauses
/// and skips the exact tab. It talks to `visor-bridge` (native messaging), which
/// passes lines to and from Visor's browser socket.
public enum BrowserBridge {
    public static let hostName = "visor.media"
    /// Fixed by the `key` in Extension/manifest.json.
    public static let chromiumID = "khhefkeppajbkdhkblihgllhpkacopkn"
    public static let geckoID = "media@visor.app"

    public struct Tab: Equatable, Sendable {
        public var media: BrowserMedia
        /// When the tab last reported, in the browser's milliseconds.
        public var at: Double
    }

    /// The tabs in a `{"type":"tabs"}` message, each in the page probe's shape
    /// (see BrowserMedia.probe) plus `id` and `at`. nil for other messages.
    public static func tabs(_ line: Data) -> [Tab]? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "tabs", let list = object["tabs"] as? [[String: Any]] else { return nil }
        return list.compactMap { entry in
            guard let id = entry["id"] as? String ?? (entry["id"] as? NSNumber)?.stringValue,
                  let json = try? JSONSerialization.data(withJSONObject: entry),
                  let media = BrowserMedia.parse(String(decoding: json, as: UTF8.self), tab: id) else { return nil }
            return Tab(media: media, at: (entry["at"] as? NSNumber)?.doubleValue ?? 0)
        }
    }

    /// The tab to show: the latest playing one, else the latest.
    public static func pick(_ tabs: [Tab]) -> Tab? {
        let latest = tabs.sorted { $0.at > $1.at }
        return latest.first { $0.media.playing } ?? latest.first
    }

    public static func command(_ command: BrowserMedia.Command, tab: String) -> Data {
        let name = switch command { case .playPause: "playPause"; case .next: "next"; case .previous: "previous" }
        let json = (try? JSONSerialization.data(withJSONObject: ["type": "command", "tab": tab, "command": name], options: .sortedKeys)) ?? Data()
        return json + Data([0x0A])
    }

    /// The native messaging host manifest that lets the extension start `path`.
    public static func manifest(path: String, firefox: Bool) -> Data {
        var object: [String: Any] = ["name": hostName, "description": "Visor media bridge", "path": path, "type": "stdio"]
        if firefox { object["allowed_extensions"] = [geckoID] } else { object["allowed_origins"] = ["chrome-extension://\(chromiumID)/"] }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Where each installed browser (its folder under Application Support
    /// exists) reads native messaging hosts. Zen isn't documented; it's said to
    /// use its own folder, so both it and Firefox's get one.
    public static func hostDirectories(support: String, exists: (String) -> Bool) -> [(path: String, firefox: Bool)] {
        let chromium = ["Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Chromium", "BraveSoftware/Brave-Browser",
                        "Microsoft Edge", "Vivaldi", "Arc/User Data", "Dia/User Data", "Opera"]
        let firefox = ["Mozilla", "zen"]
        return chromium.filter { exists("\(support)/\($0)") }.map { ("\(support)/\($0)/NativeMessagingHosts", false) }
            + firefox.filter { exists("\(support)/\($0)") }.map { ("\(support)/\($0)/NativeMessagingHosts", true) }
    }
}
