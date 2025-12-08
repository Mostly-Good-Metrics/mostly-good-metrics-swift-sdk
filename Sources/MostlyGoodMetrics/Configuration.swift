import Foundation

/// Configuration options for the MostlyGoodMetrics SDK
public struct MGMConfiguration {
    /// The API key for authentication (required)
    public let apiKey: String

    /// The base URL for the API endpoint
    public let baseURL: URL

    /// The environment (e.g., "production", "staging", "development")
    public var environment: String

    /// Optional bundle ID override (defaults to main bundle identifier)
    public var bundleId: String?

    /// Maximum number of events to batch before sending (max 1000)
    public var maxBatchSize: Int

    /// Interval in seconds between automatic flush attempts
    public var flushInterval: TimeInterval

    /// Maximum number of events to store locally before dropping oldest
    public var maxStoredEvents: Int

    /// Whether to enable debug logging
    public var enableDebugLogging: Bool

    /// Whether to automatically track app lifecycle events (default: true)
    /// Tracks: app_installed, app_updated, app_opened, app_backgrounded
    public var trackAppLifecycleEvents: Bool

    /// The wrapper SDK name (e.g., "react-native", "flutter", "expo")
    /// Used by hybrid framework SDKs to identify themselves
    public var wrapperName: String?

    /// The wrapper SDK version
    /// Used by hybrid framework SDKs to identify their version
    public var wrapperVersion: String?

    /// Default API base URL
    public static let defaultBaseURL = URL(string: "https://mostlygoodmetrics.com")!

    /// Creates a new configuration with the specified API key
    /// - Parameters:
    ///   - apiKey: The API key for authentication
    ///   - baseURL: The base URL for the API (defaults to production)
    ///   - environment: The environment name (defaults to "production")
    ///   - bundleId: Optional bundle ID override
    ///   - maxBatchSize: Maximum events per batch (defaults to 100, max 1000)
    ///   - flushInterval: Seconds between auto-flush (defaults to 30)
    ///   - maxStoredEvents: Maximum cached events (defaults to 10000)
    ///   - enableDebugLogging: Whether to enable debug logging (defaults to false)
    ///   - trackAppLifecycleEvents: Whether to auto-track lifecycle events (defaults to true)
    ///   - wrapperName: Optional wrapper SDK name (e.g., "react-native", "flutter")
    ///   - wrapperVersion: Optional wrapper SDK version
    public init(
        apiKey: String,
        baseURL: URL = MGMConfiguration.defaultBaseURL,
        environment: String = "production",
        bundleId: String? = nil,
        maxBatchSize: Int = 100,
        flushInterval: TimeInterval = 30,
        maxStoredEvents: Int = 10000,
        enableDebugLogging: Bool = false,
        trackAppLifecycleEvents: Bool = true,
        wrapperName: String? = nil,
        wrapperVersion: String? = nil
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.environment = environment
        self.bundleId = bundleId
        self.maxBatchSize = min(max(1, maxBatchSize), 1000)
        self.flushInterval = max(1, flushInterval)
        self.maxStoredEvents = max(100, maxStoredEvents)
        self.enableDebugLogging = enableDebugLogging
        self.trackAppLifecycleEvents = trackAppLifecycleEvents
        self.wrapperName = wrapperName
        self.wrapperVersion = wrapperVersion
    }
}
