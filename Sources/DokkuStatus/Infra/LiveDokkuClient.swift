import Foundation
import OSLog

enum LiveDokkuClientError: LocalizedError {
    case missingInspectState(appName: String)
    case invalidInspectJSON(appName: String)

    var errorDescription: String? {
        switch self {
        case .missingInspectState(let appName):
            return "Unable to determine Dokku app state from inspect output for app '\(appName)'."
        case .invalidInspectJSON(let appName):
            return "Unable to parse Dokku status output for app '\(appName)'."
        }
    }
}

final class LiveDokkuClient: DokkuClient, @unchecked Sendable {
    private let runner: SSHRunning
    private let logger = Logger(subsystem: "DokkuStatus", category: "dokku")

    init(runner: SSHRunning = SSHProcessRunner()) {
        self.runner = runner
    }

    func fetchAppStatuses(config: DokkuHostConfig) async throws -> [AppStatus] {
        let validatedConfig = try config.validated()
        let target = validatedConfig.target
        let checkedAt = Date()

        let appsResult = try await runner.run(
            target: target,
            port: validatedConfig.port,
            remoteCommand: "dokku apps:list",
            timeout: 15
        )

        let appNames = Self.parseAppsList(appsResult.stdout)
        var statuses: [AppStatus] = []
        statuses.reserveCapacity(appNames.count)

        for appName in appNames {
            do {
                let reportResult = try await runner.run(
                    target: target,
                    port: validatedConfig.port,
                    remoteCommand: "dokku ps:inspect \(Self.shellEscape(appName))",
                    timeout: 15
                )

                let parsedStatus = try Self.parseInspectResult(reportResult.stdout, appName: appName)

                statuses.append(
                    AppStatus(
                        appName: appName,
                        state: parsedStatus.state,
                        rawStatus: parsedStatus.rawStatus,
                        checkedAt: checkedAt,
                        errorMessage: nil,
                        details: parsedStatus.details
                    )
                )
            } catch {
                logger.error("Failed to fetch status for app \(appName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                statuses.append(
                    AppStatus(
                        appName: appName,
                        state: .unknown,
                        rawStatus: nil,
                        checkedAt: checkedAt,
                        errorMessage: error.localizedDescription,
                        details: nil
                    )
                )
            }
        }

        return statuses.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    static func parseAppsList(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                !$0.isEmpty &&
                !$0.hasPrefix("=====>")
            }
    }

    static func parseInspectStatus(_ output: String, appName: String) throws -> (state: AppHealthState, rawStatus: String) {
        let parsed = try parseInspectResult(output, appName: appName)
        return (parsed.state, parsed.rawStatus)
    }

    static func parseInspectDetails(_ output: String, appName: String) throws -> AppOperationalDetails {
        try parseInspectResult(output, appName: appName).details
    }

    static func parseInspectResult(_ output: String, appName: String) throws -> ParsedInspectResult {
        let containers = try decodeInspectContainers(output, appName: appName)

        var statuses: [String] = []
        var hasRunning = false
        var hasNonRunning = false
        var processes: [AppProcessInfo] = []
        var domains: [String] = []
        var portMappings: [String] = []
        var mounts: [AppMountInfo] = []
        var restartPolicies: [String] = []

        for container in containers {
            guard let state = container.state else {
                continue
            }

            let statusText = state.status?.trimmingCharacters(in: .whitespacesAndNewlines)
            let inferredRunning = statusText?.lowercased().hasPrefix("running") ?? false
            let isRunning = state.running ?? inferredRunning

            if isRunning {
                hasRunning = true
            } else {
                hasNonRunning = true
            }

            if let statusText, !statusText.isEmpty {
                statuses.append(statusText)
                if statusText.lowercased().hasPrefix("running") {
                    hasRunning = true
                } else {
                    hasNonRunning = true
                }
            }

            processes.append(
                AppProcessInfo(
                    identifier: processIdentifier(for: container),
                    running: isRunning,
                    status: statusText,
                    startedAt: parseTimestamp(state.startedAt),
                    finishedAt: parseTimestamp(state.finishedAt),
                    exitCode: state.exitCode
                )
            )

            mounts.append(contentsOf: parseMounts(from: container))

            if let labels = container.config?.labels {
                domains.append(contentsOf: parseDelimitedLabelValues(labels["openresty.domains"]))
                portMappings.append(contentsOf: parseDelimitedLabelValues(labels["openresty.port-mapping"]))
            }

            if let restartPolicy = normalizedRestartPolicy(container.hostConfig?.restartPolicy) {
                restartPolicies.append(restartPolicy)
            }
        }

        guard hasRunning || hasNonRunning else {
            throw LiveDokkuClientError.missingInspectState(appName: appName)
        }

        let rawStatus: String
        if statuses.isEmpty {
            rawStatus = hasRunning ? "running" : "not running"
        } else {
            rawStatus = uniquePreservingOrder(statuses).joined(separator: ", ")
        }

        return ParsedInspectResult(
            state: hasRunning ? .running : .notRunning,
            rawStatus: rawStatus,
            details: AppOperationalDetails(
                processes: deduplicatedProcesses(processes),
                domains: uniquePreservingOrder(domains),
                portMappings: uniquePreservingOrder(portMappings),
                mounts: deduplicatedMounts(mounts),
                restartPolicy: uniquePreservingOrder(restartPolicies).first
            )
        )
    }

    private static func decodeInspectContainers(_ output: String, appName: String) throws -> [InspectContainer] {
        let data = Data(output.utf8)
        do {
            return try JSONDecoder().decode([InspectContainer].self, from: data)
        } catch {
            throw LiveDokkuClientError.invalidInspectJSON(appName: appName)
        }
    }

