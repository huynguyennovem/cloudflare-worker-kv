import Foundation

/// A type that can be passed to ``CloudflareRemoteConfig/setDefaults(_:)``.
///
/// Strings, booleans, integers, floating-point numbers, ``JSONValue`` and
/// optionals of those conform. Types that are not supported are rejected at
/// compile time.
///
/// Enums backed by a supported raw value only need to declare conformance:
///
/// ```swift
/// enum Theme: String, RemoteConfigDefaultConvertible { case light, dark }
/// remoteConfig.setDefaults(["theme": Theme.dark])
/// ```
public protocol RemoteConfigDefaultConvertible: Sendable {
    /// The value as it is stored among the defaults, or `nil` to ignore it.
    var remoteConfigDefaultString: String? { get }
}

extension RemoteConfigDefaultConvertible where Self: RawRepresentable, RawValue: RemoteConfigDefaultConvertible {
    /// The raw value, converted like any other default.
    public var remoteConfigDefaultString: String? { rawValue.remoteConfigDefaultString }
}

extension String: RemoteConfigDefaultConvertible {
    public var remoteConfigDefaultString: String? { self }
}

extension Bool: RemoteConfigDefaultConvertible {
    public var remoteConfigDefaultString: String? { self ? "true" : "false" }
}

extension Int: RemoteConfigDefaultConvertible {
    public var remoteConfigDefaultString: String? { String(self) }
}

extension Int8: RemoteConfigDefaultConvertible {
    public var remoteConfigDefaultString: String? { String(self) }
}

extension Int16: RemoteConfigDefaultConvertible {
    public var remoteConfigDefaultString: String? { String(self) }
}

extension Int32: RemoteConfigDefaultConvertible {
    public var remoteConfigDefaultString: String? { String(self) }
}

extension Int64: RemoteConfigDefaultConvertible {
    public var remoteConfigDefaultString: String? { String(self) }
}

extension UInt: RemoteConfigDefaultConvertible {
    public var remoteConfigDefaultString: String? { String(self) }
}

extension UInt8: RemoteConfigDefaultConvertible {
    public var remoteConfigDefaultString: String? { String(self) }
}

extension UInt16: RemoteConfigDefaultConvertible {
    public var remoteConfigDefaultString: String? { String(self) }
}

extension UInt32: RemoteConfigDefaultConvertible {
    public var remoteConfigDefaultString: String? { String(self) }
}

extension UInt64: RemoteConfigDefaultConvertible {
    public var remoteConfigDefaultString: String? { String(self) }
}

extension Double: RemoteConfigDefaultConvertible {
    /// `description`, so `0.0` is stored as `"0.0"` like the Flutter SDK does.
    public var remoteConfigDefaultString: String? { description }
}

extension Float: RemoteConfigDefaultConvertible {
    public var remoteConfigDefaultString: String? { description }
}

extension JSONValue: RemoteConfigDefaultConvertible {
    /// Strings as is, `null` ignored, booleans and numbers as text, arrays and
    /// objects as compact JSON with sorted keys.
    public var remoteConfigDefaultString: String? { entryString }
}

extension Optional: RemoteConfigDefaultConvertible where Wrapped: RemoteConfigDefaultConvertible {
    /// `nil` is ignored.
    public var remoteConfigDefaultString: String? { self?.remoteConfigDefaultString }
}
