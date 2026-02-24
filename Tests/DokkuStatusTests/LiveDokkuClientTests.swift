import Foundation
import XCTest
@testable import DokkuStatus

final class LiveDokkuClientTests: XCTestCase {
    func testParseAppsListTrimsWhitespaceAndSkipsEmptyLines() {
        let output = "\n app-one \n\napp-two\n  \n"

        let parsed = LiveDokkuClient.parseAppsList(output)

        XCTAssertEqual(parsed, ["app-one", "app-two"])
    }

    func testParseAppsListSkipsDokkuHeaderLines() {
        let output = "=====> My Apps\napp-one\napp-two\n"

        let parsed = LiveDokkuClient.parseAppsList(output)

        XCTAssertEqual(parsed, ["app-one", "app-two"])
    }

    func testParseAppsListFromLiveFixture() throws {
        let output = try fixture(named: "apps-list.txt")

        let parsed = LiveDokkuClient.parseAppsList(output)

        XCTAssertEqual(parsed, ["charrette", "popcorn", "verona"])
    }

    func testParseInspectStatusRunningSingleContainer() throws {
        let output = """
        [
          {
            "State": {
              "Running": true,
              "Status": "running"
            }
          }
        ]
        """

        let parsed = try LiveDokkuClient.parseInspectStatus(output, appName: "app-one")

        XCTAssertEqual(parsed.state, .running)
        XCTAssertEqual(parsed.rawStatus, "running")
    }

    func testParseInspectStatusNonRunningSingleContainer() throws {
        let output = """
        [
          {
            "State": {
              "Running": false,
              "Status": "exited"
            }
          }
        ]
        """

        let parsed = try LiveDokkuClient.parseInspectStatus(output, appName: "app-one")

        XCTAssertEqual(parsed.state, .notRunning)
        XCTAssertEqual(parsed.rawStatus, "exited")
    }

    func testParseInspectStatusFromLiveCharretteRunning() throws {
        let output = try fixture(named: "ps-inspect-charrette.json")

        let parsed = try LiveDokkuClient.parseInspectStatus(output, appName: "charrette")

        XCTAssertEqual(parsed.state, .running)
        XCTAssertEqual(parsed.rawStatus.lowercased(), "running")
    }

    func testParseInspectStatusFromLivePopcornRunning() throws {
        let output = try fixture(named: "ps-inspect-popcorn.json")

        let parsed = try LiveDokkuClient.parseInspectStatus(output, appName: "popcorn")

        XCTAssertEqual(parsed.state, .running)
        XCTAssertEqual(parsed.rawStatus.lowercased(), "running")
    }

    func testParseInspectStatusFromLiveVeronaNotRunning() throws {
        let output = try fixture(named: "ps-inspect-verona.json")

        let parsed = try LiveDokkuClient.parseInspectStatus(output, appName: "verona")

        XCTAssertEqual(parsed.state, .notRunning)
        XCTAssertEqual(parsed.rawStatus.lowercased(), "exited")
    }

    func testParseInspectDetailsFromLiveCharretteExtractsOpsEssentials() throws {
        let output = try fixture(named: "ps-inspect-charrette.json")

        let details = try LiveDokkuClient.parseInspectDetails(output, appName: "charrette")

        XCTAssertEqual(details.processes.map(\.identifier), ["web.1"])
        XCTAssertEqual(details.domains, ["charrette.pendyala.net"])
        XCTAssertEqual(details.portMappings, ["http:80:3000", "https:443:3000"])
        XCTAssertEqual(
            details.mounts,
            [
                AppMountInfo(
                    source: "/var/lib/dokku/data/storage/charrette",
                    destination: "/data",
                    isReadOnly: false,
                    type: "bind"
                )
            ]
        )
        XCTAssertEqual(details.restartPolicy, "on-failure:10")
    }

    func testParseInspectDetailsFromLiveVeronaSupportsMultipleProcesses() throws {
        let output = try fixture(named: "ps-inspect-verona.json")

        let details = try LiveDokkuClient.parseInspectDetails(output, appName: "verona")

        XCTAssertEqual(details.processes.map(\.identifier), ["bot.1", "web.1"])
        let botProcess = try XCTUnwrap(details.processes.first(where: { $0.identifier == "bot.1" }))
        XCTAssertFalse(botProcess.running)
        XCTAssertEqual(botProcess.exitCode, 137)
        XCTAssertEqual(details.domains, ["verona.pendyala.net"])
        XCTAssertEqual(details.portMappings, ["https:443:5000"])
        XCTAssertEqual(details.restartPolicy, "no")
    }

