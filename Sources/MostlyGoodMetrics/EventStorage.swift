import Foundation

/// Protocol for event storage implementations
protocol EventStorage {
    func store(event: MGMEvent)
    func fetchEvents(limit: Int) -> [MGMEvent]
    func removeEvents(_ events: [MGMEvent])
    func eventCount() -> Int
    func clear()
}

/// File-based event storage using JSON
final class FileEventStorage: EventStorage {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.mostlygoodmetrics.storage", attributes: .concurrent)
    private var events: [MGMEvent] = []
    private let maxEvents: Int

    init(maxEvents: Int = 10000) {
        self.maxEvents = maxEvents

        let fileManager = FileManager.default
        let appSupportURL: URL

        #if os(tvOS)
        // tvOS doesn't have persistent storage, use caches
        appSupportURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        #else
        appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #endif

        let mgmDirectory = appSupportURL.appendingPathComponent("MostlyGoodMetrics", isDirectory: true)

        if !fileManager.fileExists(atPath: mgmDirectory.path) {
            try? fileManager.createDirectory(at: mgmDirectory, withIntermediateDirectories: true)
        }

        self.fileURL = mgmDirectory.appendingPathComponent("events.json")
        loadFromDisk()
    }

    func store(event: MGMEvent) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.events.append(event)

            // Drop oldest events if we exceed the max
            if self.events.count > self.maxEvents {
                self.events.removeFirst(self.events.count - self.maxEvents)
            }

            self.saveToDisk()
        }
    }

    func fetchEvents(limit: Int) -> [MGMEvent] {
        queue.sync {
            Array(events.prefix(limit))
        }
    }

    func removeEvents(_ eventsToRemove: [MGMEvent]) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            // Remove events by matching name and timestamp
            let removeSet = Set(eventsToRemove.map { "\($0.name)-\($0.timestamp.timeIntervalSince1970)" })
            self.events.removeAll { event in
                removeSet.contains("\(event.name)-\(event.timestamp.timeIntervalSince1970)")
            }

            self.saveToDisk()
        }
    }

    func eventCount() -> Int {
        queue.sync {
            events.count
        }
    }

    func clear() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.events.removeAll()
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }

    private func loadFromDisk() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }

            do {
                let data = try Data(contentsOf: self.fileURL)
                self.events = try JSONDecoder().decode([MGMEvent].self, from: data)
            } catch {
                // If we can't load, start fresh
                self.events = []
            }
        }
    }

    private func saveToDisk() {
        // Called within barrier queue
        do {
            let data = try JSONEncoder().encode(events)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Silently fail - we'll lose events but won't crash the app
        }
    }
}

/// In-memory event storage (for testing or when persistence isn't needed)
final class InMemoryEventStorage: EventStorage {
    private var events: [MGMEvent] = []
    private let queue = DispatchQueue(label: "com.mostlygoodmetrics.memory-storage", attributes: .concurrent)
    private let maxEvents: Int

    init(maxEvents: Int = 10000) {
        self.maxEvents = maxEvents
    }

    func store(event: MGMEvent) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.events.append(event)

            if self.events.count > self.maxEvents {
                self.events.removeFirst(self.events.count - self.maxEvents)
            }
        }
    }

    func fetchEvents(limit: Int) -> [MGMEvent] {
        queue.sync {
            Array(events.prefix(limit))
        }
    }

    func removeEvents(_ eventsToRemove: [MGMEvent]) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            let removeSet = Set(eventsToRemove.map { "\($0.name)-\($0.timestamp.timeIntervalSince1970)" })
            self.events.removeAll { event in
                removeSet.contains("\(event.name)-\(event.timestamp.timeIntervalSince1970)")
            }
        }
    }

    func eventCount() -> Int {
        queue.sync {
            events.count
        }
    }

    func clear() {
        queue.async(flags: .barrier) { [weak self] in
            self?.events.removeAll()
        }
    }
}
