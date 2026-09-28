import os

/// Loggers of the SDK. Never log the client key.
enum Log {
    static let cache = Logger(subsystem: "io.github.huynguyennovem.CloudflareWorkerKV", category: "cache")
}
