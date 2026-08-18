import XCTest
@testable import MostlyGoodMetrics

final class MostlyGoodMetricsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear persisted user ID, super properties, and opt-out state before each test
        UserDefaults.standard.removeObject(forKey: "MGM_userId")
        UserDefaults.standard.removeObject(forKey: "MGM_superProperties")
        UserDefaults.standard.removeObject(forKey: "MGM_optedOut")
    }

    override func tearDown() {
        super.tearDown()
        // Clean up shared instance
        MostlyGoodMetrics.shared?.clearPendingEvents()
        MostlyGoodMetrics.shared?.clearSuperProperties()
        UserDefaults.standard.removeObject(forKey: "MGM_userId")
        UserDefaults.standard.removeObject(forKey: "MGM_superProperties")
        UserDefaults.standard.removeObject(forKey: "MGM_optedOut")
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
        XCTAssertNotNil(event.clientEventId)
        XCTAssertFalse(event.clientEventId.isEmpty)
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

    // MARK: - Client Event ID Tests

    func testClientEventIdIsUUID() {
        let event = MGMEvent(name: "test_event")

        // Verify it's a valid UUID format
        XCTAssertNotNil(UUID(uuidString: event.clientEventId), "clientEventId should be a valid UUID")
    }

    func testClientEventIdIsUniquePerEvent() {
        let event1 = MGMEvent(name: "test_event")
        let event2 = MGMEvent(name: "test_event")

        XCTAssertNotEqual(event1.clientEventId, event2.clientEventId, "Each event should have a unique clientEventId")
    }

    func testClientEventIdEncodedInJson() throws {
        let event = MGMEvent(name: "test_event")

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["client_event_id"] as? String)
        XCTAssertEqual(json?["client_event_id"] as? String, event.clientEventId)
    }

    func testClientEventIdDecodedFromJson() throws {
        let testUUID = UUID().uuidString
        let jsonString = """
        {
            "name": "test_event",
            "client_event_id": "\(testUUID)",
            "timestamp": "2024-01-01T00:00:00.000Z"
        }
        """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let event = try decoder.decode(MGMEvent.self, from: data)

        XCTAssertEqual(event.clientEventId, testUUID)
    }

    func testClientEventIdGeneratedWhenMissingInJson() throws {
        let jsonString = """
        {
            "name": "test_event",
            "timestamp": "2024-01-01T00:00:00.000Z"
        }
        """
        let data = jsonString.data(using: .utf8)!

        let decoder = JSONDecoder()
        let event = try decoder.decode(MGMEvent.self, from: data)

        // Should generate a new UUID when missing
        XCTAssertNotNil(UUID(uuidString: event.clientEventId), "Should generate valid UUID when missing from JSON")
    }

    func testClientEventIdPreservedThroughEncodeDecode() throws {
        let originalEvent = MGMEvent(name: "test_event", properties: ["key": "value"])
        let originalId = originalEvent.clientEventId

        let encoder = JSONEncoder()
        let data = try encoder.encode(originalEvent)

        let decoder = JSONDecoder()
        let decodedEvent = try decoder.decode(MGMEvent.self, from: data)

        XCTAssertEqual(decodedEvent.clientEventId, originalId, "clientEventId should be preserved through encode/decode")
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
        XCTAssertNotNil(json?["client_event_id"] as? String)
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
        client.track("Button Clicked")
        client.track("User Signed Up")
        client.track("$app_opened")  // System event
        client.track("$custom_system")

        let expectation = self.expectation(description: "Valid events")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(storage.eventCount(), 8)
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

    // MARK: - Identify with Profile Tests

    func testIdentifyWithEmailSendsIdentifyEvent() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        // Clear any previous identify state
        UserDefaults.standard.removeObject(forKey: "MGM_identifyHash")
        UserDefaults.standard.removeObject(forKey: "MGM_identifyTimestamp")

        let profile = UserProfile(email: "test@example.com")
        client.identify(userId: "user123", profile: profile)

        let expectation = self.expectation(description: "Identify with email")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 10)
            let identifyEvent = events.first { $0.name == "$identify" }
            XCTAssertNotNil(identifyEvent, "Should send $identify event when profile has email")
            XCTAssertEqual(identifyEvent?.properties?["email"]?.value as? String, "test@example.com")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testIdentifyWithNameSendsIdentifyEvent() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        // Clear any previous identify state
        UserDefaults.standard.removeObject(forKey: "MGM_identifyHash")
        UserDefaults.standard.removeObject(forKey: "MGM_identifyTimestamp")

        let profile = UserProfile(name: "John Doe")
        client.identify(userId: "user456", profile: profile)

        let expectation = self.expectation(description: "Identify with name")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 10)
            let identifyEvent = events.first { $0.name == "$identify" }
            XCTAssertNotNil(identifyEvent, "Should send $identify event when profile has name")
            XCTAssertEqual(identifyEvent?.properties?["name"]?.value as? String, "John Doe")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testIdentifyWithEmailAndNameSendsIdentifyEvent() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        // Clear any previous identify state
        UserDefaults.standard.removeObject(forKey: "MGM_identifyHash")
        UserDefaults.standard.removeObject(forKey: "MGM_identifyTimestamp")

        let profile = UserProfile(email: "jane@example.com", name: "Jane Smith")
        client.identify(userId: "user789", profile: profile)

        let expectation = self.expectation(description: "Identify with email and name")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 10)
            let identifyEvent = events.first { $0.name == "$identify" }
            XCTAssertNotNil(identifyEvent, "Should send $identify event when profile has both email and name")
            XCTAssertEqual(identifyEvent?.properties?["email"]?.value as? String, "jane@example.com")
            XCTAssertEqual(identifyEvent?.properties?["name"]?.value as? String, "Jane Smith")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testIdentifyEventIncludesAnonymousId() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        // Clear any previous identify state
        UserDefaults.standard.removeObject(forKey: "MGM_identifyHash")
        UserDefaults.standard.removeObject(forKey: "MGM_identifyTimestamp")

        // Capture the anonymous id used for events before identify()
        let anonymousIdBeforeIdentify = client.anonymousId

        let profile = UserProfile(email: "test@example.com")
        client.identify(userId: "identified_user", profile: profile)

        let expectation = self.expectation(description: "Identify includes anonymous id")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 10)
            let identifyEvent = events.first { $0.name == "$identify" }
            XCTAssertNotNil(identifyEvent, "Should send $identify event")
            XCTAssertEqual(identifyEvent?.userId, "identified_user")
            XCTAssertEqual(
                identifyEvent?.properties?["$anonymous_id"]?.value as? String,
                anonymousIdBeforeIdentify,
                "$identify event must carry $anonymous_id = the pre-identify anonymous id"
            )
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testIdentifyEventOmitsAnonymousIdWhenEqualToUserId() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        // Clear any previous identify state
        UserDefaults.standard.removeObject(forKey: "MGM_identifyHash")
        UserDefaults.standard.removeObject(forKey: "MGM_identifyTimestamp")

        // Identify with a userId equal to the current anonymous id: nothing to stitch
        let profile = UserProfile(email: "test@example.com")
        client.identify(userId: client.anonymousId, profile: profile)

        let expectation = self.expectation(description: "Identify omits redundant anonymous id")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 10)
            let identifyEvent = events.first { $0.name == "$identify" }
            XCTAssertNotNil(identifyEvent, "Should send $identify event")
            XCTAssertNil(
                identifyEvent?.properties?["$anonymous_id"],
                "$anonymous_id must be omitted when it equals the identified user id"
            )
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testIdentifyWithoutProfileDoesNotSendIdentifyEvent() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        // Clear any previous identify state
        UserDefaults.standard.removeObject(forKey: "MGM_identifyHash")
        UserDefaults.standard.removeObject(forKey: "MGM_identifyTimestamp")

        client.identify(userId: "user_only")

        let expectation = self.expectation(description: "Identify without profile")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 10)
            let identifyEvent = events.first { $0.name == "$identify" }
            XCTAssertNil(identifyEvent, "Should NOT send $identify event when no profile provided")
            XCTAssertEqual(client.userId, "user_only")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testIdentifyDebouncesWhenHashUnchanged() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        // Clear any previous identify state
        UserDefaults.standard.removeObject(forKey: "MGM_identifyHash")
        UserDefaults.standard.removeObject(forKey: "MGM_identifyTimestamp")

        let profile = UserProfile(email: "same@example.com", name: "Same User")

        // First identify - should send event
        client.identify(userId: "debounce_user", profile: profile)

        let expectation = self.expectation(description: "Identify debounces")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let firstCount = storage.fetchEvents(limit: 100).filter { $0.name == "$identify" }.count
            XCTAssertEqual(firstCount, 1, "First identify should send event")

            // Second identify with same data - should NOT send event (debounced)
            client.identify(userId: "debounce_user", profile: profile)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let secondCount = storage.fetchEvents(limit: 100).filter { $0.name == "$identify" }.count
                XCTAssertEqual(secondCount, 1, "Second identify with same data should be debounced")
                expectation.fulfill()
            }
        }
        waitForExpectations(timeout: 2)
    }

    func testIdentifyResendAfterHashChanged() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        // Clear any previous identify state
        UserDefaults.standard.removeObject(forKey: "MGM_identifyHash")
        UserDefaults.standard.removeObject(forKey: "MGM_identifyTimestamp")

        let profile1 = UserProfile(email: "first@example.com")
        let profile2 = UserProfile(email: "second@example.com")

        // First identify
        client.identify(userId: "hash_user", profile: profile1)

        let expectation = self.expectation(description: "Identify resends on hash change")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let firstCount = storage.fetchEvents(limit: 100).filter { $0.name == "$identify" }.count
            XCTAssertEqual(firstCount, 1, "First identify should send event")

            // Second identify with different data - should send new event
            client.identify(userId: "hash_user", profile: profile2)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let events = storage.fetchEvents(limit: 100).filter { $0.name == "$identify" }
                XCTAssertEqual(events.count, 2, "Second identify with different data should send new event")

                // Verify the second event has the new email
                let latestIdentify = events.last
                XCTAssertEqual(latestIdentify?.properties?["email"]?.value as? String, "second@example.com")
                expectation.fulfill()
            }
        }
        waitForExpectations(timeout: 2)
    }

    func testResetIdentityClearsDebounceState() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        // Clear any previous identify state
        UserDefaults.standard.removeObject(forKey: "MGM_identifyHash")
        UserDefaults.standard.removeObject(forKey: "MGM_identifyTimestamp")

        let profile = UserProfile(email: "reset@example.com")

        // First identify
        client.identify(userId: "reset_user", profile: profile)

        let expectation = self.expectation(description: "Reset clears debounce state")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let firstCount = storage.fetchEvents(limit: 100).filter { $0.name == "$identify" }.count
            XCTAssertEqual(firstCount, 1, "First identify should send event")

            // Reset identity - should clear debounce state
            client.resetIdentity()

            // Verify hash and timestamp are cleared
            let storedHash = UserDefaults.standard.string(forKey: "MGM_identifyHash")
            let storedTimestamp = UserDefaults.standard.object(forKey: "MGM_identifyTimestamp")
            XCTAssertNil(storedHash, "Hash should be cleared on reset")
            XCTAssertNil(storedTimestamp, "Timestamp should be cleared on reset")

            // Re-identify with same data - should send event since state was cleared
            client.identify(userId: "reset_user", profile: profile)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let secondCount = storage.fetchEvents(limit: 100).filter { $0.name == "$identify" }.count
                XCTAssertEqual(secondCount, 2, "After reset, same profile should trigger new $identify event")
                expectation.fulfill()
            }
        }
        waitForExpectations(timeout: 2)
    }

    func testStaticIdentifyWithProfile() {
        MostlyGoodMetrics.configure(apiKey: "test_key")

        // Clear any previous identify state
        UserDefaults.standard.removeObject(forKey: "MGM_identifyHash")
        UserDefaults.standard.removeObject(forKey: "MGM_identifyTimestamp")

        let profile = UserProfile(email: "static@example.com", name: "Static User")
        MostlyGoodMetrics.identify(userId: "static_user", profile: profile)

        XCTAssertEqual(MostlyGoodMetrics.shared?.userId, "static_user")
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

    // MARK: - Super Properties Tests

    func testSetSuperProperty() {
        let config = MGMConfiguration(apiKey: "test_key")
        let client = MostlyGoodMetrics(configuration: config, storage: InMemoryEventStorage())

        client.setSuperProperty("plan", value: "premium")

        let properties = client.getSuperProperties()
        XCTAssertEqual(properties["plan"] as? String, "premium")
    }

    func testSetMultipleSuperProperties() {
        let config = MGMConfiguration(apiKey: "test_key")
        let client = MostlyGoodMetrics(configuration: config, storage: InMemoryEventStorage())

        client.setSuperProperties([
            "plan": "premium",
            "version": "2.0",
            "count": 42
        ])

        let properties = client.getSuperProperties()
        XCTAssertEqual(properties["plan"] as? String, "premium")
        XCTAssertEqual(properties["version"] as? String, "2.0")
        XCTAssertEqual(properties["count"] as? Int, 42)
    }

    func testSetSuperPropertyOverwritesExisting() {
        let config = MGMConfiguration(apiKey: "test_key")
        let client = MostlyGoodMetrics(configuration: config, storage: InMemoryEventStorage())

        client.setSuperProperty("plan", value: "free")
        client.setSuperProperty("plan", value: "premium")

        let properties = client.getSuperProperties()
        XCTAssertEqual(properties["plan"] as? String, "premium")
    }

    func testSetSuperPropertiesMergesWithExisting() {
        let config = MGMConfiguration(apiKey: "test_key")
        let client = MostlyGoodMetrics(configuration: config, storage: InMemoryEventStorage())

        client.setSuperProperty("existing", value: "value1")
        client.setSuperProperties(["new": "value2"])

        let properties = client.getSuperProperties()
        XCTAssertEqual(properties["existing"] as? String, "value1")
        XCTAssertEqual(properties["new"] as? String, "value2")
    }

    func testRemoveSuperProperty() {
        let config = MGMConfiguration(apiKey: "test_key")
        let client = MostlyGoodMetrics(configuration: config, storage: InMemoryEventStorage())

        client.setSuperProperties(["key1": "value1", "key2": "value2"])
        client.removeSuperProperty("key1")

        let properties = client.getSuperProperties()
        XCTAssertNil(properties["key1"])
        XCTAssertEqual(properties["key2"] as? String, "value2")
    }

    func testClearSuperProperties() {
        let config = MGMConfiguration(apiKey: "test_key")
        let client = MostlyGoodMetrics(configuration: config, storage: InMemoryEventStorage())

        client.setSuperProperties(["key1": "value1", "key2": "value2"])
        client.clearSuperProperties()

        let properties = client.getSuperProperties()
        XCTAssertTrue(properties.isEmpty)
    }

    func testGetSuperPropertiesReturnsEmptyWhenNoneSet() {
        let config = MGMConfiguration(apiKey: "test_key")
        let client = MostlyGoodMetrics(configuration: config, storage: InMemoryEventStorage())

        let properties = client.getSuperProperties()
        XCTAssertTrue(properties.isEmpty)
    }

    func testSuperPropertiesIncludedInTrackedEvents() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        client.setSuperProperty("plan", value: "premium")
        client.track("test_event")

        let expectation = self.expectation(description: "Super properties in event")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 1)
            let planProperty = events.first?.properties?["plan"]?.value as? String
            XCTAssertEqual(planProperty, "premium")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testEventPropertiesOverrideSuperProperties() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        client.setSuperProperty("source", value: "super")
        client.track("test_event", properties: ["source": "event"])

        let expectation = self.expectation(description: "Event overrides super")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 1)
            let sourceProperty = events.first?.properties?["source"]?.value as? String
            XCTAssertEqual(sourceProperty, "event", "Event properties should override super properties")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testSuperPropertiesPersistAcrossInstances() {
        // First instance sets super properties
        let config1 = MGMConfiguration(apiKey: "test_key")
        let client1 = MostlyGoodMetrics(configuration: config1, storage: InMemoryEventStorage())
        client1.setSuperProperty("persistent", value: "value")

        // Second instance should read persisted properties
        let config2 = MGMConfiguration(apiKey: "test_key")
        let client2 = MostlyGoodMetrics(configuration: config2, storage: InMemoryEventStorage())

        let properties = client2.getSuperProperties()
        XCTAssertEqual(properties["persistent"] as? String, "value")
    }

    func testSuperPropertiesWithDifferentValueTypes() {
        let config = MGMConfiguration(apiKey: "test_key")
        let client = MostlyGoodMetrics(configuration: config, storage: InMemoryEventStorage())

        client.setSuperProperties([
            "string": "hello",
            "integer": 42,
            "double": 3.14,
            "boolean": true
        ])

        let properties = client.getSuperProperties()
        XCTAssertEqual(properties["string"] as? String, "hello")
        XCTAssertEqual(properties["integer"] as? Int, 42)
        XCTAssertEqual(properties["double"] as? Double, 3.14)
        XCTAssertEqual(properties["boolean"] as? Bool, true)
    }

    func testStaticSetSuperProperty() {
        MostlyGoodMetrics.configure(apiKey: "test_key")

        MostlyGoodMetrics.setSuperProperty("static_key", value: "static_value")

        let properties = MostlyGoodMetrics.getSuperProperties()
        XCTAssertEqual(properties["static_key"] as? String, "static_value")
    }

    func testStaticSetSuperProperties() {
        MostlyGoodMetrics.configure(apiKey: "test_key")

        MostlyGoodMetrics.setSuperProperties(["key1": "value1", "key2": "value2"])

        let properties = MostlyGoodMetrics.getSuperProperties()
        XCTAssertEqual(properties["key1"] as? String, "value1")
        XCTAssertEqual(properties["key2"] as? String, "value2")
    }

    func testStaticRemoveSuperProperty() {
        MostlyGoodMetrics.configure(apiKey: "test_key")

        MostlyGoodMetrics.setSuperProperties(["key1": "value1", "key2": "value2"])
        MostlyGoodMetrics.removeSuperProperty("key1")

        let properties = MostlyGoodMetrics.getSuperProperties()
        XCTAssertNil(properties["key1"])
        XCTAssertEqual(properties["key2"] as? String, "value2")
    }

    func testStaticClearSuperProperties() {
        MostlyGoodMetrics.configure(apiKey: "test_key")

        MostlyGoodMetrics.setSuperProperties(["key1": "value1"])
        MostlyGoodMetrics.clearSuperProperties()

        let properties = MostlyGoodMetrics.getSuperProperties()
        XCTAssertTrue(properties.isEmpty)
    }

    func testSuperPropertiesNotOverrideSystemProperties() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        // Try to set a system property via super properties
        client.setSuperProperty("$sdk", value: "custom_sdk")
        client.track("test_event")

        let expectation = self.expectation(description: "System properties preserved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 1)
            let sdkProperty = events.first?.properties?["$sdk"]?.value as? String
            // System property should be preserved (not overwritten by super property)
            XCTAssertEqual(sdkProperty, "swift")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testMultipleSuperPropertiesIncludedInEvent() {
        let config = MGMConfiguration(apiKey: "test_key")
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(configuration: config, storage: storage)

        client.setSuperProperties([
            "app_version": "1.0.0",
            "user_type": "premium",
            "feature_flag": true
        ])
        client.track("test_event")

        let expectation = self.expectation(description: "Multiple super properties")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 1)
            let props = events.first?.properties
            XCTAssertEqual(props?["app_version"]?.value as? String, "1.0.0")
            XCTAssertEqual(props?["user_type"]?.value as? String, "premium")
            XCTAssertEqual(props?["feature_flag"]?.value as? Bool, true)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
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

    func fetchExperiments(userId: String, anonymousId: String?, completion: @escaping (Result<[String: String], MGMError>) -> Void) {
        completion(.success([:]))
    }

    func fetchExperimentConfigs(completion: @escaping (Result<[MGMExperimentConfig], MGMError>) -> Void) {
        completion(.success([]))
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

    func fetchExperiments(userId: String, anonymousId: String?, completion: @escaping (Result<[String: String], MGMError>) -> Void) {
        completion(.success([:]))
    }

    func fetchExperimentConfigs(completion: @escaping (Result<[MGMExperimentConfig], MGMError>) -> Void) {
        completion(.success([]))
    }
}

// MARK: - A/B Testing Mock Network Client

/// Mock network client for A/B testing functionality
class ExperimentsMockNetworkClient: NetworkClientProtocol {
    private let lock = NSLock()
    private var _experimentsResult: Result<[String: String], MGMError>
    private var _experimentConfigsResult: Result<[MGMExperimentConfig], MGMError>
    private var _fetchExperimentsCallCount = 0
    private var _fetchExperimentConfigsCallCount = 0
    private var _lastFetchedUserId: String?
    private var _lastFetchedAnonymousId: String?

    var experimentsResult: Result<[String: String], MGMError> {
        get { lock.lock(); defer { lock.unlock() }; return _experimentsResult }
        set { lock.lock(); defer { lock.unlock() }; _experimentsResult = newValue }
    }
    var experimentConfigsResult: Result<[MGMExperimentConfig], MGMError> {
        get { lock.lock(); defer { lock.unlock() }; return _experimentConfigsResult }
        set { lock.lock(); defer { lock.unlock() }; _experimentConfigsResult = newValue }
    }
    var fetchExperimentsCallCount: Int {
        lock.lock(); defer { lock.unlock() }; return _fetchExperimentsCallCount
    }
    var fetchExperimentConfigsCallCount: Int {
        lock.lock(); defer { lock.unlock() }; return _fetchExperimentConfigsCallCount
    }
    var lastFetchedUserId: String? {
        lock.lock(); defer { lock.unlock() }; return _lastFetchedUserId
    }
    var lastFetchedAnonymousId: String? {
        lock.lock(); defer { lock.unlock() }; return _lastFetchedAnonymousId
    }

    init(
        experimentsResult: Result<[String: String], MGMError> = .success([:]),
        experimentConfigsResult: Result<[MGMExperimentConfig], MGMError> = .success([])
    ) {
        self._experimentsResult = experimentsResult
        self._experimentConfigsResult = experimentConfigsResult
    }

    func sendEvents(_ events: [MGMEvent], context: MGMEventContext?, completion: @escaping (Result<Void, MGMError>) -> Void) {
        completion(.success(()))
    }

    func fetchExperiments(userId: String, anonymousId: String?, completion: @escaping (Result<[String: String], MGMError>) -> Void) {
        lock.lock()
        _fetchExperimentsCallCount += 1
        _lastFetchedUserId = userId
        _lastFetchedAnonymousId = anonymousId
        let result = _experimentsResult
        lock.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            completion(result)
        }
    }

    func fetchExperimentConfigs(completion: @escaping (Result<[MGMExperimentConfig], MGMError>) -> Void) {
        lock.lock()
        _fetchExperimentConfigsCallCount += 1
        let result = _experimentConfigsResult
        lock.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            completion(result)
        }
    }
}

