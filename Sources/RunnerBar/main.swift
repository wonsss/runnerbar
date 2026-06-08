import AppKit
import Foundation

struct RunnerBarConfig: Codable, Sendable {
    var refreshIntervalSeconds: TimeInterval
    var runners: [RunnerConfig]
}

struct RunnerConfig: Codable, Identifiable, Sendable {
    var id: String
    var displayName: String
    var owner: String
    var repo: String
    var runnerName: String
    var runnerPath: String
    var labels: [String]
}

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

enum ServiceState: String, Sendable {
    case started = "Started"
    case stopped = "Stopped"
    case notInstalled = "Not installed"
    case error = "Error"
}

struct RunnerSnapshot: Sendable {
    var config: RunnerConfig
    var serviceState: ServiceState
    var githubStatus: String?
    var busy: Bool?
    var labels: [String]
    var error: String?
    var currentRuns: [RunnerRunActivity]
    var recentEvents: [String]

    var isOnline: Bool {
        serviceState == .started && githubStatus == "online"
    }

    var isBusy: Bool {
        busy == true
    }
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

enum Shell {
    static func run(_ arguments: [String], cwd: String? = nil) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallbackPath = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")
        environment["PATH"] = [environment["PATH"], fallbackPath].compactMap(\.self).joined(separator: ":")
        environment["HOME"] = home
        process.environment = environment
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ShellResult(status: 127, output: error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return ShellResult(status: process.terminationStatus, output: output)
    }

    static func runScript(_ script: String, cwd: String? = nil) -> ShellResult {
        run(["bash", "-lc", script], cwd: cwd)
    }

    static func quote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

final class RunnerMonitor: @unchecked Sendable {
    private let configURL: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configURL = home.appendingPathComponent(".runnerbar/config.json")
    }

    func loadConfig() -> RunnerBarConfig {
        if FileManager.default.fileExists(atPath: configURL.path) {
            do {
                let data = try Data(contentsOf: configURL)
                return try JSONDecoder().decode(RunnerBarConfig.self, from: data)
            } catch {
                return defaultConfig()
            }
        }

        let config = defaultConfig()
        try? saveConfig(config)
        return config
    }

    func configPath() -> String {
        configURL.path
    }

    func saveConfig(_ config: RunnerBarConfig) throws {
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.prettyPrinted.encode(config)
        try data.write(to: configURL)
    }

    func collect(config: RunnerBarConfig) -> ([RunnerSnapshot], PowerSnapshot) {
        let snapshots = config.runners.map { runner in
            let service = serviceState(for: runner)
            let github = githubRunner(for: runner)
            let error = github.error
            return RunnerSnapshot(
                config: runner,
                serviceState: service,
                githubStatus: github.runner?.status,
                busy: github.runner?.busy,
                labels: github.runner?.labels.map(\.name) ?? runner.labels,
                error: error,
                currentRuns: currentRuns(for: runner),
                recentEvents: recentEvents(for: runner)
            )
        }

        return (snapshots, powerState())
    }

    func start(_ runner: RunnerConfig) -> ShellResult {
        Shell.run(["./svc.sh", "start"], cwd: runner.runnerPath)
    }

    func stop(_ runner: RunnerConfig) -> ShellResult {
        Shell.run(["./svc.sh", "stop"], cwd: runner.runnerPath)
    }

    func restart(_ runner: RunnerConfig) -> ShellResult {
        _ = stop(runner)
        return start(runner)
    }

    func cancelRun(_ runner: RunnerConfig, runID: Int64) -> ShellResult {
        Shell.run(["gh", "api", "-X", "POST", "repos/\(runner.owner)/\(runner.repo)/actions/runs/\(runID)/cancel"])
    }

    func register(_ runner: RunnerConfig) -> ShellResult {
        let owner = Shell.quote(runner.owner)
        let repo = Shell.quote(runner.repo)
        let runnerName = Shell.quote(runner.runnerName)
        let runnerPath = Shell.quote(runner.runnerPath)
        let labels = Shell.quote(runner.labels.joined(separator: ","))

        let script = """
        set -euo pipefail

        OWNER=\(owner)
        REPO=\(repo)
        RUNNER_NAME=\(runnerName)
        RUNNER_DIR=\(runnerPath)
        LABELS=\(labels)

        mkdir -p "$RUNNER_DIR"
        cd "$RUNNER_DIR"

        if [ -f .runner ]; then
          echo "Runner is already configured at $RUNNER_DIR"
          exit 2
        fi

        if [ ! -x ./config.sh ]; then
          if [ -n "$(find . -mindepth 1 -maxdepth 1 -not -name '*.tar.gz' 2>/dev/null | head -n 1)" ]; then
            echo "Runner directory is not empty and does not contain config.sh: $RUNNER_DIR"
            exit 3
          fi

          TAG="$(gh api repos/actions/runner/releases/latest --jq '.tag_name')"
          ASSET="$(gh api repos/actions/runner/releases/latest --jq '.assets[] | select(.name | test("osx-arm64.*tar.gz$")) | .name' | head -n 1)"
          if [ -z "$TAG" ] || [ -z "$ASSET" ]; then
            echo "Could not resolve latest macOS arm64 runner release"
            exit 4
          fi

          gh release download "$TAG" --repo actions/runner --pattern "$ASSET" --clobber
          tar xzf "$ASSET"
        fi

        TOKEN="$(gh api -X POST "repos/$OWNER/$REPO/actions/runners/registration-token" --jq .token)"
        ./config.sh \
          --url "https://github.com/$OWNER/$REPO" \
          --token "$TOKEN" \
          --name "$RUNNER_NAME" \
          --labels "$LABELS" \
          --work _work \
          --unattended

        ./svc.sh install
        ./svc.sh start
        ./svc.sh status
        """

        return Shell.runScript(script)
    }

