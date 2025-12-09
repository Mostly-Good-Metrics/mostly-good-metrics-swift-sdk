import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if canImport(WatchKit)
import WatchKit
#endif

/// The main client for tracking analytics events with MostlyGoodMetrics
public final class MostlyGoodMetrics {
    /// Shared instance for convenience (must call `configure` first)
    public private(set) static var shared: MostlyGoodMetrics?

    private let configuration: MGMConfiguration
    private let storage: EventStorage
    private let networkClient: NetworkClientProtocol

    private var flushTimer: Timer?
    private let flushQueue = DispatchQueue(label: "com.mostlygoodmetrics.flush")

    // Keys for tracking install/update state
    private static let installedVersionKey = "MGM_installedVersion"
    private static let lastOpenedVersionKey = "MGM_lastOpenedVersion"

    /// Current user ID (persisted across sessions)
    public var userId: String? {
        didSet {
            if let userId = userId {
                UserDefaults.standard.set(userId, forKey: "MGM_userId")
            } else {
                UserDefaults.standard.removeObject(forKey: "MGM_userId")
            }
        }
    }

    /// Current session ID (generated per app launch)
    public private(set) var sessionId: String

    /// Whether the SDK is currently sending events
    public private(set) var isFlushing: Bool = false

    // MARK: - Initialization

    /// Configures the shared instance with the given configuration
    /// - Parameter configuration: The SDK configuration
    /// - Returns: The configured shared instance
    @discardableResult
    public static func configure(with configuration: MGMConfiguration) -> MostlyGoodMetrics {
        let instance = MostlyGoodMetrics(configuration: configuration)
        shared = instance
        return instance
    }

    /// Configures the shared instance with just an API key using default settings
    /// - Parameter apiKey: The API key for authentication
    /// - Returns: The configured shared instance
    @discardableResult
    public static func configure(apiKey: String) -> MostlyGoodMetrics {
        configure(with: MGMConfiguration(apiKey: apiKey))
    }

    /// Creates a new instance with the given configuration
    /// - Parameter configuration: The SDK configuration
    public init(configuration: MGMConfiguration) {
        self.configuration = configuration
        self.storage = FileEventStorage(maxEvents: configuration.maxStoredEvents)
        self.networkClient = NetworkClient(configuration: configuration)

        // Restore or generate user ID
        self.userId = UserDefaults.standard.string(forKey: "MGM_userId")

        // Generate new session ID
        self.sessionId = UUID().uuidString

        startFlushTimer()
        setupAppLifecycleObservers()
        trackInstallOrUpdate()

        debugLog("Initialized with \(self.storage.eventCount()) cached events")
    }

    /// Internal initializer for testing with custom storage
    internal init(configuration: MGMConfiguration, storage: EventStorage) {
        self.configuration = configuration
        self.storage = storage
        self.networkClient = NetworkClient(configuration: configuration)

        self.userId = UserDefaults.standard.string(forKey: "MGM_userId")
        self.sessionId = UUID().uuidString

        startFlushTimer()
        setupAppLifecycleObservers()
        // Skip auto-tracking for test instances
    }

    /// Internal initializer for testing with custom storage and network client
    internal init(configuration: MGMConfiguration, storage: EventStorage, networkClient: NetworkClientProtocol) {
        self.configuration = configuration
        self.storage = storage
        self.networkClient = networkClient

        self.userId = nil
        self.sessionId = UUID().uuidString

        // Skip timers and lifecycle observers for test instances
    }

