import Foundation
import CryptoKit

/// How experiment variants are assigned.
public enum MGMExperimentMode {
    /// Variants are assigned by the server via `GET /v1/experiments` (default).
    case server

    /// Variants are assigned on device by hashing the experiment ID and user ID.
    /// Experiment configurations are fetched from `GET /v1/experiments/configs`,
    /// or provided inline via `MGMConfiguration.localExperiments` (no network at all).
    ///
    /// Privacy note: in local mode the user ID is never sent to the server for
    /// experiment assignment.
    case local
}

/// An experiment configuration used for local (on-device) variant assignment.
public struct MGMExperimentConfig: Codable, Equatable {
    /// The experiment's unique identifier (UUID). Used as the hash key, so it must
    /// match the server-side experiment ID for assignments to line up.
    public let id: String

    /// The experiment name (used with `getVariant(_:)` and in exposure events).
    public let name: String

    /// The variants to bucket users into. Every variant has equal weight.
    public let variants: [String]

    /// Creates a new experiment configuration.
    /// - Parameters:
    ///   - id: The experiment's unique identifier (UUID)
    ///   - name: The experiment name
    ///   - variants: The variants to bucket users into
    public init(id: String, name: String, variants: [String]) {
        self.id = id
        self.name = name
        self.variants = variants
    }
}

/// Deterministic on-device experiment bucketing.
///
/// The bucket is the first 8 bytes of `SHA256(utf8("<experiment_id>:<user_id>"))`
/// interpreted as a big-endian UInt64, and the variant is
/// `variants[bucket % variants.count]`. This must stay byte-for-byte identical
/// across all MostlyGoodMetrics SDKs so a user gets the same variant everywhere.
internal enum MGMLocalBucketing {
    /// Computes the bucket value for a (experiment, user) pair.
    /// - Parameters:
    ///   - experimentId: The experiment's unique identifier (UUID)
    ///   - userId: The effective user ID (identified user ID or anonymous ID)
    /// - Returns: The bucket as a big-endian UInt64 of the first 8 digest bytes
    static func bucket(experimentId: String, userId: String) -> UInt64 {
        let digest = SHA256.hash(data: Data("\(experimentId):\(userId)".utf8))
        return digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// Picks the variant for a (experiment, user) pair.
    /// - Parameters:
    ///   - experimentId: The experiment's unique identifier (UUID)
    ///   - userId: The effective user ID (identified user ID or anonymous ID)
    ///   - variants: The variants to bucket into
    /// - Returns: The deterministically assigned variant, or nil if `variants` is empty
    static func variant(experimentId: String, userId: String, variants: [String]) -> String? {
        guard !variants.isEmpty else { return nil }
        let bucket = bucket(experimentId: experimentId, userId: userId)
        return variants[Int(bucket % UInt64(variants.count))]
    }
}
