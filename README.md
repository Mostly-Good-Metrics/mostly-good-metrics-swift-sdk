# MostlyGoodMetrics Swift SDK

A lightweight Swift SDK for tracking analytics events with [MostlyGoodMetrics](https://mostlygoodmetrics.com).

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
  - [Swift Package Manager](#swift-package-manager)
  - [CocoaPods](#cocoapods)
- [Quick Start](#quick-start)
  - [UIKit Initialization](#uikit-initialization)
  - [SwiftUI Initialization](#swiftui-initialization)
- [Configuration Options](#configuration-options)
- [Automatic Behavior](#automatic-behavior)
- [Automatic Events](#automatic-events)
- [Automatic Context](#automatic-context)
- [Event Naming](#event-naming)
- [Properties](#properties)
- [Manual Flush](#manual-flush)
- [Debug Logging](#debug-logging)
- [License](#license)

## Requirements

- iOS 14.0+ / macOS 11.0+ / tvOS 14.0+ / watchOS 7.0+
- Swift 5.9+

## Installation

### Swift Package Manager

Add the following to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Mostly-Good-Metrics/mostly-good-metrics-swift-sdk", from: "1.0.0")
]
```

Or in Xcode: **File > Add Package Dependencies** and enter the repository URL.

### CocoaPods

Add to your `Podfile`:

```ruby
pod 'MostlyGoodMetrics', '~> 0.6.1'
```

Then run:

```bash
pod install
```

## Quick Start

### 1. Initialize the SDK

Initialize once at app launch:

#### UIKit Initialization

In your `AppDelegate`:

```swift
import UIKit
import MostlyGoodMetrics

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        MostlyGoodMetrics.configure(apiKey: "mgm_proj_your_api_key")
        return true
    }
}
```

#### SwiftUI Initialization

In your `@main` App struct:

```swift
import SwiftUI
import MostlyGoodMetrics

@main
struct MyApp: App {
    init() {
        MostlyGoodMetrics.configure(apiKey: "mgm_proj_your_api_key")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

### 2. Track Events

```swift
// Simple event
MostlyGoodMetrics.track("button_clicked")

// Event with properties
MostlyGoodMetrics.track("purchase_completed", properties: [
    "product_id": "SKU123",
    "price": 29.99,
    "currency": "USD"
])
```

### 3. Identify Users

```swift
// Set user identity
MostlyGoodMetrics.identify(userId: "user_123")

// Reset identity (e.g., on logout)
MostlyGoodMetrics.shared?.resetIdentity()
```

That's it! Events are automatically batched and sent.

## Configuration Options

For more control, use `MGMConfiguration`:

```swift
let config = MGMConfiguration(
    apiKey: "mgm_proj_your_api_key",
    baseURL: URL(string: "https://mostlygoodmetrics.com")!,
    environment: "production",
    maxBatchSize: 100,
    flushInterval: 30,
    maxStoredEvents: 10000,
    enableDebugLogging: false,
    trackAppLifecycleEvents: true
)

MostlyGoodMetrics.configure(with: config)
```

| Option | Default | Description |
|--------|---------|-------------|
| `apiKey` | Required | Your API key |
| `baseURL` | `https://mostlygoodmetrics.com` | API endpoint |
| `environment` | `"production"` | Environment name |
| `bundleId` | App's bundle ID | Override bundle identifier |
| `maxBatchSize` | `100` | Events per batch (1-1000) |
| `flushInterval` | `30` | Auto-flush interval in seconds |
| `maxStoredEvents` | `10000` | Max cached events |
| `enableDebugLogging` | `false` | Enable console output |
| `trackAppLifecycleEvents` | `true` | Auto-track lifecycle events |

## Automatic Behavior

The SDK handles event delivery and lifecycle management automatically:

### Event Processing

- **Persists events** to disk, surviving app restarts and crashes
- **Batches events** for efficient network usage (default: 100 events per batch)
- **Compresses payloads** using gzip for requests > 1KB
- **Validates events** and drops invalid ones with debug logging

### Network & Reliability

- **Flushes on interval** (default: every 30 seconds)
- **Flushes on background** when the app resigns active
- **Retries on failure** for network errors (events are preserved)
- **Handles rate limiting** by respecting `Retry-After` headers
- **Drops client errors** (4xx responses except rate limits) to prevent bad data buildup

### Session & Identity

- **Generates session IDs** once per app launch
- **Persists user ID** across app launches via UserDefaults
- **Generates anonymous IDs** (`$anon_xxxxxxxxxxxx` format) for unidentified users
- **Debounces `$identify` events** to avoid redundant server calls (only sends if data changed or >24h elapsed)

### Lifecycle Events

When `trackAppLifecycleEvents` is enabled (default):

- **`$app_installed`**: Tracked on first launch after install
- **`$app_updated`**: Tracked on first launch after version change
- **`$app_opened`**: Tracked when app becomes active (foreground)
- **`$app_backgrounded`**: Tracked when app resigns active (background)

**macOS Debouncing**: On macOS, window focus changes happen frequently (Cmd-Tab, clicking other windows). To prevent excessive events:
- `$app_backgrounded` is **not tracked** on macOS
- `$app_opened` is only tracked if the app was inactive for **at least 5 seconds**

> **Note:** Events are still flushed on every focus change regardless of debouncing.

### Thread Safety

The SDK is fully thread-safe. All methods can be called from any thread:
- Event tracking uses internal queues for safe concurrent access
- Flush operations are serialized to prevent race conditions
- Storage operations are atomic

## Automatic Events

When `trackAppLifecycleEvents` is enabled (default), the SDK automatically tracks:

| Event | When | Properties |
|-------|------|------------|
| `$app_installed` | First launch after install | `$version` |
| `$app_updated` | First launch after version change | `$version`, `$previous_version` |
| `$app_opened` | App became active (foreground) | - |
| `$app_backgrounded` | App resigned active (background) | - |

### macOS Lifecycle Event Behavior

On macOS, window focus changes happen frequently (Cmd-Tab, clicking other windows, etc.), which would generate excessive lifecycle events. To address this, the SDK applies debouncing on macOS:

- **`$app_backgrounded`**: Not tracked on macOS (focus changes are too frequent)
- **`$app_opened`**: Only tracked if the app was inactive for **at least 5 seconds**

This ensures you get meaningful "app opened" events when users return to your app after a meaningful absence, without noise from quick window switches.

> **Note:** Events are still flushed on every focus change regardless of debouncing, ensuring data is reliably sent to the server.

## Automatic Context

Every event automatically includes:

| Field | Example | Description |
|-------|---------|-------------|
| `client_event_id` | `"550e8400-e29b..."` | Unique UUID for deduplication |
| `timestamp` | `2024-01-15T10:30:00.000Z` | ISO 8601 event timestamp |
| `platform` | `"ios"` | Platform (ios, macos, tvos, watchos, visionos) |
| `os_version` | `"17.1"` | Operating system version |
| `app_version` | `"1.0.0"` | App version (CFBundleShortVersionString) |
| `app_build_number` | `"42"` | App build number (CFBundleVersion) |
| `environment` | `"production"` | Environment from configuration |
| `session_id` | `"uuid..."` | Unique session ID (generated per app launch) |
| `user_id` | `"user_123"` | User ID (if set via `identify()`) or anonymous ID |
| `device_manufacturer` | `"Apple"` | Device manufacturer |
| `locale` | `"en_US"` | User's locale from device settings |
| `timezone` | `"America/New_York"` | User's timezone from device settings |
| `$device_type` | `"phone"` | Device type (phone, tablet, desktop, tv, watch, vision, carplay) |
| `$device_model` | `"iPhone15,2"` | Device model hardware identifier |
| `$sdk` | `"swift"` | SDK identifier ("swift" or wrapper name if applicable) |

> **Note:** The `$` prefix indicates reserved system events and properties. Avoid using `$` prefix for your own custom events.

## Event Naming

Event names must:
- Start with a letter (or `$` for system events)
- Contain only alphanumeric characters and underscores
- Be 255 characters or less

```swift
// Valid
MostlyGoodMetrics.track("button_clicked")
MostlyGoodMetrics.track("PurchaseCompleted")
MostlyGoodMetrics.track("step_1_completed")

// Invalid (will be ignored)
MostlyGoodMetrics.track("123_event")      // starts with number
MostlyGoodMetrics.track("event-name")     // contains hyphen
MostlyGoodMetrics.track("event name")     // contains space
```

## Properties

Events support various property types:

```swift
MostlyGoodMetrics.track("checkout", properties: [
    "string_prop": "value",
    "int_prop": 42,
    "double_prop": 3.14,
    "bool_prop": true,
    "list_prop": ["a", "b", "c"],
    "nested": [
        "key": "value"
    ]
])
```

**Limits:**
- String values: truncated to 1000 characters
- Nesting depth: max 3 levels
- Total properties size: max 10KB

## Manual Flush

Events are automatically flushed periodically and when the app backgrounds. You can also trigger a manual flush:

```swift
MostlyGoodMetrics.shared?.flush { result in
    switch result {
    case .success:
        print("Events flushed successfully")
    case .failure(let error):
        print("Flush failed: \(error.localizedDescription)")
    }
}
```

## Debug Logging

Enable debug logging to see SDK activity:

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
[MostlyGoodMetrics] Tracked event: button_clicked
[MostlyGoodMetrics] Flushing 4 events
[MostlyGoodMetrics] Successfully flushed 4 events
```

## License

MIT
