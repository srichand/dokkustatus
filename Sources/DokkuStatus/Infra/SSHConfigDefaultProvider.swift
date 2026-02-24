import Foundation
import OSLog

protocol HostConfigDefaultProviding {
    func loadDefaultConfig() -> DokkuHostConfig?
    func loadProfiles() -> [DokkuHostConfig]
}

struct SSHConfigDefaultProvider: HostConfigDefaultProviding {
    private let logger = Logger(subsystem: "DokkuStatus", category: "ssh-config")
    private let fileURL: URL
    private let currentUser: String

    init(
        fileURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config"),
        currentUser: String = NSUserName()
    ) {
        self.fileURL = fileURL
        self.currentUser = currentUser
    }

    func loadDefaultConfig() -> DokkuHostConfig? {
        let profiles = loadProfiles()
        let config = profiles.first(where: { ($0.sshAlias ?? "").localizedCaseInsensitiveContains("dokku") })
            ?? profiles.first
        if config == nil {
            logger.info("No usable SSH host defaults found in ~/.ssh/config")
        }

        return config
    }

    func loadProfiles() -> [DokkuHostConfig] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let contents = String(data: data, encoding: .utf8)
        else {
            return []
        }

        return Self.parseProfiles(contents: contents, currentUser: currentUser)
    }

    static func parseDefaultConfig(contents: String, currentUser: String = NSUserName()) -> DokkuHostConfig? {
        let profiles = parseProfiles(contents: contents, currentUser: currentUser)
        return profiles.first(where: { ($0.sshAlias ?? "").localizedCaseInsensitiveContains("dokku") })
            ?? profiles.first
    }

    static func parseProfiles(contents: String, currentUser: String = NSUserName()) -> [DokkuHostConfig] {
        var globalUser: String?
        var globalPort: Int?

        var entries: [SSHHostEntry] = []
        var currentEntry: SSHHostEntry?

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let strippedLine = stripComment(from: line)
            let trimmedLine = strippedLine.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmedLine.isEmpty else {
                continue
            }

            let parts = trimmedLine.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count == 2 else {
                continue
            }

            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            switch key {
            case "host":
                if let currentEntry {
                    entries.append(currentEntry)
                }

                let aliases = value
                    .split(whereSeparator: { $0.isWhitespace })
                    .map(String.init)
                currentEntry = SSHHostEntry(aliases: aliases)

            case "hostname":
                if currentEntry != nil {
                    currentEntry?.hostName = firstToken(in: value)
                }

            case "user":
                let parsedUser = firstToken(in: value)
                if currentEntry != nil {
                    currentEntry?.user = parsedUser
                } else {
                    globalUser = parsedUser
                }

            case "port":
                let parsedPort = Int(firstToken(in: value) ?? "")
                if currentEntry != nil {
                    currentEntry?.port = parsedPort
                } else {
                    globalPort = parsedPort
                }

            default:
                continue
            }
        }

        if let currentEntry {
            entries.append(currentEntry)
        }

        var profiles: [DokkuHostConfig] = []
        var seen: Set<String> = []

        for entry in entries {
            let aliases = entry.aliases.filter(isConcreteAlias(_:))
            guard !aliases.isEmpty else {
                continue
            }

            for alias in aliases {
                let host = entry.hostName ?? alias
                let user = entry.user ?? globalUser ?? currentUser
                let port = entry.port ?? globalPort ?? 22
                let candidate = DokkuHostConfig(
                    host: host,
                    user: user,
                    port: port,
                    sshAlias: alias
                )

                guard let validated = try? candidate.validated() else {
                    continue
                }

                guard !seen.contains(validated.profileIdentifier) else {
                    continue
                }

                seen.insert(validated.profileIdentifier)
                profiles.append(validated)
            }
        }

        return profiles
    }

    private static func stripComment(from line: String) -> String {
        guard let hashIndex = line.firstIndex(of: "#") else {
            return line
        }

        return String(line[..<hashIndex])
    }

    private static func firstToken(in value: String) -> String? {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)
    }

    private static func isConcreteAlias(_ alias: String) -> Bool {
        if alias.contains("*") || alias.contains("?") {
            return false
        }

        if alias.hasPrefix("!") {
            return false
        }

        return !alias.isEmpty
    }
}

private struct SSHHostEntry {
    var aliases: [String]
    var hostName: String?
    var user: String?
    var port: Int?

    init(aliases: [String], hostName: String? = nil, user: String? = nil, port: Int? = nil) {
        self.aliases = aliases
        self.hostName = hostName
        self.user = user
        self.port = port
    }
}
