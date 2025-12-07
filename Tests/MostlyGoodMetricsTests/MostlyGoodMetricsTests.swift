import XCTest
@testable import MostlyGoodMetrics

final class MostlyGoodMetricsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear persisted user ID before each test
        UserDefaults.standard.removeObject(forKey: "MGM_userId")
    }

    override func tearDown() {
        super.tearDown()
        // Clean up shared instance
        MostlyGoodMetrics.shared?.clearPendingEvents()
        UserDefaults.standard.removeObject(forKey: "MGM_userId")
    }

    // MARK: - Configuration Tests

    func testConfigurationDefaults() {
        let config = MGMConfiguration(apiKey: "test_key")

        XCTAssertEqual(config.apiKey, "test_key")
        XCTAssertEqual(config.baseURL, MGMConfiguration.defaultBaseURL)
        XCTAssertEqual(config.environment, "production")
        XCTAssertNil(config.bundleId)
        XCTAssertEqual(config.maxBatchSize, 100)
        XCTAssertEqual(config.flushInterval, 30)
        XCTAssertEqual(config.maxStoredEvents, 10000)
        XCTAssertFalse(config.enableDebugLogging)
        XCTAssertTrue(config.trackAppLifecycleEvents)
    }

    func testConfigurationCustomValues() {
        let customURL = URL(string: "https://custom.api.com")!
        let config = MGMConfiguration(
            apiKey: "custom_key",
            baseURL: customURL,
            environment: "staging",
            bundleId: "com.test.app",
            maxBatchSize: 50,
            flushInterval: 60,
            maxStoredEvents: 5000,
            enableDebugLogging: true,
            trackAppLifecycleEvents: false
        )

        XCTAssertEqual(config.apiKey, "custom_key")
        XCTAssertEqual(config.baseURL, customURL)
        XCTAssertEqual(config.environment, "staging")
        XCTAssertEqual(config.bundleId, "com.test.app")
        XCTAssertEqual(config.maxBatchSize, 50)
        XCTAssertEqual(config.flushInterval, 60)
        XCTAssertEqual(config.maxStoredEvents, 5000)
        XCTAssertTrue(config.enableDebugLogging)
        XCTAssertFalse(config.trackAppLifecycleEvents)
    }

    func testMaxBatchSizeClamping() {
        let config1 = MGMConfiguration(apiKey: "key", maxBatchSize: 2000)
        XCTAssertEqual(config1.maxBatchSize, 1000)

        let config2 = MGMConfiguration(apiKey: "key", maxBatchSize: 0)
        XCTAssertEqual(config2.maxBatchSize, 1)

        let config3 = MGMConfiguration(apiKey: "key", maxBatchSize: -10)
        XCTAssertEqual(config3.maxBatchSize, 1)
    }

    func testFlushIntervalMinimum() {
        let config1 = MGMConfiguration(apiKey: "key", flushInterval: 0)
        XCTAssertEqual(config1.flushInterval, 1)

        let config2 = MGMConfiguration(apiKey: "key", flushInterval: -10)
        XCTAssertEqual(config2.flushInterval, 1)

        let config3 = MGMConfiguration(apiKey: "key", flushInterval: 120)
        XCTAssertEqual(config3.flushInterval, 120)
    }

    func testMaxStoredEventsMinimum() {
        let config1 = MGMConfiguration(apiKey: "key", maxStoredEvents: 50)
        XCTAssertEqual(config1.maxStoredEvents, 100)

        let config2 = MGMConfiguration(apiKey: "key", maxStoredEvents: 0)
        XCTAssertEqual(config2.maxStoredEvents, 100)

        let config3 = MGMConfiguration(apiKey: "key", maxStoredEvents: 5000)
        XCTAssertEqual(config3.maxStoredEvents, 5000)
    }

    // MARK: - Event Tests

    func testEventCreation() {
        let event = MGMEvent(name: "test_event")

        XCTAssertEqual(event.name, "test_event")
        XCTAssertNotNil(event.timestamp)
        XCTAssertNil(event.userId)
        XCTAssertNil(event.properties)
    }

    func testEventWithProperties() {
        let properties: [String: Any] = [
            "key": "value",
            "number": 42,
            "boolean": true
        ]
        let event = MGMEvent(name: "test_event", properties: properties)

        XCTAssertEqual(event.name, "test_event")
        XCTAssertNotNil(event.properties)
        XCTAssertEqual(event.properties?.count, 3)
    }

    func testEventEncoding() throws {
        var event = MGMEvent(name: "app_opened", properties: ["screen": "home"])
        event.userId = "user123"
        event.sessionId = "session456"
        event.platform = "ios"
        event.appVersion = "1.0.0"
        event.osVersion = "17.0"
        event.environment = "production"

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json)
        XCTAssertEqual(json?["name"] as? String, "app_opened")
        XCTAssertEqual(json?["user_id"] as? String, "user123")
        XCTAssertEqual(json?["session_id"] as? String, "session456")
        XCTAssertEqual(json?["platform"] as? String, "ios")
        XCTAssertEqual(json?["app_version"] as? String, "1.0.0")
        XCTAssertEqual(json?["os_version"] as? String, "17.0")
        XCTAssertEqual(json?["environment"] as? String, "production")
        XCTAssertNotNil(json?["timestamp"])
    }

    func testEventTimestampFormat() throws {
        let event = MGMEvent(name: "test")

        // Timestamp should be a valid date
        XCTAssertNotNil(event.timestamp)

        // When encoded, should be ISO 8601 format with Z suffix
        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let timestampStr = json?["timestamp"] as? String

        XCTAssertNotNil(timestampStr)
        XCTAssertTrue(timestampStr!.contains("T"))
        XCTAssertTrue(timestampStr!.hasSuffix("Z"))
    }

    func testEventPropertiesWithNestedObjects() throws {
        let properties: [String: Any] = [
            "user": [
                "name": "John",
                "age": 30
            ]
        ]
        let event = MGMEvent(name: "test", properties: properties)

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let props = json?["properties"] as? [String: Any]
        let user = props?["user"] as? [String: Any]

        XCTAssertNotNil(user)
        XCTAssertEqual(user?["name"] as? String, "John")
        XCTAssertEqual(user?["age"] as? Int, 30)
    }

    func testEventPropertiesWithArrays() throws {
        let properties: [String: Any] = [
            "tags": ["a", "b", "c"]
        ]
        let event = MGMEvent(name: "test", properties: properties)

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let props = json?["properties"] as? [String: Any]
        let tags = props?["tags"] as? [String]

        XCTAssertNotNil(tags)
        XCTAssertEqual(tags, ["a", "b", "c"])
    }

    // MARK: - Event Name Validation Tests

    func testValidEventNames() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        // These should be accepted
        client.track("valid_event")
        client.track("ValidEvent")
        client.track("event123")
        client.track("a")
        client.track("$app_opened")  // System event
        client.track("$custom_system")

        let expectation = self.expectation(description: "Valid events")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(storage.eventCount(), 6)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testInvalidEventNameRejected() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        // These should be rejected
        client.track("123invalid") // starts with number
        client.track("invalid-name") // contains hyphen
        client.track("") // empty
        client.track(String(repeating: "a", count: 300)) // too long
        client.track("event name") // contains space
        client.track("event.name") // contains dot

        let expectation = self.expectation(description: "Invalid events")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(storage.eventCount(), 0)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    // MARK: - Storage Tests

    func testInMemoryStorage() {
        let storage = InMemoryEventStorage(maxEvents: 100)

        XCTAssertEqual(storage.eventCount(), 0)

        let event = MGMEvent(name: "test_event")
        storage.store(event: event)

        // Wait for async operation
        let expectation = self.expectation(description: "Storage")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(storage.eventCount(), 1)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testStorageFetchesEventsInOrder() {
        let storage = InMemoryEventStorage(maxEvents: 100)

        storage.store(event: MGMEvent(name: "event_1"))
        storage.store(event: MGMEvent(name: "event_2"))
        storage.store(event: MGMEvent(name: "event_3"))

        let expectation = self.expectation(description: "Storage order")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 10)
            XCTAssertEqual(events.count, 3)
            XCTAssertEqual(events[0].name, "event_1")
            XCTAssertEqual(events[1].name, "event_2")
            XCTAssertEqual(events[2].name, "event_3")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testStorageFetchLimit() {
        let storage = InMemoryEventStorage(maxEvents: 100)

        for i in 0..<10 {
            storage.store(event: MGMEvent(name: "event_\(i)"))
        }

        let expectation = self.expectation(description: "Storage fetch limit")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 5)
            XCTAssertEqual(events.count, 5)
            XCTAssertEqual(events[0].name, "event_0")
            XCTAssertEqual(events[4].name, "event_4")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testStorageRemoveEvents() {
        let storage = InMemoryEventStorage(maxEvents: 100)

        let event1 = MGMEvent(name: "event_1")
        let event2 = MGMEvent(name: "event_2")
        let event3 = MGMEvent(name: "event_3")

        storage.store(event: event1)
        storage.store(event: event2)
        storage.store(event: event3)

        let expectation = self.expectation(description: "Storage remove")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            storage.removeEvents([event1, event2])

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                XCTAssertEqual(storage.eventCount(), 1)
                let remaining = storage.fetchEvents(limit: 10)
                XCTAssertEqual(remaining.first?.name, "event_3")
                expectation.fulfill()
            }
        }
        waitForExpectations(timeout: 1)
    }

    func testStorageMaxEvents() {
        let storage = InMemoryEventStorage(maxEvents: 5)

        // Add 10 events
        for i in 0..<10 {
            storage.store(event: MGMEvent(name: "event_\(i)"))
        }

        // Wait for async operations
        let expectation = self.expectation(description: "Storage max")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(storage.eventCount(), 5)

            // Should have the last 5 events
            let events = storage.fetchEvents(limit: 10)
            XCTAssertEqual(events.first?.name, "event_5")
            XCTAssertEqual(events.last?.name, "event_9")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testStorageClear() {
        let storage = InMemoryEventStorage()
        storage.store(event: MGMEvent(name: "test"))

        let expectation = self.expectation(description: "Storage clear")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            storage.clear()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                XCTAssertEqual(storage.eventCount(), 0)
                expectation.fulfill()
            }
        }
        waitForExpectations(timeout: 1)
    }

    func testStorageThreadSafety() {
        let storage = InMemoryEventStorage(maxEvents: 1000)
        let group = DispatchGroup()

        // Add events from multiple threads concurrently
        for threadId in 0..<10 {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<100 {
                    storage.store(event: MGMEvent(name: "thread\(threadId)_event\(i)"))
                }
                group.leave()
            }
        }

        let expectation = self.expectation(description: "Thread safety")
        group.notify(queue: .main) {
            // All 1000 events should be stored
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                XCTAssertEqual(storage.eventCount(), 1000)
                expectation.fulfill()
            }
        }
        waitForExpectations(timeout: 5)
    }

    // MARK: - Client Tests

    func testClientInitialization() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        XCTAssertNotNil(client.sessionId)
        XCTAssertNil(client.userId)
        XCTAssertFalse(client.sessionId.isEmpty)
    }

    func testClientTrack() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        client.track("test_event", properties: ["key": "value"])

        let expectation = self.expectation(description: "Track")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(storage.eventCount(), 1)

            let events = storage.fetchEvents(limit: 1)
            XCTAssertEqual(events.first?.name, "test_event")
            XCTAssertEqual(events.first?.sessionId, client.sessionId)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testClientTrackWithoutProperties() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        client.track("simple_event")

        let expectation = self.expectation(description: "Track simple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(storage.eventCount(), 1)
            let events = storage.fetchEvents(limit: 1)
            XCTAssertEqual(events.first?.name, "simple_event")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testClientIdentify() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        client.identify(userId: "user123")
        XCTAssertEqual(client.userId, "user123")

        client.track("test_event")

        let expectation = self.expectation(description: "Identify")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 1)
            XCTAssertEqual(events.first?.userId, "user123")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testClientIdentifyPersistsToUserDefaults() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        client.identify(userId: "persistent_user")

        let storedUserId = UserDefaults.standard.string(forKey: "MGM_userId")
        XCTAssertEqual(storedUserId, "persistent_user")
    }

    func testClientResetIdentity() {
        let config = MGMConfiguration(apiKey: "test_key")
        let client = MostlyGoodMetrics(configuration: config, storage: InMemoryEventStorage())

        client.identify(userId: "user123")
        XCTAssertEqual(client.userId, "user123")

        client.resetIdentity()
        XCTAssertNil(client.userId)

        let storedUserId = UserDefaults.standard.string(forKey: "MGM_userId")
        XCTAssertNil(storedUserId)
    }

    func testClientNewSession() {
        let config = MGMConfiguration(apiKey: "test_key")
        let client = MostlyGoodMetrics(configuration: config, storage: InMemoryEventStorage())

        let originalSessionId = client.sessionId
        client.startNewSession()

        XCTAssertNotEqual(client.sessionId, originalSessionId)
        XCTAssertFalse(client.sessionId.isEmpty)
    }

    func testClientPendingEventCount() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        XCTAssertEqual(client.pendingEventCount, 0)

        client.track("event1")
        client.track("event2")

        let expectation = self.expectation(description: "Pending count")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(client.pendingEventCount, 2)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testClientClearPendingEvents() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        client.track("event1")
        client.track("event2")

        let expectation = self.expectation(description: "Clear pending")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(client.pendingEventCount, 2)

            client.clearPendingEvents()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                XCTAssertEqual(client.pendingEventCount, 0)
                expectation.fulfill()
            }
        }
        waitForExpectations(timeout: 1)
    }

    func testClientEventsIncludeSessionId() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        client.track("test_event")

        let expectation = self.expectation(description: "Session ID")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 1)
            XCTAssertEqual(events.first?.sessionId, client.sessionId)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testClientEventsIncludePlatform() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        client.track("test_event")

        let expectation = self.expectation(description: "Platform")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 1)
            XCTAssertNotNil(events.first?.platform)
            // Platform should be one of: ios, macos, tvos, watchos, visionos
            let validPlatforms = ["ios", "macos", "tvos", "watchos", "visionos", "unknown"]
            XCTAssertTrue(validPlatforms.contains(events.first?.platform ?? ""))
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testClientEventsIncludeEnvironment() {
        let config = MGMConfiguration(apiKey: "test_key", environment: "staging")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        client.track("test_event")

        let expectation = self.expectation(description: "Environment")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 1)
            XCTAssertEqual(events.first?.environment, "staging")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    // MARK: - Shared Instance Tests

    func testSharedInstanceConfiguration() {
        MostlyGoodMetrics.configure(apiKey: "shared_key")

        XCTAssertNotNil(MostlyGoodMetrics.shared)
    }

    func testSharedInstanceConfigureWithConfiguration() {
        let config = MGMConfiguration(apiKey: "custom_key", environment: "test")
        MostlyGoodMetrics.configure(with: config)

        XCTAssertNotNil(MostlyGoodMetrics.shared)
    }

    func testStaticTrack() {
        MostlyGoodMetrics.configure(apiKey: "test_key")

        MostlyGoodMetrics.track("static_event")

        let expectation = self.expectation(description: "Static track")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertGreaterThan(MostlyGoodMetrics.shared?.pendingEventCount ?? 0, 0)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testStaticTrackWithProperties() {
        MostlyGoodMetrics.configure(apiKey: "test_key")

        MostlyGoodMetrics.track("static_event", properties: ["key": "value"])

        let expectation = self.expectation(description: "Static track with props")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertGreaterThan(MostlyGoodMetrics.shared?.pendingEventCount ?? 0, 0)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testStaticIdentify() {
        MostlyGoodMetrics.configure(apiKey: "test_key")

        MostlyGoodMetrics.identify(userId: "static_user")

        XCTAssertEqual(MostlyGoodMetrics.shared?.userId, "static_user")
    }

    func testStaticFlush() {
        MostlyGoodMetrics.configure(apiKey: "test_key")
        MostlyGoodMetrics.track("event")

        // Should not throw
        MostlyGoodMetrics.flush()
    }

    // MARK: - Flush Tests

    func testFlushWithCompletion() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        let expectation = self.expectation(description: "Flush completion")

        client.flush { result in
            // Should complete (even without events)
            switch result {
            case .success:
                expectation.fulfill()
            case .failure:
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 5)
    }

    func testFlushWithNoEvents() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        let expectation = self.expectation(description: "Flush no events")

        client.flush { result in
            switch result {
            case .success:
                // Should succeed with no events
                expectation.fulfill()
            case .failure:
                XCTFail("Should not fail with no events")
            }
        }

        waitForExpectations(timeout: 5)
    }
}

