import XCTest
@testable import MostlyGoodMetrics

final class StorageConcurrencyTests: XCTestCase {
    private final class ContextBox {
        var value = "context-before"
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

    func testRemovingEventUsesClientEventId() {
        let storage = InMemoryEventStorage()
        let timestamp = Date()
        let flushed = MGMEvent(name: "duplicate", timestamp: timestamp)
        let pending = MGMEvent(name: "duplicate", timestamp: timestamp)

        storage.store(event: flushed)
        storage.store(event: pending)
        XCTAssertEqual(storage.eventCount(), 2)

        storage.removeEvents([flushed])

        let remaining = storage.fetchEvents(limit: 10)
        XCTAssertEqual(remaining.map(\.clientEventId), [pending.clientEventId])
    }
}
