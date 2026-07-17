import Foundation
import AppKit

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
    #endif

    private init() {
        #if canImport(Sparkle)
        // Do not start automatic checking by default; keep control minimal.
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
        // Only start the Sparkle updater if an appcast/feed URL is configured.
        if let _ = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String {
            updaterController?.startUpdater()
            updaterController?.updater.checkForUpdates()
        } else {
            // Fallback: open Releases page when no feed is configured.
            NSWorkspace.shared.open(ProductIdentity.latestReleaseURL)
        }
        #else
        // Fallback: open Releases page
        NSWorkspace.shared.open(ProductIdentity.latestReleaseURL)
        #endif
    }
}
