import XCTest
@testable import MostlyGoodMetrics

final class IdentityConcurrencyTests: XCTestCase {
    private var savedDefaults: [String: Any] = [:]
    private let defaultKeys = ["MGM_optedOut", "MGM_userId", "MGM_anonymousId", "MGM_localExperimentAssignments"]

    override func setUp() {
        super.setUp()
        for key in defaultKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        UserDefaults.standard.removeObject(forKey: "MGM_optedOut")
    }

    override func tearDown() {
        for key in defaultKeys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private final class RetainingNetworkClient: NetworkClientProtocol {
        func sendEvents(_ events: [MGMEvent], context: MGMEventContext?,
                        completion: @escaping (Result<Void, MGMError>) -> Void) {
            completion(.failure(.serverError(503, "Keep the test events queued")))
        }
        func fetchExperiments(userId: String, anonymousId: String?,
                              completion: @escaping (Result<[String: String], MGMError>) -> Void) {
            completion(.success([:]))
        }
        func fetchExperimentConfigs(completion: @escaping (Result<[MGMExperimentConfig], MGMError>) -> Void) {
            completion(.success([]))
        }
    }

    func testConcurrentSessionChangesAndTrackingKeepValidCapturedSessions() {
        let storage = InMemoryEventStorage(maxEvents: 2000)
        let client = MostlyGoodMetrics(
            configuration: MGMConfiguration(apiKey: "test", maxBatchSize: 1000, collectDeviceProperties: false),
            storage: storage, networkClient: RetainingNetworkClient()
        )

        // This previously produced a String data race and a swift_release crash.
        // Stay below the private retained-byte ceiling while exercising real threads.
        DispatchQueue.concurrentPerform(iterations: 1000) { index in
            if index.isMultiple(of: 2) { client.startNewSession() }
            else { client.track("parallel") }
        }

        let events = storage.fetchEvents(limit: 2000)
        XCTAssertEqual(events.count, 500)
        XCTAssertTrue(events.allSatisfy { UUID(uuidString: $0.sessionId ?? "") != nil })
        XCTAssertEqual(Set(events.map(\.clientEventId)).count, events.count)
    }

    func testConcurrentIdentityMutationsTrackingAndFlushesRemainSafe() {
        let storage = InMemoryEventStorage(maxEvents: 1000)
        let client = MostlyGoodMetrics(
            configuration: MGMConfiguration(apiKey: "test", experimentMode: .local, collectDeviceProperties: false),
            storage: storage, networkClient: RetainingNetworkClient()
        )

        DispatchQueue.concurrentPerform(iterations: 800) { index in
            switch index % 4 {
            case 0: client.identify(userId: "user-\(index)")
            case 1:
                client.resetIdentity()
                client.resetAnonymousId()
            case 2: client.startNewSession()
            default:
                client.track("parallel")
                client.flush()
            }
            _ = client.userId
            _ = client.anonymousId
            _ = client.sessionId
        }

        let events = storage.fetchEvents(limit: 1000)
        XCTAssertEqual(events.count, 200)
        XCTAssertTrue(events.allSatisfy { $0.userId?.hasPrefix("user-") == true || $0.userId?.hasPrefix("$anon_") == true })
        XCTAssertTrue(events.allSatisfy { UUID(uuidString: $0.sessionId ?? "") != nil })
    }

    // Assigned once before the provider is published to background callers.
    // The weak reference avoids a client/configuration/provider retain cycle.
    private final class ClientReference: @unchecked Sendable {
        weak var client: MostlyGoodMetrics?
    }

    func testContextProviderCanReenterIdentityWithoutDeadlocking() {
        let reference = ClientReference()
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(
            configuration: MGMConfiguration(apiKey: "test", contextProvider: { [reference] in
                reference.client?.userId = "provider-user"
                reference.client?.startNewSession()
                return ["provider-session": reference.client?.sessionId ?? ""]
            }),
            storage: storage, networkClient: RetainingNetworkClient()
        )
        reference.client = client
        let completed = expectation(description: "Reentrant provider returns")
        DispatchQueue.global().async {
            client.track("reentrant")
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)

        let event = storage.fetchEvents(limit: 1).first
        XCTAssertEqual(event?.userId, "provider-user")
        XCTAssertEqual(event?.sessionId, event?.properties?["provider-session"]?.value as? String)
    }
    private final class IdentityDefaultsObserver: NSObject {
        let client: MostlyGoodMetrics
        let completed: XCTestExpectation

        init(client: MostlyGoodMetrics, completed: XCTestExpectation) {
            self.client = client
            self.completed = completed
        }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                   change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            // Ignore the nested notification from the main-thread identity update.
            guard change?[.newKey] as? String == "observer-user" else { return }
            XCTAssertEqual(client.userId, "observer-user")
            // A background setter invokes this synchronously. A UI observer must
            // be able to set identity too, without waiting on a background SDK lock.
            DispatchQueue.main.sync {
                self.client.userId = "main-user"
                XCTAssertEqual(self.client.userId, "main-user")
            }
            completed.fulfill()
        }
    }

    @MainActor
    func testDefaultsObserverCanSetIdentityOnMainWithoutDeadlocking() {
        let client = MostlyGoodMetrics(
            configuration: MGMConfiguration(apiKey: "test"),
            storage: InMemoryEventStorage(), networkClient: RetainingNetworkClient()
        )
        let completed = expectation(description: "Synchronous defaults observer updated identity")
        let setterReturned = expectation(description: "Background identity setter returned")
        let observer = IdentityDefaultsObserver(client: client, completed: completed)
        UserDefaults.standard.addObserver(observer, forKeyPath: "MGM_userId", options: [.new], context: nil)
        defer { UserDefaults.standard.removeObserver(observer, forKeyPath: "MGM_userId") }
        DispatchQueue.global().async {
            client.userId = "observer-user"
            setterReturned.fulfill()
        }
        wait(for: [completed, setterReturned], timeout: 5)
        XCTAssertEqual(client.userId, "main-user")
    }

}
