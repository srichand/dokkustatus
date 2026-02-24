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
        let letsEncryptByApp = await fetchLetsEncryptStatusByApp(target: target, port: validatedConfig.port)

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
                        details: parsedStatus.details,
                        letsEncrypt: letsEncryptByApp[appName.lowercased()]
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
                        details: nil,
                        letsEncrypt: letsEncryptByApp[appName.lowercased()]
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

    static func parseLetsEncryptList(_ output: String) -> [String: AppLetsEncryptStatus] {
        var statusesByApp: [String: AppLetsEncryptStatus] = [:]

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                continue
            }

            let normalizedLowercasedLine = line.lowercased()
            if line.hasPrefix("----->") || normalizedLowercasedLine.hasPrefix("app name") {
                continue
            }

            let columns = splitTableColumns(line)
            guard columns.count >= 4 else {
                continue
            }

            let appName = columns[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !appName.isEmpty else {
                continue
            }

            statusesByApp[appName.lowercased()] = AppLetsEncryptStatus(
                certificateExpiry: columns[1],
                timeBeforeExpiry: columns[2],
                timeBeforeRenewal: columns[3]
            )
        }

        return statusesByApp
    }

    private func fetchLetsEncryptStatusByApp(target: String, port: Int) async -> [String: AppLetsEncryptStatus] {
        do {
            let certResult = try await runner.run(
                target: target,
                port: port,
                remoteCommand: "dokku letsencrypt:list",
                timeout: 15
            )

            return Self.parseLetsEncryptList(certResult.stdout)
        } catch {
            logger.info("Skipping letsencrypt details: \(error.localizedDescription, privacy: .public)")
            return [:]
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

            let labels = container.config?.labels ?? [:]
            let statusText = normalizedString(state.status)
            let inferredRunning = statusText?.lowercased().hasPrefix("running") ?? false
            let isRunning = state.running ?? inferredRunning

            if isRunning {
                hasRunning = true
            } else {
                hasNonRunning = true
            }

            if let statusText {
                statuses.append(statusText)
                if statusText.lowercased().hasPrefix("running") {
                    hasRunning = true
                } else {
                    hasNonRunning = true
                }
            }

            let processIdentifier = processIdentifier(for: container)
            let stateError = normalizedString(state.error)
            let processType = normalizedString(labels["com.dokku.process-type"])
            let containerName = normalizedContainerName(container.name)
            let containerID = shortContainerID(container.id)
            let createdAt = parseTimestamp(container.created)
            let restartCount = container.restartCount
            let pid = state.pid
            let restarting = state.restarting ?? false
            let paused = state.paused ?? false
            let dead = state.dead ?? false
            let oomKilled = state.oomKilled ?? false
            let image = normalizedString(container.config?.image)
            let builderType = normalizedString(labels["com.dokku.builder-type"])
            let stack = normalizedString(labels["com.gliderlabs.herokuish/stack"])
            let imageStage = normalizedString(labels["com.dokku.image-stage"])
            let user = normalizedString(container.config?.user)
            let workingDir = normalizedString(container.config?.workingDir)
            let command = commandText(from: container.config)
            let networkMode = normalizedString(container.hostConfig?.networkMode)
            let ipAddress = normalizedString(container.networkSettings?.ipAddress)
            let exposedPorts = exposedPorts(from: container)
            let publishedPorts = publishedPorts(from: container.networkSettings?.ports)
            let logPath = normalizedString(container.logPath)

            processes.append(
                AppProcessInfo(
                    identifier: processIdentifier,
                    running: isRunning,
                    status: statusText,
                    startedAt: parseTimestamp(state.startedAt),
                    finishedAt: parseTimestamp(state.finishedAt),
                    exitCode: state.exitCode,
                    processType: processType,
                    containerName: containerName,
                    containerID: containerID,
                    createdAt: createdAt,
                    restartCount: restartCount,
                    pid: pid,
                    restarting: restarting,
                    paused: paused,
                    dead: dead,
                    oomKilled: oomKilled,
                    stateError: stateError,
                    image: image,
                    builderType: builderType,
                    stack: stack,
                    imageStage: imageStage,
                    user: user,
                    workingDir: workingDir,
                    command: command,
                    networkMode: networkMode,
                    ipAddress: ipAddress,
                    exposedPorts: exposedPorts,
                    publishedPorts: publishedPorts,
                    logPath: logPath
                )
            )

            mounts.append(contentsOf: parseMounts(from: container))
            domains.append(contentsOf: parseDelimitedLabelValues(labels["openresty.domains"]))
            portMappings.append(contentsOf: parseDelimitedLabelValues(labels["openresty.port-mapping"]))

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

    private static func splitTableColumns(_ line: String) -> [String] {
        line
            .replacingOccurrences(of: #"\s{2,}"#, with: "\t", options: .regularExpression)
            .split(separator: "\t")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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

    private static func normalizedString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }

    private static func normalizedContainerName(_ value: String?) -> String? {
        guard let value = normalizedString(value) else {
            return nil
        }

        if value.hasPrefix("/") {
            return String(value.dropFirst())
        }

        return value
    }

    private static func shortContainerID(_ value: String?) -> String? {
        guard let value = normalizedString(value) else {
            return nil
        }

        if value.count <= 12 {
            return value
        }

        return String(value.prefix(12))
    }

    private static func commandText(from config: InspectConfig?) -> String? {
        guard let config else {
            return nil
        }

        let parts = (config.entrypoint?.parts ?? []) + (config.cmd?.parts ?? [])
        let normalizedParts = parts.compactMap(normalizedString)
        guard !normalizedParts.isEmpty else {
            return nil
        }

        return normalizedParts.joined(separator: " ")
    }

    private static func exposedPorts(from container: InspectContainer) -> [String] {
        let fromConfig = container.config?.exposedPorts.map { Array($0.keys) } ?? []
        let fromNetwork = container.networkSettings?.ports.map { Array($0.keys) } ?? []
        return uniquePreservingOrder((fromConfig + fromNetwork).sorted())
    }

    private static func publishedPorts(from ports: [String: [InspectPortBinding]?]?) -> [String] {
        guard let ports else {
            return []
        }

        var publishedPorts: [String] = []
        for containerPort in ports.keys.sorted() {
            guard
                let bindingsByPort = ports[containerPort],
                let bindings = bindingsByPort,
                !bindings.isEmpty
            else {
                continue
            }

            let renderedBindings = bindings.compactMap { binding -> String? in
                guard let hostPort = normalizedString(binding.hostPort) else {
                    return nil
                }

                if let hostIP = normalizedString(binding.hostIP) {
                    return "\(hostIP):\(hostPort)"
                }

                return hostPort
            }

            guard !renderedBindings.isEmpty else {
                continue
            }

            publishedPorts.append("\(containerPort) -> \(renderedBindings.joined(separator: ", "))")
        }

        return publishedPorts
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
    let id: String?
    let created: String?
    let restartCount: Int?
    let logPath: String?
    let state: InspectState?
    let mounts: [InspectMount]?
    let hostConfig: InspectHostConfig?
    let networkSettings: InspectNetworkSettings?
    let config: InspectConfig?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case id = "Id"
        case created = "Created"
        case restartCount = "RestartCount"
        case logPath = "LogPath"
        case state = "State"
        case mounts = "Mounts"
        case hostConfig = "HostConfig"
        case networkSettings = "NetworkSettings"
        case config = "Config"
    }
}

private struct InspectState: Decodable {
    let dead: Bool?
    let error: String?
    let running: Bool?
    let oomKilled: Bool?
    let paused: Bool?
    let pid: Int?
    let restarting: Bool?
    let status: String?
    let startedAt: String?
    let finishedAt: String?
    let exitCode: Int?

    enum CodingKeys: String, CodingKey {
        case dead = "Dead"
        case error = "Error"
        case running = "Running"
        case oomKilled = "OOMKilled"
        case paused = "Paused"
        case pid = "Pid"
        case restarting = "Restarting"
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
    let networkMode: String?
    let restartPolicy: InspectRestartPolicy?

    enum CodingKeys: String, CodingKey {
        case binds = "Binds"
        case networkMode = "NetworkMode"
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
    let cmd: InspectCommand?
    let entrypoint: InspectCommand?
    let exposedPorts: [String: InspectExposedPort]?
    let image: String?
    let labels: [String: String]?
    let user: String?
    let workingDir: String?

    enum CodingKeys: String, CodingKey {
        case cmd = "Cmd"
        case entrypoint = "Entrypoint"
        case exposedPorts = "ExposedPorts"
        case image = "Image"
        case labels = "Labels"
        case user = "User"
        case workingDir = "WorkingDir"
    }
}

private struct InspectExposedPort: Decodable {}

private struct InspectNetworkSettings: Decodable {
    let ipAddress: String?
    let ports: [String: [InspectPortBinding]?]?

    enum CodingKeys: String, CodingKey {
        case ipAddress = "IPAddress"
        case ports = "Ports"
    }
}

private struct InspectPortBinding: Decodable {
    let hostIP: String?
    let hostPort: String?

    enum CodingKeys: String, CodingKey {
        case hostIP = "HostIp"
        case hostPort = "HostPort"
    }
}

private enum InspectCommand: Decodable {
    case array([String])
    case string(String)

    var parts: [String] {
        switch self {
        case .array(let values):
            return values
        case .string(let value):
            return [value]
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let values = try? container.decode([String].self) {
            self = .array(values)
            return
        }

        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }

        throw DecodingError.typeMismatch(
            InspectCommand.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a command string or command string array."
            )
        )
    }
}

struct ParsedInspectResult {
    let state: AppHealthState
    let rawStatus: String
    let details: AppOperationalDetails
}
