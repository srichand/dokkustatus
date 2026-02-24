import Foundation
import XCTest
@testable import DokkuStatus

final class StatusStoreTests: XCTestCase {
    func testHostConfigStoreRoundTrip() throws {
        let suiteName = "DokkuStatusTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults)

        guard let defaults else {
            return
        }

        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = HostConfigStore(defaults: defaults)
        let config = DokkuHostConfig(host: "example.com", user: "dokku", port: 22, sshAlias: "prod")
        let ignoredApps = ["verona", "popcorn"]
        let ignoredByProfile = [config.profileIdentifier: ignoredApps]

        try store.saveActive(config)
        try store.saveSavedProfiles([config])
        try store.saveIgnoredAppsByProfile(ignoredByProfile)

        XCTAssertEqual(store.loadActive(), config)
        XCTAssertEqual(store.loadSavedProfiles(), [config])
        XCTAssertEqual(store.loadIgnoredAppsByProfile(), [config.profileIdentifier: ["popcorn", "verona"]])
    }

    func testAggregateStateHealthyPartialAndError() {
        let now = Date()
        let healthyApps = [
            AppStatus(appName: "app-one", state: .running, rawStatus: "running", checkedAt: now, errorMessage: nil)
        ]
        let partialApps = [
            AppStatus(appName: "app-one", state: .running, rawStatus: "running", checkedAt: now, errorMessage: nil),
            AppStatus(appName: "app-two", state: .unknown, rawStatus: nil, checkedAt: now, errorMessage: "failed")
        ]
        let errorApps = [
            AppStatus(appName: "app-one", state: .unknown, rawStatus: nil, checkedAt: now, errorMessage: "failed")
        ]

        XCTAssertEqual(AggregateState.evaluate(apps: healthyApps, latestError: nil), .healthy)
        XCTAssertEqual(AggregateState.evaluate(apps: partialApps, latestError: "failed"), .partial)
        XCTAssertEqual(AggregateState.evaluate(apps: errorApps, latestError: "failed"), .error)
    }

    @MainActor
    func testRefreshKeepsLastSnapshotWhenDiscoveryFails() async {
        let now = Date()
        let initialStatuses = [
            AppStatus(appName: "app-one", state: .running, rawStatus: "running", checkedAt: now, errorMessage: nil)
        ]

        let client = MockDokkuClient(
            results: [
                .success(initialStatuses),
                .failure(MockError.failed)
            ]
        )

        let configStore = InMemoryHostConfigStore(
            config: DokkuHostConfig(host: "example.com", user: "dokku", port: 22, sshAlias: nil)
        )

        let store = StatusStore(dokkuClient: client, configStore: configStore)

        await store.refreshNow()
        XCTAssertEqual(store.apps, initialStatuses)
        XCTAssertEqual(store.aggregateState, .healthy)

        await store.refreshNow()
        XCTAssertEqual(store.apps, initialStatuses)
        XCTAssertEqual(store.aggregateState, .error)
        XCTAssertNotNil(store.latestError)
    }

    @MainActor
    func testRefreshSetsPartialForMixedStates() async {
        let now = Date()
        let statuses = [
            AppStatus(appName: "app-one", state: .running, rawStatus: "running", checkedAt: now, errorMessage: nil),
            AppStatus(appName: "app-two", state: .unknown, rawStatus: nil, checkedAt: now, errorMessage: "timeout")
        ]

        let client = MockDokkuClient(results: [.success(statuses)])
        let configStore = InMemoryHostConfigStore(
            config: DokkuHostConfig(host: "example.com", user: "dokku", port: 22, sshAlias: nil)
        )

        let store = StatusStore(dokkuClient: client, configStore: configStore)

        await store.refreshNow()

        XCTAssertEqual(store.aggregateState, .partial)
        XCTAssertEqual(store.apps.count, 2)
        XCTAssertNotNil(store.latestError)
    }

