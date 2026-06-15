import Foundation

/// Supervises `gui`-mode runners by launching `./run.sh` as a **child process of RunnerBar**.
///
/// Why: RunnerBar is a menu-bar app, so it runs in the logged-in **GUI (Aqua) session**.
/// A child process it spawns inherits that session — which iOS Simulator / UI test jobs
/// require. GitHub's `svc.sh` LaunchAgent instead runs in a background launchd session
/// (no GUI), where Simulator apps mis-initialize (e.g. New Architecture TurboModules don't
/// register → "RNGoogleSignin could not be found"). See `RunnerMode`.
///
/// Trade-off: a gui-mode runner is tied to RunnerBar's lifecycle — it stops when RunnerBar
/// quits (handled in `applicationWillTerminate`).
final class GUIRunnerSupervisor: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [String: Process] = [:]   // instanceID -> running ./run.sh

    static let shared = GUIRunnerSupervisor()

    // MARK: - Lifecycle

    func start(_ instance: RunnerInstance) -> ShellResult {
        lock.lock()
        if let p = processes[instance.instanceID], p.isRunning {
            lock.unlock()
            return ShellResult(status: 0, output: "Already running in GUI session (pid \(p.processIdentifier)).")
        }
        lock.unlock()

        // An orphan from a previous RunnerBar (reparented) may still be running. Don't double-spawn.
        if externalPID(for: instance) != nil {
            return ShellResult(status: 0, output: "Already running (external process for this runner path).")
        }

        let runScript = (instance.runnerPath as NSString).appendingPathComponent("run.sh")
        guard FileManager.default.isExecutableFile(atPath: runScript) else {
            return ShellResult(status: 127, output: "run.sh not found or not executable at \(runScript)")
        }

        let logHandle = makeLogHandle(for: instance)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: runScript)
        process.currentDirectoryURL = URL(fileURLWithPath: instance.runnerPath)
        process.environment = childEnvironment()
        process.standardInput = FileHandle.nullDevice         // never prompt for input
        if let logHandle {
            process.standardOutput = logHandle
            process.standardError = logHandle
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.lock.lock()
            if self.processes[instance.instanceID] === proc {
                self.processes.removeValue(forKey: instance.instanceID)
            }
            self.lock.unlock()
        }

        do {
            try process.run()
        } catch {
            return ShellResult(status: 127, output: "Failed to launch run.sh: \(error.localizedDescription)")
        }

        lock.lock()
        processes[instance.instanceID] = process
        lock.unlock()
        writePIDFile(pid: process.processIdentifier, for: instance)

        return ShellResult(status: 0, output: "Started in GUI session (pid \(process.processIdentifier)).")
    }

    func stop(_ instance: RunnerInstance) -> ShellResult {
        lock.lock()
        let tracked = processes.removeValue(forKey: instance.instanceID)
        lock.unlock()

        if let p = tracked, p.isRunning {
            // SIGINT → GitHub runner finishes the current job, then exits gracefully.
            p.interrupt()
            if !waitForExit(p, timeout: 25) {
                p.terminate()
                _ = waitForExit(p, timeout: 5)
            }
            removePIDFile(for: instance)
            return ShellResult(status: 0, output: "Stopped GUI-session runner (pid \(p.processIdentifier)).")
        }

        // Fall back to an orphaned external process for this runner path.
        if let pid = externalPID(for: instance) {
            _ = Shell.run(["kill", "-INT", String(pid)])
            removePIDFile(for: instance)
            return ShellResult(status: 0, output: "Sent SIGINT to external runner process (pid \(pid)).")
        }

        removePIDFile(for: instance)
        return ShellResult(status: 0, output: "Not running.")
    }

    func restart(_ instance: RunnerInstance) -> ShellResult {
        _ = stop(instance)
        return start(instance)
    }

    func isRunning(_ instance: RunnerInstance) -> Bool {
        lock.lock()
        let tracked = processes[instance.instanceID]?.isRunning ?? false
        lock.unlock()
        if tracked { return true }
        return externalPID(for: instance) != nil
    }

    func state(_ instance: RunnerInstance) -> ServiceState {
        isRunning(instance) ? .started : .stopped
    }

    /// Stop every tracked gui runner — call from `applicationWillTerminate`.
    func stopAllTracked() {
        lock.lock()
        let running = processes.values.filter { $0.isRunning }
        processes.removeAll()
        lock.unlock()
        for p in running { p.interrupt() }
        for p in running { _ = waitForExit(p, timeout: 8) }
        for p in running where p.isRunning { p.terminate() }
    }

    // MARK: - Helpers

    /// PID of a Runner.Listener whose executable lives under this runner's path
    /// (handles orphans reparented after a RunnerBar restart). Returns nil if none.
    private func externalPID(for instance: RunnerInstance) -> Int32? {
        let needle = (instance.runnerPath as NSString).appendingPathComponent("bin/Runner.Listener")
        let result = Shell.run(["pgrep", "-f", needle])
        guard result.status == 0 else { return nil }
        let pid = result.output
            .split(whereSeparator: { $0 == "\n" || $0 == " " })
            .compactMap { Int32($0) }
            .first
        return pid
    }

    private func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallbackPath = [
            "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ].joined(separator: ":")
        env["PATH"] = [env["PATH"], fallbackPath].compactMap(\.self).joined(separator: ":")
        env["HOME"] = home
        // The runner's actions/checkout configures git auth via a token header; make sure
        // git never falls back to an interactive credential prompt (which would fail headless).
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }

    private func diagDirectory(for instance: RunnerInstance) -> String {
        let dir = (instance.runnerPath as NSString).appendingPathComponent("_diag")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeLogHandle(for instance: RunnerInstance) -> FileHandle? {
        let path = (diagDirectory(for: instance) as NSString).appendingPathComponent("runnerbar-gui.log")
        let fm = FileManager.default
        fm.createFile(atPath: path, contents: nil)   // truncate: fresh log each start
        return FileHandle(forWritingAtPath: path)
    }

    private func writePIDFile(pid: Int32, for instance: RunnerInstance) {
        let path = (diagDirectory(for: instance) as NSString).appendingPathComponent("runnerbar.pid")
        try? "\(pid)\n".write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func removePIDFile(for instance: RunnerInstance) {
        let path = (diagDirectory(for: instance) as NSString).appendingPathComponent("runnerbar.pid")
        try? FileManager.default.removeItem(atPath: path)
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        return !process.isRunning
    }
}
