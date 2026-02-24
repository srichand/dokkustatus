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

    static func relativeDateString(from date: Date?) -> String {
        guard let date else {
            return "Never"
        }

        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
