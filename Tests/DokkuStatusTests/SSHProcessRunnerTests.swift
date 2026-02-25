import Foundation
import XCTest
@testable import DokkuStatus

final class SSHProcessRunnerTests: XCTestCase {
    func testRunReturnsStdoutAndStderrOnSuccess() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let script = workspace.appendingPathComponent("fake-ssh-success.sh")
        try writeExecutableScript(
            at: script,
            contents: """
            #!/bin/sh
            printf "hello from stdout\\n"
            printf "note on stderr\\n" 1>&2
            exit 0
            """
        )

        let runner = SSHProcessRunner(executablePath: script.path)
        let result = try await runner.run(
            target: "dokku@example.com",
            port: 22,
            remoteCommand: "dokku apps:list",
            timeout: 1
        )

        XCTAssertEqual(result.stdout, "hello from stdout\n")
        XCTAssertEqual(result.stderr, "note on stderr\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testRunThrowsCommandFailedIncludesTrimmedStderr() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let script = workspace.appendingPathComponent("fake-ssh-fail-stderr.sh")
        try writeExecutableScript(
            at: script,
            contents: """
            #!/bin/sh
            printf "simulated failure\\n" 1>&2
            exit 7
            """
        )

        let runner = SSHProcessRunner(executablePath: script.path)
        let remoteCommand = "dokku ps:inspect app-one"

        do {
            _ = try await runner.run(
                target: "dokku@example.com",
                port: 2222,
                remoteCommand: remoteCommand,
                timeout: 1
            )
            XCTFail("Expected command failure.")
        } catch let error as SSHProcessError {
            guard case .commandFailed(let command, let exitCode, let stderr) = error else {
                XCTFail("Expected commandFailed, got: \(error)")
                return
            }

            XCTAssertEqual(command, remoteCommand)
            XCTAssertEqual(exitCode, 7)
            XCTAssertEqual(stderr, "simulated failure")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunThrowsCommandFailedUsesCommandWhenStderrEmpty() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let script = workspace.appendingPathComponent("fake-ssh-fail-empty-stderr.sh")
        try writeExecutableScript(
            at: script,
            contents: """
            #!/bin/sh
            exit 23
            """
        )

        let runner = SSHProcessRunner(executablePath: script.path)
        let remoteCommand = "dokku logs app-one --tail 10"

        do {
            _ = try await runner.run(
                target: "dokku@example.com",
                port: 22,
                remoteCommand: remoteCommand,
                timeout: 1
            )
            XCTFail("Expected command failure.")
        } catch let error as SSHProcessError {
            guard case .commandFailed(let command, let exitCode, let stderr) = error else {
                XCTFail("Expected commandFailed, got: \(error)")
                return
            }

            XCTAssertEqual(command, remoteCommand)
            XCTAssertEqual(exitCode, 23)
            XCTAssertEqual(stderr, "")
            XCTAssertEqual(error.localizedDescription, "SSH command failed (23): \(remoteCommand)")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunThrowsLaunchFailedWhenExecutableCannotStart() async {
        let runner = SSHProcessRunner(executablePath: "/path/does/not/exist/\(UUID().uuidString)")

        do {
            _ = try await runner.run(
                target: "dokku@example.com",
                port: 22,
                remoteCommand: "dokku apps:list",
                timeout: 1
            )
            XCTFail("Expected launch failure.")
        } catch let error as SSHProcessError {
            guard case .launchFailed(let details) = error else {
                XCTFail("Expected launchFailed, got: \(error)")
                return
            }

            XCTAssertFalse(details.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunThrowsTimeoutWhenCommandExceedsDeadline() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let terminatedMarker = workspace.appendingPathComponent("timeout-terminated.marker")
        let script = workspace.appendingPathComponent("fake-ssh-timeout.sh")
        try writeExecutableScript(
            at: script,
            contents: """
            #!/bin/sh
            trap 'echo terminated > \(Self.shellSingleQuoted(terminatedMarker.path)); exit 0' TERM
            sleep 5
            """
        )

        let runner = SSHProcessRunner(executablePath: script.path)
        let remoteCommand = "dokku ps:inspect app-timeout"

        do {
            _ = try await runner.run(
                target: "dokku@example.com",
                port: 22,
                remoteCommand: remoteCommand,
                timeout: 0.1
            )
            XCTFail("Expected timeout.")
        } catch let error as SSHProcessError {
            guard case .timeout(let command) = error else {
                XCTFail("Expected timeout, got: \(error)")
                return
            }

            XCTAssertEqual(command, remoteCommand)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let didTerminate = await waitForFile(at: terminatedMarker, timeout: 1.0)
        XCTAssertTrue(didTerminate, "Expected timeout path to terminate the process.")
    }

    func testRunCancelsAndTerminatesRunningProcess() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let startedMarker = workspace.appendingPathComponent("cancel-started.marker")
        let terminatedMarker = workspace.appendingPathComponent("cancel-terminated.marker")
        let script = workspace.appendingPathComponent("fake-ssh-cancel.sh")
        try writeExecutableScript(
            at: script,
            contents: """
            #!/bin/sh
            echo started > \(Self.shellSingleQuoted(startedMarker.path))
            trap 'echo terminated > \(Self.shellSingleQuoted(terminatedMarker.path)); exit 0' TERM
            while true; do
              sleep 1
            done
            """
        )

        let runner = SSHProcessRunner(executablePath: script.path)

        let task = Task {
            try await runner.run(
                target: "dokku@example.com",
                port: 22,
                remoteCommand: "dokku ps:inspect app-cancel",
                timeout: 30
            )
        }

        let didStart = await waitForFile(at: startedMarker, timeout: 1.0)
        XCTAssertTrue(didStart, "Expected fake ssh process to start before cancellation.")

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got: \(error)")
        }

        let didTerminate = await waitForFile(at: terminatedMarker, timeout: 1.0)
        XCTAssertTrue(didTerminate, "Expected cancellation path to terminate the process.")
    }

    func testRunForwardsSSHArgumentsAndRemoteCommandAsSingleArgument() async throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let capturedArgsPath = workspace.appendingPathComponent("captured-args.txt")
        let script = workspace.appendingPathComponent("fake-ssh-args.sh")
        try writeExecutableScript(
            at: script,
            contents: """
            #!/bin/sh
            for arg in "$@"; do
              printf "%s\\n" "$arg"
            done > \(Self.shellSingleQuoted(capturedArgsPath.path))
            printf "ok\\n"
            """
        )

        let runner = SSHProcessRunner(executablePath: script.path)
        let remoteCommand = "dokku ps:inspect 'my app'"
        let result = try await runner.run(
            target: "dokku@example.com",
            port: 10022,
            remoteCommand: remoteCommand,
            timeout: 1
        )

        XCTAssertEqual(result.stdout, "ok\n")

        let captured = try String(contentsOf: capturedArgsPath, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }

        XCTAssertEqual(
            captured,
            [
                "-o",
                "BatchMode=yes",
                "-p",
                "10022",
                "dokku@example.com",
                remoteCommand
            ]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("DokkuStatus.SSHProcessRunnerTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeExecutableScript(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func waitForFile(at url: URL, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }

            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        return FileManager.default.fileExists(atPath: url.path)
    }
}
