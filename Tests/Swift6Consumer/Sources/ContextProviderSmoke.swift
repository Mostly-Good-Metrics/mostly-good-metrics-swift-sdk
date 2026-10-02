import Foundation
@testable import MostlyGoodMetrics

// Deliberately cross the original unannotated Swift 5 callback boundary. This
// immutable test-only wrapper lets the same fixture reproduce the pre-fix trap;
// production callers must use the SDK's Sendable provider type instead.
private struct ProviderBoundary: @unchecked Sendable {
    let callback: () -> [String: Any]
}

// The injected client has no timers, lifecycle observers, or networking. Only
// one detached task uses it, and main waits for that task before inspecting it.
// This wrapper does not declare the production SDK client concurrency-safe.
private struct TrackingBoundary: @unchecked Sendable {
    let client: MostlyGoodMetrics
    let storage: InMemoryEventStorage
}

extension Swift6Consumer {
    @MainActor
    static func verifyContextProviders() async {
        // Volatile argument-domain overrides prevent preference-dependent no-ops
        // and anonymous-ID generation without writing host preferences.
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var overrides = original
        overrides["MGM_optedOut"] = false
        overrides["MGM_anonymousId"] = "$anon_swift6consumer"
        defaults.setVolatileDomain(overrides, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }

        let build = "consumer-build"
        // No explicit @Sendable on either literal: both public SDK declarations
        // must provide the annotation that prevents inherited MainActor isolation.
        let initialized = MGMConfiguration(
            apiKey: "test",
            contextProvider: {
                let isolation: (any Actor)? = #isolation
                precondition(isolation == nil, "Initializer provider inherited actor isolation")
                return ["build": build, "source": "initializer"]
            }
        )
        var assigned = MGMConfiguration(apiKey: "test")
        assigned.contextProvider = {
            let isolation: (any Actor)? = #isolation
            precondition(isolation == nil, "Stored provider inherited actor isolation")
            return ["build": build, "source": "property"]
        }

        for (source, configuration) in [("initializer", initialized), ("property", assigned)] {
            let provider = ProviderBoundary(callback: configuration.contextProvider!)
            let invoked = await Task.detached {
                let properties = provider.callback()
                return properties["build"] as? String == build && properties["source"] as? String == source
            }.value
            precondition(invoked, "Detached provider invocation failed: \(source)")

            let storage = InMemoryEventStorage()
            let client = MostlyGoodMetrics(
                configuration: configuration, storage: storage, networkClient: NoNetworkClient()
            )
            precondition(!client.isOptedOut, "Tracking regression must not pass by opting out")
            let boundary = TrackingBoundary(client: client, storage: storage)
            let captured = await Task.detached {
                boundary.client.track("background_context")
                let events = boundary.storage.fetchEvents(limit: 10)
                guard events.count == 1, let event = events.first else { return false }
                return event.properties?["build"]?.value as? String == build
                    && event.properties?["source"]?.value as? String == source
            }.value
            precondition(captured, "Background event lost context: \(source)")
        }
        print("Swift 6 MainActor-created context providers passed detached invocation and tracking")
    }
}
