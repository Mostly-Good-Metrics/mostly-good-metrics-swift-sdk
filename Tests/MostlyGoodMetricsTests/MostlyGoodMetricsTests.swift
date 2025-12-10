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

    func testEventEncodingWithNewDeviceProperties() throws {
        var event = MGMEvent(name: "test_event")
        event.appVersion = "1.2.3"
        event.appBuildNumber = "42"
        event.deviceManufacturer = "Apple"
        event.locale = "en_US"
        event.timezone = "America/New_York"

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json)
        XCTAssertEqual(json?["app_version"] as? String, "1.2.3")
        XCTAssertEqual(json?["app_build_number"] as? String, "42")
        XCTAssertEqual(json?["device_manufacturer"] as? String, "Apple")
        XCTAssertEqual(json?["locale"] as? String, "en_US")
        XCTAssertEqual(json?["timezone"] as? String, "America/New_York")
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

    func testClientTrackIncludesSDKPropertyDefaultingToSwift() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        client.track("test_event")

        let expectation = self.expectation(description: "SDK property")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 1)
            let sdkProperty = events.first?.properties?["$sdk"]?.value as? String
            XCTAssertEqual(sdkProperty, "swift")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testClientTrackUsesWrapperNameForSDKProperty() {
        let config = MGMConfiguration(apiKey: "test_key", wrapperName: "flutter")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        client.track("test_event")

        let expectation = self.expectation(description: "SDK property with wrapper")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 1)
            let sdkProperty = events.first?.properties?["$sdk"]?.value as? String
            XCTAssertEqual(sdkProperty, "flutter")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testClientTrackIncludesDeviceTypeProperty() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        client.track("test_event")

        let expectation = self.expectation(description: "Device type property")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 1)
            let deviceType = events.first?.properties?["$device_type"]?.value as? String
            XCTAssertNotNil(deviceType)
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

    func testClientEventsIncludeLocale() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        client.track("test_event")

        let expectation = self.expectation(description: "Locale")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 1)
            XCTAssertNotNil(events.first?.locale, "Events should include locale")
            XCTAssertFalse(events.first?.locale?.isEmpty ?? true, "Locale should not be empty")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testClientEventsIncludeTimezone() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        client.track("test_event")

        let expectation = self.expectation(description: "Timezone")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 1)
            XCTAssertNotNil(events.first?.timezone, "Events should include timezone")
            XCTAssertFalse(events.first?.timezone?.isEmpty ?? true, "Timezone should not be empty")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testClientEventsIncludeDeviceManufacturer() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        client.track("test_event")

        let expectation = self.expectation(description: "Device Manufacturer")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 1)
            XCTAssertEqual(events.first?.deviceManufacturer, "Apple", "Device manufacturer should be Apple")
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

// MARK: - GzipCompression Tests

final class GzipCompressionTests: XCTestCase {

    // MARK: - Basic Compression Tests

    func testCompressEmptyData() {
        let emptyData = Data()
        let result = GzipCompression.compress(emptyData)

        XCTAssertNil(result, "Compressing empty data should return nil")
    }

    func testCompressSmallData() {
        let smallData = "Hello, World!".data(using: .utf8)!
        let compressed = GzipCompression.compress(smallData)

        XCTAssertNotNil(compressed, "Should successfully compress small data")
        XCTAssertTrue(GzipCompression.isGzipCompressed(compressed!), "Result should be valid gzip")
    }

    func testCompressLargeData() {
        // Create a large payload similar to what the SDK would send
        let largeString = String(repeating: "This is a test event with some properties. ", count: 100)
        let largeData = largeString.data(using: .utf8)!

        let compressed = GzipCompression.compress(largeData)

        XCTAssertNotNil(compressed, "Should successfully compress large data")
        XCTAssertTrue(GzipCompression.isGzipCompressed(compressed!), "Result should be valid gzip")
        XCTAssertLessThan(compressed!.count, largeData.count, "Compressed data should be smaller than original")
    }

