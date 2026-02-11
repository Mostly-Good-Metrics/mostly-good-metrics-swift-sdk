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
- [User Identification](#user-identification)
- [Tracking Events](#tracking-events)
- [Automatic Events](#automatic-events)
- [Automatic Context](#automatic-context)
- [Event Naming](#event-naming)
- [Properties](#properties)
- [Debug Logging](#debug-logging)
- [Automatic Behavior](#automatic-behavior)
- [Manual Flush](#manual-flush)
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

## Tracking Events

Track custom events with optional properties:

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

Events are automatically enriched with context (platform, OS version, device info, etc.) and batched for efficient delivery.

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

Every event automatically includes the following context properties:

| Field | Example | Description |
|-------|---------|-------------|
| `client_event_id` | `"550e8400-e29b..."` | Unique UUID for deduplication |
| `timestamp` | `2024-01-15T10:30:00.000Z` | ISO 8601 event timestamp |
| `platform` | `"ios"` | Platform (ios, macos, tvos, watchos, visionos) |
| `os_version` | `"17.1"` | Operating system version |
| `app_version` | `"1.0.0"` | App version (CFBundleShortVersionString) |
| `app_build_number` | `"42"` | App build number (CFBundleVersion) |
| `environment` | `"production"` | Environment name from configuration |
| `session_id` | `"uuid..."` | Unique session ID (generated per app launch) |
| `user_id` | `"user_123"` or `"$anon_xxx"` | User ID (set via `identify()`) or anonymous ID |
| `device_manufacturer` | `"Apple"` | Device manufacturer |
| `locale` | `"en_US"` | User's locale from device settings |
| `timezone` | `"America/New_York"` | User's timezone from device settings |
| `$device_type` | `"phone"` | Device type (phone, tablet, desktop, tv, watch, vision, carplay) |
| `$device_model` | `"iPhone15,2"` | Device model hardware identifier |
| `$sdk` | `"swift"` | SDK identifier ("swift" or wrapper name if applicable) |

> **Note:** The `$` prefix indicates reserved system properties and events. Avoid using `$` prefix for your own custom properties.

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

## Automatic Behavior

The SDK automatically handles the following without any additional configuration:

**Event Management:**
- **Event persistence** - Events are saved to disk and survive app restarts and crashes
- **Batch processing** - Events are grouped into batches (default: 100 events per batch)
- **Periodic flush** - Events are sent every 30 seconds (configurable via `flushInterval`)
- **Automatic flush on batch size** - Events flush immediately when batch size is reached
- **Retry on failure** - Failed requests are retried; events are preserved until successfully sent
- **Payload compression** - Large batches (>1KB) are automatically gzip compressed
- **Rate limiting** - Exponential backoff when rate limited by the server (respects `Retry-After` headers)
- **Deduplication** - Events include unique IDs (`client_event_id`) to prevent duplicate processing
- **Event validation** - Invalid events are dropped with debug logging

**Lifecycle Tracking:**
- **App lifecycle events** - Automatically tracks `$app_opened`, `$app_backgrounded`, `$app_installed`, and `$app_updated`
- **Background flush** - Events are automatically flushed when the app goes to background (resigns active)
- **Session management** - New session ID generated on each app launch and persisted for the entire session
- **Install/update detection** - Tracks first install and version changes by comparing stored version with current

**macOS Debouncing:**

On macOS, window focus changes happen frequently (Cmd-Tab, clicking other windows). To prevent excessive events:
- `$app_backgrounded` is **not tracked** on macOS
- `$app_opened` is only tracked if the app was inactive for **at least 5 seconds**

> **Note:** Events are still flushed on every focus change regardless of debouncing.

**User & Identity:**
- **User ID persistence** - User identity set via `identify()` persists across app launches in UserDefaults
- **Anonymous ID** - Auto-generated anonymous ID (`$anon_xxxxxxxxxxxx`) for users before identification
- **Profile debouncing** - `$identify` events with profile data are only sent if changed or >24h since last send

**Context Collection:**
- **Automatic context** - Every event includes platform, OS version, device info, locale, timezone, etc.
- **Dynamic context** - Context like app version and build number are collected at event time

**Thread Safety:**

The SDK is fully thread-safe. All methods can be called from any thread:
- Event tracking uses internal queues for safe concurrent access
- Flush operations are serialized to prevent race conditions
- Storage operations are atomic

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

## License

MIT