    func testParseInspectDetailsHandlesMissingNetworkFieldsGracefully() throws {
        let output = """
        [
          {
            "Name": "/worker.bot.1",
            "State": {
              "Running": false,
              "Status": "exited",
              "ExitCode": 12
            },
            "HostConfig": {
              "RestartPolicy": {
                "Name": "no",
                "MaximumRetryCount": 0
              }
            },
            "Config": {
              "Labels": {
                "com.dokku.dyno": "bot.1"
              }
            }
          }
        ]
        """

        let details = try LiveDokkuClient.parseInspectDetails(output, appName: "worker")

        XCTAssertEqual(details.processes.map(\.identifier), ["bot.1"])
        XCTAssertTrue(details.domains.isEmpty)
        XCTAssertTrue(details.portMappings.isEmpty)
        XCTAssertTrue(details.mounts.isEmpty)
        XCTAssertEqual(details.restartPolicy, "no")
    }

    func testParseInspectDetailsFallsBackToHostConfigBindsWhenMountsMissing() throws {
        let output = """
        [
          {
            "Name": "/example.web.1",
            "State": {
              "Running": true,
              "Status": "running",
              "StartedAt": "2026-02-23T18:06:19.467671479Z"
            },
            "HostConfig": {
              "Binds": [
                "/data/source:/app/data:ro"
              ],
              "RestartPolicy": {
                "Name": "always",
                "MaximumRetryCount": 0
              }
            },
            "Config": {
              "Labels": {
                "com.dokku.dyno": "web.1"
              }
            }
          }
        ]
        """

        let details = try LiveDokkuClient.parseInspectDetails(output, appName: "example")

        XCTAssertEqual(details.processes.map(\.identifier), ["web.1"])
        XCTAssertEqual(details.restartPolicy, "always")
        XCTAssertEqual(
            details.mounts,
            [
                AppMountInfo(
                    source: "/data/source",
                    destination: "/app/data",
                    isReadOnly: true,
                    type: "bind"
                )
            ]
        )
    }

    func testParseInspectStatusThrowsWhenInvalidJSON() {
        XCTAssertThrowsError(try LiveDokkuClient.parseInspectStatus("No status here", appName: "app-one"))
    }

    func testFetchAppStatusesReturnsUnknownForPerAppFailures() async throws {
        let runner = MockSSHRunner(
            responses: [
                "dokku apps:list": .success(
                    SSHCommandResult(stdout: "app-one\napp-two\n", stderr: "", exitCode: 0)
                ),
                "dokku ps:inspect 'app-one'": .success(
                    SSHCommandResult(stdout: "[{\"State\":{\"Running\":true,\"Status\":\"running\"}}]", stderr: "", exitCode: 0)
                ),
                "dokku ps:inspect 'app-two'": .failure(MockError.failed)
            ]
        )

        let client = LiveDokkuClient(runner: runner)
        let config = DokkuHostConfig(host: "example.com", user: "dokku", port: 22, sshAlias: nil)

        let statuses = try await client.fetchAppStatuses(config: config)

        XCTAssertEqual(statuses.count, 2)
        XCTAssertEqual(statuses[0].appName, "app-one")
        XCTAssertEqual(statuses[0].state, .running)
        XCTAssertNotNil(statuses[0].details)

        XCTAssertEqual(statuses[1].appName, "app-two")
        XCTAssertEqual(statuses[1].state, .unknown)
        XCTAssertNotNil(statuses[1].errorMessage)
        XCTAssertNil(statuses[1].details)
    }

    func testFetchAppStatusesThrowsWhenDiscoveryFails() async {
        let runner = MockSSHRunner(
            responses: [
                "dokku apps:list": .failure(MockError.failed)
            ]
        )

        let client = LiveDokkuClient(runner: runner)
        let config = DokkuHostConfig(host: "example.com", user: "dokku", port: 22, sshAlias: nil)

        await XCTAssertThrowsErrorAsync {
            _ = try await client.fetchAppStatuses(config: config)
        }
    }
}

private enum MockError: Error {
    case failed
}

private actor MockSSHRunner: SSHRunning {
    private let responses: [String: Result<SSHCommandResult, Error>]

    init(responses: [String: Result<SSHCommandResult, Error>]) {
        self.responses = responses
    }

    func run(target: String, port: Int, remoteCommand: String, timeout: TimeInterval) async throws -> SSHCommandResult {
        guard let response = responses[remoteCommand] else {
            throw MockError.failed
        }

        return try response.get()
    }
}

private func fixture(named name: String) throws -> String {
    let url =
        Bundle.module.url(forResource: name, withExtension: nil) ??
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/live") ??
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "live")

    guard let url else {
        throw NSError(
            domain: "LiveDokkuClientTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Missing fixture: \(name)"]
        )
    }

    return try String(contentsOf: url, encoding: .utf8)
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw.", file: file, line: line)
    } catch {
        // Expected path.
    }
}