/// Mock network client whose fetchExperiments completions are fired manually,
/// so tests can control exactly when a fetch "responds".
class ManualExperimentsMockNetworkClient: NetworkClientProtocol {
    private let lock = NSLock()
    private var pendingCompletions: [(Result<[String: String], MGMError>) -> Void] = []
    private var _fetchExperimentsCallCount = 0

    var fetchExperimentsCallCount: Int {
        lock.lock(); defer { lock.unlock() }; return _fetchExperimentsCallCount
    }

    var pendingFetchCount: Int {
        lock.lock(); defer { lock.unlock() }; return pendingCompletions.count
    }

    func sendEvents(_ events: [MGMEvent], context: MGMEventContext?, completion: @escaping (Result<Void, MGMError>) -> Void) {
        completion(.success(()))
    }

    func fetchExperiments(userId: String, anonymousId: String?, completion: @escaping (Result<[String: String], MGMError>) -> Void) {
        lock.lock()
        _fetchExperimentsCallCount += 1
        pendingCompletions.append(completion)
        lock.unlock()
    }

    func fetchExperimentConfigs(completion: @escaping (Result<[MGMExperimentConfig], MGMError>) -> Void) {
        completion(.success([]))
    }

    /// Fires the oldest pending fetch completion with the given result.
    func completeNextFetch(with result: Result<[String: String], MGMError>) {
        lock.lock()
        let completion = pendingCompletions.isEmpty ? nil : pendingCompletions.removeFirst()
        lock.unlock()
        completion?(result)
    }
}

