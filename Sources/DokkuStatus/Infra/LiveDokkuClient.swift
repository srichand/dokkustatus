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

                let parsedStatus = try Self.parseInspectStatus(reportResult.stdout, appName: appName)

                statuses.append(
                    AppStatus(
                        appName: appName,
                        state: parsedStatus.state,
                        rawStatus: parsedStatus.rawStatus,
                        checkedAt: checkedAt,
                        errorMessage: nil
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
                        errorMessage: error.localizedDescription
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
        let data = Data(output.utf8)
        let containers: [InspectContainer]

        do {
            containers = try JSONDecoder().decode([InspectContainer].self, from: data)
        } catch {
            throw LiveDokkuClientError.invalidInspectJSON(appName: appName)
        }

        var statuses: [String] = []
        var hasRunning = false
        var hasNonRunning = false

        for container in containers {
            guard let state = container.state else {
                continue
            }

            if let running = state.running {
                if running {
                    hasRunning = true
                } else {
                    hasNonRunning = true
                }
            }

            if let status = state.status?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
                statuses.append(status)
                if status.lowercased().hasPrefix("running") {
                    hasRunning = true
                } else {
                    hasNonRunning = true
                }
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

        return (hasRunning ? .running : .notRunning, rawStatus)
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

    private static func shellEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

private struct InspectContainer: Decodable {
    let state: InspectState?

    enum CodingKeys: String, CodingKey {
        case state = "State"
    }
}

private struct InspectState: Decodable {
    let running: Bool?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case running = "Running"
        case status = "Status"
    }
}
