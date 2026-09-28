import Foundation
@testable import CloudflareWorkerKV

/// Loads the shared fixtures from `spec/fixtures/` in the repository checkout
/// (not from a package resource), found by walking up from this file.
enum Fixtures {
    struct MissingFixtures: Error, CustomStringConvertible {
        let description: String
    }

    /// The `spec/fixtures` directory of the checkout.
    static func directory(from file: String = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: file).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("spec/fixtures", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        throw MissingFixtures(description: """
            spec/fixtures not found above \(file). The shared fixtures are read from the \
            repository checkout: run the tests from a clone of cloudflare-worker-kv.
            """)
    }

    /// The `cases` of a fixture file.
    static func cases<Case: Decodable>(_ file: String, as type: Case.Type = Case.self) throws -> [Case] {
        let url = try directory().appendingPathComponent(file)
        return try JSONDecoder().decode(FixtureDocument<Case>.self, from: Data(contentsOf: url)).cases
    }

    static func valueConversions() throws -> [ValueConversionCase] {
        try cases("value-conversions.json")
    }

    static func configURI() throws -> [ConfigURICase] {
        try cases("config-uri.json")
    }

    static func responses() throws -> [ResponseCase] {
        try cases("responses.json")
    }
}

private struct FixtureDocument<Case: Decodable>: Decodable {
    let cases: [Case]
}

/// A case of `value-conversions.json`. `raw == nil` is a static value.
struct ValueConversionCase: Decodable, Sendable, CustomStringConvertible {
    let raw: String?
    let string: String
    let bool: Bool
    let int: Int
    let double: Double

    var description: String {
        raw.map { JSONValue.string($0).compactJSONString } ?? "null"
    }
}

/// A case of `config-uri.json`.
struct ConfigURICase: Decodable, Sendable, CustomStringConvertible {
    let endpoint: String
    let template: String
    let expected: String?
    let error: Bool?

    var description: String { "\(endpoint) + \(template)" }
}

/// A case of `responses.json`.
struct ResponseCase: Decodable, Sendable, CustomStringConvertible {
    struct Expect: Decodable, Sendable {
        let result: String?
        let version: String?
        let etag: String?
        let entries: [String: String]?
        let error: String?
        let statusCode: Int?
        let throttleSeconds: Int?
        let messageContains: String?
    }

    let name: String
    let sentEtag: String?
    let status: Int
    let headers: [String: String]
    let body: String
    let expect: Expect

    var description: String { name }
}
