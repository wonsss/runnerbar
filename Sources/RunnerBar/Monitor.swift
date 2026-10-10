import Foundation

struct MonitorReport: Sendable {
    var snapshots: [RunnerSnapshot]
    var power: PowerSnapshot
    var health: MachineHealth
    var hangs: [QueueHang]
}

final class RunnerMonitor: @unchecked Sendable {
    private let configURL: URL
    /// Supervises `gui`-mode runners (child processes in RunnerBar's GUI session).
    let guiSupervisor = GUIRunnerSupervisor.shared

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

    func collect(config: RunnerBarConfig) -> MonitorReport {
        var ghRunnersByRepo: [String: [GitHubRunner]] = [:]
        var ghRunnersError: [String: String] = [:]
        var queuedJobsByRepo: [String: [GitHubJob]] = [:]
        var snapshots: [RunnerSnapshot] = []

        for runner in config.runners {
            let repoKey = "\(runner.owner)/\(runner.repo)"
            if ghRunnersByRepo[repoKey] == nil && ghRunnersError[repoKey] == nil {
                let resp = fetchGitHubRunners(owner: runner.owner, repo: runner.repo)
                if let runners = resp.runners {
                    ghRunnersByRepo[repoKey] = runners
                } else {
                    ghRunnersError[repoKey] = resp.error
                }
            }
            if queuedJobsByRepo[repoKey] == nil {
                queuedJobsByRepo[repoKey] = collectQueuedJobs(owner: runner.owner, repo: runner.repo)
            }

            for instance in runner.instances() {
                let service = instance.isGUI
                    ? guiSupervisor.state(instance)
                    : serviceState(at: instance.runnerPath)
                let github = ghRunnersByRepo[repoKey]?.first { $0.name == instance.runnerName }
                let err = ghRunnersError[repoKey]
                snapshots.append(
                    RunnerSnapshot(
                        parent: runner,
                        instance: instance,
                        serviceState: service,
                        githubStatus: github?.status,
                        busy: github?.busy,
                        labels: github?.labels.map(\.name) ?? instance.labels,
                        error: err,
                        currentRuns: currentRuns(for: instance),
                        recentEvents: recentEvents(at: instance.runnerPath)
                    )
                )
            }
        }

        let hangs = computeQueueHangs(snapshots: snapshots, queuedByRepo: queuedJobsByRepo)
        return MonitorReport(
            snapshots: snapshots,
            power: powerState(),
            health: machineHealth(),
            hangs: hangs
        )
    }

    // MARK: - Lifecycle (parent-level — acts on all instances)

    func start(_ runner: RunnerConfig) -> ShellResult {
        var last = ShellResult(status: 0, output: "")
        for instance in runner.instances() {
            last = startInstance(instance)
        }
        return last
    }

    func stop(_ runner: RunnerConfig) -> ShellResult {
        var last = ShellResult(status: 0, output: "")
        for instance in runner.instances() {
            last = stopInstance(instance)
        }
        return last
    }

    func restart(_ runner: RunnerConfig) -> ShellResult {
        var last = ShellResult(status: 0, output: "")
        for instance in runner.instances() {
            last = restartInstance(instance)
        }
        return last
    }

    // MARK: - Per-instance lifecycle

    func startInstance(_ instance: RunnerInstance) -> ShellResult {
        if instance.isGUI {
            return guiSupervisor.start(instance)
        }
        return Shell.run(["./svc.sh", "start"], cwd: instance.runnerPath)
    }

    func stopInstance(_ instance: RunnerInstance) -> ShellResult {
        if instance.isGUI {
            return guiSupervisor.stop(instance)
        }
        return Shell.run(["./svc.sh", "stop"], cwd: instance.runnerPath)
    }

    func restartInstance(_ instance: RunnerInstance) -> ShellResult {
        if instance.isGUI {
            return guiSupervisor.restart(instance)
        }
        _ = stopInstance(instance)
        return startInstance(instance)
    }

