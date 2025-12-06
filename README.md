# MostlyGoodMetrics Swift SDK

A lightweight Swift SDK for tracking analytics events with [MostlyGoodMetrics](https://mostlygoodmetrics.com).

## Requirements

- iOS 14.0+ / macOS 11.0+ / tvOS 14.0+ / watchOS 7.0+
- Swift 5.9+

## Installation

### Swift Package Manager

Add the following to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/your-org/mostly-good-metrics-swift", from: "1.0.0")
]
```

Or in Xcode: File > Add Package Dependencies and enter the repository URL.

## Quick Start

### 1. Configure the SDK

Initialize the SDK once at app launch (e.g., in `AppDelegate` or `@main` App struct):

```swift
import MostlyGoodMetrics

// Simple configuration
MostlyGoodMetrics.configure(apiKey: "mgm_proj_your_api_key")
```

### 2. Track Events

```swift
// Basic event
MostlyGoodMetrics.track("app_opened")

// Event with properties
MostlyGoodMetrics.track("button_clicked", properties: [
    "screen": "home",
    "button_id": "signup_cta"
])
```

### 3. Identify Users (Optional)

```swift
// After user logs in
MostlyGoodMetrics.identify(userId: "user_123")

// After user logs out
MostlyGoodMetrics.shared?.resetIdentity()
```

## Configuration Options

For more control, use `MGMConfiguration`:

```swift
let config = MGMConfiguration(
    apiKey: "mgm_proj_your_api_key",
    baseURL: URL(string: "https://mostlygoodmetrics.com")!,  // Custom API endpoint
    environment: "production",      // "production", "staging", "development"
    bundleId: nil,                  // Override bundle ID (optional)
    maxBatchSize: 100,              // Events per batch (max 1000)
    flushInterval: 30,              // Seconds between auto-flush
    maxStoredEvents: 10000,         // Max cached events
    enableDebugLogging: false,      // Enable console logging
    trackAppLifecycleEvents: true   // Auto-track lifecycle events (default: true)
)

MostlyGoodMetrics.configure(with: config)
```

## API Reference

### MostlyGoodMetrics

| Method | Description |
|--------|-------------|
| `configure(apiKey:)` | Initialize with API key using defaults |
| `configure(with:)` | Initialize with custom configuration |
| `track(_:properties:)` | Track an event with optional properties |
| `identify(userId:)` | Set the user ID for subsequent events |
| `resetIdentity()` | Clear the current user ID |
| `startNewSession()` | Start a new session |
| `flush(completion:)` | Manually send pending events |
| `clearPendingEvents()` | Discard all pending events |
| `pendingEventCount` | Number of events waiting to be sent |

### Event Names

Event names must:
- Start with a letter (a-z, A-Z)
- Contain only alphanumeric characters and underscores
- Be 255 characters or less

Examples: `app_opened`, `buttonClicked`, `purchase_completed`

### Event Properties

Properties support:
- Strings (truncated to 1000 chars)
- Numbers (Int, Double)
- Booleans
- Nested dictionaries (max 3 levels deep)
- Arrays

Total properties size limit: 10KB

## Automatic Behavior

The SDK automatically:

- **Persists events** to disk, surviving app restarts
- **Batches events** for efficient network usage
- **Flushes on interval** (default: every 30 seconds)
- **Flushes on background** when the app resigns active
- **Retries on failure** for network errors (events are preserved)
- **Compresses payloads** using gzip for requests > 1KB
- **Handles rate limiting** by respecting `Retry-After` headers
- **Persists user ID** across app launches
- **Generates session IDs** per app launch

## Automatic Lifecycle Events

By default, the SDK automatically tracks these lifecycle events (disable with `trackAppLifecycleEvents: false`):

| Event | When | Properties |
|-------|------|------------|
| `$app_installed` | First launch ever | `$version` |
| `$app_updated` | First launch after version change | `$version`, `$previous_version` |
| `$app_opened` | App becomes active (foreground) | - |
| `$app_backgrounded` | App resigns active (background) | - |

## Automatic Context

Every event automatically includes:

| Field | Example | Description |
|-------|---------|-------------|
| `platform` | `"ios"` | Platform (ios, macos, tvos, watchos, visionos) |
| `os_version` | `"17.1"` | Operating system version |
| `app_version` | `"1.0.0 (42)"` | App version with build number |
| `environment` | `"production"` | Environment from configuration |
| `session_id` | `"uuid..."` | Unique session ID (per app launch) |
| `user_id` | `"user_123"` | User ID (if set via `identify()`) |

Additionally, every event includes these system properties:

| Property | Example | Description |
|----------|---------|-------------|
| `$device_type` | `"phone"` | Device type (phone, tablet, desktop, tv, watch, vision) |
| `$device_model` | `"iPhone15,2"` | Device model identifier |

> **Note:** The `$` prefix indicates reserved system events and properties. Avoid using `$` prefix for your own custom events.

## Multiple Instances

While the shared instance covers most use cases, you can create separate instances:

```swift
let analytics = MostlyGoodMetrics(configuration: MGMConfiguration(
    apiKey: "mgm_proj_different_key"
))

analytics.track("custom_event")
```

## Debug Logging

Enable debug logging to see SDK activity in the console:

```swift
let config = MGMConfiguration(
    apiKey: "mgm_proj_your_api_key",
    enableDebugLogging: true
)
MostlyGoodMetrics.configure(with: config)
```

Output example:
```
[MostlyGoodMetrics] Initialized with 3 cached events
[MostlyGoodMetrics] Tracked event: app_opened
[MostlyGoodMetrics] Flushing 4 events
[MostlyGoodMetrics] Successfully flushed 4 events
```

## Error Handling

The SDK is designed to never crash your app. Errors are handled gracefully:

- **Invalid event names** are silently dropped (logged in debug mode)
- **Network failures** preserve events for retry
- **Rate limiting** respects server backoff
- **Client errors (4xx)** drop invalid events to prevent loops

For manual flush with error handling:

```swift
MostlyGoodMetrics.shared?.flush { result in
    switch result {
    case .success:
        print("Events sent successfully")
    case .failure(let error):
        print("Flush failed: \(error.localizedDescription)")
    }
}
```

## License

MIT