    @MainActor
    func testDoubleRefreshQueuesOneFollowUpRun() async {
        let now = Date()
        let statuses = [
            AppStatus(appName: "app-one", state: .running, rawStatus: "running", checkedAt: now, errorMessage: nil)
        ]

        let client = MockDokkuClient(results: [.success(statuses), .success(statuses)], delayNanoseconds: 120_000_000)
        let configStore = InMemoryHostConfigStore(
            config: DokkuHostConfig(host: "example.com", user: "dokku", port: 22, sshAlias: nil)
        )
        let store = StatusStore(dokkuClient: client, configStore: configStore)

        store.requestRefresh()
        store.requestRefresh()

        var completed = false
        let deadline = Date().addingTimeInterval(2)

        while Date() < deadline {
            if await client.callCount() == 2 {
                completed = true
                break
            }

            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertTrue(completed)
    }

    @MainActor
    func testStoreUsesDefaultProviderWhenSavedConfigMissing() {
        let defaultConfig = DokkuHostConfig(host: "default.example.com", user: "dokku", port: 22, sshAlias: "dokku")
        let store = StatusStore(
            dokkuClient: MockDokkuClient(results: []),
            configStore: InMemoryHostConfigStore(config: nil),
            defaultProvider: MockDefaultProvider(config: defaultConfig)
        )

        XCTAssertEqual(store.hostConfig, defaultConfig)
    }

    @MainActor
    func testSavedConfigOverridesDefaultProvider() {
        let savedConfig = DokkuHostConfig(host: "saved.example.com", user: "saved", port: 2022, sshAlias: nil)
        let defaultConfig = DokkuHostConfig(host: "default.example.com", user: "dokku", port: 22, sshAlias: "dokku")
        let store = StatusStore(
            dokkuClient: MockDokkuClient(results: []),
            configStore: InMemoryHostConfigStore(config: savedConfig),
            defaultProvider: MockDefaultProvider(config: defaultConfig)
        )

        XCTAssertEqual(store.hostConfig, savedConfig)
    }

    @MainActor
    func testClearHostConfigFallsBackToDefaultProvider() {
        let savedConfig = DokkuHostConfig(host: "saved.example.com", user: "saved", port: 2022, sshAlias: nil)
        let defaultConfig = DokkuHostConfig(host: "default.example.com", user: "dokku", port: 22, sshAlias: "dokku")
        let store = StatusStore(
            dokkuClient: MockDokkuClient(results: []),
            configStore: InMemoryHostConfigStore(config: savedConfig),
            defaultProvider: MockDefaultProvider(config: defaultConfig)
        )

        store.clearHostConfig()

        XCTAssertEqual(store.hostConfig, defaultConfig)
    }

    @MainActor
    func testAvailableProfilesIncludesSavedAndSSHOptions() {
        let savedConfig = DokkuHostConfig(host: "saved.example.com", user: "saved", port: 2022, sshAlias: "saved")
        let sshConfig = DokkuHostConfig(host: "ssh.example.com", user: "dokku", port: 22, sshAlias: "dokku-ssh")
        let store = StatusStore(
            dokkuClient: MockDokkuClient(results: []),
            configStore: InMemoryHostConfigStore(config: savedConfig, savedProfiles: [savedConfig]),
            defaultProvider: MockDefaultProvider(config: savedConfig, profiles: [sshConfig])
        )

        XCTAssertTrue(store.availableProfiles.contains(where: { $0.source == .saved && $0.config == savedConfig }))
        XCTAssertTrue(store.availableProfiles.contains(where: { $0.source == .sshConfig && $0.config == sshConfig }))
    }

    @MainActor
    func testActivateHostProfileSwitchesActiveConfig() {
        let savedConfig = DokkuHostConfig(host: "saved.example.com", user: "saved", port: 2022, sshAlias: "saved")
        let sshConfig = DokkuHostConfig(host: "ssh.example.com", user: "dokku", port: 22, sshAlias: "dokku-ssh")
        let store = StatusStore(
            dokkuClient: MockDokkuClient(results: []),
            configStore: InMemoryHostConfigStore(config: savedConfig, savedProfiles: [savedConfig]),
            defaultProvider: MockDefaultProvider(config: savedConfig, profiles: [sshConfig])
        )

        guard let sshOptionID = store.availableProfiles.first(where: { $0.config == sshConfig })?.id else {
            XCTFail("Expected SSH option in profile list.")
            return
        }

        store.activateHostProfile(optionID: sshOptionID)

        XCTAssertEqual(store.hostConfig, sshConfig)
    }

    @MainActor
    func testRefreshFiltersIgnoredApps() async {
        let now = Date()
        let statuses = [
            AppStatus(appName: "charrette", state: .running, rawStatus: "running", checkedAt: now, errorMessage: nil),
            AppStatus(appName: "verona", state: .notRunning, rawStatus: "exited", checkedAt: now, errorMessage: nil)
        ]

        let client = MockDokkuClient(results: [.success(statuses)])
        let configStore = InMemoryHostConfigStore(
            config: DokkuHostConfig(host: "example.com", user: "dokku", port: 22, sshAlias: nil),
            ignoredApps: ["verona"]
        )

        let store = StatusStore(dokkuClient: client, configStore: configStore)

        await store.refreshNow()

        XCTAssertEqual(store.apps.map(\.appName), ["charrette"])
        XCTAssertEqual(store.aggregateState, .healthy)
    }

    @MainActor
    func testAddingIgnoredAppFiltersSnapshotImmediately() async {
        let now = Date()
        let statuses = [
            AppStatus(appName: "charrette", state: .running, rawStatus: "running", checkedAt: now, errorMessage: nil),
            AppStatus(appName: "verona", state: .notRunning, rawStatus: "exited", checkedAt: now, errorMessage: nil)
        ]

        let client = MockDokkuClient(results: [.success(statuses)])
        let configStore = InMemoryHostConfigStore(
            config: DokkuHostConfig(host: "example.com", user: "dokku", port: 22, sshAlias: nil)
        )
        let store = StatusStore(dokkuClient: client, configStore: configStore)

        await store.refreshNow()
        XCTAssertEqual(store.apps.count, 2)

        XCTAssertNil(store.addIgnoredApp("verona"))
        XCTAssertEqual(store.apps.map(\.appName), ["charrette"])
        let profileIdentifier = DokkuHostConfig(
            host: "example.com",
            user: "dokku",
            port: 22,
            sshAlias: nil
        ).profileIdentifier
        XCTAssertEqual(configStore.loadIgnoredAppsByProfile()[profileIdentifier], ["verona"])
    }

    @MainActor
    func testRemovingIgnoredAppRestoresFromLastSnapshot() async {
        let now = Date()
        let statuses = [
            AppStatus(appName: "charrette", state: .running, rawStatus: "running", checkedAt: now, errorMessage: nil),
            AppStatus(appName: "verona", state: .notRunning, rawStatus: "exited", checkedAt: now, errorMessage: nil)
        ]

        let client = MockDokkuClient(results: [.success(statuses)])
        let configStore = InMemoryHostConfigStore(
            config: DokkuHostConfig(host: "example.com", user: "dokku", port: 22, sshAlias: nil),
            ignoredApps: ["verona"]
        )
        let store = StatusStore(dokkuClient: client, configStore: configStore)

        await store.refreshNow()
        XCTAssertEqual(store.apps.map(\.appName), ["charrette"])

        store.removeIgnoredApp("verona")

        XCTAssertEqual(Set(store.apps.map(\.appName)), Set(["charrette", "verona"]))
    }

    @MainActor
    func testIgnoredAppsAreScopedPerHostProfile() async {
        let primaryConfig = DokkuHostConfig(host: "primary.example.com", user: "dokku", port: 22, sshAlias: "primary")
        let secondaryConfig = DokkuHostConfig(host: "secondary.example.com", user: "dokku", port: 22, sshAlias: "secondary")
        let status = AppStatus(appName: "verona", state: .running, rawStatus: "running", checkedAt: Date(), errorMessage: nil)

        let client = MockDokkuClient(results: [.success([status]), .success([status])])
        let store = StatusStore(
            dokkuClient: client,
            configStore: InMemoryHostConfigStore(config: primaryConfig, savedProfiles: [primaryConfig, secondaryConfig]),
            defaultProvider: MockDefaultProvider(config: primaryConfig, profiles: [secondaryConfig])
        )

        await store.refreshNow()
        XCTAssertNil(store.addIgnoredApp("verona"))
        XCTAssertEqual(store.apps.count, 0)

        guard let secondaryOptionID = store.availableProfiles.first(where: { $0.config == secondaryConfig })?.id else {
            XCTFail("Expected secondary profile option.")
            return
        }

        store.activateHostProfile(optionID: secondaryOptionID)
        await store.refreshNow()

        XCTAssertEqual(store.ignoredApps, [])
        XCTAssertEqual(store.apps.map(\.appName), ["verona"])
    }

    @MainActor
    func testMenuStatusMetricsUsesVisibleAppsAfterIgnoredFiltering() async {
        let now = Date()
        let statuses = [
            AppStatus(appName: "charrette", state: .running, rawStatus: "running", checkedAt: now, errorMessage: nil),
            AppStatus(appName: "verona", state: .notRunning, rawStatus: "exited", checkedAt: now, errorMessage: nil),
            AppStatus(appName: "popcorn", state: .unknown, rawStatus: nil, checkedAt: now, errorMessage: "timeout")
        ]

        let client = MockDokkuClient(results: [.success(statuses)])
        let configStore = InMemoryHostConfigStore(
            config: DokkuHostConfig(host: "example.com", user: "dokku", port: 22, sshAlias: nil),
            ignoredApps: ["verona"]
        )
        let store = StatusStore(dokkuClient: client, configStore: configStore)

        await store.refreshNow()
        let metrics = store.menuStatusMetrics

        XCTAssertEqual(metrics.total, 2)
        XCTAssertEqual(metrics.running, 1)
        XCTAssertEqual(metrics.notRunning, 0)
        XCTAssertEqual(metrics.unknown, 1)
        XCTAssertEqual(metrics.impactedNames, ["popcorn"])
        XCTAssertTrue(metrics.hasChecked)
    }

    @MainActor
    func testMenuStatusMetricsNoChecksYetIsUnknown() {
        let store = StatusStore(
            dokkuClient: MockDokkuClient(results: []),
            configStore: InMemoryHostConfigStore(config: DokkuHostConfig(host: "example.com", user: "dokku", port: 22, sshAlias: nil))
        )

        let metrics = store.menuStatusMetrics
        XCTAssertEqual(metrics.total, 0)
        XCTAssertEqual(metrics.running, 0)
        XCTAssertEqual(metrics.notRunning, 0)
        XCTAssertEqual(metrics.unknown, 0)
        XCTAssertEqual(metrics.impactedNames, [])
        XCTAssertFalse(metrics.hasChecked)
    }

    @MainActor
    func testMenuStatusMetricsPreservesLastSnapshotAfterRefreshFailure() async {
        let now = Date()
        let statuses = [
            AppStatus(appName: "charrette", state: .running, rawStatus: "running", checkedAt: now, errorMessage: nil),
            AppStatus(appName: "verona", state: .notRunning, rawStatus: "exited", checkedAt: now, errorMessage: nil)
        ]

        let client = MockDokkuClient(results: [.success(statuses), .failure(MockError.failed)])
        let configStore = InMemoryHostConfigStore(
            config: DokkuHostConfig(host: "example.com", user: "dokku", port: 22, sshAlias: nil)
        )
        let store = StatusStore(dokkuClient: client, configStore: configStore)

        await store.refreshNow()
        await store.refreshNow()
        let metrics = store.menuStatusMetrics

        XCTAssertEqual(metrics.total, 2)
        XCTAssertEqual(metrics.running, 1)
        XCTAssertEqual(metrics.notRunning, 1)
        XCTAssertEqual(metrics.unknown, 0)
        XCTAssertEqual(metrics.impactedNames, ["verona"])
        XCTAssertTrue(metrics.hasChecked)
    }

    @MainActor
    func testOrderedAppsForMenuSortsByStateThenAlphabetical() async {
        let now = Date()
        let statuses = [
            AppStatus(appName: "zeta", state: .running, rawStatus: "running", checkedAt: now, errorMessage: nil),
            AppStatus(appName: "beta", state: .notRunning, rawStatus: "exited", checkedAt: now, errorMessage: nil),
            AppStatus(appName: "alpha", state: .unknown, rawStatus: nil, checkedAt: now, errorMessage: "timeout"),
            AppStatus(appName: "delta", state: .unknown, rawStatus: nil, checkedAt: now, errorMessage: "timeout"),
            AppStatus(appName: "aardvark", state: .notRunning, rawStatus: "crashed", checkedAt: now, errorMessage: nil),
            AppStatus(appName: "gamma", state: .running, rawStatus: "running", checkedAt: now, errorMessage: nil)
        ]

        let store = StatusStore(
            dokkuClient: MockDokkuClient(results: [.success(statuses)]),
            configStore: InMemoryHostConfigStore(config: DokkuHostConfig(host: "example.com", user: "dokku", port: 22, sshAlias: nil))
        )

        await store.refreshNow()

        XCTAssertEqual(
            store.orderedAppsForMenu.map(\.appName),
            ["aardvark", "beta", "alpha", "delta", "gamma", "zeta"]
        )
    }
}

private enum MockError: Error {
    case failed
}

private actor MockDokkuClient: DokkuClient {
    private var results: [Result<[AppStatus], Error>]
    private var calls = 0
    private let delayNanoseconds: UInt64

    init(results: [Result<[AppStatus], Error>], delayNanoseconds: UInt64 = 0) {
        self.results = results
        self.delayNanoseconds = delayNanoseconds
    }

    func fetchAppStatuses(config: DokkuHostConfig) async throws -> [AppStatus] {
        calls += 1

        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }

        guard !results.isEmpty else {
            return []
        }

        return try results.removeFirst().get()
    }

