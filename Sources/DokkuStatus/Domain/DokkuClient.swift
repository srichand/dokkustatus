import Foundation

protocol DokkuClient: Sendable {
    func fetchAppStatuses(config: DokkuHostConfig) async throws -> [AppStatus]
}
