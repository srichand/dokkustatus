import Combine
import Foundation
import OSLog

protocol HostConfigStoring {
    func loadActive() -> DokkuHostConfig?
    func saveActive(_ config: DokkuHostConfig) throws
    func clearActive()
    func loadSavedProfiles() -> [DokkuHostConfig]
    func saveSavedProfiles(_ profiles: [DokkuHostConfig]) throws
    func loadIgnoredAppsByProfile() -> [String: [String]]
    func saveIgnoredAppsByProfile(_ ignoredAppsByProfile: [String: [String]]) throws
}

final class HostConfigStore: HostConfigStoring {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let activeStorageKey = "dokku.hostConfig.v1"
    private let profilesStorageKey = "dokku.hostProfiles.v1"
    private let ignoredAppsByProfileStorageKey = "dokku.ignoredAppsByProfile.v1"
    private let legacyIgnoredAppsStorageKey = "dokku.ignoredApps.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadActive() -> DokkuHostConfig? {
        guard let data = defaults.data(forKey: activeStorageKey) else {
            return nil
        }

        return try? decoder.decode(DokkuHostConfig.self, from: data)
    }

    func saveActive(_ config: DokkuHostConfig) throws {
        let data = try encoder.encode(config)
        defaults.set(data, forKey: activeStorageKey)
    }

    func clearActive() {
        defaults.removeObject(forKey: activeStorageKey)
    }

    func loadSavedProfiles() -> [DokkuHostConfig] {
        if let data = defaults.data(forKey: profilesStorageKey),
           let decoded = try? decoder.decode([DokkuHostConfig].self, from: data)
        {
            return deduplicatedProfiles(decoded)
        }

        // Migration path from pre-profiles versions.
        if let active = loadActive() {
            return [active]
        }

        return []
    }

    func saveSavedProfiles(_ profiles: [DokkuHostConfig]) throws {
        let deduplicated = deduplicatedProfiles(profiles)
        let data = try encoder.encode(deduplicated)
        defaults.set(data, forKey: profilesStorageKey)
    }

    func loadIgnoredAppsByProfile() -> [String: [String]] {
        if let data = defaults.data(forKey: ignoredAppsByProfileStorageKey),
           let decoded = try? decoder.decode([String: [String]].self, from: data)
        {
            return normalizedIgnoredAppsByProfile(decoded)
        }

        // Migration path from previous global ignored-app list.
        let legacyIgnored = loadLegacyIgnoredApps()
        guard !legacyIgnored.isEmpty, let active = loadActive() else {
            return [:]
        }

        return [active.profileIdentifier: legacyIgnored]
    }

    func saveIgnoredAppsByProfile(_ ignoredAppsByProfile: [String: [String]]) throws {
        let normalized = normalizedIgnoredAppsByProfile(ignoredAppsByProfile)
        let data = try encoder.encode(normalized)
        defaults.set(data, forKey: ignoredAppsByProfileStorageKey)
    }

    private func deduplicatedProfiles(_ profiles: [DokkuHostConfig]) -> [DokkuHostConfig] {
        var seen: Set<String> = []
        var deduplicated: [DokkuHostConfig] = []

        for profile in profiles {
            guard !seen.contains(profile.profileIdentifier) else {
                continue
            }

            seen.insert(profile.profileIdentifier)
            deduplicated.append(profile)
        }

        return deduplicated
    }

    private func deduplicatedIgnoredApps(_ appNames: [String]) -> [String] {
        var seen: Set<String> = []
        var deduplicated: [String] = []

        for appName in appNames {
            let normalized = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else {
                continue
            }

            guard seen.insert(normalized).inserted else {
                continue
            }

            deduplicated.append(normalized)
        }

        return deduplicated.sorted()
    }

    private func normalizedIgnoredAppsByProfile(_ ignoredAppsByProfile: [String: [String]]) -> [String: [String]] {
        var normalized: [String: [String]] = [:]

        for (profileIdentifier, appNames) in ignoredAppsByProfile {
            let key = profileIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                continue
            }

            let deduplicated = deduplicatedIgnoredApps(appNames)
            guard !deduplicated.isEmpty else {
                continue
            }

            normalized[key] = deduplicated
        }

        return normalized
    }

    private func loadLegacyIgnoredApps() -> [String] {
        if let data = defaults.data(forKey: legacyIgnoredAppsStorageKey),
           let decoded = try? decoder.decode([String].self, from: data)
        {
            return deduplicatedIgnoredApps(decoded)
        }

        if let raw = defaults.array(forKey: legacyIgnoredAppsStorageKey) as? [String] {
            return deduplicatedIgnoredApps(raw)
        }

        return []
    }
}

