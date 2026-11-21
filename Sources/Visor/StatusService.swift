import AppKit
import VisorCore

/// Checks the providers' public status pages every five minutes, for the tools
/// you've connected only, off the main thread. A new incident peeks once; while
/// it's open the tool's mark carries a dot and Usage says what's wrong.
@MainActor
final class StatusService {
    private let model: AppModel
    private let queue = DispatchQueue(label: "visor.status", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    /// Incidents already announced, so each peeks once.
    private var announced: Set<String> = []
    var onNew: ((String, ProviderIncident) -> Void)?

    init(model: AppModel) { self.model = model }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 300, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in DispatchQueue.main.async { MainActor.assumeIsolated { self?.check() } } }
        timer.resume()
        self.timer = timer
    }

    private func check() {
        let pages: [(ProviderStatus, Bool)] = [(.claude, model.shows(.claude)), (.copilot, model.shows(.copilot))]
        for (page, connected) in pages {
            guard connected else {
                if model.incidents[page.agent] != nil { model.incidents[page.agent] = nil }
                continue
            }
            session.dataTask(with: page.url) { [weak self] data, response, _ in
                // No answer, or one we can't read, keeps what we had; a page read clears or sets it.
                guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                do {
                    let found = try ProviderStatus.incident(in: data, watching: page.components)
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.update(page.agent, found) } }
                } catch {}
            }.resume()
        }
    }

    private func update(_ agent: String, _ incident: ProviderIncident?) {
        if model.incidents[agent] != incident { model.incidents[agent] = incident }
        if let incident, !announced.contains(incident.id) {
            announced.insert(incident.id)
            onNew?(agent, incident)
        }
    }
}
