import XCTest
@testable import MostlyGoodMetrics

final class AppendOnlyStorageTests: XCTestCase {
    private enum TestError: Error {
        case appendFailed
    }

    func testLegacyMigrationPreservesEventsAboveNewLimitUntilTheyDrain() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let legacyEvents = (0..<250).map { MGMEvent(name: "legacy_\($0)") }
        try JSONEncoder().encode(legacyEvents).write(to: fixture.fileURL, options: .atomic)

        let migrated = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        XCTAssertEqual(migrated.eventCount(), 250)
        migrated.removeEvents(Array(legacyEvents.prefix(100)))
        XCTAssertEqual(migrated.eventCount(), 150)

        let partiallyDrained = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        XCTAssertEqual(partiallyDrained.eventCount(), 150)
        partiallyDrained.removeEvents(Array(legacyEvents.dropFirst(100).prefix(50)))
        XCTAssertEqual(partiallyDrained.eventCount(), 100)

        let fullyDrained = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        XCTAssertEqual(fullyDrained.fetchEvents(limit: 200).map(\.name), legacyEvents.suffix(100).map(\.name))
    }

    func testStoreWhileMigrationOverflowDrainsStaysAtMigrationCount() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let legacyEvents = (0..<250).map { MGMEvent(name: "legacy_\($0)") }
        try JSONEncoder().encode(legacyEvents).write(to: fixture.fileURL, options: .atomic)

        let storage = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        XCTAssertEqual(storage.eventCount(), 250)
        for index in 0..<10 {
            storage.store(event: MGMEvent(name: "new_\(index)"))
        }

        XCTAssertEqual(storage.eventCount(), 250)
        XCTAssertEqual(
            storage.fetchEvents(limit: 300).map(\.name),
            legacyEvents.dropFirst(10).map(\.name) + (0..<10).map { "new_\($0)" }
        )

        let reloaded = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        XCTAssertEqual(reloaded.eventCount(), 250)
        XCTAssertEqual(reloaded.fetchEvents(limit: 300).map(\.name), storage.fetchEvents(limit: 300).map(\.name))
    }

    func testLegacyMigrationBackupSurvivesUntilFirstSuccessfulFlush() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let legacyEvents = [MGMEvent(name: "first"), MGMEvent(name: "second")]
        try JSONEncoder().encode(legacyEvents).write(to: fixture.fileURL, options: .atomic)

        let storage = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        XCTAssertEqual(storage.eventCount(), 2)

        let backupURL = fixture.fileURL.appendingPathExtension("pre-ndjson")
        let backedUpEvents = try JSONDecoder().decode([MGMEvent].self, from: Data(contentsOf: backupURL))
        XCTAssertEqual(backedUpEvents.map(\.name), legacyEvents.map(\.name))

        storage.removeEvents([legacyEvents[0]])
        XCTAssertEqual(storage.eventCount(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testLegacyMigrationSalvagesValidElementsAndArchivesOriginal() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let first = try jsonObject(for: MGMEvent(name: "first"))
        let second = try jsonObject(for: MGMEvent(name: "second"))
        let invalid: [String: Any] = ["timestamp": "2026-01-01T00:00:00.000Z"]
        let data = try JSONSerialization.data(withJSONObject: [first, invalid, second])
        try data.write(to: fixture.fileURL, options: .atomic)

        let storage = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        XCTAssertEqual(storage.fetchEvents(limit: 10).map(\.name), ["first", "second"])
        XCTAssertEqual(try unreadableBackups(in: fixture.directory).count, 1)
    }

    func testUnreadableFileIsArchivedBeforeNewStorageIsWritten() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data("{not-json".utf8).write(to: fixture.fileURL, options: .atomic)

        let storage = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        XCTAssertEqual(storage.eventCount(), 0)
        XCTAssertEqual(try unreadableBackups(in: fixture.directory).count, 1)

        storage.store(event: MGMEvent(name: "after_recovery"))
        XCTAssertEqual(storage.eventCount(), 1)
        let reloaded = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        XCTAssertEqual(reloaded.fetchEvents(limit: 10).map(\.name), ["after_recovery"])
    }

    func testTornTailIsArchivedAndNextAppendRemainsReadable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        var data = try JSONEncoder().encode(MGMEvent(name: "complete"))
        data.append(Character("\n").asciiValue!)
        data.append(Data("{\"name\":\"torn".utf8))
        try data.write(to: fixture.fileURL, options: .atomic)

        let storage = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        XCTAssertEqual(storage.fetchEvents(limit: 10).map(\.name), ["complete"])
        storage.store(event: MGMEvent(name: "after_torn_tail"))
        XCTAssertEqual(storage.eventCount(), 2)

        let reloaded = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        XCTAssertEqual(reloaded.fetchEvents(limit: 10).map(\.name), ["complete", "after_torn_tail"])
    }

    func testFailedAppendIsRepairedByNextStore() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var shouldFail = true

        let storage = FileEventStorage(
            maxEvents: 100,
            fileURL: fixture.fileURL,
            appendWriter: { data, url in
                if shouldFail {
                    shouldFail = false
                    throw TestError.appendFailed
                }
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            }
        )
        XCTAssertEqual(storage.eventCount(), 0)

        storage.store(event: MGMEvent(name: "failed_append"))
        XCTAssertEqual(storage.eventCount(), 1)
        storage.store(event: MGMEvent(name: "repairing_store"))
        XCTAssertEqual(storage.eventCount(), 2)

        let reloaded = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        XCTAssertEqual(reloaded.fetchEvents(limit: 10).map(\.name), ["failed_append", "repairing_store"])
    }

    func testTwoStoragesCanInterleaveAppendsBeforeCompaction() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let first = FileEventStorage(maxEvents: 500, fileURL: fixture.fileURL)
        let second = FileEventStorage(maxEvents: 500, fileURL: fixture.fileURL)
        XCTAssertEqual(first.eventCount(), 0)
        XCTAssertEqual(second.eventCount(), 0)

        for index in 0..<100 {
            first.store(event: MGMEvent(name: "first_\(index)"))
            second.store(event: MGMEvent(name: "second_\(index)"))
        }
        XCTAssertEqual(first.eventCount(), 100)
        XCTAssertEqual(second.eventCount(), 100)

        let reloaded = FileEventStorage(maxEvents: 500, fileURL: fixture.fileURL)
        let names = Set(reloaded.fetchEvents(limit: 500).map(\.name))
        XCTAssertEqual(names.count, 200)
    }

    func testSmallStoreCompactsAtCapWithoutDiskOvershoot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let storage = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)

        for index in 0..<101 {
            storage.store(event: MGMEvent(name: "event_\(index)"))
        }
        XCTAssertEqual(storage.eventCount(), 100)

        let lines = try Data(contentsOf: fixture.fileURL)
            .split(separator: Character("\n").asciiValue!)
        XCTAssertEqual(lines.count, 100)
    }

    func testLimitEvictionWarningIsRateLimited() throws {
        var warnings: [String] = []
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let storage = FileEventStorage(
            maxEvents: 100,
            fileURL: fixture.fileURL,
            warningHandler: { warnings.append($0) }
        )

        for index in 0..<105 {
            storage.store(event: MGMEvent(name: "event_\(index)"))
        }

        XCTAssertEqual(storage.eventCount(), 100)
        XCTAssertEqual(warnings.filter { $0.contains("configured storage limit") }.count, 1)
    }

    func testStorageDoesNotDropPropertiesAcceptedByTheEventModel() throws {
        let storage = InMemoryEventStorage()
        var properties = Dictionary(uniqueKeysWithValues: (0..<20).map {
            ("large_\($0)", String(repeating: "x", count: 1_000) as Any)
        })
        properties["deep"] = ["a": ["b": ["c": ["d": "kept"]]]]

        storage.store(event: MGMEvent(name: "large", properties: properties))
        let stored = try XCTUnwrap(storage.fetchEvents(limit: 1).first)

        XCTAssertEqual(stored.properties?.count, properties.count)
        XCTAssertNotNil(stored.properties?["deep"])
    }

    func testUnreadableArchivesAreBounded() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        for index in 0..<5 {
            try Data("{not-json-\(index)".utf8).write(to: fixture.fileURL, options: .atomic)
            let storage = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
            XCTAssertEqual(storage.eventCount(), 0)
        }

        XCTAssertEqual(try unreadableBackups(in: fixture.directory).count, 3)
    }

    func testOptOutDeletesUnreadableArchivesAndMigrationBackup() throws {
        let fixture = try makeFixture()
        defer {
            UserDefaults.standard.removeObject(forKey: "MGM_optedOut")
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        try Data("{not-json".utf8).write(to: fixture.fileURL, options: .atomic)

        let storage = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        XCTAssertEqual(storage.eventCount(), 0)
        let backupURL = fixture.fileURL.appendingPathExtension("pre-ndjson")
        try Data("legacy backup".utf8).write(to: backupURL, options: .atomic)
        XCTAssertEqual(try unreadableBackups(in: fixture.directory).count, 1)

        let client = MostlyGoodMetrics(
            configuration: MGMConfiguration(apiKey: "test"),
            storage: storage
        )
        client.optOut()
        XCTAssertEqual(storage.eventCount(), 0)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertTrue(try unreadableBackups(in: fixture.directory).isEmpty)
    }

    private func makeFixture() throws -> (directory: URL, fileURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgm-append-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("events.json"))
    }

    private func jsonObject(for event: MGMEvent) throws -> Any {
        let data = try JSONEncoder().encode(event)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func unreadableBackups(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("events.json.unreadable-") }
    }
}
