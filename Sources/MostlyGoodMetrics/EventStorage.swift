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
    private let queueKey = DispatchSpecificKey<Bool>()
    private let maxEvents: Int
    private var eventWeights: [Int] = []
    private var retainedBytes = 0
    private let admissionLock = NSLock()
    private var pendingBytes = 0

    private func admit(_ weight: Int) -> Bool {
        admissionLock.lock()
        defer { admissionLock.unlock() }
        guard weight <= EventMemoryBudget.maxBytes,
              pendingBytes + weight <= EventMemoryBudget.maxBytes * 4 else { return false }
        pendingBytes += weight
        return true
    }

    private func releaseAdmission(_ weight: Int) {
        admissionLock.lock()
        pendingBytes -= weight
        admissionLock.unlock()
    }

    private func append(_ event: MGMEvent, weight: Int) {
        guard weight <= EventMemoryBudget.maxBytes else { return }
        events.append(event)
        eventWeights.append(weight)
        retainedBytes += weight
        while events.count > maxEvents || retainedBytes > EventMemoryBudget.maxBytes {
            events.removeFirst()
            retainedBytes -= eventWeights.removeFirst()
        }
    }

    private func rebuildWeights() {
        let previous = events
        events = []
        eventWeights = []
        retainedBytes = 0
        for event in previous { append(event, weight: EventMemoryBudget.weight(event)) }
    }

    init(maxEvents: Int = 10000, fileURL: URL? = nil) {
        self.maxEvents = max(0, maxEvents)
        queue.setSpecific(key: queueKey, value: true)

        let fileManager = FileManager.default
        let resolvedFileURL: URL
        if let fileURL {
            resolvedFileURL = fileURL
        } else {
            let appSupportURL: URL

            #if os(tvOS)
            // tvOS doesn't have persistent storage, use caches
            appSupportURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
            #else
            appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
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
        let weight = EventMemoryBudget.weight(event)
        guard admit(weight) else { return }
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            defer { self.releaseAdmission(weight) }
            self.append(event, weight: weight)
            self.scheduleSaveToDisk()
            completion?(self.events.count)
        }
    }

    func fetchEvents(limit: Int) -> [MGMEvent] {
        if DispatchQueue.getSpecific(key: queueKey) == true { return Array(events.prefix(max(0, limit))) }
        return queue.sync { Array(events.prefix(max(0, limit))) }
    }

    func removeEvents(_ eventsToRemove: [MGMEvent]) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            let removeSet = Set(eventsToRemove.map(\.clientEventId))
            self.events.removeAll { event in
                removeSet.contains(event.clientEventId)
            }
            self.rebuildWeights()

            self.scheduleSaveToDisk()
        }
    }

    func eventCount() -> Int {
        if DispatchQueue.getSpecific(key: queueKey) == true { return events.count }
        return queue.sync { events.count }
    }

    func clear() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.events.removeAll()
            self.eventWeights.removeAll()
            self.retainedBytes = 0
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }

    private func loadFromDisk() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }

            do {
                guard let data = JSONSafety.readCache(self.fileURL) else { return }
                self.events = try JSONDecoder().decode([MGMEvent].self, from: data)
                self.rebuildWeights()
            } catch {
                // If we can't load, start fresh
                self.events = []
            }
        }
    }

    private var saveQueued = false // Only accessed on the storage barrier queue.
    private func scheduleSaveToDisk() {
        guard !saveQueued else { return }
        saveQueued = true
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.saveQueued = false
            self.saveToDisk()
        }
    }

    private func saveToDisk() {
        // Called within barrier queue
        do {
            let data = try JSONEncoder().encode(events)
            guard data.count <= JSONSafety.maxBytes else { return }
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
    private let queueKey = DispatchSpecificKey<Bool>()
    private let maxEvents: Int
    private var eventWeights: [Int] = []
    private var retainedBytes = 0
    private let admissionLock = NSLock()
    private var pendingBytes = 0

    private func admit(_ weight: Int) -> Bool {
        admissionLock.lock()
        defer { admissionLock.unlock() }
        guard weight <= EventMemoryBudget.maxBytes,
              pendingBytes + weight <= EventMemoryBudget.maxBytes * 4 else { return false }
        pendingBytes += weight
        return true
    }

    private func releaseAdmission(_ weight: Int) {
        admissionLock.lock()
        pendingBytes -= weight
        admissionLock.unlock()
    }

    private func append(_ event: MGMEvent, weight: Int) {
        guard weight <= EventMemoryBudget.maxBytes else { return }
        events.append(event)
        eventWeights.append(weight)
        retainedBytes += weight
        while events.count > maxEvents || retainedBytes > EventMemoryBudget.maxBytes {
            events.removeFirst()
            retainedBytes -= eventWeights.removeFirst()
        }
    }

    private func rebuildWeights() {
        let previous = events
        events = []
        eventWeights = []
        retainedBytes = 0
        for event in previous { append(event, weight: EventMemoryBudget.weight(event)) }
    }

    init(maxEvents: Int = 10000) {
        self.maxEvents = max(0, maxEvents)
        queue.setSpecific(key: queueKey, value: true)
    }

    func store(event: MGMEvent, completion: ((Int) -> Void)?) {
        let weight = EventMemoryBudget.weight(event)
        guard admit(weight) else { return }
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            defer { self.releaseAdmission(weight) }
            self.append(event, weight: weight)
            completion?(self.events.count)
        }
    }

    func fetchEvents(limit: Int) -> [MGMEvent] {
        if DispatchQueue.getSpecific(key: queueKey) == true { return Array(events.prefix(max(0, limit))) }
        return queue.sync { Array(events.prefix(max(0, limit))) }
    }

    func removeEvents(_ eventsToRemove: [MGMEvent]) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            let removeSet = Set(eventsToRemove.map(\.clientEventId))
            self.events.removeAll { event in
                removeSet.contains(event.clientEventId)
            }
            self.rebuildWeights()
        }
    }

    func eventCount() -> Int {
        if DispatchQueue.getSpecific(key: queueKey) == true { return events.count }
        return queue.sync { events.count }
    }

    func clear() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.events.removeAll()
            self.eventWeights.removeAll()
            self.retainedBytes = 0
        }
    }
}
