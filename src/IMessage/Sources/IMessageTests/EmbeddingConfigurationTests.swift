import Foundation
import IMessageCore
import Logging
import Testing
@testable import IMessage

// Run this filter in its own process: the production policy intentionally cannot reset.
// No host, permission API, Apple data, or persistent preferences are accessed.
@Test func embeddingConfigurationQualification() throws {
    let domain = "app.franz.qualification.\(UUID().uuidString)"
    let forbiddenFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    setenv("IMESSAGE_HASHING_ENABLED", "0", 1)
    setenv("IMESSAGE_USE_SECONDARY_INSTANCE", "0", 1)
    setenv("IMESSAGE_LOGGING_DIR_PATH", forbiddenFile.path, 1)

    try IMessageHost.configureForEmbedding(preferencesDomain: domain, useSecondaryInstance: true)
    try IMessageHost.configureForEmbedding(preferencesDomain: domain, useSecondaryInstance: true)
    #expect(EmbeddingPolicy.configuration?.preferencesDomain == domain)
    #expect(throws: EmbeddingPolicy.ConfigurationError.conflictingConfiguration) {
        try IMessageHost.configureForEmbedding(preferencesDomain: domain + ".other")
    }

    // Registration is volatile, not a persistent-domain write. Host construction is avoided.
    Defaults.registerDefaults()
    Defaults.imessage.register(defaults: [
        DefaultsKeys.misfirePrevention: false,
        DefaultsKeys.misfirePreventionFallbackStrategy: "sleep-only",
        DefaultsKeys.misfirePreventionTracing: true,
        DefaultsKeys.misfirePreventionTracingPII: true,
        DefaultsKeys.deepLinkTracingPII: true,
        DefaultsKeys.settingsMenuItemInjection: true,
    ])
    #expect(Defaults.imessage.bool(forKey: DefaultsKeys.misfirePrevention) == false)
    #expect(Defaults.misfirePreventionEnabled)
    #expect(Defaults.misfirePreventionFallbackStrategy == "focus-waiter")
    #expect(!Defaults.misfirePreventionTracing)
    #expect(!Defaults.misfirePreventionTracingPII)
    #expect(!Defaults.deepLinkTracingPII)

    IMessageHost.isLoggingEnabled = true
    IMessageHost.enabledExperiments = "synthetic-experiment"
    IMessageHost.useSecondaryMessagesInstance = false
    Preferences.configureHashing(defaultEnabled: false)
    Preferences.setLoggingDirectory("/synthetic/must-not-be-used")
    #expect(!IMessageHost.isLoggingEnabled)
    #expect(IMessageHost.enabledExperiments.isEmpty)
    #expect(IMessageHost.useSecondaryMessagesInstance)
    #expect(IMessageHost.isHashingEnabled)
    #expect(IMessageHost.useSecondaryInstanceEnvironment == nil)
    #expect(String(cString: getenv("IMESSAGE_LOGGING_DIR_PATH")) == forbiddenFile.path)

    var consoleCalls = 0
    Log.consoleEmitter = { _ in consoleCalls += 1 }
    Log.consoleOutputEnabled = true
    Log.file = forbiddenFile
    #expect(Log.file == nil)
    #expect(LogFileCoordinator.shared == nil)
    #expect(throws: LogFileCoordinator.InitializationError.disabledForEmbedding) {
        _ = try LogFileCoordinator(url: forbiddenFile)
    }
    Log.emitToConsole("SYNTHETIC_PRIVATE_SENTINEL")
    IMessageLogHandler(identifier: "qualification").log(event: .init(
        level: .error, message: "SYNTHETIC_PRIVATE_SENTINEL", metadata: nil,
        source: "qualification", file: #file, function: #function, line: #line
    ))
    Log.default.error("SYNTHETIC_PRIVATE_SENTINEL")
    Logger(imessageLabel: "qualification").warning("SYNTHETIC_PRIVATE_SENTINEL")
    #expect(consoleCalls == 0)
    #expect(!FileManager.default.fileExists(atPath: forbiddenFile.path))
}

@Test func embeddingRejectsLateLoggerQualification() throws {
    _ = Logger(imessageLabel: "qualification")
    #expect(throws: EmbeddingPolicy.ConfigurationError.alreadyInUse) {
        try IMessageHost.configureForEmbedding(preferencesDomain: "app.franz.qualification")
    }
}

@Test func embeddingRepeatedBootstrapQualification() throws {
    let domain = "app.franz.qualification.\(UUID().uuidString)"
    setenv("IMESSAGE_LOGGING_DIR_PATH", "/synthetic/unchanged", 1)
    try IMessageHost.configureForEmbedding(preferencesDomain: domain, useSecondaryInstance: true)
    IMessageHost.bootstrapWithOptions(dataDirPath: "/synthetic/never-open", verbose: true, useSecondaryInstance: false)
    IMessageHost.bootstrapWithOptions(dataDirPath: "/synthetic/also-never-open", verbose: true, useSecondaryInstance: false)
    #expect(!IMessageHost.isLoggingEnabled)
    #expect(IMessageHost.isHashingEnabled)
    #expect(IMessageHost.useSecondaryMessagesInstance)
    #expect(String(cString: getenv("IMESSAGE_LOGGING_DIR_PATH")) == "/synthetic/unchanged")
    #expect(Log.file == nil)
    #expect(LogFileCoordinator.shared == nil)
}
