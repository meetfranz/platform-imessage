import Foundation
import IMessageCore

// Preference storage in this module is split across three backends:
//   1. `Preferences` (this enum) — in-memory toggles owned by Node module /
//      CLI bootstrap. Lost on process exit.
//   2. `Defaults.imessage` (UserDefaults) — durable user-tunable settings;
//      see Defaults.swift for keys.
//   3. `ProcessInfo.environment` — build/test escape hatches and CLI-set
//      values (IMESSAGE_LOGGING_DIR_PATH, IMESSAGE_USE_SECONDARY_INSTANCE,
//      IMESSAGE_HASHING_ENABLED).
//
// When adding a setting, pick by lifecycle: process-only → here; durable user
// pref → Defaults; build/test toggle → environment.
enum Preferences {
    private static let loggingDirectoryKey = "IMESSAGE_LOGGING_DIR_PATH"
    private static let secondaryInstanceKey = "IMESSAGE_USE_SECONDARY_INSTANCE"
    private static let hashingEnabledKey = "IMESSAGE_HASHING_ENABLED"

    private static var loggingEnabled = false
    private static var experiments = ""
    private static var secondaryInstance = false
    private static var hashing = configuredHashingEnabled(defaultEnabled: true)

    static var isLoggingEnabled: Bool {
        get { EmbeddingPolicy.isEmbedded ? false : loggingEnabled }
        set { if !EmbeddingPolicy.isEmbedded { loggingEnabled = newValue } }
    }
    static var enabledExperiments: String {
        get { EmbeddingPolicy.isEmbedded ? "" : experiments }
        set { if !EmbeddingPolicy.isEmbedded { experiments = newValue } }
    }
    static var useSecondaryMessagesInstance: Bool {
        get { EmbeddingPolicy.configuration?.useSecondaryInstance ?? secondaryInstance }
        set { if !EmbeddingPolicy.isEmbedded { secondaryInstance = newValue } }
    }
    static var hashingEnabled: Bool {
        get { EmbeddingPolicy.isEmbedded ? true : hashing }
        set { if !EmbeddingPolicy.isEmbedded { hashing = newValue } }
    }

    static var useSecondaryInstanceEnvironment: Bool? {
        EmbeddingPolicy.isEmbedded ? nil : boolEnvironmentValue(forKey: secondaryInstanceKey)
    }

    static var hashingEnabledEnvironment: Bool? {
        EmbeddingPolicy.isEmbedded ? nil : boolEnvironmentValue(forKey: hashingEnabledKey)
    }

    private static func boolEnvironmentValue(forKey key: String) -> Bool? {
        guard let value = ProcessInfo.processInfo.environment[key] else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !["0", "false", "no", "off"].contains(normalized)
    }

    private static func configuredHashingEnabled(defaultEnabled: Bool) -> Bool {
        hashingEnabledEnvironment ?? defaultEnabled
    }

    static func setLoggingDirectory(_ path: String) {
        guard !EmbeddingPolicy.isEmbedded else { return }
        setenv(loggingDirectoryKey, path, 1)
    }

    static func setUseSecondaryInstance(_ enabled: Bool) {
        guard !EmbeddingPolicy.isEmbedded else { return }
        setenv(secondaryInstanceKey, enabled ? "1" : "0", 1)
        useSecondaryMessagesInstance = enabled
    }

    static func configureHashing(defaultEnabled: Bool) {
        hashingEnabled = configuredHashingEnabled(defaultEnabled: defaultEnabled)
    }
}
