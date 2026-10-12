import SwiftUI
import AppKit

struct WatchdogLogCard: View {
    var language: AppLanguage
    var alerts: [WatchdogAlert]
    var enabled: Bool

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Localization.t("watchdogTitle", language: language))
                    .font(.headline)
                Text(enabled ? Localization.t("watchdogEnabled", language: language) : "disabled")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
            }
            if alerts.isEmpty {
                Text(Localization.t("watchdogNoEvents", language: language))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(alerts.prefix(8)) { alert in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(label(for: alert.kind))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(color(for: alert.kind))
                            .frame(width: 110, alignment: .leading)
                        Text(Self.timeFormatter.string(from: alert.timestamp))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Text(alert.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 180, alignment: .leading)
                        Text(alert.detail)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        let hasFresh = alerts.first.flatMap { alert -> Bool? in
            switch alert.kind {
            case .offline, .hang, .recoveryFailed:
                return Date().timeIntervalSince(alert.timestamp) < 300
            default: return false
            }
        } ?? false
        if hasFresh { return .red }
        if alerts.isEmpty { return .green }
        return .yellow
    }

    private func label(for kind: WatchdogAlertKind) -> String {
        switch kind {
        case .offline: return Localization.t("watchdogAlertOffline", language: language)
        case .hang: return Localization.t("watchdogAlertHang", language: language)
        case .recoveryStarted: return Localization.t("watchdogRecoveryStarted", language: language)
        case .recoverySucceeded: return Localization.t("watchdogRecoveryOK", language: language)
        case .recoveryFailed: return Localization.t("watchdogRecoveryFailed", language: language)
        }
    }

    private func color(for kind: WatchdogAlertKind) -> Color {
        switch kind {
        case .offline, .hang, .recoveryFailed: return .red
        case .recoveryStarted: return .orange
        case .recoverySucceeded: return .green
        }
    }
}

struct MachineHealthCard: View {
    var language: AppLanguage
    var health: MachineHealth
    var diskThreshold: Int
    var onStartColima: () -> Void
    var onStopColima: () -> Void
    var onCleanup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Localization.t("machineHealth", language: language))
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(overallColor)
                    .frame(width: 10, height: 10)
            }

            HStack(spacing: 18) {
                diskRow
                colimaRow
                dockerRow
            }

            HStack(spacing: 10) {
                if health.colimaInstalled {
                    if health.colimaRunning == true {
                        Button(Localization.t("stopColima", language: language), action: onStopColima)
                    } else {
                        Button(Localization.t("startColima", language: language), action: onStartColima)
                    }
                }
                Button(Localization.t("cleanup", language: language) + "...", action: onCleanup)
            }
            .controlSize(.regular)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var overallColor: Color {
        if health.isLowDisk(thresholdPercent: diskThreshold) { return .red }
        if health.colimaInstalled && health.colimaRunning == false { return .yellow }
        return .green
    }

    @ViewBuilder
    private var diskRow: some View {
        let pct = health.diskFreePercent ?? 0
        let isLow = health.isLowDisk(thresholdPercent: diskThreshold)
        VStack(alignment: .leading, spacing: 4) {
            Text(Localization.t("disk", language: language))
                .font(.caption.weight(.semibold))
            if let free = health.diskFreeGB, let total = health.diskTotalGB {
                Text(String(format: "%.0f GB %@ / %.0f GB", free, Localization.t("diskFree", language: language), total))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(isLow ? .red : .primary)
            } else {
                Text("?").font(.system(size: 12, design: .monospaced))
            }
            ProgressView(value: max(0, min(100, pct)) / 100.0)
                .progressViewStyle(.linear)
                .tint(isLow ? .red : .green)
                .frame(width: 200)
        }
    }

    @ViewBuilder
    private var colimaRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Localization.t("colima", language: language))
                .font(.caption.weight(.semibold))
            Text(colimaText)
                .font(.system(size: 12))
                .foregroundColor(colimaColor)
        }
    }

    private var colimaText: String {
        if !health.colimaInstalled { return "not installed" }
        switch health.colimaRunning {
        case .some(true): return Localization.t("colimaRunning", language: language)
        case .some(false): return Localization.t("colimaStopped", language: language)
        case .none: return Localization.t("colimaUnknown", language: language)
        }
    }

    private var colimaColor: Color {
        switch health.colimaRunning {
        case .some(true): return .green
        case .some(false): return .orange
        case .none: return .secondary
        }
    }

    @ViewBuilder
    private var dockerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Localization.t("docker", language: language))
                .font(.caption.weight(.semibold))
            Text(dockerText)
                .font(.system(size: 12))
                .foregroundColor(dockerColor)
        }
    }

    private var dockerText: String {
        switch health.dockerRunning {
        case .some(true): return Localization.t("colimaRunning", language: language)
        case .some(false): return Localization.t("colimaStopped", language: language)
        case .none: return Localization.t("colimaUnknown", language: language)
        }
    }

    private var dockerColor: Color {
        switch health.dockerRunning {
        case .some(true): return .green
        case .some(false): return .orange
        case .none: return .secondary
        }
    }
}

struct LabelGroupSummaryCard: View {
    struct Group: Identifiable {
        let id: String   // parent ID
        let displayName: String
        let total: Int
        let online: Int
        let busy: Int
        let labels: [String]
    }

    var language: AppLanguage
    var groups: [Group]

    var body: some View {
        if groups.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(Localization.t("instances", language: language))
                    .font(.headline)
                ForEach(groups) { group in
                    HStack(alignment: .firstTextBaseline) {
                        Text(group.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 200, alignment: .leading)
                        Text(String(format: Localization.t("labelGroupSummary", language: language), group.online, group.total, group.busy))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(group.labels.joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
