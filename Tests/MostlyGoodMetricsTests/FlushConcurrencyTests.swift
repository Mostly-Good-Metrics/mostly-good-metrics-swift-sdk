import XCTest
@testable import MostlyGoodMetrics

final class FlushConcurrencyTests: XCTestCase {
    @MainActor
    func testEmptyFlushCompletionCanAccessMainActorState() {
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(
            configuration: MGMConfiguration(apiKey: "test"),
            storage: storage,
            networkClient: MockNetworkClient(result: .success(()))
        )
        let completed = expectation(description: "Main actor completion")
        var callbackCount = 0

        client.flush { result in
            // This closure inherits MainActor isolation. Before the fix, runtime
            // actor checks trap here, before any assertion can execute.
            callbackCount += 1
            XCTAssertTrue(Thread.isMainThread)
            if case .failure(let error) = result { XCTFail("Unexpected error: \(error)") }
            completed.fulfill()
        }

        wait(for: [completed], timeout: 5)
        XCTAssertEqual(callbackCount, 1)
    }

    @MainActor
    func testSuccessfulFlushCompletionCanAccessMainActorState() {
        checkNetworkCompletion(result: .success(()), expectedPendingCount: 0)
    }

    @MainActor
    func testFailedFlushCompletionCanAccessMainActorState() {
        checkNetworkCompletion(result: .failure(.serverError(503, "Retry later")), expectedPendingCount: 1)
    }

    @MainActor
    func testPermanentFailureCompletionCanAccessMainActorState() {
        checkNetworkCompletion(result: .failure(.unauthorized), expectedPendingCount: 0)
    }

    @MainActor
    private func checkNetworkCompletion(result: Result<Void, MGMError>, expectedPendingCount: Int) {
        let storage = InMemoryEventStorage()
        storage.store(event: MGMEvent(name: "queued"))
        let client = MostlyGoodMetrics(
            configuration: MGMConfiguration(apiKey: "test"),
            storage: storage,
            networkClient: MockNetworkClient(result: result)
        )
        let completed = expectation(description: "Main actor network completion")
        var callbackCount = 0

        client.flush { actual in
            callbackCount += 1
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertFalse(client.isFlushing)
            XCTAssertEqual(storage.eventCount(), expectedPendingCount)
            switch (result, actual) {
            case (.success, .success), (.failure(.unauthorized), .failure(.unauthorized)): break
            case (.failure(.serverError(let expectedCode, let expectedMessage)),
                  .failure(.serverError(let actualCode, let actualMessage))):
                XCTAssertEqual(actualCode, expectedCode)
                XCTAssertEqual(actualMessage, expectedMessage)
            default: XCTFail("Flush result changed during dispatch")
            }
            completed.fulfill()
        }

        wait(for: [completed], timeout: 5)
        XCTAssertEqual(callbackCount, 1)
    }

    @MainActor
    func testOptedOutFlushCompletionCanAccessMainActorState() {
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(
            configuration: MGMConfiguration(apiKey: "test", optedOutByDefault: true),
            storage: storage,
            networkClient: MockNetworkClient(result: .success(()))
        )
        let completed = expectation(description: "Opted-out main actor completion")
        var callbackCount = 0
        client.flush { _ in
            callbackCount += 1
            XCTAssertTrue(Thread.isMainThread)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
        XCTAssertEqual(callbackCount, 1)
    }

    // This mock can complete inline on the flush queue or asynchronously on
    // an unrelated queue, and protects all state used by the test threads.
    private final class ControlledNetworkClient: NetworkClientProtocol {
        private let lock = NSLock()
        private var pending: ((Result<Void, MGMError>) -> Void)?
        private var _sendCount = 0
        let started: XCTestExpectation
        private let immediateResult: Result<Void, MGMError>?

        init(started: XCTestExpectation, immediateResult: Result<Void, MGMError>? = nil) {
            self.started = started
            self.immediateResult = immediateResult
        }
        var sendCount: Int { lock.withLock { _sendCount } }

        func sendEvents(_ events: [MGMEvent], context: MGMEventContext?,
                        completion: @escaping (Result<Void, MGMError>) -> Void) {
            lock.withLock {
                _sendCount += 1
                pending = completion
            }
            started.fulfill()
            if let immediateResult { complete(immediateResult) }
        }

        func complete(_ result: Result<Void, MGMError>) {
            let handler = lock.withLock {
                let handler = pending
                pending = nil
                return handler
            }
            handler?(result)
        }

        func fetchExperiments(userId: String, anonymousId: String?,
                              completion: @escaping (Result<[String: String], MGMError>) -> Void) {
            completion(.success([:]))
        }

        func fetchExperimentConfigs(completion: @escaping (Result<[MGMExperimentConfig], MGMError>) -> Void) {
            completion(.success([]))
        }
    }

    @MainActor
    func testConcurrentFlushesDoNotDuplicateAnInFlightBatch() {
        let storage = InMemoryEventStorage()
        storage.store(event: MGMEvent(name: "queued"))
        let started = expectation(description: "First batch started")
        let network = ControlledNetworkClient(started: started)
        let client = MostlyGoodMetrics(
            configuration: MGMConfiguration(apiKey: "test"), storage: storage, networkClient: network
        )
        let finished = expectation(description: "First batch completed")
        client.flush { _ in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertFalse(client.isFlushing)
            XCTAssertEqual(storage.eventCount(), 0)
            finished.fulfill()
        }
        wait(for: [started], timeout: 5)
        XCTAssertTrue(client.isFlushing)

        let skipped = expectation(description: "Concurrent flushes completed")
        skipped.expectedFulfillmentCount = 50
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            client.flush { _ in
                XCTAssertTrue(Thread.isMainThread)
                skipped.fulfill()
            }
        }
        wait(for: [skipped], timeout: 5)
        XCTAssertEqual(network.sendCount, 1)
        DispatchQueue.global().async { network.complete(.success(())) }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(network.sendCount, 1)
    }

    @MainActor
    func testBackgroundCallerAlsoReceivesMainQueueCompletion() {
        let storage = InMemoryEventStorage()
        let client = MostlyGoodMetrics(
            configuration: MGMConfiguration(apiKey: "test"),
            storage: storage, networkClient: MockNetworkClient(result: .success(()))
        )
        let finished = expectation(description: "Background caller completed")
        DispatchQueue.global().async {
            client.flush { _ in
                XCTAssertTrue(Thread.isMainThread)
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 5)
    }


    @MainActor
    func testInlineNetworkCompletionDoesNotDeadlockFlushQueue() {
        let storage = InMemoryEventStorage()
        storage.store(event: MGMEvent(name: "queued"))
        let started = expectation(description: "Inline batch started")
        let network = ControlledNetworkClient(started: started, immediateResult: .success(()))
        let client = MostlyGoodMetrics(
            configuration: MGMConfiguration(apiKey: "test"), storage: storage, networkClient: network
        )
        let finished = expectation(description: "Inline batch completed")
        client.flush { _ in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertFalse(client.isFlushing)
            XCTAssertEqual(storage.eventCount(), 0)
            finished.fulfill()
        }
        wait(for: [started, finished], timeout: 5)
        XCTAssertEqual(network.sendCount, 1)
    }

}
