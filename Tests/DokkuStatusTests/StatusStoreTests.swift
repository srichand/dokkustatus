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

        try store.saveActive(config)
        try store.saveSavedProfiles([config])

        XCTAssertEqual(store.loadActive(), config)
        XCTAssertEqual(store.loadSavedProfiles(), [config])
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

    init(config: DokkuHostConfig?, savedProfiles: [DokkuHostConfig]? = nil) {
        self.activeConfig = config
        self.savedProfiles = savedProfiles ?? config.map { [$0] } ?? []
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
