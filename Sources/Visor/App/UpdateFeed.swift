import Foundation
import Sparkle

/// Where updates come from: Info.plist's SUFeedURL, or VISOR_UPDATE_FEED to
/// try an update from a local appcast before releasing it.
/// A downloaded update waits for Visor to quit; the menu offers to restart now.
final class UpdateFeed: NSObject, SPUUpdaterDelegate {
    static let shared = UpdateFeed()
    private(set) var readyVersion: String?
    private(set) var installNow: (() -> Void)?

    func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["VISOR_UPDATE_FEED"]
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        readyVersion = item.displayVersionString
        installNow = immediateInstallHandler
        return true
    }
}
