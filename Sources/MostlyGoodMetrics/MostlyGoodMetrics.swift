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

    /// Tracks when the app was last backgrounded (for debouncing on macOS)
    private var lastBackgroundedTime: Date?

    /// Cached experiments from the server
    private var experiments: [MGMExperiment] = []

    /// Whether experiments have been fetched
    private var experimentsFetched: Bool = false

    /// Minimum seconds app must be backgrounded before tracking $app_opened on macOS.
    /// This prevents excessive events from quick window/app switches.
    private let macOSBackgroundThreshold: TimeInterval = 5.0

    // Keys for tracking install/update state
    private static let installedVersionKey = "MGM_installedVersion"
    private static let lastOpenedVersionKey = "MGM_lastOpenedVersion"
    private static let superPropertiesKey = "MGM_superProperties"
    private static let anonymousIdKey = "MGM_anonymousId"
    private static let identifyHashKey = "MGM_identifyHash"
    private static let identifyTimestampKey = "MGM_identifyTimestamp"

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

    /// Anonymous ID (auto-generated, persisted across sessions)
    /// Format: $anon_xxxxxxxxxxxx (12 random alphanumeric chars)
    public private(set) var anonymousId: String

    /// Current session ID (generated per app launch)
    public private(set) var sessionId: String

    /// The effective user ID to use in events (identified user or anonymous)
    private var effectiveUserId: String {
        userId ?? anonymousId
    }

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

        // Initialize or restore anonymous ID
        self.anonymousId = Self.initializeAnonymousId()

        // Generate new session ID
        self.sessionId = UUID().uuidString

        startFlushTimer()
        setupAppLifecycleObservers()
        trackInstallOrUpdate()
        fetchExperiments()

        debugLog("Initialized with \(self.storage.eventCount()) cached events")
    }

    /// Internal initializer for testing with custom storage
    internal init(configuration: MGMConfiguration, storage: EventStorage) {
        self.configuration = configuration
        self.storage = storage
        self.networkClient = NetworkClient(configuration: configuration)

        self.userId = UserDefaults.standard.string(forKey: "MGM_userId")
        self.anonymousId = Self.initializeAnonymousId()
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
        self.anonymousId = Self.initializeAnonymousId()
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

        // Merge properties: super properties < user properties < system properties
        // User properties override super properties, system properties are always added
        var mergedProperties = getSuperProperties()
        if let userProps = properties {
            for (key, value) in userProps {
                mergedProperties[key] = value
            }
        }
        // Add system properties (these always get added)
        for (key, value) in systemProperties {
            mergedProperties[key] = value
        }

        var event = MGMEvent(name: name, properties: mergedProperties.isEmpty ? nil : mergedProperties)
        event.userId = effectiveUserId
        event.sessionId = sessionId
        event.platform = currentPlatform
        event.appVersion = appVersion
        event.appBuildNumber = appBuildNumber
        event.osVersion = osVersion
        event.environment = configuration.environment
        event.deviceManufacturer = deviceManufacturer
        event.locale = currentLocale
        event.timezone = currentTimezone

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

    /// Sets the user ID for all subsequent events with optional profile data.
    /// Profile data (email, name) is sent to the backend via the $identify event.
    /// Debouncing: only sends $identify if payload changed or >24h since last send.
    ///
    /// - Parameters:
    ///   - userId: The user identifier
    ///   - profile: Optional profile data (email, name)
    public func identify(userId: String, profile: UserProfile? = nil) {
        self.userId = userId
        debugLog("Identified user: \(userId)")

        // If profile data is provided, check if we should send $identify event
        if let profile = profile, profile.email != nil || profile.name != nil {
            sendIdentifyEventIfNeeded(userId: userId, profile: profile)
        }
    }

    /// Clears the current user ID and identify debounce state
    public func resetIdentity() {
        self.userId = nil
        clearIdentifyState()
        debugLog("Reset user identity")
    }

    /// Send $identify event if debounce conditions are met.
    /// Only sends if: hash changed OR more than 24 hours since last send.
    private func sendIdentifyEventIfNeeded(userId: String, profile: UserProfile) {
        let currentHash = computeIdentifyHash(userId: userId, profile: profile)
        let storedHash = UserDefaults.standard.string(forKey: Self.identifyHashKey)
        let lastSentAt = UserDefaults.standard.object(forKey: Self.identifyTimestampKey) as? Date
        let twentyFourHours: TimeInterval = 24 * 60 * 60

        let hashChanged = storedHash != currentHash
        let expiredTime = lastSentAt == nil || Date().timeIntervalSince(lastSentAt!) > twentyFourHours

        if hashChanged || expiredTime {
            debugLog("Sending $identify event (hashChanged=\(hashChanged), expiredTime=\(expiredTime))")

            // Build properties with only defined values
            var properties: [String: Any] = [:]
            if let email = profile.email {
                properties["email"] = email
            }
            if let name = profile.name {
                properties["name"] = name
            }

            // Track the $identify event
            track("$identify", properties: properties)

            // Update stored hash and timestamp
            UserDefaults.standard.set(currentHash, forKey: Self.identifyHashKey)
            UserDefaults.standard.set(Date(), forKey: Self.identifyTimestampKey)
        } else {
            debugLog("Skipping $identify event (debounced)")
        }
    }

    /// Compute a simple hash for debouncing identify calls
    private func computeIdentifyHash(userId: String, profile: UserProfile) -> String {
        let payload = "\(userId)|\(profile.email ?? "")|\(profile.name ?? "")"
        var hash: Int = 0
        for char in payload.utf8 {
            hash = ((hash << 5) &- hash) &+ Int(char)
        }
        return String(hash, radix: 16)
    }

    /// Clear identify debounce state
    private func clearIdentifyState() {
        UserDefaults.standard.removeObject(forKey: Self.identifyHashKey)
        UserDefaults.standard.removeObject(forKey: Self.identifyTimestampKey)
    }

    /// Starts a new session with a fresh session ID
    public func startNewSession() {
        self.sessionId = UUID().uuidString
        debugLog("Started new session: \(sessionId)")
    }

    // MARK: - Super Properties

    /// Sets a single super property that will be included with every event
    /// - Parameters:
    ///   - key: The property key
    ///   - value: The property value
    public func setSuperProperty(_ key: String, value: Any) {
        var properties = getSuperProperties()
        properties[key] = value
        saveSuperProperties(properties)
        debugLog("Set super property: \(key)")
    }

    /// Sets multiple super properties at once
    /// - Parameter properties: Dictionary of properties to set
    public func setSuperProperties(_ properties: [String: Any]) {
        var current = getSuperProperties()
        for (key, value) in properties {
            current[key] = value
        }
        saveSuperProperties(current)
        debugLog("Set super properties: \(properties.keys.joined(separator: ", "))")
    }

    /// Removes a single super property
    /// - Parameter key: The property key to remove
    public func removeSuperProperty(_ key: String) {
        var properties = getSuperProperties()
        properties.removeValue(forKey: key)
        saveSuperProperties(properties)
        debugLog("Removed super property: \(key)")
    }

    /// Clears all super properties
    public func clearSuperProperties() {
        UserDefaults.standard.removeObject(forKey: Self.superPropertiesKey)
        debugLog("Cleared all super properties")
    }

    /// Gets all current super properties
    /// - Returns: Dictionary of super properties
    public func getSuperProperties() -> [String: Any] {
        guard let data = UserDefaults.standard.data(forKey: Self.superPropertiesKey),
              let properties = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return properties
    }

    private func saveSuperProperties(_ properties: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: properties) {
            UserDefaults.standard.set(data, forKey: Self.superPropertiesKey)
        }
    }

    // MARK: - A/B Testing / Experiments

    /// Gets the variant for an experiment.
    /// Returns a deterministic variant based on the user ID + experiment name hash.
    /// The variant is automatically stored as a super property.
    ///
    /// - Parameter experimentName: The name/id of the experiment
    /// - Returns: The variant string ('a', 'b', etc) or nil if experiment not found
    public func getVariant(experimentName: String) -> String? {
        // Find the experiment in cache (or use fallback if not fetched)
        let experiment = experiments.first { $0.id == experimentName }

        // If experiment not found and experiments have been fetched, return nil
        guard let variants = experiment?.variants, !variants.isEmpty else {
            // If experiments haven't been fetched yet, we can still compute a hash-based fallback
            // but we don't know the valid variants, so return nil
            if experimentsFetched {
                debugLog("Experiment '\(experimentName)' not found")
            } else {
                debugLog("Experiments not yet fetched, cannot determine variant for '\(experimentName)'")
            }
            return nil
        }

        // Compute deterministic variant based on userId + experimentName
        let variant = computeVariant(experimentName: experimentName, variants: variants)

        // Store as super property so it's attached to all events
        let propertyName = "experiment_\(toSnakeCase(experimentName))"
        setSuperProperty(propertyName, value: variant)

        debugLog("Got variant '\(variant)' for experiment '\(experimentName)'")
        return variant
    }

    /// Computes a deterministic variant for an experiment based on the user's ID.
    /// Same user + same experiment always gets the same variant.
    private func computeVariant(experimentName: String, variants: [String]) -> String {
        let hashInput = "\(effectiveUserId)|\(experimentName)"
        let hash = djb2Hash(hashInput)
        let index = Int(hash % UInt32(variants.count))
        return variants[index]
    }

    /// DJB2 hash function for deterministic variant assignment
    private func djb2Hash(_ string: String) -> UInt32 {
        var hash: UInt32 = 5381
        for char in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt32(char)
        }
        return hash
    }

    /// Converts a string to snake_case
    private func toSnakeCase(_ string: String) -> String {
        let result = string.unicodeScalars.reduce("") { result, scalar in
            if CharacterSet.uppercaseLetters.contains(scalar) {
                return result + (result.isEmpty ? "" : "_") + String(scalar).lowercased()
            } else if scalar == "-" || scalar == " " {
                return result + "_"
            } else {
                return result + String(scalar)
            }
        }
        return result.lowercased()
    }

    /// Fetches experiments from the server (called during configure)
    private func fetchExperiments() {
        networkClient.fetchExperiments { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let fetchedExperiments):
                self.experiments = fetchedExperiments
                self.experimentsFetched = true
                self.debugLog("Fetched \(fetchedExperiments.count) experiments")
            case .failure(let error):
                self.experimentsFetched = true  // Mark as fetched even on failure
                self.debugLog("Failed to fetch experiments: \(error.localizedDescription)")
            }
        }
    }

    /// Sets experiments directly (for testing purposes)
    internal func setExperiments(_ experiments: [MGMExperiment]) {
        self.experiments = experiments
        self.experimentsFetched = true
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
            appBuildNumber: appBuildNumber,
            osVersion: osVersion,
            userId: effectiveUserId,
            sessionId: sessionId,
            environment: configuration.environment,
            deviceManufacturer: deviceManufacturer,
            locale: currentLocale,
            timezone: currentTimezone
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
        lastBackgroundedTime = Date()

        #if os(macOS)
        // On macOS, we don't track $app_backgrounded because window focus changes
        // happen frequently (Cmd-Tab, clicking other windows). We still flush events.
        #else
        if configuration.trackAppLifecycleEvents {
            track("$app_backgrounded")
        }
        #endif

        flush()
    }

    @objc private func appDidBecomeActive() {
        debugLog("App did become active")

        #if os(macOS)
        // On macOS, only track $app_opened if the app was backgrounded for at least
        // macOSBackgroundThreshold seconds. This prevents excessive events from quick
        // window/app switches that are common on desktop.
        if let lastBg = lastBackgroundedTime,
           Date().timeIntervalSince(lastBg) >= macOSBackgroundThreshold,
           configuration.trackAppLifecycleEvents {
            track("$app_opened")
        }
        #else
        if configuration.trackAppLifecycleEvents {
            track("$app_opened")
        }
        #endif

        lastBackgroundedTime = nil
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
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private var appBuildNumber: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    private var currentLocale: String {
        Locale.current.identifier
    }

    private var currentTimezone: String {
        TimeZone.current.identifier
    }

    private var deviceManufacturer: String {
        "Apple"
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

    // MARK: - Anonymous ID

    /// Generates a random alphanumeric string of the given length
    private static func generateRandomString(length: Int) -> String {
        let chars = "0123456789abcdefghijklmnopqrstuvwxyz"
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    /// Generates an anonymous user ID with $anon_ prefix
    /// Format: $anon_xxxxxxxxxxxx (12 random alphanumeric chars)
    private static func generateAnonymousId() -> String {
        "$anon_\(generateRandomString(length: 12))"
    }

    /// Initializes or restores the anonymous ID from UserDefaults
    private static func initializeAnonymousId() -> String {
        if let stored = UserDefaults.standard.string(forKey: anonymousIdKey) {
            return stored
        }
        let newId = generateAnonymousId()
        UserDefaults.standard.set(newId, forKey: anonymousIdKey)
        return newId
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

    /// Identifies a user using the shared instance with optional profile data.
    /// Profile data (email, name) is sent to the backend via the $identify event.
    /// Debouncing: only sends $identify if payload changed or >24h since last send.
    ///
    /// - Parameters:
    ///   - userId: The user identifier
    ///   - profile: Optional profile data (email, name)
    static func identify(userId: String, profile: UserProfile? = nil) {
        shared?.identify(userId: userId, profile: profile)
    }

    /// Flushes events using the shared instance
    static func flush() {
        shared?.flush()
    }

    /// Sets a single super property using the shared instance
    /// - Parameters:
    ///   - key: The property key
    ///   - value: The property value
    static func setSuperProperty(_ key: String, value: Any) {
        shared?.setSuperProperty(key, value: value)
    }

    /// Sets multiple super properties using the shared instance
    /// - Parameter properties: Dictionary of properties to set
    static func setSuperProperties(_ properties: [String: Any]) {
        shared?.setSuperProperties(properties)
    }

    /// Removes a single super property using the shared instance
    /// - Parameter key: The property key to remove
    static func removeSuperProperty(_ key: String) {
        shared?.removeSuperProperty(key)
    }

    /// Clears all super properties using the shared instance
    static func clearSuperProperties() {
        shared?.clearSuperProperties()
    }

    /// Gets all current super properties using the shared instance
    /// - Returns: Dictionary of super properties
    static func getSuperProperties() -> [String: Any] {
        shared?.getSuperProperties() ?? [:]
    }

    /// Gets the variant for an experiment using the shared instance.
    /// Returns a deterministic variant based on the user ID + experiment name hash.
    /// The variant is automatically stored as a super property.
    ///
    /// - Parameter experimentName: The name/id of the experiment
    /// - Returns: The variant string ('a', 'b', etc) or nil if experiment not found
    static func getVariant(experimentName: String) -> String? {
        shared?.getVariant(experimentName: experimentName)
    }
}

// MARK: - User Profile

/// User profile data for the identify() call.
public struct UserProfile {
    /// The user's email address.
    public let email: String?

    /// The user's display name.
    public let name: String?

    /// Creates a new user profile.
    /// - Parameters:
    ///   - email: The user's email address
    ///   - name: The user's display name
    public init(email: String? = nil, name: String? = nil) {
        self.email = email
        self.name = name
    }
}

// MARK: - Experiments / A/B Testing

/// Represents an experiment for A/B testing
public struct MGMExperiment: Codable {
    /// The experiment identifier
    public let id: String

    /// The available variants for this experiment
    public let variants: [String]

    public init(id: String, variants: [String]) {
        self.id = id
        self.variants = variants
    }
}

/// Response from the experiments API
internal struct ExperimentsResponse: Codable {
    let experiments: [MGMExperiment]
}