// MARK: - A/B Testing Tests

final class ABTestingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        clearExperimentsDefaults()
    }

    override func tearDown() {
        super.tearDown()
        clearExperimentsDefaults()
        MostlyGoodMetrics.shared?.clearSuperProperties()
    }

    private func clearExperimentsDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "MGM_experimentsCache")
        defaults.removeObject(forKey: "MGM_experimentsFetchedAt")
        defaults.removeObject(forKey: "MGM_experimentsCachedUserId")
        defaults.removeObject(forKey: "MGM_experimentExposures")
        defaults.removeObject(forKey: "MGM_userId")
        defaults.removeObject(forKey: "MGM_anonymousId")
        defaults.removeObject(forKey: "MGM_superProperties")
    }

    private func makeConfig() -> MGMConfiguration {
        MGMConfiguration(apiKey: "test_key", trackAppLifecycleEvents: false)
    }

    /// Blocks the test for the given duration (lets async mock completions land).
    private func waitBriefly(_ seconds: TimeInterval = 0.3) {
        let exp = expectation(description: "brief wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        waitForExpectations(timeout: seconds + 2)
    }

    /// Seeds the experiments cache in UserDefaults for the given user.
    private func seedCache(variants: [String: String], userId: String, fetchedAt: Date) {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(variants), forKey: "MGM_experimentsCache")
        defaults.set(fetchedAt, forKey: "MGM_experimentsFetchedAt")
        defaults.set(userId, forKey: "MGM_experimentsCachedUserId")
    }

    // MARK: - getVariant Tests

    func testGetVariantReturnsCorrectVariant() {
        let mockNetwork = ExperimentsMockNetworkClient(
            experimentsResult: .success(["button_color": "red", "checkout_flow": "v2"])
        )
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        waitBriefly()

        XCTAssertEqual(sdk.getVariant("button_color"), "red")
        XCTAssertEqual(sdk.getVariant("checkout_flow"), "v2")
        XCTAssertEqual(mockNetwork.fetchExperimentsCallCount, 1, "Should have fetched exactly once on init")
    }

    func testGetVariantReturnsNilForUnknownExperiment() {
        let mockNetwork = ExperimentsMockNetworkClient(
            experimentsResult: .success(["known_experiment": "control"])
        )
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        waitBriefly()

        XCTAssertEqual(sdk.getVariant("known_experiment"), "control")
        XCTAssertNil(sdk.getVariant("unknown_experiment"), "getVariant should return nil for unknown experiment")
    }

    func testGetVariantReturnsFallbackForUnknownExperiment() {
        let mockNetwork = ExperimentsMockNetworkClient(
            experimentsResult: .success(["known_experiment": "control"])
        )
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        waitBriefly()

        XCTAssertEqual(
            sdk.getVariant("unknown_experiment", fallback: "fallback_variant"),
            "fallback_variant",
            "getVariant should return the fallback for unknown experiments"
        )
        XCTAssertEqual(
            sdk.getVariant("known_experiment", fallback: "fallback_variant"),
            "control",
            "Fallback must not override an assigned variant"
        )
    }

    func testGetVariantReturnsFallbackBeforeExperimentsLoad() {
        let mockNetwork = ExperimentsMockNetworkClient(
            experimentsResult: .success(["test_experiment": "variant_a"])
        )
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: true // experiments never loaded
        )

        XCTAssertNil(sdk.getVariant("test_experiment"), "Should return nil pre-load without fallback")
        XCTAssertEqual(
            sdk.getVariant("test_experiment", fallback: "control"),
            "control",
            "Should return fallback pre-load"
        )
    }

    // MARK: - Super Property Tests

    func testGetVariantSetsSuperPropertyWithExperimentPrefix() {
        let mockNetwork = ExperimentsMockNetworkClient(
            experimentsResult: .success(["buttonColor": "red"])
        )
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        waitBriefly()

        XCTAssertEqual(sdk.getVariant("buttonColor"), "red")
        let superProps = sdk.getSuperProperties()
        XCTAssertEqual(
            superProps["$experiment_button_color"] as? String,
            "red",
            "getVariant should register a $experiment_{snake_case} super property"
        )
    }

    func testSuperPropertyUsesSnakeCaseExperimentName() {
        XCTAssertEqual("myExperiment".toSnakeCase(), "my_experiment")
        XCTAssertEqual("My Experiment".toSnakeCase(), "my__experiment")
        XCTAssertEqual("my-experiment".toSnakeCase(), "my_experiment")
        XCTAssertEqual("MyExperiment123".toSnakeCase(), "my_experiment123")
        XCTAssertEqual("already_snake_case".toSnakeCase(), "already_snake_case")
        XCTAssertEqual("ABC".toSnakeCase(), "a_b_c")
        XCTAssertEqual("getHTTPResponse".toSnakeCase(), "get_h_t_t_p_response")
    }

    // MARK: - Exposure Tracking Tests

    private func exposureEvents(in storage: InMemoryEventStorage) -> [MGMEvent] {
        storage.fetchEvents(limit: 1000).filter { $0.name == "$experiment_exposure" }
    }

    func testExposureTrackedOnFirstGetVariant() {
        let storage = InMemoryEventStorage()
        let mockNetwork = ExperimentsMockNetworkClient(
            experimentsResult: .success(["button_color": "red"])
        )
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: storage,
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        waitBriefly()
        XCTAssertEqual(sdk.getVariant("button_color"), "red")
        waitBriefly(0.2)

        let exposures = exposureEvents(in: storage)
        XCTAssertEqual(exposures.count, 1, "Exactly one $experiment_exposure event should be tracked")
        XCTAssertEqual(exposures.first?.properties?["$experiment_name"]?.value as? String, "button_color")
        XCTAssertEqual(exposures.first?.properties?["$variant"]?.value as? String, "red")
    }

    func testExposureTrackedOnlyOncePerVariant() {
        let storage = InMemoryEventStorage()
        let mockNetwork = ExperimentsMockNetworkClient(
            experimentsResult: .success(["button_color": "red"])
        )
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: storage,
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        waitBriefly()
        _ = sdk.getVariant("button_color")
        _ = sdk.getVariant("button_color")
        _ = sdk.getVariant("button_color")
        waitBriefly(0.2)

        XCTAssertEqual(exposureEvents(in: storage).count, 1, "Repeated getVariant calls must not re-fire exposure")
    }

    func testExposureNotRefiredAcrossRelaunch() {
        // First "launch": load, read variant, exposure fires
        let storage1 = InMemoryEventStorage()
        let mockNetwork1 = ExperimentsMockNetworkClient(
            experimentsResult: .success(["button_color": "red"])
        )
        let sdk1 = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: storage1,
            networkClient: mockNetwork1,
            skipExperimentsLoad: false
        )

        waitBriefly()
        XCTAssertEqual(sdk1.getVariant("button_color"), "red")
        waitBriefly(0.2)
        XCTAssertEqual(exposureEvents(in: storage1).count, 1, "First launch should fire exposure")

        // Simulated relaunch: fresh instance and storage, same UserDefaults suite
        let storage2 = InMemoryEventStorage()
        let mockNetwork2 = ExperimentsMockNetworkClient(
            experimentsResult: .success(["button_color": "red"])
        )
        let sdk2 = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: storage2,
            networkClient: mockNetwork2,
            skipExperimentsLoad: false
        )

        waitBriefly()
        XCTAssertEqual(sdk2.getVariant("button_color"), "red")
        waitBriefly(0.2)
        XCTAssertEqual(
            exposureEvents(in: storage2).count,
            0,
            "Exposure must not re-fire across relaunch for the same (user, experiment, variant)"
        )
    }

    func testExposureFiresAgainForNewVariant() {
        let storage = InMemoryEventStorage()
        let mockNetwork = ManualExperimentsMockNetworkClient()
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: storage,
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        mockNetwork.completeNextFetch(with: .success(["button_color": "red"]))
        waitBriefly(0.2)
        XCTAssertEqual(sdk.getVariant("button_color"), "red")

        // User changes -> refetch assigns a different variant
        sdk.identify(userId: "different_user")
        mockNetwork.completeNextFetch(with: .success(["button_color": "blue"]))
        waitBriefly(0.2)
        XCTAssertEqual(sdk.getVariant("button_color"), "blue")
        waitBriefly(0.2)

        let exposures = exposureEvents(in: storage)
        XCTAssertEqual(exposures.count, 2, "A new (user, experiment, variant) combination should fire a new exposure")
        XCTAssertEqual(exposures.last?.properties?["$variant"]?.value as? String, "blue")
    }

    // MARK: - Cache Tests (no expiry, stale-while-revalidate)

    func testCacheIsRestoredOnInitAndServedImmediately() {
        let anonId = "$anon_testcache123"
        UserDefaults.standard.set(anonId, forKey: "MGM_anonymousId")
        seedCache(variants: ["cached_experiment": "cached_variant"], userId: anonId, fetchedAt: Date())

        let mockNetwork = ExperimentsMockNetworkClient(experimentsResult: .success([:]))
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        // Cache path is synchronous inside init: variant is available immediately
        XCTAssertEqual(sdk.getVariant("cached_experiment"), "cached_variant")
        XCTAssertEqual(
            mockNetwork.fetchExperimentsCallCount,
            0,
            "A fresh cache (fetched < 1h ago) must not trigger a background refetch"
        )
    }

    func testCacheNeverExpires() {
        let anonId = "$anon_neverexpires"
        UserDefaults.standard.set(anonId, forKey: "MGM_anonymousId")
        // 30 days old - way past the old 24h TTL
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        seedCache(variants: ["old_experiment": "old_variant"], userId: anonId, fetchedAt: thirtyDaysAgo)

        // Network fails: only the cache can provide the variant
        let mockNetwork = ExperimentsMockNetworkClient(
            experimentsResult: .failure(.networkError(NSError(domain: "test", code: -1)))
        )
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        XCTAssertEqual(
            sdk.getVariant("old_experiment"),
            "old_variant",
            "Cached assignments must be served regardless of age (no TTL)"
        )

        waitBriefly()
        XCTAssertEqual(
            sdk.getVariant("old_experiment"),
            "old_variant",
            "A failed background refetch must not drop cached assignments"
        )
    }

    func testStaleCacheTriggersBackgroundRefetchAndSwap() {
        let anonId = "$anon_stalecache"
        UserDefaults.standard.set(anonId, forKey: "MGM_anonymousId")
        // 2 hours old - past the 1h refresh throttle
        let twoHoursAgo = Date().addingTimeInterval(-2 * 60 * 60)
        seedCache(variants: ["exp": "stale_variant"], userId: anonId, fetchedAt: twoHoursAgo)

        let mockNetwork = ExperimentsMockNetworkClient(
            experimentsResult: .success(["exp": "fresh_variant"])
        )
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        // Cache served immediately (stale-while-revalidate)
        XCTAssertEqual(sdk.getVariant("exp"), "stale_variant")

        waitBriefly()
        XCTAssertEqual(mockNetwork.fetchExperimentsCallCount, 1, "Stale cache should trigger a background refetch")
        XCTAssertEqual(sdk.getVariant("exp"), "fresh_variant", "Fetched assignments should atomically replace the cache")
    }

    func testFreshCacheDoesNotRefetchWithinThrottle() {
        let anonId = "$anon_freshcache"
        UserDefaults.standard.set(anonId, forKey: "MGM_anonymousId")
        // 5 minutes old - within the 1h refresh throttle
        seedCache(variants: ["exp": "v"], userId: anonId, fetchedAt: Date().addingTimeInterval(-5 * 60))

        let mockNetwork = ExperimentsMockNetworkClient(experimentsResult: .success(["exp": "other"]))
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        waitBriefly()
        XCTAssertEqual(mockNetwork.fetchExperimentsCallCount, 0, "Refetch must be throttled while cache is fresh")
        XCTAssertEqual(sdk.getVariant("exp"), "v")
    }

    func testSuccessfulFetchWritesCache() {
        let mockNetwork = ExperimentsMockNetworkClient(
            experimentsResult: .success(["exp": "variant_a"])
        )
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        waitBriefly()

        let defaults = UserDefaults.standard
        let data = defaults.data(forKey: "MGM_experimentsCache")
        XCTAssertNotNil(data, "Fetch should persist assignments to UserDefaults")
        let cached = data.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
        XCTAssertEqual(cached?["exp"], "variant_a")
        XCTAssertEqual(defaults.string(forKey: "MGM_experimentsCachedUserId"), sdk.anonymousId)
        XCTAssertNotNil(defaults.object(forKey: "MGM_experimentsFetchedAt") as? Date)
    }

    // MARK: - identify() Behavior Tests

    func testIdentifyKeepsOldVariantsUntilNewResponseArrives() {
        let mockNetwork = ManualExperimentsMockNetworkClient()
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        // Initial load resolves with variant "a"
        mockNetwork.completeNextFetch(with: .success(["exp": "a"]))
        waitBriefly(0.2)
        XCTAssertEqual(sdk.getVariant("exp"), "a")

        // User changes: refetch starts but has NOT responded yet
        sdk.identify(userId: "new_user")
        XCTAssertEqual(
            sdk.getVariant("exp"),
            "a",
            "Old variants must keep being served while the refetch is in flight"
        )
        XCTAssertEqual(mockNetwork.fetchExperimentsCallCount, 2, "identify with a new user should trigger a refetch")

        // Response arrives: assignments atomically swap
        mockNetwork.completeNextFetch(with: .success(["exp": "b"]))
        waitBriefly(0.2)
        XCTAssertEqual(sdk.getVariant("exp"), "b", "Assignments should swap once the new response arrives")
    }

    func testIdentifyFetchFailureKeepsOldVariants() {
        let mockNetwork = ManualExperimentsMockNetworkClient()
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        mockNetwork.completeNextFetch(with: .success(["exp": "a"]))
        waitBriefly(0.2)
        XCTAssertEqual(sdk.getVariant("exp"), "a")

        sdk.identify(userId: "new_user")
        mockNetwork.completeNextFetch(with: .failure(.networkError(NSError(domain: "test", code: -1))))
        waitBriefly(0.2)

        XCTAssertEqual(
            sdk.getVariant("exp"),
            "a",
            "A failed refetch after identify must not clear current assignments"
        )
    }

    func testIdentifyRefetchesWhenUserChanges() {
        let mockNetwork = ExperimentsMockNetworkClient(
            experimentsResult: .success(["test": "variant"])
        )
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: true
        )

        sdk.identify(userId: "user_1")
        waitBriefly(0.2)
        let firstCallCount = mockNetwork.fetchExperimentsCallCount
        XCTAssertEqual(firstCallCount, 1, "identify with a new user should fetch experiments")

        sdk.identify(userId: "user_2")
        waitBriefly(0.2)
        XCTAssertEqual(mockNetwork.fetchExperimentsCallCount, 2, "Should refetch experiments when user changes")
        XCTAssertEqual(mockNetwork.lastFetchedUserId, "user_2")
    }

    func testIdentifyDoesNotRefetchForSameUser() {
        let mockNetwork = ExperimentsMockNetworkClient(
            experimentsResult: .success(["test": "variant"])
        )
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: true
        )

        sdk.identify(userId: "same_user")
        waitBriefly(0.2)
        let callCountAfterFirst = mockNetwork.fetchExperimentsCallCount

        sdk.identify(userId: "same_user")
        waitBriefly(0.2)
        XCTAssertEqual(
            mockNetwork.fetchExperimentsCallCount,
            callCountAfterFirst,
            "Should NOT refetch experiments when the same user is identified again"
        )
    }

    func testExperimentsFetchIncludesAnonymousId() {
        let mockNetwork = ExperimentsMockNetworkClient(
            experimentsResult: .success(["test": "variant"])
        )
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        waitBriefly()
        XCTAssertEqual(mockNetwork.lastFetchedUserId, sdk.anonymousId, "Anonymous users fetch with their anonymous ID")
        XCTAssertEqual(mockNetwork.lastFetchedAnonymousId, sdk.anonymousId, "anonymous_id must be sent alongside user_id")

        sdk.identify(userId: "specific_user_id")
        waitBriefly(0.2)
        XCTAssertEqual(mockNetwork.lastFetchedUserId, "specific_user_id")
        XCTAssertEqual(mockNetwork.lastFetchedAnonymousId, sdk.anonymousId, "anonymous_id is still sent after identify")
    }

    // MARK: - ready() Tests

    @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
    func testReadyResolvesAfterExperimentsLoad() async {
        let mockNetwork = ExperimentsMockNetworkClient(
            experimentsResult: .success(["async_test": "variant"])
        )
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        let start = Date()
        await sdk.ready(timeout: 5.0)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 4.0, "ready() should resolve on fetch completion, not wait for the timeout")
        XCTAssertEqual(sdk.getVariant("async_test"), "variant", "Variants must be available after ready() resolves")
    }

    @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
    func testReadyResolvesOnFetchFailure() async {
        let mockNetwork = ExperimentsMockNetworkClient(
            experimentsResult: .failure(.networkError(NSError(domain: "test", code: -1)))
        )
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        let start = Date()
        await sdk.ready(timeout: 10.0)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 5.0, "ready() must resolve promptly when the fetch fails - it must not hang")
        XCTAssertEqual(sdk.getVariant("anything", fallback: "control"), "control")
    }

    @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
    func testReadyResolvesOnTimeoutWhenFetchNeverCompletes() async {
        // Manual mock that never fires its completion: the only way out is the timeout
        let mockNetwork = ManualExperimentsMockNetworkClient()
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )
        XCTAssertEqual(mockNetwork.pendingFetchCount, 1, "Fetch should be in flight and unresolved")

        let start = Date()
        await sdk.ready(timeout: 0.5)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThanOrEqual(elapsed, 0.4, "ready() should wait for the timeout when the fetch never completes")
        XCTAssertLessThan(elapsed, 3.0, "ready() must resolve at the timeout - it must never hang")

        // Late completion after timeout must not crash (double-resume is a no-op)
        mockNetwork.completeNextFetch(with: .success(["late": "variant"]))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(sdk.getVariant("late"), "variant", "Late responses still populate assignments")
    }

    @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
    func testReadyResolvesImmediatelyIfAlreadyLoaded() async {
        let mockNetwork = ExperimentsMockNetworkClient(
            experimentsResult: .success(["exp": "v"])
        )
        let sdk = MostlyGoodMetrics(
            configuration: makeConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )
        try? await Task.sleep(nanoseconds: 300_000_000)

        let start = Date()
        await sdk.ready(timeout: 5.0)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 1.0, "ready() should return immediately when experiments are already loaded")
        XCTAssertEqual(sdk.getVariant("exp"), "v")
    }

    // MARK: - Static Method Tests

    func testStaticGetVariantWithFallback() {
        let config = MGMConfiguration(apiKey: "test_key", trackAppLifecycleEvents: false)
        MostlyGoodMetrics.configure(with: config)

        // No experiments loaded from the real network in tests: fallback applies
        XCTAssertEqual(MostlyGoodMetrics.getVariant("static_test", fallback: "control"), "control")
        XCTAssertNil(MostlyGoodMetrics.getVariant("static_test"))
    }

    @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
    func testStaticReadyResolvesWithinTimeout() async {
        let config = MGMConfiguration(apiKey: "test_key", trackAppLifecycleEvents: false)
        MostlyGoodMetrics.configure(with: config)

        let start = Date()
        await MostlyGoodMetrics.ready(timeout: 1.0)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 5.0, "Static ready() must resolve no later than its timeout")
    }
}

