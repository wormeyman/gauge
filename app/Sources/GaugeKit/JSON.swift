import Foundation

/// Any JSON value. The local API and the MCP server pass requests and results around as these,
/// so neither needs to know every result's shape.
public enum JSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var object: [String: JSON]? { if case .object(let v) = self { return v }; return nil }

    /// Whole numbers, including ones sent as 3000.0.
    public var int: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v) where v.rounded() == v && abs(v) < 1e15: return Int(v)
        case .string(let v): return Int(v)
        default: return nil
        }
    }

    // MARK: Conversions

    /// Encodes a Codable value as JSON, with dates as ISO 8601 strings.
    public init<T: Encodable>(encoding value: T) throws {
        self = try API.decoder.decode(JSON.self, from: API.encoder.encode(value))
    }

    public func decode<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try API.decoder.decode(T.self, from: API.encoder.encode(self))
    }

    public func data(pretty: Bool = false) -> Data {
        let encoder = pretty ? API.prettyEncoder : API.encoder
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public func text(pretty: Bool = false) -> String { String(decoding: data(pretty: pretty), as: UTF8.self) }

    public static func parse(_ data: Data) throws -> JSON { try API.decoder.decode(JSON.self, from: data) }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
