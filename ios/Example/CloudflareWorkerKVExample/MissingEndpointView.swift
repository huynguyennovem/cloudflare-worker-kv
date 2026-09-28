import SwiftUI

/// Shown when the app was built without a valid `CF_CONFIG_ENDPOINT`.
@MainActor
struct MissingEndpointView: View {
    let rawEndpoint: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "network.slash")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Set your Worker URL")
                .font(.headline)
            Text("Copy Config/Local.xcconfig.example to Config/Local.xcconfig and set CF_CONFIG_ENDPOINT, or build with:")
            Text("xcodebuild … CF_CONFIG_ENDPOINT=https://<worker>.<subdomain>.workers.dev")
                .font(.footnote.monospaced())
                .textSelection(.enabled)
            if !rawEndpoint.isEmpty {
                Text("Not an absolute URL: \(rawEndpoint)")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
    }
}
