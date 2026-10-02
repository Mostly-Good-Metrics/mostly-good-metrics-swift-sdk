import XCTest
@testable import MostlyGoodMetrics

final class NetworkConcurrencyTests: XCTestCase {
    private final class RateLimitURLProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var _requestCount = 0
        static var requestCount: Int { lock.withLock { _requestCount } }
        private static var retryAfter = "60"
        private static var onRequest: (() -> Void)?

        static func reset(retryAfter: String = "60", onRequest: (() -> Void)? = nil) {
            lock.withLock {
                _requestCount = 0
                Self.retryAfter = retryAfter
                Self.onRequest = onRequest
            }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let state = Self.lock.withLock {
                Self._requestCount += 1
                return (Self.retryAfter, Self._requestCount <= 8 ? Self.onRequest : nil)
            }
            state.1?()
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": state.0]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testRateLimitFromURLSessionAppliesToConcurrentSends() {
        RateLimitURLProtocol.reset()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RateLimitURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let network = NetworkClient(configuration: MGMConfiguration(apiKey: "test"), session: session)
        let events = [MGMEvent(name: "queued")]
        let limited = expectation(description: "URLSession received rate limit")

        network.sendEvents(events, context: nil) { @Sendable result in
            guard case .failure(.rateLimited(let retryAfter)) = result else {
                XCTFail("Expected rate limit from URLSession")
                limited.fulfill()
                return
            }
            XCTAssertEqual(retryAfter, 60)
            limited.fulfill()
        }
        wait(for: [limited], timeout: 5)

        let backedOff = expectation(description: "Concurrent requests respect backoff")
        backedOff.expectedFulfillmentCount = 50
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            network.sendEvents(events, context: nil) { @Sendable result in
                guard case .failure(.rateLimited(let retryAfter)) = result else {
                    XCTFail("Expected cached rate limit")
                    backedOff.fulfill()
                    return
                }
                XCTAssertGreaterThan(retryAfter, 0)
                XCTAssertLessThanOrEqual(retryAfter, 60)
                backedOff.fulfill()
            }
        }
        wait(for: [backedOff], timeout: 5)
        XCTAssertEqual(RateLimitURLProtocol.requestCount, 1)
    }

    func testRateLimitResponsesOverlapConcurrentBackoffReads() {
        let requestsStarted = expectation(description: "Initial requests waiting for responses")
        requestsStarted.expectedFulfillmentCount = 8
        RateLimitURLProtocol.reset(onRequest: { requestsStarted.fulfill() })
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RateLimitURLProtocol.self]
        // Suspend completion delivery, rather than calling URLProtocol clients
        // outside startLoading, so the stub follows Foundation lifecycle rules.
        let callbacks = OperationQueue()
        callbacks.maxConcurrentOperationCount = 1
        callbacks.isSuspended = true
        let session = URLSession(configuration: sessionConfiguration, delegate: nil, delegateQueue: callbacks)
        defer {
            callbacks.isSuspended = false
            session.invalidateAndCancel()
        }
        let network = NetworkClient(configuration: MGMConfiguration(apiKey: "test"), session: session)
        let events = [MGMEvent(name: "queued")]
        let completed = expectation(description: "All requests rate limited")
        completed.expectedFulfillmentCount = 8
        let completion: @Sendable (Result<Void, MGMError>) -> Void = { result in
            if case .failure(.rateLimited(let retryAfter)) = result {
                XCTAssertGreaterThan(retryAfter, 0)
                XCTAssertLessThanOrEqual(retryAfter, 60)
            } else {
                XCTFail("Expected rate limit")
            }
            completed.fulfill()
        }
        for _ in 0..<8 { network.sendEvents(events, context: nil, completion: completion) }
        wait(for: [requestsStarted], timeout: 5)

        // Keep independent readers running while URLSession delivers 429 writes.
        // Reader callbacks deliberately avoid expectation locks, which could
        // accidentally order the accesses and hide a missing backoff lock.
        // Explicit reader threads avoid concurrentPerform's core-count-limited
        // worker pool: waiting for more workers than cores otherwise deadlocks.
        let readerCount = 2
        let readersStarted = DispatchSemaphore(value: 0)
        let stopReaders = DispatchSemaphore(value: 0)
        defer { for _ in 0..<readerCount { stopReaders.signal() } }
        let readersFinished = expectation(description: "Concurrent readers finished")
        readersFinished.expectedFulfillmentCount = readerCount
        for _ in 0..<readerCount {
            Thread.detachNewThread {
                readersStarted.signal()
                while stopReaders.wait(timeout: .now()) != .success {
                    network.sendEvents(events, context: nil) { @Sendable _ in }
                }
                readersFinished.fulfill()
            }
        }
        for _ in 0..<readerCount {
            XCTAssertEqual(readersStarted.wait(timeout: .now() + 5), .success)
        }
        callbacks.isSuspended = false
        wait(for: [completed], timeout: 5)
        for _ in 0..<readerCount { stopReaders.signal() }
        wait(for: [readersFinished], timeout: 5)
    }

    @MainActor
    func testMalformedRetryAfterDoesNotCrashFlushWithLoggingDisabled() {
        let defaults = UserDefaults.standard
        let previousOptOut = defaults.object(forKey: "MGM_optedOut")
        defaults.removeObject(forKey: "MGM_optedOut")
        defer {
            if let previousOptOut { defaults.set(previousOptOut, forKey: "MGM_optedOut") }
            else { defaults.removeObject(forKey: "MGM_optedOut") }
        }

        for header in ["NaN", "inf", "-inf", "1e300", "-1", "86401", "invalid", ""] {
            RateLimitURLProtocol.reset(retryAfter: header)
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.protocolClasses = [RateLimitURLProtocol.self]
            let session = URLSession(configuration: sessionConfiguration)
            defer { session.invalidateAndCancel() }
            let configuration = MGMConfiguration(apiKey: "test", enableDebugLogging: false)
            let storage = InMemoryEventStorage()
            storage.store(event: MGMEvent(name: "queued"))
            let network = NetworkClient(configuration: configuration, session: session)
            let client = MostlyGoodMetrics(configuration: configuration, storage: storage, networkClient: network)
            let completed = expectation(description: "Malformed Retry-After: \(header)")
            client.flush { result in
                if case .failure(.rateLimited(let retryAfter)) = result {
                    XCTAssertEqual(retryAfter, 60, "Invalid header must use safe fallback: \(header)")
                } else {
                    XCTFail("Expected rate limit for header \(header)")
                }
                XCTAssertEqual(storage.eventCount(), 1, "Rate-limited events must remain queued")
                completed.fulfill()
            }
            wait(for: [completed], timeout: 5)
        }
    }

    func testRateLimitDescriptionHandlesInvalidPublicIntervals() {
        for interval in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, Double(Int.max), -1] {
            let description = MGMError.rateLimited(retryAfter: interval).localizedDescription
            XCTAssertTrue(description.contains("Rate limited"))
        }
        XCTAssertTrue(MGMError.rateLimited(retryAfter: 1.5).localizedDescription.contains("1 seconds"))
    }

}