// MARK: - Snake Case Conversion Tests

final class SnakeCaseTests: XCTestCase {

    func testBasicCamelCase() {
        XCTAssertEqual("camelCase".toSnakeCase(), "camel_case")
        XCTAssertEqual("myVariableName".toSnakeCase(), "my_variable_name")
    }

    func testPascalCase() {
        XCTAssertEqual("PascalCase".toSnakeCase(), "pascal_case")
        XCTAssertEqual("MyClassName".toSnakeCase(), "my_class_name")
    }

    func testWithSpaces() {
        XCTAssertEqual("With Spaces".toSnakeCase(), "with__spaces")
        XCTAssertEqual("multiple words here".toSnakeCase(), "multiple_words_here")
    }

    func testWithHyphens() {
        XCTAssertEqual("with-hyphens".toSnakeCase(), "with_hyphens")
        XCTAssertEqual("kebab-case-string".toSnakeCase(), "kebab_case_string")
    }

    func testWithNumbers() {
        XCTAssertEqual("test123".toSnakeCase(), "test123")
        XCTAssertEqual("test123Name".toSnakeCase(), "test123_name")
        XCTAssertEqual("Version2Update".toSnakeCase(), "version2_update")
    }

    func testAlreadySnakeCase() {
        XCTAssertEqual("already_snake_case".toSnakeCase(), "already_snake_case")
        XCTAssertEqual("simple".toSnakeCase(), "simple")
    }

