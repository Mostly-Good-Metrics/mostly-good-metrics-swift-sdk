import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Protocol for event storage implementations
protocol EventStorage {
    func store(event: MGMEvent, completion: ((Int) -> Void)?)
    func fetchEvents(limit: Int) -> [MGMEvent]
    func removeEvents(_ events: [MGMEvent])
    func eventCount() -> Int
    func clear()
}

extension EventStorage {
    func store(event: MGMEvent) {
        store(event: event, completion: nil)
    }
}

/// File-based event storage using newline-delimited JSON.
final class FileEventStorage: EventStorage {
    typealias AppendWriter = (Data, URL) throws -> Void

    private struct StorageHeader: Codable {
        let format: String
        let migrationEventLimit: Int
    }

    private static let storageFormat = "mgm-ndjson-v1"
    private static let maximumUnreadableArchives = 3

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.mostlygoodmetrics.storage")
    private let maxEvents: Int
    private let appendWriter: AppendWriter
    private let warningHandler: (String) -> Void
    private let encoder = JSONEncoder()
    private var events: [MGMEvent] = []
    private var staleEventCount = 0
    private var isAppendFormatReady = false
    private var migrationEventLimit: Int?
    private var requiresLegacyBackup = false
    private var hasWarnedAboutLimitEviction = false

    private var preMigrationBackupURL: URL {
        fileURL.appendingPathExtension("pre-ndjson")
    }

    /// Compact after at most 1% stale entries (capped at 100). Small stores compact
    /// immediately at their cap, while the default store amortizes full rewrites.
    private var compactionThreshold: Int {
        max(1, min(100, (migrationEventLimit ?? maxEvents) / 100))
    }

    init(
        maxEvents: Int = 10000,
        fileURL: URL? = nil,
        appendWriter: AppendWriter? = nil,
        warningHandler: ((String) -> Void)? = nil
    ) {
        self.maxEvents = maxEvents
        self.appendWriter = appendWriter ?? Self.appendUsingOAppend
        self.warningHandler = warningHandler ?? { _ in }

        let fileManager = FileManager.default
        let resolvedFileURL: URL
        if let fileURL {
            resolvedFileURL = fileURL
        } else {
            let appSupportURL: URL

            #if os(tvOS)
            // tvOS doesn't have persistent storage, use caches
            appSupportURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
            #else
            appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            #endif

            resolvedFileURL = appSupportURL
                .appendingPathComponent("MostlyGoodMetrics", isDirectory: true)
                .appendingPathComponent("events.json")
        }

        let mgmDirectory = resolvedFileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: mgmDirectory.path) {
            try? fileManager.createDirectory(at: mgmDirectory, withIntermediateDirectories: true)
        }

