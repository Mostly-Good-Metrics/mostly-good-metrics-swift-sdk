import XCTest
import Foundation
@testable import MostlyGoodMetrics

final class BoundedResponseTests: XCTestCase {
    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedResponseProtocol.self]
        return configuration
    }

    private func session(_ responses: BoundedResponses) -> URLSession {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration(), delegate: responses, delegateQueue: queue)
    }

    func testDeclaredAndChunkedOverflowCompleteOnceCancelAndRecover() {
        let responses = BoundedResponses()
        let session = session(responses)
        defer { session.invalidateAndCancel() }
        for path in ["declared", "chunked"] {
            let failed = expectation(description: "\(path) rejected once")
            failed.assertForOverFulfill = true
            let request = URLRequest(url: URL(string: "https://transport-test.invalid/\(path)")!)
            responses.task(in: session, request: request) { data, _, error in
                XCTAssertNil(data)
                XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
                failed.fulfill()
            }?.resume()
            wait(for: [failed], timeout: 3)
            let recovered = expectation(description: "Same session recovers after \(path)")
            responses.task(in: session, request: URLRequest(url: URL(string: "https://transport-test.invalid/recovery")!)) { data, _, error in
                XCTAssertNil(error)
                XCTAssertEqual(String(decoding: data ?? Data(), as: UTF8.self), "{\"assigned_variants\":{\"experiment\":\"control\"}}")
                recovered.fulfill()
            }?.resume()
            wait(for: [recovered], timeout: 3)
        }
    }

    func testConcurrentAdmissionIsBoundedAndCancellationCompletesOnce() {
        let responses = BoundedResponses()
        let session = session(responses)
        defer { session.invalidateAndCancel() }
        let cancelled = expectation(description: "Admitted requests cancel once")
        cancelled.expectedFulfillmentCount = 8
        cancelled.assertForOverFulfill = true
        let request = URLRequest(url: URL(string: "https://transport-test.invalid/hold")!)
        let collector = ResponseTaskCollector()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            collector.append(responses.task(in: session, request: request) { _, _, error in
                XCTAssertEqual((error as? URLError)?.code, .cancelled)
                cancelled.fulfill()
            }!)
        }
        let tasks = collector.tasks
        for task in tasks { task.resume() }
        let rejected = expectation(description: "Ninth request rejected before body allocation")
        rejected.expectedFulfillmentCount = 20_000
        rejected.assertForOverFulfill = true
        for _ in 0..<20_000 {
            XCTAssertNil(responses.task(in: session, request: request) { _, _, error in
                XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
                rejected.fulfill()
            })
        }
        let countObserved = expectation(description: "Rejected calls create no Foundation tasks")
        session.getAllTasks { tasks in
            XCTAssertEqual(tasks.count, 8)
            countObserved.fulfill()
        }
        wait(for: [countObserved], timeout: 3)
        for task in tasks { task.cancel() }
        wait(for: [cancelled, rejected], timeout: 3)
        let recovered = expectation(description: "Admission recovers after cancellation")
        responses.task(in: session, request: URLRequest(url: URL(string: "https://transport-test.invalid/recovery")!)) { _, _, error in
            XCTAssertNil(error)
            recovered.fulfill()
        }?.resume()
        wait(for: [recovered], timeout: 3)
    }

    func testSDKOwnedOversizeResponsesReportNetworkFailure() {
        for path in ["declared", "chunked"] {
            let client = NetworkClient(configuration: MGMConfiguration(apiKey: "offline", baseURL: URL(string: "https://transport-test.invalid/\(path)")!), sessionConfiguration: configuration())
            let failed = expectation(description: "SDK \(path) fails safely")
            failed.assertForOverFulfill = true
            client.fetchExperiments(userId: "offline", anonymousId: nil) { result in
                if case .failure(.networkError(let error)) = result {
                    XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
                } else { XCTFail("Expected bounded transport network failure") }
                failed.fulfill()
            }
            wait(for: [failed], timeout: 3)
            withExtendedLifetime(client) {}
        }
    }

    func testSDKOwnedTransportPreservesHeadersAndResponseHandling() {
        let sessionConfig = configuration()
        let client = NetworkClient(configuration: MGMConfiguration(apiKey: "offline", baseURL: URL(string: "https://transport-test.invalid/recovery")!), sessionConfiguration: sessionConfig)
        XCTAssertEqual(sessionConfig.timeoutIntervalForRequest, 30)
        XCTAssertEqual(sessionConfig.timeoutIntervalForResource, 60)
        let sent = expectation(description: "204 event response")
        client.sendEvents([MGMEvent(name: "offline")], context: nil) { result in
            if case .failure(let error) = result { XCTFail("Unexpected failure: \(error)") }
            sent.fulfill()
        }
        let assignments = expectation(description: "Experiment response")
        client.fetchExperiments(userId: "offline", anonymousId: nil) { result in
            if case .success(let variants) = result { XCTAssertEqual(variants["experiment"], "control") }
            else { XCTFail("Expected bounded experiment response") }
            assignments.fulfill()
        }
        wait(for: [sent, assignments], timeout: 3)
    }
}

private final class BoundedResponseProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "transport-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let declared = url.path.hasPrefix("/declared")
        let chunked = url.path.hasPrefix("/chunked")
        let event = url.path.hasSuffix("/events")
        if url.path.contains("/v1/") {
            if event {
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-MGM-Key"), "offline")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-MGM-SDK-Version"), sdkVersion)
            } else { XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer offline") }
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains(sdkVersion) == true)
        }
        let headers = declared ? ["Content-Length": String(JSONSafety.maxBytes + 1)] : [:]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: event ? 204 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        if declared { client?.urlProtocol(self, didLoad: Data([32])); client?.urlProtocolDidFinishLoading(self); return }
        if url.path == "/hold" { return }
        if chunked {
            DispatchQueue.global().async {
                let chunk = Data(repeating: 32, count: 64 * 1024)
                for _ in 0..<32 {
                    let active = self.lock.withLock { !self.stopped }
                    guard active else { return }
                    self.client?.urlProtocol(self, didLoad: chunk)
                    Thread.sleep(forTimeInterval: 0.001)
                }
                self.client?.urlProtocolDidFinishLoading(self)
            }
        } else {
            if !event { client?.urlProtocol(self, didLoad: Data("{\"assigned_variants\":{\"experiment\":\"control\"}}".utf8)) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}

private final class ResponseTaskCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLSessionDataTask] = []
    var tasks: [URLSessionDataTask] { lock.withLock { values } }
    func append(_ task: URLSessionDataTask) { lock.withLock { values.append(task) } }
}
