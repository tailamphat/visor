import Foundation
import VisorCore

/// Keeps the model's usage numbers fresh, all off the main thread:
/// - plan limits (5-hour session, weekly) from the Claude account Claude Code signed in with
/// - API-equivalent spend from Claude Code's local transcripts
@MainActor
final class UsageService {
    private let model: AppModel
    private let work = DispatchQueue(label: "visor.usage", qos: .utility)
    private let transcripts = TranscriptUsage()
    private var timers: [Timer] = []
    private var fetching = false
    /// Read from the keychain on demand; Claude Code owns and refreshes it.
    private var token: (value: String, expires: Date)?

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        scanTranscripts()
        refreshPlan()
        timers.append(Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanTranscripts() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPlan() }
        })
        for timer in timers { timer.tolerance = 3 }
    }

    /// Called when the usage tab opens, so numbers are never stale when looked at.
    func refreshIfStale() {
        if Date().timeIntervalSince(model.planUpdated ?? .distantPast) > 45 { refreshPlan() }
    }

    private func scanTranscripts() {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let transcripts = transcripts
        work.async {
            let changed = transcripts.scan(root: root)
            // Recompute at least once a minute so "today" rolls over at midnight.
            let summary = SpendSummary.make(from: transcripts.records)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if changed || self.model.spend != summary { self.model.spend = summary }
                }
            }
        }
    }

    func refreshPlan() {
        refreshCopilot()
        guard !fetching else { return }
        fetching = true
        let cached = token
        work.async {
            let result = Self.fetchPlan(cached: cached)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fetching = false
                    switch result {
                    case .success(let fetched):
                        self.token = fetched.token
                        self.model.plan = fetched.plan
                        if let name = fetched.planName { self.model.planName = name }
                        self.model.planError = nil
                        self.model.planUpdated = Date()
                    case .failure(let error):
                        self.token = nil
                        self.model.planError = error.message
                    }
                }
            }
        }
    }

    // MARK: Copilot

    private var fetchingCopilot = false

    /// Copilot allowances for every GitHub host `gh` is signed in to (github.com
    /// and company *.ghe.com), keeping plans with premium requests to count.
    /// The token comes from `gh` each time; Visor never stores it.
    private func refreshCopilot() {
        guard !fetchingCopilot, let gh = Self.ghPath else { return }
        fetchingCopilot = true
        work.async {
            let status = Self.run(gh, ["auth", "status"]) ?? ""
            var found: [CopilotUsage] = []
            for host in CopilotUsage.signedInHosts(fromStatus: status) {
                guard let base = CopilotUsage.apiBase(for: host),
                      let token = Self.run(gh, ["auth", "token", "--hostname", host])?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { continue }
                var request = URLRequest(url: base.appendingPathComponent("copilot_internal/user"))
                request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("Visor", forHTTPHeaderField: "User-Agent")
                request.timeoutInterval = 15
                if case .ok(let data) = Self.send(request), let usage = CopilotUsage.parse(data, host: host), usage.isTracked {
                    found.append(usage)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fetchingCopilot = false
                    // Company plans first.
                    let sorted = found.sorted { ($0.host == "github.com" ? 1 : 0) < ($1.host == "github.com" ? 1 : 0) }
                    if sorted != self.model.copilot { self.model.copilot = sorted }
                }
            }
        }
    }

    private nonisolated static let ghPath: String? = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Runs a command and returns its output (stdout and stderr; `gh auth status` writes to stderr).
    private nonisolated static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    struct PlanError: Error { var message: String }
    struct Fetched {
        var plan: PlanUsage
        var planName: String?
        var token: (value: String, expires: Date)
    }

    private nonisolated static func fetchPlan(cached: (value: String, expires: Date)?) -> Result<Fetched, PlanError> {
        var credentials: Credentials?
        if cached == nil || cached!.expires < Date() {
            credentials = readCredentials()
            guard credentials != nil else { return .failure(PlanError(message: "Sign in to Claude Code to see your plan limits.")) }
        }
        let token = credentials.map { ($0.token, $0.expires) } ?? cached!
        switch request(token: token.0) {
        case .ok(let data):
            guard let plan = PlanUsage.parse(data) else { return .failure(PlanError(message: "Couldn't read plan usage.")) }
            return .success(Fetched(plan: plan, planName: credentials?.planName ?? nil, token: token))
        case .status(let status) where status == 401 && credentials == nil:
            // Claude Code may have refreshed the token since we read it.
            return fetchPlan(cached: nil)
        case .status(let status):
            return .failure(PlanError(message: status == 401 ? "Claude Code's sign-in expired. Run claude to refresh it."
                                                             : "Plan usage unavailable (\(status))."))
        }
    }

    struct Credentials {
        var token: String
        var expires: Date
        var planName: String?
    }

    /// Claude Code keeps its OAuth credentials in the login keychain. Reading
    /// them through /usr/bin/security avoids a keychain prompt for this app.
    private nonisolated static func readCredentials() -> Credentials? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        let expiresMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        let plan = (oauth["subscriptionType"] as? String).map { "Claude " + $0.capitalized }
        return Credentials(token: token, expires: Date(timeIntervalSince1970: expiresMs / 1000), planName: plan)
    }

    enum Response { case ok(Data), status(Int) }

    private nonisolated static func send(_ request: URLRequest) -> Response {
        let done = DispatchSemaphore(value: 0)
        var result = Response.status(0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            result = status == 200 && data != nil ? .ok(data!) : .status(status)
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    private nonisolated static func request(token: String) -> Response {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Visor", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let done = DispatchSemaphore(value: 0)
        var result = Response.status(0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            result = status == 200 && data != nil ? .ok(data!) : .status(status)
            done.signal()
        }.resume()
        done.wait()
        return result
    }
}