    private func serviceState(for runner: RunnerConfig) -> ServiceState {
        let result = Shell.run(["./svc.sh", "status"], cwd: runner.runnerPath)
        if result.status != 0 {
            return .error
        }
        if result.output.contains("Started:") {
            return .started
        }
        if result.output.contains("Stopped") {
            return .stopped
        }
        if result.output.contains("not installed") {
            return .notInstalled
        }
        return .error
    }

    private func githubRunner(for runner: RunnerConfig) -> (runner: GitHubRunner?, error: String?) {
        let path = "repos/\(runner.owner)/\(runner.repo)/actions/runners"
        let result = Shell.run(["gh", "api", path])
        if result.status != 0 {
            return (nil, result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        do {
            let response = try JSONDecoder().decode(GitHubRunnersResponse.self, from: Data(result.output.utf8))
            return (response.runners.first { $0.name == runner.runnerName }, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func currentRuns(for runner: RunnerConfig) -> [RunnerRunActivity] {
        let inProgress = workflowRuns(for: runner, status: "in_progress")
        let queued = workflowRuns(for: runner, status: "queued")
        let runs = Array((inProgress + queued).prefix(12))
        var activities: [RunnerRunActivity] = []

        for run in runs {
            let jobs = jobs(for: runner, runID: run.id)
            let matchingJobs = jobs.filter { job in
                if let runnerName = job.runnerName {
                    return runnerName == runner.runnerName
                }
                return run.status == "queued"
            }

            if matchingJobs.isEmpty, run.status == "queued" {
                activities.append(
                    RunnerRunActivity(
                        runID: run.id,
                        runName: run.displayTitle ?? run.name ?? "Queued run",
                        jobName: "Waiting for matching runner",
                        status: run.status,
                        runnerName: nil,
                        htmlURL: run.htmlURL
                    )
                )
            } else {
                activities.append(contentsOf: matchingJobs.map { job in
                    RunnerRunActivity(
                        runID: run.id,
                        runName: run.displayTitle ?? run.name ?? "Workflow run",
                        jobName: job.name,
                        status: job.status,
                        runnerName: job.runnerName,
                        htmlURL: job.htmlURL ?? run.htmlURL
                    )
                })
            }
        }

        return Array(activities.prefix(8))
    }

    private func workflowRuns(for runner: RunnerConfig, status: String) -> [GitHubRun] {
        let result = Shell.run(["gh", "api", "repos/\(runner.owner)/\(runner.repo)/actions/runs", "-f", "status=\(status)", "-f", "per_page=10"])
        guard result.status == 0 else { return [] }
        do {
            return try JSONDecoder().decode(GitHubRunsResponse.self, from: Data(result.output.utf8)).workflowRuns
        } catch {
            return []
        }
    }

    private func jobs(for runner: RunnerConfig, runID: Int64) -> [GitHubJob] {
        let result = Shell.run(["gh", "api", "repos/\(runner.owner)/\(runner.repo)/actions/runs/\(runID)/jobs", "-f", "per_page=100"])
        guard result.status == 0 else { return [] }
        do {
            return try JSONDecoder().decode(GitHubJobsResponse.self, from: Data(result.output.utf8)).jobs
        } catch {
            return []
        }
    }

    private func recentEvents(for runner: RunnerConfig) -> [String] {
        guard let logPath = serviceStdoutLogPath(for: runner) else {
            return []
        }
        let result = Shell.run(["tail", "-n", "160", logPath])
        guard result.status == 0 else { return [] }
        let lines = result.output
            .split(separator: "\n")
            .map(String.init)
            .filter { line in
                line.contains("Running job:") || line.contains("Job ") && line.contains(" completed with result:")
            }
        return Array(lines.suffix(8).reversed())
    }

    private func serviceStdoutLogPath(for runner: RunnerConfig) -> String? {
        let serviceFile = URL(fileURLWithPath: runner.runnerPath).appendingPathComponent(".service").path
        guard let plistPath = try? String(contentsOfFile: serviceFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !plistPath.isEmpty
        else {
            return nil
        }
        let serviceName = URL(fileURLWithPath: plistPath).deletingPathExtension().lastPathComponent
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
            .appendingPathComponent(serviceName)
            .appendingPathComponent("stdout.log")
            .path
    }

    private func powerState() -> PowerSnapshot {
        let result = Shell.run(["pmset", "-g", "custom"])
        guard result.status == 0 else {
            return PowerSnapshot(acSleep: nil, acDisplaySleep: nil, acDiskSleep: nil, acWakeOnNetwork: nil)
        }

        var inAC = false
        var values: [String: String] = [:]
        for rawLine in result.output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "AC Power:" {
                inAC = true
                continue
            }
            if line == "Battery Power:" {
                inAC = false
                continue
            }
            guard inAC else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.count >= 2 {
                values[parts[0]] = parts[1]
            }
        }

        return PowerSnapshot(
            acSleep: values["sleep"],
            acDisplaySleep: values["displaysleep"],
            acDiskSleep: values["disksleep"],
            acWakeOnNetwork: values["womp"]
        )
    }

    private func defaultConfig() -> RunnerBarConfig {
        RunnerBarConfig(
            refreshIntervalSeconds: 20,
            runners: [
                RunnerConfig(
                    id: "reading-crew",
                    displayName: "Reading Crew",
                    owner: "wonsss",
                    repo: "reading-crew",
                    runnerName: "macbook-air-ai-analyzer",
                    runnerPath: "/Users/marco/actions-runner-readingcrew",
                    labels: ["readingcrew-ai-analyzer"]
                )
            ]
        )
    }

}

extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor = RunnerMonitor()
    private var config: RunnerBarConfig!
    private var snapshots: [RunnerSnapshot] = []
    private var power = PowerSnapshot(acSleep: nil, acDisplaySleep: nil, acDiskSleep: nil, acWakeOnNetwork: nil)
    private var timer: Timer?
    private var isRefreshing = false
    private var dashboardWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        config = monitor.loadConfig()
        configureStatusItem()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: max(config.refreshIntervalSeconds, 5), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func configureStatusItem() {
        statusItem.button?.target = self
        statusItem.button?.action = #selector(openMenu)
        updateTitle(color: .systemGray, text: "RB")
        rebuildMenu()
    }

    @objc private func openMenu() {
        rebuildMenu()
        statusItem.button?.performClick(nil)
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let monitor = monitor
        let currentConfig = config!
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = monitor.collect(config: currentConfig)
            Task { @MainActor in
                guard let self else { return }
                self.snapshots = result.0
                self.power = result.1
                self.isRefreshing = false
                self.updateTitleForCurrentState()
                self.rebuildMenu()
                self.rebuildDashboardIfVisible()
            }
        }
    }

    private func updateTitleForCurrentState() {
        if snapshots.contains(where: { $0.error != nil || $0.serviceState == .error }) {
            updateTitle(color: .systemRed, text: "RB")
        } else if snapshots.contains(where: { $0.isBusy }) {
            updateTitle(color: .systemBlue, text: "RB")
        } else if snapshots.contains(where: { $0.serviceState == .started && $0.githubStatus != "online" }) {
            updateTitle(color: .systemYellow, text: "RB")
        } else if snapshots.allSatisfy(\.isOnline) && !snapshots.isEmpty {
            updateTitle(color: .systemGreen, text: "RB")
        } else {
            updateTitle(color: .systemGray, text: "RB")
        }
    }

    private func updateTitle(color: NSColor, text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        ]
        statusItem.button?.attributedTitle = NSAttributedString(string: "● \(text)", attributes: attributes)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "RunnerBar  \(overallSummary())", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(actionItem("Open Dashboard...", selector: #selector(openDashboard)))
        menu.addItem(actionItem("Refresh Now", selector: #selector(refreshAction)))
        menu.addItem(actionItem("Start All Runners", selector: #selector(startAllRunners)))
        menu.addItem(actionItem("Stop All Runners", selector: #selector(stopAllRunners)))
        menu.addItem(actionItem("Restart All Runners", selector: #selector(restartAllRunners)))
        menu.addItem(.separator())

        for snapshot in snapshots {
            addRunner(snapshot, to: menu)
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("Register New GitHub Runner...", selector: #selector(registerRepositoryRunner)))
        menu.addItem(actionItem("Add Existing Runner Config...", selector: #selector(addRepositoryRunner)))
        menu.addItem(actionItem("Config Settings...", selector: #selector(configSettings)))
        menu.addItem(actionItem("Reload Config", selector: #selector(reloadConfig)))
        menu.addItem(actionItem("Open Config", selector: #selector(openConfig)))
        addPowerSection(to: menu)
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit", selector: #selector(quit)))
        statusItem.menu = menu
    }

    private func addRunner(_ snapshot: RunnerSnapshot, to menu: NSMenu) {
        let item = NSMenuItem(title: "\(snapshot.config.displayName)  \(compactSummary(snapshot))", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(NSMenuItem(title: summary(snapshot), action: nil, keyEquivalent: ""))
        submenu.addItem(NSMenuItem(title: "Repo: \(snapshot.config.owner)/\(snapshot.config.repo)", action: nil, keyEquivalent: ""))
        submenu.addItem(NSMenuItem(title: "Runner: \(snapshot.config.runnerName)", action: nil, keyEquivalent: ""))
        submenu.addItem(NSMenuItem(title: "Path: \(snapshot.config.runnerPath)", action: nil, keyEquivalent: ""))
        submenu.addItem(NSMenuItem(title: "Labels: \(snapshot.labels.joined(separator: ", "))", action: nil, keyEquivalent: ""))
        if let error = snapshot.error, !error.isEmpty {
            submenu.addItem(NSMenuItem(title: "GitHub error: \(error.prefix(90))", action: nil, keyEquivalent: ""))
        }

        submenu.addItem(.separator())
        submenu.addItem(actionItem("Start", selector: #selector(startRunner(_:)), representedObject: snapshot.config.id))
        submenu.addItem(actionItem("Stop", selector: #selector(stopRunner(_:)), representedObject: snapshot.config.id))
        submenu.addItem(actionItem("Restart", selector: #selector(restartRunner(_:)), representedObject: snapshot.config.id))
        submenu.addItem(.separator())
        submenu.addItem(actionItem("Open GitHub Runner Page", selector: #selector(openGitHubRunnerPage(_:)), representedObject: snapshot.config.id))
        submenu.addItem(actionItem("Open Runner Logs", selector: #selector(openRunnerLogs(_:)), representedObject: snapshot.config.id))
        submenu.addItem(actionItem("Remove From RunnerBar...", selector: #selector(removeRunner(_:)), representedObject: snapshot.config.id))
        item.submenu = submenu
        menu.addItem(item)
    }

    private func addPowerSection(to menu: NSMenu) {
        let status = power.isRunnerFriendly ? "OK" : "Needs attention"
        menu.addItem(NSMenuItem(title: "AC Power: \(status)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "sleep=\(power.acSleep ?? "?") displaysleep=\(power.acDisplaySleep ?? "?") disksleep=\(power.acDiskSleep ?? "?") womp=\(power.acWakeOnNetwork ?? "?")", action: nil, keyEquivalent: ""))
        if !power.isRunnerFriendly {
            menu.addItem(actionItem("Copy AC Sleep Fix Command", selector: #selector(copyPowerFixCommand)))
        }
    }

    private func summary(_ snapshot: RunnerSnapshot) -> String {
        let github = snapshot.githubStatus ?? "unknown"
        let busy = snapshot.busy == true ? "busy" : "idle"
        return "[service: \(snapshot.serviceState.rawValue), github: \(github), \(busy)]"
    }

    private func compactSummary(_ snapshot: RunnerSnapshot) -> String {
        if snapshot.error != nil || snapshot.serviceState == .error {
            return "Error"
        }
        if snapshot.isBusy {
            return "Busy"
        }
        if snapshot.isOnline {
            return "Online"
        }
        if snapshot.serviceState == .started {
            return "Starting/Offline"
        }
        return snapshot.serviceState.rawValue
    }

    private func overallSummary() -> String {
        guard !snapshots.isEmpty else { return "No runners" }
        let online = snapshots.filter(\.isOnline).count
        let busy = snapshots.filter(\.isBusy).count
        let errors = snapshots.filter { $0.error != nil || $0.serviceState == .error }.count
        if errors > 0 {
            return "\(online)/\(snapshots.count) online, \(errors) error"
        }
        if busy > 0 {
            return "\(online)/\(snapshots.count) online, \(busy) busy"
        }
        return "\(online)/\(snapshots.count) online"
    }

    private func actionItem(_ title: String, selector: Selector, representedObject: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        return item
    }

    private func runner(for item: NSMenuItem) -> RunnerConfig? {
        guard let id = item.representedObject as? String else { return nil }
        return config.runners.first { $0.id == id }
    }

    @objc private func refreshAction() {
        refresh()
    }

    @objc private func openDashboard() {
        if dashboardWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "RunnerBar Dashboard"
            window.minSize = NSSize(width: 820, height: 520)
            window.center()
            dashboardWindow = window
        }
        rebuildDashboard()
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func reloadConfig() {
        config = monitor.loadConfig()
        refresh()
    }

    @objc private func addRepositoryRunner() {
        let fields = RunnerFormFields(
            displayName: "",
            owner: "",
            repo: "",
            runnerName: "",
            runnerPath: "",
            labels: ""
        )
        guard let values = showRunnerForm(title: "Add Repository Runner", fields: fields) else {
            return
        }

        let repoID = values.repo
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let baseID = repoID.isEmpty ? UUID().uuidString : repoID
        let id = uniqueRunnerID(baseID)
        let labels = values.labels
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let runner = RunnerConfig(
            id: id,
            displayName: values.displayName.isEmpty ? values.repo : values.displayName,
            owner: values.owner,
            repo: values.repo,
            runnerName: values.runnerName,
            runnerPath: values.runnerPath,
            labels: labels
        )

        guard validate(runner) else { return }
        config.runners.append(runner)
        saveCurrentConfig()
    }

    @objc private func configSettings() {
        let refreshField = inputField(String(Int(config.refreshIntervalSeconds)), placeholder: "20")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.addArrangedSubview(row(label: "Refresh sec", field: refreshField, help: "How often RunnerBar refreshes local service, GitHub runner, and AC power status. Minimum is 5 seconds."))

        let alert = NSAlert()
        alert.messageText = "Config Settings"
        alert.informativeText = "These settings are saved to ~/.runnerbar/config.json."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let rawValue = refreshField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let interval = TimeInterval(rawValue), interval >= 5 else {
            showError("Invalid refresh interval", detail: "Refresh interval must be at least 5 seconds.")
            return
        }

        config.refreshIntervalSeconds = interval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(config.refreshIntervalSeconds, 5), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        saveCurrentConfig()
    }

    @objc private func registerRepositoryRunner() {
        let defaultOwner = currentGitHubLogin() ?? "wonsss"
        let fields = RunnerFormFields(
            displayName: "",
            owner: defaultOwner,
            repo: "",
            runnerName: "",
            runnerPath: "/Users/marco/actions-runners/",
            labels: ""
        )
        guard let values = showRunnerForm(title: "Register New GitHub Runner", fields: fields) else {
            return
        }

        let repoName = values.repo
        let repoID = repoName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let baseID = repoID.isEmpty ? UUID().uuidString : repoID
        let defaultLabel = repoID.isEmpty ? "self-hosted-runner" : "\(repoID)-runner"
        let labels = (values.labels.isEmpty ? defaultLabel : values.labels)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let runnerName = values.runnerName.isEmpty ? defaultRunnerName(repoID: repoID) : values.runnerName
        let runnerPath = normalizedRunnerPath(values.runnerPath, repoID: repoID)

        let runner = RunnerConfig(
            id: uniqueRunnerID(baseID),
            displayName: values.displayName.isEmpty ? repoName : values.displayName,
            owner: values.owner,
            repo: repoName,
            runnerName: runnerName,
            runnerPath: runnerPath,
            labels: labels
        )

        guard validateRegistration(runner) else { return }
        updateTitle(color: .systemYellow, text: "REG")

        let monitor = monitor
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = monitor.register(runner)
            Task { @MainActor in
                guard let self else { return }
                if result.status == 0 {
                    self.config.runners.append(runner)
                    self.saveCurrentConfig()
                    self.showInfo("Runner registered", detail: "\(runner.displayName) is registered and started.")
                } else {
                    self.updateTitleForCurrentState()
                    self.showError("Runner registration failed", detail: result.output.isEmpty ? "Command exited with \(result.status)." : result.output)
                }
            }
        }
    }

    @objc private func removeRunner(_ sender: NSMenuItem) {
        guard let runner = runner(for: sender) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(runner.displayName)?"
        alert.informativeText = "This only removes it from RunnerBar config. It does not unregister the GitHub runner or delete files."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        config.runners.removeAll { $0.id == runner.id }
        saveCurrentConfig()
    }

    @objc private func startAllRunners() {
        runBulkControl(action: monitor.start)
    }

    @objc private func stopAllRunners() {
        runBulkControl(action: monitor.stop)
    }

    @objc private func restartAllRunners() {
        runBulkControl(action: monitor.restart)
    }

    @objc private func startRunner(_ sender: NSMenuItem) {
        runControl(sender, action: monitor.start)
    }

    @objc private func stopRunner(_ sender: NSMenuItem) {
        runControl(sender, action: monitor.stop)
    }

    @objc private func restartRunner(_ sender: NSMenuItem) {
        runControl(sender, action: monitor.restart)
    }

    private func runControl(_ sender: NSMenuItem, action: @escaping @Sendable (RunnerConfig) -> ShellResult) {
        guard let runner = runner(for: sender) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = action(runner)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        }
    }

    private func runBulkControl(action: @escaping @Sendable (RunnerConfig) -> ShellResult) {
        let runners = config.runners
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for runner in runners {
                _ = action(runner)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        }
    }

    private func rebuildDashboardIfVisible() {
        guard dashboardWindow?.isVisible == true else { return }
        rebuildDashboard()
    }

    private func rebuildDashboard() {
        guard let window = dashboardWindow else { return }
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let content = NSStackView()
        content.orientation = .vertical
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        content.translatesAutoresizingMaskIntoConstraints = false

        content.addArrangedSubview(dashboardHeader())
        content.addArrangedSubview(powerCard())

        if snapshots.isEmpty {
            content.addArrangedSubview(textLabel("No runners configured.", size: 14, color: .secondaryLabelColor))
        } else {
            for snapshot in snapshots {
                content.addArrangedSubview(runnerCard(snapshot))
            }
        }

        scrollView.documentView = content
        window.contentView = scrollView

        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])
    }

    private func dashboardHeader() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12

        let title = textLabel("RunnerBar Dashboard", size: 20, color: .labelColor, weight: .semibold)
        let summary = textLabel(overallSummary(), size: 13, color: .secondaryLabelColor)
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshAction))
        refreshButton.bezelStyle = .rounded

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(summary)
        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(refreshButton)
        return stack
    }

    private func powerCard() -> NSView {
        let box = card()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let status = power.isRunnerFriendly ? "Runner-friendly" : "Needs attention"
        stack.addArrangedSubview(textLabel("Mac Power Policy  \(status)", size: 15, color: power.isRunnerFriendly ? .systemGreen : .systemOrange, weight: .semibold))
        stack.addArrangedSubview(textLabel("AC sleep=\(power.acSleep ?? "?")  display=\(power.acDisplaySleep ?? "?")  disk=\(power.acDiskSleep ?? "?")  wake-on-network=\(power.acWakeOnNetwork ?? "?")", size: 12, color: .secondaryLabelColor))
        if !power.isRunnerFriendly {
            let button = NSButton(title: "Copy Sleep Fix Command", target: self, action: #selector(copyPowerFixCommand))
            button.bezelStyle = .rounded
            stack.addArrangedSubview(button)
        }

        box.contentView?.addSubview(stack)
        pin(stack, to: box.contentView)
        return box
    }

    private func runnerCard(_ snapshot: RunnerSnapshot) -> NSView {
        let box = card()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.addArrangedSubview(textLabel(snapshot.config.displayName, size: 16, color: .labelColor, weight: .semibold))
        header.addArrangedSubview(textLabel("\(snapshot.config.owner)/\(snapshot.config.repo)", size: 12, color: .secondaryLabelColor))
        header.addArrangedSubview(spacer())
        header.addArrangedSubview(statusBadge(compactSummary(snapshot), snapshot: snapshot))
        stack.addArrangedSubview(header)

        stack.addArrangedSubview(textLabel("Service: \(snapshot.serviceState.rawValue)   GitHub: \(snapshot.githubStatus ?? "unknown")   Runner: \(snapshot.config.runnerName)", size: 12, color: .secondaryLabelColor))
        stack.addArrangedSubview(textLabel("Labels: \(snapshot.labels.joined(separator: ", "))", size: 12, color: .secondaryLabelColor))

        if let error = snapshot.error, !error.isEmpty {
            stack.addArrangedSubview(textLabel("GitHub error: \(error)", size: 12, color: .systemRed))
        }

        stack.addArrangedSubview(sectionTitle("Current Requests"))
        if snapshot.currentRuns.isEmpty {
            stack.addArrangedSubview(textLabel("No active or queued requests for this runner.", size: 12, color: .secondaryLabelColor))
        } else {
            for activity in snapshot.currentRuns {
                stack.addArrangedSubview(activityRow(activity, runnerID: snapshot.config.id))
            }
        }

        stack.addArrangedSubview(sectionTitle("Recent Runner Events"))
        if snapshot.recentEvents.isEmpty {
            stack.addArrangedSubview(textLabel("No recent local runner events found.", size: 12, color: .secondaryLabelColor))
        } else {
            for event in snapshot.recentEvents {
                stack.addArrangedSubview(textLabel(event, size: 11, color: .secondaryLabelColor))
            }
        }

        box.contentView?.addSubview(stack)
        pin(stack, to: box.contentView)
        return box
    }

    private func activityRow(_ activity: RunnerRunActivity, runnerID: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let text = "\(activity.status.uppercased())  \(activity.runName)  ->  \(activity.jobName)"
        row.addArrangedSubview(textLabel(text, size: 12, color: .labelColor))
        row.addArrangedSubview(spacer())

        let open = RunActionButton(title: "Open", target: self, action: #selector(openRun(_:)))
        open.bezelStyle = .rounded
        open.actionRef = RunActionRef(runnerID: runnerID, runID: activity.runID, url: activity.htmlURL)
        row.addArrangedSubview(open)

        let cancel = RunActionButton(title: "Cancel", target: self, action: #selector(cancelRun(_:)))
        cancel.bezelStyle = .rounded
        cancel.actionRef = RunActionRef(runnerID: runnerID, runID: activity.runID, url: activity.htmlURL)
        row.addArrangedSubview(cancel)

        return row
    }

    private func card() -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 8
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        return box
    }

    private func textLabel(_ text: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        textLabel(text, size: 13, color: .labelColor, weight: .semibold)
    }

    private func statusBadge(_ text: String, snapshot: RunnerSnapshot) -> NSTextField {
        let color: NSColor
        if snapshot.error != nil || snapshot.serviceState == .error {
            color = .systemRed
        } else if snapshot.isBusy {
            color = .systemBlue
        } else if snapshot.isOnline {
            color = .systemGreen
        } else {
            color = .secondaryLabelColor
        }
        return textLabel(text, size: 13, color: color, weight: .semibold)
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func pin(_ child: NSView, to parent: NSView?) {
        guard let parent else { return }
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }

    @objc private func openRun(_ sender: RunActionButton) {
        guard let action = sender.actionRef,
              let url = URL(string: action.url)
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func cancelRun(_ sender: RunActionButton) {
        guard let action = sender.actionRef,
              let runner = config.runners.first(where: { $0.id == action.runnerID })
        else { return }

        let alert = NSAlert()
        alert.messageText = "Cancel workflow run?"
        alert.informativeText = "This sends a GitHub cancel request for run \(action.runID)."
        alert.addButton(withTitle: "Cancel Run")
        alert.addButton(withTitle: "Keep Running")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let monitor = monitor
        let runID = action.runID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = monitor.cancelRun(runner, runID: runID)
            Task { @MainActor in
                guard let self else { return }
                if result.status != 0 {
                    self.showError("Cancel failed", detail: result.output)
                }
                self.refresh()
            }
        }
    }

    private func saveCurrentConfig() {
        do {
            try monitor.saveConfig(config)
            refresh()
        } catch {
            showError("Could not save config", detail: error.localizedDescription)
        }
    }

    private func validate(_ runner: RunnerConfig) -> Bool {
        if runner.owner.isEmpty || runner.repo.isEmpty || runner.runnerName.isEmpty || runner.runnerPath.isEmpty {
            showError("Missing runner fields", detail: "Owner, repo, runner name, and runner path are required.")
            return false
        }
        if config.runners.contains(where: { $0.owner == runner.owner && $0.repo == runner.repo && $0.runnerName == runner.runnerName }) {
            showError("Runner already exists", detail: "\(runner.owner)/\(runner.repo) already has \(runner.runnerName) in RunnerBar.")
            return false
        }
        if !FileManager.default.fileExists(atPath: "\(runner.runnerPath)/svc.sh") {
            showError("Runner path is not ready", detail: "Expected svc.sh at \(runner.runnerPath). Register the runner first, then add it here.")
            return false
        }
        return true
    }

    private func validateRegistration(_ runner: RunnerConfig) -> Bool {
        if runner.owner.isEmpty || runner.repo.isEmpty || runner.runnerName.isEmpty || runner.runnerPath.isEmpty {
            showError("Missing runner fields", detail: "Owner, repo, runner name, and runner path are required.")
            return false
        }
        if runner.labels.isEmpty {
            showError("Missing label", detail: "Add at least one restrictive runner label. Workflows should target that label.")
            return false
        }
        if config.runners.contains(where: { $0.owner == runner.owner && $0.repo == runner.repo && $0.runnerName == runner.runnerName }) {
            showError("Runner already exists", detail: "\(runner.owner)/\(runner.repo) already has \(runner.runnerName) in RunnerBar.")
            return false
        }
        if FileManager.default.fileExists(atPath: "\(runner.runnerPath)/.runner") {
            showError("Runner already configured", detail: "\(runner.runnerPath) already contains a configured GitHub runner.")
            return false
        }
        return true
    }

    private func uniqueRunnerID(_ baseID: String) -> String {
        var candidate = baseID
        var index = 2
        while config.runners.contains(where: { $0.id == candidate }) {
            candidate = "\(baseID)-\(index)"
            index += 1
        }
        return candidate
    }

    private func currentGitHubLogin() -> String? {
        let result = Shell.run(["gh", "api", "user", "--jq", ".login"])
        guard result.status == 0 else { return nil }
        let login = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return login.isEmpty ? nil : login
    }

    private func defaultRunnerName(repoID: String) -> String {
        let host = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        if repoID.isEmpty {
            return "\(host)-runner"
        }
        return "\(host)-\(repoID)-runner"
    }

    private func normalizedRunnerPath(_ value: String, repoID: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let homeExpanded = trimmed.replacingOccurrences(
            of: "~",
            with: FileManager.default.homeDirectoryForCurrentUser.path,
            options: [.anchored]
        )
        guard !repoID.isEmpty else { return homeExpanded }
        if homeExpanded.hasSuffix("/") || homeExpanded == "/Users/marco/actions-runners" {
            return URL(fileURLWithPath: homeExpanded).appendingPathComponent(repoID).path
        }
        return homeExpanded
    }

    private func showRunnerForm(title: String, fields: RunnerFormFields) -> RunnerFormFields? {
        let displayName = inputField(fields.displayName, placeholder: "Reading Crew")
        let owner = inputField(fields.owner, placeholder: "wonsss")
        let repo = inputField(fields.repo, placeholder: "reading-crew")
        let runnerName = inputField(fields.runnerName, placeholder: "auto: macbook-air-<repo>-runner")
        let runnerPath = inputField(fields.runnerPath, placeholder: "/Users/marco/actions-runners/")
        let labels = inputField(fields.labels, placeholder: "auto: <repo>-runner")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.center()
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row(label: "Display name", field: displayName, help: "Name shown inside RunnerBar. It does not affect GitHub. Empty uses the repo name."))
        stack.addArrangedSubview(row(label: "Owner", field: owner, help: "GitHub user or organization that owns the target repository. Requires access through gh auth."))
        stack.addArrangedSubview(row(label: "Repo", field: repo, help: "Repository where the self-hosted runner will be registered. This field is required."))
        stack.addArrangedSubview(row(label: "Runner name", field: runnerName, help: "Exact runner name in GitHub settings. Empty auto-generates a Mac-and-repo-specific name."))
        stack.addArrangedSubview(row(label: "Runner path", field: runnerPath, help: "Local install directory. If it ends with '/', RunnerBar appends the repo name and creates that directory."))
        stack.addArrangedSubview(row(label: "Labels", field: labels, help: "Comma-separated workflow labels. Empty uses '<repo>-runner'. Use restrictive labels per repo."))

        let info = NSTextField(labelWithString: "Owner and repo are required. Empty runner name, runner path ending in '/', and empty labels are auto-filled from the repo.")
        info.translatesAutoresizingMaskIntoConstraints = false
        info.lineBreakMode = .byWordWrapping
        info.maximumNumberOfLines = 3
        info.textColor = .secondaryLabelColor

        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        let add = NSButton(title: "Add", target: nil, action: nil)
        add.translatesAutoresizingMaskIntoConstraints = false
        add.keyEquivalent = "\r"
        add.bezelStyle = .rounded

        let formController = RunnerFormController()
        formController.window = window
        add.target = formController
        add.action = #selector(RunnerFormController.accept)
        cancel.target = formController
        cancel.action = #selector(RunnerFormController.cancel)

        let buttonStack = NSStackView(views: [cancel, add])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 12
        buttonStack.alignment = .centerY
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(info)
        content.addSubview(stack)
        content.addSubview(buttonStack)
        window.contentView = content

        NSLayoutConstraint.activate([
            info.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            info.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            info.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttonStack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            buttonStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            buttonStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            cancel.widthAnchor.constraint(equalToConstant: 120),
            add.widthAnchor.constraint(equalToConstant: 120)
        ])

        window.makeFirstResponder(repo.stringValue.isEmpty ? repo : displayName)
        NSApp.runModal(for: window)

        guard formController.accepted else {
            return nil
        }

        return RunnerFormFields(
            displayName: displayName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            owner: owner.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            repo: repo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            runnerName: runnerName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            runnerPath: runnerPath.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            labels: labels.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func inputField(_ value: String, placeholder: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        return field
    }

    private func row(label: String, field: NSTextField, help: String) -> NSStackView {
        let text = NSTextField(labelWithString: label)
        text.alignment = .right
        text.widthAnchor.constraint(equalToConstant: 92).isActive = true
        field.widthAnchor.constraint(equalToConstant: 460).isActive = true

        let helpText = NSTextField(labelWithString: help)
        helpText.textColor = .secondaryLabelColor
        helpText.font = .systemFont(ofSize: 11)
        helpText.lineBreakMode = .byWordWrapping
        helpText.maximumNumberOfLines = 2
        helpText.widthAnchor.constraint(equalToConstant: 460).isActive = true

        let fieldStack = NSStackView(views: [field, helpText])
        fieldStack.orientation = .vertical
        fieldStack.spacing = 3

        let row = NSStackView(views: [text, fieldStack])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .top
        return row
    }

    private func showError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showInfo(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func openGitHubRunnerPage(_ sender: NSMenuItem) {
        guard let runner = runner(for: sender) else { return }
        let url = URL(string: "https://github.com/\(runner.owner)/\(runner.repo)/settings/actions/runners")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openRunnerLogs(_ sender: NSMenuItem) {
        guard let runner = runner(for: sender) else { return }
        let url = URL(fileURLWithPath: runner.runnerPath).appendingPathComponent("_diag")
        NSWorkspace.shared.open(url)
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(URL(fileURLWithPath: monitor.configPath()))
    }

    @objc private func copyPowerFixCommand() {
        let command = "sudo pmset -c sleep 0 displaysleep 30 disksleep 0 powernap 1 womp 1"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
