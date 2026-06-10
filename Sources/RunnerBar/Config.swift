import Foundation

struct RunnerBarConfig: Codable, Sendable {
    var language: String?
    var defaultAIProvider: String?
    var aiProviderFallbackOrder: [String]?
    var refreshIntervalSeconds: TimeInterval
    var runners: [RunnerConfig]
    var slackWebhookURL: String?
    var watchdog: WatchdogConfig?
    var diskWarnThresholdPercent: Int?

    var appLanguage: AppLanguage {
        AppLanguage(rawValue: language ?? "") ?? .english
    }

    var selectedAIProvider: AIProvider {
        AIProvider(rawValue: defaultAIProvider ?? "") ?? .codex
    }

    var effectiveAIFallbackOrder: [AIProvider] {
        let configured = aiProviderFallbackOrder?
            .compactMap(AIProvider.init(rawValue:)) ?? []
        if configured.isEmpty {
            return AIProvider.allCases
        }
        let missing = AIProvider.allCases.filter { !configured.contains($0) }
        return configured + missing
    }

    var effectiveWatchdog: WatchdogConfig {
        watchdog ?? .defaults
    }

    var effectiveDiskWarnThreshold: Int {
        diskWarnThresholdPercent ?? 15
    }
}

struct WatchdogConfig: Codable, Sendable {
    var enabled: Bool?
    var recoveryAttempts: Int?
    var recoveryBaseDelaySeconds: Double?
    var autoStartColima: Bool?

    static let defaults = WatchdogConfig(
        enabled: true,
        recoveryAttempts: 3,
        recoveryBaseDelaySeconds: 8,
        autoStartColima: true
    )

    var isEnabled: Bool { enabled ?? true }
    var maxAttempts: Int { recoveryAttempts ?? 3 }
    var baseDelay: Double { recoveryBaseDelaySeconds ?? 8 }
    var shouldStartColima: Bool { autoStartColima ?? true }
}

enum AppLanguage: String, Sendable {
    case english = "en"
    case korean = "ko"
}

enum AIProvider: String, CaseIterable, Sendable {
    case codex
    case claude

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }

    var healthPrompt: String { "Say READY in one word." }
}

struct RunnerConfig: Codable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var owner: String
    var repo: String
    var runnerName: String
    var runnerPath: String
    var labels: [String]
    var replicas: Int?

    var instanceCount: Int { max(1, replicas ?? 1) }

    func instances() -> [RunnerInstance] {
        (1...instanceCount).map { index in
            RunnerInstance(
                parentID: id,
                index: index,
                displayName: index == 1 ? displayName : "\(displayName) #\(index)",
                owner: owner,
                repo: repo,
                runnerName: Self.derivedRunnerName(base: runnerName, index: index),
                runnerPath: Self.derivedRunnerPath(base: runnerPath, index: index),
                labels: labels
            )
        }
    }

    static func derivedRunnerName(base: String, index: Int) -> String {
        index == 1 ? base : "\(base)-\(index)"
    }

    static func derivedRunnerPath(base: String, index: Int) -> String {
        index == 1 ? base : "\(base)-\(index)"
    }
}

struct RunnerInstance: Sendable, Hashable {
    var parentID: String
    var index: Int
    var displayName: String
    var owner: String
    var repo: String
    var runnerName: String
    var runnerPath: String
    var labels: [String]

    var instanceID: String { "\(parentID)#\(index)" }
}
