import Foundation
import Testing
@testable import CloudflareWorkerKV

@Suite("JSONValue")
struct JSONValueTests {
    private func parse(_ text: String) throws -> JSONValue {
        try JSONValue(parsing: Data(text.utf8))
    }

    @Test("booleans and numbers are told apart")
    func boolVersusNumber() throws {
        #expect(try parse("true") == .bool(true))
        #expect(try parse("false") == .bool(false))
        #expect(try parse("1") == .int(1))
        #expect(try parse("0") == .int(0))
        #expect(try parse("-3") == .int(-3))
        #expect(try parse("1.5") == .double(1.5))
        #expect(try parse("9223372036854775807") == .int(.max))
        #expect(try parse("[true,1,0,false]") == [true, 1, 0, false])
        #expect(try parse(#"{"t":true,"one":1}"#) == ["t": true, "one": 1])
    }

    @Test("parses every kind of value")
    func kinds() throws {
        #expect(try parse("null") == .null)
        #expect(try parse(#""xin chào""#) == .string("xin chào"))
        #expect(try parse(#"[1,"two",null,{"k":[]}]"#) == [1, "two", nil, ["k": []]])
        #expect(throws: (any Error).self) { try parse("not json") }
        #expect(throws: (any Error).self) { try parse("") }
    }

    @Test("serializer escapes quotes, backslashes and control characters")
    func escaping() {
        let value: JSONValue = .string("q\" b\\ \u{08}\u{0C}\n\r\t \u{01}\u{1F}")
        #expect(value.compactJSONString == #""q\" b\\ \b\f\n\r\t \u0001\u001f""#)
    }

    @Test("serializer does not escape / or non-ASCII characters")
    func noEscaping() {
        let value: JSONValue = ["url": "https://x.dev/a", "text": "xin chào 👋", "del": "\u{7F}"]
        #expect(value.compactJSONString == #"{"del":"\#u{7F}","text":"xin chào 👋","url":"https://x.dev/a"}"#)
    }

    @Test("serializer sorts object keys and writes no whitespace")
    func keyOrder() {
        let value: JSONValue = ["b": 1, "a": ["d": true, "c": nil], "A": [1, 2.5, "x"]]
        #expect(value.compactJSONString == #"{"A":[1,2.5,"x"],"a":{"c":null,"d":true},"b":1}"#)
        #expect(JSONValue.object([:]).compactJSONString == "{}")
        #expect(JSONValue.array([]).compactJSONString == "[]")
    }

    @Test("serializer writes non-finite doubles as null")
    func nonFinite() {
        #expect(JSONValue.array([.double(.nan), .double(.infinity)]).compactJSONString == "[null,null]")
    }

    @Test("serialized text parses back to the same value")
    func roundTrip() throws {
        let value: JSONValue = ["s": "a\"b\\c\n/é", "i": -42, "d": 0.25, "b": false, "n": nil, "a": [[], [:]]]
        #expect(try parse(value.compactJSONString) == value)
    }

    @Test("entry strings follow the contract")
    func entryStrings() {
        #expect(JSONValue.string("text").entryString == "text")
        #expect(JSONValue.null.entryString == nil)
        #expect(JSONValue.int(42).entryString == "42")
        #expect(JSONValue.bool(true).entryString == "true")
        #expect(JSONValue.double(1.5).entryString == "1.5")
        #expect(JSONValue.double(0).entryString == "0.0")
        #expect((["k": 1] as JSONValue).entryString == #"{"k":1}"#)
        #expect(([1, "two", true] as JSONValue).entryString == #"[1,"two",true]"#)
    }

    @Test("Codable round trip through JSONEncoder")
    func codable() throws {
        let value: JSONValue = ["a": [1, 2.5, "x", true, nil]]
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test("literals")
    func literals() {
        let value: JSONValue = ["k": "v", "k2": 1, "k3": 1.5, "k4": false, "k5": nil, "k6": [1]]
        #expect(value == .object([
            "k": .string("v"), "k2": .int(1), "k3": .double(1.5), "k4": .bool(false),
            "k5": .null, "k6": .array([.int(1)]),
        ]))
    }
}
