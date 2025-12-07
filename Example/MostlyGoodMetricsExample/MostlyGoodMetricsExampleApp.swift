import SwiftUI
import MostlyGoodMetrics

@main
struct MostlyGoodMetricsExampleApp: App {
    init() {
        // Configure MostlyGoodMetrics with debug logging enabled
        let config = MGMConfiguration(
            apiKey: "your-api-key-here",
            environment: "development",
            enableDebugLogging: true,
            trackAppLifecycleEvents: true
        )
        MostlyGoodMetrics.configure(with: config)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
