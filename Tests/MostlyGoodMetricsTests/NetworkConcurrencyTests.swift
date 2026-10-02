import XCTest
@testable import MostlyGoodMetrics

final class NetworkConcurrencyTests: XCTestCase {
    private final class RateLimitURLProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var _requestCount = 0
        static var requestCount: Int { lock.withLock { _requestCount } }
        static func reset() { lock.withLock { _requestCount = 0 } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.withLock { Self._requestCount += 1 }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "60"]
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
}
