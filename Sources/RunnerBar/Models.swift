import AppKit
import Foundation

struct GitHubRunnersResponse: Decodable, Sendable {
    var runners: [GitHubRunner]
}

struct GitHubRunner: Decodable, Sendable {
    var name: String
    var status: String
    var busy: Bool
    var labels: [GitHubRunnerLabel]
}

struct GitHubRunnerLabel: Decodable, Sendable {
    var name: String
}

struct GitHubRunsResponse: Decodable, Sendable {
    var workflowRuns: [GitHubRun]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

struct GitHubRun: Decodable, Sendable {
    var id: Int64
    var name: String?
    var displayTitle: String?
    var status: String
    var conclusion: String?
    var htmlURL: String
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case displayTitle = "display_title"
        case status
        case conclusion
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct GitHubJobsResponse: Decodable, Sendable {
    var jobs: [GitHubJob]
}

struct GitHubJob: Decodable, Sendable {
    var id: Int64
    var runID: Int64?
    var name: String
    var status: String
    var conclusion: String?
    var runnerName: String?
    var htmlURL: String?
    var startedAt: String?
    var completedAt: String?
    var labels: [String]?

    enum CodingKeys: String, CodingKey {
        case id
        case runID = "run_id"
        case name
        case status
        case conclusion
        case runnerName = "runner_name"
        case htmlURL = "html_url"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case labels
    }
}

struct RunnerRunActivity: Sendable {
    var runID: Int64
    var runName: String
    var jobName: String
    var status: String
    var runnerName: String?
    var htmlURL: String
}

struct RunnerLogEvent: Sendable {
    var timestamp: String
    var status: String
    var jobName: String
    var detail: String
}

enum ServiceState: String, Sendable {
    case started = "Started"
    case stopped = "Stopped"
    case notInstalled = "Not installed"
    case error = "Error"
}

struct RunnerSnapshot: Sendable {
    var parent: RunnerConfig
    var instance: RunnerInstance
    var serviceState: ServiceState
    var githubStatus: String?
    var busy: Bool?
    var labels: [String]
    var error: String?
    var currentRuns: [RunnerRunActivity]
    var recentEvents: [RunnerLogEvent]

    var isOnline: Bool {
        serviceState == .started && githubStatus == "online"
    }

    var isBusy: Bool {
        busy == true
    }
}

struct MachineHealth: Sendable {
    var diskFreePercent: Double?
    var diskFreeGB: Double?
    var diskTotalGB: Double?
    var colimaRunning: Bool?
    var colimaInstalled: Bool
    var dockerRunning: Bool?
    var error: String?

    func isLowDisk(thresholdPercent: Int) -> Bool {
        guard let p = diskFreePercent else { return false }
        return p < Double(thresholdPercent)
    }
}

enum WatchdogAlertKind: String, Sendable {
    case offline
    case hang
    case recoveryStarted
    case recoverySucceeded
    case recoveryFailed
}

struct WatchdogAlert: Sendable, Identifiable {
    var id: UUID = UUID()
    var timestamp: Date
    var kind: WatchdogAlertKind
    var instanceID: String?
    var displayName: String
    var detail: String
}

struct QueueHang: Sendable {
    var owner: String
    var repo: String
    var labels: [String]
    var jobName: String
    var runID: Int64
    var htmlURL: String?
}

struct PowerSnapshot: Sendable {
    var acSleep: String?
    var acDisplaySleep: String?
    var acDiskSleep: String?
    var acWakeOnNetwork: String?

    var isRunnerFriendly: Bool {
        acSleep == "0" && acDiskSleep == "0"
    }
}

struct ShellResult: Sendable {
    var status: Int32
    var output: String
}

struct AIHealthReport: Sendable {
    var status: String
    var detail: String
}

struct RunnerFormFields {
    var displayName: String
    var owner: String
    var repo: String
    var runnerName: String
    var runnerPath: String
    var labels: String
}

@MainActor
final class RunnerFormController: NSObject {
    var accepted = false
    weak var window: NSWindow?

    @objc func accept() {
        accepted = true
        NSApp.stopModal()
        window?.close()
    }

    @objc func cancel() {
        accepted = false
        NSApp.stopModal()
        window?.close()
    }
}

final class RunActionRef: NSObject {
    let runnerID: String
    let runID: Int64
    let url: String

    init(runnerID: String, runID: Int64, url: String) {
        self.runnerID = runnerID
        self.runID = runID
        self.url = url
    }
}

final class RunActionButton: NSButton {
    var actionRef: RunActionRef?
}

final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}