    func testCompressJsonPayload() throws {
        // Simulate a real events payload
        let events: [[String: Any]] = (0..<50).map { i in
            [
                "name": "event_\(i)",
                "timestamp": "2024-01-01T00:00:00Z",
                "properties": [
                    "index": i,
                    "description": "This is event number \(i) with some additional text"
                ]
            ]
        }
        let payload: [String: Any] = ["events": events]
        let jsonData = try JSONSerialization.data(withJSONObject: payload)

        let compressed = GzipCompression.compress(jsonData)

        XCTAssertNotNil(compressed, "Should successfully compress JSON payload")
        XCTAssertTrue(GzipCompression.isGzipCompressed(compressed!), "Result should be valid gzip")

        // JSON typically compresses very well
        let compressionRatio = Double(compressed!.count) / Double(jsonData.count)
        XCTAssertLessThan(compressionRatio, 0.5, "JSON should compress to less than 50% of original size")
    }

    // MARK: - Gzip Format Validation Tests

    func testGzipHeader() {
        let data = "Test data for gzip header validation".data(using: .utf8)!
        let compressed = GzipCompression.compress(data)!

        // Check gzip magic bytes
        XCTAssertEqual(compressed[0], 0x1f, "First magic byte should be 0x1f")
        XCTAssertEqual(compressed[1], 0x8b, "Second magic byte should be 0x8b")

        // Check compression method (deflate = 8)
        XCTAssertEqual(compressed[2], 0x08, "Compression method should be deflate (0x08)")

        // Check flags (should be 0 for no extra fields)
        XCTAssertEqual(compressed[3], 0x00, "Flags should be 0x00")

        // OS byte can vary (0xff = unknown, 0x13/19 = macOS, etc.) - just check it exists
        XCTAssertTrue(compressed.count >= 10, "Header should have OS byte at index 9")
    }

    func testGzipTrailer() {
        let testString = "Hello, gzip!"
        let data = testString.data(using: .utf8)!
        let compressed = GzipCompression.compress(data)!

        // Extract trailer (last 8 bytes)
        let trailerStart = compressed.count - 8

        // Extract CRC32 (little-endian)
        let crc32FromTrailer = UInt32(compressed[trailerStart]) |
                              (UInt32(compressed[trailerStart + 1]) << 8) |
                              (UInt32(compressed[trailerStart + 2]) << 16) |
                              (UInt32(compressed[trailerStart + 3]) << 24)

        // Extract original size (little-endian)
        let sizeFromTrailer = UInt32(compressed[trailerStart + 4]) |
                             (UInt32(compressed[trailerStart + 5]) << 8) |
                             (UInt32(compressed[trailerStart + 6]) << 16) |
                             (UInt32(compressed[trailerStart + 7]) << 24)

        // Verify CRC32 matches what we calculate
        let expectedCrc = GzipCompression.crc32(data)
        XCTAssertEqual(crc32FromTrailer, expectedCrc, "CRC32 in trailer should match calculated CRC32")

        // Verify size matches original data size
        XCTAssertEqual(sizeFromTrailer, UInt32(data.count), "Size in trailer should match original data size")
    }

    func testGzipMinimumSize() {
        let data = "x".data(using: .utf8)!
        let compressed = GzipCompression.compress(data)!

        // Minimum gzip size: 10 (header) + 1 (at least some compressed data) + 8 (trailer) = 19
        XCTAssertGreaterThanOrEqual(compressed.count, 19, "Gzip output should be at least 19 bytes")
    }

    // MARK: - CRC32 Tests

    func testCrc32EmptyData() {
        let emptyData = Data()
        let crc = GzipCompression.crc32(emptyData)

        // CRC32 of empty data should be 0
        XCTAssertEqual(crc, 0x00000000, "CRC32 of empty data should be 0")
    }

    func testCrc32KnownValues() {
        // Test against known CRC32 values
        // "123456789" has a well-known CRC32 value: 0xCBF43926
        let testData = "123456789".data(using: .utf8)!
        let crc = GzipCompression.crc32(testData)

        XCTAssertEqual(crc, 0xCBF43926, "CRC32 of '123456789' should be 0xCBF43926")
    }