    // MARK: - Power

    func applyRunnerPowerPolicy() -> ShellResult {
        let command = "pmset -c sleep 0 displaysleep 30 disksleep 0 powernap 1 womp 1"
        let script = """
        do shell script "\(command)" with administrator privileges
        """
        return Shell.run(["osascript", "-e", script])
    }

    func restoreDefaultPowerPolicy() -> ShellResult {
        let command = "pmset -c sleep 1 displaysleep 10 disksleep 10 powernap 1 womp 1"
        let script = """
        do shell script "\(command)" with administrator privileges
        """
        return Shell.run(["osascript", "-e", script])
    }

    // MARK: - GitHub Runs

    func cancelRun(owner: String, repo: String, runID: Int64) -> ShellResult {
        Shell.run(["gh", "api", "-X", "POST", "repos/\(owner)/\(repo)/actions/runs/\(runID)/cancel"])
    }

    // MARK: - Registration / Removal

    func registerInstance(_ instance: RunnerInstance) -> ShellResult {
        let owner = Shell.quote(instance.owner)
        let repo = Shell.quote(instance.repo)
        let runnerName = Shell.quote(instance.runnerName)
        let runnerPath = Shell.quote(instance.runnerPath)
        let labels = Shell.quote(instance.labels.joined(separator: ","))

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

        # LaunchAgent runners inherit launchd's minimal PATH — pin one that
        # covers Homebrew so workflow steps can find gh/rg/etc. Point the
        # setup-* toolcache at a writable shared dir — otherwise it tries the
        # hosted image's /Users/runner path and fails with Permission denied.
        # PNPM_HOME is per-instance: replicas sharing one store hit ENOTEMPTY
        # under concurrent installs.
        cat > .env <<ENV
        PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
        AGENT_TOOLSDIRECTORY=$HOME/actions-runners/_toolcache
        RUNNER_TOOL_CACHE=$HOME/actions-runners/_toolcache
        PNPM_HOME=$RUNNER_DIR/tools/pnpm
        ENV
        mkdir -p "$RUNNER_DIR/tools/pnpm"

        ./svc.sh install
        ./svc.sh start
        ./svc.sh status
        """

        return Shell.runScript(script)
    }

    func removeInstance(_ instance: RunnerInstance) -> ShellResult {
        let owner = Shell.quote(instance.owner)
        let repo = Shell.quote(instance.repo)
        let runnerPath = Shell.quote(instance.runnerPath)

        let script = """
        set -euo pipefail

        OWNER=\(owner)
        REPO=\(repo)
        RUNNER_DIR=\(runnerPath)

        cd "$RUNNER_DIR"

        if [ -x ./svc.sh ]; then
          ./svc.sh stop || true
          ./svc.sh uninstall || true
        fi

        if [ -f .runner ]; then
          TOKEN="$(gh api -X POST "repos/$OWNER/$REPO/actions/runners/remove-token" --jq .token)"
          ./config.sh remove --unattended --token "$TOKEN" || true
        fi

        echo "Instance removed."
        """

        return Shell.runScript(script)
    }

    // MARK: - Machine Health

    func machineHealth() -> MachineHealth {
        var disk: (free: Double?, total: Double?, percent: Double?) = (nil, nil, nil)
        let df = Shell.run(["df", "-k", "/"])
        if df.status == 0 {
            let lines = df.output.split(separator: "\n").map(String.init)
            if lines.count >= 2 {
                let parts = lines[1].split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if parts.count >= 4, let used1k = Double(parts[2]), let avail1k = Double(parts[3]) {
                    let total = used1k + avail1k
                    let freeGB = avail1k / 1024.0 / 1024.0
                    let totalGB = total / 1024.0 / 1024.0
                    let pct = total > 0 ? (avail1k / total) * 100.0 : 0
                    disk = (freeGB, totalGB, pct)
                }
            }
        }

        let colimaInstalled = Shell.run(["which", "colima"]).status == 0
        var colimaRunning: Bool? = nil
        if colimaInstalled {
            let result = Shell.run(["colima", "status"])
            if result.status == 0 {
                colimaRunning = result.output.localizedCaseInsensitiveContains("running")
            } else {
                colimaRunning = false
            }
        }

        let dockerInfo = Shell.run(["docker", "info"])
        let dockerRunning = dockerInfo.status == 0 ? true : (dockerInfo.output.isEmpty ? nil : false)

        return MachineHealth(
            diskFreePercent: disk.percent,
            diskFreeGB: disk.free,
            diskTotalGB: disk.total,
            colimaRunning: colimaRunning,
            colimaInstalled: colimaInstalled,
            dockerRunning: dockerRunning,
            error: nil
        )
    }

    func startColima() -> ShellResult {
        Shell.run(["colima", "start"])
    }

    func stopColima() -> ShellResult {
        Shell.run(["colima", "stop"])
    }

    func cleanupWork(instance: RunnerInstance) -> ShellResult {
        Shell.runScript("""
        set -e
        DIR=\(Shell.quote(instance.runnerPath))/_work
        if [ -d "$DIR" ]; then
          rm -rf "$DIR"/_temp "$DIR"/_tool 2>/dev/null || true
          find "$DIR" -type d -name node_modules -prune -exec rm -rf {} + 2>/dev/null || true
          echo "Cleaned $DIR"
        else
          echo "No _work directory at $DIR"
        fi
        """)
    }

    func dockerPrune() -> ShellResult {
        Shell.run(["docker", "system", "prune", "-af", "--volumes"])
    }

    func supabaseStop() -> ShellResult {
        Shell.run(["supabase", "stop"])
    }

    func cleanupSimulators() -> ShellResult {
        Shell.run(["xcrun", "simctl", "delete", "unavailable"])
    }

    // MARK: - Internal helpers

    private func fetchGitHubRunners(owner: String, repo: String) -> (runners: [GitHubRunner]?, error: String?) {
        let path = "repos/\(owner)/\(repo)/actions/runners"
        let result = Shell.run(["gh", "api", path])
        if result.status != 0 {
            return (nil, result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do {
            let response = try JSONDecoder().decode(GitHubRunnersResponse.self, from: Data(result.output.utf8))
            return (response.runners, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func collectQueuedJobs(owner: String, repo: String) -> [GitHubJob] {
        let runs = workflowRuns(owner: owner, repo: repo, status: "queued")
        var jobs: [GitHubJob] = []
        for run in runs.prefix(10) {
            jobs.append(contentsOf: self.jobs(owner: owner, repo: repo, runID: run.id))
        }
        return jobs.filter { $0.status == "queued" }
    }

    private func computeQueueHangs(snapshots: [RunnerSnapshot], queuedByRepo: [String: [GitHubJob]]) -> [QueueHang] {
        var hangs: [QueueHang] = []
        for (repoKey, jobs) in queuedByRepo {
            let parts = repoKey.split(separator: "/").map(String.init)
            guard parts.count == 2 else { continue }
            let owner = parts[0]
            let repo = parts[1]

            let onlineInstancesInRepo = snapshots.filter {
                $0.parent.owner == owner && $0.parent.repo == repo && $0.isOnline
            }

            for job in jobs {
                guard let labels = job.labels, !labels.isEmpty else { continue }
                let matching = onlineInstancesInRepo.contains { snap in
                    Set(labels).isSubset(of: Set(snap.labels))
                }
                if !matching {
                    hangs.append(
                        QueueHang(
                            owner: owner,
                            repo: repo,
                            labels: labels,
                            jobName: job.name,
                            runID: job.runID ?? 0,
                            htmlURL: job.htmlURL
                        )
                    )
                }
            }
        }
        return hangs
    }

    private func serviceState(at runnerPath: String) -> ServiceState {
        let result = Shell.run(["./svc.sh", "status"], cwd: runnerPath)
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

    private func currentRuns(for instance: RunnerInstance) -> [RunnerRunActivity] {
        let inProgress = workflowRuns(owner: instance.owner, repo: instance.repo, status: "in_progress")
        let queued = workflowRuns(owner: instance.owner, repo: instance.repo, status: "queued")
        let runs = Array((inProgress + queued).prefix(12))
        var activities: [RunnerRunActivity] = []

        for run in runs {
            let jobs = jobs(owner: instance.owner, repo: instance.repo, runID: run.id)
            let matchingJobs = jobs.filter { job in
                if let runnerName = job.runnerName {
                    return runnerName == instance.runnerName
                }
                // For queued runs without an assigned runner yet, attribute to the instance
                // only if the job's labels are satisfied by this instance's labels.
                if run.status == "queued" {
                    if let labels = job.labels, !labels.isEmpty {
                        return Set(labels).isSubset(of: Set(instance.labels))
                    }
                    return true
                }
                return false
            }

            if matchingJobs.isEmpty, run.status == "queued" {
                // Skip — hang detection surfaces this at the repo level.
                continue
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

    private func workflowRuns(owner: String, repo: String, status: String) -> [GitHubRun] {
        let result = Shell.run(["gh", "api", "repos/\(owner)/\(repo)/actions/runs", "-f", "status=\(status)", "-f", "per_page=10"])
        guard result.status == 0 else { return [] }
        do {
            return try JSONDecoder().decode(GitHubRunsResponse.self, from: Data(result.output.utf8)).workflowRuns
        } catch {
            return []
        }
    }

    private func jobs(owner: String, repo: String, runID: Int64) -> [GitHubJob] {
        let result = Shell.run(["gh", "api", "repos/\(owner)/\(repo)/actions/runs/\(runID)/jobs", "-f", "per_page=100"])
        guard result.status == 0 else { return [] }
        do {
            return try JSONDecoder().decode(GitHubJobsResponse.self, from: Data(result.output.utf8)).jobs
        } catch {
            return []
        }
    }

    private func recentEvents(at runnerPath: String) -> [RunnerLogEvent] {
        guard let logPath = serviceStdoutLogPath(at: runnerPath) else {
            return []
        }
        let result = Shell.run(["tail", "-n", "160", logPath])
        guard result.status == 0 else { return [] }
        let events = result.output
            .split(separator: "\n")
            .map(String.init)
            .compactMap(parseRunnerEvent)
        return Array(events.suffix(8).reversed())
    }

    private func parseRunnerEvent(_ line: String) -> RunnerLogEvent? {
        guard let separatorRange = line.range(of: ": ") else { return nil }
        let timestamp = String(line[..<separatorRange.lowerBound])
        let message = String(line[separatorRange.upperBound...])

        if let range = message.range(of: "Running job: ") {
            return RunnerLogEvent(
                timestamp: timestamp,
                status: "Running",
                jobName: String(message[range.upperBound...]),
                detail: "Job assigned to runner"
            )
        }

        if message.hasPrefix("Job "), let resultRange = message.range(of: " completed with result: ") {
            let start = message.index(message.startIndex, offsetBy: 4)
            return RunnerLogEvent(
                timestamp: timestamp,
                status: String(message[resultRange.upperBound...]),
                jobName: String(message[start..<resultRange.lowerBound]),
                detail: "Completed"
            )
        }

        return nil
    }

    private func serviceStdoutLogPath(at runnerPath: String) -> String? {
        let serviceFile = URL(fileURLWithPath: runnerPath).appendingPathComponent(".service").path
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
            language: AppLanguage.english.rawValue,
            defaultAIProvider: AIProvider.codex.rawValue,
            aiProviderFallbackOrder: AIProvider.allCases.map(\.rawValue),
            refreshIntervalSeconds: 20,
            runners: [],
            slackWebhookURL: nil,
            watchdog: WatchdogConfig.defaults,
            diskWarnThresholdPercent: 15
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
