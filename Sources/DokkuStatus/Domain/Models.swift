import Foundation

enum HostConfigValidationError: LocalizedError {
    case missingHost
    case missingUser
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .missingHost:
            return "Host is required."
        case .missingUser:
            return "User is required."
        case .invalidPort:
            return "Port must be between 1 and 65535."
        }
    }
}

struct DokkuHostConfig: Codable, Equatable, Hashable {
    let host: String
    let user: String
    let port: Int
    let sshAlias: String?

    var target: String {
        if let alias = sshAlias?.trimmedNilIfEmpty {
            return alias
        }

        return "\(user)@\(host)"
    }

    var profileIdentifier: String {
        "\(sshAlias?.lowercased() ?? "")|\(user.lowercased())|\(host.lowercased())|\(port)"
    }

    var displayTitle: String {
        if let alias = sshAlias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            return alias
        }

        return "\(user)@\(host)"
    }

    var displaySubtitle: String {
        "\(user)@\(host):\(port)"
    }

    func validated() throws -> DokkuHostConfig {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAlias = sshAlias?.trimmedNilIfEmpty

        guard !normalizedHost.isEmpty else {
            throw HostConfigValidationError.missingHost
        }

        guard !normalizedUser.isEmpty else {
            throw HostConfigValidationError.missingUser
        }

        guard (1...65535).contains(port) else {
            throw HostConfigValidationError.invalidPort
        }

        return DokkuHostConfig(
            host: normalizedHost,
            user: normalizedUser,
            port: port,
            sshAlias: normalizedAlias
        )
    }
}

enum HostProfileSource: String {
    case saved
    case sshConfig
    case active

    var badgeTitle: String {
        switch self {
        case .saved:
            return "Saved"
        case .sshConfig:
            return "SSH"
        case .active:
            return "Current"
        }
    }
}

struct HostProfileOption: Identifiable, Equatable {
    let source: HostProfileSource
    let config: DokkuHostConfig

    var id: String {
        "\(source.rawValue):\(config.profileIdentifier)"
    }

    var menuTitle: String {
        "\(config.displayTitle) (\(source.badgeTitle))"
    }
}

enum AppHealthState: String, Codable {
    case running
    case notRunning
    case unknown
}

struct AppStatus: Identifiable, Codable, Equatable {
    let id: String
    let appName: String
    let state: AppHealthState
    let rawStatus: String?
    let checkedAt: Date
    let errorMessage: String?

    init(
        appName: String,
        state: AppHealthState,
        rawStatus: String?,
        checkedAt: Date,
        errorMessage: String?
    ) {
        self.id = appName
        self.appName = appName
        self.state = state
        self.rawStatus = rawStatus
        self.checkedAt = checkedAt
        self.errorMessage = errorMessage
    }
}

enum AggregateState {
    case healthy
    case partial
    case error
    case unknown

    static func evaluate(apps: [AppStatus], latestError: String?) -> AggregateState {
        if apps.isEmpty {
            return latestError == nil ? .unknown : .error
        }

        if apps.allSatisfy({ $0.state == .running }) {
            return .healthy
        }

        let hasResolvedState = apps.contains { $0.state != .unknown }

        if !hasResolvedState {
            return .error
        }

        if latestError != nil {
            return .partial
        }

        return .partial
    }

    var title: String {
        switch self {
        case .healthy:
            return "Healthy"
        case .partial:
            return "Partial"
        case .error:
            return "Error"
        case .unknown:
            return "Unknown"
        }
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