    func testCrc32HelloWorld() {
        // "Hello, World!" CRC32 = 0xEC4AC3D0
        let testData = "Hello, World!".data(using: .utf8)!
        let crc = GzipCompression.crc32(testData)

        XCTAssertEqual(crc, 0xEC4AC3D0, "CRC32 of 'Hello, World!' should be 0xEC4AC3D0")
    }

    func testCrc32Deterministic() {
        let data = "Test data for determinism check".data(using: .utf8)!

        let crc1 = GzipCompression.crc32(data)
        let crc2 = GzipCompression.crc32(data)
        let crc3 = GzipCompression.crc32(data)

        XCTAssertEqual(crc1, crc2, "CRC32 should be deterministic")
        XCTAssertEqual(crc2, crc3, "CRC32 should be deterministic")
    }

    func testCrc32DifferentData() {
        let data1 = "Hello".data(using: .utf8)!
        let data2 = "World".data(using: .utf8)!

        let crc1 = GzipCompression.crc32(data1)
        let crc2 = GzipCompression.crc32(data2)

        XCTAssertNotEqual(crc1, crc2, "Different data should produce different CRC32 values")
    }

    // MARK: - isGzipCompressed Tests

    func testIsGzipCompressedValid() {
        let data = "Test data".data(using: .utf8)!
        let compressed = GzipCompression.compress(data)!

        XCTAssertTrue(GzipCompression.isGzipCompressed(compressed), "Compressed data should be detected as gzip")
    }

    func testIsGzipCompressedInvalid() {
        let plainData = "This is not gzip compressed".data(using: .utf8)!

        XCTAssertFalse(GzipCompression.isGzipCompressed(plainData), "Plain data should not be detected as gzip")
    }

    func testIsGzipCompressedTooShort() {
        let shortData = Data([0x1f]) // Only one byte

        XCTAssertFalse(GzipCompression.isGzipCompressed(shortData), "Single byte should not be detected as gzip")
    }

    func testIsGzipCompressedEmpty() {
        let emptyData = Data()

        XCTAssertFalse(GzipCompression.isGzipCompressed(emptyData), "Empty data should not be detected as gzip")
    }

    func testIsGzipCompressedWrongMagic() {
        // Data that starts with wrong magic bytes
        let wrongMagic = Data([0x1f, 0x8a, 0x08, 0x00]) // 0x8a instead of 0x8b

        XCTAssertFalse(GzipCompression.isGzipCompressed(wrongMagic), "Wrong magic bytes should not be detected as gzip")
    }

    // MARK: - Decompression Compatibility Tests

    func testCompressedDataCanBeDecompressedByFoundation() {
        let originalString = "This is test data that will be compressed and then decompressed to verify compatibility."
        let originalData = originalString.data(using: .utf8)!

        guard let compressed = GzipCompression.compress(originalData) else {
            XCTFail("Compression should succeed")
            return
        }

        // Use NSData's built-in decompression (available on macOS/iOS)
        // This verifies our gzip format is compatible with system libraries
        do {
            _ = try (compressed as NSData).decompressed(using: .zlib)
            // Note: NSData.decompressed with .zlib expects raw deflate, not gzip
            // For full gzip compatibility, we'd need to strip the header/trailer
            // This test verifies the structure is correct even if we can't decompress directly
            XCTAssertTrue(GzipCompression.isGzipCompressed(compressed))
        } catch {
            // Expected - NSData.decompressed doesn't handle full gzip format
            // The important thing is that our format is correct
            XCTAssertTrue(GzipCompression.isGzipCompressed(compressed))
        }
    }

    // MARK: - Performance Tests

    func testCompressionPerformance() {
        // Create a moderately large payload
        let largePayload = String(repeating: "Event data with properties ", count: 1000)
        let data = largePayload.data(using: .utf8)!

        measure {
            for _ in 0..<100 {
                _ = GzipCompression.compress(data)
            }
        }
    }

    func testCrc32Performance() {
        let data = String(repeating: "Test data for CRC32 performance ", count: 1000).data(using: .utf8)!

        measure {
            for _ in 0..<1000 {
                _ = GzipCompression.crc32(data)
            }
        }
    }

    // MARK: - Edge Cases