    deinit {
        flushTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Event Tracking

    /// Tracks an event with the given name and optional properties
    /// - Parameters:
    ///   - name: The event name (alphanumeric + underscore, must start with letter)
    ///   - properties: Optional custom properties for the event
    public func track(_ name: String, properties: [String: Any]? = nil) {
        guard validateEventName(name) else {
            debugLog("Invalid event name: \(name)")
            return
        }

        // Merge user properties with system properties (user properties take precedence)
        var mergedProperties = systemProperties
        if let userProps = properties {
            for (key, value) in userProps {
                mergedProperties[key] = value
            }
        }

        var event = MGMEvent(name: name, properties: mergedProperties.isEmpty ? nil : mergedProperties)
        event.userId = userId
        event.sessionId = sessionId
        event.platform = currentPlatform
        event.appVersion = appVersion
        event.osVersion = osVersion
        event.environment = configuration.environment

        storage.store(event: event)
        debugLog("Tracked event: \(name)")

        // Auto-flush if we've reached the batch size
        if storage.eventCount() >= configuration.maxBatchSize {
            flush()
        }
    }

    /// Tracks an event with the given name
    /// - Parameter name: The event name
    public func track(_ name: String) {
        track(name, properties: nil)
    }

    // MARK: - User Identity

    /// Sets the user ID for all subsequent events
    /// - Parameter userId: The user identifier
    public func identify(userId: String) {
        self.userId = userId
        debugLog("Identified user: \(userId)")
    }

    /// Clears the current user ID
    public func resetIdentity() {
        self.userId = nil
        debugLog("Reset user identity")
    }

    /// Starts a new session with a fresh session ID
    public func startNewSession() {
        self.sessionId = UUID().uuidString
        debugLog("Started new session: \(sessionId)")
    }

    // MARK: - Flushing

    /// Manually flushes all pending events to the server
    /// - Parameter completion: Optional completion handler
    public func flush(completion: ((Result<Void, MGMError>) -> Void)? = nil) {
        flushQueue.async { [weak self] in
            self?.performFlush(completion: completion)
        }
    }

    private func performFlush(completion: ((Result<Void, MGMError>) -> Void)?) {
        guard !isFlushing else {
            debugLog("Already flushing, skipping")
            completion?(.success(()))
            return
        }

        let events = storage.fetchEvents(limit: configuration.maxBatchSize)
        guard !events.isEmpty else {
            debugLog("No events to flush")
            completion?(.success(()))
            return
        }

        isFlushing = true
        debugLog("Flushing \(events.count) events")

        let context = MGMEventContext(
            platform: currentPlatform,
            appVersion: appVersion,
            osVersion: osVersion,
            userId: userId,
            sessionId: sessionId,
            environment: configuration.environment
        )

        networkClient.sendEvents(events, context: context) { [weak self] result in
            guard let self = self else { return }

            self.isFlushing = false

            switch result {
            case .success:
                self.storage.removeEvents(events)
                self.debugLog("Successfully flushed \(events.count) events")

                // If there are more events, continue flushing
                if self.storage.eventCount() > 0 {
                    self.flushQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.performFlush(completion: nil)
                    }
                }
                completion?(.success(()))

            case .failure(let error):
                self.debugLog("Flush failed: \(error.localizedDescription)")

                // Don't remove events on failure - they'll be retried
                // But if it's a 4xx error (except rate limit), we should drop them
                switch error {
                case .badRequest, .unauthorized, .forbidden:
                    self.storage.removeEvents(events)
                    self.debugLog("Dropped \(events.count) events due to client error")
                default:
                    break
                }

                completion?(.failure(error))
            }
        }
    }

    /// Clears all pending events without sending them
    public func clearPendingEvents() {
        storage.clear()
        debugLog("Cleared all pending events")
    }

    /// Returns the number of pending events
    public var pendingEventCount: Int {
        storage.eventCount()
    }

    // MARK: - Private Helpers