    func callCount() -> Int {
        calls
    }
}

private final class InMemoryHostConfigStore: HostConfigStoring {
    private var activeConfig: DokkuHostConfig?
    private var savedProfiles: [DokkuHostConfig]
    private var ignoredAppsByProfile: [String: [String]]

    init(
        config: DokkuHostConfig?,
        savedProfiles: [DokkuHostConfig]? = nil,
        ignoredApps: [String] = []
    ) {
        self.activeConfig = config
        self.savedProfiles = savedProfiles ?? config.map { [$0] } ?? []
        if let config, !ignoredApps.isEmpty {
            self.ignoredAppsByProfile = [config.profileIdentifier: ignoredApps]
        } else {
            self.ignoredAppsByProfile = [:]
        }
    }

    func loadActive() -> DokkuHostConfig? {
        activeConfig
    }

    func saveActive(_ config: DokkuHostConfig) throws {
        self.activeConfig = config
    }

    func clearActive() {
        activeConfig = nil
    }

    func loadSavedProfiles() -> [DokkuHostConfig] {
        savedProfiles
    }

    func saveSavedProfiles(_ profiles: [DokkuHostConfig]) throws {
        savedProfiles = profiles
    }

    func loadIgnoredAppsByProfile() -> [String: [String]] {
        ignoredAppsByProfile
    }

    func saveIgnoredAppsByProfile(_ ignoredAppsByProfile: [String: [String]]) throws {
        self.ignoredAppsByProfile = ignoredAppsByProfile
    }
}

private struct MockDefaultProvider: HostConfigDefaultProviding {
    let config: DokkuHostConfig?
    let profiles: [DokkuHostConfig]

    init(config: DokkuHostConfig?) {
        self.config = config
        self.profiles = config.map { [$0] } ?? []
    }

    init(config: DokkuHostConfig?, profiles: [DokkuHostConfig]) {
        self.config = config
        self.profiles = profiles
    }

    func loadDefaultConfig() -> DokkuHostConfig? {
        config
    }

    func loadProfiles() -> [DokkuHostConfig] {
        profiles
    }
}
