import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if canImport(WatchKit)
import WatchKit
#endif

/// Centralized platform detection for the SDK.
///
/// Mac Catalyst compiles with `os(iOS) == true`, so bare `#if os(macOS)` checks
/// miss it and Catalyst apps get iOS behavior even though they run on a Mac.
/// All platform-dependent derivation lives here so Catalyst is handled in one place.
internal enum MGMPlatformInfo {
    /// True when the app is running as a Mac app: native macOS or Mac Catalyst.
    /// Use this (instead of `#if os(macOS)`) for any "desktop-like" behavior.
    static var isMacLike: Bool {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    /// Lowercase platform identifier sent in event payloads (`platform` field).
    /// Mac Catalyst reports "macos" because the app is running on a Mac.
    static var platformName: String {
        #if targetEnvironment(macCatalyst)
        return "macos"
        #elseif os(iOS)
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

    /// Display-cased platform name used in the User-Agent header.
    static var platformDisplayName: String {
        #if targetEnvironment(macCatalyst)
        return "macOS"
        #elseif os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(watchOS)
        return "watchOS"
        #elseif os(visionOS)
        return "visionOS"
        #else
        return "unknown"
        #endif
    }

    /// OS version string.
    ///
    /// On Mac Catalyst, `UIDevice.current.systemVersion` returns the iOS
    /// compatibility version (e.g. "18.5"), not the macOS version the app is
    /// actually running on, so we use `ProcessInfo.operatingSystemVersion` instead.
    static var osVersion: String {
        #if targetEnvironment(macCatalyst)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #elseif os(watchOS)
        return WKInterfaceDevice.current().systemVersion
        #elseif canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    /// Device type reported as `$device_type`.
    /// Mac Catalyst reports "desktop" because the app is running on a Mac
    /// (the iPad idiom would otherwise report "tablet").
    static var deviceType: String {
        #if targetEnvironment(macCatalyst)
        return "desktop"
        #elseif os(iOS)
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

    /// Device model reported as `$device_model`.
    ///
    /// On iOS/tvOS/watchOS devices, `uname` machine gives the hardware
    /// identifier (e.g. "iPhone15,2"). On a Mac (native macOS or Mac Catalyst),
    /// `uname` machine only returns the architecture ("arm64"/"x86_64"), so we
    /// use `sysctl hw.model` to get the real model identifier (e.g. "Mac14,12").
    static var deviceModel: String? {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return sysctlString("hw.model") ?? unameMachine
        #elseif os(iOS) || os(tvOS) || os(watchOS)
        return unameMachine
        #else
        return nil
        #endif
    }

    // MARK: - Private Helpers

    /// Returns the `uname` machine identifier (e.g. "iPhone15,2", "arm64")
    private static var unameMachine: String? {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier.isEmpty ? nil : identifier
    }

    /// Reads a string value from sysctl by name (e.g. "hw.model")
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }
}
