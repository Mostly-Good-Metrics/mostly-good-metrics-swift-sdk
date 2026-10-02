import XCTest
@testable import MostlyGoodMetrics

// Every access to mutable state is synchronized, including the provider read.
final class LockedContextValue: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String
    init(_ value: String) { storedValue = value }
    var value: String {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

final class ContextProviderConcurrencyTests: XCTestCase {
    func testConcurrentTrackingCapturesSynchronizedContextSnapshots() {
        let defaults = UserDefaults.standard
        let previousOptOut = defaults.object(forKey: "MGM_optedOut")
        defaults.removeObject(forKey: "MGM_optedOut")
        defer {
            if let previousOptOut { defaults.set(previousOptOut, forKey: "MGM_optedOut") }
            else { defaults.removeObject(forKey: "MGM_optedOut") }
        }
        let context = LockedContextValue("snapshot_initial")
        let configuration = MGMConfiguration(
            apiKey: "test", maxBatchSize: 1000,
            contextProvider: { ["snapshot": context.value] }
        )
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(
            configuration: configuration, storage: storage, networkClient: MockNetworkClient(result: .success(()))
        )
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            context.value = "snapshot_\(index)"
            client.track("concurrent_context")
        }
        let events = storage.fetchEvents(limit: 1000)
        XCTAssertEqual(events.count, 200)
        XCTAssertTrue(events.allSatisfy {
            ($0.properties?["snapshot"]?.value as? String)?.hasPrefix("snapshot_") == true
        })
    }
}
