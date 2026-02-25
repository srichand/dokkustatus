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
    let details: AppOperationalDetails?
    let letsEncrypt: AppLetsEncryptStatus?

    init(
        appName: String,
        state: AppHealthState,
        rawStatus: String?,
        checkedAt: Date,
        errorMessage: String?,
        details: AppOperationalDetails? = nil,
        letsEncrypt: AppLetsEncryptStatus? = nil
    ) {
        self.id = appName
        self.appName = appName
        self.state = state
        self.rawStatus = rawStatus
        self.checkedAt = checkedAt
        self.errorMessage = errorMessage
        self.details = details
        self.letsEncrypt = letsEncrypt
    }
}

struct AppMountInfo: Codable, Equatable {
    let source: String
    let destination: String
    let isReadOnly: Bool
    let type: String
}

struct AppProcessInfo: Codable, Equatable {
    let identifier: String
    let running: Bool
    let status: String?
    let startedAt: Date?
    let finishedAt: Date?
    let exitCode: Int?
    let processType: String?
    let containerName: String?
    let containerID: String?
    let createdAt: Date?
    let restartCount: Int?
    let pid: Int?
    let restarting: Bool
    let paused: Bool
    let dead: Bool
    let oomKilled: Bool
    let stateError: String?
    let image: String?
    let builderType: String?
    let stack: String?
    let imageStage: String?
    let user: String?
    let workingDir: String?
    let command: String?
    let networkMode: String?
    let ipAddress: String?
    let exposedPorts: [String]
    let publishedPorts: [String]
    let logPath: String?

    init(
        identifier: String,
        running: Bool,
        status: String?,
        startedAt: Date?,
        finishedAt: Date?,
        exitCode: Int?,
        processType: String? = nil,
        containerName: String? = nil,
        containerID: String? = nil,
        createdAt: Date? = nil,
        restartCount: Int? = nil,
        pid: Int? = nil,
        restarting: Bool = false,
        paused: Bool = false,
        dead: Bool = false,
        oomKilled: Bool = false,
        stateError: String? = nil,
        image: String? = nil,
        builderType: String? = nil,
        stack: String? = nil,
        imageStage: String? = nil,
        user: String? = nil,
        workingDir: String? = nil,
        command: String? = nil,
        networkMode: String? = nil,
        ipAddress: String? = nil,
        exposedPorts: [String] = [],
        publishedPorts: [String] = [],
        logPath: String? = nil
    ) {
        self.identifier = identifier
        self.running = running
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.processType = processType
        self.containerName = containerName
        self.containerID = containerID
        self.createdAt = createdAt
        self.restartCount = restartCount
        self.pid = pid
        self.restarting = restarting
        self.paused = paused
        self.dead = dead
        self.oomKilled = oomKilled
        self.stateError = stateError
        self.image = image
        self.builderType = builderType
        self.stack = stack
        self.imageStage = imageStage
        self.user = user
        self.workingDir = workingDir
        self.command = command
        self.networkMode = networkMode
        self.ipAddress = ipAddress
        self.exposedPorts = exposedPorts
        self.publishedPorts = publishedPorts
        self.logPath = logPath
    }
}

struct AppOperationalDetails: Codable, Equatable {
    let processes: [AppProcessInfo]
    let domains: [String]
    let portMappings: [String]
    let mounts: [AppMountInfo]
    let restartPolicy: String?
}

struct AppLetsEncryptStatus: Codable, Equatable {
    let certificateExpiry: String
    let certificateExpiryDate: Date?
    let serverTimeZoneIdentifier: String?
    let serverTimeZoneAbbreviation: String?
    let serverTimeZoneOffset: String?
    let timeBeforeExpiry: String
    let timeBeforeRenewal: String

    var isExpired: Bool {
        timeBeforeExpiry.lowercased().contains("ago")
    }

    var renewalOverdue: Bool {
        timeBeforeRenewal.lowercased().contains("ago")
    }

    var serverTimeZone: TimeZone? {
        if let identifier = serverTimeZoneIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty,
           let timeZone = TimeZone(identifier: identifier) {
            return timeZone
        }

        if let abbreviation = serverTimeZoneAbbreviation?.trimmingCharacters(in: .whitespacesAndNewlines), !abbreviation.isEmpty,
           let timeZone = TimeZone(abbreviation: abbreviation) {
            return timeZone
        }

        guard let seconds = TimeZoneOffsetParser.secondsFromGMT(offset: serverTimeZoneOffset) else {
            return nil
        }

        return TimeZone(secondsFromGMT: seconds)
    }
}

struct MenuStatusMetrics: Equatable {
    let total: Int
    let running: Int
    let notRunning: Int
    let unknown: Int
    let impactedNames: [String]
    let hasChecked: Bool
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