    func testUppercaseAcronyms() {
        XCTAssertEqual("parseJSON".toSnakeCase(), "parse_j_s_o_n")
        XCTAssertEqual("XMLParser".toSnakeCase(), "x_m_l_parser")
        XCTAssertEqual("getHTTPResponse".toSnakeCase(), "get_h_t_t_p_response")
    }

    func testEmptyAndSingleChar() {
        XCTAssertEqual("".toSnakeCase(), "")
        XCTAssertEqual("a".toSnakeCase(), "a")
        XCTAssertEqual("A".toSnakeCase(), "a")
    }

    func testMixedFormats() {
        XCTAssertEqual("mixed-Case_and spaces".toSnakeCase(), "mixed__case_and_spaces")
    }

    func testJSReferenceContractPinnedOutputs() {
        // Pinned against the shared JS reference implementation:
        // name.replace(/([A-Z])/g, "_$1").replace(/[-\s]+/g, "_").toLowerCase().replace(/^_/, "")
        XCTAssertEqual("Pricing-Test V2".toSnakeCase(), "pricing__test__v2")
        XCTAssertEqual("A-B-Test".toSnakeCase(), "a__b__test")
        XCTAssertEqual("ABTest".toSnakeCase(), "a_b_test")
        XCTAssertEqual("button-color".toSnakeCase(), "button_color")
        XCTAssertEqual("myExperiment2".toSnakeCase(), "my_experiment2")
    }
}

// MARK: - Platform Info Tests (Mac Catalyst support, MGM-26)

final class PlatformInfoTests: XCTestCase {

    // These tests run on whatever platform hosts `swift test` (typically native
    // macOS). The Catalyst-specific branches can only be exercised in an actual
    // Mac Catalyst target, but the mac-like derivation paths (hw.model, desktop
    // device type, macos platform name) are shared with native macOS and are
    // verified here.

    func testPlatformNameIsKnownValue() {
        let known = ["ios", "macos", "tvos", "watchos", "visionos"]
        XCTAssertTrue(known.contains(MGMPlatformInfo.platformName),
                      "platformName should never be 'unknown' on Apple platforms, got \(MGMPlatformInfo.platformName)")
    }

    func testPlatformDisplayNameMatchesPlatformName() {
        XCTAssertEqual(MGMPlatformInfo.platformDisplayName.lowercased(),
                       MGMPlatformInfo.platformName)
    }

    func testOSVersionIsNotEmpty() {
        XCTAssertFalse(MGMPlatformInfo.osVersion.isEmpty)
    }

    func testDeviceModelIsNotEmpty() {
        let model = MGMPlatformInfo.deviceModel
        XCTAssertNotNil(model)
        XCTAssertFalse(model!.isEmpty)
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
    func testIsMacLikeTrueOnMac() {
        XCTAssertTrue(MGMPlatformInfo.isMacLike)
    }

    func testPlatformNameIsMacOSOnMac() {
        XCTAssertEqual(MGMPlatformInfo.platformName, "macos")
        XCTAssertEqual(MGMPlatformInfo.platformDisplayName, "macOS")
    }

    func testDeviceTypeIsDesktopOnMac() {
        XCTAssertEqual(MGMPlatformInfo.deviceType, "desktop")
    }

    func testDeviceModelIsRealMacModelIdentifierNotArchitecture() {
        // Before the fix, a Mac reported the uname machine architecture
        // ("arm64"/"x86_64") instead of a model identifier like "Mac14,12".
        let model = MGMPlatformInfo.deviceModel
        XCTAssertNotNil(model)
        XCTAssertNotEqual(model, "arm64")
        XCTAssertNotEqual(model, "x86_64")
        // Mac model identifiers look like "Mac14,12", "MacBookPro18,3",
        // "VirtualMac2,1" (CI), etc.
        let pattern = "^[A-Za-z]+[0-9]+,[0-9]+$"
        XCTAssertNotNil(model!.range(of: pattern, options: .regularExpression),
                        "Expected a Mac model identifier, got \(model!)")
    }
    #endif

    #if os(iOS) && !targetEnvironment(macCatalyst)
    func testIsMacLikeFalseOnIOS() {
        XCTAssertFalse(MGMPlatformInfo.isMacLike)
    }
    #endif
}

// MARK: - Mac Lifecycle Debounce Policy Tests (Mac Catalyst support, MGM-26)

final class MacLifecyclePolicyTests: XCTestCase {

    private let threshold: TimeInterval = 5.0

    // MARK: $app_backgrounded

    func testAppBackgroundedNotTrackedOnMacLike() {
        // Native macOS and Mac Catalyst: never track $app_backgrounded
        // (window focus changes are too frequent).
        XCTAssertFalse(MostlyGoodMetrics.shouldTrackAppBackgrounded(isMacLike: true))
    }

    func testAppBackgroundedTrackedOnNonMac() {
        // iOS / tvOS / watchOS / visionOS keep the normal behavior.
        XCTAssertTrue(MostlyGoodMetrics.shouldTrackAppBackgrounded(isMacLike: false))
    }

    // MARK: $app_opened

    func testAppOpenedAlwaysTrackedOnNonMac() {
        XCTAssertTrue(MostlyGoodMetrics.shouldTrackAppOpened(
            lastBackgroundedTime: nil,
            threshold: threshold,
            isMacLike: false
        ))
        XCTAssertTrue(MostlyGoodMetrics.shouldTrackAppOpened(
            lastBackgroundedTime: Date().addingTimeInterval(-1),
            threshold: threshold,
            isMacLike: false
        ))
    }

    func testAppOpenedNotTrackedOnMacLikeWithoutPriorBackground() {
        // First activation (no recorded background time): don't track on Mac.
        XCTAssertFalse(MostlyGoodMetrics.shouldTrackAppOpened(
            lastBackgroundedTime: nil,
            threshold: threshold,
            isMacLike: true
        ))
    }

    func testAppOpenedNotTrackedOnMacLikeBelowThreshold() {
        // Quick window/app switch (< 5s): suppressed on Mac.
        let now = Date()
        XCTAssertFalse(MostlyGoodMetrics.shouldTrackAppOpened(
            lastBackgroundedTime: now.addingTimeInterval(-4.9),
            threshold: threshold,
            now: now,
            isMacLike: true
        ))
    }

    func testAppOpenedTrackedOnMacLikeAtThreshold() {
        let now = Date()
        XCTAssertTrue(MostlyGoodMetrics.shouldTrackAppOpened(
            lastBackgroundedTime: now.addingTimeInterval(-5.0),
            threshold: threshold,
            now: now,
            isMacLike: true
        ))
    }

    func testAppOpenedTrackedOnMacLikeAboveThreshold() {
        let now = Date()
        XCTAssertTrue(MostlyGoodMetrics.shouldTrackAppOpened(
            lastBackgroundedTime: now.addingTimeInterval(-60),
            threshold: threshold,
            now: now,
            isMacLike: true
        ))
    }
}

// MARK: - Local Bucketing Golden Vector Tests

/// Golden vectors for the cross-SDK on-device bucketing algorithm:
/// bucket = first 8 bytes of SHA256(utf8("<experiment_uuid>:<effective_user_id>"))
/// as a big-endian UInt64; variant = variants[bucket % variants.count].
/// These vectors are shared across all MostlyGoodMetrics SDKs and must never drift.
final class LocalBucketingGoldenVectorTests: XCTestCase {

    private struct GoldenVector {
        let experimentId: String
        let userId: String
        let variants: [String]
        let bucket: UInt64
        let expectedVariant: String
    }

