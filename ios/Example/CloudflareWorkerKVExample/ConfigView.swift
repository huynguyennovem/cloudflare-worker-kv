import CloudflareWorkerKV
import Foundation
import SwiftUI

/// The values of the remote config, like `ConfigPage` of the Flutter example.
@MainActor
struct ConfigView: View {
    @State private var model: ConfigViewModel

    init(endpoint: URL, clientKey: String?) {
        _model = State(initialValue: ConfigViewModel(endpoint: endpoint, clientKey: clientKey))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let remoteConfig = model.remoteConfig {
                    content(remoteConfig)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Cloudflare Remote Config")
            .navigationBarTitleDisplayMode(.inline)
        }
        .animation(.default, value: model.toast)
        .task { await model.start() }
    }

    private func content(_ remoteConfig: CloudflareRemoteConfig) -> some View {
        let values = remoteConfig.allValues().sorted { $0.key < $1.key }
        let checkoutEnabled = remoteConfig["new_checkout_enabled"].boolValue
        let discount = String(format: "%.0f", remoteConfig["discount_ratio"].doubleValue * 100)
        let lastFetch = remoteConfig.lastFetchTime.map {
            $0.formatted(date: .abbreviated, time: .standard)
        } ?? "never"

        return List {
            Section {
                Text(remoteConfig["welcome_message"].stringValue)
                    .font(.title2.weight(.semibold))
                Text("Max items: \(remoteConfig["max_items"].intValue) · Discount: \(discount)%")
                Label(
                    "New checkout \(checkoutEnabled ? "enabled" : "disabled")",
                    systemImage: checkoutEnabled ? "checkmark.circle.fill" : "xmark.circle"
                )
            }
            Section {
                LabeledContent("Status", value: remoteConfig.lastFetchStatus.rawValue)
                LabeledContent("Last fetch", value: lastFetch)
                LabeledContent("Endpoint", value: model.endpoint.absoluteString)
            }
            Section("Values") {
                ForEach(values, id: \.key) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.key)
                            Text(entry.value.stringValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.value.source.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        // Applied before safeAreaInset, so the toast sits just above the button bar.
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast.message)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.85), in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await model.refresh() }
            } label: {
                HStack(spacing: 8) {
                    if model.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Fetch & activate")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isLoading)
            .padding()
            .background(.bar)
        }
    }
}
