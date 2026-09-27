import Foundation

/// Process policy selected before any upstream preferences or diagnostics are used.
/// This configures isolation only; it does not start a host or qualify recipients.
public enum EmbeddingPolicy {
    public struct Configuration: Equatable {
        public let preferencesDomain: String
        public let useSecondaryInstance: Bool

        public init(preferencesDomain: String, useSecondaryInstance: Bool = false) {
            self.preferencesDomain = preferencesDomain
            self.useSecondaryInstance = useSecondaryInstance
        }
    }

    public enum ConfigurationError: Error {
        case invalidDomain
        case alreadyInUse
        case conflictingConfiguration
    }

    private enum Selection {
        case unselected
        case legacy
        case embedded(Configuration)
    }

    private static let lock = NSLock()
    private static var selection: Selection = .unselected

    public static func configure(_ configuration: Configuration) throws {
        let domain = configuration.preferencesDomain
        guard !domain.isEmpty, domain.count <= 200, domain.contains("."),
              !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains(".."),
              domain.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (65...90).contains($0.value) ||
                  (97...122).contains($0.value) || $0 == "." || $0 == "-"
              }),
              domain.lowercased() != "com.apple",
              !domain.lowercased().hasPrefix("com.apple."),
              domain.lowercased() != "com.automattic.beeper",
              !domain.lowercased().hasPrefix("com.automattic.beeper.") else {
            throw ConfigurationError.invalidDomain
        }
        lock.lock()
        defer { lock.unlock() }
        switch selection {
        case .unselected:
            selection = .embedded(configuration)
        case .legacy:
            throw ConfigurationError.alreadyInUse
        case .embedded(let existing):
            guard existing == configuration else {
                throw ConfigurationError.conflictingConfiguration
            }
        }
    }

    /// The first consumer seals legacy mode if configuration was omitted.
    /// No preference backend, file, environment or Apple API is touched here.
    public static var configuration: Configuration? {
        lock.lock()
        defer { lock.unlock() }
        switch selection {
        case .unselected:
            selection = .legacy
            return nil
        case .legacy:
            return nil
        case .embedded(let configuration):
            return configuration
        }
    }

    public static var isEmbedded: Bool { configuration != nil }
}
