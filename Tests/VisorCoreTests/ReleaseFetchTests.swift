import Foundation
import Testing
@testable import VisorCore

/// Answers requests from a table instead of the network, and records them.
final class StubFeed: URLProtocol, @unchecked Sendable {
    enum Reply {
        case body(status: Int, headers: [String: String], Data)
        case redirect(to: String)
        /// No Content-Length, `chunks` pieces of `size` bytes.
        case stream(chunks: Int, size: Int)
    }

    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    private static let lock = NSLock()

    static func set(_ url: String, _ reply: Reply) { lock.withLock { replies[url] = reply } }
    static func requests(_ prefix: String) -> [URLRequest] {
        lock.withLock { seen.filter { $0.url?.absoluteString.hasPrefix(prefix) == true } }
    }
    static func requests(host: String) -> [URLRequest] { lock.withLock { seen.filter { $0.url?.host == host } } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let reply = Self.lock.withLock { () -> Reply? in
            Self.seen.append(request)
            return Self.replies[url.absoluteString]
        }
        switch reply {
        case .body(let status, let headers, let data)?:
            var all = headers
            all["Content-Length"] = String(data.count)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: all)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let target)?:
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        case .stream(let chunks, let size)?:
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!,
                                cacheStoragePolicy: .notAllowed)
            for _ in 0..<chunks { client?.urlProtocol(self, didLoad: Data(count: size)) }
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
        }
    }

    override func stopLoading() {}
}

/// Thread-safe log lines.
final class LogLines: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

@Suite("Release fetch")
struct ReleaseFetchTests {
    let log = LogLines()
    var fetcher: ReleaseFetcher { ReleaseFetcher(protocolClasses: [StubFeed.self], timeout: 5) { [log] in log.add($0) } }

    @Test func refusesRedirectToOtherHost() {
        let start = "https://api.github.com/repos/t1/x/tarball"
        StubFeed.set(start, .redirect(to: "https://codeload.github.com/t1/x/legacy.tar.gz"))
        StubFeed.set("https://codeload.github.com/t1/x/legacy.tar.gz", .body(status: 200, headers: [:], Data("secret".utf8)))
        #expect(fetcher.get(URL(string: start)!) == .refused(host: "codeload.github.com"))
        #expect(StubFeed.requests("https://codeload.github.com/t1/").isEmpty)
        #expect(log.all.contains("refused redirect api.github.com -> codeload.github.com"))
    }

    @Test func refusesUrlOffTheList() {
        #expect(fetcher.get(URL(string: "https://evil.example/x")!) == .refused(host: "evil.example"))
        #expect(StubFeed.requests(host: "evil.example").isEmpty)
    }

    @Test func followsRedirectWithinAllowedHosts() {
        let start = "https://api.github.com/repos/t2/old/releases/latest"
        let moved = "https://api.github.com/repositories/2/releases/latest"
        StubFeed.set(start, .redirect(to: moved))
        StubFeed.set(moved, .body(status: 200, headers: [:], Data("{}".utf8)))
        #expect(fetcher.get(URL(string: start)!) == .data(Data("{}".utf8), cached: false))
    }

    @Test func cutsAnswerOverLimitByLength() {
        let url = "https://registry.npmjs.org/t3/latest"
        StubFeed.set(url, .body(status: 200, headers: [:], Data(count: 3_000_000)))
        #expect(fetcher.get(URL(string: url)!) == .tooLarge)
    }

    @Test func cutsAnswerOverLimitStreamed() {
        let url = "https://registry.npmjs.org/t4/latest"
        StubFeed.set(url, .stream(chunks: 12, size: 256_000))
        #expect(fetcher.get(URL(string: url)!) == .tooLarge)
    }

    @Test func sendsETagAndReusesOn304() {
        let url = "https://formulae.brew.sh/api/formula/t5.json"
        let body = Data(#"{"versions":{"stable":"1.0.0"}}"#.utf8)
        StubFeed.set(url, .body(status: 200, headers: ["ETag": "\"abc\""], body))
        let fetcher = self.fetcher
        #expect(fetcher.get(URL(string: url)!) == .data(body, cached: false))
        StubFeed.set(url, .body(status: 304, headers: [:], Data()))
        #expect(fetcher.get(URL(string: url)!) == .data(body, cached: true))
        #expect(StubFeed.requests(url).last?.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
    }

    @Test func sendsNoCookiesOrAuth() throws {
        let url = "https://api.github.com/repos/t6/x/releases/latest"
        StubFeed.set(url, .body(status: 200, headers: [:], Data("{}".utf8)))
        _ = fetcher.get(URL(string: url)!)
        let request = try #require(StubFeed.requests(url).first)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Visor")
    }
}