// MARK: - AnyCodable Tests

final class AnyCodableTests: XCTestCase {

    func testEncodePrimitives() throws {
        let encoder = JSONEncoder()

        let stringCodable = AnyCodable("test")
        let intCodable = AnyCodable(42)
        let doubleCodable = AnyCodable(3.14)
        let boolCodable = AnyCodable(true)

        let stringData = try encoder.encode(stringCodable)
        let intData = try encoder.encode(intCodable)
        let doubleData = try encoder.encode(doubleCodable)
        let boolData = try encoder.encode(boolCodable)

        XCTAssertEqual(String(data: stringData, encoding: .utf8), "\"test\"")
        XCTAssertEqual(String(data: intData, encoding: .utf8), "42")
        XCTAssertEqual(String(data: doubleData, encoding: .utf8), "3.14")
        XCTAssertEqual(String(data: boolData, encoding: .utf8), "true")
    }

    func testEncodeArray() throws {
        let encoder = JSONEncoder()
        let arrayCodable = AnyCodable([1, 2, 3])

        let data = try encoder.encode(arrayCodable)
        let json = String(data: data, encoding: .utf8)

        XCTAssertEqual(json, "[1,2,3]")
    }

    func testEncodeDictionary() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let dictCodable = AnyCodable(["a": 1, "b": 2])

