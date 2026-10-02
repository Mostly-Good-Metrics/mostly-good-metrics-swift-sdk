import Foundation
@testable import MostlyGoodMetrics

@main
struct Swift6Consumer {
    // A real Swift 6 caller of the Swift 5.9 library. Dynamic actor isolation
    // checks are enabled by Swift 6 even without the test compiler flag.
    @MainActor
    static func main() async {
        await verifyContextProviders()
        if CommandLine.arguments.contains("--context-provider-only") { return }
        let configuration = MGMConfiguration(
            apiKey: "test", trackAppLifecycleEvents: false,
            experimentMode: .local,
            localExperiments: [MGMExperimentConfig(id: "smoke", name: "smoke", variants: ["control"])],
            optedOutByDefault: true
        )
        // Only setup uses test-only injection: exercise the public callback
        // without touching the host application's persisted event queue or network.
        let client = MostlyGoodMetrics(
            configuration: configuration,
            storage: InMemoryEventStorage(),
            networkClient: NoNetworkClient()
        )
        let timeout = Task { @MainActor in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            fatalError("Flush callback did not complete within five seconds")
        }
        var completed = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            client.flush { result in
                MainActor.assertIsolated()
                precondition(Thread.isMainThread)
                if case .failure(let error) = result {
                    fatalError("Unexpected flush error: \(error)")
                }
                completed = true
                continuation.resume()
            }
        }
        let observer = FlushObserver()
        await observer.flush(using: FlushClientTransfer(client: client))
        let observerCount = await observer.completionCount
        precondition(observerCount == 1, "Custom actor did not receive its explicit completion hop")
        timeout.cancel()
        withExtendedLifetime(client) {}
        precondition(completed)
        print("Swift 6 inline MainActor completion and explicit custom-actor hop passed")
    }
}

final class NoNetworkClient: NetworkClientProtocol {
    func sendEvents(_ events: [MGMEvent], context: MGMEventContext?,
                    completion: @escaping (Result<Void, MGMError>) -> Void) {
        preconditionFailure("The empty consumer smoke test must not send events")
    }

    func fetchExperiments(userId: String, anonymousId: String?,
                          completion: @escaping (Result<[String: String], MGMError>) -> Void) {
        completion(.success([:]))
    }

    func fetchExperimentConfigs(completion: @escaping (Result<[MGMExperimentConfig], MGMError>) -> Void) {
        completion(.success([]))
    }
}

// The injected client has no timers or lifecycle observers; its empty flushes
// serialize their state internally. This fixture-only transfer does not declare
// the public SDK client Sendable.
private struct FlushClientTransfer: @unchecked Sendable {
    let client: MostlyGoodMetrics
}

private actor FlushObserver {
    private(set) var completionCount = 0

    func flush(using transfer: FlushClientTransfer) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // The SDK's contextual type must make this inline callback MainActor
            // isolated even though it is created inside another actor.
            transfer.client.flush { result in
                MainActor.assertIsolated()
                if case .failure(let error) = result {
                    fatalError("Unexpected custom-actor flush error: \(error)")
                }
                Task { await self.recordCompletion(continuation) }
            }
        }
    }

    private func recordCompletion(_ continuation: CheckedContinuation<Void, Never>) {
        completionCount += 1
        continuation.resume()
    }
}
