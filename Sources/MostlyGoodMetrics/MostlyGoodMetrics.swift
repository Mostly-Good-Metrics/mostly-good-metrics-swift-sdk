import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
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

    /// Tracks when the app was last backgrounded (for debouncing on Mac,
    /// i.e. native macOS and Mac Catalyst)
    private var lastBackgroundedTime: Date?

    /// Minimum seconds app must be backgrounded before tracking $app_opened on a Mac
    /// (native macOS or Mac Catalyst). This prevents excessive events from quick
    /// window/app switches.
    private let macBackgroundThreshold: TimeInterval = 5.0

    // Keys for tracking install/update state
    private static let installedVersionKey = "MGM_installedVersion"
    private static let lastOpenedVersionKey = "MGM_lastOpenedVersion"
    private static let superPropertiesKey = "MGM_superProperties"
    private static let anonymousIdKey = "MGM_anonymousId"
    private static let identifyHashKey = "MGM_identifyHash"
    private static let identifyTimestampKey = "MGM_identifyTimestamp"
    private static let optedOutKey = "MGM_optedOut"

    // Keys for experiments cache
    private static let experimentsCacheKey = "MGM_experimentsCache"
    private static let experimentsFetchedAtKey = "MGM_experimentsFetchedAt"
    private static let experimentsCachedUserIdKey = "MGM_experimentsCachedUserId"
    private static let experimentExposuresKey = "MGM_experimentExposures"

    // Keys for local experiment mode (on-device bucketing)
    private static let localExperimentAssignmentsKey = "MGM_localExperimentAssignments"
    private static let localExperimentConfigsCacheKey = "MGM_localExperimentConfigsCache"
    private static let localExperimentConfigsFetchedAtKey = "MGM_localExperimentConfigsFetchedAt"

    /// Minimum time between background experiment refreshes (stale-while-revalidate throttle)
    private static let experimentsRefreshInterval: TimeInterval = 60 * 60

    /// Assigned experiment variants (keyed by experiment name, `.server` mode)
    private var assignedVariants: [String: String] = [:]

    /// Experiment configs for on-device bucketing (keyed by experiment name, `.local` mode)
    private var localExperimentConfigs: [String: MGMExperimentConfig] = [:]

    /// Whether experiments have been loaded
    private var experimentsLoaded: Bool = false

    /// Waiters (from `ready()`) to resolve when experiments finish loading
    private var experimentsWaiters: [ExperimentsWaiter] = []

    /// Generation counter so a stale in-flight fetch can't overwrite a newer one
    private var experimentsFetchGeneration: Int = 0

    /// Lock for thread-safe access to experiments state
    private let experimentsLock = NSLock()

    /// Resumes a continuation exactly once, no matter how many paths race to resume it
    /// (fetch success, fetch failure, or timeout).
    private final class ExperimentsWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var resumeHandler: (() -> Void)?

        init(_ resumeHandler: @escaping () -> Void) {
            self.resumeHandler = resumeHandler
        }

        func resume() {
            lock.lock()
            let handler = resumeHandler
            resumeHandler = nil
            lock.unlock()
            handler?()
        }
    }

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

    /// Lock for thread-safe access to the opt-out state
    private let optOutLock = NSLock()

    /// Backing storage for `isOptedOut` (guarded by `optOutLock`)
    private var _isOptedOut: Bool = false

    /// Whether experiments loading was skipped because the SDK was opted out at init
    /// (guarded by `experimentsLock`)
    private var experimentsLoadSkipped: Bool = false

    /// Whether the user has opted out of tracking.
    /// While opted out, `track`, `identify`, and `flush` are no-ops and no
    /// events are collected or sent. Use `optOut()` / `optIn()` to change.
    public var isOptedOut: Bool {
        optOutLock.lock()
        defer { optOutLock.unlock() }
        return _isOptedOut
    }

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

        // Restore persisted opt-out choice (falls back to the configured default)
        self._isOptedOut = Self.initialOptOutState(configuration: configuration)

        startFlushTimer()
        setupAppLifecycleObservers()

        if _isOptedOut {
            // No tracking or network activity while opted out. Mark experiments
            // as loaded (empty) so `ready()` resolves immediately with fallbacks;
            // they are fetched when `optIn()` is called. In `.local` mode,
            // inline or previously cached configs are still applied (no network)
            // so on-device bucketing keeps working.
            experimentsLoadSkipped = true
            experimentsLoaded = true
            loadExperimentsWhileOptedOut()
            debugLog("Initialized opted out - tracking disabled")
        } else {
            trackInstallOrUpdate()
            loadExperiments()
        }

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
        self._isOptedOut = Self.initialOptOutState(configuration: configuration)

        startFlushTimer()
        setupAppLifecycleObservers()
        // Skip auto-tracking for test instances
        // Mark experiments as loaded for test instances
        experimentsLoaded = true
    }

    /// Internal initializer for testing with custom storage and network client
    internal init(configuration: MGMConfiguration, storage: EventStorage, networkClient: NetworkClientProtocol) {
        self.configuration = configuration
        self.storage = storage
        self.networkClient = networkClient

        self.userId = nil
        self.anonymousId = Self.initializeAnonymousId()
        self.sessionId = UUID().uuidString
        self._isOptedOut = Self.initialOptOutState(configuration: configuration)

        // Skip timers and lifecycle observers for test instances
        // Mark experiments as loaded for test instances
        experimentsLoaded = true
    }

    /// Internal initializer for testing A/B testing functionality.
    /// - Parameter skipExperimentsLoad: When true, experiments are neither loaded nor
    ///   marked as loaded (to test pre-load behavior, `ready()` timeouts, etc).
    ///   When false, the real load flow runs against the injected network client.
    internal init(
        configuration: MGMConfiguration,
        storage: EventStorage,
        networkClient: NetworkClientProtocol,
        skipExperimentsLoad: Bool
    ) {
        self.configuration = configuration
        self.storage = storage
        self.networkClient = networkClient

        self.userId = UserDefaults.standard.string(forKey: "MGM_userId")
        self.anonymousId = Self.initializeAnonymousId()
        self.sessionId = UUID().uuidString
        self._isOptedOut = Self.initialOptOutState(configuration: configuration)

        // Don't auto-load experiments if we want to test the loading flow manually.
        // Mirrors the public initializer's opt-out gate: no experiments network
        // activity while opted out.
        if !skipExperimentsLoad {
            if _isOptedOut {
                experimentsLoadSkipped = true
                experimentsLoaded = true
                loadExperimentsWhileOptedOut()
            } else {
                loadExperiments()
            }
        }
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
        guard !isOptedOut else {
            debugLog("Opted out - dropping event: \(name)")
            return
        }

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
        if configuration.collectDeviceProperties {
            event.deviceManufacturer = deviceManufacturer
            event.locale = currentLocale
            event.timezone = currentTimezone
        }

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
    /// When the user ID changes, experiments are refetched from the server. The current
    /// in-memory variants keep being served until the new response arrives, at which point
    /// they are atomically swapped.
    ///
    /// - Parameters:
    ///   - userId: The user identifier
    ///   - profile: Optional profile data (email, name)
    public func identify(userId: String, profile: UserProfile? = nil) {
        guard !isOptedOut else {
            debugLog("Opted out - ignoring identify")
            return
        }

        let previousUserId = self.userId
        self.userId = userId
        debugLog("Identified user: \(userId)")

        // If user ID changed, refetch experiments
        if previousUserId != userId {
            refetchExperiments()
        }

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

    /// Resets all local SDK state ("forget me").
    /// Clears the user ID and identify debounce state, purges the pending event
    /// queue, clears super properties, and starts a new session.
    /// - Parameter clearAnonymousId: When true, also rotates the anonymous ID so
    ///   future events cannot be linked to the previous anonymous user, and clears
    ///   persisted local experiment assignments so the new identity is re-bucketed
    ///   fresh (default: false)
    public func reset(clearAnonymousId: Bool = false) {
        resetIdentity()
        clearPendingEvents()
        clearSuperProperties()
        startNewSession()
        if clearAnonymousId {
            resetAnonymousId()
        }
        debugLog("Reset SDK state (clearAnonymousId: \(clearAnonymousId))")
    }

    /// Rotates the anonymous ID, generating and persisting a new one.
    /// Subsequent anonymous events are attributed to the new ID and cannot be
    /// linked to the previous one.
    ///
    /// Persisted local experiment assignments (`.local` experiment mode) are also
    /// cleared: they were bucketed under the previous identity, so the rotated
    /// anonymous ID is re-bucketed fresh on the next `getVariant()` call.
    /// - Returns: The newly generated anonymous ID
    @discardableResult
    public func resetAnonymousId() -> String {
        let newId = Self.generateAnonymousId()
        UserDefaults.standard.set(newId, forKey: Self.anonymousIdKey)
        self.anonymousId = newId

        // Local experiment assignments belong to the previous identity - clear
        // them so the new anonymous ID is re-bucketed fresh. (Plain reset() /
        // resetIdentity() keeps them, matching server-mode stickiness.)
        UserDefaults.standard.removeObject(forKey: Self.localExperimentAssignmentsKey)

        debugLog("Reset anonymous ID")
        return newId
    }

    // MARK: - Privacy (Opt-Out)

    /// Opts the user out of all tracking.
    /// Takes effect immediately: any queued events are purged, and `track`,
    /// `identify`, and `flush` become no-ops. The choice is persisted across
    /// app launches until `optIn()` is called.
    public func optOut() {
        optOutLock.lock()
        _isOptedOut = true
        optOutLock.unlock()

        UserDefaults.standard.set(true, forKey: Self.optedOutKey)
        storage.clear()
        debugLog("Opted out of tracking - purged pending events")
    }

    /// Opts the user back in to tracking.
    /// The choice is persisted across app launches and overrides
    /// `MGMConfiguration.optedOutByDefault`.
    public func optIn() {
        optOutLock.lock()
        _isOptedOut = false
        optOutLock.unlock()

        UserDefaults.standard.set(false, forKey: Self.optedOutKey)
        debugLog("Opted in to tracking")

        // Load experiments now if the initial load was skipped while opted out
        var shouldLoadExperiments = false
        experimentsLock.lock()
        if experimentsLoadSkipped {
            experimentsLoadSkipped = false
            shouldLoadExperiments = true
        }
        experimentsLock.unlock()

        if shouldLoadExperiments {
            loadExperiments()
        }
    }

    /// Resolves the initial opt-out state: a persisted `optIn()`/`optOut()`
    /// choice always wins; otherwise the configured default applies.
    private static func initialOptOutState(configuration: MGMConfiguration) -> Bool {
        if UserDefaults.standard.object(forKey: optedOutKey) != nil {
            return UserDefaults.standard.bool(forKey: optedOutKey)
        }
        return configuration.optedOutByDefault
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

    // MARK: - A/B Testing (Experiments)

    /// Waits for experiments to be loaded.
    /// Call this before accessing `getVariant` if you need to ensure experiments are available.
    ///
    /// This is guaranteed to resolve: it returns when experiments finish loading (success
    /// or failure), or when the timeout elapses, whichever comes first.
    ///
    /// - Parameter timeout: Maximum time to wait, in seconds (default 5)
    @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
    public func ready(timeout: TimeInterval = 5.0) async {
        // Check if already loaded (synchronous check)
        let isLoaded = experimentsLock.withLock { experimentsLoaded }
        if isLoaded {
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = ExperimentsWaiter { continuation.resume() }

            var loadedWhileRegistering = false
            experimentsLock.lock()
            if experimentsLoaded {
                loadedWhileRegistering = true
            } else {
                experimentsWaiters.append(waiter)
            }
            experimentsLock.unlock()

            if loadedWhileRegistering {
                waiter.resume()
                return
            }

            // Guarantee resolution even if the fetch never completes.
            // ExperimentsWaiter makes double-resume a no-op, so racing with
            // fetch completion is safe.
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout)) {
                waiter.resume()
            }
        }
    }

    /// Gets the variant assigned to a specific experiment.
    /// When a variant is accessed, it's automatically registered as a super property
    /// with the key `$experiment_{snake_case_name}`, and a `$experiment_exposure` event
    /// is tracked once per (user, experiment, variant).
    ///
    /// - Parameters:
    ///   - experimentName: The name of the experiment
    ///   - fallback: Value to return when the experiment is unknown or experiments
    ///     haven't loaded yet
    /// - Returns: The assigned variant, or `fallback` if the experiment doesn't exist
    ///   or experiments haven't loaded
    public func getVariant(_ experimentName: String, fallback: String? = nil) -> String? {
        let assignedVariant: String?
        switch configuration.experimentMode {
        case .server:
            experimentsLock.lock()
            assignedVariant = assignedVariants[experimentName]
            experimentsLock.unlock()
        case .local:
            assignedVariant = localVariant(for: experimentName)
        }

        guard let variant = assignedVariant else {
            return fallback
        }

        // Set as super property with $experiment_ prefix
        let snakeCaseName = experimentName.toSnakeCase()
        setSuperProperty("$experiment_\(snakeCaseName)", value: variant)
        debugLog("Variant '\(variant)' for experiment '\(experimentName)' set as super property")

        trackExposureIfNeeded(experimentName: experimentName, variant: variant)

        return variant
    }

    /// Tracks a `$experiment_exposure` event on the first `getVariant` hit for a given
    /// (user, experiment, variant) combination. Dedup state is persisted in UserDefaults
    /// so relaunches don't re-fire exposures.
    private func trackExposureIfNeeded(experimentName: String, variant: String) {
        // While opted out, no exposure is tracked and no dedup state is recorded,
        // so the exposure can still fire after a later opt-in.
        guard !isOptedOut else {
            debugLog("Opted out - skipping $experiment_exposure for '\(experimentName)'")
            return
        }

        let exposureKey = "\(effectiveUserId)|\(experimentName)|\(variant)"
        let defaults = UserDefaults.standard

        var alreadyTracked = false
        experimentsLock.lock()
        var exposures = defaults.stringArray(forKey: Self.experimentExposuresKey) ?? []
        if exposures.contains(exposureKey) {
            alreadyTracked = true
        } else {
            exposures.append(exposureKey)
            defaults.set(exposures, forKey: Self.experimentExposuresKey)
        }
        experimentsLock.unlock()

        guard !alreadyTracked else { return }

        track("$experiment_exposure", properties: [
            "$experiment_name": experimentName,
            "$variant": variant
        ])
        debugLog("Tracked $experiment_exposure for '\(experimentName)' variant '\(variant)'")
    }

    /// Loads experiments according to the configured `experimentMode`.
    ///
    /// - `.server`: loads server-assigned variants from cache and/or the server
    /// - `.local`: loads experiment configs (inline, cached, or fetched) for
    ///   on-device bucketing
    private func loadExperiments() {
        switch configuration.experimentMode {
        case .server:
            loadServerExperiments()
        case .local:
            loadLocalExperiments()
        }
    }

    /// Loads whatever experiment state is available without touching the network,
    /// for use while opted out.
    ///
    /// In `.server` mode nothing is loaded (assignments come from the server, and
    /// they are fetched when `optIn()` is called). In `.local` mode, inline configs
    /// or previously cached configs are applied so on-device bucketing keeps
    /// working from persisted/inline state - but no fetch or background
    /// revalidation happens while opted out.
    private func loadExperimentsWhileOptedOut() {
        guard case .local = configuration.experimentMode else { return }

        if !configuration.localExperiments.isEmpty {
            applyLocalExperimentConfigs(configuration.localExperiments)
            debugLog("Opted out - applied \(configuration.localExperiments.count) inline local experiment configs (no fetch)")
        } else if let cachedConfigs = loadCachedExperimentConfigs() {
            applyLocalExperimentConfigs(cachedConfigs)
            debugLog("Opted out - applied \(cachedConfigs.count) cached experiment configs (no fetch)")
        }
    }

    /// Loads server-assigned experiments from cache and/or fetches from server.
    ///
    /// Cached assignments never expire (stale-while-revalidate): the cache for the current
    /// user is served immediately, and a background refetch runs if the last successful
    /// fetch was more than `experimentsRefreshInterval` ago.
    private func loadServerExperiments() {
        if let cachedVariants = loadCachedExperiments() {
            experimentsLock.lock()
            assignedVariants = cachedVariants
            experimentsLoaded = true
            let waiters = experimentsWaiters
            experimentsWaiters.removeAll()
            experimentsLock.unlock()

            debugLog("Loaded \(cachedVariants.count) experiments from cache")
            waiters.forEach { $0.resume() }

            // Background revalidation, throttled to once per refresh interval
            let lastFetchedAt = UserDefaults.standard.object(forKey: Self.experimentsFetchedAtKey) as? Date
            if lastFetchedAt == nil || Date().timeIntervalSince(lastFetchedAt!) >= Self.experimentsRefreshInterval {
                fetchExperimentsFromServer()
            }
            return
        }

        // No cache for this user - fetch from server
        fetchExperimentsFromServer()
    }

    /// Fetches experiments from the server.
    ///
    /// On success, the in-memory assignments are atomically swapped (unless a newer fetch
    /// has been started since). On failure, current assignments keep being served.
    /// All `ready()` waiters are resolved in both cases.
    private func fetchExperimentsFromServer() {
        experimentsLock.lock()
        experimentsFetchGeneration += 1
        let generation = experimentsFetchGeneration
        experimentsLock.unlock()

        let requestedUserId = effectiveUserId
        networkClient.fetchExperiments(userId: requestedUserId, anonymousId: anonymousId) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let variants):
                self.experimentsLock.lock()
                let isLatestFetch = generation == self.experimentsFetchGeneration
                if isLatestFetch {
                    self.assignedVariants = variants
                }
                self.experimentsLoaded = true
                let waiters = self.experimentsWaiters
                self.experimentsWaiters.removeAll()
                self.experimentsLock.unlock()

                if isLatestFetch {
                    self.cacheExperiments(variants, userId: requestedUserId)
                    self.debugLog("Fetched \(variants.count) experiment assignments")
                } else {
                    self.debugLog("Ignored stale experiments response for user \(requestedUserId)")
                }
                waiters.forEach { $0.resume() }

            case .failure(let error):
                // Mark experiments as loaded even on failure to avoid blocking forever.
                // Keep serving whatever assignments we already have (cache or previous fetch).
                self.experimentsLock.lock()
                self.experimentsLoaded = true
                let waiters = self.experimentsWaiters
                self.experimentsWaiters.removeAll()
                self.experimentsLock.unlock()

                self.debugLog("Failed to fetch experiments: \(error.localizedDescription)")
                waiters.forEach { $0.resume() }
            }
        }
    }

    /// Loads cached experiments for the current user, if present.
    /// The cache never expires; freshness is handled by background revalidation.
    /// - Returns: Cached variants if present for the current user, nil otherwise
    private func loadCachedExperiments() -> [String: String]? {
        let defaults = UserDefaults.standard

        guard let cachedUserId = defaults.string(forKey: Self.experimentsCachedUserIdKey),
              cachedUserId == effectiveUserId,
              let data = defaults.data(forKey: Self.experimentsCacheKey),
              let variants = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }

        return variants
    }

    /// Caches experiments to UserDefaults
    /// - Parameters:
    ///   - variants: The variants to cache
    ///   - userId: The user ID these variants belong to
    private func cacheExperiments(_ variants: [String: String], userId: String) {
        let defaults = UserDefaults.standard

        if let data = try? JSONEncoder().encode(variants) {
            defaults.set(data, forKey: Self.experimentsCacheKey)
            defaults.set(Date(), forKey: Self.experimentsFetchedAtKey)
            defaults.set(userId, forKey: Self.experimentsCachedUserIdKey)
            debugLog("Cached \(variants.count) experiment assignments")
        }
    }

    /// Refetches experiments after identify.
    ///
    /// In `.server` mode the server is asked for fresh assignments; current in-memory
    /// assignments keep being served until the new response arrives, at which point
    /// they are atomically swapped.
    ///
    /// In `.local` mode nothing is refetched: persisted local assignments are sticky
    /// across `identify()`, which matches server behavior of keeping the
    /// anonymous-era variant.
    private func refetchExperiments() {
        switch configuration.experimentMode {
        case .server:
            fetchExperimentsFromServer()
        case .local:
            debugLog("Local experiment mode: keeping sticky assignments after identify")
        }
    }

    // MARK: - Local Experiment Mode

    /// Loads experiment configs for on-device bucketing.
    ///
    /// Inline configs (`MGMConfiguration.localExperiments`) take priority and involve
    /// no network request at all. Otherwise cached configs are served immediately
    /// (stale-while-revalidate, same throttle as server mode) and fetched from the
    /// server when absent or stale.
    private func loadLocalExperiments() {
        if !configuration.localExperiments.isEmpty {
            applyLocalExperimentConfigs(configuration.localExperiments)
            debugLog("Loaded \(configuration.localExperiments.count) inline local experiment configs")
            return
        }

        if let cachedConfigs = loadCachedExperimentConfigs() {
            applyLocalExperimentConfigs(cachedConfigs)
            debugLog("Loaded \(cachedConfigs.count) experiment configs from cache")

            // Background revalidation, throttled to once per refresh interval
            let lastFetchedAt = UserDefaults.standard.object(forKey: Self.localExperimentConfigsFetchedAtKey) as? Date
            if lastFetchedAt == nil || Date().timeIntervalSince(lastFetchedAt!) >= Self.experimentsRefreshInterval {
                fetchExperimentConfigsFromServer()
            }
            return
        }

        // No inline configs and no cache - fetch from server
        fetchExperimentConfigsFromServer()
    }

    /// Atomically swaps in the given experiment configs, marks experiments as loaded,
    /// and resolves all `ready()` waiters.
    private func applyLocalExperimentConfigs(_ configs: [MGMExperimentConfig]) {
        let configsByName = Dictionary(configs.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        experimentsLock.lock()
        localExperimentConfigs = configsByName
        experimentsLoaded = true
        let waiters = experimentsWaiters
        experimentsWaiters.removeAll()
        experimentsLock.unlock()

        waiters.forEach { $0.resume() }
    }

    /// Fetches experiment configs from the server for local mode.
    ///
    /// On success, the in-memory configs are atomically swapped (unless a newer fetch
    /// has been started since). On failure, current configs keep being served.
    /// All `ready()` waiters are resolved in both cases. No user identifier is sent.
    private func fetchExperimentConfigsFromServer() {
        experimentsLock.lock()
        experimentsFetchGeneration += 1
        let generation = experimentsFetchGeneration
        experimentsLock.unlock()

        networkClient.fetchExperimentConfigs { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let configs):
                self.experimentsLock.lock()
                let isLatestFetch = generation == self.experimentsFetchGeneration
                if isLatestFetch {
                    self.localExperimentConfigs = Dictionary(
                        configs.map { ($0.name, $0) },
                        uniquingKeysWith: { first, _ in first }
                    )
                }
                self.experimentsLoaded = true
                let waiters = self.experimentsWaiters
                self.experimentsWaiters.removeAll()
                self.experimentsLock.unlock()

                if isLatestFetch {
                    self.cacheExperimentConfigs(configs)
                    self.debugLog("Fetched \(configs.count) experiment configs")
                } else {
                    self.debugLog("Ignored stale experiment configs response")
                }
                waiters.forEach { $0.resume() }

            case .failure(let error):
                // Mark experiments as loaded even on failure to avoid blocking forever.
                // Keep serving whatever configs we already have (inline, cache, or previous fetch).
                self.experimentsLock.lock()
                self.experimentsLoaded = true
                let waiters = self.experimentsWaiters
                self.experimentsWaiters.removeAll()
                self.experimentsLock.unlock()

                self.debugLog("Failed to fetch experiment configs: \(error.localizedDescription)")
                waiters.forEach { $0.resume() }
            }
        }
    }

    /// Loads cached experiment configs, if present.
    /// The cache never expires; freshness is handled by background revalidation.
    private func loadCachedExperimentConfigs() -> [MGMExperimentConfig]? {
        guard let data = UserDefaults.standard.data(forKey: Self.localExperimentConfigsCacheKey),
              let configs = try? JSONDecoder().decode([MGMExperimentConfig].self, from: data) else {
            return nil
        }
        return configs
    }

    /// Caches experiment configs to UserDefaults
    /// - Parameter configs: The configs to cache
    private func cacheExperimentConfigs(_ configs: [MGMExperimentConfig]) {
        let defaults = UserDefaults.standard

        if let data = try? JSONEncoder().encode(configs) {
            defaults.set(data, forKey: Self.localExperimentConfigsCacheKey)
            defaults.set(Date(), forKey: Self.localExperimentConfigsFetchedAtKey)
            debugLog("Cached \(configs.count) experiment configs")
        }
    }

    /// Resolves the variant for an experiment in `.local` mode.
    ///
    /// The first resolution for an experiment buckets on device
    /// (`MGMLocalBucketing`) using the effective user ID and persists the
    /// assignment per experiment UUID. Later calls - including after `identify()` -
    /// reuse the persisted assignment, so an anonymous-era variant sticks (matching
    /// server behavior).
    private func localVariant(for experimentName: String) -> String? {
        experimentsLock.lock()
        defer { experimentsLock.unlock() }

        guard let config = localExperimentConfigs[experimentName] else {
            return nil
        }

        let defaults = UserDefaults.standard
        var assignments = defaults.dictionary(forKey: Self.localExperimentAssignmentsKey) as? [String: String] ?? [:]
        if let stickyVariant = assignments[config.id] {
            return stickyVariant
        }

        guard let variant = MGMLocalBucketing.variant(
            experimentId: config.id,
            userId: effectiveUserId,
            variants: config.variants
        ) else {
            return nil
        }

        assignments[config.id] = variant
        defaults.set(assignments, forKey: Self.localExperimentAssignmentsKey)
        debugLog("Locally bucketed '\(experimentName)' (\(config.id)) into variant '\(variant)'")
        return variant
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

    // MARK: - Flushing

    /// Manually flushes all pending events to the server
    /// - Parameter completion: Optional completion handler
    public func flush(completion: ((Result<Void, MGMError>) -> Void)? = nil) {
        flushQueue.async { [weak self] in
            self?.performFlush(completion: completion)
        }
    }

    private func performFlush(completion: ((Result<Void, MGMError>) -> Void)?) {
        guard !isOptedOut else {
            debugLog("Opted out - skipping flush")
            completion?(.success(()))
            return
        }

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

        let collectDeviceProperties = configuration.collectDeviceProperties
        let context = MGMEventContext(
            platform: currentPlatform,
            appVersion: appVersion,
            appBuildNumber: appBuildNumber,
            osVersion: osVersion,
            userId: effectiveUserId,
            sessionId: sessionId,
            environment: configuration.environment,
            deviceManufacturer: collectDeviceProperties ? deviceManufacturer : nil,
            locale: collectDeviceProperties ? currentLocale : nil,
            timezone: collectDeviceProperties ? currentTimezone : nil
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

        // On a Mac (native macOS or Mac Catalyst), we don't track $app_backgrounded
        // because window focus changes happen frequently (Cmd-Tab, clicking other
        // windows). We still flush events.
        if Self.shouldTrackAppBackgrounded(), configuration.trackAppLifecycleEvents {
            track("$app_backgrounded")
        }

        flush()
    }

    @objc private func appDidBecomeActive() {
        debugLog("App did become active")

        // On a Mac (native macOS or Mac Catalyst), only track $app_opened if the app
        // was backgrounded for at least macBackgroundThreshold seconds. This prevents
        // excessive events from quick window/app switches that are common on desktop.
        if Self.shouldTrackAppOpened(
            lastBackgroundedTime: lastBackgroundedTime,
            threshold: macBackgroundThreshold
        ), configuration.trackAppLifecycleEvents {
            track("$app_opened")
        }

        lastBackgroundedTime = nil
        flush()
    }

    /// Whether $app_backgrounded should be tracked when the app resigns active.
    /// On a Mac (native macOS or Mac Catalyst) it never is, because window focus
    /// changes are too frequent to be meaningful.
    internal static func shouldTrackAppBackgrounded(
        isMacLike: Bool = MGMPlatformInfo.isMacLike
    ) -> Bool {
        !isMacLike
    }

    /// Whether $app_opened should be tracked when the app becomes active.
    /// On a Mac (native macOS or Mac Catalyst), only after the app has been
    /// inactive for at least `threshold` seconds.
    internal static func shouldTrackAppOpened(
        lastBackgroundedTime: Date?,
        threshold: TimeInterval,
        now: Date = Date(),
        isMacLike: Bool = MGMPlatformInfo.isMacLike
    ) -> Bool {
        guard isMacLike else { return true }
        guard let lastBackgrounded = lastBackgroundedTime else { return false }
        return now.timeIntervalSince(lastBackgrounded) >= threshold
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
        let pattern = "^\\$?[a-zA-Z][a-zA-Z0-9_]*(?: [a-zA-Z0-9_]+)*$"
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    private var currentPlatform: String {
        MGMPlatformInfo.platformName
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
        MGMPlatformInfo.osVersion
    }

    private var deviceType: String {
        MGMPlatformInfo.deviceType
    }

    private var deviceModel: String? {
        MGMPlatformInfo.deviceModel
    }

    private var systemProperties: [String: Any] {
        var props: [String: Any] = [
            "$sdk": configuration.wrapperName ?? "swift"
        ]
        if configuration.collectDeviceProperties {
            props["$device_type"] = deviceType
            if let model = deviceModel {
                props["$device_model"] = model
            }
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

    /// Opts the user out of all tracking using the shared instance
    static func optOut() {
        shared?.optOut()
    }

    /// Opts the user back in to tracking using the shared instance
    static func optIn() {
        shared?.optIn()
    }

    /// Whether the user has opted out of tracking (false if not configured)
    static var isOptedOut: Bool {
        shared?.isOptedOut ?? false
    }

    /// Rotates the anonymous ID using the shared instance
    /// - Returns: The newly generated anonymous ID, or nil if not configured
    @discardableResult
    static func resetAnonymousId() -> String? {
        shared?.resetAnonymousId()
    }

    /// Resets all local SDK state using the shared instance ("forget me")
    /// - Parameter clearAnonymousId: When true, also rotates the anonymous ID
    static func reset(clearAnonymousId: Bool = false) {
        shared?.reset(clearAnonymousId: clearAnonymousId)
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

    /// Waits for experiments to be loaded using the shared instance.
    /// Resolves on load completion (success or failure) or when the timeout elapses.
    /// - Parameter timeout: Maximum time to wait, in seconds (default 5)
    @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
    static func ready(timeout: TimeInterval = 5.0) async {
        await shared?.ready(timeout: timeout)
    }

    /// Gets the variant assigned to a specific experiment using the shared instance.
    /// - Parameters:
    ///   - experimentName: The name of the experiment
    ///   - fallback: Value to return when the experiment is unknown or experiments
    ///     haven't loaded yet
    /// - Returns: The assigned variant, or `fallback` if the experiment doesn't exist
    static func getVariant(_ experimentName: String, fallback: String? = nil) -> String? {
        shared?.getVariant(experimentName, fallback: fallback) ?? fallback
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

// MARK: - String Extensions

extension String {
    /// Converts a string to snake_case.
    ///
    /// Byte-for-byte port of the shared JS reference implementation:
    ///   name.replace(/([A-Z])/g, "_$1").replace(/[-\s]+/g, "_").toLowerCase().replace(/^_/, "")
    ///
    /// Note: double underscores are contractual and must NOT be collapsed.
    /// Examples:
    /// - "myExperiment" -> "my_experiment"
    /// - "Pricing-Test V2" -> "pricing__test__v2"
    /// - "button-color" -> "button_color"
    /// - "ABTest" -> "a_b_test"
    func toSnakeCase() -> String {
        // Step 1: insert "_" before every uppercase letter (no conditions)
        var result = self.replacingOccurrences(
            of: "([A-Z])",
            with: "_$1",
            options: .regularExpression
        )
        // Step 2: replace runs of hyphens and whitespace with a single "_"
        result = result.replacingOccurrences(
            of: "[-\\s]+",
            with: "_",
            options: .regularExpression
        )
        // Step 3: lowercase everything
        result = result.lowercased()
        // Step 4: strip one leading "_" if present
        if result.hasPrefix("_") {
            result.removeFirst()
        }
        return result
    }
}
