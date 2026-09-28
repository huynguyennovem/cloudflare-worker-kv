import SwiftUI

@main
@MainActor
struct CloudflareWorkerKVExampleApp: App {
    private let configuration = ExampleConfiguration()

    var body: some Scene {
        WindowGroup {
            if let endpoint = configuration.endpoint {
                ConfigView(endpoint: endpoint, clientKey: configuration.clientKey)
            } else {
                MissingEndpointView(rawEndpoint: configuration.rawEndpoint)
            }
        }
    }
}
