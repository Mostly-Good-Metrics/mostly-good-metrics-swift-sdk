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
    private let queue = DispatchQueue(label: "com.mostlygoodmetrics.storage", attributes: .concurrent)
    private var events: [MGMEvent] = []
    private let maxEvents: Int

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
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.events.append(event)

            // Drop oldest events if we exceed the max
            if self.events.count > self.maxEvents {
                self.events.removeFirst(self.events.count - self.maxEvents)
            }

            self.saveToDisk()
            completion?(self.events.count)
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

            let removeSet = Set(eventsToRemove.map(\.clientEventId))
            self.events.removeAll { event in
                removeSet.contains(event.clientEventId)
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

    func store(event: MGMEvent, completion: ((Int) -> Void)?) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
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
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

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
        queue.async(flags: .barrier) { [weak self] in
            self?.events.removeAll()
        }
    }
}
