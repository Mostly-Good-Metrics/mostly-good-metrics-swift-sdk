import XCTest
import Foundation
@testable import MostlyGoodMetrics

final class HostSafetyTests: XCTestCase {
    private var savedDefaults: [String: Any] = [:]
    private let keys = ["MGM_optedOut", "MGM_anonymousId", "MGM_userId", "MGM_superProperties"]
    override func setUp() {
        super.setUp()
        for key in keys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.removeObject(forKey: "MGM_optedOut")
        UserDefaults.standard.removeObject(forKey: "MGM_superProperties")
    }
    override func tearDown() {
        for key in keys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    func testDeepPropertiesAreBoundedBeforeEncoding() throws {
        var value: Any = "leaf"
        // Release subprocess additionally exercises the original 20,000-level crash.
        for _ in 0..<200 { value = [value] }
        let event = MGMEvent(name: "deep", properties: ["value": value, "readable": "yes"])
        let data = try JSONEncoder().encode(event)
        XCTAssertLessThan(data.count, 1000)
        XCTAssertEqual(event.properties?["readable"]?.value as? String, "yes")
    }

    func testCyclicFoundationContainersAndFanoutAreBounded() throws {
        let array = NSMutableArray()
        for _ in 0..<200 { array.add(array) }
        let dictionary = NSMutableDictionary()
        dictionary["self"] = dictionary
        dictionary["readable"] = "yes"
        defer { array.removeAllObjects(); dictionary.removeAllObjects() }
        let event = MGMEvent(name: "cycle", properties: ["array": array, "dictionary": dictionary])
        XCTAssertLessThan(try JSONEncoder().encode(event).count, 20_000)
    }

    func testMutableContainersAreSnapshotted() throws {
        let values = NSMutableArray(array: ["before"])
        let event = MGMEvent(name: "snapshot", properties: ["values": values])
        values.removeAllObjects()
        values.add("after")
        XCTAssertEqual(event.properties?["values"]?.value as? [String], ["before"])
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("before"))
    }

    func testOversizedPropertiesAndNonfiniteNumbersDoNotPoisonEvent() throws {
        let properties = Dictionary(uniqueKeysWithValues: (0..<500).map { ("key\($0)", String(repeating: "x", count: 1000) as Any) })
        let event = MGMEvent(name: "oversized", properties: properties)
        XCTAssertNil(event.properties)
        XCTAssertNoThrow(try JSONEncoder().encode(event))
        XCTAssertNoThrow(try JSONEncoder().encode(MGMEvent(name: "finite", properties: ["bad": Double.infinity])))
    }

    func testPublicPropertyAssignmentCannotBypassAggregateLimit() throws {
        var event = MGMEvent(name: "assigned")
        event.properties = Dictionary(uniqueKeysWithValues: (0..<500).map { ("key\($0)", AnyCodable(String(repeating: "x", count: 1000))) })
        let data = try JSONEncoder().encode(event)
        XCTAssertLessThan(data.count, 1000)
        let decoded = try JSONDecoder().decode(MGMEvent.self, from: data)
        XCTAssertNil(decoded.properties)
        XCTAssertEqual(decoded.name, "assigned")
    }

    func testCombiningMarkGraphemesCannotBypassStringAndKeyBounds() throws {
        let pathological = "a" + String(repeating: "\u{0301}", count: 100_000)
        let wrapper = AnyCodable(pathological)
        let encoded = try JSONEncoder().encode(wrapper)
        XCTAssertLessThan(encoded.count, PropertySnapshot.maxPropertyBytes + 10)
        let event = MGMEvent(name: "grapheme", properties: [pathological: "bad", "readable": "yes"])
        XCTAssertEqual(event.properties?.count, 1)
        XCTAssertEqual(event.properties?["readable"]?.value as? String, "yes")
        XCTAssertEqual((AnyCodable(String(repeating: "😀", count: 1000)).value as? String)?.count, 1000)
    }

