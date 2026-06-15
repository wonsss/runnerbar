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

/// How RunnerBar starts/supervises a runner.
/// - `service`: GitHub's `svc.sh` LaunchAgent. Robust & independent, but runs in a
///   background launchd session (no GUI/Aqua session) — iOS Simulator / UI test jobs
///   fail there (e.g. New Architecture TurboModule registration breaks → app crashes
///   with "RNGoogleSignin could not be found").
/// - `gui`: RunnerBar launches `./run.sh` as its own child process, so the runner
///   inherits RunnerBar's GUI (Aqua) session — required for Simulator/UI tests.
///   Trade-off: the runner is tied to RunnerBar's lifecycle (stops when RunnerBar quits).
enum RunnerMode: String, Codable, Sendable {
    case service
    case gui
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
    /// "service" (default) or "gui". See `RunnerMode`.
    var mode: String?

    var instanceCount: Int { max(1, replicas ?? 1) }

    var effectiveMode: RunnerMode { RunnerMode(rawValue: mode ?? "") ?? .service }

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
                labels: labels,
                mode: effectiveMode
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
    var mode: RunnerMode = .service

    var instanceID: String { "\(parentID)#\(index)" }
    var isGUI: Bool { mode == .gui }
}