    private static func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []

        for value in values {
            let key = value.lowercased()
            if seen.insert(key).inserted {
                ordered.append(value)
            }
        }

        return ordered
    }

    private static func deduplicatedProcesses(_ processes: [AppProcessInfo]) -> [AppProcessInfo] {
        var seen: Set<String> = []
        var deduplicated: [AppProcessInfo] = []

        for process in processes {
            let key = process.identifier.lowercased()
            guard seen.insert(key).inserted else {
                continue
            }

            deduplicated.append(process)
        }

        return deduplicated.sorted {
            $0.identifier.localizedCaseInsensitiveCompare($1.identifier) == .orderedAscending
        }
    }

    private static func deduplicatedMounts(_ mounts: [AppMountInfo]) -> [AppMountInfo] {
        var seen: Set<String> = []
        var deduplicated: [AppMountInfo] = []

        for mount in mounts {
            let key = "\(mount.source.lowercased())|\(mount.destination.lowercased())|\(mount.isReadOnly)|\(mount.type.lowercased())"
            guard seen.insert(key).inserted else {
                continue
            }

            deduplicated.append(mount)
        }

        return deduplicated.sorted {
            if $0.destination.caseInsensitiveCompare($1.destination) != .orderedSame {
                return $0.destination.localizedCaseInsensitiveCompare($1.destination) == .orderedAscending
            }

            return $0.source.localizedCaseInsensitiveCompare($1.source) == .orderedAscending
        }
    }

    private static func processIdentifier(for container: InspectContainer) -> String {
        if let dyno = container.config?.labels?["com.dokku.dyno"]?.trimmingCharacters(in: .whitespacesAndNewlines), !dyno.isEmpty {
            return dyno
        }

        if let name = container.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name.hasPrefix("/") ? String(name.dropFirst()) : name
        }

        if let processType = container.config?.labels?["com.dokku.process-type"]?.trimmingCharacters(in: .whitespacesAndNewlines), !processType.isEmpty {
            return processType
        }

        return "process"
    }

    private static func parseMounts(from container: InspectContainer) -> [AppMountInfo] {
        if let mounts = container.mounts {
            let parsedMounts = mounts.compactMap { mount -> AppMountInfo? in
                guard
                    let source = mount.source?.trimmingCharacters(in: .whitespacesAndNewlines),
                    let destination = mount.destination?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !source.isEmpty,
                    !destination.isEmpty
                else {
                    return nil
                }

                let type = mount.type?.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedType = (type?.isEmpty == false) ? type ?? "bind" : "bind"

                return AppMountInfo(
                    source: source,
                    destination: destination,
                    isReadOnly: !(mount.isReadWrite ?? true),
                    type: normalizedType
                )
            }

            if !parsedMounts.isEmpty {
                return parsedMounts
            }
        }

        guard let binds = container.hostConfig?.binds else {
            return []
        }

        return binds.compactMap(parseBindMount)
    }

    private static func parseBindMount(_ bind: String) -> AppMountInfo? {
        let parts = bind
            .split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            .map(String.init)

        guard parts.count >= 2 else {
            return nil
        }

        let source = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !destination.isEmpty else {
            return nil
        }

        let mode = parts.count == 3 ? parts[2] : ""
        let isReadOnly = mode
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains("ro")

        return AppMountInfo(
            source: source,
            destination: destination,
            isReadOnly: isReadOnly,
            type: "bind"
        )
    }

    private static func parseDelimitedLabelValues(_ value: String?) -> [String] {
        guard let value else {
            return []
        }

        return value
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizedRestartPolicy(_ policy: InspectRestartPolicy?) -> String? {
        guard
            let name = policy?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else {
            return nil
        }

        let retryCount = policy?.maximumRetryCount ?? 0
        if retryCount > 0 {
            return "\(name):\(retryCount)"
        }

        return name
    }

    private static func parseTimestamp(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        guard !value.hasPrefix("0001-01-01") else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func shellEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

private struct InspectContainer: Decodable {
    let name: String?
    let state: InspectState?
    let mounts: [InspectMount]?
    let hostConfig: InspectHostConfig?
    let config: InspectConfig?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case state = "State"
        case mounts = "Mounts"
        case hostConfig = "HostConfig"
        case config = "Config"
    }
}

private struct InspectState: Decodable {
    let running: Bool?
    let status: String?
    let startedAt: String?
    let finishedAt: String?
    let exitCode: Int?

    enum CodingKeys: String, CodingKey {
        case running = "Running"
        case status = "Status"
        case startedAt = "StartedAt"
        case finishedAt = "FinishedAt"
        case exitCode = "ExitCode"
    }
}

private struct InspectMount: Decodable {
    let source: String?
    let destination: String?
    let isReadWrite: Bool?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case source = "Source"
        case destination = "Destination"
        case isReadWrite = "RW"
        case type = "Type"
    }
}

private struct InspectHostConfig: Decodable {
    let binds: [String]?
    let restartPolicy: InspectRestartPolicy?

    enum CodingKeys: String, CodingKey {
        case binds = "Binds"
        case restartPolicy = "RestartPolicy"
    }
}

private struct InspectRestartPolicy: Decodable {
    let name: String?
    let maximumRetryCount: Int?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case maximumRetryCount = "MaximumRetryCount"
    }
}

private struct InspectConfig: Decodable {
    let labels: [String: String]?

    enum CodingKeys: String, CodingKey {
        case labels = "Labels"
    }
}

struct ParsedInspectResult {
    let state: AppHealthState
    let rawStatus: String
    let details: AppOperationalDetails
}
