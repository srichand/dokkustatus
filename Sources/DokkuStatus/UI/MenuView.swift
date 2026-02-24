import SwiftUI

struct MenuView: View {
    @ObservedObject var store: StatusStore
    let onQuit: () -> Void
    @State private var selectedAppID: String?

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

            Text("Last check: \(MenuBarController.relativeDateString(from: store.lastCheckedAt))")
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
            .frame(maxHeight: 190)
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
        Button {
            selectedAppID = app.id
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.appName)
                        .font(.body)
                    Text(MenuBarController.relativeDateString(from: app.checkedAt))
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
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selectedAppID == app.id ? Color.accentColor.opacity(0.16) : Color.clear)
        )
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
                .frame(maxHeight: 210)
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

            if let rawStatus = app.rawStatus, !rawStatus.isEmpty {
                Text("Raw status: \(rawStatus)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let details = app.details {
                detailsSection(title: "Process") {
                    ForEach(details.processes, id: \.identifier) { process in
                        processRow(process)
                    }
                }

                detailsSection(title: "Networking") {
                    keyValueRow(
                        key: "Domains",
                        value: details.domains.isEmpty ? "none" : details.domains.joined(separator: ", ")
                    )
                    keyValueRow(
                        key: "Port mapping",
                        value: details.portMappings.isEmpty ? "none" : details.portMappings.joined(separator: ", ")
                    )
                }

                detailsSection(title: "Storage") {
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

                detailsSection(title: "Runtime Policy") {
                    keyValueRow(key: "Restart", value: details.restartPolicy ?? "unknown")
                }
            } else {
                Text("No detailed process data available.")
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

    private func processRow(_ process: AppProcessInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            keyValueRow(key: "Identifier", value: process.identifier)
            keyValueRow(key: "Status", value: process.status ?? (process.running ? "running" : "not running"))
            if let startedAt = process.startedAt {
                keyValueRow(key: "Started", value: MenuBarController.relativeDateString(from: startedAt))
            }
            if !process.running, let finishedAt = process.finishedAt {
                keyValueRow(key: "Finished", value: MenuBarController.relativeDateString(from: finishedAt))
            }
            if !process.running, let exitCode = process.exitCode {
                keyValueRow(key: "Exit code", value: "\(exitCode)")
            }
        }
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
