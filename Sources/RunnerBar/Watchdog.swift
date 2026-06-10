import Foundation
import UserNotifications

@MainActor
final class Watchdog {
    private let monitor: RunnerMonitor
    private var failureCounts: [String: Int] = [:]
    private var inRecovery: Set<String> = []
    private(set) var log: [WatchdogAlert] = []
    var onChange: (@MainActor () -> Void)?

    init(monitor: RunnerMonitor) {
        self.monitor = monitor
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable _, _ in }
    }

    func evaluate(report: MonitorReport, config: RunnerBarConfig) {
        guard config.effectiveWatchdog.isEnabled else { return }
        let cfg = config.effectiveWatchdog
        let slack = config.slackWebhookURL

        // Identify which label groups are currently hung (jobs queued, 0 matching online runner).
        let hungLabelSets: [Set<String>] = report.hangs.map { Set($0.labels) }

        for snapshot in report.snapshots {
            let id = snapshot.instance.instanceID
            let healthy = snapshot.isOnline
            if healthy {
                if failureCounts[id, default: 0] > 0 {
                    failureCounts[id] = 0
                    appendAlert(.recoverySucceeded, instanceID: id, displayName: snapshot.instance.displayName,
                                detail: "runner is online again")
                }
                continue
            }

            // Instance is unhealthy. Skip if recovery is already in flight.
            if inRecovery.contains(id) { continue }

            failureCounts[id, default: 0] += 1
            let count = failureCounts[id] ?? 0

            // Is this instance part of a hung label group? If so escalate faster.
            let myLabels = Set(snapshot.instance.labels)
            let isInHungGroup = hungLabelSets.contains { !$0.isEmpty && $0.isSubset(of: myLabels) }

            if count == 1 && !isInHungGroup {
                appendAlert(.offline, instanceID: id, displayName: snapshot.instance.displayName,
                            detail: "service=\(snapshot.serviceState.rawValue) github=\(snapshot.githubStatus ?? "unknown")")
                continue
            }

            // First failure in a hung group, or 2+ failures otherwise → start recovery.
            let attempt = max(1, count - (isInHungGroup ? 0 : 1))
            guard attempt <= cfg.maxAttempts else {
                appendAlert(.recoveryFailed, instanceID: id, displayName: snapshot.instance.displayName,
                            detail: "exhausted \(cfg.maxAttempts) attempts")
                notify(title: "RunnerBar: \(snapshot.instance.displayName) is offline",
                       body: "Recovery failed after \(cfg.maxAttempts) attempts.")
                if let slack { postSlack(url: slack, text: ":rotating_light: RunnerBar: \(snapshot.instance.displayName) recovery failed after \(cfg.maxAttempts) attempts.") }
                continue
            }
            startRecovery(snapshot: snapshot, attempt: attempt, config: cfg, slack: slack)
        }

        // Hang alerts at the repo/label-group level (separate from instance log)
        for hang in report.hangs {
            let label = "\(hang.owner)/\(hang.repo)"
            let detail = "labels=[\(hang.labels.joined(separator: ","))] job=\(hang.jobName)"
            if !log.contains(where: {
                $0.kind == .hang && $0.displayName == label && $0.detail == detail
                && Date().timeIntervalSince($0.timestamp) < 120
            }) {
                appendAlert(.hang, instanceID: nil, displayName: label, detail: detail)
            }
        }
    }

    var hasActiveAlert: Bool {
        for alert in log.prefix(10) {
            switch alert.kind {
            case .offline, .hang, .recoveryFailed:
                if Date().timeIntervalSince(alert.timestamp) < 300 { return true }
            default: continue
            }
        }
        return false
    }

    private func startRecovery(snapshot: RunnerSnapshot, attempt: Int, config: WatchdogConfig, slack: String?) {
        let id = snapshot.instance.instanceID
        inRecovery.insert(id)
        let instance = snapshot.instance
        let delay = pow(2.0, Double(max(0, attempt - 1))) * config.baseDelay
        appendAlert(.recoveryStarted, instanceID: id, displayName: instance.displayName,
                    detail: "attempt \(attempt)/\(config.maxAttempts) in \(Int(delay))s")

        let shouldStartColima = config.shouldStartColima
        let monitor = monitor
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            if shouldStartColima {
                _ = monitor.startColima()
            }
            let result = monitor.restartInstance(instance)
            Task { @MainActor in
                guard let self else { return }
                self.inRecovery.remove(id)
                if result.status == 0 {
                    self.appendAlert(.recoveryStarted, instanceID: id, displayName: instance.displayName,
                                     detail: "restart command exited 0 — waiting for next refresh to confirm")
                } else if attempt >= config.maxAttempts {
                    self.appendAlert(.recoveryFailed, instanceID: id, displayName: instance.displayName,
                                     detail: "attempt \(attempt) failed: \(self.summarize(result.output))")
                    self.notify(title: "RunnerBar: \(instance.displayName) recovery failed",
                                body: "All \(config.maxAttempts) attempts failed.")
                    if let slack { self.postSlack(url: slack, text: ":rotating_light: RunnerBar: \(instance.displayName) recovery failed after \(config.maxAttempts) attempts.") }
                } else {
                    self.appendAlert(.recoveryFailed, instanceID: id, displayName: instance.displayName,
                                     detail: "attempt \(attempt) failed: \(self.summarize(result.output))")
                }
            }
        }
    }

    private func appendAlert(_ kind: WatchdogAlertKind, instanceID: String?, displayName: String, detail: String) {
        let alert = WatchdogAlert(timestamp: Date(), kind: kind, instanceID: instanceID, displayName: displayName, detail: detail)
        log.insert(alert, at: 0)
        if log.count > 30 { log.removeLast() }
        onChange?()
    }

    private func summarize(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "(no output)" }
        return String(trimmed.prefix(160))
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { @Sendable _ in }
    }

    private func postSlack(url: String, text: String) {
        guard let endpoint = URL(string: url) else { return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["text": text]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req).resume()
    }
}