@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var apps: [AppStatus] = []
    @Published private(set) var aggregateState: AggregateState = .unknown
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var latestError: String?
    @Published private(set) var hostConfig: DokkuHostConfig?
    @Published private(set) var availableProfiles: [HostProfileOption] = []
    @Published private(set) var ignoredApps: [String]

    private let dokkuClient: DokkuClient
    private let configStore: HostConfigStoring
    private let defaultProvider: HostConfigDefaultProviding
    private let logger = Logger(subsystem: "DokkuStatus", category: "store")
    private var savedProfiles: [DokkuHostConfig]
    private var sshProfiles: [DokkuHostConfig]
    private var ignoredAppsByProfile: [String: [String]]

    private var didHandleLaunch = false
    private var refreshQueued = false
    private var lastFetchedStatuses: [AppStatus] = []
    private var hasGlobalRefreshFailure = false

    init(
        dokkuClient: DokkuClient = LiveDokkuClient(),
        configStore: HostConfigStoring = HostConfigStore(),
        defaultProvider: HostConfigDefaultProviding = SSHConfigDefaultProvider()
    ) {
        let activeConfig = configStore.loadActive() ?? defaultProvider.loadDefaultConfig()
        let loadedIgnoredAppsByProfile = configStore.loadIgnoredAppsByProfile()
        let activeProfileIdentifier = activeConfig?.profileIdentifier ?? ""
        let activeIgnoredApps = Self.normalizeIgnoredApps(loadedIgnoredAppsByProfile[activeProfileIdentifier] ?? [])

        self.dokkuClient = dokkuClient
        self.configStore = configStore
        self.defaultProvider = defaultProvider
        self.savedProfiles = configStore.loadSavedProfiles()
        self.sshProfiles = defaultProvider.loadProfiles()
        self.hostConfig = activeConfig
        self.ignoredAppsByProfile = loadedIgnoredAppsByProfile
        self.ignoredApps = activeIgnoredApps
        rebuildAvailableProfiles()
    }

    func handleLaunch(showSettings: () -> Void) {
        guard !didHandleLaunch else {
            return
        }

        didHandleLaunch = true

        guard hostConfig != nil else {
            showSettings()
            return
        }

        requestRefresh()
    }

    func requestRefresh() {
        if isRefreshing {
            refreshQueued = true
            return
        }

        Task { await refreshNow() }
    }

    func refreshNow() async {
        if isRefreshing {
            refreshQueued = true
            return
        }

        guard let hostConfig else {
            aggregateState = .unknown
            latestError = "Configure a Dokku host in Settings."
            return
        }

        isRefreshing = true
        latestError = nil

        defer {
            isRefreshing = false
            if refreshQueued {
                refreshQueued = false
                Task { await refreshNow() }
            }
        }

        do {
            let statuses = try await dokkuClient.fetchAppStatuses(config: hostConfig)
            hasGlobalRefreshFailure = false
            lastFetchedStatuses = statuses
            apps = filteredIgnoredApps(from: statuses)
            lastCheckedAt = Date()
            latestError = collapsedAppError(from: apps)
            aggregateState = AggregateState.evaluate(apps: apps, latestError: latestError)
        } catch {
            logger.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
            hasGlobalRefreshFailure = true
            latestError = error.localizedDescription
            aggregateState = .error
        }
    }

    @discardableResult
    func saveHostConfig(
        host: String,
        user: String,
        portText: String,
        sshAlias: String?
    ) -> String? {
        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return "Port must be a number."
        }

        let candidate = DokkuHostConfig(
            host: host,
            user: user,
            port: port,
            sshAlias: sshAlias
        )

        do {
            let validated = try candidate.validated()
            try setActiveHostConfig(validated)
            upsertSavedProfile(validated)
            latestError = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func activateHostProfile(optionID: String) {
        guard let selected = availableProfiles.first(where: { $0.id == optionID }) else {
            return
        }

        do {
            try setActiveHostConfig(selected.config)
            latestError = nil
        } catch {
            latestError = error.localizedDescription
        }
    }

    func reloadProfileOptions() {
        savedProfiles = configStore.loadSavedProfiles()
        sshProfiles = defaultProvider.loadProfiles()
        rebuildAvailableProfiles()
    }

    var menuStatusMetrics: MenuStatusMetrics {
        let running = apps.filter { $0.state == .running }.count
        let notRunningApps = apps
            .filter { $0.state == .notRunning }
            .map(\.appName)
        let unknownApps = apps
            .filter { $0.state == .unknown }
            .map(\.appName)
        let impacted = (notRunningApps + unknownApps)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        return MenuStatusMetrics(
            total: apps.count,
            running: running,
            notRunning: notRunningApps.count,
            unknown: unknownApps.count,
            impactedNames: impacted,
            hasChecked: lastCheckedAt != nil
        )
    }

    var orderedAppsForMenu: [AppStatus] {
        apps.sorted { lhs, rhs in
            let lhsPriority = Self.menuStatePriority(lhs.state)
            let rhsPriority = Self.menuStatePriority(rhs.state)

            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }

            return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
        }
    }

    var activeProfileOptionID: String? {
        guard let hostConfig else {
            return nil
        }

        return availableProfiles.first(where: { $0.config.profileIdentifier == hostConfig.profileIdentifier })?.id
    }

    func clearHostConfig() {
        if let hostConfig {
            savedProfiles.removeAll { $0.profileIdentifier == hostConfig.profileIdentifier }
            try? configStore.saveSavedProfiles(savedProfiles)
        }

        sshProfiles = defaultProvider.loadProfiles()
        hostConfig = defaultProvider.loadDefaultConfig()

        if let hostConfig {
            try? configStore.saveActive(hostConfig)
        } else {
            configStore.clearActive()
        }

        syncIgnoredAppsForActiveProfile()
        rebuildAvailableProfiles()
        apps = []
        lastFetchedStatuses = []
        hasGlobalRefreshFailure = false
        aggregateState = .unknown
        latestError = nil
        lastCheckedAt = nil
    }

    @discardableResult
    func addIgnoredApp(_ appName: String) -> String? {
        guard hostConfig != nil else {
            return "Select a host profile first."
        }

        guard let normalized = Self.normalizeIgnoredAppName(appName) else {
            return "App name is required."
        }

        guard !ignoredApps.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) else {
            return "App is already ignored."
        }

        ignoredApps.append(normalized)
        ignoredApps = Self.normalizeIgnoredApps(ignoredApps)
        persistIgnoredApps()
        reapplyIgnoredAppsFilter()
        return nil
    }

    func removeIgnoredApp(_ appName: String) {
        guard hostConfig != nil else {
            return
        }

        let normalized = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let before = ignoredApps.count
        ignoredApps.removeAll { $0.caseInsensitiveCompare(normalized) == .orderedSame }
        guard ignoredApps.count != before else {
            return
        }

        persistIgnoredApps()
        reapplyIgnoredAppsFilter()
    }

    private func setActiveHostConfig(_ config: DokkuHostConfig) throws {
        try configStore.saveActive(config)
        hostConfig = config
        syncIgnoredAppsForActiveProfile()
        rebuildAvailableProfiles()

        apps = []
        lastFetchedStatuses = []
        hasGlobalRefreshFailure = false
        aggregateState = .unknown
        latestError = nil
        lastCheckedAt = nil
    }

    private func upsertSavedProfile(_ config: DokkuHostConfig) {
        if let index = savedProfiles.firstIndex(where: { $0.profileIdentifier == config.profileIdentifier }) {
            savedProfiles[index] = config
        } else {
            savedProfiles.insert(config, at: 0)
        }

        try? configStore.saveSavedProfiles(savedProfiles)
        rebuildAvailableProfiles()
    }

    private func rebuildAvailableProfiles() {
        var options: [HostProfileOption] = []
        var seen: Set<String> = []

        for saved in savedProfiles {
            guard !seen.contains(saved.profileIdentifier) else {
                continue
            }
            seen.insert(saved.profileIdentifier)
            options.append(HostProfileOption(source: .saved, config: saved))
        }

        for ssh in sshProfiles {
            guard !seen.contains(ssh.profileIdentifier) else {
                continue
            }
            seen.insert(ssh.profileIdentifier)
            options.append(HostProfileOption(source: .sshConfig, config: ssh))
        }

        if let hostConfig, !seen.contains(hostConfig.profileIdentifier) {
            options.insert(HostProfileOption(source: .active, config: hostConfig), at: 0)
        }

        availableProfiles = options
    }

    private func collapsedAppError(from statuses: [AppStatus]) -> String? {
        let uniqueErrors = Array(
            Set(
                statuses
                    .compactMap { $0.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()

        guard !uniqueErrors.isEmpty else {
            return nil
        }

        if uniqueErrors.count == 1 {
            return uniqueErrors[0]
        }

        return "\(uniqueErrors.count) app checks failed."
    }

    private func filteredIgnoredApps(from statuses: [AppStatus]) -> [AppStatus] {
        let ignored = Set(ignoredApps.map { $0.lowercased() })
        guard !ignored.isEmpty else {
            return statuses
        }

        return statuses.filter { !ignored.contains($0.appName.lowercased()) }
    }

    private func reapplyIgnoredAppsFilter() {
        apps = filteredIgnoredApps(from: lastFetchedStatuses)

        guard !hasGlobalRefreshFailure else {
            return
        }

        latestError = collapsedAppError(from: apps)
        aggregateState = AggregateState.evaluate(apps: apps, latestError: latestError)
    }

    private func persistIgnoredApps() {
        guard let hostConfig else {
            return
        }

        if ignoredApps.isEmpty {
            ignoredAppsByProfile.removeValue(forKey: hostConfig.profileIdentifier)
        } else {
            ignoredAppsByProfile[hostConfig.profileIdentifier] = ignoredApps
        }

        do {
            try configStore.saveIgnoredAppsByProfile(ignoredAppsByProfile)
        } catch {
            logger.error("Failed to persist ignored apps: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func syncIgnoredAppsForActiveProfile() {
        guard let hostConfig else {
            ignoredApps = []
            return
        }

        ignoredApps = Self.normalizeIgnoredApps(ignoredAppsByProfile[hostConfig.profileIdentifier] ?? [])
    }

    private static func normalizeIgnoredApps(_ appNames: [String]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []

        for appName in appNames {
            guard let item = normalizeIgnoredAppName(appName) else {
                continue
            }

            guard seen.insert(item).inserted else {
                continue
            }

            normalized.append(item)
        }

        return normalized.sorted()
    }

    private static func normalizeIgnoredAppName(_ appName: String) -> String? {
        let normalized = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func menuStatePriority(_ state: AppHealthState) -> Int {
        switch state {
        case .notRunning:
            return 0
        case .unknown:
            return 1
        case .running:
            return 2
        }
    }
}