    func testJSONPreflightIgnoresQuotedBracketsAndRejectsHugeDepth() {
        XCTAssertTrue(JSONSafety.accepts(Data("{\"text\":\"[[]]\\\"{\"}".utf8)))
        XCTAssertFalse(JSONSafety.accepts(Data((String(repeating: "[", count: 20_000) + "0" + String(repeating: "]", count: 20_000)).utf8)))
        XCTAssertFalse(JSONSafety.accepts(Data(repeating: 32, count: JSONSafety.maxBytes + 1)))
    }

    func testStorageRejectsUnsafeCacheAndRecoversWithNewEvents() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((String(repeating: "[", count: 20_000) + "0" + String(repeating: "]", count: 20_000)).utf8).write(to: url)
        let storage = FileEventStorage(maxEvents: 2, fileURL: url)
        XCTAssertEqual(storage.eventCount(), 0)
        storage.store(event: MGMEvent(name: "recovery"))
        XCTAssertEqual(storage.fetchEvents(limit: 10).map(\.name), ["recovery"])
    }

    func testStorageClampsNegativeBoundsAndReentrantReads() {
        let zero = InMemoryEventStorage(maxEvents: -1)
        zero.store(event: MGMEvent(name: "ignored"))
        XCTAssertEqual(zero.eventCount(), 0)
        XCTAssertTrue(zero.fetchEvents(limit: -1).isEmpty)
        let storage = InMemoryEventStorage()
        let done = expectation(description: "reentrant callback")
        storage.store(event: MGMEvent(name: "one")) { count in
            XCTAssertEqual(count, storage.eventCount())
            XCTAssertEqual(storage.fetchEvents(limit: 1).count, 1)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testProviderReentryDoesNotRecursivelyInvokeProvider() {
        let box = ReentrantClientBox()
        let storage = InMemoryEventStorage()
        let configuration = MGMConfiguration(apiKey: "offline", maxBatchSize: 1000,
            trackAppLifecycleEvents: false, contextProvider: {
                box.calls += 1
                box.client?.track("nested")
                return ["context": "yes"]
            })
        let client = MostlyGoodMetrics(configuration: configuration, storage: storage, networkClient: HostNoNetworkClient())
        box.client = client
        client.optIn()
        client.track("outer")
        XCTAssertEqual(box.calls, 1)
        let events = storage.fetchEvents(limit: 10)
        XCTAssertEqual(events.map(\.name), ["nested", "outer"])
        XCTAssertNil(events.first?.properties?["context"])
        XCTAssertEqual(events.last?.properties?["context"]?.value as? String, "yes")
    }

    func testCyclicSuperPropertiesAndCorruptSavedJSONRecover() {
        let client = MostlyGoodMetrics(configuration: MGMConfiguration(apiKey: "offline", trackAppLifecycleEvents: false),
            storage: InMemoryEventStorage(), networkClient: HostNoNetworkClient())
        client.clearSuperProperties()
        defer { client.clearSuperProperties() }
        let cycle = NSMutableDictionary()
        cycle["self"] = cycle
        client.setSuperProperties(["cycle": cycle, "readable": "yes"])
        cycle.removeAllObjects()
        XCTAssertEqual(client.getSuperProperties()["readable"] as? String, "yes")
        UserDefaults.standard.set(Data((String(repeating: "[", count: 20_000) + "0" + String(repeating: "]", count: 20_000)).utf8), forKey: "MGM_superProperties")
        XCTAssertTrue(client.getSuperProperties().isEmpty)
        client.setSuperProperty("after", value: "recovery")
        XCTAssertEqual(client.getSuperProperties()["after"] as? String, "recovery")
    }

    func testProviderReentryGuardIsPerThreadAndResetsAfterCalls() {
        let box = ConcurrentProviderBox()
        let storage = InMemoryEventStorage(maxEvents: 1000)
        let configuration = MGMConfiguration(apiKey: "offline", maxBatchSize: 1000,
            trackAppLifecycleEvents: false, contextProvider: {
                box.recordCall()
                box.client?.track("nested_thread")
                return ["context": "yes"]
            }, collectDeviceProperties: false)
        let client = MostlyGoodMetrics(configuration: configuration, storage: storage, networkClient: HostNoNetworkClient())
        box.client = client
        client.optIn()
        client.clearSuperProperties()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in client.track("outer_thread") }
        XCTAssertEqual(box.calls, 100)
        let events = storage.fetchEvents(limit: 1000)
        XCTAssertEqual(events.filter { $0.name == "outer_thread" && $0.properties?["context"]?.value as? String == "yes" }.count, 100)
        XCTAssertEqual(events.filter { $0.name == "nested_thread" }.count, 100)
        client.track("outer_thread")
        XCTAssertEqual(box.calls, 101)
    }

    func testConcurrentTrackAndMutableSnapshotRecovery() {
        let storage = InMemoryEventStorage(maxEvents: 1000)
        let client = MostlyGoodMetrics(configuration: MGMConfiguration(apiKey: "offline", maxBatchSize: 1000, trackAppLifecycleEvents: false),
            storage: storage, networkClient: HostNoNetworkClient())
        client.optIn()
        client.clearSuperProperties()
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in 0..<50 { client.track("worker_\(worker)_\(index)", properties: ["value": [index]]) }
        }
        let events = storage.fetchEvents(limit: 1000)
        XCTAssertGreaterThan(events.count, 0)
        XCTAssertLessThanOrEqual(events.count, 400)
        XCTAssertEqual(Set(events.map(\.clientEventId)).count, events.count)
        client.track("after_concurrency")
        XCTAssertEqual(storage.fetchEvents(limit: 1000).last?.name, "after_concurrency")
    }

    func testConcurrentSharedInstallationAndTrackingKeepCapturedIdentity() {
        let previous = MostlyGoodMetrics.shared
        defer { MostlyGoodMetrics.installSharedInstance(previous) }
        let storages = (0..<8).map { _ in InMemoryEventStorage(maxEvents: 1000) }
        let clients = storages.enumerated().map { index, storage -> MostlyGoodMetrics in
            let client = MostlyGoodMetrics(configuration: MGMConfiguration(apiKey: "offline", maxBatchSize: 1000, trackAppLifecycleEvents: false, collectDeviceProperties: false),
                storage: storage, networkClient: HostNoNetworkClient())
            client.userId = "shared_user_\(index)"
            return client
        }
        for _ in 0..<5 {
            DispatchQueue.concurrentPerform(iterations: 400) { index in
                MostlyGoodMetrics.installSharedInstance(clients[index % clients.count])
                MostlyGoodMetrics.track("shared_track")
                XCTAssertNotNil(MostlyGoodMetrics.shared)
            }
            var count = 0
            for (index, storage) in storages.enumerated() {
                let events = storage.fetchEvents(limit: 1000)
                count += events.count
                XCTAssertTrue(events.allSatisfy { $0.userId == "shared_user_\(index)" })
                storage.clear()
                XCTAssertEqual(storage.eventCount(), 0)
            }
            XCTAssertEqual(count, 400)
        }
    }

    func testReplacedSharedInstanceTearsDownOutsideSharedLock() {
        let previous = MostlyGoodMetrics.shared
        defer { MostlyGoodMetrics.installSharedInstance(previous) }
        let released = expectation(description: "Storage teardown can read shared")
        var original: MostlyGoodMetrics? = MostlyGoodMetrics(configuration: MGMConfiguration(apiKey: "offline", trackAppLifecycleEvents: false),
            storage: SharedReadOnDeinitStorage(released: released), networkClient: HostNoNetworkClient())
        weak var weakOriginal = original
        MostlyGoodMetrics.installSharedInstance(original)
        original = nil
        let replacement = MostlyGoodMetrics(configuration: MGMConfiguration(apiKey: "offline", trackAppLifecycleEvents: false),
            storage: InMemoryEventStorage(), networkClient: HostNoNetworkClient())
        let replaced = expectation(description: "Reconfiguration returns")
        DispatchQueue.global().async {
            MostlyGoodMetrics.installSharedInstance(replacement)
            replaced.fulfill()
        }
        wait(for: [released, replaced], timeout: 3)
        XCTAssertNil(weakOriginal)
        XCTAssertTrue(MostlyGoodMetrics.shared === replacement)
    }

    func testNonfiniteAndExcessiveReadinessTimeoutsResolve() async {
        let client = MostlyGoodMetrics(configuration: MGMConfiguration(apiKey: "offline", trackAppLifecycleEvents: false),
            storage: InMemoryEventStorage(), networkClient: HostNoNetworkClient(), skipExperimentsLoad: true)
        for timeout in [Double.infinity, -Double.infinity, Double.nan, Double.greatestFiniteMagnitude, -1, 0] {
            await client.ready(timeout: timeout)
        }
        // Repeated timeouts should release their waiters even if no response arrives.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 { group.addTask { await client.ready(timeout: 0) } }
        }
    }

    func testBlockedStorageBoundsPendingPayloadsAndRecovers() {
        let storage = InMemoryEventStorage(maxEvents: 10_000)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        storage.store(event: MGMEvent(name: "blocker")) { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        for index in 0..<10_000 { storage.store(event: MGMEvent(name: "pending_\(index)")) }
        release.signal()
        // Drains admitted operations. Some overload was dropped before dispatch,
        // rather than retaining every closure/payload behind the blocked writer.
        XCTAssertNotEqual(storage.fetchEvents(limit: 10_000).last?.name, "pending_9999")
        storage.store(event: MGMEvent(name: "after_backpressure"))
        XCTAssertEqual(storage.fetchEvents(limit: 10_000).last?.name, "after_backpressure")
    }

    func testStorageByteBudgetRetainsNewestEvents() {
        let storage = InMemoryEventStorage(maxEvents: 10_000)
        let payload = String(repeating: "x", count: 1000)
        for index in 0..<500 {
            storage.store(event: MGMEvent(name: "event_\(index)", properties: ["value": payload]))
        }
        let events = storage.fetchEvents(limit: 10_000)
        XCTAssertLessThan(events.count, 500)
        XCTAssertEqual(events.last?.name, "event_499")
        XCTAssertLessThanOrEqual(events.reduce(0) { $0 + EventMemoryBudget.weight($1) }, EventMemoryBudget.maxBytes)
    }
}