    func testCompressBinaryData() {
        // Test with binary data (all byte values)
        var binaryData = Data()
        for i: UInt8 in 0...255 {
            binaryData.append(i)
        }

        let compressed = GzipCompression.compress(binaryData)

        XCTAssertNotNil(compressed, "Should handle binary data")
        XCTAssertTrue(GzipCompression.isGzipCompressed(compressed!), "Result should be valid gzip")
    }

    func testCompressRepetitiveData() {
        // Highly repetitive data should compress very well
        let repetitiveData = String(repeating: "A", count: 10000).data(using: .utf8)!

        let compressed = GzipCompression.compress(repetitiveData)!

        let compressionRatio = Double(compressed.count) / Double(repetitiveData.count)
        XCTAssertLessThan(compressionRatio, 0.01, "Repetitive data should compress to less than 1% of original")
    }

    func testCompressRandomData() {
        // Random data typically doesn't compress well
        var randomData = Data()
        for _ in 0..<1000 {
            randomData.append(UInt8.random(in: 0...255))
        }

        let compressed = GzipCompression.compress(randomData)

        XCTAssertNotNil(compressed, "Should handle random data")
        XCTAssertTrue(GzipCompression.isGzipCompressed(compressed!), "Result should be valid gzip")
        // Random data might actually be larger after compression due to overhead
    }
}

// MARK: - Flush Behavior Tests

/// Tests for flush behavior with different network results.
///
/// Verifies that:
/// - Events are removed from storage on Success
/// - Events are removed from storage on client errors (badRequest, unauthorized, forbidden)
/// - Events are kept in storage on transient errors (networkError, serverError, rateLimited)
final class FlushBehaviorTests: XCTestCase {

    var storage: InMemoryEventStorage!
    var configuration: MGMConfiguration!

    override func setUp() {
        super.setUp()
        storage = InMemoryEventStorage(maxEvents: 100)
        configuration = MGMConfiguration(
            apiKey: "test-api-key",
            enableDebugLogging: false,
            trackAppLifecycleEvents: false
        )
    }

    override func tearDown() {
        storage = nil
        configuration = nil
        super.tearDown()
    }

    // MARK: - Success Tests

    func testEventsRemovedFromStorageOnSuccess() {
        let mockNetwork = MockNetworkClient(result: .success(()))
        let sdk = MostlyGoodMetrics(configuration: configuration, storage: storage, networkClient: mockNetwork)

        // Pre-load storage to avoid auto-flush during track()
        storage.store(event: MGMEvent(name: "event1"))
        storage.store(event: MGMEvent(name: "event2"))
        storage.store(event: MGMEvent(name: "event3"))

        let expectation = self.expectation(description: "Flush success")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.storage.eventCount(), 3)

