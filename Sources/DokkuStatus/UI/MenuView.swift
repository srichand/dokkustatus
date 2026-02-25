import Foundation
import SwiftUI

struct MenuView: View {
    @ObservedObject var store: StatusStore
    let onQuit: () -> Void
    @State private var selectedAppID: String?
    @State private var now = Date()
    @State private var sectionExpansionState: [String: Bool] = [:]
    @State private var expandedProcessIDs: Set<String> = []
    private let secondTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

            if let latestError = store.latestError {
                errorRow(message: latestError)
            }

            if orderedApps.isEmpty {
                Text(emptyStateText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                appList
                appDetailsPanel
            }

            Divider()

            HStack(spacing: 8) {
                Button(store.isRefreshing ? "Refreshing…" : "Refresh Now") {
                    store.requestRefresh()
                }
                .disabled(store.isRefreshing || store.hostConfig == nil)

                Spacer()

                SettingsLink {
                    Text("Settings…")
                }

                Button("Quit") {
                    onQuit()
                }
            }
        }
        .padding(12)
        .frame(width: 460)
        .onAppear {
            syncSelectedApp()
        }
        .onChange(of: store.apps) { _, _ in
            syncSelectedApp()
        }
        .onChange(of: selectedAppID) { _, _ in
            expandedProcessIDs.removeAll()
        }
        .onReceive(secondTicker) { now = $0 }
    }

    private var orderedApps: [AppStatus] {
        store.orderedAppsForMenu
    }

    private var selectedApp: AppStatus? {
        guard let selectedAppID else {
            return nil
        }

        return orderedApps.first(where: { $0.id == selectedAppID })
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Host: \(store.hostConfig?.displayTitle ?? "Not configured")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Text("Last check: \(MenuBarController.relativeDateString(from: store.lastCheckedAt, relativeTo: now))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apps")
                .font(.headline)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(orderedApps) { app in
                        appRowButton(app)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: 190)
        }
    }

    private func errorRow(message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Retry") {
                    store.requestRefresh()
                }
                .disabled(store.isRefreshing || store.hostConfig == nil)
                .font(.caption)
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func appRowButton(_ app: AppStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.appName)
                    .font(.body)
                Text(MenuBarController.relativeDateString(from: app.checkedAt, relativeTo: now))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(MenuBarController.badgeTitle(for: app.state))
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(MenuBarController.badgeColor(for: app.state).opacity(0.16), in: Capsule())
                .foregroundStyle(MenuBarController.badgeColor(for: app.state))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selectedAppID == app.id ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedAppID = app.id
        }
    }

    private var appDetailsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("App Details")
                .font(.headline)

            if let selectedApp {
                ScrollView {
                    selectedAppDetails(selectedApp)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            } else {
                Text("Select an app to view details.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func selectedAppDetails(_ app: AppStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(app.appName)
                    .font(.headline)

                Spacer()

                Text(MenuBarController.badgeTitle(for: app.state))
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(MenuBarController.badgeColor(for: app.state).opacity(0.16), in: Capsule())
                    .foregroundStyle(MenuBarController.badgeColor(for: app.state))
            }

            detailsSection(title: "Summary") {
                keyValueRow(key: "Last checked", value: MenuBarController.relativeDateString(from: app.checkedAt, relativeTo: now))
                keyValueRow(key: "Raw status", value: app.rawStatus ?? "unknown")
                keyValueRow(
                    key: "Processes",
                    value: app.details.map { "\($0.processes.count) process(es)" } ?? "inspect unavailable"
                )
                if let errorMessage = app.errorMessage, !errorMessage.isEmpty {
                    keyValueRow(key: "Inspect error", value: errorMessage)
                }
                if let letsEncrypt = app.letsEncrypt {
                    keyValueRow(
                        key: "TLS",
                        value: letsEncrypt.isExpired ? "expired (\(letsEncrypt.timeBeforeExpiry))" : "valid (\(letsEncrypt.timeBeforeExpiry))"
                    )
                } else {
                    keyValueRow(key: "TLS", value: "no letsencrypt data")
                }
            }

            disclosureSection(id: "tls", title: "TLS (Let's Encrypt)", defaultExpanded: true) {
                if let letsEncrypt = app.letsEncrypt {
                    keyValueRow(key: "Status", value: letsEncrypt.isExpired ? "Expired" : "Valid")
                    if let certificateExpiryDate = letsEncrypt.certificateExpiryDate {
                        if let serverTimeZone = letsEncrypt.serverTimeZone {
                            keyValueRow(
                                key: "Certificate expiry (server)",
                                value: formattedDateTime(certificateExpiryDate, in: serverTimeZone)
                            )
                        } else {
                            keyValueRow(
                                key: "Certificate expiry",
                                value: formattedDateTime(certificateExpiryDate, in: TimeZone.autoupdatingCurrent)
                            )
                        }

                        keyValueRow(
                            key: "Certificate expiry (you)",
                            value: formattedDateTime(certificateExpiryDate, in: TimeZone.autoupdatingCurrent)
                        )
                    } else {
                        keyValueRow(key: "Certificate expiry", value: letsEncrypt.certificateExpiry)
                    }
                    keyValueRow(key: "Server timezone", value: formattedServerTimeZone(letsEncrypt))
                    keyValueRow(key: "Your timezone", value: formattedTimeZone(TimeZone.autoupdatingCurrent))
                    keyValueRow(key: "Time before expiry", value: letsEncrypt.timeBeforeExpiry)
                    keyValueRow(key: "Time before renewal", value: letsEncrypt.timeBeforeRenewal)
                } else {
                    Text("No letsencrypt certificate data found for this app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let details = app.details {
                disclosureSection(id: "health", title: "Health & Runtime", defaultExpanded: true) {
                    keyValueRow(key: "Restart policy", value: details.restartPolicy ?? "unknown")
                    keyValueRow(
                        key: "Process health",
                        value: "\(details.processes.filter(\.running).count) running / \(details.processes.count) total"
                    )
                    let nonZeroExits = details.processes.compactMap(\.exitCode).filter { $0 != 0 }
                    if !nonZeroExits.isEmpty {
                        keyValueRow(key: "Non-zero exits", value: nonZeroExits.map(String.init).joined(separator: ", "))
                    }
                    let runtimeFlags = processRuntimeFlags(details.processes)
                    if !runtimeFlags.isEmpty {
                        keyValueRow(key: "Flags", value: runtimeFlags.joined(separator: ", "))
                    }
                }

                disclosureSection(id: "processes", title: "Processes (\(details.processes.count))", defaultExpanded: true) {
                    ForEach(details.processes, id: \.identifier) { process in
                        processDisclosure(process)
                    }
                }

                disclosureSection(id: "networking", title: "Networking") {
                    keyValueRow(
                        key: "Domains",
                        value: details.domains.isEmpty ? "none" : details.domains.joined(separator: ", ")
                    )
                    keyValueRow(
                        key: "Port mapping",
                        value: details.portMappings.isEmpty ? "none" : details.portMappings.joined(separator: ", ")
                    )
                    let networkModes = uniqueSorted(details.processes.compactMap(\.networkMode))
                    keyValueRow(key: "Network mode", value: networkModes.isEmpty ? "unknown" : networkModes.joined(separator: ", "))

                    let containerIPs = uniqueSorted(details.processes.compactMap(\.ipAddress))
                    keyValueRow(key: "Container IPs", value: containerIPs.isEmpty ? "none" : containerIPs.joined(separator: ", "))

                    let exposedPorts = uniqueSorted(details.processes.flatMap(\.exposedPorts))
                    keyValueRow(key: "Exposed ports", value: exposedPorts.isEmpty ? "none" : exposedPorts.joined(separator: ", "))

                    let publishedPorts = uniqueSorted(details.processes.flatMap(\.publishedPorts))
                    keyValueRow(key: "Published ports", value: publishedPorts.isEmpty ? "none" : publishedPorts.joined(separator: ", "))
                }

                disclosureSection(id: "storage", title: "Storage") {
                    if details.mounts.isEmpty {
                        keyValueRow(key: "Mounts", value: "none")
                    } else {
                        ForEach(details.mounts.indices, id: \.self) { index in
                            let mount = details.mounts[index]
                            keyValueRow(
                                key: "Mount \(index + 1)",
                                value: "\(mount.source) -> \(mount.destination) (\(mount.isReadOnly ? "RO" : "RW"))"
                            )
                        }
                    }
                }

                disclosureSection(id: "deployment", title: "Deployment & Build") {
                    let images = uniqueSorted(details.processes.compactMap(\.image))
                    keyValueRow(key: "Image", value: images.isEmpty ? "unknown" : images.joined(separator: ", "))

                    let builders = uniqueSorted(details.processes.compactMap(\.builderType))
                    keyValueRow(key: "Builder", value: builders.isEmpty ? "unknown" : builders.joined(separator: ", "))

                    let stacks = uniqueSorted(details.processes.compactMap(\.stack))
                    keyValueRow(key: "Stack", value: stacks.isEmpty ? "unknown" : stacks.joined(separator: ", "))

                    let imageStages = uniqueSorted(details.processes.compactMap(\.imageStage))
                    keyValueRow(key: "Image stage", value: imageStages.isEmpty ? "unknown" : imageStages.joined(separator: ", "))
                }
            } else {
                Text("No inspect JSON details are available for this app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detailsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            content()
                .font(.caption)
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func disclosureSection<Content: View>(
        id: String,
        title: String,
        defaultExpanded: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isExpanded = sectionExpansionState[id] ?? defaultExpanded

        return VStack(alignment: .leading, spacing: 2) {
            Button {
                sectionExpansionState[id] = !isExpanded
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    content()
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
                .padding(.leading, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func processDisclosure(_ process: AppProcessInfo) -> some View {
        let isExpanded = expandedProcessIDs.contains(process.identifier)

        return VStack(alignment: .leading, spacing: 2) {
            Button {
                if isExpanded {
                    expandedProcessIDs.remove(process.identifier)
                } else {
                    expandedProcessIDs.insert(process.identifier)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(process.identifier)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(process.status ?? (process.running ? "running" : "not running"))
                        .font(.caption2)
                        .foregroundStyle(process.running ? .green : .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                processRow(process)
                    .padding(.leading, 14)
            }
        }
        .padding(.vertical, 2)
    }

    private func processRow(_ process: AppProcessInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            keyValueRow(key: "Identifier", value: process.identifier)
            if let processType = process.processType {
                keyValueRow(key: "Process type", value: processType)
            }
            keyValueRow(key: "Status", value: process.status ?? (process.running ? "running" : "not running"))
            if let startedAt = process.startedAt {
                keyValueRow(key: "Started", value: MenuBarController.relativeDateString(from: startedAt, relativeTo: now))
            }
            if !process.running, let finishedAt = process.finishedAt {
                keyValueRow(key: "Finished", value: MenuBarController.relativeDateString(from: finishedAt, relativeTo: now))
            }
            if !process.running, let exitCode = process.exitCode {
                keyValueRow(key: "Exit code", value: "\(exitCode)")
            }
            if let containerName = process.containerName {
                keyValueRow(key: "Container", value: containerName)
            }
            if let containerID = process.containerID {
                keyValueRow(key: "Container ID", value: containerID)
            }
            if let createdAt = process.createdAt {
                keyValueRow(key: "Created", value: MenuBarController.relativeDateString(from: createdAt, relativeTo: now))
            }
            if let restartCount = process.restartCount {
                keyValueRow(key: "Restart count", value: "\(restartCount)")
            }
            if let pid = process.pid, pid > 0 {
                keyValueRow(key: "PID", value: "\(pid)")
            }
            let flags = processFlags(for: process)
            if !flags.isEmpty {
                keyValueRow(key: "Flags", value: flags.joined(separator: ", "))
            }
            if let stateError = process.stateError {
                keyValueRow(key: "State error", value: stateError)
            }
            if let image = process.image {
                keyValueRow(key: "Image", value: image)
            }
            if let builderType = process.builderType {
                keyValueRow(key: "Builder", value: builderType)
            }
            if let stack = process.stack {
                keyValueRow(key: "Stack", value: stack)
            }
            if let imageStage = process.imageStage {
                keyValueRow(key: "Image stage", value: imageStage)
            }
            if let user = process.user {
                keyValueRow(key: "User", value: user)
            }
            if let workingDir = process.workingDir {
                keyValueRow(key: "Workdir", value: workingDir)
            }
            if let command = process.command {
                keyValueRow(key: "Command", value: command)
            }
            if let networkMode = process.networkMode {
                keyValueRow(key: "Network mode", value: networkMode)
            }
            if let ipAddress = process.ipAddress {
                keyValueRow(key: "IP address", value: ipAddress)
            }
            if !process.exposedPorts.isEmpty {
                keyValueRow(key: "Exposed ports", value: process.exposedPorts.joined(separator: ", "))
            }
            if !process.publishedPorts.isEmpty {
                keyValueRow(key: "Published ports", value: process.publishedPorts.joined(separator: ", "))
            }
            if let logPath = process.logPath {
                keyValueRow(key: "Log path", value: logPath)
            }
        }
    }

    private func processFlags(for process: AppProcessInfo) -> [String] {
        var flags: [String] = []
        if process.restarting {
            flags.append("restarting")
        }
        if process.paused {
            flags.append("paused")
        }
        if process.dead {
            flags.append("dead")
        }
        if process.oomKilled {
            flags.append("oom-killed")
        }

        return flags
    }

    private func processRuntimeFlags(_ processes: [AppProcessInfo]) -> [String] {
        uniqueSorted(processes.flatMap(processFlags(for:)))
    }

    private func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func keyValueRow(key: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(key):")
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func formattedDateTime(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz (ZZZZZ)"
        return formatter.string(from: date)
    }

    private func formattedServerTimeZone(_ status: AppLetsEncryptStatus) -> String {
        if let serverTimeZone = status.serverTimeZone {
            return formattedTimeZone(serverTimeZone)
        }

        if
            let abbreviation = status.serverTimeZoneAbbreviation?.trimmingCharacters(in: .whitespacesAndNewlines),
            !abbreviation.isEmpty
        {
            if
                let offset = status.serverTimeZoneOffset?.trimmingCharacters(in: .whitespacesAndNewlines),
                !offset.isEmpty
            {
                return "\(abbreviation) (\(formattedUTCOffset(offset)))"
            }

            return abbreviation
        }

        return "unknown"
    }

    private func formattedTimeZone(_ timeZone: TimeZone) -> String {
        let identifier = timeZone.identifier
        let abbreviation = timeZone.abbreviation() ?? "UTC"
        let offset = formattedUTCOffset(timeZone.secondsFromGMT())
        return "\(identifier) (\(abbreviation), \(offset))"
    }

    private func formattedUTCOffset(_ offset: String) -> String {
        let normalized = offset.replacingOccurrences(of: ":", with: "")
        guard
            normalized.count == 5,
            let signCharacter = normalized.first
        else {
            return offset
        }

        let digits = normalized.dropFirst()
        guard digits.count == 4 else {
            return offset
        }

        let hours = digits.prefix(2)
        let minutes = digits.suffix(2)
        return "UTC\(signCharacter)\(hours):\(minutes)"
    }

    private func formattedUTCOffset(_ seconds: Int) -> String {
        let sign = seconds >= 0 ? "+" : "-"
        let absoluteSeconds = abs(seconds)
        let hours = absoluteSeconds / 3600
        let minutes = (absoluteSeconds % 3600) / 60
        return String(format: "UTC%@%02d:%02d", sign, hours, minutes)
    }

    private func syncSelectedApp() {
        selectedAppID = MenuBarController.resolvedSelectedAppID(
            previousSelectedID: selectedAppID,
            orderedApps: orderedApps
        )
    }

    private var emptyStateText: String {
        if store.hostConfig == nil {
            return "No Dokku host configured. Open Settings to add one."
        }

        if !store.ignoredApps.isEmpty {
            return "No apps to display. Check ignored apps in Settings."
        }

        return "No apps were found on this host."
    }
}