        self.fileURL = resolvedFileURL
        loadFromDisk()
    }

    func store(event: MGMEvent, completion: ((Int) -> Void)?) {
        queue.async {
            self.events.append(event)

            let eventLimit = self.migrationEventLimit ?? self.maxEvents
            if self.events.count > eventLimit {
                let droppedCount = self.events.count - eventLimit
                self.events.removeFirst(droppedCount)
                self.staleEventCount += droppedCount
                if !self.hasWarnedAboutLimitEviction {
                    self.hasWarnedAboutLimitEviction = true
                    self.warningHandler(
                        "Dropped oldest event(s) at the configured storage limit; "
                            + "further evictions will not be logged this session"
                    )
                }
            }

            if !self.isAppendFormatReady || self.staleEventCount >= self.compactionThreshold {
                self.rewriteDisk()
            } else {
                self.appendToDisk(event)
            }

            completion?(self.events.count)
        }
    }

    func fetchEvents(limit: Int) -> [MGMEvent] {
        queue.sync {
            Array(events.prefix(limit))
        }
    }

    func removeEvents(_ eventsToRemove: [MGMEvent]) {
        queue.async {
            let removeSet = Set(eventsToRemove.map(\.clientEventId))
            self.events.removeAll { removeSet.contains($0.clientEventId) }

            if self.migrationEventLimit != nil, self.events.count <= self.maxEvents {
                self.migrationEventLimit = nil
            }
            if self.rewriteDisk() {
                self.removePreMigrationBackup()
            }
        }
    }

    func eventCount() -> Int {
        queue.sync {
            events.count
        }
    }

    func clear() {
        queue.async {
            self.events.removeAll()
            self.staleEventCount = 0
            self.migrationEventLimit = nil
            self.requiresLegacyBackup = false
            self.isAppendFormatReady = true
            self.removeItemIfPresent(at: self.fileURL)
            self.removeItemIfPresent(at: self.preMigrationBackupURL)
            for archiveURL in self.unreadableArchiveURLs() {
                self.removeItemIfPresent(at: archiveURL)
            }
        }
    }

    private func loadFromDisk() {
        queue.async {
            guard FileManager.default.fileExists(atPath: self.fileURL.path) else {
                self.isAppendFormatReady = true
                return
            }

            do {
                let data = try Data(contentsOf: self.fileURL)
                let firstByte = data.first { !$0.isASCIIWhitespace }
                if firstByte == Character("[").asciiValue {
                    self.loadLegacyArray(data)
                } else {
                    self.loadNDJSON(data)
                }
            } catch {
                self.recoverUnreadableFile(salvagedEvents: [], reason: error.localizedDescription)
            }
        }
    }

    private func loadLegacyArray(_ data: Data) {
        guard let values = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            recoverUnreadableFile(salvagedEvents: [], reason: "invalid legacy JSON array")
            return
        }

        var salvaged: [MGMEvent] = []
        var invalidCount = 0
        for value in values {
            guard JSONSerialization.isValidJSONObject(value),
                  let elementData = try? JSONSerialization.data(withJSONObject: value),
                  let event = try? JSONDecoder().decode(MGMEvent.self, from: elementData) else {
                invalidCount += 1
                continue
            }
            salvaged.append(event)
        }

        events = salvaged
        migrationEventLimit = events.count > maxEvents ? max(maxEvents, events.count) : nil
        if let migrationEventLimit {
            warningHandler(
                "Preserving \(events.count - maxEvents) event(s) above the configured limit until flush drains them; "
                    + "the queue remains bounded at \(migrationEventLimit) events"
            )
        }

        requiresLegacyBackup = true
        guard createLegacyBackupIfNeeded() else { return }

        if invalidCount > 0 {
            recoverUnreadableFile(
                salvagedEvents: salvaged,
                reason: "\(invalidCount) unreadable legacy event(s)"
            )
        } else {
            rewriteDisk()
        }
    }

    private func loadNDJSON(_ data: Data) {
        let lines = data.split(separator: Character("\n").asciiValue!, omittingEmptySubsequences: true)
        var startIndex = 0
        var storedMigrationLimit: Int?

        if let first = lines.first,
           let header = try? JSONDecoder().decode(StorageHeader.self, from: Data(first)),
           header.format == Self.storageFormat {
            storedMigrationLimit = max(maxEvents, header.migrationEventLimit)
            startIndex = 1
        }

        var salvaged: [MGMEvent] = []
        var invalidCount = 0
        for line in lines.dropFirst(startIndex) {
            if let event = try? JSONDecoder().decode(MGMEvent.self, from: Data(line)) {
                salvaged.append(event)
            } else {
                invalidCount += 1
            }
        }

        events = salvaged
        migrationEventLimit = storedMigrationLimit.flatMap { events.count > maxEvents ? $0 : nil }

        var staleCount = 0
        let eventLimit = migrationEventLimit ?? maxEvents
        if events.count > eventLimit {
            staleCount = events.count - eventLimit
            events.removeFirst(staleCount)
            warningHandler("Discarded \(staleCount) stale journal entr\(staleCount == 1 ? "y" : "ies") while loading")
        }

        if invalidCount > 0 {
            recoverUnreadableFile(
                salvagedEvents: events,
                reason: "\(invalidCount) unreadable or stale journal line(s)"
            )
        } else if staleCount > 0 || (storedMigrationLimit != nil && migrationEventLimit == nil) {
            rewriteDisk()
        } else {
            isAppendFormatReady = true
        }
    }

    private func appendToDisk(_ event: MGMEvent) {
        do {
            var data = try encoder.encode(event)
            data.append(Character("\n").asciiValue!)
            try appendWriter(data, fileURL)
        } catch {
            // Force the next store to atomically rewrite all in-memory events,
            // repairing both failed appends and partial tails.
            isAppendFormatReady = false
            warningHandler("Append failed; the next store will repair the journal: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func rewriteDisk() -> Bool {
        isAppendFormatReady = false
        if requiresLegacyBackup, !createLegacyBackupIfNeeded() {
            return false
        }
        do {
            var data = Data()
            if let migrationEventLimit {
                let header = StorageHeader(
                    format: Self.storageFormat,
                    migrationEventLimit: migrationEventLimit
                )
                data.append(try encoder.encode(header))
                data.append(Character("\n").asciiValue!)
            }
            for event in events {
                data.append(try encoder.encode(event))
                data.append(Character("\n").asciiValue!)
            }
            try data.write(to: fileURL, options: .atomic)
            staleEventCount = 0
            isAppendFormatReady = true
            return true
        } catch {
            warningHandler("Atomic journal rewrite failed: \(error.localizedDescription)")
            return false
        }
    }

    private func recoverUnreadableFile(salvagedEvents: [MGMEvent], reason: String) {
        let backupURL = fileURL.appendingPathExtension("unreadable-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
            pruneUnreadableArchives()
            warningHandler(
                "Moved unreadable storage to \(backupURL.lastPathComponent) (\(reason)); "
                    + "salvaged \(salvagedEvents.count) event(s)"
            )
            events = salvagedEvents
            rewriteDisk()
        } catch {
            isAppendFormatReady = false
            warningHandler(
                "Could not preserve unreadable storage; refusing to overwrite it: \(error.localizedDescription)"
            )
        }
    }

    private func createLegacyBackupIfNeeded() -> Bool {
        guard requiresLegacyBackup else { return true }
        if FileManager.default.fileExists(atPath: preMigrationBackupURL.path) {
            requiresLegacyBackup = false
            return true
        }

        do {
            try FileManager.default.copyItem(at: fileURL, to: preMigrationBackupURL)
            requiresLegacyBackup = false
            return true
        } catch {
            warningHandler("Could not back up legacy storage before migration: \(error.localizedDescription)")
            return false
        }
    }

    private func removePreMigrationBackup() {
        removeItemIfPresent(at: preMigrationBackupURL)
    }

    private func unreadableArchiveURLs() -> [URL] {
        let prefix = fileURL.lastPathComponent + ".unreadable-"
        return (try? FileManager.default.contentsOfDirectory(
            at: fileURL.deletingLastPathComponent(),
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
        ))?.filter { $0.lastPathComponent.hasPrefix(prefix) } ?? []
    }

    private func pruneUnreadableArchives() {
        let archives = unreadableArchiveURLs().sorted { lhs, rhs in
            let lhsValues = try? lhs.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let rhsValues = try? rhs.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let lhsDate = lhsValues?.creationDate ?? lhsValues?.contentModificationDate ?? .distantPast
            let rhsDate = rhsValues?.creationDate ?? rhsValues?.contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }
        for archiveURL in archives.dropFirst(Self.maximumUnreadableArchives) {
            removeItemIfPresent(at: archiveURL)
        }
    }

    private func removeItemIfPresent(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            warningHandler("Could not remove \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func appendUsingOAppend(_ data: Data, to fileURL: URL) throws {
        #if canImport(Darwin)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? Data().write(to: fileURL, options: .withoutOverwriting)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        let descriptor = handle.fileDescriptor
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_APPEND) >= 0 else {
            try? handle.close()
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let written = data.withUnsafeBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return Darwin.write(descriptor, baseAddress, bytes.count)
        }
        try handle.close()
        guard written == data.count else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        #else
        throw NSError(domain: NSPOSIXErrorDomain, code: ENOTSUP)
        #endif
    }
}

private extension UInt8 {
    var isASCIIWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}

/// In-memory event storage (for testing or when persistence isn't needed)
final class InMemoryEventStorage: EventStorage {
    private var events: [MGMEvent] = []
    private let queue = DispatchQueue(label: "com.mostlygoodmetrics.memory-storage")
    private let maxEvents: Int
    private let warningHandler: (String) -> Void

    init(maxEvents: Int = 10000, warningHandler: ((String) -> Void)? = nil) {
        self.maxEvents = maxEvents
        self.warningHandler = warningHandler ?? { _ in }
    }

    func store(event: MGMEvent, completion: ((Int) -> Void)?) {
        queue.async {
            self.events.append(event)

            if self.events.count > self.maxEvents {
                let droppedCount = self.events.count - self.maxEvents
                self.events.removeFirst(droppedCount)
                self.warningHandler("Dropped \(droppedCount) oldest event(s) at the configured storage limit")
            }

            completion?(self.events.count)
        }
    }

    func fetchEvents(limit: Int) -> [MGMEvent] {
        queue.sync {
            Array(events.prefix(limit))
        }
    }

    func removeEvents(_ eventsToRemove: [MGMEvent]) {
        queue.async {
            let removeSet = Set(eventsToRemove.map(\.clientEventId))
            self.events.removeAll { removeSet.contains($0.clientEventId) }
        }
    }

    func eventCount() -> Int {
        queue.sync {
            events.count
        }
    }

    func clear() {
        queue.async {
            self.events.removeAll()
        }
    }
}
