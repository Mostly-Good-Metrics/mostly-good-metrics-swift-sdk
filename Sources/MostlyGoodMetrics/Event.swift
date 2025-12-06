import Foundation

/// Represents an analytics event to be tracked
public struct MGMEvent: Codable, Equatable {
    /// The event name (alphanumeric + underscore, must start with letter, max 255 chars)
    public let name: String

    /// The timestamp when the event occurred
    public let timestamp: Date

    /// Optional user identifier
    public var userId: String?

    /// Optional session identifier
    public var sessionId: String?

    /// Platform identifier (e.g., "ios", "macos", "tvos", "watchos")
    public var platform: String?

    /// App version string
    public var appVersion: String?

    /// OS version string
    public var osVersion: String?

    /// Environment (e.g., "production", "staging")
    public var environment: String?

    /// Custom properties for the event (max 10KB, 3 levels deep)
    public var properties: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case name
        case timestamp
        case userId = "user_id"
        case sessionId = "session_id"
        case platform
        case appVersion = "app_version"
        case osVersion = "os_version"
        case environment
        case properties
    }

    /// Creates a new event with the specified name and optional properties
    /// - Parameters:
    ///   - name: The event name
    ///   - properties: Optional custom properties
    ///   - timestamp: The event timestamp (defaults to now)
    public init(
        name: String,
        properties: [String: Any]? = nil,
        timestamp: Date = Date()
    ) {
        self.name = name
        self.timestamp = timestamp
        self.properties = properties?.mapValues { AnyCodable($0) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try container.encode(formatter.string(from: timestamp), forKey: .timestamp)

        try container.encodeIfPresent(userId, forKey: .userId)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(platform, forKey: .platform)
        try container.encodeIfPresent(appVersion, forKey: .appVersion)
        try container.encodeIfPresent(osVersion, forKey: .osVersion)
        try container.encodeIfPresent(environment, forKey: .environment)
        try container.encodeIfPresent(properties, forKey: .properties)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)

        let timestampString = try container.decode(String.self, forKey: .timestamp)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestampString) {
            timestamp = date
        } else {
            formatter.formatOptions = [.withInternetDateTime]
            timestamp = formatter.date(from: timestampString) ?? Date()
        }

        userId = try container.decodeIfPresent(String.self, forKey: .userId)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
        osVersion = try container.decodeIfPresent(String.self, forKey: .osVersion)
        environment = try container.decodeIfPresent(String.self, forKey: .environment)
        properties = try container.decodeIfPresent([String: AnyCodable].self, forKey: .properties)
    }
}

/// Type-erased wrapper for encoding any value as JSON
public struct AnyCodable: Codable, Equatable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unable to decode value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(String(string.prefix(1000))) // Truncate to 1000 chars
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case is (NSNull, NSNull):
            return true
        case let (lhs as Bool, rhs as Bool):
            return lhs == rhs
        case let (lhs as Int, rhs as Int):
            return lhs == rhs
        case let (lhs as Double, rhs as Double):
            return lhs == rhs
        case let (lhs as String, rhs as String):
            return lhs == rhs
        default:
            return false
        }
    }
}

/// Payload structure for the events API
struct MGMEventsPayload: Encodable {
    let events: [MGMEvent]
    let context: MGMEventContext?
}

/// Context applied to all events in a batch
struct MGMEventContext: Encodable {
    var platform: String?
    var appVersion: String?
    var osVersion: String?
    var userId: String?
    var sessionId: String?
    var environment: String?

    enum CodingKeys: String, CodingKey {
        case platform
        case appVersion = "app_version"
        case osVersion = "os_version"
        case userId = "user_id"
        case sessionId = "session_id"
        case environment
    }
}