        let data = try encoder.encode(dictCodable)
        let json = String(data: data, encoding: .utf8)

        XCTAssertEqual(json, "{\"a\":1,\"b\":2}")
    }

    func testStringTruncation() throws {
        let encoder = JSONEncoder()
        let longString = String(repeating: "a", count: 2000)
        let codable = AnyCodable(longString)

        let data = try encoder.encode(codable)
        let decoded = String(data: data, encoding: .utf8)!

        // Should be truncated to 1000 chars + quotes
        XCTAssertEqual(decoded.count, 1002)
    }

    func testEncodeNestedDictionary() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let nested: [String: Any] = [
            "user": [
                "name": "John",
                "age": 30
            ] as [String: Any]
        ]
        let codable = AnyCodable(nested)

        let data = try encoder.encode(codable)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json)
        let user = json?["user"] as? [String: Any]
        XCTAssertEqual(user?["name"] as? String, "John")
        XCTAssertEqual(user?["age"] as? Int, 30)
    }

    func testEncodeNil() throws {
        let encoder = JSONEncoder()
        let nilCodable = AnyCodable(NSNull())

        let data = try encoder.encode(nilCodable)
        let json = String(data: data, encoding: .utf8)

        XCTAssertEqual(json, "null")
    }
}

// MARK: - MGMError Tests

