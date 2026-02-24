import AppKit
import SwiftUI

@MainActor
enum MenuBarController {
    static func symbolName(for state: AggregateState) -> String {
        switch state {
        case .healthy:
            return "checkmark.circle.fill"
        case .partial:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        case .unknown:
            return "questionmark.circle"
        }
    }

    static func summaryColor(for state: AggregateState) -> Color {
        switch state {
        case .healthy:
            return .green
        case .partial:
            return .yellow
        case .error:
            return .red
        case .unknown:
            return .secondary
        }
    }

    static func badgeTitle(for state: AppHealthState) -> String {
        switch state {
        case .running:
            return "Running"
        case .notRunning:
            return "Not Running"
        case .unknown:
            return "Unknown"
        }
    }

    static func badgeColor(for state: AppHealthState) -> Color {
        switch state {
        case .running:
            return .green
        case .notRunning:
            return .orange
        case .unknown:
            return .secondary
        }
    }

    static func relativeDateString(from date: Date?, relativeTo referenceDate: Date = Date()) -> String {
        guard let date else {
            return "Never"
        }

        return relativeFormatter.localizedString(for: date, relativeTo: referenceDate)
    }

    static func menuBarCountText(metrics: MenuStatusMetrics) -> String {
        if metrics.total > 0 {
            return "\(metrics.running)/\(metrics.total)"
        }

        return metrics.hasChecked ? "0/0" : "--"
    }

    static func impactedSummaryText(metrics: MenuStatusMetrics, limit: Int = 3) -> String? {
        let impacted = metrics.impactedNames
        guard !impacted.isEmpty else {
            return nil
        }

        let cappedLimit = max(1, limit)
        let displayed = Array(impacted.prefix(cappedLimit))

        if impacted.count <= cappedLimit {
            return displayed.joined(separator: ", ")
        }

        let remaining = impacted.count - displayed.count
        return "\(displayed.joined(separator: ", ")) +\(remaining) more"
    }

    static func resolvedSelectedAppID(previousSelectedID: String?, orderedApps: [AppStatus]) -> String? {
        if let previousSelectedID, orderedApps.contains(where: { $0.id == previousSelectedID }) {
            return previousSelectedID
        }

        return orderedApps.first?.id
    }

    static func groupedAppsForDetails(_ apps: [AppStatus]) -> (notRunning: [AppStatus], unknown: [AppStatus], running: [AppStatus]) {
        let sorted = apps.sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }

        return (
            notRunning: sorted.filter { $0.state == .notRunning },
            unknown: sorted.filter { $0.state == .unknown },
            running: sorted.filter { $0.state == .running }
        )
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
