import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let monitor = RunnerMonitor()
    private lazy var watchdog: Watchdog = {
        let w = Watchdog(monitor: monitor)
        w.onChange = { [weak self] in
            Task { @MainActor in
                self?.rebuildDashboardIfVisible()
                self?.updateTitleForCurrentState()
            }
        }
        return w
    }()
    private var config: RunnerBarConfig!
    private var snapshots: [RunnerSnapshot] = []
    private var power = PowerSnapshot(acSleep: nil, acDisplaySleep: nil, acDiskSleep: nil, acWakeOnNetwork: nil)
    private var health = MachineHealth(diskFreePercent: nil, diskFreeGB: nil, diskTotalGB: nil, colimaRunning: nil, colimaInstalled: false, dockerRunning: nil, error: nil)
    private var hangs: [QueueHang] = []
    private var timer: Timer?
    private var isRefreshing = false
    private var dashboardWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        config = monitor.loadConfig()
        watchdog.requestNotificationPermission()
        configureStatusItem()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: max(config.refreshIntervalSeconds, 5), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        startGUIRunnersIfNeeded()
    }

    /// `gui`-mode runners must be children of RunnerBar (this GUI/Aqua session) to run
    /// Simulator/UI jobs. Bring them up on launch; `applicationWillTerminate` stops them.
    private func startGUIRunnersIfNeeded() {
        let guiRunners = config.runners.filter { $0.effectiveMode == .gui }
        guard !guiRunners.isEmpty else { return }
        let monitor = self.monitor
        DispatchQueue.global(qos: .utility).async {
            for runner in guiRunners {
                for instance in runner.instances() {
                    _ = monitor.startInstance(instance)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // gui-mode runners are our children — stop them cleanly so jobs aren't left orphaned.
        monitor.guiSupervisor.stopAllTracked()
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
            let report = monitor.collect(config: currentConfig)
            Task { @MainActor in
                guard let self else { return }
                self.snapshots = report.snapshots
                self.power = report.power
                self.health = report.health
                self.hangs = report.hangs
                self.isRefreshing = false
                self.watchdog.evaluate(report: report, config: currentConfig)
                self.updateTitleForCurrentState()
                self.rebuildMenu()
                self.rebuildDashboardIfVisible()
            }
        }
    }

    private func updateTitleForCurrentState() {
        if watchdog.hasActiveAlert {
            updateTitle(color: .systemRed, text: "!")
        } else if snapshots.contains(where: { $0.error != nil || $0.serviceState == .error }) {
            updateTitle(color: .systemRed, text: "RB")
        } else if !hangs.isEmpty {
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
        menu.addItem(actionItem(t("openDashboard"), selector: #selector(openDashboard)))
        menu.addItem(actionItem(t("refreshNow"), selector: #selector(refreshAction)))
        menu.addItem(.separator())

        for snapshot in snapshots {
            addRunner(snapshot, to: menu)
        }

        menu.addItem(.separator())
        menu.addItem(managementMenu())
        menu.addItem(settingsMenu())
        addPowerSection(to: menu)
        menu.addItem(.separator())
        menu.addItem(actionItem(t("quit"), selector: #selector(quit)))
        statusItem.menu = menu
    }

    private func managementMenu() -> NSMenuItem {
        let item = NSMenuItem(title: t("manageRunners"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(actionItem(t("startAll"), selector: #selector(startAllRunners)))
        submenu.addItem(actionItem(t("stopAll"), selector: #selector(stopAllRunners)))
        submenu.addItem(actionItem(t("restartAll"), selector: #selector(restartAllRunners)))
        submenu.addItem(.separator())
        submenu.addItem(actionItem(t("registerRunner"), selector: #selector(registerRepositoryRunner)))
        submenu.addItem(actionItem(t("addExistingConfig"), selector: #selector(addRepositoryRunner)))
        item.submenu = submenu
        return item
    }

    private func settingsMenu() -> NSMenuItem {
        let item = NSMenuItem(title: t("settings"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(actionItem(t("configSettings"), selector: #selector(configSettings)))
        submenu.addItem(aiProviderMenu())
        submenu.addItem(actionItem(t("reloadConfig"), selector: #selector(reloadConfig)))
        submenu.addItem(actionItem(t("openConfig"), selector: #selector(openConfig)))
        submenu.addItem(.separator())
        let english = actionItem(t("languageEnglish"), selector: #selector(setEnglish))
        english.state = config.appLanguage == .english ? .on : .off
        let korean = actionItem(t("languageKorean"), selector: #selector(setKorean))
        korean.state = config.appLanguage == .korean ? .on : .off
        submenu.addItem(english)
        submenu.addItem(korean)
        item.submenu = submenu
        return item
    }

    private func aiProviderMenu() -> NSMenuItem {
        let item = NSMenuItem(title: t("aiProvider"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for provider in AIProvider.allCases {
            let providerItem = actionItem(provider.displayName, selector: #selector(setAIProvider(_:)), representedObject: provider.rawValue)
            providerItem.state = config.selectedAIProvider == provider ? .on : .off
            submenu.addItem(providerItem)
        }

        submenu.addItem(.separator())
        submenu.addItem(actionItem(t("aiFallbackOrder"), selector: #selector(toggleAIFallbackOrder)))
        submenu.addItem(actionItem(t("aiHealthCheck"), selector: #selector(runAIHealthCheck)))
        item.submenu = submenu
        return item
    }

    private func addRunner(_ snapshot: RunnerSnapshot, to menu: NSMenu) {
        let item = NSMenuItem(title: "\(snapshot.instance.displayName)  \(compactSummary(snapshot))", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(NSMenuItem(title: summary(snapshot), action: nil, keyEquivalent: ""))
        submenu.addItem(NSMenuItem(title: "Repo: \(snapshot.parent.owner)/\(snapshot.parent.repo)", action: nil, keyEquivalent: ""))
        submenu.addItem(NSMenuItem(title: "Runner: \(snapshot.instance.runnerName)", action: nil, keyEquivalent: ""))
        submenu.addItem(NSMenuItem(title: "Path: \(snapshot.instance.runnerPath)", action: nil, keyEquivalent: ""))
        submenu.addItem(NSMenuItem(title: "Labels: \(snapshot.labels.joined(separator: ", "))", action: nil, keyEquivalent: ""))
        if let error = snapshot.error, !error.isEmpty {
            submenu.addItem(NSMenuItem(title: "GitHub error: \(error.prefix(90))", action: nil, keyEquivalent: ""))
        }

        submenu.addItem(.separator())
        submenu.addItem(actionItem("Start", selector: #selector(startRunner(_:)), representedObject: snapshot.parent.id))
        submenu.addItem(actionItem("Stop", selector: #selector(stopRunner(_:)), representedObject: snapshot.parent.id))
        submenu.addItem(actionItem("Restart", selector: #selector(restartRunner(_:)), representedObject: snapshot.parent.id))
        submenu.addItem(.separator())
        submenu.addItem(actionItem(t("scaleUp"), selector: #selector(scaleUpRunner(_:)), representedObject: snapshot.parent.id))
        submenu.addItem(actionItem(t("scaleDown"), selector: #selector(scaleDownRunner(_:)), representedObject: snapshot.parent.id))
        submenu.addItem(.separator())
        submenu.addItem(actionItem("Open GitHub Runner Page", selector: #selector(openGitHubRunnerPage(_:)), representedObject: snapshot.parent.id))
        submenu.addItem(actionItem("Open Runner Logs", selector: #selector(openRunnerLogs(_:)), representedObject: snapshot.parent.id))
        submenu.addItem(actionItem("Remove From RunnerBar...", selector: #selector(removeRunner(_:)), representedObject: snapshot.parent.id))
        item.submenu = submenu
        menu.addItem(item)
    }

    private func addPowerSection(to menu: NSMenu) {
        let status = power.isRunnerFriendly ? t("runnerFriendly") : t("needsAttention")
        menu.addItem(NSMenuItem(title: "\(t("powerPolicy")): \(status)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "sleep=\(power.acSleep ?? "?") displaysleep=\(power.acDisplaySleep ?? "?") disksleep=\(power.acDiskSleep ?? "?") womp=\(power.acWakeOnNetwork ?? "?")", action: nil, keyEquivalent: ""))
        if !power.isRunnerFriendly {
            menu.addItem(actionItem("\(t("applyPower"))...", selector: #selector(applyPowerPolicy)))
            menu.addItem(actionItem(t("copyCommand"), selector: #selector(copyPowerFixCommand)))
        } else {
            menu.addItem(actionItem("\(t("restorePower"))...", selector: #selector(restorePowerPolicy)))
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

    private func t(_ key: String) -> String {
        Localization.t(key, language: config.appLanguage)
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
            window.title = t("dashboardTitle")
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

    @objc private func setEnglish() {
        config.language = AppLanguage.english.rawValue
        saveCurrentConfig()
    }

    @objc private func setKorean() {
        config.language = AppLanguage.korean.rawValue
        saveCurrentConfig()
    }

    @objc private func setAIProvider(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let provider = AIProvider(rawValue: rawValue)
        else { return }
        config.defaultAIProvider = provider.rawValue
        let currentFallbacks = config.effectiveAIFallbackOrder
        config.aiProviderFallbackOrder = ([provider] + currentFallbacks.filter { $0 != provider }).map(\.rawValue)
        saveCurrentConfig()
    }

    @objc private func toggleAIFallbackOrder() {
        let current = config.effectiveAIFallbackOrder
        let next: [AIProvider]
        if current.first == .codex {
            next = [.claude, .codex]
            config.defaultAIProvider = AIProvider.claude.rawValue
        } else {
            next = [.codex, .claude]
            config.defaultAIProvider = AIProvider.codex.rawValue
        }
        config.aiProviderFallbackOrder = next.map(\.rawValue)
        saveCurrentConfig()
    }

    @objc private func runAIHealthCheck() {
        let providers = config.effectiveAIFallbackOrder
        let cwd = aiHealthCheckCWD()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let lines = providers.map { provider -> String in
                let report = self?.runAIHealth(provider: provider, cwd: cwd)
                    ?? AIHealthReport(status: "FAILED", detail: "RunnerBar is not available.")
                return "\(provider.displayName): \(report.status)\nWorking directory: \(cwd)\n\(report.detail)"
            }
            Task { @MainActor in
                self?.showInfo("AI Health Check", detail: lines.joined(separator: "\n\n"))
            }
        }
    }

    private func aiHealthCheckCWD() -> String {
        let fileManager = FileManager.default
        for runner in config.runners {
            let worktree = "\(runner.runnerPath)/_work/\(runner.repo)/\(runner.repo)"
            if fileManager.fileExists(atPath: "\(worktree)/.git") {
                return worktree
            }
        }
        for candidate in ["runnerbar", "tools/runnerbar", "Documents/runnerbar"] {
            let path = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(candidate).path
            if fileManager.fileExists(atPath: "\(path)/.git") {
                return path
            }
        }
        return fileManager.homeDirectoryForCurrentUser.path
    }

    nonisolated private func runAIHealth(provider: AIProvider, cwd: String) -> AIHealthReport {
        switch provider {
        case .codex:
            let result = runCodexHealth(provider: provider, cwd: cwd)
            let ok = result.status == 0 && result.output.localizedCaseInsensitiveContains("READY")
            return AIHealthReport(status: ok ? "OK" : "FAILED", detail: summarizedOutput(result.output))
        case .claude:
            let execution = Shell.run(
                ["claude", "-p", provider.healthPrompt, "--max-turns", "1"],
                cwd: cwd,
                unsetEnvironmentKeys: ["ANTHROPIC_API_KEY", "CLAUDE_API_KEY"]
            )
            if execution.status == 0 && execution.output.localizedCaseInsensitiveContains("READY") {
                return AIHealthReport(status: "OK", detail: summarizedOutput(execution.output))
            }

            let auth = Shell.run(
                ["claude", "auth", "status"],
                cwd: cwd,
                unsetEnvironmentKeys: ["ANTHROPIC_API_KEY", "CLAUDE_API_KEY"]
            )
            if auth.status == 0 && auth.output.localizedCaseInsensitiveContains("\"loggedIn\": true") {
                return AIHealthReport(
                    status: "CONNECTED",
                    detail: "Claude Code login is active. Non-interactive execution still failed:\n\(summarizedOutput(execution.output))"
                )
            }
            return AIHealthReport(status: "FAILED", detail: summarizedOutput(execution.output))
        }
    }

    nonisolated private func runCodexHealth(provider: AIProvider, cwd: String) -> ShellResult {
        let result = Shell.run(["codex", "exec", provider.healthPrompt], cwd: cwd)
        if result.status != 0 && result.output.localizedCaseInsensitiveContains("trusted directory") {
            return Shell.run(["codex", "exec", "--skip-git-repo-check", provider.healthPrompt], cwd: cwd)
        }
        return result
    }

    nonisolated private func summarizedOutput(_ output: String) -> String {
        let summary = output
            .split(separator: "\n")
            .prefix(6)
            .joined(separator: "\n")
        if summary.isEmpty {
            return "(no output)"
        }
        return summary
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
        guard let values = showRunnerForm(title: t("addExistingConfig"), fields: fields) else {
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
        let slackField = inputField(config.slackWebhookURL ?? "", placeholder: "https://hooks.slack.com/services/...")
        let diskField = inputField(String(config.effectiveDiskWarnThreshold), placeholder: "15")
        let watchdogCheckbox = NSButton(checkboxWithTitle: t("watchdogEnabled"), target: nil, action: nil)
        watchdogCheckbox.state = config.effectiveWatchdog.isEnabled ? .on : .off

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.addArrangedSubview(row(label: "Refresh sec", field: refreshField, help: "How often RunnerBar refreshes local service, GitHub runner, and AC power status. Minimum is 5 seconds."))
        stack.addArrangedSubview(row(label: "Disk warn %", field: diskField, help: "Free-disk threshold below which the dashboard warns and the cleanup button is suggested."))
        stack.addArrangedSubview(row(label: t("watchdogSlackWebhook"), field: slackField, help: t("watchdogSlackHelp")))
        stack.addArrangedSubview(watchdogCheckbox)

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
        let slackVal = slackField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.slackWebhookURL = slackVal.isEmpty ? nil : slackVal
        if let diskInt = Int(diskField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
           diskInt > 0 && diskInt < 100 {
            config.diskWarnThresholdPercent = diskInt
        }
        var wd = config.effectiveWatchdog
        wd.enabled = watchdogCheckbox.state == .on
        config.watchdog = wd

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(config.refreshIntervalSeconds, 5), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        saveCurrentConfig()
    }

    @objc private func registerRepositoryRunner() {
        let defaultRunnerDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("actions-runners").path + "/"
        let fields = RunnerFormFields(
            displayName: "",
            owner: currentGitHubLogin() ?? "",
            repo: "",
            runnerName: "",
            runnerPath: defaultRunnerDir,
            labels: ""
        )
        guard let values = showRunnerForm(title: t("registerRunner"), fields: fields) else {
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
            // Register the first instance only — replicas can be scaled up afterwards.
            let firstInstance = runner.instances().first!
            let result = monitor.registerInstance(firstInstance)
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
        content.alignment = .leading

        content.addArrangedSubview(dashboardHeader())
        content.addArrangedSubview(machineHealthHostView())
        content.addArrangedSubview(watchdogHostView())
        content.addArrangedSubview(labelGroupHostView())
        content.addArrangedSubview(aiProviderCard())
        content.addArrangedSubview(powerCard())

        if snapshots.isEmpty {
            content.addArrangedSubview(textLabel("No runners configured.", size: 14, color: .secondaryLabelColor))
        } else {
            for snapshot in snapshots {
                content.addArrangedSubview(runnerCard(snapshot))
            }
        }

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scrollView.documentView = document
        window.contentView = scrollView

        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
    }

    private func watchdogHostView() -> NSView {
        let view = WatchdogLogCard(
            language: config.appLanguage,
            alerts: watchdog.log,
            enabled: config.effectiveWatchdog.isEnabled
        )
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.widthAnchor.constraint(equalToConstant: 920).isActive = true
        return host
    }

    private func machineHealthHostView() -> NSView {
        let view = MachineHealthCard(
            language: config.appLanguage,
            health: health,
            diskThreshold: config.effectiveDiskWarnThreshold,
            onStartColima: { [weak self] in self?.startColima() },
            onStopColima: { [weak self] in self?.stopColima() },
            onCleanup: { [weak self] in self?.openCleanupSheet() }
        )
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.widthAnchor.constraint(equalToConstant: 920).isActive = true
        return host
    }

    private func labelGroupHostView() -> NSView {
        let groups = config.runners.map { parent -> LabelGroupSummaryCard.Group in
            let instances = snapshots.filter { $0.parent.id == parent.id }
            let total = parent.instanceCount
            let online = instances.filter(\.isOnline).count
            let busy = instances.filter(\.isBusy).count
            return LabelGroupSummaryCard.Group(
                id: parent.id,
                displayName: parent.displayName,
                total: total,
                online: online,
                busy: busy,
                labels: parent.labels
            )
        }
        let view = LabelGroupSummaryCard(language: config.appLanguage, groups: groups)
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.widthAnchor.constraint(equalToConstant: 920).isActive = true
        return host
    }

    private func dashboardHeader() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12

        let title = textLabel(t("dashboardTitle"), size: 20, color: .labelColor, weight: .semibold)
        let summary = textLabel(overallSummary(), size: 13, color: .secondaryLabelColor)
        let refreshButton = NSButton(title: t("refreshNow"), target: self, action: #selector(refreshAction))
        refreshButton.bezelStyle = .rounded

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(summary)
        stack.addArrangedSubview(spacer())
        stack.addArrangedSubview(refreshButton)
        stack.widthAnchor.constraint(equalToConstant: 920).isActive = true
        return stack
    }

    private func powerCard() -> NSView {
        let box = card()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let status = power.isRunnerFriendly ? t("runnerFriendly") : t("needsAttention")
        stack.addArrangedSubview(textLabel("\(t("powerPolicy"))  \(status)", size: 15, color: power.isRunnerFriendly ? .systemGreen : .systemOrange, weight: .semibold))
        stack.addArrangedSubview(textLabel("AC sleep=\(power.acSleep ?? "?")  display=\(power.acDisplaySleep ?? "?")  disk=\(power.acDiskSleep ?? "?")  wake-on-network=\(power.acWakeOnNetwork ?? "?")", size: 12, color: .secondaryLabelColor))
        stack.addArrangedSubview(textLabel(powerPolicyExplanation(), size: 11, color: .secondaryLabelColor))
        if !power.isRunnerFriendly {
            let buttons = NSStackView()
            buttons.orientation = .horizontal
            buttons.spacing = 10
            let apply = NSButton(title: t("applyPower"), target: self, action: #selector(applyPowerPolicy))
            apply.bezelStyle = .rounded
            let copy = NSButton(title: t("copyCommand"), target: self, action: #selector(copyPowerFixCommand))
            copy.bezelStyle = .rounded
            buttons.addArrangedSubview(apply)
            buttons.addArrangedSubview(copy)
            stack.addArrangedSubview(buttons)
        } else {
            let restore = NSButton(title: t("restorePower"), target: self, action: #selector(restorePowerPolicy))
            restore.bezelStyle = .rounded
            stack.addArrangedSubview(restore)
        }

        box.contentView?.addSubview(stack)
        pin(stack, to: box.contentView)
        box.widthAnchor.constraint(equalToConstant: 760).isActive = true
        return box
    }

    private func aiProviderCard() -> NSView {
        let box = card()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let fallback = config.effectiveAIFallbackOrder.map(\.displayName).joined(separator: " -> ")
        stack.addArrangedSubview(textLabel("\(t("aiProvider"))  \(config.selectedAIProvider.displayName)", size: 15, color: .labelColor, weight: .semibold))
        stack.addArrangedSubview(textLabel("Fallback: \(fallback)", size: 12, color: .secondaryLabelColor))
        let health = NSButton(title: t("aiHealthCheck"), target: self, action: #selector(runAIHealthCheck))
        health.bezelStyle = .rounded
        stack.addArrangedSubview(health)

        box.contentView?.addSubview(stack)
        pin(stack, to: box.contentView)
        box.widthAnchor.constraint(equalToConstant: 760).isActive = true
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
        header.addArrangedSubview(textLabel(snapshot.instance.displayName, size: 16, color: .labelColor, weight: .semibold))
        header.addArrangedSubview(textLabel("\(snapshot.parent.owner)/\(snapshot.parent.repo)", size: 12, color: .secondaryLabelColor))
        header.addArrangedSubview(spacer())
        header.addArrangedSubview(statusBadge(compactSummary(snapshot), snapshot: snapshot))
        stack.addArrangedSubview(header)

        stack.addArrangedSubview(textLabel("\(t("service")): \(snapshot.serviceState.rawValue)   \(t("github")): \(snapshot.githubStatus ?? "unknown")   \(t("runner")): \(snapshot.instance.runnerName)", size: 12, color: .secondaryLabelColor))
        stack.addArrangedSubview(textLabel("\(t("labels")): \(snapshot.labels.joined(separator: ", "))", size: 12, color: .secondaryLabelColor))

        if let error = snapshot.error, !error.isEmpty {
            stack.addArrangedSubview(textLabel("GitHub error: \(error)", size: 12, color: .systemRed))
        }

        stack.addArrangedSubview(sectionTitle(t("currentRequests")))
        if snapshot.currentRuns.isEmpty {
            stack.addArrangedSubview(textLabel(t("noCurrentRequests"), size: 12, color: .secondaryLabelColor))
        } else {
            for activity in snapshot.currentRuns {
                stack.addArrangedSubview(activityRow(activity, runnerID: snapshot.parent.id))
            }
        }

        stack.addArrangedSubview(sectionTitle(t("recentEvents")))
        if snapshot.recentEvents.isEmpty {
            stack.addArrangedSubview(textLabel(t("noRecentEvents"), size: 12, color: .secondaryLabelColor))
        } else {
            for event in snapshot.recentEvents {
                stack.addArrangedSubview(eventRow(event))
            }
        }

        box.contentView?.addSubview(stack)
        pin(stack, to: box.contentView)
        box.widthAnchor.constraint(equalToConstant: 920).isActive = true
        return box
    }

    private func activityRow(_ activity: RunnerRunActivity, runnerID: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        var text = "\(activity.status.uppercased())  \(activity.runName)  ->  \(activity.jobName)"
        if let runnerName = activity.runnerName, !runnerName.isEmpty {
            text += "  [\(t("onRunner")) \(runnerName)]"
        }
        row.addArrangedSubview(textLabel(text, size: 12, color: .labelColor))
        row.addArrangedSubview(spacer())

        let open = RunActionButton(title: t("open"), target: self, action: #selector(openRun(_:)))
        open.bezelStyle = .rounded
        open.actionRef = RunActionRef(runnerID: runnerID, runID: activity.runID, url: activity.htmlURL)
        row.addArrangedSubview(open)

        let cancel = RunActionButton(title: t("cancel"), target: self, action: #selector(cancelRun(_:)))
        cancel.bezelStyle = .rounded
        cancel.actionRef = RunActionRef(runnerID: runnerID, runID: activity.runID, url: activity.htmlURL)
        row.addArrangedSubview(cancel)

        return row
    }

    private func eventRow(_ event: RunnerLogEvent) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let statusColor: NSColor
        switch event.status.lowercased() {
        case "running":
            statusColor = .systemBlue
        case "succeeded":
            statusColor = .systemGreen
        case "failed":
            statusColor = .systemRed
        default:
            statusColor = .secondaryLabelColor
        }

        let status = textLabel(event.status, size: 11, color: statusColor, weight: .semibold)
        status.widthAnchor.constraint(equalToConstant: 84).isActive = true
        let time = textLabel(compactTime(event.timestamp), size: 11, color: .tertiaryLabelColor)
        time.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let job = textLabel(event.jobName, size: 12, color: .secondaryLabelColor)
        job.widthAnchor.constraint(lessThanOrEqualToConstant: 560).isActive = true

        row.addArrangedSubview(status)
        row.addArrangedSubview(time)
        row.addArrangedSubview(job)
        return row
    }

    private func compactTime(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: timestamp) else {
            return timestamp
                .replacingOccurrences(of: "2026-", with: "")
                .replacingOccurrences(of: "T", with: " ")
                .replacingOccurrences(of: "Z", with: "")
        }

        let output = DateFormatter()
        output.timeZone = TimeZone(identifier: "Asia/Seoul")
        output.dateFormat = "MM-dd HH:mm:ss 'KST'"
        return output.string(from: date)
    }

    private func powerPolicyExplanation() -> String {
        if config.appLanguage == .korean {
            return "러너 전원 정책은 AC 전원 연결 중 시스템/디스크 잠자기를 막아 GitHub job 대기와 실행이 끊기지 않도록 합니다. 화면은 30분 뒤 꺼지고, 네트워크 깨우기는 유지됩니다."
        }
        return "Runner power policy prevents system and disk sleep while on AC power so GitHub jobs keep waiting and running. The display still sleeps after 30 minutes, and wake-on-network remains enabled."
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
            let result = monitor.cancelRun(owner: runner.owner, repo: runner.repo, runID: runID)
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
        let defaultRunnerDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("actions-runners").path
        if homeExpanded.hasSuffix("/") || homeExpanded == defaultRunnerDir {
            return URL(fileURLWithPath: homeExpanded).appendingPathComponent(repoID).path
        }
        return homeExpanded
    }

    private func showRunnerForm(title: String, fields: RunnerFormFields) -> RunnerFormFields? {
        let displayName = inputField(fields.displayName, placeholder: "My Project")
        let owner = inputField(fields.owner, placeholder: "your-org")
        let repo = inputField(fields.repo, placeholder: "your-repo")
        let runnerName = inputField(fields.runnerName, placeholder: "auto: macbook-air-<repo>-runner")
        let runnerPath = inputField(fields.runnerPath, placeholder: "~/actions-runners/")
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
        stack.addArrangedSubview(row(label: t("displayName"), field: displayName, help: t("displayNameHelp")))
        stack.addArrangedSubview(row(label: t("owner"), field: owner, help: t("ownerHelp")))
        stack.addArrangedSubview(row(label: t("repo"), field: repo, help: t("repoHelp")))
        stack.addArrangedSubview(row(label: t("runnerName"), field: runnerName, help: t("runnerNameHelp")))
        stack.addArrangedSubview(row(label: t("runnerPath"), field: runnerPath, help: t("runnerPathHelp")))
        stack.addArrangedSubview(row(label: t("labels"), field: labels, help: t("labelsHelp")))

        let info = NSTextField(labelWithString: t("formHelp"))
        info.translatesAutoresizingMaskIntoConstraints = false
        info.lineBreakMode = .byWordWrapping
        info.maximumNumberOfLines = 3
        info.textColor = .secondaryLabelColor

        let cancel = NSButton(title: t("cancel"), target: nil, action: nil)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        let add = NSButton(title: t("add"), target: nil, action: nil)
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

    @objc private func applyPowerPolicy() {
        let alert = NSAlert()
        alert.messageText = "Apply runner power policy?"
        alert.informativeText = "RunnerBar will ask macOS for administrator permission and set AC power sleep=0, displaysleep=30, disksleep=0, powernap=1, and wake-on-network=1."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let monitor = monitor
        updateTitle(color: .systemYellow, text: "PWR")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = monitor.applyRunnerPowerPolicy()
            Task { @MainActor in
                guard let self else { return }
                if result.status != 0 {
                    self.updateTitleForCurrentState()
                    self.showError("Power policy failed", detail: result.output.isEmpty ? "macOS did not apply the pmset command." : result.output)
                }
                self.refresh()
            }
        }
    }

    @objc private func restorePowerPolicy() {
        let alert = NSAlert()
        alert.messageText = "Restore default power policy?"
        alert.informativeText = "RunnerBar will ask macOS for administrator permission and restore AC power sleep=1, displaysleep=10, disksleep=10, powernap=1, and wake-on-network=1."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let monitor = monitor
        updateTitle(color: .systemYellow, text: "PWR")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = monitor.restoreDefaultPowerPolicy()
            Task { @MainActor in
                guard let self else { return }
                if result.status != 0 {
                    self.updateTitleForCurrentState()
                    self.showError("Power policy restore failed", detail: result.output.isEmpty ? "macOS did not apply the pmset command." : result.output)
                }
                self.refresh()
            }
        }
    }

    @objc private func scaleUpRunner(_ sender: NSMenuItem) {
        guard let runner = runner(for: sender) else { return }
        promptScale(parent: runner, suggestion: runner.instanceCount + 1)
    }

    @objc private func scaleDownRunner(_ sender: NSMenuItem) {
        guard let runner = runner(for: sender) else { return }
        promptScale(parent: runner, suggestion: max(1, runner.instanceCount - 1))
    }

    private func promptScale(parent: RunnerConfig, suggestion: Int) {
        let field = inputField(String(suggestion), placeholder: "1")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        stack.addArrangedSubview(row(label: t("replicas"), field: field, help: "Currently \(parent.instanceCount). Use the same labels per replica."))

        let alert = NSAlert()
        alert.messageText = t("scaleTitle")
        alert.informativeText = t("scalePrompt")
        alert.accessoryView = stack
        alert.addButton(withTitle: t("add"))
        alert.addButton(withTitle: t("cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let target = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), target >= 1 else {
            showError("Invalid count", detail: "Please enter an integer >= 1.")
            return
        }
        scale(parent: parent, target: target)
    }

    private func scale(parent: RunnerConfig, target: Int) {
        let current = parent.instanceCount
        if target == current { return }
        guard let idx = config.runners.firstIndex(where: { $0.id == parent.id }) else { return }

        if target > current {
            updateTitle(color: .systemYellow, text: "SCL")
            let newInstances = (current + 1...target).map { index in
                RunnerInstance(
                    parentID: parent.id,
                    index: index,
                    displayName: "\(parent.displayName) #\(index)",
                    owner: parent.owner,
                    repo: parent.repo,
                    runnerName: RunnerConfig.derivedRunnerName(base: parent.runnerName, index: index),
                    runnerPath: RunnerConfig.derivedRunnerPath(base: parent.runnerPath, index: index),
                    labels: parent.labels
                )
            }
            let monitor = monitor
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var failures: [String] = []
                for instance in newInstances {
                    let r = monitor.registerInstance(instance)
                    if r.status != 0 {
                        failures.append("instance #\(instance.index): \(r.output.prefix(120))")
                    }
                }
                Task { @MainActor in
                    guard let self else { return }
                    if failures.isEmpty {
                        self.config.runners[idx].replicas = target
                        self.saveCurrentConfig()
                        self.showInfo("Scaled up", detail: "\(parent.displayName) now has \(target) instances.")
                    } else {
                        self.updateTitleForCurrentState()
                        self.showError("Scale up failed", detail: failures.joined(separator: "\n\n"))
                    }
                }
            }
        } else {
            let toRemove = (target + 1...current).map { index in
                RunnerInstance(
                    parentID: parent.id,
                    index: index,
                    displayName: "\(parent.displayName) #\(index)",
                    owner: parent.owner,
                    repo: parent.repo,
                    runnerName: RunnerConfig.derivedRunnerName(base: parent.runnerName, index: index),
                    runnerPath: RunnerConfig.derivedRunnerPath(base: parent.runnerPath, index: index),
                    labels: parent.labels
                )
            }
            let monitor = monitor
            updateTitle(color: .systemYellow, text: "SCL")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                for instance in toRemove {
                    _ = monitor.removeInstance(instance)
                }
                Task { @MainActor in
                    guard let self else { return }
                    self.config.runners[idx].replicas = target
                    self.saveCurrentConfig()
                    self.showInfo("Scaled down", detail: "\(parent.displayName) now has \(target) instances.")
                }
            }
        }
    }

    @objc private func startColima() {
        updateTitle(color: .systemYellow, text: "DOC")
        let monitor = monitor
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = monitor.startColima()
            Task { @MainActor in
                guard let self else { return }
                if result.status != 0 {
                    self.updateTitleForCurrentState()
                    self.showError("colima start failed", detail: result.output.isEmpty ? "exit \(result.status)" : result.output)
                }
                self.refresh()
            }
        }
    }

    @objc private func stopColima() {
        let monitor = monitor
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = monitor.stopColima()
            Task { @MainActor in
                guard let self else { return }
                if result.status != 0 {
                    self.showError("colima stop failed", detail: result.output)
                }
                self.refresh()
            }
        }
    }

    @objc private func openCleanupSheet() {
        let cleanWork = NSButton(checkboxWithTitle: t("cleanupWork"), target: nil, action: nil)
        cleanWork.state = .on
        let cleanDocker = NSButton(checkboxWithTitle: t("cleanupDocker"), target: nil, action: nil)
        let cleanSupabase = NSButton(checkboxWithTitle: t("cleanupSupabase"), target: nil, action: nil)
        let cleanSim = NSButton(checkboxWithTitle: t("cleanupSim"), target: nil, action: nil)

        let stack = NSStackView(views: [cleanWork, cleanDocker, cleanSupabase, cleanSim])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let alert = NSAlert()
        alert.messageText = t("cleanupTitle")
        alert.informativeText = "Choose what to clean. These actions are not reversible."
        alert.accessoryView = stack
        alert.addButton(withTitle: t("run"))
        alert.addButton(withTitle: t("cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let runWork = cleanWork.state == .on
        let runDocker = cleanDocker.state == .on
        let runSupabase = cleanSupabase.state == .on
        let runSim = cleanSim.state == .on

        let monitor = monitor
        let currentConfig = config!
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var lines: [String] = []
            if runWork {
                for parent in currentConfig.runners {
                    for instance in parent.instances() {
                        let svc = Shell.run(["./svc.sh", "status"], cwd: instance.runnerPath)
                        if svc.output.contains("Started:") {
                            lines.append("Skipped \(instance.runnerName): runner is started — stop it first.")
                            continue
                        }
                        let r = monitor.cleanupWork(instance: instance)
                        lines.append("\(instance.runnerName) _work: exit \(r.status)\n\(r.output.prefix(160))")
                    }
                }
            }
            if runDocker {
                let r = monitor.dockerPrune()
                lines.append("docker system prune: exit \(r.status)\n\(r.output.prefix(160))")
            }
            if runSupabase {
                let r = monitor.supabaseStop()
                lines.append("supabase stop: exit \(r.status)\n\(r.output.prefix(160))")
            }
            if runSim {
                let r = monitor.cleanupSimulators()
                lines.append("simctl delete unavailable: exit \(r.status)\n\(r.output.prefix(160))")
            }
            Task { @MainActor in
                guard let self else { return }
                self.showInfo(self.t("cleanupTitle"), detail: lines.joined(separator: "\n\n"))
                self.refresh()
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
