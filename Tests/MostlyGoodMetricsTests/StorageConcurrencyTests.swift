import XCTest
@testable import MostlyGoodMetrics

final class StorageConcurrencyTests: XCTestCase {
    private final class ContextBox {
        var value = "context-before"
    }

    private final class ControlledNetworkClient: NetworkClientProtocol {
        private let lock = NSLock()
        private var sendCompletion: ((Result<Void, MGMError>) -> Void)?
        var onSend: (() -> Void)?

        func sendEvents(
            _ events: [MGMEvent],
            context: MGMEventContext?,
            completion: @escaping (Result<Void, MGMError>) -> Void
        ) {
            lock.lock()
            sendCompletion = completion
            lock.unlock()
            onSend?()
        }

        func succeed() {
            lock.lock()
            let completion = sendCompletion
            sendCompletion = nil
            lock.unlock()
            completion?(.success(()))
        }

        func fetchExperiments(
            userId: String,
            anonymousId: String?,
            completion: @escaping (Result<[String: String], MGMError>) -> Void
        ) {
            completion(.success([:]))
        }

        func fetchExperimentConfigs(
            completion: @escaping (Result<[MGMExperimentConfig], MGMError>) -> Void
        ) {
            completion(.success([]))
        }
    }

    func testFileStoragePreservesAppendOrderAcrossReload() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let storage = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        storage.store(event: MGMEvent(name: "first"))
        storage.store(event: MGMEvent(name: "second"))
        storage.store(event: MGMEvent(name: "third"))
        XCTAssertEqual(storage.eventCount(), 3)

        let reloaded = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        let events = reloaded.fetchEvents(limit: 10)
        XCTAssertEqual(events.map(\.name), ["first", "second", "third"])
    }

    func testFileStorageMigratesLegacyJSONArrayWithoutLosingEvents() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let legacyEvents = [MGMEvent(name: "legacy_first"), MGMEvent(name: "legacy_second")]
        try JSONEncoder().encode(legacyEvents).write(to: fixture.fileURL, options: .atomic)

        let migrated = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        XCTAssertEqual(migrated.fetchEvents(limit: 10).map(\.name), ["legacy_first", "legacy_second"])

        let reloaded = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        XCTAssertEqual(reloaded.fetchEvents(limit: 10).map(\.name), ["legacy_first", "legacy_second"])
    }

    func testTrackCapturesTimestampIdentityAndPropertiesAtCallTime() {
        let context = ContextBox()
        let configuration = MGMConfiguration(
            apiKey: "test",
            contextProvider: { [context] in ["context": context.value] }
        )
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: configuration, storage: storage)
        client.userId = "user-before"
        client.setSuperProperty("super", value: "super-before")

        let earliestTimestamp = Date()
        client.track("captured", properties: ["event": "event-before"])
        let latestTimestamp = Date()

        context.value = "context-after"
        client.userId = "user-after"
        client.startNewSession()
        client.setSuperProperty("super", value: "super-after")

        let event = storage.fetchEvents(limit: 1).first
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.userId, "user-before")
        XCTAssertGreaterThanOrEqual(event?.timestamp ?? .distantPast, earliestTimestamp)
        XCTAssertLessThanOrEqual(event?.timestamp ?? .distantFuture, latestTimestamp)
        XCTAssertEqual(event?.properties?["context"]?.value as? String, "context-before")
        XCTAssertEqual(event?.properties?["super"]?.value as? String, "super-before")
        XCTAssertEqual(event?.properties?["event"]?.value as? String, "event-before")
    }

    func testSuccessfulFlushDoesNotRemoveEventAppendedWhileRequestIsInFlight() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let storage = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        storage.store(event: MGMEvent(name: "being_flushed"))
        XCTAssertEqual(storage.eventCount(), 1)

        let network = ControlledNetworkClient()
        let sent = expectation(description: "Initial batch sent")
        let completed = expectation(description: "Flush completed")
        network.onSend = { sent.fulfill() }
        let client = MostlyGoodMetrics(
            configuration: MGMConfiguration(apiKey: "test", maxBatchSize: 100),
            storage: storage,
            networkClient: network
        )

        client.flush { _ in completed.fulfill() }
        wait(for: [sent], timeout: 1)

        client.track("appended_during_flush")
        XCTAssertEqual(storage.eventCount(), 2)

        network.succeed()
        wait(for: [completed], timeout: 1)

        XCTAssertEqual(storage.fetchEvents(limit: 10).map(\.name), ["appended_during_flush"])

        let reloaded = FileEventStorage(maxEvents: 100, fileURL: fixture.fileURL)
        XCTAssertEqual(reloaded.fetchEvents(limit: 10).map(\.name), ["appended_during_flush"])
    }

    private func makeFixture() throws -> (directory: URL, fileURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgm-storage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("events.json"))
    }
}
