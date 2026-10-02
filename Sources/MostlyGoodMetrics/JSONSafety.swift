import Foundation

/// Reject oversized or deeply nested persisted/network JSON before recursive parsers.
enum JSONSafety {
    static let maxBytes = 1024 * 1024
    static func accepts(_ data: Data) -> Bool {
        guard data.count <= maxBytes else { return false }
        var depth = 0, nodes = 0
        var quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else {
                if byte == 34 { quoted = true; nodes += 1 }
                else if byte == 91 || byte == 123 { depth += 1; nodes += 1 }
                else if byte == 93 || byte == 125 { depth -= 1 }
                else if byte == 44 { nodes += 1 }
                if depth > 16 || depth < 0 || nodes > 65536 { return false }
            }
        }
        return !quoted && depth == 0
    }

    static func readCache(_ url: URL) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: maxBytes + 1), accepts(data) else { return nil }
        return data
    }
}

/// Conservative retained-memory estimate, separate from the encoded JSON size.
enum EventMemoryBudget {
    static let maxBytes = 1024 * 1024
    static func weight(_ event: MGMEvent) -> Int {
        let strings = [event.name, event.clientEventId, event.userId, event.sessionId,
                       event.platform, event.appVersion, event.appBuildNumber, event.osVersion,
                       event.environment, event.deviceManufacturer, event.locale, event.timezone]
        var bytes = 512
        for case let string? in strings {
            guard string.utf8.count <= maxBytes / 6 else { return maxBytes + 1 }
            bytes += string.utf8.count * 6
        }
        var stack: [Any] = event.properties?.map { [$0.key, $0.value.value] as [Any] } ?? []
        var nodes = 0
        while let value = stack.popLast() {
            nodes += 1
            guard nodes <= 4096, bytes <= maxBytes else { return maxBytes + 1 }
            bytes += 96
            if let string = value as? String { bytes += string.utf8.count * 6 }
            else if let array = value as? [Any] { stack.append(contentsOf: array) }
            else if let dictionary = value as? [String: Any] {
                for (key, item) in dictionary { stack.append(key); stack.append(item) }
            }
        }
        return bytes
    }
}
