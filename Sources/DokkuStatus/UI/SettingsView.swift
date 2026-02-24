import SwiftUI

private enum SettingsSection: String, CaseIterable, Hashable, Identifiable {
    case general
    case ignoredApps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .ignoredApps:
            return "Ignored Apps"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: StatusStore

    private let customProfileSelectionID = "__custom_profile__"

    @State private var selectedSection: SettingsSection = .general
    @State private var host = ""
    @State private var user = ""
    @State private var port = "22"
    @State private var sshAlias = ""
    @State private var selectedProfileID: String?
    @State private var errorMessage: String?
    @State private var ignoredAppName = ""
    @State private var ignoredAppError: String?
    @State private var didLoad = false
    @State private var isApplyingSelection = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailPane
        }
        .frame(width: 820, height: 520)
        .onAppear {
            guard !didLoad else {
                return
            }

            didLoad = true
            store.reloadProfileOptions()
            loadFromStore()
        }
        .onChange(of: store.hostConfig) { _, _ in
            guard didLoad else {
                return
            }

            loadFromStore()
        }
        .onChange(of: store.availableProfiles) { _, _ in
            guard didLoad else {
                return
            }

            syncSelectedProfile()
        }
        .onChange(of: selectedProfileID) { _, newValue in
            guard didLoad, !isApplyingSelection else {
                return
            }

            applyProfileSelection(newValue)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedProfileID) {
                Section("Host Profiles") {
                    ForEach(store.availableProfiles) { option in
                        profileRow(option)
                            .tag(Optional(option.id))
                    }

                    customProfileRow
                        .tag(Optional(customProfileSelectionID))
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 10) {
                Button("New Profile") {
                    beginCustomProfileCreation()
                }

                Spacer()

                Button("Delete") {
                    deleteSelectedProfile()
                }
                .disabled(!canDeleteSelectedProfile)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 280)
    }

    private func profileRow(_ option: HostProfileOption) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(option.config.displayTitle)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(option.source.badgeTitle)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            Text(option.config.displaySubtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var customProfileRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Custom Override")
                .lineLimit(1)

            Text("Create or edit a new host profile")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(detailTitle)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(detailSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Section", selection: $selectedSection) {
                    ForEach(SettingsSection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 270)
            }

            switch selectedSection {
            case .general:
                hostSection
            case .ignoredApps:
                ignoredAppsSection
            }

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var hostSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                TextField("Host", text: $host)
                    .textFieldStyle(.roundedBorder)

                TextField("User", text: $user)
                    .textFieldStyle(.roundedBorder)

                TextField("Port", text: $port)
                    .textFieldStyle(.roundedBorder)

                TextField("SSH Alias (optional)", text: $sshAlias)
                    .textFieldStyle(.roundedBorder)
            }
            .formStyle(.grouped)

            Text("If SSH Alias is set, it will be used instead of user@host.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Save Profile") {
                    save()
                }
                .keyboardShortcut(.defaultAction)

                Spacer()
            }
        }
    }

    private var ignoredAppsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isCustomProfileSelected {
                Text("Save and activate this profile to edit ignored apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let hostConfig = store.hostConfig {
                Text("Editing ignored apps for \(hostConfig.displayTitle).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Select or create a host profile first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            List {
                if isCustomProfileSelected {
                    Text("Ignored apps are unavailable for unsaved profiles")
                        .foregroundStyle(.secondary)
                } else if store.hostConfig == nil {
                    Text("No host profile selected")
                        .foregroundStyle(.secondary)
                } else {
                    if store.ignoredApps.isEmpty {
                        Text("No ignored apps")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.ignoredApps, id: \.self) { appName in
                            HStack {
                                Text(appName)
                                    .textSelection(.enabled)
                                Spacer()
                                Button("Remove") {
                                    store.removeIgnoredApp(appName)
                                    ignoredAppError = nil
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 280)

            HStack(spacing: 8) {
                TextField("App name", text: $ignoredAppName)
                    .textFieldStyle(.roundedBorder)

                Button("Add") {
                    addIgnoredApp()
                }
                .disabled(
                    store.hostConfig == nil ||
                    isCustomProfileSelected ||
                    ignoredAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            if let ignoredAppError {
                Text(ignoredAppError)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }

    private func loadFromStore() {
        isApplyingSelection = true
        defer { isApplyingSelection = false }

        if let config = store.hostConfig {
            host = config.host
            user = config.user
            port = String(config.port)
            sshAlias = config.sshAlias ?? ""
        } else {
            host = ""
            user = ""
            port = "22"
            sshAlias = ""
        }

        syncSelectedProfile(force: true)
        errorMessage = nil
    }

    private func save() {
        errorMessage = store.saveHostConfig(
            host: host,
            user: user,
            portText: port,
            sshAlias: sshAlias
        )

        if errorMessage == nil {
            store.reloadProfileOptions()
            loadFromStore()
            selectedSection = .general
        }
    }

    private func applyProfileSelection(_ selectionID: String?) {
        guard let selectionID else {
            return
        }

        guard selectionID != customProfileSelectionID else {
            return
        }

        store.activateHostProfile(optionID: selectionID)
        loadFromStore()
    }

    private func syncSelectedProfile(force: Bool = false) {
        if !force, selectedProfileID == customProfileSelectionID {
            return
        }

        let targetSelection = store.activeProfileOptionID ?? customProfileSelectionID
        if selectedProfileID != targetSelection {
            selectedProfileID = targetSelection
        }
    }

    private func addIgnoredApp() {
        ignoredAppError = store.addIgnoredApp(ignoredAppName)
        if ignoredAppError == nil {
            ignoredAppName = ""
        }
    }

    private func beginCustomProfileCreation() {
        isApplyingSelection = true
        selectedProfileID = customProfileSelectionID
        isApplyingSelection = false

        host = ""
        user = ""
        port = "22"
        sshAlias = ""
        errorMessage = nil
        ignoredAppError = nil
        selectedSection = .general
    }

    private func deleteSelectedProfile() {
        guard canDeleteSelectedProfile else {
            return
        }

        store.clearHostConfig()
        store.reloadProfileOptions()
        loadFromStore()
    }

    private var selectedProfileOption: HostProfileOption? {
        guard let selectedProfileID else {
            return nil
        }

        return store.availableProfiles.first(where: { $0.id == selectedProfileID })
    }

    private var canDeleteSelectedProfile: Bool {
        selectedProfileOption?.source == .saved
    }

    private var isCustomProfileSelected: Bool {
        selectedProfileID == customProfileSelectionID
    }

    private var detailTitle: String {
        if isCustomProfileSelected {
            return "Custom Override"
        }

        if let selectedProfileOption {
            return selectedProfileOption.config.displayTitle
        }

        if let hostConfig = store.hostConfig {
            return hostConfig.displayTitle
        }

        return "Dokku Host"
    }

    private var detailSubtitle: String {
        if isCustomProfileSelected {
            return "Define and save a new host profile."
        }

        guard let selectedProfileOption else {
            return "Select a host profile to edit settings."
        }

        return "\(selectedProfileOption.config.displaySubtitle) • \(selectedProfileOption.source.badgeTitle)"
    }
}
