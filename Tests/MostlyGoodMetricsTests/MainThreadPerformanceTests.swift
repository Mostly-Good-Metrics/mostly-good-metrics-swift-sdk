import XCTest
@testable import MostlyGoodMetrics

final class MainThreadPerformanceTests: XCTestCase {
    private final class NonCompletingNetworkClient: NetworkClientProtocol {
        func sendEvents(
            _ events: [MGMEvent],
            context: MGMEventContext?,
            completion: @escaping (Result<Void, MGMError>) -> Void
        ) {}

        func fetchExperiments(
            userId: String,
            anonymousId: String?,
            completion: @escaping (Result<[String: String], MGMError>) -> Void
        ) {
            completion(.success([:]))
        }

        func fetchExperimentConfigs(
            completion: @escaping (Result<[MGMExperimentConfig], MGMError>) -> Void
        ) {
            completion(.success([]))
        }
    }

    private struct Scenario {
        let name: String
        let eventCount: Int
        let cleanupCount: Int
    }

    func testTrackDoesNotBlockMainThreadOnStorage() throws {
        guard ProcessInfo.processInfo.environment["MGM_RUN_PERFORMANCE_TESTS"] == "1" else {
            throw XCTSkip("Set MGM_RUN_PERFORMANCE_TESTS=1 to run timing-sensitive storage regression coverage")
        }

        let scenarios = [
            Scenario(name: "100 events", eventCount: 100, cleanupCount: 0),
            Scenario(name: "1,000 events", eventCount: 1_000, cleanupCount: 0),
            Scenario(name: "10,000 events", eventCount: 10_000, cleanupCount: 0),
            Scenario(name: "10,000 events + 100-event cleanup in flight", eventCount: 10_000, cleanupCount: 100)
        ]
        var results: [(String, Double)] = []

        for scenario in scenarios {
            let samples = try (0..<5).map { sample in
                try measureTrackLatency(scenario: scenario, sample: sample)
            }
            let median = samples.sorted()[samples.count / 2]
            results.append((scenario.name, median))
        }

        print("\nMain-thread track() latency (release build, median of 5)")
        print("| Scenario | Median |")
        print("|---|---:|")
        for result in results {
            print("| \(result.0) | \(String(format: "%.3f ms", result.1)) |")
            XCTAssertLessThan(
                result.1,
                5,
                "\(result.0): track() must not synchronously wait for storage work on the main thread"
            )
        }

        let largePayloadMedian = measureLargePayloadTrackLatency()
        print("| 400-property payload | \(String(format: "%.3f ms", largePayloadMedian)) |")
        XCTAssertLessThan(
            largePayloadMedian,
            5,
            "Large property capture must remain within the caller-thread budget"
        )
    }

    private func measureTrackLatency(scenario: Scenario, sample: Int) throws -> Double {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgm-track-benchmark-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("events.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let events = (0..<scenario.eventCount).map { MGMEvent(name: "queued_\($0)") }
        try JSONEncoder().encode(events).write(to: fileURL, options: .atomic)

        let storage = FileEventStorage(maxEvents: 10_000, fileURL: fileURL)
        XCTAssertEqual(storage.eventCount(), scenario.eventCount)

        if scenario.cleanupCount > 0 {
            storage.removeEvents(Array(events.prefix(scenario.cleanupCount)))
        }

        let configuration = MGMConfiguration(
            apiKey: "benchmark",
            maxBatchSize: 1_000,
            maxStoredEvents: 10_000
        )
        let client = MostlyGoodMetrics(
            configuration: configuration,
            storage: storage,
            networkClient: NonCompletingNetworkClient()
        )

        var elapsed = 0.0
        let measurement = {
            let start = DispatchTime.now().uptimeNanoseconds
            client.track("main_thread_event", properties: ["sample": sample])
            elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }

        if Thread.isMainThread {
            measurement()
        } else {
            DispatchQueue.main.sync(execute: measurement)
        }

        _ = storage.eventCount() // Drain storage work before removing the temporary file.
        return elapsed
    }

    private func measureLargePayloadTrackLatency() -> Double {
        let properties = Dictionary(uniqueKeysWithValues: (0..<400).map {
            ("property_\($0)", String(repeating: "x", count: 64))
        })
        let storage = InMemoryEventStorage(maxEvents: 100)
        let client = MostlyGoodMetrics(
            configuration: MGMConfiguration(apiKey: "benchmark", maxBatchSize: 1_000),
            storage: storage,
            networkClient: NonCompletingNetworkClient()
        )
        var samples: [Double] = []

        for _ in 0..<25 {
            var elapsed = 0.0
            let measurement = {
                let start = DispatchTime.now().uptimeNanoseconds
                client.track("large_payload", properties: properties)
                elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            if Thread.isMainThread {
                measurement()
            } else {
                DispatchQueue.main.sync(execute: measurement)
            }
            samples.append(elapsed)
        }

        _ = storage.eventCount()
        return samples.sorted()[samples.count / 2]
    }
}
