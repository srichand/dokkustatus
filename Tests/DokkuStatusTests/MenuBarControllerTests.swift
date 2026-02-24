import Foundation
import XCTest
@testable import DokkuStatus

final class MenuBarControllerTests: XCTestCase {
    @MainActor
    func testMenuBarCountTextUsesRunningOverTotalWhenAppsExist() {
        let metrics = MenuStatusMetrics(
            total: 5,
            running: 3,
            notRunning: 1,
            unknown: 1,
            impactedNames: ["alpha", "beta"],
            hasChecked: true
        )

        XCTAssertEqual(MenuBarController.menuBarCountText(metrics: metrics), "3/5")
    }

    @MainActor
    func testMenuBarCountTextUsesZeroOverZeroAfterCheckedEmptyResult() {
        let metrics = MenuStatusMetrics(
            total: 0,
            running: 0,
            notRunning: 0,
            unknown: 0,
            impactedNames: [],
            hasChecked: true
        )

        XCTAssertEqual(MenuBarController.menuBarCountText(metrics: metrics), "0/0")
    }

    @MainActor
    func testMenuBarCountTextUsesDashesBeforeAnyCheck() {
        let metrics = MenuStatusMetrics(
            total: 0,
            running: 0,
            notRunning: 0,
            unknown: 0,
            impactedNames: [],
            hasChecked: false
        )

        XCTAssertEqual(MenuBarController.menuBarCountText(metrics: metrics), "--")
    }

    @MainActor
    func testImpactedSummaryTextReturnsNilWhenNoImpactedApps() {
        let metrics = MenuStatusMetrics(
            total: 2,
            running: 2,
            notRunning: 0,
            unknown: 0,
            impactedNames: [],
            hasChecked: true
        )

        XCTAssertNil(MenuBarController.impactedSummaryText(metrics: metrics))
    }

    @MainActor
    func testImpactedSummaryTextReturnsCommaSeparatedNamesWithinLimit() {
        let metrics = MenuStatusMetrics(
            total: 4,
            running: 2,
            notRunning: 1,
            unknown: 1,
            impactedNames: ["alpha", "beta", "gamma"],
            hasChecked: true
        )

        XCTAssertEqual(MenuBarController.impactedSummaryText(metrics: metrics, limit: 3), "alpha, beta, gamma")
    }

    @MainActor
    func testImpactedSummaryTextReturnsOverflowSuffixWhenExceedingLimit() {
        let metrics = MenuStatusMetrics(
            total: 6,
            running: 2,
            notRunning: 2,
            unknown: 2,
            impactedNames: ["alpha", "beta", "delta", "gamma"],
            hasChecked: true
        )

        XCTAssertEqual(MenuBarController.impactedSummaryText(metrics: metrics, limit: 3), "alpha, beta, delta +1 more")
    }

    @MainActor
    func testGroupedAppsForDetailsGroupsAndSortsAppNames() {
        let now = Date()
        let apps = [
            AppStatus(appName: "zeta", state: .running, rawStatus: "running", checkedAt: now, errorMessage: nil),
            AppStatus(appName: "beta", state: .notRunning, rawStatus: "exited", checkedAt: now, errorMessage: nil),
            AppStatus(appName: "alpha", state: .unknown, rawStatus: nil, checkedAt: now, errorMessage: "failed"),
            AppStatus(appName: "gamma", state: .running, rawStatus: "running", checkedAt: now, errorMessage: nil),
            AppStatus(appName: "delta", state: .notRunning, rawStatus: "exited", checkedAt: now, errorMessage: nil)
        ]

        let grouped = MenuBarController.groupedAppsForDetails(apps)

        XCTAssertEqual(grouped.notRunning.map(\.appName), ["beta", "delta"])
        XCTAssertEqual(grouped.unknown.map(\.appName), ["alpha"])
        XCTAssertEqual(grouped.running.map(\.appName), ["gamma", "zeta"])
    }

    @MainActor
    func testResolvedSelectedAppIDKeepsExistingSelectionWhenStillPresent() {
        let now = Date()
        let apps = [
            AppStatus(appName: "alpha", state: .running, rawStatus: "running", checkedAt: now, errorMessage: nil),
            AppStatus(appName: "beta", state: .notRunning, rawStatus: "exited", checkedAt: now, errorMessage: nil)
        ]

        let selectedID = MenuBarController.resolvedSelectedAppID(previousSelectedID: "beta", orderedApps: apps)
        XCTAssertEqual(selectedID, "beta")
    }

    @MainActor
    func testResolvedSelectedAppIDFallsBackToFirstOrderedApp() {
        let now = Date()
        let apps = [
            AppStatus(appName: "alpha", state: .running, rawStatus: "running", checkedAt: now, errorMessage: nil),
            AppStatus(appName: "beta", state: .notRunning, rawStatus: "exited", checkedAt: now, errorMessage: nil)
        ]

        let selectedID = MenuBarController.resolvedSelectedAppID(previousSelectedID: "missing", orderedApps: apps)
        XCTAssertEqual(selectedID, "alpha")
    }

    @MainActor
    func testResolvedSelectedAppIDReturnsNilWhenNoAppsExist() {
        let selectedID = MenuBarController.resolvedSelectedAppID(previousSelectedID: "beta", orderedApps: [])
        XCTAssertNil(selectedID)
    }
}