final class MGMErrorTests: XCTestCase {

    func testNetworkErrorDescription() {
        let underlyingError = NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connection failed"])
        let error = MGMError.networkError(underlyingError)

        XCTAssertTrue(error.localizedDescription.contains("Network error"))
    }

    func testUnauthorizedErrorDescription() {
        let error = MGMError.unauthorized

        XCTAssertTrue(error.localizedDescription.contains("Invalid") || error.localizedDescription.contains("API key"))
    }

    func testRateLimitedErrorDescription() {
        let error = MGMError.rateLimited(retryAfter: 60)

        XCTAssertTrue(error.localizedDescription.contains("Rate limited"))
        XCTAssertTrue(error.localizedDescription.contains("60"))
    }

    func testServerErrorDescription() {
        let error = MGMError.serverError(500, "Internal server error")

        XCTAssertTrue(error.localizedDescription.contains("500"))
        XCTAssertTrue(error.localizedDescription.contains("Internal server error"))
    }

    func testBadRequestErrorDescription() {
        let error = MGMError.badRequest("Invalid event format")

        XCTAssertTrue(error.localizedDescription.contains("Bad request"))
        XCTAssertTrue(error.localizedDescription.contains("Invalid event format"))
    }

    func testInvalidEventNameErrorDescription() {
        let error = MGMError.invalidEventName("123invalid")

        XCTAssertTrue(error.localizedDescription.contains("Invalid event name"))
        XCTAssertTrue(error.localizedDescription.contains("123invalid"))
    }
}
