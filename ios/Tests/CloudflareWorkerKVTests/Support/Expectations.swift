import Foundation
import Testing
@testable import CloudflareWorkerKV

/// Expects `body` to throw a ``RemoteConfigError`` with `code`, and returns
/// it. `statusCode`, `throttleEnd` and `messageContains` are checked when
/// given. (`#expect(throws:)` only returns the error from Swift 6.1 on.)
@discardableResult
func expectError<Result>(
    code: RemoteConfigError.Code,
    statusCode: Int? = nil,
    throttleEnd: Date? = nil,
    messageContains: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation,
    performing body: () async throws -> Result
) async -> RemoteConfigError? {
    do {
        let result = try await body()
        Issue.record("Expected RemoteConfigError[\(code.rawValue)], got \(result)",
                     sourceLocation: sourceLocation)
        return nil
    } catch let error as RemoteConfigError {
        #expect(error.code == code, "\(error)", sourceLocation: sourceLocation)
        if let statusCode {
            #expect(error.statusCode == statusCode, "\(error)", sourceLocation: sourceLocation)
        }
        if let throttleEnd {
            #expect(error.throttleEndTime == throttleEnd, "\(error)", sourceLocation: sourceLocation)
        }
        if let messageContains {
            #expect(error.message.contains(messageContains), "\(error)", sourceLocation: sourceLocation)
        }
        return error
    } catch {
        Issue.record("Expected RemoteConfigError[\(code.rawValue)], got \(error)",
                     sourceLocation: sourceLocation)
        return nil
    }
}

extension HTTPResponse {
    /// A response with a UTF-8 body.
    init(_ statusCode: Int, _ body: String = "", headers: [String: String] = [:]) {
        self.init(statusCode: statusCode, headers: headers, body: Data(body.utf8))
    }
}
