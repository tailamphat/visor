import Foundation

/// The answer to one release-feed GET.
public enum ReleaseFetchResult: Equatable, Sendable {
    /// A 200 (or a 304 with the body kept from before, `cached`).
    case data(Data, cached: Bool)
    /// A URL or redirect to a host that isn't allowed; nothing was read from it.
    case refused(host: String)
    /// More than `ReleaseFeed.maxAnswer` bytes: cut off.
    case tooLarge
    /// Any other status (0: no answer).
    case failed(status: Int)
}

/// GETs from the radar's allowed hosts only. Every URL and every redirect
/// target must pass `ReleaseFeed.url`; answers are capped at 2 MB while they
/// download; no cookies, no URL cache, no sign-in. Keeps ETag / Last-Modified
/// per URL in memory so a repeat GET can be a 304. Blocking: call from one
/// background queue.
public final class ReleaseFetcher: @unchecked Sendable {
    private let protocolClasses: [AnyClass]?
    private let log: (String) -> Void
    private var cache: [URL: (etag: String?, modified: String?, body: Data)] = [:]
    let timeout: TimeInterval

    public init(protocolClasses: [AnyClass]? = nil, timeout: TimeInterval = 20, log: @escaping (String) -> Void = { _ in }) {
        self.protocolClasses = protocolClasses
        self.timeout = timeout
        self.log = log
    }

    public func get(_ url: URL) -> ReleaseFetchResult {
        guard ReleaseFeed.url(url.absoluteString) != nil else {
            log("refused \(url.host ?? "?"): not an allowed host")
            return .refused(host: url.host ?? "")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("Visor", forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        let cached = cache[url]
        if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = cached?.modified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let task = FetchTask(log: log)
        let session = URLSession(configuration: configuration, delegate: task, delegateQueue: nil)
        session.dataTask(with: request).resume()
        guard task.done.wait(timeout: .now() + timeout + 5) == .success else {
            // Stuck past its own timeout: cancel and wait for the delegate to finish
            // before anything reads its fields; if it still hasn't, read nothing.
            session.invalidateAndCancel()
            _ = task.done.wait(timeout: .now() + 2)
            log("GET \(url.host ?? "?")\(url.path): timed out")
            return .failed(status: 0)
        }
        session.finishTasksAndInvalidate()

        if let host = task.refusedHost { return .refused(host: host) }
        if task.tooBig {
            log("cut \(url.host ?? "?")\(url.path): over \(ReleaseFeed.maxAnswer) bytes")
            return .tooLarge
        }
        guard let response = task.response else { return .failed(status: 0) }
        switch response.statusCode {
        case 200:
            let etag = response.value(forHTTPHeaderField: "ETag")
            let modified = response.value(forHTTPHeaderField: "Last-Modified")
            if etag != nil || modified != nil {
                if cache.count >= 50 { cache.removeAll() }
                cache[url] = (etag, modified, task.data)
            }
            return .data(task.data, cached: false)
        case 304 where cached != nil:
            return .data(cached!.body, cached: true)
        default:
            return .failed(status: response.statusCode)
        }
    }
}

/// One request's delegate: checks redirects, caps the size, collects the body.
private final class FetchTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let log: (String) -> Void
    let done = DispatchSemaphore(value: 0)
    var data = Data()
    var response: HTTPURLResponse?
    var tooBig = false
    var refusedHost: String?

    init(log: @escaping (String) -> Void) { self.log = log }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ReleaseFeed.url(url.absoluteString) != nil else {
            refusedHost = request.url?.host ?? ""
            log("refused redirect \(task.originalRequest?.url?.host ?? "?") -> \(request.url?.host ?? "?")")
            task.cancel()
            return completionHandler(nil)
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        if response.expectedContentLength > Int64(ReleaseFeed.maxAnswer) {
            tooBig = true
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !tooBig else { return }
        self.data.append(data)
        if self.data.count > ReleaseFeed.maxAnswer {
            tooBig = true
            self.data = Data()
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil, refusedHost == nil, !tooBig { response = nil; data = Data() }
        done.signal()
    }
}
