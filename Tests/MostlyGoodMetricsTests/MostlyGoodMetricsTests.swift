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
            enableDebugLogging: true
        )

        XCTAssertEqual(config.apiKey, "custom_key")
        XCTAssertEqual(config.baseURL, customURL)
        XCTAssertEqual(config.environment, "staging")
        XCTAssertEqual(config.bundleId, "com.test.app")
        XCTAssertEqual(config.maxBatchSize, 50)
        XCTAssertEqual(config.flushInterval, 60)
        XCTAssertEqual(config.maxStoredEvents, 5000)
        XCTAssertTrue(config.enableDebugLogging)
    }

    func testMaxBatchSizeClamping() {
        let config1 = MGMConfiguration(apiKey: "key", maxBatchSize: 2000)
        XCTAssertEqual(config1.maxBatchSize, 1000)

        let config2 = MGMConfiguration(apiKey: "key", maxBatchSize: 0)
        XCTAssertEqual(config2.maxBatchSize, 1)
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

    // MARK: - Client Tests

    func testClientInitialization() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        XCTAssertNotNil(client.sessionId)
        XCTAssertNil(client.userId)
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

    func testClientResetIdentity() {
        let config = MGMConfiguration(apiKey: "test_key")
        let client = MostlyGoodMetrics(configuration: config, storage: InMemoryEventStorage())

        client.identify(userId: "user123")
        XCTAssertEqual(client.userId, "user123")

        client.resetIdentity()
        XCTAssertNil(client.userId)
    }

    func testClientNewSession() {
        let config = MGMConfiguration(apiKey: "test_key")
        let client = MostlyGoodMetrics(configuration: config, storage: InMemoryEventStorage())

        let originalSessionId = client.sessionId
        client.startNewSession()

        XCTAssertNotEqual(client.sessionId, originalSessionId)
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

        let expectation = self.expectation(description: "Invalid events")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(storage.eventCount(), 0)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testValidEventNames() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        // These should be accepted
        client.track("valid_event")
        client.track("ValidEvent")
        client.track("event123")
        client.track("a")

        let expectation = self.expectation(description: "Valid events")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(storage.eventCount(), 4)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    // MARK: - Shared Instance Tests

    func testSharedInstanceConfiguration() {
        MostlyGoodMetrics.configure(apiKey: "shared_key")

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
}
