import SwiftUI

struct MenuView: View {
    @ObservedObject var store: StatusStore
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryRow

            if let latestError = store.latestError {
                errorRow(message: latestError)
            }

            if store.apps.isEmpty {
                Text(emptyStateText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                appList
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
        .frame(width: 380)
    }

    private var summaryRow: some View {
        HStack {
            Label {
                Text(store.aggregateState.title)
                    .font(.headline)
            } icon: {
                Image(systemName: MenuBarController.symbolName(for: store.aggregateState))
                    .foregroundStyle(MenuBarController.summaryColor(for: store.aggregateState))
            }

            Spacer()

            Text("Last check: \(MenuBarController.relativeDateString(from: store.lastCheckedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var appList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(store.apps) { app in
                    appRow(app)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 260)
    }

    private func appRow(_ app: AppStatus) -> some View {
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
        .padding(.vertical, 2)
    }

    private var emptyStateText: String {
        if store.hostConfig == nil {
            return "No Dokku host configured. Open Settings to add one."
        }

        return "No apps were found on this host."
    }
}
