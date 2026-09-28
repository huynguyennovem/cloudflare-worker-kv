// Runs the shared fixtures in spec/fixtures/ (read from the repository
// checkout) against this SDK. Every SDK of the repository runs the same files.
import Foundation
import Testing
@testable import CloudflareWorkerKV

@Suite("Shared fixtures")
struct SharedFixtureTests {
    @Test("value-conversions.json", arguments: try Fixtures.valueConversions())
    func valueConversion(_ c: ValueConversionCase) {
        let value = RemoteConfigValue(c.raw, source: c.raw == nil ? .static : .remote)
        #expect(value.stringValue == c.string)
        #expect(value.boolValue == c.bool)
        #expect(value.intValue == c.int)
        #expect(value.doubleValue == c.double)
    }

    @Test("config-uri.json", arguments: try Fixtures.configURI())
    func configURI(_ c: ConfigURICase) throws {
        func build() throws -> String {
            guard let endpoint = URL(string: c.endpoint) else {
                throw WorkerClient.InvalidArgument(description: "URL(string:) rejects \(c.endpoint)")
            }
            return try WorkerClient.configURL(endpoint: endpoint, template: c.template).absoluteString
        }
        if c.error == true {
            #expect(throws: (any Error).self) { try build() }
        } else {
            #expect(try build() == c.expected)
        }
    }

    @Test("responses.json", arguments: try Fixtures.responses())
    func response(_ c: ResponseCase) async throws {
        let now = FakeClock.start
        let reply = HTTPResponse(statusCode: c.status, headers: c.headers, body: Data(c.body.utf8))
        let client = WorkerClient(
            configURL: try WorkerClient.configURL(endpoint: URL(string: "https://cfg.example.com")!,
                                                  template: "default"),
            clientKey: nil,
            transport: StubTransport { _ in reply },
            clock: { now })
        let expected = c.expect

        switch expected.result {
        case "fetched":
            let result = try await client.fetch(etag: c.sentEtag, timeout: 5)
            guard case .fetched(let snapshot, let etag) = result else {
                Issue.record("Expected fetched, got \(result)")
                return
            }
            #expect(snapshot.version == expected.version)
            #expect(etag == expected.etag)
            #expect(snapshot.entries == expected.entries)
        case "notModified":
            #expect(try await client.fetch(etag: c.sentEtag, timeout: 5) == .notModified)
        default:
            let code = try #require(expected.error.flatMap(RemoteConfigError.Code.init(rawValue:)))
            let error = await expectError(code: code, messageContains: expected.messageContains) {
                try await client.fetch(etag: c.sentEtag, timeout: 5)
            }
            #expect(error?.statusCode == expected.statusCode)
            #expect(error?.throttleEndTime == expected.throttleSeconds.map { now.addingTimeInterval(TimeInterval($0)) })
        }
    }

    @Test("the fixtures are found in the checkout")
    func fixturesFound() throws {
        #expect(try Fixtures.valueConversions().count >= 31)
        #expect(try Fixtures.configURI().count >= 12)
        #expect(try Fixtures.responses().count >= 29)
    }
}
