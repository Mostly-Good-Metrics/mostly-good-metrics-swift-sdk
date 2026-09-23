import Foundation

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

/// File-based event storage using JSON
final class FileEventStorage: EventStorage {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.mostlygoodmetrics.storage")
    private var events: [MGMEvent] = []
    private let maxEvents: Int
    private var staleEventCount = 0
    private var isAppendFormatReady = false

    /// Compact only after enough capped events have accumulated. Normal stores append
    /// one JSON line and never encode the complete queue.
    private var compactionThreshold: Int {
        max(100, maxEvents / 10)
    }

    init(maxEvents: Int = 10000, fileURL: URL? = nil) {
        self.maxEvents = maxEvents

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

            // Drop oldest events if we exceed the max
            if self.events.count > self.maxEvents {
                let overflow = self.events.count - self.maxEvents
                self.events.removeFirst(overflow)
                self.staleEventCount += overflow
            }

            if self.isAppendFormatReady {
                self.appendToDisk(event)
            } else {
                self.rewriteDisk()
            }

            if self.staleEventCount >= self.compactionThreshold {
                self.rewriteDisk()
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
            self.events.removeAll { event in
                removeSet.contains(event.clientEventId)
            }

            self.rewriteDisk()
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
            self.isAppendFormatReady = true
            try? FileManager.default.removeItem(at: self.fileURL)
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
                    // Migrate the legacy JSON-array store once. Subsequent writes use
                    // an append-only newline-delimited format.
                    self.events = try JSONDecoder().decode([MGMEvent].self, from: data)
                    self.trimToLimit()
                    self.rewriteDisk()
                } else {
                    self.isAppendFormatReady = true
                    self.events = data.split(separator: Character("\n").asciiValue!).compactMap {
                        try? JSONDecoder().decode(MGMEvent.self, from: Data($0))
                    }
                    if self.events.count > self.maxEvents {
                        self.trimToLimit()
                        self.rewriteDisk()
                    }
                }
            } catch {
                // If we can't load, start fresh
                self.events = []
            }
        }
    }

    private func appendToDisk(_ event: MGMEvent) {
        do {
            var data = try JSONEncoder().encode(event)
            data.append(Character("\n").asciiValue!)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            // Silently fail - matches the existing best-effort persistence behavior.
        }
    }

    private func rewriteDisk() {
        isAppendFormatReady = false
        do {
            var data = Data()
            for event in events {
                data.append(try JSONEncoder().encode(event))
                data.append(Character("\n").asciiValue!)
            }
            try data.write(to: fileURL, options: .atomic)
            staleEventCount = 0
            isAppendFormatReady = true
        } catch {
            // Silently fail - we'll lose events but won't crash the app
        }
    }

    private func trimToLimit() {
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
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

    init(maxEvents: Int = 10000) {
        self.maxEvents = maxEvents
    }

    func store(event: MGMEvent, completion: ((Int) -> Void)?) {
        queue.async {
            self.events.append(event)

            if self.events.count > self.maxEvents {
                self.events.removeFirst(self.events.count - self.maxEvents)
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
            self.events.removeAll { event in
                removeSet.contains(event.clientEventId)
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
        }
    }
}
