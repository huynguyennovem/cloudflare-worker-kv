import CloudflareWorkerKV
import Foundation
import Observation

/// Initializes the shared `CloudflareRemoteConfig` and runs
/// "Fetch & activate", like `main()` and `_ConfigPageState` of the Flutter
/// example.
@MainActor
@Observable
final class ConfigViewModel {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }

    let endpoint: URL
    private let clientKey: String?

    /// `nil` until the cached config has been loaded.
    private(set) var remoteConfig: CloudflareRemoteConfig?
    private(set) var isLoading = false
    private(set) var toast: Toast?

    init(endpoint: URL, clientKey: String?) {
        self.endpoint = endpoint
        self.clientKey = clientKey
    }

    /// Loads the cached config, applies the settings and defaults, then
    /// fetches.
    func start() async {
        guard remoteConfig == nil else { return }
        let remoteConfig = await CloudflareRemoteConfig.initialize(
            endpoint: endpoint,
            clientKey: clientKey
        )
        await remoteConfig.setConfigSettings(RemoteConfigSettings(
            fetchTimeout: 10,
            // Use a long interval (e.g. 1 hour) in production.
            minimumFetchInterval: 0
        ))
        remoteConfig.setDefaults([
            "welcome_message": "Hello from defaults",
            "max_items": 5,
            "discount_ratio": 0.0,
            "new_checkout_enabled": false,
        ])
        self.remoteConfig = remoteConfig
        await refresh()
    }

    /// Fetches and activates the latest config, then shows the outcome.
    func refresh() async {
        guard let remoteConfig, !isLoading else { return }
        isLoading = true
        let message: String
        do {
            let activated = try await remoteConfig.fetchAndActivate()
            message = activated ? "New config activated" : "Config is up to date"
        } catch let error as RemoteConfigError {
            message = "Fetch failed: \(error.code.rawValue)"
        } catch {
            message = "Fetch failed: \(error.localizedDescription)"
        }
        isLoading = false
        show(message)
    }

    private func show(_ message: String) {
        let toast = Toast(message: message)
        self.toast = toast
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self?.toast == toast { self?.toast = nil }
        }
    }
}
