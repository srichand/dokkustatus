@preconcurrency import Foundation
import OSLog

struct SSHCommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum SSHProcessError: LocalizedError {
    case launchFailed(String)
    case timeout(command: String)
    case commandFailed(command: String, exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let details):
            return "Failed to launch ssh: \(details)"
        case .timeout(let command):
            return "SSH command timed out: \(command)"
        case .commandFailed(let command, let exitCode, let stderr):
            if stderr.isEmpty {
                return "SSH command failed (\(exitCode)): \(command)"
            }

            return "SSH command failed (\(exitCode)): \(stderr)"
        }
    }
}

protocol SSHRunning: Sendable {
    func run(target: String, port: Int, remoteCommand: String, timeout: TimeInterval) async throws -> SSHCommandResult
}

final class SSHProcessRunner: SSHRunning, @unchecked Sendable {
    private let executablePath: String
    private let logger = Logger(subsystem: "DokkuStatus", category: "ssh")

    init(executablePath: String = "/usr/bin/ssh") {
        self.executablePath = executablePath
    }

    func run(
        target: String,
        port: Int,
        remoteCommand: String,
        timeout: TimeInterval = 15
    ) async throws -> SSHCommandResult {
        try await Task.detached(priority: .utility) { [executablePath, logger] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["-o", "BatchMode=yes", "-p", "\(port)", target, remoteCommand]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            #if DEBUG
            logger.debug(
                "Running SSH command: ssh -o BatchMode=yes -p \(port, privacy: .public) \(target, privacy: .public) \(remoteCommand, privacy: .public)"
            )
            #else
            logger.info("Running Dokku command over SSH")
            #endif

            do {
                try process.run()
            } catch {
                throw SSHProcessError.launchFailed(error.localizedDescription)
            }

            do {
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning, Date() < deadline {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            } catch {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }

                throw error
            }

            if process.isRunning {
                process.terminate()
                throw SSHProcessError.timeout(command: remoteCommand)
            }

            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            let result = SSHCommandResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)

            if result.exitCode != 0 {
                throw SSHProcessError.commandFailed(
                    command: remoteCommand,
                    exitCode: result.exitCode,
                    stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

            return result
        }.value
    }
}
