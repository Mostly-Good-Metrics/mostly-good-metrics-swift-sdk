import Foundation
import CoreFoundation

/// Bounds work before bridging Foundation collections or recursively encoding values.
/// Snapshots own their containers; callers must still avoid mutating inputs during track().
struct PropertySnapshot {
    static let maxNodes = 1024
    static let maxDepth = 3
    static let maxPropertyBytes = 10 * 1024
    static func validKey(_ key: String) -> Bool {
        // A single grapheme can contain arbitrarily many combining marks.
        key.utf8.prefix(4001).count <= 4000 && key.count <= 1000
    }
    static func boundedString(_ string: String) -> String {
        let bounded = String(decoding: string.utf8.prefix(maxPropertyBytes), as: UTF8.self)
        return String(bounded.prefix(1000))
    }
    private var remaining = maxNodes

    mutating func copy(_ value: Any, depth: Int = 0) -> Any {
        guard remaining > 0 else { return NSNull() }
        remaining -= 1
        // Inspect Objective-C containers BEFORE any Swift collection cast: bridging
        // a self-referential NSMutableArray/Dictionary recursively traverses its graph.
        if type(of: value) is AnyClass {
            if let array = value as? NSArray {
                guard depth < Self.maxDepth else { return NSNull() }
                let cf = unsafeBitCast(array, to: CFArray.self)
                var result: [Any] = []
                for index in 0..<min(CFArrayGetCount(cf), remaining) {
                    guard remaining > 0 else { break }
                    let object = Unmanaged<AnyObject>.fromOpaque(CFArrayGetValueAtIndex(cf, index)).takeUnretainedValue()
                    result.append(copy(object, depth: depth + 1))
                }
                return result
            }
            if let dictionary = value as? NSDictionary {
                guard depth < Self.maxDepth else { return NSNull() }
                // Enumerate bounded keys, then retrieve raw CF values. Do not bridge
                // the entire dictionary, including unread nested cyclic containers.
                let cf = unsafeBitCast(dictionary, to: CFDictionary.self)
                var result: [String: Any] = [:]
                let enumerator = dictionary.keyEnumerator()
                while remaining > 0, let rawKey = enumerator.nextObject() {
                    guard let key = rawKey as? String, Self.validKey(key) else { remaining -= 1; continue }
                    let pointer = Unmanaged.passUnretained(rawKey as AnyObject).toOpaque()
                    guard let raw = CFDictionaryGetValue(cf, pointer) else { continue }
                    let object = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
                    result[key] = copy(object, depth: depth + 1)
                }
                return result
            }
        }
        if let array = value as? [Any] {
            guard depth < Self.maxDepth else { return NSNull() }
            var result: [Any] = []
            for item in array.prefix(remaining) {
                guard remaining > 0 else { break }
                result.append(copy(item, depth: depth + 1))
            }
            return result
        }
        if let dictionary = value as? [String: Any] {
            guard depth < Self.maxDepth else { return NSNull() }
            var result: [String: Any] = [:]
            for (key, item) in dictionary {
                guard remaining > 0 else { break }
                guard Self.validKey(key) else { remaining -= 1; continue }
                result[key] = copy(item, depth: depth + 1)
            }
            return result
        }
        if value is NSNull { return NSNull() }
        if let string = value as? String { return Self.boundedString(string) }
        if let bool = value as? Bool { return bool }
        if let int = value as? Int { return int }
        if let double = value as? Double { return double.isFinite ? double : NSNull() }
        return NSNull()
    }

    static func properties(_ properties: [String: Any]?) -> [String: AnyCodable]? {
        guard let properties else { return nil }
        var snapshot = PropertySnapshot()
        // The root property dictionary does not consume one of the three value levels.
        var result: [String: AnyCodable] = [:]
        for (key, value) in properties {
            guard snapshot.remaining > 0 else { break }
            guard Self.validKey(key) else { snapshot.remaining -= 1; continue }
            result[key] = AnyCodable(snapshotValue: snapshot.copy(value))
        }
        guard let data = try? JSONEncoder().encode(result), data.count <= maxPropertyBytes else { return nil }
        return result
    }
}
