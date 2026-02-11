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
- [User Identification](#user-identification)
- [Configuration Options](#configuration-options)
- [Automatic Events](#automatic-events)
- [Automatic Context](#automatic-context)
- [Automatic Behavior](#automatic-behavior)
- [Event Naming](#event-naming)
- [Properties](#properties)
- [Manual Flush](#manual-flush)
- [Debug Logging](#debug-logging)
- [Thread Safety](#thread-safety)
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

### 2. Identify Users

```swift
// Set user identity
MostlyGoodMetrics.identify(userId: "user_123")

// Reset identity (e.g., on logout)
MostlyGoodMetrics.shared?.resetIdentity()
```

### 3. Track Events

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

That's it! Events are automatically batched and sent.

## User Identification

Associate events with specific users by calling `identify()`:

```swift
// Set user identity
MostlyGoodMetrics.identify(userId: "user_123")
```

**Identity Persistence:**
- User IDs persist across app launches via UserDefaults
- The user ID is included in all subsequent events as the `user_id` field

**Anonymous Users:**
- Before calling `identify()`, users are tracked with an auto-generated anonymous ID
- Format: `$anon_xxxxxxxxxxxx` (12 random alphanumeric characters)
- Anonymous IDs persist across app launches

**Reset Identity:**

Clear the user identity on logout:

```swift
MostlyGoodMetrics.shared?.resetIdentity()
```

This clears the persisted user ID and resets to anonymous tracking. Events will use the anonymous ID until `identify()` is called again.

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

Every event automatically includes contextual information to provide rich analytics capabilities. You don't need to manually add these fields.

### Identity & Session

| Field | Description | Example | Persistence |
|-------|-------------|---------|-------------|
| `user_id` | Identified user ID (set via `identify()`) or anonymous ID | `user_123` or `$anon_abc123def456` | Persisted in UserDefaults (survives app restarts) |
| `session_id` | UUID generated per app launch | `a1b2c3d4-e5f6-7890-abcd-ef1234567890` | Regenerated on each app launch |

### Device & Platform

| Field | Description | Example | Source |
|-------|-------------|---------|--------|
| `platform` | Platform identifier | `ios`, `macos`, `tvos`, `watchos`, `visionos` | System platform detection |
| `os_version` | Operating system version | `17.1`, `14.3` | `ProcessInfo.operatingSystemVersion` |
| `device_manufacturer` | Device manufacturer | `Apple` | Always "Apple" for Apple platforms |
| `locale` | User's locale from device settings | `en_US`, `fr_FR` | `Locale.current.identifier` |
| `timezone` | User's timezone from device settings | `America/New_York`, `Europe/Paris` | `TimeZone.current.identifier` |
| `$device_type` | Device type category | `phone`, `tablet`, `desktop`, `tv`, `watch`, `vision`, `carplay` | Device idiom detection |
| `$device_model` | Device model hardware identifier | `iPhone15,2`, `MacBookPro18,3` | System model identifier |

### App & Environment

| Field | Description | Example | Source |
|-------|-------------|---------|--------|
| `app_version` | App version | `1.0.0` | `CFBundleShortVersionString` from Info.plist |
| `app_build_number` | App build number | `42` | `CFBundleVersion` from Info.plist |
| `environment` | Environment name | `production`, `staging`, `development` | Configuration option (default: `production`) |

### Event Metadata

| Field | Description | Example | Purpose |
|-------|-------------|---------|---------|
| `client_event_id` | Unique UUID for each event | `550e8400-e29b-41d4-a716-446655440000` | Deduplication (prevents processing the same event twice) |
| `timestamp` | ISO 8601 timestamp when event was tracked | `2024-01-15T10:30:00.000Z` | Event ordering and time-based analysis |
| `$sdk` | SDK identifier | `swift` | Identifies events from this SDK |

> **Note:** The `$` prefix indicates reserved system properties and events. Avoid using `$` prefix for your own custom properties.

## Automatic Behavior

The SDK automatically handles common tasks so you can focus on tracking what matters:

**Event Management:**
- **Event persistence** - Events are saved to disk and survive app restarts and crashes
- **Batch processing** - Events are grouped into batches (default: 100 events per batch)
- **Periodic flush** - Events are sent every 30 seconds (configurable via `flushInterval`)
- **Automatic flush on batch size** - Events flush immediately when batch size is reached
- **Background flush** - Events are automatically flushed when the app goes to background (resigns active)
- **Retry on failure** - Failed requests are retried; events are preserved until successfully sent
- **Payload compression** - Large batches (>1KB) are automatically gzip compressed
- **Rate limiting** - Exponential backoff when rate limited by the server (respects `Retry-After` headers)
- **Event validation** - Invalid events are dropped with debug logging
- **Deduplication** - Events include unique IDs (`client_event_id`) to prevent duplicate processing

**Lifecycle Tracking:**
- **App lifecycle events** - Automatically tracks `$app_opened`, `$app_backgrounded`, `$app_installed`, and `$app_updated`
- **Install/update detection** - Tracks first install and version changes by comparing stored version with current
- **Session management** - New session ID generated on each app launch and persisted for the entire session

**macOS Debouncing:**

On macOS, window focus changes happen frequently (Cmd-Tab, clicking other windows). To prevent excessive events:
- `$app_backgrounded` is **not tracked** on macOS
- `$app_opened` is only tracked if the app was inactive for **at least 5 seconds**

> **Note:** Events are still flushed on every focus change regardless of debouncing.

**User & Identity:**
- **User ID persistence** - User identity set via `identify()` persists across app launches in UserDefaults
- **Anonymous ID** - Auto-generated anonymous ID (`$anon_xxxxxxxxxxxx`) for users before identification
- **Anonymous ID persistence** - Anonymous IDs persist across app launches

**Context Collection:**
- **Automatic context** - Every event includes platform, OS version, device info, locale, timezone, etc.
- **Dynamic context** - Context like app version and build number are collected at event time

## Event Naming

Event names must:
- Start with a letter (or `$` for system events)
- Contain only alphanumeric characters and underscores
- Be 255 characters or less

> **Reserved `$` prefix:** The `$` prefix is reserved for system events (e.g., `$app_opened`). Avoid using `$` for your own custom event names.

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

## Thread Safety

The SDK is fully thread-safe. All public methods can be called from any thread:

```swift
// Safe to call from any thread
DispatchQueue.global(qos: .background).async {
    MostlyGoodMetrics.track("background_event")
}

DispatchQueue.main.async {
    MostlyGoodMetrics.identify(userId: "user_123")
}
```

**Thread Safety Implementation:**
- Event tracking uses internal serial queues for safe concurrent access
- Flush operations are serialized to prevent race conditions
- Storage operations are atomic and use thread-safe mechanisms
- All configuration and state management is protected with proper synchronization

> **Note:** While the SDK is thread-safe, it's recommended to call `configure()` once at app launch on the main thread before making other SDK calls.

## License

MIT