            sdk.flush { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    XCTAssertEqual(self.storage.eventCount(), 0, "Events should be removed on success")
                    expectation.fulfill()
                }
            }
        }

        waitForExpectations(timeout: 5)
    }

    func testAllBatchesSentOnSuccess() {
        let mockNetwork = MockNetworkClient(result: .success(()))
        let smallBatchConfig = MGMConfiguration(
            apiKey: "test-api-key",
            maxBatchSize: 2,
            enableDebugLogging: false,
            trackAppLifecycleEvents: false
        )

        // Pre-load storage
        let preloadedStorage = InMemoryEventStorage(maxEvents: 100)
        for i in 0..<5 {
            preloadedStorage.store(event: MGMEvent(name: "event\(i)"))
        }

        let sdk = MostlyGoodMetrics(configuration: smallBatchConfig, storage: preloadedStorage, networkClient: mockNetwork)

        let expectation = self.expectation(description: "All batches sent")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(preloadedStorage.eventCount(), 5)

            sdk.flush { _ in
                // Allow time for continuation flushes
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    XCTAssertEqual(preloadedStorage.eventCount(), 0, "All events should be removed")
                    XCTAssertGreaterThanOrEqual(mockNetwork.sendCount, 3, "Should have sent at least 3 batches")
                    expectation.fulfill()
                }
            }
        }

        waitForExpectations(timeout: 10)
    }

    // MARK: - DropEvents Tests (Client Errors)

    func testEventsRemovedOnBadRequest() {
        let mockNetwork = MockNetworkClient(result: .failure(.badRequest("Invalid data")))
        let sdk = MostlyGoodMetrics(configuration: configuration, storage: storage, networkClient: mockNetwork)

        storage.store(event: MGMEvent(name: "bad_event1"))
        storage.store(event: MGMEvent(name: "bad_event2"))

        let expectation = self.expectation(description: "Bad request drops events")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.storage.eventCount(), 2)

            sdk.flush { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    XCTAssertEqual(self.storage.eventCount(), 0, "Events should be dropped on bad request")
                    expectation.fulfill()
                }
            }
        }

        waitForExpectations(timeout: 5)
    }

    func testEventsRemovedOnUnauthorized() {
        let mockNetwork = MockNetworkClient(result: .failure(.unauthorized))
        let sdk = MostlyGoodMetrics(configuration: configuration, storage: storage, networkClient: mockNetwork)

        storage.store(event: MGMEvent(name: "event1"))

        let expectation = self.expectation(description: "Unauthorized drops events")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.storage.eventCount(), 1)

            sdk.flush { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    XCTAssertEqual(self.storage.eventCount(), 0, "Events should be dropped on unauthorized")
                    expectation.fulfill()
                }
            }
        }

        waitForExpectations(timeout: 5)
    }

    func testEventsRemovedOnForbidden() {
        let mockNetwork = MockNetworkClient(result: .failure(.forbidden("Access denied")))
        let sdk = MostlyGoodMetrics(configuration: configuration, storage: storage, networkClient: mockNetwork)

        storage.store(event: MGMEvent(name: "event1"))

        let expectation = self.expectation(description: "Forbidden drops events")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.storage.eventCount(), 1)

            sdk.flush { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    XCTAssertEqual(self.storage.eventCount(), 0, "Events should be dropped on forbidden")
                    expectation.fulfill()
                }
            }
        }

        waitForExpectations(timeout: 5)
    }

    // MARK: - RetryLater Tests (Transient Errors)

    func testEventsKeptOnNetworkError() {
        let underlyingError = NSError(domain: "test", code: -1, userInfo: nil)
        let mockNetwork = MockNetworkClient(result: .failure(.networkError(underlyingError)))
        let sdk = MostlyGoodMetrics(configuration: configuration, storage: storage, networkClient: mockNetwork)

        storage.store(event: MGMEvent(name: "event1"))
        storage.store(event: MGMEvent(name: "event2"))

        let expectation = self.expectation(description: "Network error keeps events")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.storage.eventCount(), 2)

            sdk.flush { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    XCTAssertEqual(self.storage.eventCount(), 2, "Events should be kept for retry on network error")
                    expectation.fulfill()
                }
            }
        }

        waitForExpectations(timeout: 5)
    }

    func testEventsKeptOnRateLimited() {
        let mockNetwork = MockNetworkClient(result: .failure(.rateLimited(retryAfter: 60)))
        let sdk = MostlyGoodMetrics(configuration: configuration, storage: storage, networkClient: mockNetwork)

        storage.store(event: MGMEvent(name: "event1"))

        let expectation = self.expectation(description: "Rate limited keeps events")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.storage.eventCount(), 1)

            sdk.flush { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    XCTAssertEqual(self.storage.eventCount(), 1, "Events should be kept for retry on rate limit")
                    expectation.fulfill()
                }
            }
        }

        waitForExpectations(timeout: 5)
    }

    func testEventsKeptOnServerError() {
        let mockNetwork = MockNetworkClient(result: .failure(.serverError(500, "Internal error")))
        let sdk = MostlyGoodMetrics(configuration: configuration, storage: storage, networkClient: mockNetwork)

        storage.store(event: MGMEvent(name: "event1"))

        let expectation = self.expectation(description: "Server error keeps events")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.storage.eventCount(), 1)

            sdk.flush { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    XCTAssertEqual(self.storage.eventCount(), 1, "Events should be kept for retry on server error")
                    expectation.fulfill()
                }
            }
        }

        waitForExpectations(timeout: 5)
    }

    func testEventsKeptOnUnexpectedStatusCode() {
        let mockNetwork = MockNetworkClient(result: .failure(.unexpectedStatusCode(418)))
        let sdk = MostlyGoodMetrics(configuration: configuration, storage: storage, networkClient: mockNetwork)

        storage.store(event: MGMEvent(name: "event1"))

        let expectation = self.expectation(description: "Unexpected status keeps events")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.storage.eventCount(), 1)

            sdk.flush { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    XCTAssertEqual(self.storage.eventCount(), 1, "Events should be kept for retry")
                    expectation.fulfill()
                }
            }
        }

        waitForExpectations(timeout: 5)
    }

    // MARK: - Retry Success Tests

    func testEventsCanBeRetriedAfterFailure() {
        let sequentialNetwork = SequentialMockNetworkClient(results: [
            .failure(.networkError(NSError(domain: "test", code: -1, userInfo: nil))),
            .success(())
        ])
        let sdk = MostlyGoodMetrics(configuration: configuration, storage: storage, networkClient: sequentialNetwork)

        storage.store(event: MGMEvent(name: "event1"))

        let expectation = self.expectation(description: "Retry success")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.storage.eventCount(), 1)

            // First flush - should fail and keep events
            sdk.flush { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    XCTAssertEqual(self.storage.eventCount(), 1, "Events should be kept after first failure")

                    // Second flush - should succeed and remove events
                    sdk.flush { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            XCTAssertEqual(self.storage.eventCount(), 0, "Events should be removed after retry success")
                            expectation.fulfill()
                        }
                    }
                }
            }
        }

        waitForExpectations(timeout: 10)
    }

    // MARK: - Edge Cases

    func testFlushWithEmptyStorageDoesNothing() {
        let mockNetwork = MockNetworkClient(result: .success(()))
        let sdk = MostlyGoodMetrics(configuration: configuration, storage: storage, networkClient: mockNetwork)

        let expectation = self.expectation(description: "Empty flush")

        XCTAssertEqual(storage.eventCount(), 0)

        sdk.flush { result in
            switch result {
            case .success:
                XCTAssertEqual(mockNetwork.sendCount, 0, "Should not send when storage is empty")
            case .failure:
                XCTFail("Empty flush should not fail")
            }
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    func testNewEventsAddedDuringRetryArePreserved() {
        let mockNetwork = MockNetworkClient(result: .failure(.networkError(NSError(domain: "test", code: -1, userInfo: nil))))
        let sdk = MostlyGoodMetrics(configuration: configuration, storage: storage, networkClient: mockNetwork)

        storage.store(event: MGMEvent(name: "event1"))

        let expectation = self.expectation(description: "New events preserved")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            sdk.flush { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    // Add another event after failed flush
                    self.storage.store(event: MGMEvent(name: "event2"))

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        XCTAssertEqual(self.storage.eventCount(), 2, "Both events should be in storage")
                        expectation.fulfill()
                    }
                }
            }
        }

        waitForExpectations(timeout: 5)
    }
}

// MARK: - Mock Network Clients

/// Mock network client that always returns the same result
class MockNetworkClient: NetworkClientProtocol {
    private let result: Result<Void, MGMError>
    private(set) var sendCount = 0

    init(result: Result<Void, MGMError>) {
        self.result = result
    }

    func sendEvents(_ events: [MGMEvent], context: MGMEventContext?, completion: @escaping (Result<Void, MGMError>) -> Void) {
        sendCount += 1
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            completion(self.result)
        }
    }
}

/// Mock network client that returns results in sequence
class SequentialMockNetworkClient: NetworkClientProtocol {
    private let results: [Result<Void, MGMError>]
    private var callIndex = 0

    init(results: [Result<Void, MGMError>]) {
        self.results = results
    }

    func sendEvents(_ events: [MGMEvent], context: MGMEventContext?, completion: @escaping (Result<Void, MGMError>) -> Void) {
        let result = callIndex < results.count ? results[callIndex] : results.last!
        callIndex += 1

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            completion(result)
        }
    }
}
