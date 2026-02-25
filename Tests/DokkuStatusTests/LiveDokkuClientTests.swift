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

        XCTAssertEqual(parsed, ["app-alpha", "app-beta", "app-gamma"])
    }

    func testParseLetsEncryptListFromFixture() throws {
        let output = try fixture(named: "letsencrypt-list.txt")

        let parsed = LiveDokkuClient.parseLetsEncryptList(output)

        XCTAssertEqual(parsed.keys.sorted(), ["app-alpha", "app-beta", "app-gamma"])

        let appGamma = try XCTUnwrap(parsed["app-gamma"])
        XCTAssertEqual(appGamma.certificateExpiry, "2025-10-07 22:19:26")
        XCTAssertNil(appGamma.certificateExpiryDate)
        XCTAssertEqual(appGamma.timeBeforeExpiry, "139d, 18h, 56m, 40s ago")
        XCTAssertEqual(appGamma.timeBeforeRenewal, "169d, 18h, 56m, 40s ago")
        XCTAssertTrue(appGamma.isExpired)
        XCTAssertTrue(appGamma.renewalOverdue)

        let appBeta = try XCTUnwrap(parsed["app-beta"])
        XCTAssertEqual(appBeta.timeBeforeExpiry, "82d, 12h, 10m, 1s")
        XCTAssertFalse(appBeta.isExpired)
        XCTAssertFalse(appBeta.renewalOverdue)
    }

    func testParseLetsEncryptListParsesExpiryWithRemoteTimezone() throws {
        let output = try fixture(named: "letsencrypt-list.txt")
        let parsed = LiveDokkuClient.parseLetsEncryptList(
            output,
            remoteTimeZoneIdentifier: "America/New_York",
            remoteTimeZoneAbbreviation: "EST",
            remoteTimeZoneOffset: "-0500"
        )

        let appBeta = try XCTUnwrap(parsed["app-beta"])
        let expiryDate = try XCTUnwrap(appBeta.certificateExpiryDate)
        let remoteTimeZone = try XCTUnwrap(appBeta.serverTimeZone)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = remoteTimeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        XCTAssertEqual(formatter.string(from: expiryDate), "2026-05-18 05:26:06")
        XCTAssertEqual(appBeta.serverTimeZoneIdentifier, "America/New_York")
        XCTAssertEqual(appBeta.serverTimeZoneAbbreviation, "EST")
        XCTAssertEqual(appBeta.serverTimeZoneOffset, "-0500")
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

    func testParseInspectStatusFromLiveAppAlphaRunning() throws {
        let output = try fixture(named: "ps-inspect-app-alpha.json")

        let parsed = try LiveDokkuClient.parseInspectStatus(output, appName: "app-alpha")

        XCTAssertEqual(parsed.state, .running)
        XCTAssertEqual(parsed.rawStatus.lowercased(), "running")
    }

    func testParseInspectStatusFromLiveAppBetaRunning() throws {
        let output = try fixture(named: "ps-inspect-app-beta.json")

        let parsed = try LiveDokkuClient.parseInspectStatus(output, appName: "app-beta")

        XCTAssertEqual(parsed.state, .running)
        XCTAssertEqual(parsed.rawStatus.lowercased(), "running")
    }

    func testParseInspectStatusFromLiveAppGammaNotRunning() throws {
        let output = try fixture(named: "ps-inspect-app-gamma.json")

        let parsed = try LiveDokkuClient.parseInspectStatus(output, appName: "app-gamma")

        XCTAssertEqual(parsed.state, .notRunning)
        XCTAssertEqual(parsed.rawStatus.lowercased(), "exited")
    }

    func testParseInspectDetailsFromLiveAppAlphaExtractsOpsEssentials() throws {
        let output = try fixture(named: "ps-inspect-app-alpha.json")

        let details = try LiveDokkuClient.parseInspectDetails(output, appName: "app-alpha")

        XCTAssertEqual(details.processes.map(\.identifier), ["web.1"])
        XCTAssertEqual(details.domains, ["app-alpha.example.test"])
        XCTAssertEqual(details.portMappings, ["http:80:3000", "https:443:3000"])
        XCTAssertEqual(
            details.mounts,
            [
                AppMountInfo(
                    source: "/var/lib/dokku/data/storage/app-alpha",
                    destination: "/data",
                    isReadOnly: false,
                    type: "bind"
                )
            ]
        )
        XCTAssertEqual(details.restartPolicy, "on-failure:10")

        let process = try XCTUnwrap(details.processes.first)
        XCTAssertEqual(process.processType, "web")
        XCTAssertEqual(process.containerName, "app-alpha.web.1")
        XCTAssertEqual(process.containerID, "d4fda6d91409")
        XCTAssertEqual(process.restartCount, 0)
        XCTAssertEqual(process.pid, 2_091_794)
        XCTAssertFalse(process.restarting)
        XCTAssertFalse(process.paused)
        XCTAssertFalse(process.dead)
        XCTAssertFalse(process.oomKilled)
        XCTAssertEqual(process.image, "dokku/app-alpha:latest")
        XCTAssertEqual(process.builderType, "dockerfile")
        XCTAssertEqual(process.imageStage, "release")
        XCTAssertNil(process.user)
        XCTAssertEqual(process.workingDir, "/app")
        XCTAssertEqual(process.command, "docker-entrypoint.sh node build")
        XCTAssertEqual(process.networkMode, "bridge")
        XCTAssertEqual(process.ipAddress, "10.0.0.5")
        XCTAssertEqual(process.exposedPorts, ["3000/tcp"])
        XCTAssertTrue(process.publishedPorts.isEmpty)
        XCTAssertNotNil(process.logPath)
    }

    func testParseInspectDetailsFromLiveAppGammaSupportsMultipleProcesses() throws {
        let output = try fixture(named: "ps-inspect-app-gamma.json")

        let details = try LiveDokkuClient.parseInspectDetails(output, appName: "app-gamma")

        XCTAssertEqual(details.processes.map(\.identifier), ["bot.1", "web.1"])
        let botProcess = try XCTUnwrap(details.processes.first(where: { $0.identifier == "bot.1" }))
        XCTAssertFalse(botProcess.running)
        XCTAssertEqual(botProcess.exitCode, 137)
        XCTAssertEqual(details.domains, ["app-gamma.example.test"])
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

    func testFetchAppStatusesIncludesLetsEncryptDataWhenAvailable() async throws {
        let runner = MockSSHRunner(
            responses: [
                "dokku apps:list": .success(
                    SSHCommandResult(stdout: "app-one\n", stderr: "", exitCode: 0)
                ),
                "dokku letsencrypt:list": .success(
                    SSHCommandResult(
                        stdout: """
                        -----> App name           Certificate Expiry        Time before expiry        Time before renewal
                        app-one                   2026-05-18 05:26:06       82d, 12h, 10m, 1s         52d, 12h, 10m, 1s
                        """,
                        stderr: "",
                        exitCode: 0
                    )
                ),
                "printf '%s\\t%s\\t%s\\n' \"$(cat /etc/timezone 2>/dev/null || true)\" \"$(date +%Z)\" \"$(date +%z)\"": .success(
                    SSHCommandResult(stdout: "America/New_York\tEST\t-0500\n", stderr: "", exitCode: 0)
                ),
                "dokku ps:inspect 'app-one'": .success(
                    SSHCommandResult(stdout: "[{\"State\":{\"Running\":true,\"Status\":\"running\"}}]", stderr: "", exitCode: 0)
                )
            ]
        )

        let client = LiveDokkuClient(runner: runner)
        let config = DokkuHostConfig(host: "example.com", user: "dokku", port: 22, sshAlias: nil)

        let statuses = try await client.fetchAppStatuses(config: config)
        let status = try XCTUnwrap(statuses.first)
        let cert = try XCTUnwrap(status.letsEncrypt)

        XCTAssertEqual(cert.certificateExpiry, "2026-05-18 05:26:06")
        XCTAssertNotNil(cert.certificateExpiryDate)
        XCTAssertEqual(cert.serverTimeZoneIdentifier, "America/New_York")
        XCTAssertEqual(cert.serverTimeZoneAbbreviation, "EST")
        XCTAssertEqual(cert.serverTimeZoneOffset, "-0500")
        XCTAssertEqual(cert.timeBeforeExpiry, "82d, 12h, 10m, 1s")
        XCTAssertEqual(cert.timeBeforeRenewal, "52d, 12h, 10m, 1s")
        XCTAssertFalse(cert.isExpired)
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