    private func startFlushTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.flushTimer?.invalidate()
            self.flushTimer = Timer.scheduledTimer(
                withTimeInterval: self.configuration.flushInterval,
                repeats: true
            ) { [weak self] _ in
                self?.flush()
            }
        }
    }

    private func setupAppLifecycleObservers() {
        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        #elseif canImport(AppKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        #endif
    }

    @objc private func appWillResignActive() {
        debugLog("App will resign active - flushing events")
        if configuration.trackAppLifecycleEvents {
            track("$app_backgrounded")
        }
        flush()
    }

    @objc private func appDidBecomeActive() {
        debugLog("App did become active")
        if configuration.trackAppLifecycleEvents {
            track("$app_opened")
        }
        flush()
    }

    private func trackInstallOrUpdate() {
        guard configuration.trackAppLifecycleEvents else { return }
        guard let currentVersion = appVersion else { return }

        let defaults = UserDefaults.standard
        let installedVersion = defaults.string(forKey: Self.installedVersionKey)
        let lastOpenedVersion = defaults.string(forKey: Self.lastOpenedVersionKey)

        if installedVersion == nil {
            // First install ever
            defaults.set(currentVersion, forKey: Self.installedVersionKey)
            defaults.set(currentVersion, forKey: Self.lastOpenedVersionKey)
            track("$app_installed", properties: ["$version": currentVersion])
            debugLog("Tracked $app_installed for version \(currentVersion)")
        } else if lastOpenedVersion != currentVersion {
            // App was updated
            defaults.set(currentVersion, forKey: Self.lastOpenedVersionKey)
            track("$app_updated", properties: [
                "$previous_version": lastOpenedVersion ?? "unknown",
                "$version": currentVersion
            ])
            debugLog("Tracked $app_updated from \(lastOpenedVersion ?? "unknown") to \(currentVersion)")
        }
    }

    private func validateEventName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }

        // Allow $ prefix for system events, otherwise must start with letter
        let pattern = "^\\$?[a-zA-Z][a-zA-Z0-9_]*$"
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    private var currentPlatform: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #elseif os(visionOS)
        return "visionos"
        #else
        return "unknown"
        #endif
    }

    private var appVersion: String? {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

        switch (version, build) {
        case let (v?, b?) where v != b:
            return "\(v) (\(b))"
        case let (v?, _):
            return v
        case let (nil, b?):
            return b
        default:
            return nil
        }
    }

    private var osVersion: String {
        #if os(watchOS)
        return WKInterfaceDevice.current().systemVersion
        #elseif canImport(UIKit)
        return UIDevice.current.systemVersion
        #elseif canImport(AppKit)
        return ProcessInfo.processInfo.operatingSystemVersionString
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    private var deviceType: String {
        #if os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return "phone"
        case .pad:
            return "tablet"
        case .tv:
            return "tv"
        case .carPlay:
            return "carplay"
        case .mac:
            return "mac"
        case .vision:
            return "vision"
        @unknown default:
            return "unknown"
        }
        #elseif os(macOS)
        return "desktop"
        #elseif os(tvOS)
        return "tv"
        #elseif os(watchOS)
        return "watch"
        #elseif os(visionOS)
        return "vision"
        #else
        return "unknown"
        #endif
    }

    private var deviceModel: String? {
        #if os(iOS) || os(tvOS)
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
        #elseif os(watchOS)
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
        #elseif os(macOS)
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
        #else
        return nil
        #endif
    }

    private var systemProperties: [String: Any] {
        var props: [String: Any] = [
            "$device_type": deviceType,
            "$sdk": configuration.wrapperName ?? "swift"
        ]
        if let model = deviceModel {
            props["$device_model"] = model
        }
        return props
    }

    private func debugLog(_ message: String) {
        if configuration.enableDebugLogging {
            print("[MostlyGoodMetrics] \(message)")
        }
    }
}

// MARK: - Convenience Extensions

public extension MostlyGoodMetrics {
    /// Tracks an event using the shared instance
    /// - Parameters:
    ///   - name: The event name
    ///   - properties: Optional custom properties
    static func track(_ name: String, properties: [String: Any]? = nil) {
        shared?.track(name, properties: properties)
    }

    /// Identifies a user using the shared instance
    /// - Parameter userId: The user identifier
    static func identify(userId: String) {
        shared?.identify(userId: userId)
    }

    /// Flushes events using the shared instance
    static func flush() {
        shared?.flush()
    }
}
