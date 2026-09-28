import Foundation
import Testing
@testable import CloudflareWorkerKV

private func remote(_ value: String) -> RemoteConfigValue {
    RemoteConfigValue(value, source: .remote)
}

// Port of flutter/test/remote_config_value_test.dart.
@Suite("RemoteConfigValue")
struct RemoteConfigValueTests {
    @Suite("asBool")
    struct AsBool {
        @Test("truthy strings (case-insensitive, trimmed)",
              arguments: ["1", "true", "TRUE", "t", "T", "yes", "Y", "on", " On "])
        func truthy(_ value: String) {
            #expect(remote(value).boolValue)
        }

        @Test("everything else is false",
              arguments: ["0", "false", "no", "off", "", "2", "truthy", "null"])
        func falsy(_ value: String) {
            #expect(!remote(value).boolValue)
        }
    }

    @Suite("asInt")
    struct AsInt {
        @Test("parses integers")
        func parses() {
            #expect(remote("42").intValue == 42)
            #expect(remote("-7").intValue == -7)
            #expect(remote(" 5 ").intValue == 5)
        }

        @Test("non-integers fall back to 0", arguments: ["1.5", "abc", "", "true", "10.0"])
        func fallsBack(_ value: String) {
            #expect(remote(value).intValue == 0)
        }
    }

    @Suite("asDouble")
    struct AsDouble {
        @Test("parses numbers")
        func parses() {
            #expect(remote("1.5").doubleValue == 1.5)
            #expect(remote("3").doubleValue == 3.0)
            #expect(remote("-0.25").doubleValue == -0.25)
        }

        @Test("non-numeric falls back to 0.0", arguments: ["abc", "", "true"])
        func fallsBack(_ value: String) {
            #expect(remote(value).doubleValue == 0.0)
        }

        @Test("exotic numbers are not decimal numbers",
              arguments: ["nan", "NaN", "inf", "-Infinity", "0x1p3", "1e", "e5", ".", "+", "1.5f"])
        func exotic(_ value: String) {
            #expect(remote(value).doubleValue == 0.0)
        }
    }

    @Test("static values use type defaults")
    func staticDefaults() {
        let value = RemoteConfigValue(nil, source: .static)
        #expect(value.stringValue == "")
        #expect(value.intValue == 0)
        #expect(value.doubleValue == 0.0)
        #expect(!value.boolValue)
        #expect(value.source == .static)
        #expect(value.stringValue == RemoteConfigValue.defaultValueForString)
        #expect(value.intValue == RemoteConfigValue.defaultValueForInt)
        #expect(value.doubleValue == RemoteConfigValue.defaultValueForDouble)
        #expect(value.boolValue == RemoteConfigValue.defaultValueForBool)
    }

    @Test("equality and hashCode")
    func equality() {
        #expect(remote("a") == remote("a"))
        #expect(remote("a").hashValue == remote("a").hashValue)
        #expect(remote("a") != RemoteConfigValue("a", source: .default))
        #expect(RemoteConfigValue(nil, source: .static) != RemoteConfigValue("", source: .static))
    }

    // Swift-specific accessors.

    @Test("numberValue and dataValue")
    func numberAndData() {
        #expect(remote("2.5").numberValue == NSNumber(value: 2.5))
        #expect(remote("xin chào").dataValue == Data("xin chào".utf8))
        #expect(RemoteConfigValue(nil, source: .static).dataValue.isEmpty)
    }

    @Test("jsonValue parses JSON and is nil otherwise")
    func jsonValue() {
        #expect(remote(#"{"a":[1,true,null]}"#).jsonValue == ["a": [1, true, nil]])
        #expect(remote("42").jsonValue == .int(42))
        #expect(remote("not json").jsonValue == nil)
        #expect(RemoteConfigValue(nil, source: .static).jsonValue == nil)
    }

    @Test("decoded(asType:) decodes JSON")
    func decoded() throws {
        struct AdUnits: Decodable, Equatable {
            let banner: String
            let sizes: [Int]
        }
        let value = remote(#"{"banner":"b1","sizes":[320,728]}"#)
        #expect(try value.decoded(asType: AdUnits.self) == AdUnits(banner: "b1", sizes: [320, 728]))
        let inferred: [String: Int] = try remote(#"{"a":1}"#).decoded()
        #expect(inferred == ["a": 1])
        #expect(throws: DecodingError.self) { try remote("nope").decoded(asType: AdUnits.self) }
    }

    @Test("description")
    func description() {
        #expect(remote("a").description == #"RemoteConfigValue("a", source: .remote)"#)
        #expect(RemoteConfigValue(nil, source: .static).description == "RemoteConfigValue(nil, source: .static)")
    }
}