// A synchronous reentry fixture, never transferred between threads.
private final class ReentrantClientBox: @unchecked Sendable {
    weak var client: MostlyGoodMetrics?
    var calls = 0
}

private final class HostNoNetworkClient: NetworkClientProtocol {
    func sendEvents(_ events: [MGMEvent], context: MGMEventContext?, completion: @escaping (Result<Void, MGMError>) -> Void) {
        completion(.failure(.invalidResponse))
    }
    func fetchExperiments(userId: String, anonymousId: String?, completion: @escaping (Result<[String: String], MGMError>) -> Void) {
        completion(.success([:]))
    }
    func fetchExperimentConfigs(completion: @escaping (Result<[MGMExperimentConfig], MGMError>) -> Void) { completion(.success([])) }
}

private final class ConcurrentProviderBox: @unchecked Sendable {
    weak var client: MostlyGoodMetrics? // Published once before worker threads start.
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func recordCall() { lock.lock(); count += 1; lock.unlock() }
}

private final class SharedReadOnDeinitStorage: EventStorage {
    let released: XCTestExpectation
    init(released: XCTestExpectation) { self.released = released }
    deinit { _ = MostlyGoodMetrics.shared; released.fulfill() }
    func store(event: MGMEvent, completion: ((Int) -> Void)?) { completion?(0) }
    func fetchEvents(limit: Int) -> [MGMEvent] { [] }
    func removeEvents(_ events: [MGMEvent]) {}
    func eventCount() -> Int { 0 }
    func clear() {}
}