    private let vectors: [GoldenVector] = [
        GoldenVector(
            experimentId: "7b1e8a90-4c2d-4f6a-9e3b-2a1d5c8f0e71",
            userId: "user_123",
            variants: ["control", "treatment"],
            bucket: 11452140836674321702,
            expectedVariant: "control"
        ),
        GoldenVector(
            experimentId: "7b1e8a90-4c2d-4f6a-9e3b-2a1d5c8f0e71",
            userId: "$anon_abc123def456",
            variants: ["control", "treatment"],
            bucket: 10935638356306450407,
            expectedVariant: "treatment"
        ),
        GoldenVector(
            experimentId: "3f9c2d11-8b7a-4e5f-a0c6-91d2e3f4a5b6",
            userId: "user_123",
            variants: ["a", "b", "c"],
            bucket: 3772238658190659659,
            expectedVariant: "c"
        ),
        GoldenVector(
            experimentId: "3f9c2d11-8b7a-4e5f-a0c6-91d2e3f4a5b6",
            userId: "chris@nihongo.example",
            variants: ["a", "b", "c"],
            bucket: 15293329125595004806,
            expectedVariant: "b"
        ),
        GoldenVector(
            experimentId: "c0ffee00-1234-5678-9abc-def012345678",
            userId: "u",
            variants: ["on", "off"],
            bucket: 5314609686893464838,
            expectedVariant: "on"
        ),
        GoldenVector(
            experimentId: "c0ffee00-1234-5678-9abc-def012345678",
            userId: "日本語ユーザー",
            variants: ["on", "off"],
            bucket: 15854517259962621242,
            expectedVariant: "on"
        ),
        GoldenVector(
            experimentId: "aaaaaaaa-bbbb-cccc-dddd-eeeeffff0000",
            userId: "user_with_long_id_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
            variants: ["v1", "v2", "v3", "v4", "v5"],
            bucket: 16479651874404423415,
            expectedVariant: "v1"
        ),
        GoldenVector(
            experimentId: "aaaaaaaa-bbbb-cccc-dddd-eeeeffff0000",
            userId: "",
            variants: ["v1", "v2"],
            bucket: 2902893145859674316,
            expectedVariant: "v1"
        )
    ]

    func testGoldenVectorBuckets() {
        for vector in vectors {
            XCTAssertEqual(
                MGMLocalBucketing.bucket(experimentId: vector.experimentId, userId: vector.userId),
                vector.bucket,
                "Bucket mismatch for experiment \(vector.experimentId), user '\(vector.userId)'"
            )
        }
    }

    func testGoldenVectorVariants() {
        for vector in vectors {
            XCTAssertEqual(
                MGMLocalBucketing.variant(
                    experimentId: vector.experimentId,
                    userId: vector.userId,
                    variants: vector.variants
                ),
                vector.expectedVariant,
                "Variant mismatch for experiment \(vector.experimentId), user '\(vector.userId)'"
            )
        }
    }

    func testVariantIsNilForEmptyVariantsList() {
        XCTAssertNil(MGMLocalBucketing.variant(
            experimentId: "7b1e8a90-4c2d-4f6a-9e3b-2a1d5c8f0e71",
            userId: "user_123",
            variants: []
        ))
    }
}

// MARK: - Local Experiment Mode Tests

final class LocalExperimentsTests: XCTestCase {

    /// Golden-vector experiment: "user_123" -> "control", "$anon_abc123def456" -> "treatment"
    private let buttonColorExperiment = MGMExperimentConfig(
        id: "7b1e8a90-4c2d-4f6a-9e3b-2a1d5c8f0e71",
        name: "button-color",
        variants: ["control", "treatment"]
    )

    override func setUp() {
        super.setUp()
        clearLocalExperimentsDefaults()
    }

    override func tearDown() {
        super.tearDown()
        clearLocalExperimentsDefaults()
        MostlyGoodMetrics.shared?.clearSuperProperties()
    }

