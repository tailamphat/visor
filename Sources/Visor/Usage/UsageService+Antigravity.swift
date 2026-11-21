import AppKit
import VisorCore

/// Antigravity quotas from `agy`.
extension UsageService {


    /// Antigravity's weekly quotas, from its own CLI. Print mode takes a few
    /// seconds and a couple of hundred MB, so it runs only when the Usage tab
    /// opens and the last reading is over two minutes old.
    func refreshAntigravity() {
        guard model.shows(.antigravity), let agy = Self.agyPath, !fetchingAntigravity else { return }
        if let attempt = antigravityAttempt, Date().timeIntervalSince(attempt) < 120 { return }
        antigravityAttempt = Date()
        fetchingAntigravity = true
        model.antigravityLoading = true
        work.async {
            let result = Self.fetchAntigravity(agy)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fetchingAntigravity = false
                    self.model.antigravityLoading = false
                    switch result {
                    case .success(let usage):
                        if self.model.antigravity != usage { self.model.antigravity = usage }
                        self.model.antigravityError = nil
                        self.model.antigravityUpdated = Date()
                    case .failure(let error):
                        self.model.antigravityError = error.message
                    }
                }
            }
        }
    }

    nonisolated static let agyPath = Shell.which("agy")

    struct AntigravityError: Error { var message: String }

    nonisolated static func fetchAntigravity(_ agy: String) -> Result<AntigravityUsage, AntigravityError> {
        var environment = ProcessInfo.processInfo.environment
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        environment["VISOR_USAGE_PROBE"] = "1"
        // The timeout stops a stuck CLI from holding the usage queue.
        guard let output = Shell.run(agy, ["-p", "/usage", "--output-format", "json"], environment: environment, timeout: 30) else {
            return .failure(AntigravityError(message: "Antigravity isn't available."))
        }
        guard output.ok else {
            return .failure(AntigravityError(message: "Run agy and sign in to see Antigravity limits."))
        }
        guard let usage = AntigravityUsage.parse(output.data) else {
            return .failure(AntigravityError(message: "Couldn't read Antigravity usage."))
        }
        return .success(usage)
    }
}