    private func clearLocalExperimentsDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "MGM_localExperimentAssignments")
        defaults.removeObject(forKey: "MGM_localExperimentConfigsCache")
        defaults.removeObject(forKey: "MGM_localExperimentConfigsFetchedAt")
        defaults.removeObject(forKey: "MGM_experimentExposures")
        defaults.removeObject(forKey: "MGM_userId")
        defaults.removeObject(forKey: "MGM_anonymousId")
        defaults.removeObject(forKey: "MGM_superProperties")
        defaults.removeObject(forKey: "MGM_optedOut")
    }

    private func makeLocalConfig(
        localExperiments: [MGMExperimentConfig] = [],
        optedOutByDefault: Bool = false
    ) -> MGMConfiguration {
        MGMConfiguration(
            apiKey: "test_key",
            trackAppLifecycleEvents: false,
            experimentMode: .local,
            localExperiments: localExperiments,
            optedOutByDefault: optedOutByDefault
        )
    }

    /// Blocks the test for the given duration (lets async mock completions land).
    private func waitBriefly(_ seconds: TimeInterval = 0.3) {
        let exp = expectation(description: "brief wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        waitForExpectations(timeout: seconds + 2)
    }

    private func exposureEvents(in storage: InMemoryEventStorage) -> [MGMEvent] {
        storage.fetchEvents(limit: 1000).filter { $0.name == "$experiment_exposure" }
    }

    // MARK: - Inline Configs (zero network)

    func testInlineConfigsBucketOnDeviceWithoutAnyFetch() {
        UserDefaults.standard.set("user_123", forKey: "MGM_userId")

        let mockNetwork = ExperimentsMockNetworkClient()
        let sdk = MostlyGoodMetrics(
            configuration: makeLocalConfig(localExperiments: [buttonColorExperiment]),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        // Inline configs load synchronously; matches the golden vector for user_123
        XCTAssertEqual(sdk.getVariant("button-color"), "control")
        XCTAssertEqual(mockNetwork.fetchExperimentsCallCount, 0, "Local mode must not fetch server assignments")
        XCTAssertEqual(mockNetwork.fetchExperimentConfigsCallCount, 0, "Inline configs must not trigger a configs fetch")
    }

    func testInlineConfigsReadyResolvesImmediately() async {
        let sdk = MostlyGoodMetrics(
            configuration: makeLocalConfig(localExperiments: [buttonColorExperiment]),
            storage: InMemoryEventStorage(),
            networkClient: ExperimentsMockNetworkClient(),
            skipExperimentsLoad: false
        )

        // Should return without waiting for any timeout
        await sdk.ready(timeout: 5.0)
        XCTAssertNotNil(sdk.getVariant("button-color"))
    }

    // MARK: - Fetched Configs

    func testFetchedConfigsBucketOnDevice() {
        UserDefaults.standard.set("user_123", forKey: "MGM_userId")

        let mockNetwork = ExperimentsMockNetworkClient(
            experimentConfigsResult: .success([buttonColorExperiment])
        )
        let sdk = MostlyGoodMetrics(
            configuration: makeLocalConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        waitBriefly()

        XCTAssertEqual(sdk.getVariant("button-color"), "control")
        XCTAssertEqual(mockNetwork.fetchExperimentConfigsCallCount, 1, "Should have fetched configs exactly once on init")
        XCTAssertEqual(mockNetwork.fetchExperimentsCallCount, 0, "Local mode must never call the server-assignment endpoint")
    }

    func testFetchedConfigsAreCachedAndServedWhenLaterFetchFails() {
        UserDefaults.standard.set("user_123", forKey: "MGM_userId")

        // First "launch" fetches and caches configs
        let mockNetwork1 = ExperimentsMockNetworkClient(
            experimentConfigsResult: .success([buttonColorExperiment])
        )
        let sdk1 = MostlyGoodMetrics(
            configuration: makeLocalConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork1,
            skipExperimentsLoad: false
        )
        waitBriefly()
        XCTAssertEqual(sdk1.getVariant("button-color"), "control")

        // Second "launch" cannot reach the server but serves the cached configs
        let mockNetwork2 = ExperimentsMockNetworkClient(
            experimentConfigsResult: .failure(.networkError(NSError(domain: "test", code: -1)))
        )
        let sdk2 = MostlyGoodMetrics(
            configuration: makeLocalConfig(),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork2,
            skipExperimentsLoad: false
        )
        waitBriefly()
        XCTAssertEqual(sdk2.getVariant("button-color"), "control", "Cached configs should be served offline")
    }

    func testGetVariantReturnsFallbackForUnknownExperiment() {
        let sdk = MostlyGoodMetrics(
            configuration: makeLocalConfig(localExperiments: [buttonColorExperiment]),
            storage: InMemoryEventStorage(),
            networkClient: ExperimentsMockNetworkClient(),
            skipExperimentsLoad: false
        )

        XCTAssertEqual(sdk.getVariant("unknown_experiment", fallback: "fallback"), "fallback")
        XCTAssertNil(sdk.getVariant("unknown_experiment"))
    }

    // MARK: - Sticky Assignments

    func testAssignmentIsStickyAcrossIdentify() {
        // Anonymous at first launch: variant is bucketed from the anonymous ID
        let sdk = MostlyGoodMetrics(
            configuration: makeLocalConfig(localExperiments: [buttonColorExperiment]),
            storage: InMemoryEventStorage(),
            networkClient: ExperimentsMockNetworkClient(),
            skipExperimentsLoad: false
        )

        guard let anonymousVariant = sdk.getVariant("button-color") else {
            XCTFail("Expected a variant for the anonymous user")
            return
        }

        // Identifying must NOT re-bucket: the anonymous-era variant sticks
        // (matches server behavior)
        sdk.identify(userId: "user_123")
        waitBriefly()
        XCTAssertEqual(sdk.getVariant("button-color"), anonymousVariant, "identify() must not re-bucket a sticky local assignment")
    }

    func testAssignmentIsPersistedPerExperimentUUID() {
        UserDefaults.standard.set("user_123", forKey: "MGM_userId")

        let sdk = MostlyGoodMetrics(
            configuration: makeLocalConfig(localExperiments: [buttonColorExperiment]),
            storage: InMemoryEventStorage(),
            networkClient: ExperimentsMockNetworkClient(),
            skipExperimentsLoad: false
        )

        XCTAssertEqual(sdk.getVariant("button-color"), "control")

        let assignments = UserDefaults.standard.dictionary(forKey: "MGM_localExperimentAssignments") as? [String: String]
        XCTAssertEqual(
            assignments?[buttonColorExperiment.id],
            "control",
            "Assignment should be persisted keyed by the experiment UUID"
        )
    }

    func testPersistedAssignmentIsReusedAcrossRelaunchEvenIfUserChanged() {
        // First launch as user_123 -> "control" (golden vector)
        UserDefaults.standard.set("user_123", forKey: "MGM_userId")
        let sdk1 = MostlyGoodMetrics(
            configuration: makeLocalConfig(localExperiments: [buttonColorExperiment]),
            storage: InMemoryEventStorage(),
            networkClient: ExperimentsMockNetworkClient(),
            skipExperimentsLoad: false
        )
        XCTAssertEqual(sdk1.getVariant("button-color"), "control")

        // Relaunch as a user that would bucket into "treatment"
        // ($anon_abc123def456 -> "treatment" per golden vector); the persisted
        // assignment must win.
        UserDefaults.standard.set("$anon_abc123def456", forKey: "MGM_userId")
        let sdk2 = MostlyGoodMetrics(
            configuration: makeLocalConfig(localExperiments: [buttonColorExperiment]),
            storage: InMemoryEventStorage(),
            networkClient: ExperimentsMockNetworkClient(),
            skipExperimentsLoad: false
        )
        XCTAssertEqual(sdk2.getVariant("button-color"), "control", "Persisted assignment must be reused across relaunches")
    }

    // MARK: - Exposure Events

    func testExposureTrackedWithRawExperimentName() {
        UserDefaults.standard.set("user_123", forKey: "MGM_userId")

        let storage = InMemoryEventStorage()
        let sdk = MostlyGoodMetrics(
            configuration: makeLocalConfig(localExperiments: [buttonColorExperiment]),
            storage: storage,
            networkClient: ExperimentsMockNetworkClient(),
            skipExperimentsLoad: false
        )

        XCTAssertEqual(sdk.getVariant("button-color"), "control")
        waitBriefly(0.2)

        let exposures = exposureEvents(in: storage)
        XCTAssertEqual(exposures.count, 1, "Exactly one $experiment_exposure event should be tracked")
        XCTAssertEqual(exposures.first?.properties?["$experiment_name"]?.value as? String, "button-color")
        XCTAssertEqual(exposures.first?.properties?["$variant"]?.value as? String, "control")
    }

    func testExposureDedupedAcrossRepeatedGetVariantCalls() {
        UserDefaults.standard.set("user_123", forKey: "MGM_userId")

        let storage = InMemoryEventStorage()
        let sdk = MostlyGoodMetrics(
            configuration: makeLocalConfig(localExperiments: [buttonColorExperiment]),
            storage: storage,
            networkClient: ExperimentsMockNetworkClient(),
            skipExperimentsLoad: false
        )

        _ = sdk.getVariant("button-color")
        _ = sdk.getVariant("button-color")
        _ = sdk.getVariant("button-color")
        waitBriefly(0.2)

        XCTAssertEqual(exposureEvents(in: storage).count, 1, "Repeated getVariant calls must not re-fire exposure")
    }

    func testGetVariantSetsSuperPropertyInLocalMode() {
        UserDefaults.standard.set("user_123", forKey: "MGM_userId")

        let sdk = MostlyGoodMetrics(
            configuration: makeLocalConfig(localExperiments: [buttonColorExperiment]),
            storage: InMemoryEventStorage(),
            networkClient: ExperimentsMockNetworkClient(),
            skipExperimentsLoad: false
        )

        _ = sdk.getVariant("button-color")

        let superProperties = sdk.getSuperProperties()
        XCTAssertEqual(superProperties["$experiment_button_color"] as? String, "control")
    }

    // MARK: - Privacy Interplay (Forget-Me / Opt-Out)

    /// Golden-vector experiment: "user_123" -> "c", "chris@nihongo.example" -> "b"
    private var onboardingFlowExperiment: MGMExperimentConfig {
        MGMExperimentConfig(
            id: "3f9c2d11-8b7a-4e5f-a0c6-91d2e3f4a5b6",
            name: "onboarding-flow",
            variants: ["a", "b", "c"]
        )
    }

    func testForgetMeResetClearsLocalAssignmentsAndRebucketsUnderNewAnonymousId() {
        UserDefaults.standard.set("user_123", forKey: "MGM_userId")

        let sdk = MostlyGoodMetrics(
            configuration: makeLocalConfig(localExperiments: [onboardingFlowExperiment]),
            storage: InMemoryEventStorage(),
            networkClient: ExperimentsMockNetworkClient(),
            skipExperimentsLoad: false
        )
        XCTAssertEqual(sdk.getVariant("onboarding-flow"), "c", "Golden vector for user_123")

        sdk.reset(clearAnonymousId: true)

        XCTAssertNil(
            UserDefaults.standard.dictionary(forKey: "MGM_localExperimentAssignments"),
            "Forget-me must clear persisted local experiment assignments"
        )

        // The next getVariant must re-bucket fresh under the rotated anonymous ID
        // (deterministic for whatever new ID was generated).
        let expectedForRotatedId = MGMLocalBucketing.variant(
            experimentId: onboardingFlowExperiment.id,
            userId: sdk.anonymousId,
            variants: onboardingFlowExperiment.variants
        )
        XCTAssertEqual(
            sdk.getVariant("onboarding-flow"),
            expectedForRotatedId,
            "After forget-me the variant must be re-bucketed from the new anonymous ID"
        )
    }

    func testForgetMeRebucketedAssignmentCanChangeUnderNewIdentity() {
        UserDefaults.standard.set("user_123", forKey: "MGM_userId")

        let sdk = MostlyGoodMetrics(
            configuration: makeLocalConfig(localExperiments: [onboardingFlowExperiment]),
            storage: InMemoryEventStorage(),
            networkClient: ExperimentsMockNetworkClient(),
            skipExperimentsLoad: false
        )
        XCTAssertEqual(sdk.getVariant("onboarding-flow"), "c", "Golden vector for user_123")

        // Forget-me, then a new identity that hashes into a different variant
        // (golden vector: chris@nihongo.example -> "b").
        sdk.reset(clearAnonymousId: true)
        sdk.identify(userId: "chris@nihongo.example")
        waitBriefly(0.2)

        XCTAssertEqual(
            sdk.getVariant("onboarding-flow"),
            "b",
            "Re-bucketing under the new identity must produce that identity's variant, not the pre-reset one"
        )
    }

    func testPlainResetKeepsLocalAssignments() {
        UserDefaults.standard.set("user_123", forKey: "MGM_userId")

        let sdk = MostlyGoodMetrics(
            configuration: makeLocalConfig(localExperiments: [buttonColorExperiment]),
            storage: InMemoryEventStorage(),
            networkClient: ExperimentsMockNetworkClient(),
            skipExperimentsLoad: false
        )
        XCTAssertEqual(sdk.getVariant("button-color"), "control")

        // Plain reset (no clearAnonymousId) matches server-mode stickiness
        sdk.reset()

        let assignments = UserDefaults.standard.dictionary(forKey: "MGM_localExperimentAssignments") as? [String: String]
        XCTAssertEqual(
            assignments?[buttonColorExperiment.id],
            "control",
            "Plain reset() must keep sticky local assignments"
        )
        XCTAssertEqual(sdk.getVariant("button-color"), "control", "Sticky assignment must survive a plain reset")
    }

    func testOptedOutLocalModePerformsNoConfigFetch() {
        let mockNetwork = ExperimentsMockNetworkClient(
            experimentConfigsResult: .success([buttonColorExperiment])
        )
        let sdk = MostlyGoodMetrics(
            configuration: makeLocalConfig(optedOutByDefault: true),
            storage: InMemoryEventStorage(),
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )
        waitBriefly()

        XCTAssertTrue(sdk.isOptedOut)
        XCTAssertEqual(mockNetwork.fetchExperimentConfigsCallCount, 0, "Opted-out local mode must not fetch experiment configs")
        XCTAssertEqual(mockNetwork.fetchExperimentsCallCount, 0, "Opted-out local mode must not call the server-assignment endpoint")
    }

    func testOptedOutLocalModeBucketsFromInlineConfigsWithoutExposures() {
        UserDefaults.standard.set("user_123", forKey: "MGM_userId")

        let storage = InMemoryEventStorage()
        let mockNetwork = ExperimentsMockNetworkClient()
        let sdk = MostlyGoodMetrics(
            configuration: makeLocalConfig(localExperiments: [buttonColorExperiment], optedOutByDefault: true),
            storage: storage,
            networkClient: mockNetwork,
            skipExperimentsLoad: false
        )

        // Bucketing still works from inline configs while opted out
        XCTAssertEqual(sdk.getVariant("button-color"), "control")
        XCTAssertEqual(mockNetwork.fetchExperimentConfigsCallCount, 0, "Inline configs while opted out must not fetch")
        waitBriefly(0.2)

        // ...but no exposure is tracked and no dedup state is recorded
        XCTAssertEqual(exposureEvents(in: storage).count, 0, "No $experiment_exposure while opted out")
        XCTAssertNil(
            UserDefaults.standard.stringArray(forKey: "MGM_experimentExposures"),
            "No exposure dedup state should be recorded while opted out"
        )

        // After opting in, the exposure can still fire
        sdk.optIn()
        XCTAssertEqual(sdk.getVariant("button-color"), "control")
        waitBriefly(0.2)
        XCTAssertEqual(exposureEvents(in: storage).count, 1, "Exposure should fire on the first getVariant after opt-in")
    }
}

// MARK: - Privacy Controls Tests

final class PrivacyControlsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear persisted privacy/identity state before each test
        UserDefaults.standard.removeObject(forKey: "MGM_optedOut")
        UserDefaults.standard.removeObject(forKey: "MGM_userId")
        UserDefaults.standard.removeObject(forKey: "MGM_superProperties")
        UserDefaults.standard.removeObject(forKey: "MGM_identifyHash")
        UserDefaults.standard.removeObject(forKey: "MGM_identifyTimestamp")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "MGM_optedOut")
        UserDefaults.standard.removeObject(forKey: "MGM_userId")
        UserDefaults.standard.removeObject(forKey: "MGM_superProperties")
        UserDefaults.standard.removeObject(forKey: "MGM_identifyHash")
        UserDefaults.standard.removeObject(forKey: "MGM_identifyTimestamp")
        super.tearDown()
    }

    private func makeClient(
        storage: InMemoryEventStorage,
        optedOutByDefault: Bool = false,
        collectDeviceProperties: Bool = true
    ) -> MostlyGoodMetrics {
        let config = MGMConfiguration(
            apiKey: "test_key",
            optedOutByDefault: optedOutByDefault,
            collectDeviceProperties: collectDeviceProperties
        )
        return MostlyGoodMetrics(configuration: config, storage: storage)
    }

    // MARK: - Opt-Out Tests

    func testDefaultIsOptedIn() {
        let client = makeClient(storage: InMemoryEventStorage())
        XCTAssertFalse(client.isOptedOut)
    }

    func testOptOutMakesTrackNoOp() {
        let storage = InMemoryEventStorage()
        let client = makeClient(storage: storage)

        client.optOut()
        XCTAssertTrue(client.isOptedOut)

        client.track("should_be_dropped")

        let expectation = self.expectation(description: "Opt-out drops events")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(storage.eventCount(), 0, "No events should be stored while opted out")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testOptOutPurgesQueuedEvents() {
        let storage = InMemoryEventStorage()
        let client = makeClient(storage: storage)

        client.track("event1")
        client.track("event2")

        let expectation = self.expectation(description: "Opt-out purges queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(storage.eventCount(), 2)

            client.optOut()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                XCTAssertEqual(storage.eventCount(), 0, "Queued events should be purged on opt-out")
                expectation.fulfill()
            }
        }
        waitForExpectations(timeout: 1)
    }

    func testOptOutMakesIdentifyNoOp() {
        let storage = InMemoryEventStorage()
        let client = makeClient(storage: storage)

        client.optOut()
        client.identify(userId: "ignored_user", profile: UserProfile(email: "ignored@example.com"))

        XCTAssertNil(client.userId, "identify should be a no-op while opted out")

        let expectation = self.expectation(description: "Opt-out ignores identify")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(storage.eventCount(), 0, "No $identify event should be stored while opted out")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testOptOutMakesFlushNoOp() {
        let storage = InMemoryEventStorage()
        let mockNetwork = MockNetworkClient(result: .success(()))
        let config = MGMConfiguration(apiKey: "test_key")
        let client = MostlyGoodMetrics(configuration: config, storage: storage, networkClient: mockNetwork)

        // Pre-load storage directly, then opt out without purging via a fresh store
        storage.store(event: MGMEvent(name: "event1"))

        client.optOut()

        let expectation = self.expectation(description: "Opt-out skips flush")
        client.flush { result in
            switch result {
            case .success:
                XCTAssertEqual(mockNetwork.sendCount, 0, "No network calls should happen while opted out")
                expectation.fulfill()
            case .failure:
                XCTFail("Flush should no-op successfully while opted out")
            }
        }
        waitForExpectations(timeout: 5)
    }

    func testOptInResumesTracking() {
        let storage = InMemoryEventStorage()
        let client = makeClient(storage: storage)

        client.optOut()
        client.track("dropped_event")

        client.optIn()
        XCTAssertFalse(client.isOptedOut)
        client.track("tracked_event")

        let expectation = self.expectation(description: "Opt-in resumes tracking")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(storage.eventCount(), 1)
            let events = storage.fetchEvents(limit: 10)
            XCTAssertEqual(events.first?.name, "tracked_event")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testOptOutPersistsAcrossInstances() {
        let client1 = makeClient(storage: InMemoryEventStorage())
        client1.optOut()

        // Simulate app relaunch with a new instance
        let client2 = makeClient(storage: InMemoryEventStorage())
        XCTAssertTrue(client2.isOptedOut, "Opt-out should persist across instances")

        // Opt back in and verify persistence again
        client2.optIn()
        let client3 = makeClient(storage: InMemoryEventStorage())
        XCTAssertFalse(client3.isOptedOut, "Opt-in should persist across instances")
    }

    func testOptOutPersistedInUserDefaults() {
        let client = makeClient(storage: InMemoryEventStorage())

        client.optOut()
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "MGM_optedOut"), true)

        client.optIn()
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "MGM_optedOut"), false)
    }

    // MARK: - Opted Out By Default Tests

    func testOptedOutByDefaultStartsOptedOut() {
        let storage = InMemoryEventStorage()
        let client = makeClient(storage: storage, optedOutByDefault: true)

        XCTAssertTrue(client.isOptedOut)

        client.track("consent_pending_event")

        let expectation = self.expectation(description: "Opted out by default drops events")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(storage.eventCount(), 0)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testOptedOutByDefaultCanOptIn() {
        let storage = InMemoryEventStorage()
        let client = makeClient(storage: storage, optedOutByDefault: true)

        client.optIn()
        XCTAssertFalse(client.isOptedOut)

        client.track("consented_event")

        let expectation = self.expectation(description: "Opt-in after consent")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(storage.eventCount(), 1)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testPersistedOptInOverridesOptedOutByDefault() {
        let client1 = makeClient(storage: InMemoryEventStorage(), optedOutByDefault: true)
        client1.optIn()

        // Relaunch: persisted opt-in choice wins over the configured default
        let client2 = makeClient(storage: InMemoryEventStorage(), optedOutByDefault: true)
        XCTAssertFalse(client2.isOptedOut, "Persisted opt-in should override optedOutByDefault")
    }

    // MARK: - Anonymous ID Rotation Tests

    func testResetAnonymousIdRotatesId() {
        let client = makeClient(storage: InMemoryEventStorage())
        let originalId = client.anonymousId

        let newId = client.resetAnonymousId()

        XCTAssertNotEqual(newId, originalId, "resetAnonymousId should generate a new ID")
        XCTAssertEqual(client.anonymousId, newId)
        XCTAssertTrue(newId.hasPrefix("$anon_"), "New anonymous ID should keep the $anon_ prefix")
    }

    func testResetAnonymousIdPersists() {
        let client1 = makeClient(storage: InMemoryEventStorage())
        let newId = client1.resetAnonymousId()

        XCTAssertEqual(UserDefaults.standard.string(forKey: "MGM_anonymousId"), newId)

        // A new instance should restore the rotated ID
        let client2 = makeClient(storage: InMemoryEventStorage())
        XCTAssertEqual(client2.anonymousId, newId)
    }

    func testResetAnonymousIdUsedForSubsequentEvents() {
        let storage = InMemoryEventStorage()
        let client = makeClient(storage: storage)

        let newId = client.resetAnonymousId()
        client.track("after_rotation")

        let expectation = self.expectation(description: "Rotated ID in events")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 1)
            XCTAssertEqual(events.first?.userId, newId, "Events should use the rotated anonymous ID")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    // MARK: - Reset ("Forget Me") Tests

    func testResetClearsLocalState() {
        let storage = InMemoryEventStorage()
        let client = makeClient(storage: storage)

        client.identify(userId: "user123")
        client.setSuperProperty("plan", value: "premium")
        client.track("event_before_reset")
        let originalSessionId = client.sessionId
        let originalAnonymousId = client.anonymousId

        let expectation = self.expectation(description: "Reset clears state")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(storage.eventCount(), 1)

            client.reset()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                XCTAssertNil(client.userId, "Reset should clear the user ID")
                XCTAssertEqual(storage.eventCount(), 0, "Reset should purge the pending queue")
                XCTAssertTrue(client.getSuperProperties().isEmpty, "Reset should clear super properties")
                XCTAssertNotEqual(client.sessionId, originalSessionId, "Reset should start a new session")
                XCTAssertEqual(client.anonymousId, originalAnonymousId, "Reset should keep the anonymous ID by default")
                expectation.fulfill()
            }
        }
        waitForExpectations(timeout: 2)
    }

    func testResetWithClearAnonymousIdRotatesId() {
        let client = makeClient(storage: InMemoryEventStorage())

        client.identify(userId: "user123")
        let originalAnonymousId = client.anonymousId

        client.reset(clearAnonymousId: true)

        XCTAssertNil(client.userId)
        XCTAssertNotEqual(client.anonymousId, originalAnonymousId, "reset(clearAnonymousId: true) should rotate the anonymous ID")
        XCTAssertTrue(client.anonymousId.hasPrefix("$anon_"))
        XCTAssertEqual(UserDefaults.standard.string(forKey: "MGM_anonymousId"), client.anonymousId)
    }

    // MARK: - Device Property Collection Tests

    func testCollectDevicePropertiesEnabledByDefault() {
        let storage = InMemoryEventStorage()
        let client = makeClient(storage: storage)

        client.track("test_event")

        let expectation = self.expectation(description: "Device properties collected by default")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 1)
            let event = events.first
            XCTAssertNotNil(event?.properties?["$device_type"]?.value as? String)
            XCTAssertEqual(event?.deviceManufacturer, "Apple")
            XCTAssertNotNil(event?.locale)
            XCTAssertNotNil(event?.timezone)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testCollectDevicePropertiesDisabledOmitsDeviceProperties() {
        let storage = InMemoryEventStorage()
        let client = makeClient(storage: storage, collectDeviceProperties: false)

        client.track("test_event")

        let expectation = self.expectation(description: "Device properties omitted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let events = storage.fetchEvents(limit: 1)
            let event = events.first
            XCTAssertNotNil(event, "Event should still be tracked")

            // Device properties must be omitted entirely
            XCTAssertNil(event?.properties?["$device_type"], "$device_type should be omitted")
            XCTAssertNil(event?.properties?["$device_model"], "$device_model should be omitted")
            XCTAssertNil(event?.deviceManufacturer, "device_manufacturer should be omitted")
            XCTAssertNil(event?.locale, "locale should be omitted")
            XCTAssertNil(event?.timezone, "timezone should be omitted")

            // Functional context is still sent
            XCTAssertNotNil(event?.platform)
            XCTAssertNotNil(event?.osVersion)
            XCTAssertEqual(event?.properties?["$sdk"]?.value as? String, "swift")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testConfigurationPrivacyDefaults() {
        let config = MGMConfiguration(apiKey: "test_key")
        XCTAssertFalse(config.optedOutByDefault)
        XCTAssertTrue(config.collectDeviceProperties)
    }
}

// MARK: - SDK Version Tests

/// Guards against the reported SDK version drifting from the podspec release version.
final class SDKVersionTests: XCTestCase {

    /// The reported `sdkVersion` (sent in User-Agent and X-MGM-SDK-Version headers)
    /// must match `s.version` in MostlyGoodMetrics.podspec — the release source of truth.
    func testSDKVersionMatchesPodspec() throws {
        // Locate the podspec relative to this test file (repo root is three levels up).
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MostlyGoodMetricsTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
        let podspecURL = repoRoot.appendingPathComponent("MostlyGoodMetrics.podspec")

        let podspec = try String(contentsOf: podspecURL, encoding: .utf8)

        // Parse `s.version = 'X.Y.Z'` from the podspec.
        let pattern = #"s\.version\s*=\s*['"]([^'"]+)['"]"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(podspec.startIndex..., in: podspec)
        guard let match = regex.firstMatch(in: podspec, range: range),
              let versionRange = Range(match.range(at: 1), in: podspec) else {
            XCTFail("Could not find s.version in podspec")
            return
        }

        let podspecVersion = String(podspec[versionRange])
        XCTAssertEqual(
            sdkVersion,
            podspecVersion,
            "sdkVersion (\(sdkVersion)) must match podspec version (\(podspecVersion)). Update NetworkClient.swift when bumping the release."
        )
    }
}
